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
        try testMenuTitleShowsSelectedFiveHourUsedPercent()
        try testMenuTitleShowsSelectedCodexCredits()
        try testMenuTitleShowsCombinedClaudeBillingDollars()
        try testMenuTitleFallsBackToDollarsWhenWindowMissing()
        try testClaudeUsageParserReadsSessionAndWeeklyPercentLeft()
        try testClaudeUsageParserReadsLocalTotalCost()
        try testDurationLabelsAndCodexWindowClassification()
        try testCodexAccountUsageParsingAndFormatting()
        try testPartialDualLimitFormatting()
        try testCostScannerOnlyCountsCurrentBillingPeriodExplicitCosts()
        try testResetCreditSummaryAndExpirationHelp()
        try testMenuBarStatusImagesRenderVisiblePixels()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.expectation(message) }
    }

    private static func testMenuTitleShowsSelectedFiveHourUsedPercent() throws {
        let states: [Provider: ProviderState] = [
            .codex: ProviderState(snapshot: UsageSnapshot(
                provider: .codex,
                fiveHour: RateWindow(usedPercent: 41.6, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                sevenDay: nil,
                billingCost: nil,
                localUsageCost: nil,
                accountEmail: nil,
                plan: nil,
                source: "test",
                updatedAt: Date())),
        ]

        let title = DisplayFormatter.menuTitle(
            states: states,
            providerSelection: .codex,
            metric: .fiveHourPercent,
            showUsed: false)

        try expect(title == "Codex 58%", "expected Codex 58%, got \(title)")
    }

    private static func testMenuTitleShowsSelectedCodexCredits() throws {
        let states: [Provider: ProviderState] = [
            .codex: ProviderState(snapshot: UsageSnapshot(
                provider: .codex,
                fiveHour: nil,
                sevenDay: nil,
                credits: CreditSnapshot(balance: 1492.8456, hasCredits: true, unlimited: false),
                billingCost: nil,
                localUsageCost: nil,
                accountEmail: nil,
                plan: nil,
                source: "test",
                updatedAt: Date())),
        ]

        let title = DisplayFormatter.menuTitle(
            states: states,
            providerSelection: .codex,
            metric: .billingDollars,
            showUsed: true)

        try expect(title == "Codex 1,493", "expected Codex credits, got \(title)")
    }

    private static func testMenuTitleShowsCombinedClaudeBillingDollars() throws {
        let start = Date()
        let states: [Provider: ProviderState] = [
            .codex: ProviderState(snapshot: UsageSnapshot(
                provider: .codex,
                fiveHour: nil,
                sevenDay: nil,
                credits: CreditSnapshot(balance: 1492.8456, hasCredits: true, unlimited: false),
                billingCost: nil,
                localUsageCost: nil,
                accountEmail: nil,
                plan: nil,
                source: "test",
                updatedAt: Date())),
            .claude: ProviderState(snapshot: snapshot(provider: .claude, dollars: 3.5, since: start)),
        ]

        let title = DisplayFormatter.menuTitle(
            states: states,
            providerSelection: .combined,
            metric: .billingDollars,
            showUsed: true)

        try expect(title == "AI $3.50", "expected AI $3.50, got \(title)")
    }

    private static func testMenuTitleFallsBackToDollarsWhenWindowMissing() throws {
        let states: [Provider: ProviderState] = [
            .claude: ProviderState(snapshot: UsageSnapshot(
                provider: .claude,
                fiveHour: nil,
                sevenDay: nil,
                billingCost: nil,
                localUsageCost: CostSnapshot(dollars: 12.34, since: Date(), updatedAt: Date(), scannedFiles: 0),
                accountEmail: nil,
                plan: "Claude Enterprise",
                source: "test",
                updatedAt: Date())),
        ]

        let title = DisplayFormatter.menuTitle(
            states: states,
            providerSelection: .claude,
            metric: .fiveHourPercent,
            showUsed: true)

        try expect(title == "Claude Code $12.34", "expected Claude dollar fallback, got \(title)")
    }

    private static func testClaudeUsageParserReadsSessionAndWeeklyPercentLeft() throws {
        let output = """
        Settings: Usage

        Current session
        72% left
        Resets at 4:00PM (America/Los_Angeles)

        Current week (all models)
        38% remaining
        Resets Jun 10 at 9:00AM (America/Los_Angeles)
        """

        let parsed = try ClaudeUsageParser.parse(
            usageText: output,
            statusText: "Account: person@example.com\nClaude Max")

        try expect(parsed.fiveHour?.usedPercent == 28, "expected 28% used for Claude 5h")
        try expect(parsed.sevenDay?.usedPercent == 62, "expected 62% used for Claude 7d")
        try expect(parsed.accountEmail == "person@example.com", "expected Claude email")
        try expect(parsed.plan == "Claude Max", "expected Claude plan")
        try expect(parsed.fiveHour?.windowMinutes == 300, "expected 5h window")
        try expect(parsed.sevenDay?.windowMinutes == 10_080, "expected 7d window")
    }

    private static func testClaudeUsageParserReadsLocalTotalCost() throws {
        let output = """
        Settings Status Config Usage Stats

        Session
        Total cost: $7.89
        Total duration (API): 1m
        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine
        """

        let parsed = try ClaudeUsageParser.parse(usageText: output)

        try expect(parsed.fiveHour == nil, "expected no Claude 5h window")
        try expect(parsed.sevenDay == nil, "expected no Claude 7d window")
        try expect(parsed.localUsageDollars == 7.89, "expected Claude local cost")
        try expect(parsed.plan == "Claude local usage", "expected local usage plan marker")
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
        try expect(
            DisplayFormatter.duration(seconds: activity.longestRunningTurnSec) == "13h 17m",
            "expected 13h 17m")
        try expect(DisplayFormatter.roundedAxisMaximum(6_559_374_729) == 10_000_000_000, "expected 10B axis")
        try expect(DisplayFormatter.roundedAxisMaximum(24_670_581_944) == 25_000_000_000, "expected 25B axis")
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
            metric: .bothPercent,
            showUsed: false)
        try expect(text == "7d: 97%", "expected weekly-only dual text, got \(text ?? "nil")")
    }

    private static func testCostScannerOnlyCountsCurrentBillingPeriodExplicitCosts() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = temp.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let file = sessions.appendingPathComponent("usage.jsonl")
        let body = """
        {"timestamp":"2026-05-31T23:59:00Z","cost_usd":99}
        {"timestamp":"2026-06-01T08:01:00Z","cost_usd":1.25}
        {"timestamp":"2026-06-08T12:00:00Z","usage":{"total_cost_usd":2.50}}
        """
        try body.write(to: file, atomically: true, encoding: .utf8)

        let scanner = CostUsageScanner(
            provider: .codex,
            environment: ["HOME": temp.path],
            now: ISO8601DateFormatter().date(from: "2026-06-08T19:00:00Z")!)

        let scanned = try scanner.scanCurrentBillingPeriod()

        try expect(abs(scanned.dollars - 3.75) < 0.0001, "expected $3.75, got \(scanned.dollars)")
        try expect(scanned.scannedFiles == 1, "expected one scanned file")
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

    private static func snapshot(provider: Provider, dollars: Double, since: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            fiveHour: nil,
            sevenDay: nil,
            billingCost: CostSnapshot(dollars: dollars, since: since, updatedAt: Date(), scannedFiles: 0),
            localUsageCost: nil,
            accountEmail: nil,
            plan: nil,
            source: "test",
            updatedAt: Date())
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
