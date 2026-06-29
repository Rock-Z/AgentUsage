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
