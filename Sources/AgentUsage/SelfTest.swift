import Foundation
import AppKit

enum SelfTest {
    enum Failure: Error, CustomStringConvertible {
        case expectation(String)

        var description: String {
            switch self {
            case let .expectation(message): message
            }
        }
    }

    static func run() throws {
        try testCreditFormatting()
        try testClaudeOAuthUsageParserReadsWindows()
        try testClaudeCredentialHelperFraming()
        try testClaudeOAuthRefreshPolicyIsExact()
        try testClaudeOAuthRefreshEnvironmentIsIsolated()
        try testClaudeOAuthDelegatedRefreshRetriesOnce()
        try testClaudeOAuthRefreshPTYUsesStatus()
        try testDurationLabelsAndCodexWindowClassification()
        try testCodexAccountUsageParsingAndFormatting()
        try testPreferredAxisMaximums()
        try testMenuProviderSelectionFollowsSingleTrackedProvider()
        try testMenuMetricLabelsAreProviderIndependent()
        try testFirstLaunchSettingsFollowAvailableProviders()
        try testChartPositionsDefaultLatestAndPersistIndependently()
        try testUpdateActionTitles()
        try testLaunchAtLoginControllerTracksServiceAndErrors()
        try testCredentialRepairTriggersAreExact()
        try testWeeklyActivityUsesMondayThroughSundayBuckets()
        try testPartialDualLimitFormatting()
        try testResetCreditSummaryAndExpirationHelp()
        try testMenuBarStatusImagesRenderVisiblePixels()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.expectation(message) }
    }

    private static func testClaudeOAuthUsageParserReadsWindows() throws {
        let data = Data(#"{"five_hour":{"utilization":28.5,"resets_at":"2026-07-21T21:20:00Z"},"seven_day":{"utilization":62,"resets_at":"2026-07-28T18:00:00Z"},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":3750,"utilization":37.5,"currency":"USD"}}"#.utf8)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try ClaudeOAuthUsageFetcher.snapshot(
            from: data,
            subscriptionType: "max",
            updatedAt: updatedAt)

        try expect(snapshot.fiveHour?.usedPercent == 28.5, "expected OAuth 5h utilization")
        try expect(snapshot.sevenDay?.usedPercent == 62, "expected OAuth 7d utilization")
        try expect(snapshot.fiveHour?.resetsAt != nil, "expected OAuth 5h reset")
        try expect(snapshot.sevenDay?.resetsAt != nil, "expected OAuth 7d reset")
        try expect(snapshot.plan == "Claude Max", "expected OAuth subscription plan")
        try expect(snapshot.credits?.balance == 62.5, "expected remaining OAuth extra-usage credits")
        try expect(snapshot.credits?.currencyCode == "USD", "expected OAuth credit currency")
        try expect(DisplayFormatter.amountText(snapshot) == "$62.50", "expected formatted OAuth credit balance")
        try expect(snapshot.source == "claude oauth", "expected OAuth source label")
        try expect(snapshot.updatedAt == updatedAt, "expected supplied OAuth update time")
    }

    private static func testClaudeCredentialHelperFraming() throws {
        let body = Data(#"{"five_hour":{"utilization":12.5}}"#.utf8)
        var output = Data("200\n120\npro\n".utf8)
        output.append(body)
        let response = try ClaudeCredentialHelper.parse(output)

        try expect(response.statusCode == 200, "expected helper HTTP status")
        try expect(response.retryAfter == "120", "expected helper retry header")
        try expect(
            response.subscriptionType == "pro",
            "expected helper subscription type")
        try expect(response.body == body, "expected helper body bytes to remain unchanged")
    }

    private static func testClaudeOAuthRefreshPolicyIsExact() throws {
        try expect(
            ClaudeOAuthRefreshPolicy.shouldAttempt(
                statusCode: 401,
                alreadyAttempted: false),
            "expected first OAuth 401 to trigger delegated refresh")
        try expect(
            !ClaudeOAuthRefreshPolicy.shouldAttempt(
                statusCode: 401,
                alreadyAttempted: true),
            "expected OAuth refresh to run at most once")
        try expect(
            !ClaudeOAuthRefreshPolicy.shouldAttempt(
                statusCode: 429,
                alreadyAttempted: false),
            "expected rate limiting not to trigger OAuth refresh")
    }

    private static func testClaudeOAuthRefreshEnvironmentIsIsolated() throws {
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

        try expect(
            environment["PWD"] == directory.path,
            "expected Claude refresh PWD to use its isolated directory")
        try expect(
            environment["OLDPWD"] == nil,
            "expected Claude refresh to remove OLDPWD")
        try expect(
            environment["ANTHROPIC_API_KEY"] == nil,
            "expected Claude refresh to ignore inherited Anthropic credentials")
        try expect(
            environment["CLAUDE_CODE_SAFE_MODE"] == "1",
            "expected Claude refresh to disable project customizations")
        try expect(
            environment["SAFE_VALUE"] == "preserved",
            "expected unrelated environment values to remain")
    }

    private static func testClaudeOAuthDelegatedRefreshRetriesOnce() throws {
        try awaitTest {
            let state = ClaudeOAuthRefreshTestState()
            let initial = ClaudeHelperResponse(
                statusCode: 401,
                retryAfter: nil,
                subscriptionType: nil,
                body: Data())
            let response = try await ClaudeOAuthUsageFetcher
                .responseAfterDelegatedRefreshIfNeeded(
                    initial,
                    refresh: {
                        await state.recordRefresh()
                        return true
                    },
                    retry: {
                        await state.recordRetry()
                        return ClaudeHelperResponse(
                            statusCode: 200,
                            retryAfter: nil,
                            subscriptionType: "pro",
                            body: Data(#"{"five_hour":{"utilization":10}}"#.utf8))
                    })

            try expect(
                response.statusCode == 200,
                "expected a successful response after delegated refresh")
            let counts = await state.counts()
            try expect(counts.refresh == 1, "expected one delegated refresh")
            try expect(counts.retry == 1, "expected one usage retry")
        }
    }

    private static func testClaudeOAuthRefreshPTYUsesStatus() throws {
        try awaitTest {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "AgentUsage-ClaudeOAuthRefreshTest-\(UUID().uuidString)",
                    isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            let marker = directory.appendingPathComponent("status-ran")
            let executable = directory.appendingPathComponent("claude")
            let script = """
            #!/bin/sh
            IFS= read -r command
            if [ "$command" = "/status" ]; then
              printf refreshed > "$AGENTUSAGE_TEST_MARKER"
              exit 0
            fi
            exit 1
            """
            try Data(script.utf8).write(to: executable)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path)

            let coordinator = ClaudeOAuthRefreshCoordinator()
            let succeeded = await coordinator.refresh(
                environment: [
                    "HOME": NSHomeDirectory(),
                    "PATH": directory.path,
                    "AGENTUSAGE_TEST_MARKER": marker.path,
                ])
            try expect(succeeded, "expected fake Claude /status touch to succeed")
            try expect(
                (try? String(contentsOf: marker, encoding: .utf8)) == "refreshed",
                "expected delegated refresh to send /status over its PTY")
        }
    }

    private static func awaitTest(
        _ operation: @escaping @Sendable () async throws -> Void
    ) throws {
        let result = SelfTestResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await operation()
                result.set(.success(()))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get().get()
    }

    private static func testDurationLabelsAndCodexWindowClassification() throws {
        try expect(RateWindow.durationLabel(minutes: 300) == "5h", "expected 300 minutes to display as 5h")
        try expect(RateWindow.durationLabel(minutes: 10_080) == "7d", "expected 10080 minutes to display as 7d")
        try expect(RateWindow.durationLabel(minutes: 90) == "1h 30m", "expected mixed duration label")

        let weekly = RateWindow(
            usedPercent: 3,
            windowMinutes: 10_080,
            resetsAt: nil,
            resetDescription: nil)
        let weeklyOnly = CodexUsageFetcher.classifyWindows([weekly])
        try expect(weeklyOnly.short == nil, "expected no short window for a weekly-only response")
        try expect(weeklyOnly.long == weekly, "expected the weekly-only response in the long slot")

        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 360,
            resetsAt: nil,
            resetDescription: nil)
        let both = CodexUsageFetcher.classifyWindows([weekly, session])
        try expect(both.short == session, "expected shorter duration first regardless of backend order")
        try expect(both.long == weekly, "expected longer duration second regardless of backend order")
    }

    private static func testCodexAccountUsageParsingAndFormatting() throws {
        let body = """
        {
          "summary": {
            "lifetimeTokens": 24670581944,
            "peakDailyTokens": 1954897499,
            "longestRunningTurnSec": 47828,
            "currentStreakDays": 15,
            "longestStreakDays": 38
          },
          "dailyUsageBuckets": [
            {"startDate": "2026-07-19", "tokens": 726133164},
            {"startDate": "2026-07-20", "tokens": 198515919}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            CodexAccountUsageResponse.self,
            from: Data(body.utf8))
        let activity = decoded.snapshot

        try expect(activity.lifetimeTokens == 24_670_581_944, "expected lifetime token total")
        try expect(activity.dailyUsage.count == 2, "expected two daily usage buckets")
        try expect(activity.dailyUsage.last?.date != nil, "expected activity date parsing")
        try expect(DisplayFormatter.compactTokens(activity.lifetimeTokens) == "24.7B", "expected 24.7B")
        try expect(DisplayFormatter.compactTokens(activity.peakDailyTokens) == "1.95B", "expected 1.95B")
        try expect(DisplayFormatter.compactTokens(6_559_374_729) == "6.56B", "expected three significant figures")
        try expect(DisplayFormatter.compactTokens(637_697_578) == "638M", "expected rounded megatokens")
        try expect(DisplayFormatter.compactAxisTokens(900_000_000) == "0.9B", "expected promoted billion axis label")
        try expect(DisplayFormatter.compactAxisTokens(900_000) == "0.9M", "expected promoted million axis label")
        try expect(DisplayFormatter.compactAxisTokens(900) == "0.9K", "expected promoted thousand axis label")
        try expect(DisplayFormatter.compactAxisTokens(90_000_000) == "90M", "expected ordinary million axis label")
        try expect(
            DisplayFormatter.duration(seconds: activity.longestRunningTurnSec) == "13h 17m",
            "expected 13h 17m")
    }

    private static func testPreferredAxisMaximums() throws {
        try expect(DisplayFormatter.roundedAxisMaximum(1_100_000) == 1_500_000, "expected 1.5M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(2_100_000) == 2_500_000, "expected 2.5M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(5_300_000) == 6_000_000, "expected 6M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(6_400_000) == 8_000_000, "expected 8M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(8_000_000) == 10_000_000, "expected 10M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(9_900_000) == 10_000_000, "expected capped 10M axis")
        try expect(DisplayFormatter.roundedAxisMaximum(24_670_581_944) == 30_000_000_000, "expected 30B axis")
    }

    private static func testMenuProviderSelectionFollowsSingleTrackedProvider() throws {
        try expect(
            !MenuProviderSelection.combined.isAvailable(with: [.codex]),
            "expected Both to be unavailable when Claude is not tracked")
        try expect(
            !MenuProviderSelection.combined.isAvailable(with: [.claude]),
            "expected Both to be unavailable when Codex is not tracked")
        try expect(
            MenuProviderSelection.combined.isAvailable(with: [.codex, .claude]),
            "expected Both to be available when both providers are tracked")
        try expect(
            MenuProviderSelection.combined.constrained(to: [.codex]) == .codex,
            "expected Both to become Codex when only Codex is tracked")
        try expect(
            MenuProviderSelection.combined.constrained(to: [.claude]) == .claude,
            "expected Both to become Claude when only Claude is tracked")
        try expect(
            MenuProviderSelection.combined.constrained(to: [.codex, .claude]) == .combined,
            "expected Both to remain available when both providers are tracked")
    }

    private static func testMenuMetricLabelsAreProviderIndependent() throws {
        try expect(MenuMetric.fiveHourPercent.label == "5h%", "expected fixed 5h metric label")
        try expect(MenuMetric.sevenDayPercent.label == "7d%", "expected fixed 7d metric label")
        try expect(MenuMetric.bothPercent.label == "All limits", "expected fixed all-limits label")
        try expect(MenuMetric.billingDollars.label == "Billing $", "expected fixed billing label")
    }

    private static func testFirstLaunchSettingsFollowAvailableProviders() throws {
        let suiteName = "AgentUsage.SelfTest.FirstLaunch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure.expectation("expected isolated first-launch defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FirstLaunchSettings.applyIfNeeded(
            defaults: defaults,
            availableProviders: [.claude],
            hasLaunchedBefore: false)
        try expect(!defaults.bool(forKey: "trackCodex"), "expected unavailable Codex off")
        try expect(defaults.bool(forKey: "trackClaude"), "expected available Claude on")
        try expect(
            defaults.string(forKey: "menuProvider")
                == MenuProviderSelection.claude.rawValue,
            "expected Claude menu default")
        try expect(
            defaults.string(forKey: "menuMetric")
                == MenuMetric.bothPercent.rawValue,
            "expected all-limits metric default")
        try expect(
            defaults.string(forKey: "menuDisplayMode")
                == MenuDisplayMode.ringAndPercentage.rawValue,
            "expected ring and percentage default")

        FirstLaunchSettings.applyIfNeeded(
            defaults: defaults,
            availableProviders: [.codex],
            hasLaunchedBefore: false)
        try expect(
            defaults.string(forKey: "menuProvider")
                == MenuProviderSelection.claude.rawValue,
            "expected first-launch settings to apply only once")

        let existingSuiteName =
            "AgentUsage.SelfTest.ExistingSettings.\(UUID().uuidString)"
        guard let existingDefaults = UserDefaults(suiteName: existingSuiteName) else {
            throw Failure.expectation("expected isolated existing-user defaults")
        }
        defer {
            existingDefaults.removePersistentDomain(forName: existingSuiteName)
        }
        existingDefaults.set(
            MenuMetric.fiveHourPercent.rawValue,
            forKey: "menuMetric")
        FirstLaunchSettings.applyIfNeeded(
            defaults: existingDefaults,
            availableProviders: [.claude],
            hasLaunchedBefore: true)
        try expect(
            existingDefaults.string(forKey: "menuMetric")
                == MenuMetric.fiveHourPercent.rawValue,
            "expected existing user settings to remain unchanged")
    }

    private static func testChartPositionsDefaultLatestAndPersistIndependently() throws {
        let suiteName = "AgentUsage.SelfTest.ChartPosition.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure.expectation("expected isolated chart-position defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = ChartPositionPersistence(
            defaults: defaults,
            keyPrefix: "testChartPosition")
        let dates = [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 300),
        ]
        try expect(
            persistence.restoredPosition(for: "daily", availableDates: dates)
                == dates[2],
            "expected a new chart to end on its latest period")

        persistence.save(dates[1], for: "daily")
        try expect(
            ChartPositionPersistence(
                defaults: defaults,
                keyPrefix: "testChartPosition")
                .restoredPosition(for: "daily", availableDates: dates)
                == dates[1],
            "expected daily position to persist across chart instances")
        try expect(
            persistence.restoredPosition(for: "weekly", availableDates: dates)
                == dates[2],
            "expected weekly position to remain independently latest")
    }

    private static func testUpdateActionTitles() throws {
        try expect(
            UpdateController.actionTitle(readyVersion: nil) == "Check for Updates",
            "expected default update action")
        try expect(
            UpdateController.actionTitle(readyVersion: "0.4.2")
                == "Update v0.4.2 Ready - Install",
            "expected ready update action")
    }

    private static func testLaunchAtLoginControllerTracksServiceAndErrors() throws {
        let service = LaunchAtLoginTestService()
        let controller = LaunchAtLoginController(service: service)

        try expect(
            !controller.isEnabled,
            "expected launch at login to start disabled")
        controller.setEnabled(true)
        try expect(
            controller.isEnabled && service.setValues == [true],
            "expected launch at login to enable through the service")

        service.error = LaunchAtLoginTestError.denied
        controller.setEnabled(false)
        try expect(
            controller.isEnabled,
            "expected failed disable to preserve service state")
        try expect(
            controller.errorMessage == "Login item change denied.",
            "expected launch at login error to remain visible")
    }

    private static func testCredentialRepairTriggersAreExact() throws {
        let initialize = FetchError.timeout("initialize")
        let otherTimeout = FetchError.timeout("account/rateLimits/read")
        let broadCredentialText = FetchError.malformed(
            "some unrelated credential warning")

        try expect(
            CodexCredentialRepairTrigger.matches(error: initialize),
            "expected the exact Codex initialize timeout to trigger repair")
        try expect(
            !CodexCredentialRepairTrigger.matches(error: otherTimeout),
            "expected another Codex timeout to remain untouched")
        try expect(
            !CodexCredentialRepairTrigger.matches(error: broadCredentialText),
            "expected broad credential text not to trigger repair")
    }

    private static func testWeeklyActivityUsesMondayThroughSundayBuckets() throws {
        let days = [
            TokenUsageDay(startDate: "2026-07-19", tokens: 10),
            TokenUsageDay(startDate: "2026-07-20", tokens: 20),
            TokenUsageDay(startDate: "2026-07-21", tokens: 30),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let buckets = TokenWeekBucket.calendarWeeks(
            from: days,
            calendar: calendar,
            minimumCount: 1)

        try expect(buckets.count == 2, "expected two calendar-week buckets")
        try expect(buckets[0].tokens == 10, "expected Sunday in the prior week")
        try expect(buckets[1].tokens == 50, "expected Monday and Tuesday in the current week")
        try expect(
            calendar.component(.weekday, from: buckets[1].startDate) == 2,
            "expected the current bucket to start Monday")
        try expect(
            calendar.component(.weekday, from: buckets[1].endDate) == 3,
            "expected the partial current bucket to end Tuesday")
    }

    private static func testPartialDualLimitFormatting() throws {
        let weekly = RateWindow(
            usedPercent: 3,
            windowMinutes: 10_080,
            resetsAt: nil,
            resetDescription: nil)
        let text = DisplayFormatter.menuPercentText(
            window: nil,
            innerWindow: weekly,
            metric: .bothPercent)
        try expect(text == "7d: 97%", "expected weekly-only dual text, got \(text ?? "nil")")
    }

    private static func testResetCreditSummaryAndExpirationHelp() throws {
        let later = Date(timeIntervalSince1970: 3_600)
        let sooner = Date(timeIntervalSince1970: 60)
        let snapshot = ResetCreditSnapshot(
            availableCount: 2,
            credits: [
                ResetCredit(
                    resetType: "codex_rate_limits",
                    status: "available",
                    grantedAt: nil,
                    expiresAt: later,
                    title: "Full reset",
                    description: nil),
                ResetCredit(
                    resetType: "codex_rate_limits",
                    status: "redeemed",
                    grantedAt: nil,
                    expiresAt: Date(timeIntervalSince1970: 10),
                    title: "Redeemed reset",
                    description: nil),
                ResetCredit(
                    resetType: "codex_rate_limits",
                    status: "available",
                    grantedAt: nil,
                    expiresAt: sooner,
                    title: "Full reset",
                    description: nil),
            ])

        let help = DisplayFormatter.resetExpirationHelp(snapshot)
        try expect(DisplayFormatter.resetSummary(snapshot) == "Resets: 2 available", "expected reset summary")
        try expect(
            help == """
            Reset 1: expires \(DisplayFormatter.resetExpirationDate(sooner))
            Reset 2: expires \(DisplayFormatter.resetExpirationDate(later))
            """,
            "expected sorted available reset expirations, got \(help)")
    }

    private static func testMenuBarStatusImagesRenderVisiblePixels() throws {
        let window = RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        try expect(MenuProviderSelection.combined.label == "Both", "expected Both provider label")
        try expect(MenuProviderSelection.claude.label == "Claude", "expected compact Claude provider label")
        for selection in MenuProviderSelection.allCases {
            let image = MenuBarStatusImageRenderer.image(
                selection: selection,
                metric: .fiveHourPercent,
                displayMode: .ring,
                window: window,
                percentText: nil,
                amountText: nil)
            try expect(image.size.width >= 16, "expected status image width")
            try expect(image.size.height >= 16, "expected status image height")
            try expect(Self.visiblePixelCount(in: image) > 8, "expected visible pixels for \(selection)")
        }

        let nestedImage = MenuBarStatusImageRenderer.image(
            selection: .combined,
            metric: .bothPercent,
            displayMode: .ringAndPercentage,
            window: window,
            innerWindow: RateWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil),
            percentText: "5h: 75%\n7d: 30%",
            amountText: nil)
        try expect(nestedImage.size.width > 40, "expected nested status image width")
        try expect(
            nestedImage.size.height >= 18 && nestedImage.size.height <= 20,
            "expected compact nested status image height")
        try expect(Self.visiblePixelCount(in: nestedImage) > 8, "expected visible pixels for nested status image")

        let sideBySideImage = MenuBarStatusImageRenderer.image(
            selection: .combined,
            metric: .fiveHourPercent,
            displayMode: .ringAndPercentage,
            window: window,
            percentText: "75%",
            amountText: nil,
            sideBySideEntries: [
                MenuBarStatusEntry(
                    window: window,
                    innerWindow: nil,
                    percentText: "75%",
                    amountText: nil),
                MenuBarStatusEntry(
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    innerWindow: nil,
                    percentText: "60%",
                    amountText: nil),
            ])
        try expect(sideBySideImage.size.width > 80, "expected two side-by-side provider indicators")
        try expect(Self.visiblePixelCount(in: sideBySideImage) > 16, "expected visible pixels for both providers")

        let percentImage = MenuBarStatusImageRenderer.image(
            selection: .codex,
            metric: .fiveHourPercent,
            displayMode: .percentage,
            window: window,
            percentText: "75%",
            amountText: nil)
        try expect(percentImage.size.width >= 20, "expected percentage status image width")
        try expect(Self.visiblePixelCount(in: percentImage) > 8, "expected visible pixels for percentage status image")

        let weeklyOnlyImage = MenuBarStatusImageRenderer.image(
            selection: .codex,
            metric: .bothPercent,
            displayMode: .ringAndPercentage,
            window: nil,
            innerWindow: RateWindow(usedPercent: 3, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil),
            percentText: "7d: 97%",
            amountText: nil)
        try expect(weeklyOnlyImage.size.width > 40, "expected weekly-only ring and percentage width")
        try expect(Self.visiblePixelCount(in: weeklyOnlyImage) > 8, "expected visible weekly-only status image")
    }

    private static func testCreditFormatting() throws {
        let plainCredits = CreditSnapshot(
            balance: 1492.8456,
            hasCredits: true,
            unlimited: false)
        let dollarCredits = CreditSnapshot(
            balance: 62.5,
            hasCredits: true,
            unlimited: false,
            currencyCode: "USD")
        let unlimited = CreditSnapshot(balance: nil, hasCredits: false, unlimited: true)
        let empty = CreditSnapshot(balance: nil, hasCredits: false, unlimited: false)

        try expect(DisplayFormatter.credits(plainCredits) == "1,493", "expected grouped credit balance")
        try expect(DisplayFormatter.credits(dollarCredits) == "$62.50", "expected USD credit balance")
        try expect(DisplayFormatter.credits(unlimited) == "Unlimited", "expected unlimited credits")
        try expect(DisplayFormatter.credits(empty) == "--", "expected placeholder without credits")
    }

    private static func visiblePixelCount(in image: NSImage) -> Int {
        let width = Int(ceil(image.size.width))
        let height = Int(ceil(image.size.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else {
            return 0
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()

        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 else {
                    continue
                }
                count += 1
            }
        }
        return count
    }
}

private enum LaunchAtLoginTestError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Login item change denied."
    }
}

private final class LaunchAtLoginTestService: LaunchAtLoginManaging {
    var isEnabled = false
    var setValues: [Bool] = []
    var error: Error?

    func setEnabled(_ enabled: Bool) throws {
        setValues.append(enabled)
        if let error { throw error }
        isEnabled = enabled
    }
}

private actor ClaudeOAuthRefreshTestState {
    private var refreshCount = 0
    private var retryCount = 0

    func recordRefresh() {
        refreshCount += 1
    }

    func recordRetry() {
        retryCount += 1
    }

    func counts() -> (refresh: Int, retry: Int) {
        (refreshCount, retryCount)
    }
}

private final class SelfTestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func set(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(
            SelfTest.Failure.expectation("async self-test produced no result"))
    }
}
