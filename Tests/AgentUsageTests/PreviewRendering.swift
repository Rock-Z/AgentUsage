import AppKit
import SwiftUI
import Testing
@testable import AgentUsage

/// Renders the README previews offscreen from fixed demo data. Runs only when
/// AGENTUSAGE_PREVIEW_DIR is set; see Scripts/render-readme-previews.sh.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTUSAGE_PREVIEW_DIR"] != nil))
func renderReadmePreviews() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGENTUSAGE_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = UsageStore(states: PreviewData.states)
    let updates = UpdateController(startsUpdater: false)
    // The first chart a process draws misses its initial scroll to the latest
    // period; later ones do not. Render once and discard it.
    _ = try renderPopover(store: store, updates: updates, period: .daily, appearance: .aqua)

    for (period, appearance, name) in [
        (CodexActivityPeriod.daily, NSAppearance.Name.aqua, "day"),
        (.weekly, .aqua, "week"),
        (.cumulative, .darkAqua, "cumulative"),
    ] {
        let popover = try renderPopover(store: store, updates: updates, period: period, appearance: appearance)
        try png(popover).write(to: directory.appendingPathComponent("\(name)-popover.png"))
        let status = renderStatusItem(appearance: appearance)
        try png(status).write(to: directory.appendingPathComponent("\(name)-status.png"))
    }
}

@MainActor
private func renderPopover(
    store: UsageStore,
    updates: UpdateController,
    period: CodexActivityPeriod,
    appearance: NSAppearance.Name
) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: MenuContentView(
        store: store,
        updateController: updates,
        initialActivityPeriod: period,
        version: ProcessInfo.processInfo.environment["AGENTUSAGE_PREVIEW_VERSION"] ?? "Dev")
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true))
    // On a real display but fully transparent and click-through: nothing shows,
    // yet SwiftUI gets display updates (an offscreen window never scrolls charts).
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)

    // Charts scroll to the latest period and rescale once scroll geometry
    // arrives. SwiftUI applies that from run loop observers, which the test
    // runner does not otherwise run, so spin the run loop between draws.
    for _ in 0..<3 {
        let warmup = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: warmup)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
    }
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// The menu bar icon on a 24pt menu bar at 2x, drawn for a light or dark menu bar.
@MainActor
private func renderStatusItem(appearance: NSAppearance.Name) -> NSBitmapImageRep {
    let entries = Provider.allCases.map {
        MenuBarStatusEntry(provider: $0, snapshot: PreviewData.states[$0]?.snapshot, metrics: [.limits])
    }
    let icon = MenuBarStatusImageRenderer.image(entries: entries, displayMode: .ringAndPercentage)
    let canvas = NSSize(width: ceil(icon.size.width) + 16, height: 24)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        icon.draw(
            at: NSPoint(x: 8, y: (canvas.height - icon.size.height) / 2),
            from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func png(_ rep: NSBitmapImageRep) throws -> Data {
    try #require(rep.representation(using: .png, properties: [:]))
}

/// Plausible, fixed usage so previews are reproducible and show no real account.
private enum PreviewData {
    static let now = Date()

    static var states: [Provider: ProviderState] {
        [.codex: ProviderState(snapshot: codex), .claude: ProviderState(snapshot: claude)]
    }

    static let codex = UsageSnapshot(
        provider: .codex,
        limits: [
            UsageLimit(id: "codex.secondary", title: "5h", usedPercent: 24, resetsAt: now + 2.4 * 3_600),
            UsageLimit(id: "codex.primary", title: "7d", usedPercent: 41, resetsAt: now + 3.2 * 86_400),
        ],
        credits: CreditSnapshot(balance: 0, unlimited: false),
        resetCredits: ResetCreditSnapshot(
            availableCount: 2,
            credits: [
                ResetCredit(resetType: nil, status: "available", grantedAt: nil, expiresAt: now + 9 * 86_400, title: nil, description: nil),
                ResetCredit(resetType: nil, status: "available", grantedAt: nil, expiresAt: now + 26 * 86_400, title: nil, description: nil),
            ]),
        plan: PlanNames.codex("pro"),
        codexActivity: activity,
        updatedAt: now)

    static let claude = UsageSnapshot(
        provider: .claude,
        limits: [
            UsageLimit(id: "Session", title: "Session", usedPercent: 32, resetsAt: now + 3.1 * 3_600),
            UsageLimit(id: "Weekly", title: "Weekly", usedPercent: 47, resetsAt: now + 2.1 * 86_400),
            UsageLimit(id: "Weekly Fable", title: "Weekly Fable", usedPercent: 18, resetsAt: now + 2.1 * 86_400, scope: "Fable"),
        ],
        credits: CreditSnapshot(balance: 25, unlimited: false, currencyCode: "USD"),
        plan: PlanNames.claude("max", rateLimitTier: "default_claude_max_20x"),
        updatedAt: now)

    /// About 200 days of activity with weekday rhythm and a few quiet stretches.
    static var activity: CodexActivitySnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        var seed: UInt64 = 0x5eed
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let days = (0..<200).reversed().map { offset -> TokenUsageDay in
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let season = 0.55 + 0.45 * sin(Double(200 - offset) / 23)
            let quiet = random() < (weekend ? 0.45 : 0.12)
            let tokens = quiet ? 0 : (weekend ? 0.3 : 1) * season * (0.4 + random()) * 480_000_000
            return TokenUsageDay(startDate: formatter.string(from: date), tokens: Int64(tokens))
        }
        return CodexActivitySnapshot(
            lifetimeTokens: days.reduce(0) { $0 + $1.tokens },
            peakDailyTokens: days.map(\.tokens).max(),
            longestRunningTurnSec: 47_828,
            currentStreakDays: 12,
            longestStreakDays: 31,
            dailyUsage: days)
    }
}
