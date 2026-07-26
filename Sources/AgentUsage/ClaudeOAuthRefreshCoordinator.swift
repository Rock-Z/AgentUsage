import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum ClaudeOAuthRefreshPolicy {
    static func shouldAttempt(statusCode: Int, alreadyAttempted: Bool) -> Bool {
        statusCode == 401 && !alreadyAttempted
    }
}

enum ClaudeOAuthRefreshEnvironment {
    static func make(
        _ source: [String: String],
        workingDirectory: URL
    ) -> [String: String] {
        var environment = BinaryLocator.enrichedEnvironment(source)
        environment["PWD"] = workingDirectory.path
        environment.removeValue(forKey: "OLDPWD")
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment["CLAUDE_CODE_SAFE_MODE"] = "1"
        return environment
    }
}

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

        #if canImport(Darwin)
        try await runStatusPTY(binary: binary, environment: environment)
        #else
        throw FetchError.launchFailed("Claude OAuth refresh requires macOS")
        #endif
    }

    #if canImport(Darwin)
    private static func runStatusPTY(
        binary: String,
        environment: [String: String]
    ) async throws {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(
            ws_row: 50,
            ws_col: 160,
            ws_xpixel: 0,
            ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
            throw FetchError.launchFailed("Claude OAuth refresh PTY")
        }

        let primary = FileHandle(
            fileDescriptor: primaryFD,
            closeOnDealloc: true)
        let secondary = FileHandle(
            fileDescriptor: secondaryFD,
            closeOnDealloc: true)
        let process = Process()
        let workingDirectory = probeDirectory()
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        process.currentDirectoryURL = workingDirectory
        process.environment = ClaudeOAuthRefreshEnvironment.make(
            environment,
            workingDirectory: workingDirectory)

        primary.readabilityHandler = { handle in
            _ = try? handle.read(upToCount: 8_192)
        }
        defer {
            primary.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            try? primary.close()
            try? secondary.close()
        }

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed(
                "Claude OAuth refresh: \(error.localizedDescription)")
        }

        try await Task.sleep(for: .milliseconds(800))
        guard process.isRunning else {
            throw FetchError.launchFailed(
                "Claude exited before refreshing OAuth")
        }
        try primary.write(contentsOf: Data("/status\r".utf8))

        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(800))
            if process.isRunning {
                try? primary.write(contentsOf: Data("\r".utf8))
            }
        }
        guard process.isRunning else { return }

        try? primary.write(contentsOf: Data([0x03, 0x03]))
        try await Task.sleep(for: .milliseconds(200))
        if process.isRunning {
            process.terminate()
        }
    }

    private static func probeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentUsage-ClaudeOAuthRefresh",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    #endif
}
