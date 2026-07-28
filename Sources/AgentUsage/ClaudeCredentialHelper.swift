import Foundation

struct ClaudeHelperResponse: Sendable {
    var statusCode: Int
    var retryAfter: String?
    var subscriptionType: String?
    var body: Data
}

enum ClaudeCredentialHelper {
    private static let executableName = "AgentUsageClaudeHelper"
    private static let timeout: TimeInterval = 12

    static func fetch() async throws -> ClaudeHelperResponse {
        let executable = try bundledExecutable()
        return try await Task.detached(priority: .utility) {
            try run(executable: executable)
        }.value
    }

    static func parse(_ output: Data) throws -> ClaudeHelperResponse {
        guard let firstNewline = output.firstIndex(of: 0x0A),
              let secondNewline = output[
                output.index(after: firstNewline)...
              ].firstIndex(of: 0x0A),
              let thirdNewline = output[
                output.index(after: secondNewline)...
              ].firstIndex(of: 0x0A),
              let statusCode = Int(
                String(decoding: output[..<firstNewline], as: UTF8.self))
        else {
            throw FetchError.parseFailed(
                "invalid Claude credential helper response framing")
        }

        let retryStart = output.index(after: firstNewline)
        let retryAfter = String(
            decoding: output[retryStart..<secondNewline],
            as: UTF8.self)
        let subscriptionStart = output.index(after: secondNewline)
        let subscriptionType = String(
            decoding: output[subscriptionStart..<thirdNewline],
            as: UTF8.self)
        let bodyStart = output.index(after: thirdNewline)
        return ClaudeHelperResponse(
            statusCode: statusCode,
            retryAfter: retryAfter.isEmpty ? nil : retryAfter,
            subscriptionType: subscriptionType.isEmpty
                ? nil
                : subscriptionType,
            body: Data(output[bodyStart...]))
    }

    private static func bundledExecutable() throws -> URL {
        let fileManager = FileManager.default
        // The helper delegates Keychain access to /usr/bin/security, so it no
        // longer needs a preserved on-disk identity. Always use the bundled
        // copy to prevent an older helper from surviving an app update.
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(executableName),
            fileManager.isExecutableFile(atPath: bundled.path)
        else {
            throw FetchError.launchFailed(
                "bundled Claude credential helper is missing")
        }
        return bundled
    }

    private static func run(executable: URL) throws -> ClaudeHelperResponse {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = process.currentDirectoryURL?.path
        environment.removeValue(forKey: "OLDPWD")
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed(
                "Claude credential helper: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw FetchError.timeout("Claude credential helper")
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FetchError.malformed(
                message.isEmpty
                    ? "Claude credential helper failed"
                    : message)
        }
        return try parse(output)
    }
}
