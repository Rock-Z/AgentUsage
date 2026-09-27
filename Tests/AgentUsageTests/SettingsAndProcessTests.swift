import Foundation
import Testing
@testable import AgentUsage

struct SettingsTests {
    @Test func menuProviderFollowsTrackedProviders() {
        #expect(!MenuProviderSelection.combined.isAvailable(with: [.codex]))
        #expect(MenuProviderSelection.combined.constrained(to: [.codex]) == .codex)
        #expect(MenuProviderSelection.combined.constrained(to: [.claude]) == .claude)
        #expect(MenuProviderSelection.combined.constrained(to: [.codex, .claude]) == .combined)
    }

    @Test func providersToggleIndependentlyButNeverAllOff() {
        #expect(MenuProviderSelection.combined.setting(.claude, false) == .codex)
        #expect(MenuProviderSelection.codex.setting(.claude, true) == .combined)
        #expect(MenuProviderSelection.codex.setting(.codex, true) == .codex)
        #expect(MenuProviderSelection.codex.setting(.codex, false) == nil, "the last provider stays on")
    }

    @Test func firstLaunchFollowsAvailableProvidersOnce() throws {
        let suiteName = "AgentUsageTests.FirstLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FirstLaunchSettings.applyIfNeeded(defaults: defaults, availableProviders: [.claude], hasLaunchedBefore: false)
        #expect(!defaults.bool(forKey: "trackCodex"))
        #expect(defaults.bool(forKey: "trackClaude"))
        #expect(defaults.string(forKey: "menuProvider") == MenuProviderSelection.claude.rawValue)

        FirstLaunchSettings.applyIfNeeded(defaults: defaults, availableProviders: [.codex], hasLaunchedBefore: false)
        #expect(defaults.string(forKey: "menuProvider") == MenuProviderSelection.claude.rawValue, "applies only once")
    }

    @Test func firstLaunchLeavesExistingUsersAlone() throws {
        let suiteName = "AgentUsageTests.ExistingUser.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MenuMetric.credits.rawValue, forKey: "menuMetric")

        FirstLaunchSettings.applyIfNeeded(defaults: defaults, availableProviders: [.claude], hasLaunchedBefore: true)
        #expect(defaults.string(forKey: "menuMetric") == MenuMetric.credits.rawValue)
    }

    @Test func chartPositionsDefaultToLatestAndPersistPerPeriod() throws {
        let suiteName = "AgentUsageTests.ChartPosition.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = ChartPositionPersistence(defaults: defaults)
        let dates = [100.0, 200, 300].map(Date.init(timeIntervalSince1970:))

        #expect(persistence.restoredPosition(for: "daily", availableDates: dates) == dates[2])
        persistence.save(dates[1], for: "daily")
        #expect(ChartPositionPersistence(defaults: defaults).restoredPosition(for: "daily", availableDates: dates) == dates[1])
        #expect(persistence.restoredPosition(for: "weekly", availableDates: dates) == dates[2])
    }
}

struct ClaudeOAuthRefreshTests {
    @Test func environmentIsIsolated() {
        let directory = URL(fileURLWithPath: "/tmp/AgentUsage-ClaudeOAuthRefresh")
        let environment = ClaudeOAuthRefreshEnvironment.make(
            [
                "PATH": "/usr/bin",
                "PWD": "/private/project",
                "OLDPWD": "/private",
                "ANTHROPIC_API_KEY": "must-not-leak",
                "SAFE_VALUE": "preserved",
            ],
            workingDirectory: directory)

        #expect(environment["PWD"] == directory.path)
        #expect(environment["OLDPWD"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil, "inherited Anthropic credentials are ignored")
        #expect(environment["CLAUDE_CODE_SAFE_MODE"] == "1", "project customizations are disabled")
        #expect(environment["SAFE_VALUE"] == "preserved")
    }

    @Test func sendsStatusOverPseudoTerminal() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AgentUsageTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("status-ran")
        let executable = directory.appendingPathComponent("claude")
        try Data("""
            #!/bin/sh
            IFS= read -r command
            if [ "$command" = "/status" ]; then
              printf refreshed > "$AGENTUSAGE_TEST_MARKER"
              exit 0
            fi
            exit 1
            """.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let succeeded = await ClaudeOAuthRefreshCoordinator().refresh(environment: [
            "HOME": NSHomeDirectory(),
            "PATH": directory.path,
            "AGENTUSAGE_TEST_MARKER": marker.path,
        ])
        #expect(succeeded)
        #expect((try? String(contentsOf: marker, encoding: .utf8)) == "refreshed")
    }
}
