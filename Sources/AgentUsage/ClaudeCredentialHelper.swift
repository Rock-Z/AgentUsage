import Foundation

struct ClaudeHelperResponse: Sendable {
    var statusCode: Int
    var retryAfter: String?
    var subscriptionType: String?
    var rateLimitTier: String?
    var body: Data
}

enum ClaudeCredentialHelper {
    private static let executableName = "AgentUsageClaudeHelper"
    private static let timeout: TimeInterval = 12

    /// With `includePlan`, the helper also reads the live OAuth profile.
    static func fetch(includePlan: Bool) async throws -> ClaudeHelperResponse {
        let executable = try bundledExecutable()
        return try await Task.detached(priority: .utility) {
            try run(executable: executable, arguments: includePlan ? ["--plan"] : [])
        }.value
    }

    /// The helper writes one JSON header line, then the raw usage response body.
    static func parse(_ output: Data) throws -> ClaudeHelperResponse {
        struct Header: Decodable {
            var status: Int
            var retryAfter: String?
            var subscriptionType: String?
            var rateLimitTier: String?
        }
        guard let newline = output.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: output[..<newline])
        else {
            throw FetchError.parseFailed(
                "invalid Claude credential helper response framing")
        }
        return ClaudeHelperResponse(
            statusCode: header.status,
            retryAfter: header.retryAfter,
            subscriptionType: header.subscriptionType,
            rateLimitTier: header.rateLimitTier,
            body: Data(output[output.index(after: newline)...]))
    }

    private static func bundledExecutable() throws -> URL {
        // The helper delegates Keychain access to /usr/bin/security, so it no
        // longer needs a preserved on-disk identity. Always use the bundled
        // copy to prevent an older helper from surviving an app update.
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(executableName),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        else {
            throw FetchError.launchFailed(
                "bundled Claude credential helper is missing")
        }
        return bundled
    }

    private static func run(executable: URL, arguments: [String]) throws -> ClaudeHelperResponse {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
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

        let timedOut = IsolatedProcess.terminate(process, after: timeout)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if timedOut() {
            throw FetchError.timeout("Claude credential helper")
        }
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
