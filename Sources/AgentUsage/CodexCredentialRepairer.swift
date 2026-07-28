import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum CodexCredentialRepairTrigger {
    static func matches(error: Error) -> Bool {
        guard case let FetchError.timeout(operation) = error else {
            return false
        }
        return operation == "initialize"
    }
}

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

        let command = "codex"
        guard let binary = BinaryLocator.resolve(command, env: environment) else {
            throw FetchError.binaryNotFound(command)
        }

        #if canImport(Darwin)
        try await runPTYCycle(
            binary: binary,
            environment: environment)
        #else
        throw FetchError.launchFailed(
            "\(command) credential repair requires macOS")
        #endif
    }

    #if canImport(Darwin)
    private func runPTYCycle(
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
            throw FetchError.launchFailed("credential repair PTY")
        }

        let primary = FileHandle(
            fileDescriptor: primaryFD,
            closeOnDealloc: true)
        let secondary = FileHandle(
            fileDescriptor: secondaryFD,
            closeOnDealloc: true)
        let process = Process()
        let probeDirectory = Self.probeDirectory()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-s", "read-only", "-a", "untrusted"]
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        process.environment = Self.sanitizedEnvironment(
            environment,
            workingDirectory: probeDirectory)
        process.currentDirectoryURL = probeDirectory

        defer {
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
                "Codex credential repair: \(error.localizedDescription)")
        }

        try await Task.sleep(for: Self.startupDuration)
        guard process.isRunning else {
            throw FetchError.launchFailed("Codex exited during credential repair")
        }

        try primary.write(contentsOf: Data([0x03, 0x03]))
        try await Task.sleep(for: .milliseconds(300))
        if process.isRunning {
            process.terminate()
        }
    }

    private static func probeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentUsage-CodexCredentialRepair", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    private static func sanitizedEnvironment(
        _ source: [String: String],
        workingDirectory: URL
    ) -> [String: String] {
        var environment = BinaryLocator.enrichedEnvironment(source)
        environment["PWD"] = workingDirectory.path
        environment.removeValue(forKey: "OLDPWD")
        return environment
    }
    #endif
}
