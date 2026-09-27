import Foundation

enum ClaudeOAuthRefreshEnvironment {
    static func make(
        _ source: [String: String],
        workingDirectory: URL
    ) -> [String: String] {
        var environment = IsolatedProcess.environment(source, in: workingDirectory)
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment["CLAUDE_CODE_SAFE_MODE"] = "1"
        return environment
    }
}

/// Runs `claude /status` so Claude Code refreshes an expired OAuth token itself.
actor ClaudeOAuthRefreshCoordinator {
    static let shared = ClaudeOAuthRefreshCoordinator()

    private static let timeout: Duration = .seconds(8)
    private static let attemptCooldown: TimeInterval = 60

    private var inFlight: Task<Bool, Never>?
    private var lastAttemptAt: Date?

    func refresh(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Bool {
        if let inFlight {
            return await inFlight.value
        }
        if let lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < Self.attemptCooldown
        {
            return false
        }

        let task = Task.detached(priority: .utility) {
            do {
                try await Self.touchClaudeAuth(environment: environment)
                return true
            } catch {
                return false
            }
        }
        inFlight = task
        let succeeded = await task.value
        inFlight = nil
        lastAttemptAt = Date()
        return succeeded
    }

    private static func touchClaudeAuth(
        environment: [String: String]
    ) async throws {
        guard let binary = BinaryLocator.resolve("claude", env: environment) else {
            throw FetchError.binaryNotFound("claude")
        }
        let directory = IsolatedProcess.directory(named: "AgentUsage-ClaudeOAuthRefresh")
        try await IsolatedProcess.runInPseudoTerminal(
            executable: binary,
            environment: ClaudeOAuthRefreshEnvironment.make(
                environment,
                workingDirectory: directory),
            directory: directory
        ) { terminal, process in
            try await Task.sleep(for: .milliseconds(800))
            guard process.isRunning else {
                throw FetchError.launchFailed(
                    "Claude exited before refreshing OAuth")
            }
            try terminal.write(contentsOf: Data("/status\r".utf8))

            let deadline = ContinuousClock.now.advanced(by: Self.timeout)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(800))
                if process.isRunning {
                    try? terminal.write(contentsOf: Data("\r".utf8))
                }
            }
            guard process.isRunning else { return }

            try? terminal.write(contentsOf: Data([0x03, 0x03]))
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
