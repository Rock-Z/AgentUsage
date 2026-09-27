import Darwin
import Foundation

/// Launches agent CLIs away from any project directory, for probes and credential touches.
enum IsolatedProcess {
    static func directory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func environment(
        _ source: [String: String],
        in directory: URL
    ) -> [String: String] {
        var environment = BinaryLocator.enrichedEnvironment(source)
        environment["PWD"] = directory.path
        environment.removeValue(forKey: "OLDPWD")
        return environment
    }

    /// Terminates `process` if it is still running after `timeout`. Call the
    /// returned closure after the process exits to learn whether that happened.
    static func terminate(_ process: Process, after timeout: TimeInterval) -> () -> Bool {
        let kill = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        return {
            kill.cancel()
            return process.terminationReason == .uncaughtSignal
        }
    }

    /// Runs `executable` attached to a pseudo-terminal, as interactive CLIs
    /// expect. `interact` drives it through the terminal's primary handle; the
    /// process is terminated when `interact` returns.
    static func runInPseudoTerminal(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        directory: URL,
        interact: (FileHandle, Process) async throws -> Void
    ) async throws {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
            throw FetchError.launchFailed("could not open a pseudo-terminal")
        }

        let primary = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        process.currentDirectoryURL = directory
        process.environment = environment

        // Drain output so a chatty CLI cannot block on a full terminal buffer.
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
                "\(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)")
        }
        try await interact(primary, process)
    }
}
