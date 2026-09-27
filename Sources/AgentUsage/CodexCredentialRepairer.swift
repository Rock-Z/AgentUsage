import Foundation

/// Starts interactive Codex briefly, which reloads its stored credentials.
actor CodexCredentialRepairer {
    static let shared = CodexCredentialRepairer()

    private static let startupDuration: Duration = .seconds(2)
    private static let cooldown: TimeInterval = 5 * 60
    private var lastAttempt: Date?

    func cycle(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let now = Date()
        if let lastAttempt,
           now.timeIntervalSince(lastAttempt) < Self.cooldown
        {
            return
        }
        lastAttempt = now

        guard let binary = BinaryLocator.resolve("codex", env: environment) else {
            throw FetchError.binaryNotFound("codex")
        }
        let directory = IsolatedProcess.directory(named: "AgentUsage-CodexCredentialRepair")
        try await IsolatedProcess.runInPseudoTerminal(
            executable: binary,
            arguments: ["-s", "read-only", "-a", "untrusted"],
            environment: IsolatedProcess.environment(environment, in: directory),
            directory: directory
        ) { terminal, process in
            try await Task.sleep(for: Self.startupDuration)
            guard process.isRunning else {
                throw FetchError.launchFailed("Codex exited during credential repair")
            }
            try terminal.write(contentsOf: Data([0x03, 0x03]))
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
