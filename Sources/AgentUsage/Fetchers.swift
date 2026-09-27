import Foundation

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
        let directories = (enrichedEnvironment(env)["PATH"] ?? "").split(separator: ":")
        return directories
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
            .first(where: fileManager.isExecutableFile(atPath:))
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
        do {
            return try await fetchOnce()
        } catch FetchError.timeout("initialize") {
            // A stale credential makes app-server hang during initialize.
            try await CodexCredentialRepairer.shared.cycle(
                environment: environment)
            return try await fetchOnce()
        }
    }

    private func fetchOnce() async throws -> UsageSnapshot {
        let rpc = try CodexRPCClient(environment: environment)
        defer { rpc.shutdown() }
        try await rpc.initialize()
        let response = try await rpc.fetchRateLimits()
        let activity = try? await CodexActivityCache.shared.fetch(using: rpc)
        return UsageSnapshot(
            provider: .codex,
            limits: response.limits,
            credits: response.rateLimits.credits?.snapshot,
            resetCredits: response.rateLimitResetCredits.map {
                ResetCreditSnapshot(availableCount: $0.availableCount, credits: $0.credits ?? [])
            },
            // Usage is a live server response; account/read can reflect old sign-in metadata.
            plan: PlanNames.codex(response.rateLimits.planType),
            codexActivity: activity,
            updatedAt: Date())
    }
}

struct CodexRateLimitsResponse: Decodable {
    struct ResetCredits: Decodable {
        let availableCount: Int
        let credits: [ResetCredit]?
    }

    /// The account's main limit; also carries plan and credits.
    let rateLimits: CodexRateLimitSnapshot
    /// Every limit, including model-specific ones, keyed by limit id.
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    let rateLimitResetCredits: ResetCredits?

    /// One entry per reported window, main limit first. Titles combine the
    /// window length with the limit's own name, e.g. "7d" or "7d gpt-reserve".
    var limits: [UsageLimit] {
        let mainID = rateLimits.limitId ?? "codex"
        var byID = rateLimitsByLimitId ?? [:]
        byID[mainID] = byID[mainID] ?? rateLimits
        let ids = [mainID] + byID.keys.filter { $0 != mainID }.sorted()
        return ids.flatMap { id -> [UsageLimit] in
            guard let snapshot = byID[id] else { return [] }
            let name = id == mainID
                ? nil
                : snapshot.limitName ?? snapshot.normalModelSlug ?? humanizedIdentifier(id)
            return [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
                .compactMap { slot, window in window.map { (slot, $0) } }
                .sorted { ($0.1.windowDurationMins ?? .max) < ($1.1.windowDurationMins ?? .max) }
                .map { slot, window in
                    let duration = window.windowDurationMins.map(UsageLimit.durationLabel(minutes:))
                    return UsageLimit(
                        id: "\(id).\(slot)",
                        title: [duration ?? (name == nil ? "Limit" : nil), name]
                            .compactMap { $0 }.joined(separator: " "),
                        usedPercent: max(0, min(100, window.usedPercent)),
                        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        scope: name)
                }
        }
    }
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

struct CodexRateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let normalModelSlug: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
    let credits: CodexCredits?
}

struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct CodexCredits: Decodable {
    let balance: Double?
    let unlimited: Bool

    var snapshot: CreditSnapshot {
        CreditSnapshot(balance: balance, unlimited: unlimited)
    }

    private enum CodingKeys: CodingKey { case balance, unlimited }

    // The balance arrives as either a string or a number.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = (try? container.decode(String.self, forKey: .balance)).flatMap(Double.init)
            ?? (try? container.decode(Double.self, forKey: .balance))
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
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
    private let stderrBuffer = DiagnosticBuffer()

    private struct JSONMessage: @unchecked Sendable {
        var value: [String: Any]
    }

    // Drain stderr continuously so a noisy server cannot fill its pipe, and
    // never wait for EOF from a process that may still be running.
    private final class DiagnosticBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            data = Data(data.suffix(4096))
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        // `app-server` is a subcommand in current Codex releases. The old
        // `-a untrusted app-server` form now exits immediately because
        // `untrusted` is no longer a valid approval policy, which otherwise
        // surfaces here as the misleading "closed stdout" error.
        process.arguments = [binary, "app-server", "--stdio"]
        process.environment = BinaryLocator.enrichedEnvironment(environment)
        process.currentDirectoryURL = IsolatedProcess.directory(named: "AgentUsage-CodexProbe")
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed(error.localizedDescription)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
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

    func fetchAccountUsage() async throws -> CodexAccountUsageResponse {
        try await decodeResult(from: request(method: "account/usage/read", timeout: 8))
    }

    func shutdown() {
        stdoutContinuation.finish()
        try? stdinPipe.fileHandleForWriting.close()
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
            defer { group.cancelAll() }
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
                try Task.checkCancellation()
                let stderr = self.stderrBuffer.text()
                let status = self.process.isRunning
                    ? "still running" : "exit \(self.process.terminationStatus)"
                if !stderr.isEmpty {
                    let detail = String(
                        stderr.replacingOccurrences(of: "\n", with: " ").prefix(500))
                    throw FetchError.malformed(
                        "codex app-server closed stdout (\(status)): \(detail)")
                }
                throw FetchError.malformed(
                    "codex app-server closed stdout (\(status))")
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: data)
    }
}

struct ClaudeUsageFetcher: UsageFetching {
    private static let gate = ClaudeOAuthUsageRateLimitGate()
    private static let planLifetime: TimeInterval = 60 * 60

    var environment: [String: String] = ProcessInfo.processInfo.environment

    func fetch() async throws -> UsageSnapshot {
        let gate = Self.gate
        switch await gate.decision() {
        case let .cached(snapshot):
            return snapshot
        case let .blocked(until):
            throw ClaudeOAuthFetchError.rateLimited(until: until)
        case .request:
            break
        }

        // Plans change rarely; skip the profile request while the label is fresh.
        let includePlan = await gate.planNeedsRefresh(lifetime: Self.planLifetime)
        var response = try await ClaudeCredentialHelper.fetch(includePlan: includePlan)
        if response.statusCode == 401,
           await ClaudeOAuthRefreshCoordinator.shared.refresh(environment: environment)
        {
            response = try await ClaudeCredentialHelper.fetch(includePlan: includePlan)
        }
        if response.statusCode == 429 {
            let retryAfter = Self.retryAfterDate(from: response.retryAfter)
            if let cached = await gate.recordRateLimit(retryAfter: retryAfter) {
                return cached
            }
            throw ClaudeOAuthFetchError.rateLimited(
                until: await gate.currentBlockedUntil())
        }
        if response.statusCode == 401 {
            throw ClaudeOAuthFetchError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw FetchError.malformed(
                "Claude OAuth returned HTTP \(response.statusCode)")
        }
        let plan = if includePlan {
            await gate.recordPlan(
                PlanNames.claude(response.subscriptionType, rateLimitTier: response.rateLimitTier),
                lookupSucceeded: response.subscriptionType != nil)
        } else {
            await gate.cachedPlan()
        }
        let snapshot = try Self.snapshot(from: response.body, plan: plan)
        await gate.recordSuccess(snapshot)
        return snapshot
    }

    static func snapshot(
        from data: Data,
        plan: String? = nil,
        updatedAt: Date = Date()
    ) throws -> UsageSnapshot {
        let response: Response
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw FetchError.parseFailed("invalid Claude OAuth usage response")
        }
        return UsageSnapshot(
            provider: .claude,
            limits: limits(response.limits ?? []),
            credits: creditSnapshot(response.extraUsage, spendCurrency: response.spend?.used?.currency),
            plan: plan,
            updatedAt: updatedAt)
    }

    /// One entry per reported limit, titled from its group and scope, such as
    /// "Session", "Weekly", or "Weekly Fable". Presence, not `is_active` or
    /// nonzero usage, determines visibility; the first entry per title wins.
    private static func limits(_ entries: [Response.Limit]) -> [UsageLimit] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let percent = entry.percent, percent.isFinite,
                  let base = (entry.group ?? entry.kind).map(humanizedIdentifier)
            else { return nil }
            let scope = entry.scope?.model?.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? entry.scope?.surface.map(humanizedIdentifier)
            let title = [base, scope].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " ")
            guard seen.insert(title).inserted else { return nil }
            return UsageLimit(
                id: title,
                title: title,
                usedPercent: max(0, min(100, percent)),
                resetsAt: parseISO8601Date(entry.resetsAt),
                scope: scope?.isEmpty == false ? scope : nil)
        }
    }

    /// Remaining extra-usage credit; zero while extra usage is off.
    private static func creditSnapshot(
        _ extraUsage: Response.ExtraUsage?,
        spendCurrency: String?
    ) -> CreditSnapshot? {
        guard let extraUsage else { return nil }
        let currency = extraUsage.currency ?? spendCurrency
        guard extraUsage.isEnabled == true, let monthlyLimit = extraUsage.monthlyLimit else {
            return CreditSnapshot(balance: 0, unlimited: false, currencyCode: currency)
        }
        // Claude OAuth reports monetary values in minor currency units (for
        // example, 10000 USD means $100.00), matching Claude's web API.
        let remaining = max(0, monthlyLimit - (extraUsage.usedCredits ?? 0)) / 100
        return CreditSnapshot(balance: remaining, unlimited: false, currencyCode: currency)
    }

    private static func retryAfterDate(
        from header: String?,
        now: Date = Date()
    ) -> Date? {
        guard let value = header?
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

    // Decoded with `.convertFromSnakeCase`.
    private struct Response: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    var displayName: String?
                }
                var model: Model?
                var surface: String?

                private enum CodingKeys: CodingKey { case model, surface }

                // Unknown scope shapes must not fail the whole usage response.
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    model = try? container.decode(Model.self, forKey: .model)
                    surface = try? container.decode(String.self, forKey: .surface)
                }
            }
            var kind: String?
            var group: String?
            var percent: Double?
            var resetsAt: String?
            var scope: Scope?
        }

        struct ExtraUsage: Decodable {
            var isEnabled: Bool?
            var monthlyLimit: Double?
            var usedCredits: Double?
            var currency: String?
        }

        struct Spend: Decodable {
            struct Amount: Decodable {
                var currency: String?
            }
            var used: Amount?
        }

        var extraUsage: ExtraUsage?
        var limits: [Limit]?
        var spend: Spend?

        private enum CodingKeys: CodingKey { case extraUsage, limits, spend }

        // `spend` only supplies a currency; an unexpected shape must not fail usage.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
            limits = try container.decodeIfPresent([Limit].self, forKey: .limits)
            spend = try? container.decode(Spend.self, forKey: .spend)
        }
    }
}

private enum ClaudeOAuthFetchError: LocalizedError {
    case unauthorized
    case rateLimited(until: Date?)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Claude OAuth authorization expired. Open Claude Code to refresh its sign-in."
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
    private var plan: String?
    private var planFetchedAt: Date?

    func planNeedsRefresh(lifetime: TimeInterval, now: Date = Date()) -> Bool {
        guard let planFetchedAt else { return true }
        return now.timeIntervalSince(planFetchedAt) >= lifetime
    }

    func cachedPlan() -> String? { plan }

    /// A failed profile lookup clears the label and is retried on the next fetch.
    func recordPlan(_ plan: String?, lookupSucceeded: Bool, now: Date = Date()) -> String? {
        self.plan = plan
        planFetchedAt = lookupSucceeded ? now : nil
        return plan
    }

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
