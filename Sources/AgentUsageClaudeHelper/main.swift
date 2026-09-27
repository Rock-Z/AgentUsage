import Foundation

private let keychainService = "Claude Code-credentials"
private let keychainReadTimeout: TimeInterval = 5
private let usageEndpoint =
    URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let profileEndpoint =
    URL(string: "https://api.anthropic.com/api/oauth/profile")!

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

/// Written as the first output line; the raw usage body follows it.
private struct Header: Encodable {
    var status: Int
    var retryAfter: String?
    var subscriptionType: String?
    var rateLimitTier: String?
}

private func livePlan(accessToken: String) async -> (subscriptionType: String, rateLimitTier: String?)? {
    var request = URLRequest(url: profileEndpoint)
    request.timeoutInterval = 4
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let organization = root["organization"] as? [String: Any],
          let type = organization["organization_type"] as? String,
          !type.isEmpty
    else { return nil }
    // Take both fields from the same live profile; never pair a new plan with
    // an old cached tier after an upgrade or downgrade.
    return (
        type.hasPrefix("claude_") ? String(type.dropFirst(7)) : type,
        organization["rate_limit_tier"] as? String)
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

    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + keychainReadTimeout, execute: timeout)
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    if process.terminationReason == .uncaughtSignal {
        fail("Claude credential is unavailable (Keychain access timed out).")
    }
    guard process.terminationStatus == 0, !data.isEmpty else {
        fail(
            "Claude credential is unavailable "
                + "(macOS Keychain access failed).")
    }
    return data
}

private func accessToken() -> String {
    guard
        let root = try? JSONSerialization.jsonObject(with: keychainData())
            as? [String: Any],
        let oauth = root["claudeAiOauth"] as? [String: Any],
        let accessToken = oauth["accessToken"] as? String,
        !accessToken.isEmpty
    else {
        fail("Claude credential does not contain an OAuth access token.")
    }
    return accessToken
}

private func run() async {
    let token = accessToken()
    let includePlan = CommandLine.arguments.contains("--plan")
    // Fetch concurrently so profile availability does not delay usage by the
    // sum of both request timeouts. Profile failures must not hide usage.
    async let profile = includePlan ? livePlan(accessToken: token) : nil
    var request = URLRequest(url: usageEndpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 8
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

    do {
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            fail("Claude usage request returned no HTTP response.")
        }
        let plan = await profile
        let header = Header(
            status: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            subscriptionType: plan?.subscriptionType,
            rateLimitTier: plan?.rateLimitTier)
        FileHandle.standardOutput.write(try JSONEncoder().encode(header) + Data([0x0A]))
        FileHandle.standardOutput.write(body)
    } catch {
        fail("Claude usage request failed: \(error.localizedDescription)")
    }
}

await run()
