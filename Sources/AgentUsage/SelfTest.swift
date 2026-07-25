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
        try testClaudeOAuthCredentialParserReadsClaudeCodeShape()
        try testDurationLabelsAndCodexWindowClassification()
        try testCodexAccountUsageParsingAndFormatting()
        try testPreferredAxisMaximums()
        try testMenuProviderSelectionFollowsSingleTrackedProvider()
        try testUpdateActionTitles()
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

    private static func testClaudeOAuthCredentialParserReadsClaudeCodeShape() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","expiresAt":1800000000000,"subscriptionType":"pro"}}"#.utf8)
        let credentials = ClaudeOAuthCredentialReader.parse(data)

        try expect(credentials?.accessToken == "token", "expected Claude OAuth access token")
        try expect(credentials?.subscriptionType == "pro", "expected Claude OAuth subscription type")
        try expect(
            credentials?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000),
            "expected millisecond OAuth expiration")
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
            MenuProviderSelection.combined.constrained(to: [.codex]) == .codex,
            "expected Both to become Codex when only Codex is tracked")
        try expect(
            MenuProviderSelection.combined.constrained(to: [.claude]) == .claude,
            "expected Both to become Claude when only Claude is tracked")
        try expect(
            MenuProviderSelection.combined.constrained(to: [.codex, .claude]) == .combined,
            "expected Both to remain available when both providers are tracked")
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
