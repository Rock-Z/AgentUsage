import AppKit
import Foundation
import Testing
@testable import AgentUsage

struct FormattingTests {
    @Test func durationLabels() {
        #expect(UsageLimit.durationLabel(minutes: 300) == "5h")
        #expect(UsageLimit.durationLabel(minutes: 10_080) == "7d")
        #expect(UsageLimit.durationLabel(minutes: 90) == "1h 30m")
    }

    @Test func compactTokens() {
        #expect(DisplayFormatter.compactTokens(24_670_581_944) == "24.7B")
        #expect(DisplayFormatter.compactTokens(1_954_897_499) == "1.95B")
        #expect(DisplayFormatter.compactTokens(637_697_578) == "638M")
        #expect(DisplayFormatter.compactAxisTokens(900_000_000) == "0.9B", "axis labels promote to the next unit")
        #expect(DisplayFormatter.compactAxisTokens(900) == "0.9K")
        #expect(DisplayFormatter.compactAxisTokens(90_000_000) == "90M")
    }

    @Test(arguments: [
        (Int64(1_100_000), Int64(1_500_000)),
        (2_100_000, 2_500_000),
        (5_300_000, 6_000_000),
        (6_400_000, 8_000_000),
        (8_000_000, 10_000_000),
        (9_900_000, 10_000_000),
        (24_670_581_944, 30_000_000_000),
    ])
    func axisMaximum(value: Int64, expected: Int64) {
        #expect(DisplayFormatter.roundedAxisMaximum(value) == expected)
    }

    @Test func credits() {
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: 1492.8456, unlimited: false)) == "1,493")
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: 62.5, unlimited: false, currencyCode: "USD")) == "$62.50")
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: nil, unlimited: true)) == "Unlimited")
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: nil, unlimited: false)) == "--")
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: 0, unlimited: false)) == "0", "zero still shows")
        #expect(DisplayFormatter.credits(CreditSnapshot(balance: 0, unlimited: false, currencyCode: "USD")) == "$0.00")
    }

    @Test func resetExpirationsListAvailableCreditsSoonestFirst() {
        let later = Date(timeIntervalSince1970: 3_600)
        let sooner = Date(timeIntervalSince1970: 60)
        func credit(_ status: String, _ expiresAt: Date) -> ResetCredit {
            ResetCredit(resetType: nil, status: status, grantedAt: nil, expiresAt: expiresAt, title: nil, description: nil)
        }
        let snapshot = ResetCreditSnapshot(
            availableCount: 2,
            credits: [credit("available", later), credit("redeemed", Date(timeIntervalSince1970: 10)), credit("available", sooner)])

        #expect(DisplayFormatter.resetExpirationHelp(snapshot) == """
            Reset 1: expires \(DisplayFormatter.resetExpirationDate(sooner))
            Reset 2: expires \(DisplayFormatter.resetExpirationDate(later))
            """)
    }

    @Test func weeklyBucketsRunMondayThroughSunday() {
        let days = [
            TokenUsageDay(startDate: "2026-07-19", tokens: 10),
            TokenUsageDay(startDate: "2026-07-20", tokens: 20),
            TokenUsageDay(startDate: "2026-07-21", tokens: 30),
        ]
        let calendar = Calendar(identifier: .gregorian)
        let buckets = TokenWeekBucket.calendarWeeks(from: days, calendar: calendar, minimumCount: 1)

        #expect(buckets.map(\.tokens) == [10, 50], "Sunday belongs to the prior week")
        #expect(calendar.component(.weekday, from: buckets[1].startDate) == 2)
        #expect(calendar.component(.weekday, from: buckets[1].endDate) == 3, "the current week ends today")
    }
}

@MainActor
struct MenuBarTests {
    private let snapshot = UsageSnapshot(
        provider: .claude,
        limits: [
            UsageLimit(id: "session", title: "Session", usedPercent: 25),
            UsageLimit(id: "weekly", title: "Weekly", usedPercent: 60),
            UsageLimit(id: "fable", title: "Weekly Fable", usedPercent: 10, scope: "Fable"),
        ],
        credits: CreditSnapshot(balance: 12, unlimited: false, currencyCode: "USD"),
        updatedAt: Date())

    @Test func limitsShowAccountWideWindowsShortestFirst() {
        let entry = MenuBarStatusEntry(provider: .claude, snapshot: snapshot, metrics: [.limits])
        #expect(entry.limits.map(\.title) == ["Session", "Weekly"], "model-scoped limits stay out of the menu bar")
        #expect(entry.percentText == "Session 75%\nWeekly 40%")
        #expect(entry.amountText == nil)
    }

    @Test func onlyTheLongWindowWhenThereIsNoShortOne() {
        let codex = UsageSnapshot(
            provider: .codex,
            limits: [
                UsageLimit(id: "codex.primary", title: "7d", usedPercent: 3),
                UsageLimit(id: "reserve.primary", title: "7d gpt-reserve", usedPercent: 50, scope: "gpt-reserve"),
            ],
            updatedAt: Date())
        let entry = MenuBarStatusEntry(provider: .codex, snapshot: codex, metrics: [.limits])
        #expect(entry.percentText == "7d 97%")
        #expect(entry.summary == "7d 97% left")
    }

    @Test func limitsAndCreditsAreIndependent() {
        let both = MenuBarStatusEntry(provider: .claude, snapshot: snapshot, metrics: [.limits, .credits])
        #expect(both.limits.count == 2)
        #expect(both.amountText == "$12.00")
        #expect(both.summary == "Session 75% left, Weekly 40% left, $12.00")

        let credits = MenuBarStatusEntry(provider: .claude, snapshot: snapshot, metrics: [.credits])
        #expect(credits.limits.isEmpty)
        #expect(credits.amountText == "$12.00")

        var noLimits = snapshot
        noLimits.limits = []
        #expect(MenuBarStatusEntry(provider: .claude, snapshot: noLimits, metrics: [.limits]).amountText == "$12.00",
                "credits fill in when there are no limits")
    }

    @Test func ringAndPercentageToggleIndependently() {
        #expect(MenuDisplayMode(ring: true, percentage: true) == .ringAndPercentage)
        #expect(MenuDisplayMode(ring: false, percentage: true) == .percentage)
        #expect(MenuDisplayMode(ring: false, percentage: false) == nil, "one of them stays on")
        #expect(MenuDisplayMode.ring.showsRing && !MenuDisplayMode.ring.showsPercentage)
    }

    @Test func storedMetricsFromEarlierVersionsMigrate() {
        #expect(MenuMetric.set(stored: "fiveHourPercent") == [.limits])
        #expect(MenuMetric.set(stored: "bothPercent") == [.limits])
        #expect(MenuMetric.set(stored: "billingDollars") == [.credits])
        #expect(MenuMetric.set(stored: "limits,credits") == [.limits, .credits])
        #expect(MenuMetric.set(stored: "") == [.limits])
        #expect(MenuMetric.stored([.credits, .limits]) == "limits,credits")
    }

    @Test func statusImagesDrawVisiblePixels() {
        for metrics in [[MenuMetric.limits], [.credits], [.limits, .credits]] as [Set<MenuMetric>] {
            for mode in MenuDisplayMode.allCases {
                let entry = MenuBarStatusEntry(provider: .claude, snapshot: snapshot, metrics: metrics)
                let single = MenuBarStatusImageRenderer.image(entries: [entry], displayMode: mode)
                let pair = MenuBarStatusImageRenderer.image(entries: [entry, entry], displayMode: mode)

                #expect((18...20).contains(single.size.height), "\(metrics) \(mode)")
                #expect(visiblePixelCount(in: single) > 8, "\(metrics) \(mode)")
                #expect(pair.size.width > single.size.width * 2, "providers are drawn side by side")
            }
        }
    }

    private func visiblePixelCount(in image: NSImage) -> Int {
        let width = Int(ceil(image.size.width))
        let height = Int(ceil(image.size.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<height).reduce(0) { count, y in
            count + (0..<width).filter { x in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
            }.count
        }
    }
}
