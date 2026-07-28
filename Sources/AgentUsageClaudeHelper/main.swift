import Foundation

private let keychainService = "Claude Code-credentials"
private let keychainReadTimeout: TimeInterval = 5
private let usageEndpoint =
    URL(string: "https://api.anthropic.com/api/oauth/usage")!

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

private struct Credential {
    var accessToken: String
    var subscriptionType: String?
}

private func keychainData() -> Data {
    let process = Process()
    let stdout = Pipe()
    // Claude Code stores and refreshes this item through the system security
    // tool. Use that same stable, Apple-signed reader so a credential rewrite
    // cannot invalidate access based on this helper's changing code identity.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
        "find-generic-password",
        "-a", NSUserName(),
        "-s", keychainService,
        "-w",
    ]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        fail(
            "Claude credential is unavailable "
                + "(could not launch macOS Keychain access).")
    }

    let deadline = Date().addingTimeInterval(keychainReadTimeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        fail("Claude credential is unavailable (Keychain access timed out).")
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0, !data.isEmpty else {
        fail(
            "Claude credential is unavailable "
                + "(macOS Keychain access failed).")
    }
    return data
}

private func credential() -> Credential {
    let data = keychainData()
    guard
        let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
        let oauth = root["claudeAiOauth"] as? [String: Any],
        let accessToken = oauth["accessToken"] as? String,
        !accessToken.isEmpty
    else {
        fail("Claude credential does not contain an OAuth access token.")
    }
    let subscriptionType = (oauth["subscriptionType"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return Credential(
        accessToken: accessToken,
        subscriptionType: subscriptionType?.isEmpty == false
            ? subscriptionType
            : nil)
}

private func run() async {
    let credential = credential()
    var request = URLRequest(url: usageEndpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 8
    request.setValue(
        "Bearer \(credential.accessToken)",
        forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
        "oauth-2025-04-20",
        forHTTPHeaderField: "anthropic-beta")
    request.setValue(
        "claude-code/2.1.0",
        forHTTPHeaderField: "User-Agent")

    do {
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            fail("Claude usage request returned no HTTP response.")
        }
        let retryAfter =
            response.value(forHTTPHeaderField: "Retry-After") ?? ""
        let header = "\(response.statusCode)\n\(retryAfter)\n"
            + "\(credential.subscriptionType ?? "")\n"
        FileHandle.standardOutput.write(
            Data(header.utf8))
        FileHandle.standardOutput.write(body)
    } catch {
        fail("Claude usage request failed: \(error.localizedDescription)")
    }
}

await run()
