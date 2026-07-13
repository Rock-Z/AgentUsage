import Foundation

#if canImport(Darwin)
import Darwin
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
        let resetCredits = (try? await CodexResetCreditFetcher(environment: environment).fetch())
            ?? rateLimitsResponse.rateLimitResetCredits?.snapshot
        let classifiedWindows = Self.classifyWindows(
            [limits.primary, limits.secondary].compactMap(Self.makeWindow))
        let now = Date()
        return UsageSnapshot(
            provider: .codex,
            fiveHour: classifiedWindows.short,
            sevenDay: classifiedWindows.long,
            credits: limits.credits?.snapshot,
            resetCredits: resetCredits,
            billingCost: nil,
            localUsageCost: nil,
            accountEmail: account?.email,
            plan: account?.plan ?? limits.planType,
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
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }

    var snapshot: ResetCreditSnapshot {
        ResetCreditSnapshot(
            availableCount: availableCount,
            credits: credits.map(\.snapshot))
    }
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

private struct CodexResetCreditFetcher {
    var environment: [String: String]

    func fetch() async throws -> ResetCreditSnapshot {
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
        request.setValue("aiusage", forHTTPHeaderField: "User-Agent")

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
        return try decoder.decode(CodexResetCreditsResponse.self, from: data).snapshot
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
            .appendingPathComponent("aiusage-CodexProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex-claude-bar", "version": "0.1"]],
            timeout: 8)
        try sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        try await decodeResult(from: request(method: "account/rateLimits/read", timeout: 3))
    }

    func fetchAccount() async throws -> CodexAccountResponse {
        try await decodeResult(from: request(method: "account/read", timeout: 3))
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
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var costScanner = CostUsageScanner(provider: .claude)

    func fetch() async throws -> UsageSnapshot {
        guard let binary = BinaryLocator.resolve("claude", env: environment) else {
            throw FetchError.binaryNotFound("claude")
        }
        let usageText = try await PTYCommandSession.shared.captureClaudeUsage(
            binary: binary,
            environment: environment,
            timeout: 20)
        var parsed = try ClaudeUsageParser.parse(usageText: usageText)
        if parsed.fiveHour != nil, parsed.accountEmail == nil, parsed.plan == nil {
            let statusText = try? await PTYCommandSession.shared.capture(
                subcommand: "/status",
                binary: binary,
                environment: environment,
                timeout: 4,
                stopWhen: { clean in
                    clean.localizedCaseInsensitiveContains("Account") ||
                        clean.localizedCaseInsensitiveContains("Login")
                })
            if let statusText {
                parsed = try ClaudeUsageParser.parse(usageText: usageText, statusText: statusText)
            }
        }
        let localUsageCost = parsed.localUsageDollars.map {
            CostSnapshot(dollars: $0, since: Date(), updatedAt: Date(), scannedFiles: 0)
        }
        let scannedCost: CostSnapshot?
        if environment["AIUSAGE_SCAN_CLAUDE_FILES"] == "1" {
            scannedCost = (try? costScanner.scanCurrentBillingPeriod()).flatMap { snapshot in
                localUsageCost != nil && snapshot.dollars == 0 ? nil : snapshot
            }
        } else {
            scannedCost = nil
        }
        return UsageSnapshot(
            provider: .claude,
            fiveHour: parsed.fiveHour,
            sevenDay: parsed.sevenDay,
            billingCost: scannedCost,
            localUsageCost: localUsageCost,
            accountEmail: parsed.accountEmail,
            plan: parsed.plan,
            source: "claude /usage",
            updatedAt: Date())
    }
}

struct ClaudeUsageParseResult: Equatable {
    var fiveHour: RateWindow?
    var sevenDay: RateWindow?
    var localUsageDollars: Double?
    var accountEmail: String?
    var plan: String?
}

enum ClaudeUsageParser {
    static func parse(usageText: String, statusText: String? = nil) throws -> ClaudeUsageParseResult {
        let clean = TextParsing.stripANSICodes(usageText)
        guard !clean.isEmpty else { throw FetchError.parseFailed("empty Claude output") }
        let panel = trimToLatestUsagePanel(clean) ?? clean
        let lines = panel.components(separatedBy: .newlines)

        let identitySource = clean + "\n" + (statusText.map(TextParsing.stripANSICodes) ?? "")
        let plan = extractFirst(pattern: #"(?i)(Claude\s+[A-Za-z0-9 _.-]{2,24})"#, text: identitySource)
        guard let sessionLeft = extractPercentLeft(label: "Current session", lines: lines)
            ?? orderedPercents(panel).first else {
            if isSubscriptionNoticeOnly(clean) {
                return ClaudeUsageParseResult(
                    fiveHour: nil,
                    sevenDay: nil,
                    localUsageDollars: parseTotalCostDollars(clean),
                    accountEmail: extractFirst(
                        pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                        text: identitySource),
                    plan: plan ?? "Claude subscription")
            }
            if isLocalUsageOnly(clean) {
                return ClaudeUsageParseResult(
                    fiveHour: nil,
                    sevenDay: nil,
                    localUsageDollars: parseTotalCostDollars(clean),
                    accountEmail: extractFirst(
                        pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                        text: identitySource),
                    plan: plan ?? "Claude local usage")
            }
            if ProcessInfo.processInfo.environment["DEBUG_CLAUDE_USAGE"] == "1" {
                fputs("--- Claude usage capture ---\n\(clean)\n--- end capture ---\n", stderr)
            }
            throw FetchError.parseFailed("missing Current session percentage")
        }
        let weeklyLeft = extractPercentLeft(label: "Current week (all models)", lines: lines)
            ?? extractPercentLeft(label: "Current week", lines: lines)
            ?? orderedPercents(panel).dropFirst().first

        let sessionReset = extractReset(label: "Current session", lines: lines)
        let weeklyReset = extractReset(label: "Current week", lines: lines)

        return ClaudeUsageParseResult(
            fiveHour: RateWindow(
                usedPercent: 100 - Double(sessionLeft),
                windowMinutes: 5 * 60,
                resetsAt: parseResetDate(sessionReset),
                resetDescription: sessionReset),
            sevenDay: weeklyLeft.map {
                RateWindow(
                    usedPercent: 100 - Double($0),
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: parseResetDate(weeklyReset),
                    resetDescription: weeklyReset)
            },
            localUsageDollars: parseTotalCostDollars(clean),
            accountEmail: extractFirst(pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, text: identitySource),
            plan: plan)
    }

    static func parseTotalCostDollars(_ text: String) -> Double? {
        let clean = TextParsing.stripANSICodes(text)
        let patterns = [
            #"(?i)total\s+cost\s*:?\s*\$?\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"(?i)\$\s*([0-9]+(?:\.[0-9]+)?)"#,
        ]
        for pattern in patterns {
            guard let value = extractFirst(pattern: pattern, text: clean),
                  let dollars = Double(value) else {
                continue
            }
            return dollars
        }
        return nil
    }

    static func isSubscriptionNoticeOnly(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        guard normalized.contains("currentlyusingyoursubscription"),
              normalized.contains("claudecodeusage") else {
            return false
        }
        return !normalized.contains("currentsession") && !normalized.contains("currentweek")
    }

    static func isLocalUsageOnly(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        let hasLocalStats = normalized.contains("totalcost")
            || normalized.contains("whatscontributingtoyourlimitsusage")
            || normalized.contains("scanninglocalsessions")
        let hasQuotaStats = normalized.contains("currentsession") || normalized.contains("currentweek")
        return hasLocalStats && !hasQuotaStats
    }

    private static func trimToLatestUsagePanel(_ text: String) -> String? {
        guard let range = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = String(text[range.lowerBound...])
        return tail.range(of: "Usage", options: .caseInsensitive) == nil ? nil : tail
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func extractPercentLeft(label: String, lines: [String]) -> Int? {
        let normalizedLabel = normalized(label)
        let normalizedLines = lines.map(normalized)
        for (index, line) in normalizedLines.enumerated() where line.contains(normalizedLabel) {
            for candidate in lines.dropFirst(index).prefix(12) {
                if let percent = percentLeft(from: candidate) {
                    return percent
                }
            }
        }
        return nil
    }

    private static func orderedPercents(_ text: String) -> [Int] {
        text.components(separatedBy: .newlines).compactMap(percentLeft)
    }

    private static func percentLeft(from line: String) -> Int? {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]) else {
            return nil
        }
        let clamped = max(0, min(100, value))
        let lower = line.lowercased()
        if lower.contains("used") || lower.contains("spent") || lower.contains("consumed") {
            return Int((100 - clamped).rounded())
        }
        if lower.contains("left") || lower.contains("remaining") || lower.contains("available") {
            return Int(clamped.rounded())
        }
        return nil
    }

    private static func extractReset(label: String, lines: [String]) -> String? {
        let normalizedLabel = normalized(label)
        let normalizedLines = lines.map(normalized)
        for (index, line) in normalizedLines.enumerated() where line.contains(normalizedLabel) {
            for candidate in lines.dropFirst(index).prefix(14) {
                guard let range = candidate.range(of: "Resets", options: .caseInsensitive) else {
                    continue
                }
                return String(candidate[range.lowerBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ")")))
            }
        }
        return nil
    }

    private static func parseResetDate(_ text: String?, now: Date = Date()) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"\s*\([^)]+\)"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.defaultDate = now
        let formats = ["MMM d h:mma", "MMM d, h:mma", "MMM d ha", "MMM d, ha", "h:mma", "ha"]
        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: raw) {
                if format.hasPrefix("h") {
                    let calendar = Calendar.current
                    let comps = calendar.dateComponents([.hour, .minute], from: parsed)
                    let anchored = calendar.date(
                        bySettingHour: comps.hour ?? 0,
                        minute: comps.minute ?? 0,
                        second: 0,
                        of: now)
                    if let anchored, anchored >= now { return anchored }
                    return anchored.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                }
                return parsed
            }
        }
        return nil
    }

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: min(1, match.numberOfRanges - 1)), in: text) else {
            return nil
        }
        return String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(Darwin)
actor PTYCommandSession {
    static let shared = PTYCommandSession()

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?
    private var binaryPath: String?

    func captureClaudeUsage(binary: String, environment: [String: String], timeout: TimeInterval) async throws -> String {
        var output = try await capture(
            subcommand: "/usage",
            binary: binary,
            environment: environment,
            timeout: min(timeout, 8),
            stopWhen: { clean in
                let compact = clean.lowercased().filter { !$0.isWhitespace }
                let hasQuotaPanel = compact.contains("currentsession") &&
                    (compact.contains("%left") || compact.contains("%used") || compact.contains("%remaining"))
                return hasQuotaPanel ||
                    ClaudeUsageParser.isSubscriptionNoticeOnly(clean) ||
                    ClaudeUsageParser.isLocalUsageOnly(clean)
            })
        if !output.localizedCaseInsensitiveContains("Current session"),
           !ClaudeUsageParser.isSubscriptionNoticeOnly(output),
           !ClaudeUsageParser.isLocalUsageOnly(output)
        {
            output = try await capture(
                subcommand: "/usage",
                binary: binary,
                environment: environment,
                timeout: 8,
                stopWhen: { clean in
                    clean.localizedCaseInsensitiveContains("Current session") ||
                        ClaudeUsageParser.isSubscriptionNoticeOnly(clean) ||
                        ClaudeUsageParser.isLocalUsageOnly(clean)
                })
        }
        return output
    }

    func capture(
        subcommand: String,
        binary: String,
        environment: [String: String],
        timeout: TimeInterval,
        stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String
    {
        try ensureStarted(binary: binary, environment: environment)
        if let process, !process.isRunning {
            cleanup()
            throw FetchError.launchFailed("process exited")
        }
        drain()
        try send(subcommand)
        try send("\r")

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutputAt = Date()
        while Date() < deadline {
            let chunk = readChunk()
            if !chunk.isEmpty {
                buffer.append(chunk)
                lastOutputAt = Date()
                if let text = String(data: buffer, encoding: .utf8) {
                    let clean = TextParsing.stripANSICodes(text)
                    respondToPrompts(clean)
                    if stopWhen(clean) {
                        try await Task.sleep(for: .milliseconds(350))
                        buffer.append(readChunk())
                        return String(data: buffer, encoding: .utf8) ?? text
                    }
                }
            }
            if !buffer.isEmpty, Date().timeIntervalSince(lastOutputAt) > 3 {
                break
            }
            if let process, !process.isRunning {
                throw FetchError.launchFailed("process exited")
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        guard let text = String(data: buffer, encoding: .utf8), !text.isEmpty else {
            throw FetchError.timeout(subcommand)
        }
        return text
    }

    func reset() {
        cleanup()
    }

    private func ensureStarted(binary: String, environment: [String: String]) throws {
        if let process, process.isRunning, binaryPath == binary { return }
        cleanup()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
            throw FetchError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--allowed-tools", ""]
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        process.environment = Self.claudeEnvironment(environment)
        process.currentDirectoryURL = Self.probeDirectory()

        do {
            try process.run()
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw FetchError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
        self.binaryPath = binary
    }

    private static func claudeEnvironment(_ base: [String: String]) -> [String: String] {
        var env = BinaryLocator.enrichedEnvironment(base)
        for key in env.keys where key.hasPrefix("ANTHROPIC_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    private static func probeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aiusage-ClaudeProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func respondToPrompts(_ clean: String) {
        let prompts: [(String, String)] = [
            ("Do you trust the files in this folder?", "y\r"),
            ("Quick safety check:", "\r"),
            ("Yes, I trust this folder", "\r"),
            ("Ready to code here?", "\r"),
            ("Press Enter to continue", "\r"),
            ("Show plan usage limits", "\r"),
            ("Show plan", "\r"),
        ]
        for (needle, response) in prompts where clean.localizedCaseInsensitiveContains(needle) {
            try? send(response)
        }
        if clean.contains("\u{1B}[6n") {
            try? send("\u{1b}[1;1R")
        }
    }

    private func cleanup() {
        if let process, process.isRunning {
            try? send("/exit\r")
            process.terminate()
        }
        try? primaryHandle?.close()
        try? secondaryHandle?.close()
        process = nil
        primaryHandle = nil
        secondaryHandle = nil
        primaryFD = -1
        binaryPath = nil
    }

    private func drain() {
        _ = readChunk()
    }

    private func readChunk() -> Data {
        guard primaryFD >= 0 else { return Data() }
        var data = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(primaryFD, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else {
                break
            }
        }
        return data
    }

    private func send(_ text: String) throws {
        guard let data = text.data(using: .utf8), primaryFD >= 0 else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(primaryFD, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EINTR || errno == EAGAIN {
                    usleep(5_000)
                } else {
                    throw FetchError.launchFailed("PTY write failed")
                }
            }
        }
    }
}
#endif

struct CostUsageScanner: @unchecked Sendable {
    var provider: Provider
    var fileManager: FileManager = .default
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var now: Date = Date()

    func scanCurrentBillingPeriod() throws -> CostSnapshot {
        let calendar = Calendar.current
        let periodStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var total = 0.0
        var scanned = 0
        for root in roots() where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" || url.pathExtension == "json" {
                guard shouldScanFile(url, since: periodStart) else { continue }
                scanned += 1
                total += scanFile(url, since: periodStart)
            }
        }
        return CostSnapshot(dollars: total, since: periodStart, updatedAt: now, scannedFiles: scanned)
    }

    private func roots() -> [URL] {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        switch provider {
        case .codex:
            return [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            ]
        case .claude:
            return [
                home.appendingPathComponent(".claude/projects", isDirectory: true),
                home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            ]
        }
    }

    private func shouldScanFile(_ url: URL, since: Date) -> Bool {
        let calendar = Calendar.current
        let sinceComponents = calendar.dateComponents([.year, .month], from: since)
        let pathComponents = url.pathComponents
        for index in pathComponents.indices {
            guard let year = Int(pathComponents[index]), year >= 2_000,
                  pathComponents.indices.contains(index + 1),
                  let month = Int(pathComponents[index + 1]),
                  (1...12).contains(month) else {
                continue
            }
            if year < (sinceComponents.year ?? year) { return false }
            if year == sinceComponents.year, month < (sinceComponents.month ?? month) { return false }
            return true
        }

        if let date = Self.dateFromRolloutFilename(url.lastPathComponent) {
            return date >= since
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           modified < since {
            return false
        }
        return true
    }

    private func scanFile(_ url: URL, since: Date) -> Double {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var total = 0.0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any],
                  let timestamp = timestamp(in: object),
                  timestamp >= since else { continue }
            total += explicitCost(in: object) ?? 0
        }
        return total
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        let keys = ["timestamp", "created_at", "createdAt", "time", "ts"]
        for key in keys {
            if let string = object[key] as? String, let date = Self.parseDate(string) {
                return date
            }
            if let number = object[key] as? NSNumber {
                let raw = number.doubleValue
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
            }
        }
        return nil
    }

    private func explicitCost(in value: Any) -> Double? {
        let costKeys = Set([
            "cost_usd",
            "costUSD",
            "total_cost_usd",
            "totalCostUsd",
            "total_cost",
            "cost",
            "usd",
        ])
        var values: [Double] = []
        func walk(_ value: Any, key: String?) {
            if let key, costKeys.contains(key) {
                if let number = value as? NSNumber { values.append(number.doubleValue) }
                if let string = value as? String, let double = Double(string) { values.append(double) }
            }
            if let dict = value as? [String: Any] {
                for (childKey, childValue) in dict {
                    walk(childValue, key: childKey)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child, key: nil)
                }
            }
        }
        walk(value, key: nil)
        return values.max()
    }

    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private static func dateFromRolloutFilename(_ name: String) -> Date? {
        guard let range = name.range(
            of: #"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#,
            options: .regularExpression) else {
            return nil
        }
        let stamp = String(name[range])
            .replacingOccurrences(of: "rollout-", with: "")
            .replacingOccurrences(of: #"T(\d{2})-(\d{2})-(\d{2})"#, with: "T$1:$2:$3Z", options: .regularExpression)
        return Self.parseDate(stamp)
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
