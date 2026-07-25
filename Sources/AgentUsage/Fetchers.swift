import Foundation

#if canImport(Security)
import Security
#endif

enum FetchError: LocalizedError {
    case binaryNotFound(String)
    case launchFailed(String)
    case timeout(String)
    case malformed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(binary):
            "`\(binary)` was not found on PATH."
        case let .launchFailed(message):
            "Launch failed: \(message)"
        case let .timeout(message):
            "Timed out: \(message)"
        case let .malformed(message):
            "Unexpected response: \(message)"
        case let .parseFailed(message):
            "Parse failed: \(message)"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageSnapshot
}

enum BinaryLocator {
    static func resolve(_ name: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fileManager = FileManager.default
        if name.contains("/"), fileManager.isExecutableFile(atPath: name) {
            return name
        }
        var candidates = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = env["HOME"] ?? NSHomeDirectory()
        candidates.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
        ])
        candidates.append(contentsOf: versionManagerBins(home: home))
        for dir in candidates {
            let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func enrichedEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var copy = env
        let home = env["HOME"] ?? NSHomeDirectory()
        let additions = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
        ] + versionManagerBins(home: home)
        let path = copy["PATH"] ?? ""
        copy["PATH"] = ([path] + additions).filter { !$0.isEmpty }.joined(separator: ":")
        copy["TERM"] = copy["TERM"] ?? "xterm-256color"
        return copy
    }

    private static func versionManagerBins(home: String) -> [String] {
        let fileManager = FileManager.default
        let roots = [
            "\(home)/.nvm/versions/node",
            "\(home)/.nodenv/versions",
            "\(home)/.asdf/installs/nodejs",
            "\(home)/.volta/bin",
        ]
        var bins: [String] = []
        for root in roots {
            if root.hasSuffix("/bin") {
                if fileManager.fileExists(atPath: root) { bins.append(root) }
                continue
            }
            guard let children = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for child in children.sorted(by: >) {
                let bin = URL(fileURLWithPath: root)
                    .appendingPathComponent(child)
                    .appendingPathComponent("bin")
                    .path
                if fileManager.fileExists(atPath: bin) {
                    bins.append(bin)
                }
            }
        }
        return bins
    }
}

struct CodexUsageFetcher: UsageFetching {
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func fetch() async throws -> UsageSnapshot {
        let rpc = try CodexRPCClient(environment: environment)
        defer { rpc.shutdown() }
        try await rpc.initialize()
        let rateLimitsResponse = try await rpc.fetchRateLimits()
        let limits = rateLimitsResponse.rateLimits
        let account = try? await rpc.fetchAccount()
        let activity = try? await CodexActivityCache.shared.fetch(using: rpc)
        let resetExpirationDetails = try? await CodexResetExpirationFetcher(environment: environment).fetch()
        let resetCredits = rateLimitsResponse.rateLimitResetCredits.map {
            ResetCreditSnapshot(
                availableCount: $0.availableCount,
                credits: resetExpirationDetails ?? [])
        }
        let classifiedWindows = Self.classifyWindows(
            [limits.primary, limits.secondary].compactMap(Self.makeWindow))
        let now = Date()
        return UsageSnapshot(
            provider: .codex,
            fiveHour: classifiedWindows.short,
            sevenDay: classifiedWindows.long,
            credits: limits.credits?.snapshot,
            resetCredits: resetCredits,
            accountEmail: account?.email,
            plan: account?.plan ?? limits.planType,
            codexActivity: activity,
            source: "codex app-server",
            updatedAt: now)
    }

    private static func makeWindow(_ rpc: CodexRateLimitWindow?) -> RateWindow? {
        guard let rpc else { return nil }
        return RateWindow(
            usedPercent: rpc.usedPercent,
            windowMinutes: rpc.windowDurationMins,
            resetsAt: rpc.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            resetDescription: nil)
    }

    static func classifyWindows(_ windows: [RateWindow]) -> (short: RateWindow?, long: RateWindow?) {
        let sorted = windows.sorted { lhs, rhs in
            switch (lhs.windowMinutes, rhs.windowMinutes) {
            case let (lhsMinutes?, rhsMinutes?): lhsMinutes < rhsMinutes
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): false
            }
        }
        guard let first = sorted.first else { return (nil, nil) }
        if sorted.count > 1 {
            return (first, sorted.last)
        }

        // A lone window is placed by its scale because the backend may collapse a
        // weekly window into `primary` when no shorter window applies.
        if let minutes = first.windowMinutes, minutes >= 24 * 60 {
            return (nil, first)
        }
        return (first, nil)
    }
}

private struct CodexRateLimitsResponse: Decodable {
    let rateLimits: CodexRateLimitSnapshot
    let rateLimitResetCredits: CodexResetCreditsSummary?
}

struct CodexAccountUsageResponse: Decodable {
    struct Summary: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSec: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }

    struct DailyBucket: Decodable {
        let startDate: String
        let tokens: Int64
    }

    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?

    var snapshot: CodexActivitySnapshot {
        CodexActivitySnapshot(
            lifetimeTokens: summary.lifetimeTokens,
            peakDailyTokens: summary.peakDailyTokens,
            longestRunningTurnSec: summary.longestRunningTurnSec,
            currentStreakDays: summary.currentStreakDays,
            longestStreakDays: summary.longestStreakDays,
            dailyUsage: (dailyUsageBuckets ?? []).map {
                TokenUsageDay(startDate: $0.startDate, tokens: $0.tokens)
            })
    }
}

private struct CodexRateLimitSnapshot: Decodable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
    let credits: CodexCredits?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct CodexCredits: Decodable {
    let balance: Double?
    let hasCredits: Bool
    let unlimited: Bool

    var snapshot: CreditSnapshot {
        CreditSnapshot(balance: balance, hasCredits: hasCredits, unlimited: unlimited)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        if let string = try? container.decode(String.self, forKey: DynamicCodingKey("balance")) {
            self.balance = Double(string)
        } else {
            self.balance = try? container.decode(Double.self, forKey: DynamicCodingKey("balance"))
        }
        self.hasCredits = (try? container.decode(Bool.self, forKey: DynamicCodingKey("hasCredits"))) ?? false
        self.unlimited = (try? container.decode(Bool.self, forKey: DynamicCodingKey("unlimited"))) ?? false
    }
}

private struct CodexResetCreditsSummary: Decodable {
    let availableCount: Int

    var snapshot: ResetCreditSnapshot {
        ResetCreditSnapshot(availableCount: availableCount, credits: [])
    }
}

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }

    let tokens: Tokens
}

private struct CodexResetCreditsResponse: Decodable {
    let credits: [CodexResetCredit]
}

private struct CodexResetCredit: Decodable {
    let resetType: String?
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case title
        case description
    }

    var snapshot: ResetCredit {
        ResetCredit(
            resetType: resetType,
            status: status,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            title: title,
            description: description)
    }
}

private struct CodexResetExpirationFetcher {
    var environment: [String: String]

    func fetch() async throws -> [ResetCredit] {
        let auth = try readAuthFile()
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            throw FetchError.malformed("invalid reset-credit endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentUsage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.malformed("missing reset-credit HTTP response")
        }
        guard http.statusCode == 200 else {
            throw FetchError.malformed("reset-credit endpoint returned HTTP \(http.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.isoDate(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO date: \(raw)")
        }
        return try decoder.decode(CodexResetCreditsResponse.self, from: data).credits.map(\.snapshot)
    }

    private func readAuthFile() throws -> CodexAuthFile {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".codex/auth.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CodexAuthFile.self, from: data)
        } catch {
            throw FetchError.malformed("could not read Codex auth for reset credits")
        }
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private struct CodexAccountResponse: Decodable {
    struct ChatGPTAccount: Decodable {
        let email: String?
        let plan: String?
    }

    let email: String?
    let plan: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        if let account = try? container.decode([String: ChatGPTAccount].self, forKey: DynamicCodingKey("account")),
           let chatgpt = account["chatgpt"] {
            self.email = chatgpt.email
            self.plan = chatgpt.plan
            return
        }
        self.email = try? container.decode(String.self, forKey: DynamicCodingKey("email"))
        self.plan = try? container.decode(String.self, forKey: DynamicCodingKey("plan"))
    }
}

private actor CodexActivityCache {
    static let shared = CodexActivityCache()

    private var cached: CodexActivitySnapshot?
    private var fetchedAt: Date?
    private let lifetime: TimeInterval = 60

    func fetch(using rpc: CodexRPCClient, now: Date = Date()) async throws -> CodexActivitySnapshot {
        if let cached, let fetchedAt, now.timeIntervalSince(fetchedAt) < lifetime {
            return cached
        }
        let snapshot = try await rpc.fetchAccountUsage().snapshot
        cached = snapshot
        fetchedAt = now
        return snapshot
    }
}

private final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutStream: AsyncStream<Data>
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1

    private struct JSONMessage: @unchecked Sendable {
        var value: [String: Any]
    }

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            var lines: [Data] = []
            while let newline = data.firstIndex(of: 0x0A) {
                let line = Data(data[..<newline])
                data.removeSubrange(...newline)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }

    init(environment: [String: String]) throws {
        guard let binary = BinaryLocator.resolve("codex", env: environment) else {
            throw FetchError.binaryNotFound("codex")
        }

        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutStream = AsyncStream { continuation = $0 }
        self.stdoutContinuation = continuation

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = BinaryLocator.enrichedEnvironment(environment)
        process.currentDirectoryURL = Self.probeDirectory()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed(error.localizedDescription)
        }

        let buffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutContinuation] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }
            for line in buffer.append(chunk) {
                stdoutContinuation.yield(line)
            }
        }
    }

    private static func probeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentUsage-CodexProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex-claude-bar", "version": "0.3"]],
            timeout: 8)
        try sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        try await decodeResult(from: request(method: "account/rateLimits/read", timeout: 3))
    }

    func fetchAccount() async throws -> CodexAccountResponse {
        try await decodeResult(from: request(method: "account/read", timeout: 3))
    }

    func fetchAccountUsage() async throws -> CodexAccountUsageResponse {
        try await decodeResult(from: request(method: "account/usage/read", timeout: 8))
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func request(method: String, params: [String: Any] = [:], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try sendPayload(["id": id, "method": method, "params": params])

        let wrapped = try await withThrowingTaskGroup(of: JSONMessage.self) { group in
            group.addTask { [stdoutStream] in
                for await line in stdoutStream {
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        continue
                    }
                    if message["id"] == nil {
                        continue
                    }
                    guard (message["id"] as? NSNumber)?.intValue == id || message["id"] as? Int == id else {
                        continue
                    }
                    if let error = message["error"] as? [String: Any],
                       let messageText = error["message"] as? String {
                        throw FetchError.malformed(messageText)
                    }
                    return JSONMessage(value: message)
                }
                throw FetchError.malformed("codex app-server closed stdout")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw FetchError.timeout(method)
            }
            guard let result = try await group.next() else {
                throw FetchError.timeout(method)
            }
            group.cancelAll()
            return result
        }
        return wrapped.value
    }

    private func sendNotification(method: String, params: [String: Any] = [:]) throws {
        try sendPayload(["method": method, "params": params])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw FetchError.malformed("missing result")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct ClaudeUsageFetcher: UsageFetching {
    func fetch() async throws -> UsageSnapshot {
        guard let credentials = ClaudeOAuthCredentialReader.loadFromKeychain() else {
            throw FetchError.malformed(
                "Claude OAuth credentials could not be read from Keychain")
        }
        guard !credentials.isExpired else {
            throw FetchError.malformed(
                "Claude OAuth credentials in Keychain have expired")
        }
        return try await ClaudeOAuthUsageFetcher.fetch(credentials: credentials)
    }
}

struct ClaudeOAuthCredentials: Sendable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?

    var isExpired: Bool {
        expiresAt.map { Date() >= $0 } ?? false
    }
}

enum ClaudeOAuthCredentialReader {
    private static let keychainService = "Claude Code-credentials"

    static func loadFromKeychain() -> ClaudeOAuthCredentials? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return parse(data)
        #else
        return nil
        #endif
    }

    static func parse(_ data: Data) -> ClaudeOAuthCredentials? {
        struct Root: Decodable {
            struct OAuth: Decodable {
                var accessToken: String?
                var expiresAt: Double?
                var subscriptionType: String?
            }
            var claudeAiOauth: OAuth?
        }

        guard let root = try? JSONDecoder().decode(Root.self, from: data),
              let oauth = root.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return ClaudeOAuthCredentials(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
            subscriptionType: oauth.subscriptionType)
    }
}

enum ClaudeOAuthUsageFetcher {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let gate = ClaudeOAuthUsageRateLimitGate()

    static func fetch(credentials: ClaudeOAuthCredentials) async throws -> UsageSnapshot {
        switch await gate.decision() {
        case let .cached(snapshot):
            return snapshot
        case let .blocked(until):
            throw ClaudeOAuthFetchError.rateLimited(until: until)
        case .request:
            break
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.malformed("missing Claude OAuth HTTP response")
        }
        if http.statusCode == 429 {
            let retryAfter = retryAfterDate(from: http)
            if let cached = await gate.recordRateLimit(retryAfter: retryAfter) {
                return cached
            }
            throw ClaudeOAuthFetchError.rateLimited(
                until: await gate.currentBlockedUntil())
        }
        guard http.statusCode == 200 else {
            throw FetchError.malformed("Claude OAuth returned HTTP \(http.statusCode)")
        }
        let snapshot = try snapshot(from: data, subscriptionType: credentials.subscriptionType)
        await gate.recordSuccess(snapshot)
        return snapshot
    }

    static func snapshot(
        from data: Data,
        subscriptionType: String? = nil,
        updatedAt: Date = Date()
    ) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FetchError.parseFailed("invalid Claude OAuth usage response")
        }
        return UsageSnapshot(
            provider: .claude,
            fiveHour: rateWindow(response.fiveHour, minutes: 5 * 60),
            sevenDay: rateWindow(response.sevenDay, minutes: 7 * 24 * 60),
            credits: creditSnapshot(response.extraUsage),
            accountEmail: nil,
            plan: planName(subscriptionType),
            source: "claude oauth",
            updatedAt: updatedAt)
    }

    private static func rateWindow(_ window: Response.Window?, minutes: Int) -> RateWindow? {
        guard let window, let utilization = window.utilization else { return nil }
        return RateWindow(
            usedPercent: max(0, min(100, utilization)),
            windowMinutes: minutes,
            resetsAt: parseISO8601(window.resetsAt),
            resetDescription: nil)
    }

    private static func creditSnapshot(_ extraUsage: Response.ExtraUsage?) -> CreditSnapshot? {
        guard let extraUsage, extraUsage.isEnabled == true,
              let monthlyLimit = extraUsage.monthlyLimit
        else { return nil }
        // Claude OAuth reports monetary values in minor currency units (for
        // example, 10000 USD means $100.00), matching Claude's web API.
        let remaining = max(0, monthlyLimit - (extraUsage.usedCredits ?? 0)) / 100
        return CreditSnapshot(
            balance: remaining,
            hasCredits: true,
            unlimited: false,
            currencyCode: extraUsage.currency)
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }

    private static func planName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        let name = value.replacingOccurrences(of: "_", with: " ").capitalized
        return name.localizedCaseInsensitiveContains("claude") ? name : "Claude \(name)"
    }

    private struct Response: Decodable {
        struct Window: Decodable {
            var utilization: Double?
            var resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct ExtraUsage: Decodable {
            var isEnabled: Bool?
            var monthlyLimit: Double?
            var usedCredits: Double?
            var utilization: Double?
            var currency: String?

            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
                case monthlyLimit = "monthly_limit"
                case usedCredits = "used_credits"
                case utilization
                case currency
            }
        }

        var fiveHour: Window?
        var sevenDay: Window?
        var extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case extraUsage = "extra_usage"
        }
    }
}

private enum ClaudeOAuthFetchError: LocalizedError {
    case rateLimited(until: Date?)

    var errorDescription: String? {
        switch self {
        case let .rateLimited(until):
            if let until {
                return "Claude usage is rate limited; retrying after \(DisplayFormatter.rateLimitResetDate(until))."
            }
            return "Claude usage is rate limited; retrying in a few minutes."
        }
    }
}

private actor ClaudeOAuthUsageRateLimitGate {
    enum Decision: Sendable {
        case request
        case cached(UsageSnapshot)
        case blocked(Date?)
    }

    private static let minimumRefreshInterval: TimeInterval = 60
    private static let defaultRateLimitCooldown: TimeInterval = 5 * 60
    private static let blockedUntilDefaultsKey = "claudeOAuthUsageBlockedUntil"

    private var cachedSnapshot: UsageSnapshot?
    private var lastSuccessfulFetchAt: Date?
    private var blockedUntil: Date?

    func decision(now: Date = Date()) -> Decision {
        let persistedBlockedUntil = UserDefaults.standard.object(
            forKey: Self.blockedUntilDefaultsKey) as? Double
        if blockedUntil == nil, let persistedBlockedUntil {
            blockedUntil = Date(timeIntervalSince1970: persistedBlockedUntil)
        }
        if let blockedUntil, blockedUntil > now {
            return cachedSnapshot.map(Decision.cached) ?? .blocked(blockedUntil)
        }
        self.blockedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.blockedUntilDefaultsKey)
        if let cachedSnapshot, let lastSuccessfulFetchAt,
           now.timeIntervalSince(lastSuccessfulFetchAt) < Self.minimumRefreshInterval
        {
            return .cached(cachedSnapshot)
        }
        return .request
    }

    func recordSuccess(_ snapshot: UsageSnapshot, now: Date = Date()) {
        cachedSnapshot = snapshot
        lastSuccessfulFetchAt = now
        blockedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.blockedUntilDefaultsKey)
    }

    func recordRateLimit(retryAfter: Date?, now: Date = Date()) -> UsageSnapshot? {
        let fallback = now.addingTimeInterval(Self.defaultRateLimitCooldown)
        let candidate = max(retryAfter ?? fallback, fallback)
        blockedUntil = max(blockedUntil ?? candidate, candidate)
        UserDefaults.standard.set(
            blockedUntil?.timeIntervalSince1970,
            forKey: Self.blockedUntilDefaultsKey)
        return cachedSnapshot
    }

    func currentBlockedUntil() -> Date? {
        blockedUntil
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
