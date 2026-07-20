import Foundation
import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store = UsageStore()

    init() {
        if let optionIndex = CommandLine.arguments.firstIndex(of: "--render-snapshot"),
           CommandLine.arguments.indices.contains(optionIndex + 1)
        {
            do {
                let period = CommandLine.arguments.indices.contains(optionIndex + 2)
                    ? CodexActivityPeriod(rawValue: CommandLine.arguments[optionIndex + 2])
                    : nil
                try RenderSnapshotCommand.run(
                    path: CommandLine.arguments[optionIndex + 1],
                    period: period)
                Foundation.exit(0)
            } catch {
                fputs("Snapshot render failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfTest.run()
                print("Self-test passed")
                Foundation.exit(0)
            } catch {
                fputs("Self-test failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }
        if CommandLine.arguments.contains("--probe-once") {
            ProbeCommand.run()
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
                .frame(width: 360)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var states: [Provider: ProviderState] = [
        .codex: ProviderState(),
        .claude: ProviderState(),
    ]
    @AppStorage("refreshSeconds") var refreshSeconds = 60
    @AppStorage("showUsedPercent") var showUsedPercent = false
    @AppStorage("trackCodex") var trackCodex = true
    @AppStorage("trackClaude") var trackClaude = true
    @AppStorage("menuMetric") private var menuMetricRaw = MenuMetric.fiveHourPercent.rawValue
    @AppStorage("menuProvider") private var menuProviderRaw = MenuProviderSelection.combined.rawValue
    @AppStorage("menuDisplayMode") private var menuDisplayModeRaw = MenuDisplayMode.ring.rawValue

    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private let fetchers: [Provider: any UsageFetching]

    var menuMetric: MenuMetric {
        get { MenuMetric(rawValue: menuMetricRaw) ?? .fiveHourPercent }
        set { menuMetricRaw = newValue.rawValue }
    }

    var menuProvider: MenuProviderSelection {
        get { MenuProviderSelection(rawValue: menuProviderRaw) ?? .combined }
        set { menuProviderRaw = newValue.rawValue }
    }

    var menuDisplayMode: MenuDisplayMode {
        get { MenuDisplayMode(rawValue: menuDisplayModeRaw) ?? .ring }
        set { menuDisplayModeRaw = newValue.rawValue }
    }

    var menuBarTitle: String {
        DisplayFormatter.menuTitle(
            states: states,
            providerSelection: menuProvider,
            metric: menuMetric,
            showUsed: false)
    }

    var menuBarWindow: RateWindow? {
        let metric = menuMetric == .bothPercent ? MenuMetric.fiveHourPercent : menuMetric
        return DisplayFormatter.selectedWindow(
            states: states,
            providerSelection: menuProvider,
            metric: metric)
    }

    var menuBarInnerWindow: RateWindow? {
        guard menuMetric == .bothPercent else { return nil }
        return DisplayFormatter.selectedWindow(
            states: states,
            providerSelection: menuProvider,
            metric: .sevenDayPercent)
    }

    var menuBarAmountText: String? {
        guard menuMetric == .billingDollars || (menuBarWindow == nil && menuBarInnerWindow == nil) else {
            return nil
        }
        guard let amount = DisplayFormatter.fallbackAmountText(
            states: states,
            providerSelection: menuProvider)
        else { return nil }
        return amount
    }

    var menuBarPercentText: String? {
        DisplayFormatter.menuPercentText(
            window: menuBarWindow,
            innerWindow: menuBarInnerWindow,
            metric: menuMetric,
            showUsed: false)
    }

    func menuMetricLabel(_ metric: MenuMetric) -> String {
        switch metric {
        case .fiveHourPercent:
            let window = DisplayFormatter.selectedWindow(
                states: states,
                providerSelection: menuProvider,
                metric: metric)
            return "\(window?.durationLabel ?? "Short") %"
        case .sevenDayPercent:
            let window = DisplayFormatter.selectedWindow(
                states: states,
                providerSelection: menuProvider,
                metric: metric)
            return "\(window?.durationLabel ?? "Long") %"
        case .bothPercent:
            return "All limits"
        case .billingDollars:
            return metric.label
        }
    }

    var trackedProviders: [Provider] {
        Provider.allCases.filter { isTracking($0) }
    }

    init(fetchers: [Provider: any UsageFetching]? = nil, startImmediately: Bool = true) {
        self.fetchers = fetchers ?? [
            .codex: CodexUsageFetcher(),
            .claude: ClaudeUsageFetcher(),
        ]
        guard startImmediately else { return }
        start()
    }

    func start() {
        refreshAll()
        restartTimer()
    }

    func restartTimer() {
        timerTask?.cancel()
        guard refreshSeconds > 0 else { return }
        let seconds = refreshSeconds
        timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(providers: self.trackedProviders)
        }
    }

    func refresh(provider: Provider) {
        guard isTracking(provider) else { return }
        Task { [weak self] in
            await self?.refresh(providers: [provider])
        }
    }

    func refreshForSnapshot() async {
        await refresh(providers: trackedProviders)
    }

    func isTracking(_ provider: Provider) -> Bool {
        switch provider {
        case .codex: trackCodex
        case .claude: trackClaude
        }
    }

    func setTracking(_ provider: Provider, enabled: Bool) {
        switch provider {
        case .codex:
            trackCodex = enabled
        case .claude:
            trackClaude = enabled
        }

        if enabled {
            refresh(provider: provider)
        } else {
            states[provider] = ProviderState()
        }
    }

    private func refresh(providers: [Provider]) async {
        let providers = providers.filter { isTracking($0) }
        for provider in providers {
            states[provider, default: ProviderState()].isRefreshing = true
            states[provider, default: ProviderState()].error = nil
        }

        await withTaskGroup(of: (Provider, Result<UsageSnapshot, Error>).self) { group in
            for provider in providers {
                guard let fetcher = fetchers[provider] else { continue }
                group.addTask {
                    do {
                        return (provider, .success(try await fetcher.fetch()))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }

            for await (provider, result) in group {
                guard isTracking(provider) else {
                    states[provider] = ProviderState()
                    continue
                }
                var state = states[provider, default: ProviderState()]
                state.isRefreshing = false
                switch result {
                case let .success(snapshot):
                    state.snapshot = snapshot
                    state.error = nil
                case let .failure(error):
                    state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                states[provider] = state
            }
        }
    }
}

@MainActor
private enum RenderSnapshotCommand {
    enum RenderError: LocalizedError {
        case bitmapCreationFailed
        case pngCreationFailed

        var errorDescription: String? {
            switch self {
            case .bitmapCreationFailed: "Could not create a bitmap for the rendered menu."
            case .pngCreationFailed: "Could not encode the rendered menu as PNG."
            }
        }
    }

    static func run(path: String, period: CodexActivityPeriod?) throws {
        let store = UsageStore(startImmediately: false)
        var finished = false
        var renderResult: Result<Void, Error>?

        Task { @MainActor in
            await store.refreshForSnapshot()
            do {
                try render(store: store, path: path, period: period)
                renderResult = .success(())
            } catch {
                renderResult = .failure(error)
            }
            finished = true
        }

        while !finished {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        try renderResult?.get()
    }

    private static func render(
        store: UsageStore,
        path: String,
        period: CodexActivityPeriod?) throws
    {
        let rootView = MenuContentView(store: store, initialActivityPeriod: period ?? .daily)
            .frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 1_200)
        hostingView.layoutSubtreeIfNeeded()

        let fittingHeight = ceil(hostingView.fittingSize.height)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: fittingHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.bitmapCreationFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngCreationFailed
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    var initialActivityPeriod: CodexActivityPeriod = .daily

    private static let refreshIntervals = [5, 15, 30, 60, 300, 900, 1_800, 3_600]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: LayoutSpacing.related) {
                ForEach(store.trackedProviders) { provider in
                    ProviderCard(
                        provider: provider,
                        state: store.states[provider] ?? ProviderState(),
                        isTracking: store.isTracking(provider),
                        refresh: { store.refresh(provider: provider) })
                }
                if store.trackedProviders.isEmpty {
                    Text("No providers selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                if store.isTracking(.codex),
                   let activity = store.states[.codex]?.snapshot?.codexActivity
                {
                    CodexActivityView(activity: activity, initialPeriod: initialActivityPeriod)
                }
            }
            .padding(12)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agent Usage")
                .font(.headline)
            Spacer()
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Track")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(Provider.allCases) { provider in
                        Toggle(provider.displayName, isOn: Binding(
                            get: { store.isTracking(provider) },
                            set: { store.setTracking(provider, enabled: $0) }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            GridRow {
                Text("Menu")
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.menuProvider },
                    set: { store.menuProvider = $0 }))
                {
                    ForEach(MenuProviderSelection.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            GridRow {
                Text("Metric")
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.menuMetric },
                    set: { store.menuMetric = $0 }))
                {
                    ForEach(MenuMetric.allCases) { metric in
                        Text(store.menuMetricLabel(metric)).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            GridRow {
                Text("Display")
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.menuDisplayMode },
                    set: { store.menuDisplayMode = $0 }))
                {
                    ForEach(MenuDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            GridRow {
                Text("Refresh")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { Double(refreshIntervalIndex) },
                            set: { setRefreshInterval(index: Int($0.rounded())) }),
                        in: 0...Double(Self.refreshIntervals.count - 1),
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                store.restartTimer()
                            }
                        })
                    Text(refreshIntervalLabel)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .font(.callout)
        .padding(12)
    }

    private var refreshIntervalIndex: Int {
        Self.refreshIntervals.enumerated().min {
            abs($0.element - store.refreshSeconds) < abs($1.element - store.refreshSeconds)
        }?.offset ?? 3
    }

    private var refreshIntervalLabel: String {
        switch store.refreshSeconds {
        case ..<60:
            "\(store.refreshSeconds)s"
        case ..<3_600:
            "\(store.refreshSeconds / 60)m"
        default:
            "1h"
        }
    }

    private func setRefreshInterval(index: Int) {
        let boundedIndex = min(max(index, 0), Self.refreshIntervals.count - 1)
        let seconds = Self.refreshIntervals[boundedIndex]
        guard seconds != store.refreshSeconds else { return }
        store.refreshSeconds = seconds
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Image(nsImage: MenuBarStatusImageRenderer.image(
            selection: store.menuProvider,
            metric: store.menuMetric,
            displayMode: store.menuDisplayMode,
            window: store.menuBarWindow,
            innerWindow: store.menuBarInnerWindow,
            percentText: store.menuBarPercentText,
            amountText: store.menuBarAmountText))
            .renderingMode(.original)
            .help(helpText)
    }

    private var helpText: String {
        if store.menuMetric == .bothPercent {
            let summaries = [store.menuBarWindow, store.menuBarInnerWindow].compactMap { window -> String? in
                guard let window else { return nil }
                return "\(window.durationLabel) \(DisplayFormatter.percent(window.remainingPercent)) left"
            }
            if !summaries.isEmpty { return summaries.joined(separator: ", ") }
        }
        if let window = store.menuBarWindow, store.menuMetric != .billingDollars {
            return "\(window.durationLabel) \(DisplayFormatter.percent(window.remainingPercent)) left"
        }
        return store.menuBarAmountText ?? "No usage data"
    }
}

enum MenuBarStatusImageRenderer {
    private static let ringDiameter: CGFloat = 18
    private static let ringTextSpacing: CGFloat = 8
    private static let multilineFontSize: CGFloat = 9.5
    private static let multilineLineHeight: CGFloat = 10
    private static let multilineTextVerticalOffset: CGFloat = -1.25

    static func image(
        selection: MenuProviderSelection,
        metric: MenuMetric,
        displayMode: MenuDisplayMode,
        window: RateWindow?,
        innerWindow: RateWindow? = nil,
        percentText: String?,
        amountText: String?) -> NSImage
    {
        _ = selection
        let availableWindow = window ?? innerWindow
        let showsProgress = metric != .billingDollars && availableWindow != nil
        let showsRing = showsProgress && displayMode != .percentage
        let showsPercent = showsProgress && displayMode != .ring
        let amount = showsProgress ? nil : amountText
        let text = showsPercent ? percentText : amount
        let textSize = text.map { self.textSize($0) } ?? .zero
        let ringSize: CGFloat = showsRing ? Self.ringDiameter : 0
        let spacing: CGFloat = showsRing && text != nil ? Self.ringTextSpacing : 0
        let width = max(18, ringSize + spacing + textSize.width)
        let height = max(18, textSize.height)
        let size = NSSize(width: ceil(width), height: ceil(height))

        return NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            if let availableWindow, showsRing {
                let progressRect = NSRect(
                    x: 0,
                    y: (rect.height - Self.ringDiameter) / 2,
                    width: Self.ringDiameter,
                    height: Self.ringDiameter)
                if metric == .bothPercent, let window, let innerWindow {
                    self.drawNestedProgress(
                        outerRemainingPercent: window.remainingPercent,
                        innerRemainingPercent: innerWindow.remainingPercent,
                        in: progressRect)
                } else {
                    self.drawProgress(
                        remainingPercent: availableWindow.remainingPercent,
                        in: progressRect)
                }
            }
            if let text {
                let x = showsRing ? ringSize + spacing : 0
                self.drawText(text, at: CGPoint(x: x, y: (rect.height - textSize.height) / 2))
            }
            return true
        }
    }

    private static func drawProgress(remainingPercent: Double, in rect: NSRect) {
        let clamped = max(0, min(100, remainingPercent))
        guard clamped > 0 else { return }

        NSColor.labelColor.setFill()
        let path = NSBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.appendArc(
            withCenter: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: 90,
            endAngle: 90 + 360 * clamped / 100,
            clockwise: false)
        path.close()
        path.fill()
    }

    private static func drawNestedProgress(
        outerRemainingPercent: Double,
        innerRemainingPercent: Double,
        in rect: NSRect)
    {
        let minSide = min(rect.width, rect.height)
        let outerThickness = minSide / 8
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = minSide / 2 - outerThickness / 2
        let innerRadius = max(1, outerRadius - outerThickness * 1.10)
        let innerRect = NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2)

        self.drawProgress(remainingPercent: innerRemainingPercent, in: innerRect)
        self.drawRingProgress(
            remainingPercent: outerRemainingPercent,
            center: center,
            radius: outerRadius,
            lineWidth: outerThickness)
    }

    private static func drawRingProgress(
        remainingPercent: Double,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat)
    {
        let clamped = max(0, min(100, remainingPercent))
        guard clamped > 0 else { return }

        NSColor.labelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .butt
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 + 360 * clamped / 100,
            clockwise: false)
        path.stroke()
    }

    private static func drawText(_ text: String, at point: CGPoint) {
        let lines = text.components(separatedBy: "\n")
        if lines.count <= 1 {
            let size = self.textSize(text)
            text.draw(
                with: NSRect(origin: point, size: size),
                options: [.usesLineFragmentOrigin],
                attributes: self.textAttributes(for: text))
            return
        }

        let lineHeight = Self.multilineLineHeight
        let totalHeight = lineHeight * CGFloat(lines.count)
        let blockHeight = max(Self.ringDiameter, totalHeight)
        let topY = point.y + (blockHeight - totalHeight) / 2 + Self.multilineTextVerticalOffset
        let attributes = self.textAttributes(for: text)
        for (index, line) in lines.enumerated() {
            let linePoint = CGPoint(
                x: point.x,
                y: topY + CGFloat(lines.count - index - 1) * lineHeight)
            line.draw(
                at: linePoint,
                withAttributes: attributes)
        }
    }

    private static func textSize(_ text: String) -> NSSize {
        let lines = text.components(separatedBy: "\n")
        let attributes = self.textAttributes(for: text)
        let widths = lines.map { $0.size(withAttributes: attributes).width }
        if lines.count > 1 {
            let height = max(Self.ringDiameter, Self.multilineLineHeight * CGFloat(lines.count))
            return NSSize(width: widths.max() ?? 0, height: height)
        }
        let lineHeight = self.textAttributesFont(multiline: false).boundingRectForFont.height
        return NSSize(
            width: widths.max() ?? 0,
            height: max(Self.ringDiameter, lineHeight))
    }

    private static func textAttributes(for text: String) -> [NSAttributedString.Key: Any] {
        let multiline = text.contains("\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        if multiline {
            paragraph.minimumLineHeight = Self.multilineLineHeight
            paragraph.maximumLineHeight = Self.multilineLineHeight
            paragraph.lineSpacing = 0
        }
        return [
            .font: self.textAttributesFont(multiline: multiline),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    private static func textAttributesFont(multiline: Bool) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: multiline ? Self.multilineFontSize : 12, weight: .medium)
    }
}

private enum LayoutSpacing {
    static let compact: CGFloat = 4
    static let related: CGFloat = 6
    static let inset: CGFloat = 8
    static let section: CGFloat = 10
}

struct ProviderCard: View {
    var provider: Provider
    var state: ProviderState
    var isTracking: Bool
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutSpacing.section) {
            providerHeader

            VStack(alignment: .leading, spacing: LayoutSpacing.related) {
                if let shortWindow = state.snapshot?.fiveHour {
                    UsageBar(label: shortWindow.durationLabel, window: shortWindow)
                }
                if let longWindow = state.snapshot?.sevenDay {
                    UsageBar(label: longWindow.durationLabel, window: longWindow)
                }
                if state.snapshot?.rateWindows.isEmpty != false {
                    UsageBar(label: "Limits", window: nil)
                }
                amountRow
            }

            if let error = state.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .opacity(isTracking ? 1 : 0.55)
    }

    @ViewBuilder
    private var providerHeader: some View {
        if provider == .codex {
            VStack(alignment: .leading, spacing: LayoutSpacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(planText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: LayoutSpacing.related)
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, state.isRefreshing ? 46 : 26)
                }
                Text(streakText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .overlay(alignment: .topTrailing) {
                refreshControl
            }
        } else {
            HStack(spacing: LayoutSpacing.related) {
                VStack(alignment: .leading, spacing: LayoutSpacing.compact) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                refreshControl
            }
        }
    }

    private var refreshControl: some View {
        HStack(spacing: LayoutSpacing.compact) {
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .disabled(!isTracking)
            .help("Refresh \(provider.displayName)")
        }
    }

    private var planText: String {
        guard isTracking else { return "Tracking off" }
        return state.snapshot?.plan ?? "--"
    }

    private var updatedText: String {
        if let snapshot = state.snapshot {
            return "Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
        }
        if state.isRefreshing { return "Refreshing..." }
        return "No data"
    }

    private var streakText: String {
        guard let activity = state.snapshot?.codexActivity else {
            return "Current streak -- · Longest --"
        }
        let current = activity.currentStreakDays.map { "\($0)d" } ?? "--"
        let longest = activity.longestStreakDays.map { "\($0)d" } ?? "--"
        return "Current streak \(current) · Longest \(longest)"
    }

    private var subtitle: String {
        guard isTracking else { return "Tracking disabled" }
        if let snapshot = state.snapshot {
            let account = snapshot.accountEmail ?? snapshot.plan ?? snapshot.source
            return "Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · \(account)"
        }
        if state.isRefreshing { return "Refreshing..." }
        return "No data yet"
    }

    private var amountLabel: String {
        guard let snapshot = state.snapshot else { return "Amount used" }
        if snapshot.credits != nil { return "Credits" }
        if snapshot.billingCost != nil { return "Billing period" }
        if snapshot.localUsageCost != nil { return "Local usage" }
        return "Amount used"
    }

    private var amountValueText: String {
        DisplayFormatter.amountText(state.snapshot) ?? DisplayFormatter.dollars(0)
    }

    @ViewBuilder
    private var amountRow: some View {
        if provider == .codex {
            HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
                ResetSummaryHoverLabel(
                    summary: resetSummaryText,
                    expirationHelp: resetExpirationHelp)
                Spacer(minLength: LayoutSpacing.related)
                Text("Credits: \(amountValueText)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 96, alignment: .trailing)
            }
            .font(.caption)
        } else {
            HStack {
                Text(amountLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(amountValueText)
                    .monospacedDigit()
            }
            .font(.caption)
        }
    }

    private var resetSummaryText: String {
        DisplayFormatter.resetSummary(state.snapshot?.resetCredits)
    }

    private var resetExpirationHelp: String {
        DisplayFormatter.resetExpirationHelp(state.snapshot?.resetCredits)
    }
}

enum CodexActivityPeriod: String, CaseIterable, Identifiable {
    case daily = "Day"
    case weekly = "Week"
    case cumulative = "Cumulative"

    var id: String { rawValue }
}

private struct CodexActivityView: View {
    var activity: CodexActivitySnapshot
    @State private var period: CodexActivityPeriod

    init(activity: CodexActivitySnapshot, initialPeriod: CodexActivityPeriod = .daily) {
        self.activity = activity
        _period = State(initialValue: initialPeriod)
    }

    var body: some View {
        VStack(spacing: LayoutSpacing.related) {
            HStack(spacing: LayoutSpacing.related) {
                ActivityStatPanel(
                    label: "Lifetime",
                    value: DisplayFormatter.compactTokens(activity.lifetimeTokens),
                    detail: "tokens",
                    helpText: activity.lifetimeTokens.map {
                        "\(DisplayFormatter.compactTokens($0)) tokens"
                    })
                ActivityStatPanel(
                    label: "Peak day",
                    value: DisplayFormatter.compactTokens(activity.peakDailyTokens),
                    detail: peakDateLabel,
                    helpText: activity.peakDailyTokens.map {
                        "\(peakDateLabel ?? "Peak") – \(DisplayFormatter.compactTokens($0))"
                    })
                ActivityStatPanel(
                    label: "Longest chat",
                    value: DisplayFormatter.duration(seconds: activity.longestRunningTurnSec),
                    detail: "single turn",
                    helpText: activity.longestRunningTurnSec.map {
                        DisplayFormatter.duration(seconds: $0)
                    })
            }

            Picker("Activity period", selection: $period) {
                ForEach(CodexActivityPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            Group {
                switch period {
                case .daily:
                    TokenDailyHeatmap(days: activity.dailyUsage)
                case .weekly:
                    TokenWeeklyBars(buckets: weeklyBuckets)
                case .cumulative:
                    TokenCumulativeLine(days: activity.dailyUsage)
                }
            }
            .frame(height: 110)
        }
    }

    private var sortedDays: [TokenUsageDay] {
        activity.dailyUsage.sorted { $0.startDate < $1.startDate }
    }

    private var peakDateLabel: String? {
        guard let peak = activity.peakDailyTokens,
              let day = sortedDays.first(where: { $0.tokens == peak }),
              let date = day.date
        else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var weeklyBuckets: [TokenWeekBucket] {
        let calendar = Calendar.current
        let dated = Dictionary(uniqueKeysWithValues: sortedDays.compactMap { day -> (Date, Int64)? in
            guard let date = day.date else { return nil }
            return (calendar.startOfDay(for: date), day.tokens)
        })
        let end = dated.keys.max() ?? calendar.startOfDay(for: Date())
        let start = dated.keys.min() ?? end
        let dayCount = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let bucketCount = max(12, (dayCount + 6) / 7)
        return (0..<bucketCount).map { week in
            let weeksAgo = bucketCount - 1 - week
            let bucketEnd = calendar.date(byAdding: .day, value: -(weeksAgo * 7), to: end) ?? end
            let bucketStart = calendar.date(byAdding: .day, value: -6, to: bucketEnd) ?? bucketEnd
            let total = (0..<7).reduce(Int64(0)) { result, day in
                let date = calendar.date(byAdding: .day, value: day, to: bucketStart) ?? bucketStart
                return result + (dated[date] ?? 0)
            }
            return TokenWeekBucket(startDate: bucketStart, endDate: bucketEnd, tokens: total)
        }
    }

}

private struct ActivityStatPanel: View {
    var label: String
    var value: String
    var detail: String?
    var helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutSpacing.compact) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .padding(LayoutSpacing.inset)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .hoverDetail(helpText ?? "No details available")
    }
}

private struct TokenPlotPoint: Identifiable {
    var date: Date
    var tokens: Int64

    var id: Date { date }
}

private struct TokenWeekBucket: Identifiable {
    var startDate: Date
    var endDate: Date
    var tokens: Int64

    var id: Date { startDate }
}

private enum ChartLayout {
    static let plotHeight: CGFloat = 88
    static let timelineHeight: CGFloat = 110
    static let axisLabelWidth: CGFloat = 26
    static let axisSpacing: CGFloat = LayoutSpacing.compact
    static let weekdayLabelWidth: CGFloat = 10
    static let ruleWidth: CGFloat = 1
    static let tooltipHalfWidth: CGFloat = 76
    static let hoverAnimation = Animation.easeOut(duration: 0.10)
    static let heatmapHoverAnimation = Animation.easeOut(duration: 0.045)
    static let scrollIndicatorFadeDuration = 0.08
    static let legendRevealDelay = 0.10
}

private struct ChartViewport: Equatable {
    var offsetX: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
}

private struct CellSnapScrollTargetBehavior: ScrollTargetBehavior {
    var step: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard step > 0 else { return }
        let maximumX = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = min(
            max((target.rect.origin.x / step).rounded() * step, 0),
            maximumX)
    }
}

private struct ChartDateLegend: View {
    var dates: [Date]
    var isHidden: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(dates.prefix(3).enumerated()), id: \.offset) { index, date in
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .frame(
                        maxWidth: .infinity,
                        alignment: index == 0 ? .leading : index == 2 ? .trailing : .center)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(false)
    }
}

private struct ChartScrollIndicator: View {
    var viewport: ChartViewport
    var isVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let hasOverflow = viewport.contentWidth > viewport.visibleWidth
                && viewport.visibleWidth > 0
            let thumbWidth = hasOverflow
                ? max(24, trackWidth * viewport.visibleWidth / viewport.contentWidth)
                : trackWidth
            let travel = max(0, trackWidth - thumbWidth)
            let maximumOffset = max(1, viewport.contentWidth - viewport.visibleWidth)
            let progress = min(max(viewport.offsetX / maximumOffset, 0), 1)

            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: thumbWidth, height: 3)
                .offset(x: travel * progress)
                .opacity(isVisible && hasOverflow ? 1 : 0)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}

private extension View {
    @ViewBuilder
    func trackChartScroll(
        viewport: Binding<ChartViewport>,
        unitWidth: CGFloat,
        phaseChanged: @escaping (Bool) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            self
                .onScrollGeometryChange(for: ChartViewport.self) { geometry in
                    let offset = unitWidth > 0
                        ? floor(geometry.visibleRect.minX / unitWidth) * unitWidth
                        : geometry.visibleRect.minX
                    return ChartViewport(
                        offsetX: offset,
                        visibleWidth: geometry.visibleRect.width,
                        contentWidth: geometry.contentSize.width)
                } action: { _, newValue in
                    viewport.wrappedValue = newValue
                }
                .onScrollPhaseChange { _, newPhase in
                    phaseChanged(newPhase.isScrolling)
                }
        } else {
            self
        }
    }
}

private func visibleIndexRange(
    count: Int,
    viewport: ChartViewport,
    defaultVisibleCount: Int
) -> ClosedRange<Int>? {
    guard count > 0 else { return nil }
    guard viewport.visibleWidth > 0, viewport.contentWidth > 0 else {
        let lower = max(0, count - min(count, defaultVisibleCount))
        return lower...(count - 1)
    }
    let unitWidth = viewport.contentWidth / CGFloat(count)
    guard unitWidth > 0 else { return 0...(count - 1) }
    let lower = min(max(Int(floor(viewport.offsetX / unitWidth)), 0), count - 1)
    let upper = min(
        max(Int(ceil((viewport.offsetX + viewport.visibleWidth) / unitWidth)) - 1, lower),
        count - 1)
    return lower...upper
}

private func threeDates(_ dates: [Date]) -> [Date] {
    guard let first = dates.first else { return [] }
    guard dates.count > 1, let last = dates.last else { return [first, first, first] }
    return [first, dates[(dates.count - 1) / 2], last]
}

private struct HeatmapModel {
    let points: [TokenPlotPoint]
    let latestDate: Date
    let weekCount: Int

    init(days: [TokenUsageDay]) {
        let calendar = Calendar.current
        var dated: [Date: Int64] = [:]
        for day in days {
            guard let date = day.date else { continue }
            dated[calendar.startOfDay(for: date), default: 0] += day.tokens
        }

        let latest = dated.keys.max() ?? calendar.startOfDay(for: Date())
        let earliest = dated.keys.min() ?? latest
        let weekday = calendar.component(.weekday, from: latest)
        let daysToSunday = (8 - weekday) % 7
        let end = calendar.date(byAdding: .day, value: daysToSunday, to: latest) ?? latest
        let daysFromEarliest = (calendar.dateComponents([.day], from: earliest, to: end).day ?? 0) + 1
        let weekCount = max(26, (daysFromEarliest + 6) / 7)
        let pointCount = weekCount * 7
        let points = (0..<pointCount).map { index in
            let date = calendar.date(byAdding: .day, value: index - (pointCount - 1), to: end) ?? end
            return TokenPlotPoint(date: date, tokens: dated[date] ?? 0)
        }

        self.points = points
        self.latestDate = latest
        self.weekCount = weekCount
    }
}

private struct HeatmapMetrics {
    let rowSpacing = LayoutSpacing.compact / 2
    let columnSpacing = LayoutSpacing.compact / 2
    let labelSpacing = LayoutSpacing.compact
    let cellSize: CGFloat
    let contentWidth: CGFloat

    init(size: CGSize, weekCount: Int) {
        let cellHeight = (size.height - rowSpacing * 6) / 7
        cellSize = max(1, cellHeight)
        contentWidth = cellSize * CGFloat(weekCount)
            + columnSpacing * CGFloat(max(0, weekCount - 1))
    }

    func cellCenter(at index: Int) -> CGPoint {
        let week = index / 7
        let weekday = index % 7
        return CGPoint(
            x: CGFloat(week) * (cellSize + columnSpacing) + cellSize / 2,
            y: CGFloat(weekday) * (cellSize + rowSpacing) + cellSize / 2)
    }
}

private struct TokenDailyHeatmap: View {
    private let model: HeatmapModel
    @State private var scrollTarget: String?
    @State private var viewport = ChartViewport()
    @State private var legendHidden = false
    @State private var scrollIndicatorVisible = false
    @State private var legendRevealTask: Task<Void, Never>?

    init(days: [TokenUsageDay]) {
        model = HeatmapModel(days: days)
        _scrollTarget = State(initialValue: "heatmap-latest")
    }

    var body: some View {
        let metrics = HeatmapMetrics(
            size: CGSize(width: 0, height: ChartLayout.plotHeight),
            weekCount: model.weekCount)
        let weekRange = visibleIndexRange(
            count: model.weekCount,
            viewport: viewport,
            defaultVisibleCount: 26) ?? 0...0
        let visiblePoints = weekRange.flatMap { week in
            let lower = week * 7
            let upper = min(lower + 6, model.points.count - 1)
            return model.points[lower...upper].filter { $0.date <= model.latestDate }
        }
        let visibleMaximum = Double(max(visiblePoints.map(\.tokens).max() ?? 0, 1))
        let legendDates = threeDates(weekRange.map { week in
            let index = min(week * 7 + 3, model.points.count - 1)
            return min(model.points[index].date, model.latestDate)
        })

        HStack(alignment: .top, spacing: metrics.labelSpacing) {
            VStack(spacing: metrics.rowSpacing) {
                let weekdayLabels = ["M", "", "W", "", "F", "", "S"]
                ForEach(weekdayLabels.indices, id: \.self) { index in
                    Text(weekdayLabels[index])
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ChartLayout.weekdayLabelWidth,
                            height: metrics.cellSize,
                            alignment: .center)
                }
            }
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            HeatmapGrid(
                                model: model,
                                metrics: metrics,
                                maximum: visibleMaximum)
                            HeatmapHoverOverlay(
                                model: model,
                                metrics: metrics,
                                viewport: viewport,
                                plotSize: CGSize(
                                    width: metrics.contentWidth,
                                    height: ChartLayout.plotHeight))
                        }
                        .frame(width: metrics.contentWidth, height: ChartLayout.plotHeight)
                        .frame(height: ChartLayout.timelineHeight, alignment: .top)
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("heatmap-latest")
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.trailing)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $scrollTarget, anchor: .trailing)
                .scrollTargetBehavior(CellSnapScrollTargetBehavior(
                    step: metrics.cellSize + metrics.columnSpacing))
                .trackChartScroll(
                    viewport: $viewport,
                    unitWidth: metrics.cellSize + metrics.columnSpacing,
                    phaseChanged: updateScrollPhase)

                ChartScrollIndicator(
                    viewport: viewport,
                    isVisible: scrollIndicatorVisible)
                    .padding(.horizontal, 2)
                ChartDateLegend(dates: legendDates, isHidden: legendHidden)
                    .padding(.horizontal, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily token activity")
        .onDisappear {
            legendRevealTask?.cancel()
        }
    }

    private func updateScrollPhase(_ isScrolling: Bool) {
        legendRevealTask?.cancel()
        if isScrolling {
            legendHidden = true
            withAnimation(.linear(duration: 0.04)) {
                scrollIndicatorVisible = true
            }
        } else {
            withAnimation(.easeOut(duration: ChartLayout.scrollIndicatorFadeDuration)) {
                scrollIndicatorVisible = false
            }
            legendRevealTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ChartLayout.legendRevealDelay))
                guard !Task.isCancelled else { return }
                legendHidden = false
            }
        }
    }
}

private struct HeatmapGrid: View {
    let model: HeatmapModel
    let metrics: HeatmapMetrics
    let maximum: Double

    var body: some View {
        HStack(spacing: metrics.columnSpacing) {
            ForEach(0..<model.weekCount, id: \.self) { week in
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let point = model.points[week * 7 + weekday]
                        if point.date > model.latestDate {
                            Color.clear
                                .frame(width: metrics.cellSize, height: metrics.cellSize)
                        } else {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color(for: point.tokens))
                                .frame(width: metrics.cellSize, height: metrics.cellSize)
                        }
                    }
                }
            }
        }
    }

    private func color(for value: Int64) -> Color {
        guard value > 0 else { return Color.secondary.opacity(0.08) }
        let normalized = min(1, sqrt(Double(value) / maximum))
        return Color.accentColor.opacity(0.2 + normalized * 0.8)
    }
}

private struct HeatmapHoverOverlay: View {
    let model: HeatmapModel
    let metrics: HeatmapMetrics
    let viewport: ChartViewport
    let plotSize: CGSize
    @State private var hoveredIndex: Int?
    @State private var highlightedIndex: Int

    init(
        model: HeatmapModel,
        metrics: HeatmapMetrics,
        viewport: ChartViewport,
        plotSize: CGSize
    ) {
        self.model = model
        self.metrics = metrics
        self.viewport = viewport
        self.plotSize = plotSize
        let forcedIndex = Self.forcedHoverIndex(in: model.points)
        _hoveredIndex = State(initialValue: forcedIndex)
        _highlightedIndex = State(initialValue: forcedIndex ?? 0)
    }

    var body: some View {
        let activeIndex = hoveredIndex
        ZStack(alignment: .topLeading) {
            Color.clear

            let center = metrics.cellCenter(at: highlightedIndex)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: metrics.cellSize + 2, height: metrics.cellSize + 2)
                .position(center)
                .opacity(activeIndex == nil ? 0 : 1)
                .scaleEffect(activeIndex == nil ? 0.92 : 1)
                .animation(ChartLayout.heatmapHoverAnimation, value: activeIndex != nil)

            if let activeIndex, model.points.indices.contains(activeIndex) {
                let activeCenter = metrics.cellCenter(at: activeIndex)
                let tooltipText = dayHelp(model.points[activeIndex])
                ChartHoverLabel(text: tooltipText)
                    .position(tooltipPosition(
                        cellCenter: activeCenter,
                        labelWidth: chartHoverLabelWidth(tooltipText)))
            }
        }
        .frame(width: plotSize.width, height: plotSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                updateHoveredIndex(pointIndex(at: location))
            case .ended:
                updateHoveredIndex(nil)
            }
        }
    }

    private func pointIndex(at location: CGPoint) -> Int? {
        let localX = location.x
        let gridWidth = metrics.contentWidth
        let gridHeight = metrics.cellSize * 7 + metrics.rowSpacing * 6
        guard localX >= 0, localX <= gridWidth,
              location.y >= 0, location.y <= gridHeight
        else { return nil }

        let week = min(max(Int((localX + metrics.columnSpacing / 2)
            / (metrics.cellSize + metrics.columnSpacing)), 0), model.weekCount - 1)
        let weekday = min(max(Int((location.y + metrics.rowSpacing / 2)
            / (metrics.cellSize + metrics.rowSpacing)), 0), 6)
        let index = week * 7 + weekday
        guard model.points.indices.contains(index),
              model.points[index].date <= model.latestDate
        else { return nil }
        return index
    }

    private static func forcedHoverIndex(in points: [TokenPlotPoint]) -> Int? {
        guard let match = ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_HOVER"],
              !match.isEmpty
        else { return nil }
        return points.firstIndex { point in
            dayHelp(point).localizedCaseInsensitiveContains(match)
        }
    }

    private func updateHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        if let index {
            highlightedIndex = index
        }
        hoveredIndex = index
    }

    private static func dayHelp(_ point: TokenPlotPoint) -> String {
        let date = point.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) – \(DisplayFormatter.compactTokens(point.tokens))"
    }

    private func dayHelp(_ point: TokenPlotPoint) -> String {
        Self.dayHelp(point)
    }

    private func tooltipPosition(cellCenter: CGPoint, labelWidth: CGFloat) -> CGPoint {
        let halfWidth = labelWidth / 2
        let halfHeight: CGFloat = 13
        let gap = LayoutSpacing.compact
        let visibleBounds = chartVisibleBounds(
            viewport: viewport,
            contentWidth: plotSize.width)
        let rightX = cellCenter.x + metrics.cellSize / 2 + gap + halfWidth
        let leftX = cellCenter.x - metrics.cellSize / 2 - gap - halfWidth
        let x: CGFloat
        if rightX + halfWidth <= visibleBounds.upperBound {
            x = rightX
        } else if leftX - halfWidth >= visibleBounds.lowerBound {
            x = leftX
        } else {
            x = viewportTooltipX(
                cellCenter.x,
                viewport: viewport,
                contentWidth: plotSize.width)
        }
        let y = min(max(halfHeight, cellCenter.y), plotSize.height - halfHeight)
        return CGPoint(x: x, y: y)
    }
}

private struct TokenWeeklyBars: View {
    var buckets: [TokenWeekBucket]
    @State private var hoveredIndex: Int?
    @State private var scrollTarget: String?
    @State private var viewport = ChartViewport()
    @State private var legendHidden = false
    @State private var scrollIndicatorVisible = false
    @State private var legendRevealTask: Task<Void, Never>?

    init(buckets: [TokenWeekBucket]) {
        self.buckets = buckets
        _hoveredIndex = State(initialValue: nil)
        _scrollTarget = State(initialValue: "weekly-latest")
    }

    var body: some View {
        let range = visibleIndexRange(
            count: buckets.count,
            viewport: viewport,
            defaultVisibleCount: 12)
        let visibleBuckets = range.map { Array(buckets[$0]) } ?? []
        let maximumValue = DisplayFormatter.roundedAxisMaximum(
            visibleBuckets.map(\.tokens).max() ?? 0)
        let legendDates: [Date] = if let first = visibleBuckets.first,
                                     let last = visibleBuckets.last
        {
            [first.startDate,
             visibleBuckets[(visibleBuckets.count - 1) / 2].startDate,
             last.endDate]
        } else {
            []
        }

        HStack(alignment: .top, spacing: ChartLayout.axisSpacing) {
            VStack(alignment: .trailing) {
                Text(DisplayFormatter.compactTokens(maximumValue))
                Spacer()
                Text("0")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: ChartLayout.axisLabelWidth, height: ChartLayout.plotHeight)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: ChartLayout.ruleWidth, height: ChartLayout.plotHeight)
            GeometryReader { geometry in
                let baseColumnWidth = geometry.size.width / 12
                let contentWidth = max(
                    geometry.size.width,
                    baseColumnWidth * CGFloat(max(1, buckets.count)))
                let columnWidth = buckets.isEmpty
                    ? contentWidth
                    : contentWidth / CGFloat(buckets.count)

                ZStack(alignment: .bottom) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                let activeIndex = hoveredIndex ?? forcedHoverIndex
                                let highlightIndex = activeIndex ?? 0
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.06))
                                    .frame(width: columnWidth, height: ChartLayout.plotHeight)
                                    .position(
                                        x: (CGFloat(highlightIndex) + 0.5) * columnWidth,
                                        y: ChartLayout.plotHeight / 2)
                                    .opacity(activeIndex == nil ? 0 : 1)
                                    .animation(ChartLayout.hoverAnimation, value: hoveredIndex)

                                HStack(alignment: .bottom, spacing: 0) {
                                    ForEach(buckets.indices, id: \.self) { index in
                                        let bucket = buckets[index]
                                        let fraction = CGFloat(
                                            Double(bucket.tokens) / Double(maximumValue))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.accentColor)
                                            .frame(width: max(2, columnWidth - LayoutSpacing.compact))
                                            .frame(
                                                width: columnWidth,
                                                height: max(
                                                    2,
                                                    ChartLayout.plotHeight
                                                        * min(1, fraction)),
                                                alignment: .bottom)
                                    }
                                }
                                .frame(
                                    width: contentWidth,
                                    height: ChartLayout.plotHeight,
                                    alignment: .bottom)

                                if let activeIndex, buckets.indices.contains(activeIndex) {
                                    let centerX = (CGFloat(activeIndex) + 0.5) * columnWidth
                                    ChartHoverLabel(text: weekHelp(buckets[activeIndex]))
                                        .position(
                                            x: viewportTooltipX(
                                                centerX,
                                                viewport: viewport,
                                                contentWidth: contentWidth),
                                            y: 12)
                                }
                            }
                            .frame(width: contentWidth, height: ChartLayout.plotHeight)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    updateHoveredIndex(bucketIndex(
                                        at: location.x,
                                        width: contentWidth))
                                case .ended:
                                    updateHoveredIndex(nil)
                                }
                            }
                            .frame(height: ChartLayout.timelineHeight, alignment: .top)
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("weekly-latest")
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $scrollTarget, anchor: .trailing)
                    .scrollTargetBehavior(CellSnapScrollTargetBehavior(step: columnWidth))
                    .trackChartScroll(
                        viewport: $viewport,
                        unitWidth: columnWidth,
                        phaseChanged: updateScrollPhase)

                    ChartScrollIndicator(
                        viewport: viewport,
                        isVisible: scrollIndicatorVisible)
                        .padding(.horizontal, 2)
                    ChartDateLegend(dates: legendDates, isHidden: legendHidden)
                        .padding(.horizontal, 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekly token activity")
        .onDisappear {
            legendRevealTask?.cancel()
        }
    }

    private func weekHelp(_ bucket: TokenWeekBucket) -> String {
        let start = bucket.startDate.formatted(.dateTime.month(.abbreviated).day())
        let end = bucket.endDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(start)–\(end) · \(DisplayFormatter.compactTokens(bucket.tokens))"
    }

    private var forcedHoverIndex: Int? {
        guard let match = ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_HOVER"],
              !match.isEmpty
        else { return nil }
        return buckets.firstIndex { weekHelp($0).localizedCaseInsensitiveContains(match) }
    }

    private func bucketIndex(at x: CGFloat, width: CGFloat) -> Int? {
        guard !buckets.isEmpty, width > 0, x >= 0, x <= width else { return nil }
        return min(Int(x / width * CGFloat(buckets.count)), buckets.count - 1)
    }

    private func updateHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
    }

    private func updateScrollPhase(_ isScrolling: Bool) {
        legendRevealTask?.cancel()
        if isScrolling {
            legendHidden = true
            withAnimation(.linear(duration: 0.04)) {
                scrollIndicatorVisible = true
            }
        } else {
            withAnimation(.easeOut(duration: ChartLayout.scrollIndicatorFadeDuration)) {
                scrollIndicatorVisible = false
            }
            legendRevealTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ChartLayout.legendRevealDelay))
                guard !Task.isCancelled else { return }
                legendHidden = false
            }
        }
    }
}

private struct TokenCumulativeLine: View {
    private let points: [TokenPlotPoint]
    @State private var hoverLocation: CGPoint?
    @State private var scrollTarget: String?
    @State private var viewport = ChartViewport()
    @State private var legendHidden = false
    @State private var scrollIndicatorVisible = false
    @State private var legendRevealTask: Task<Void, Never>?

    init(days: [TokenUsageDay]) {
        var total: Int64 = 0
        points = days.sorted { $0.startDate < $1.startDate }.compactMap { day in
            guard let date = day.date else { return nil }
            total += day.tokens
            return TokenPlotPoint(date: date, tokens: total)
        }
        if let rawX = ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_HOVER_X"],
           let normalizedX = Double(rawX)
        {
            _hoverLocation = State(initialValue: CGPoint(x: normalizedX, y: 0))
        } else {
            _hoverLocation = State(initialValue: nil)
        }
        _scrollTarget = State(initialValue: "cumulative-latest")
    }

    var body: some View {
        let range = visibleIndexRange(
            count: points.count,
            viewport: viewport,
            defaultVisibleCount: 160)
        let visiblePoints = range.map { Array(points[$0]) } ?? []
        let maximumValue = DisplayFormatter.roundedAxisMaximum(
            visiblePoints.map(\.tokens).max() ?? 0)
        let legendDates = threeDates(visiblePoints.map(\.date))

        HStack(alignment: .top, spacing: ChartLayout.axisSpacing) {
            VStack(alignment: .trailing) {
                Text(DisplayFormatter.compactTokens(maximumValue))
                Spacer()
                Text("0")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: ChartLayout.axisLabelWidth, height: ChartLayout.plotHeight)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: ChartLayout.ruleWidth, height: ChartLayout.plotHeight)
            GeometryReader { geometry in
                let contentWidth = max(
                    geometry.size.width,
                    CGFloat(max(1, points.count - 1)) * 2)
                ZStack(alignment: .bottom) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            let plotSize = CGSize(
                                width: contentWidth,
                                height: ChartLayout.plotHeight)
                            let activeLocation = resolvedHoverLocation(in: plotSize)
                            let activeIndex = activeLocation.map {
                                pointIndex(
                                    at: $0.x,
                                    width: contentWidth,
                                    count: points.count)
                            }

                            ZStack(alignment: .topLeading) {
                                Path { path in
                                    guard points.count > 1 else { return }
                                    for (index, point) in points.enumerated() {
                                        let x = contentWidth * CGFloat(index)
                                            / CGFloat(points.count - 1)
                                        let y = ChartLayout.plotHeight * (1 - CGFloat(
                                            Double(point.tokens) / Double(maximumValue)))
                                        if index == 0 {
                                            path.move(to: CGPoint(x: x, y: y))
                                        } else {
                                            path.addLine(to: CGPoint(x: x, y: y))
                                        }
                                    }
                                }
                                .stroke(
                                    Color.accentColor,
                                    style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                                if let activeLocation,
                                   let activeIndex,
                                   points.indices.contains(activeIndex)
                                {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.55))
                                        .frame(width: 1, height: ChartLayout.plotHeight)
                                        .position(
                                            x: activeLocation.x,
                                            y: ChartLayout.plotHeight / 2)

                                    Circle()
                                        .fill(Color.accentColor)
                                        .overlay(Circle().stroke(
                                            Color(nsColor: .windowBackgroundColor),
                                            lineWidth: 1.5))
                                        .frame(width: 7, height: 7)
                                        .position(
                                            x: activeLocation.x,
                                            y: interpolatedY(
                                                at: activeLocation.x,
                                                points: points,
                                                maximumValue: maximumValue,
                                                size: plotSize))

                                    ChartHoverLabel(text: pointHelp(points[activeIndex]))
                                        .position(
                                            x: tooltipX(
                                                activeLocation.x,
                                                contentWidth: contentWidth),
                                            y: 12)
                                }
                            }
                            .frame(width: contentWidth, height: ChartLayout.plotHeight)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                            .frame(height: ChartLayout.timelineHeight, alignment: .top)
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("cumulative-latest")
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $scrollTarget, anchor: .trailing)
                    .trackChartScroll(
                        viewport: $viewport,
                        unitWidth: contentWidth / CGFloat(max(1, points.count)),
                        phaseChanged: updateScrollPhase)

                    ChartScrollIndicator(
                        viewport: viewport,
                        isVisible: scrollIndicatorVisible)
                        .padding(.horizontal, 2)
                    ChartDateLegend(dates: legendDates, isHidden: legendHidden)
                        .padding(.horizontal, 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cumulative token activity")
        .onDisappear {
            legendRevealTask?.cancel()
        }
    }

    private func pointHelp(_ point: TokenPlotPoint) -> String {
        let date = point.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) – \(DisplayFormatter.compactTokens(point.tokens))"
    }

    private func resolvedHoverLocation(in size: CGSize) -> CGPoint? {
        guard let hoverLocation else { return nil }
        if ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_HOVER_X"] != nil {
            return CGPoint(
                x: min(max(0, hoverLocation.x), 1) * size.width,
                y: hoverLocation.y)
        }
        return CGPoint(x: min(max(0, hoverLocation.x), size.width), y: hoverLocation.y)
    }

    private func pointIndex(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0 else { return 0 }
        let scaled = x / width * CGFloat(count - 1)
        return min(max(Int(scaled.rounded()), 0), count - 1)
    }

    private func interpolatedY(
        at x: CGFloat,
        points: [TokenPlotPoint],
        maximumValue: Int64,
        size: CGSize) -> CGFloat
    {
        guard points.count > 1, size.width > 0 else { return size.height }
        let scaled = min(max(0, x / size.width), 1) * CGFloat(points.count - 1)
        let lowerIndex = Int(floor(scaled))
        let upperIndex = min(lowerIndex + 1, points.count - 1)
        let fraction = scaled - CGFloat(lowerIndex)
        let lower = Double(points[lowerIndex].tokens)
        let upper = Double(points[upperIndex].tokens)
        let interpolated = lower + (upper - lower) * Double(fraction)
        return size.height * (1 - CGFloat(interpolated / Double(maximumValue)))
    }

    private func tooltipX(_ x: CGFloat, contentWidth: CGFloat) -> CGFloat {
        viewportTooltipX(x, viewport: viewport, contentWidth: contentWidth)
    }

    private func updateScrollPhase(_ isScrolling: Bool) {
        legendRevealTask?.cancel()
        if isScrolling {
            legendHidden = true
            withAnimation(.linear(duration: 0.04)) {
                scrollIndicatorVisible = true
            }
        } else {
            withAnimation(.easeOut(duration: ChartLayout.scrollIndicatorFadeDuration)) {
                scrollIndicatorVisible = false
            }
            legendRevealTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ChartLayout.legendRevealDelay))
                guard !Task.isCancelled else { return }
                legendHidden = false
            }
        }
    }
}

private func chartVisibleBounds(
    viewport: ChartViewport,
    contentWidth: CGFloat
) -> ClosedRange<CGFloat> {
    guard viewport.visibleWidth > 0 else { return 0...contentWidth }
    let lower = min(max(viewport.offsetX, 0), contentWidth)
    let upper = min(max(lower, lower + viewport.visibleWidth), contentWidth)
    return lower...upper
}

private func chartHoverLabelWidth(_ text: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
    return ceil(textWidth) + LayoutSpacing.inset * 2
}

private func viewportTooltipX(
    _ x: CGFloat,
    viewport: ChartViewport,
    contentWidth: CGFloat
) -> CGFloat {
    let bounds = chartVisibleBounds(viewport: viewport, contentWidth: contentWidth)
    let halfWidth = min(
        ChartLayout.tooltipHalfWidth,
        max(0, (bounds.upperBound - bounds.lowerBound) / 2))
    let minimum = bounds.lowerBound + halfWidth
    let maximum = max(minimum, bounds.upperBound - halfWidth)
    return min(max(x, minimum), maximum)
}

private extension View {
    func hoverDetail(_ text: String, alignment: Alignment = .top) -> some View {
        modifier(HoverDetailModifier(text: text, alignment: alignment))
    }
}

private struct ChartHoverLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, LayoutSpacing.inset)
            .padding(.vertical, LayoutSpacing.compact)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 5, x: 0, y: 2)
            .allowsHitTesting(false)
    }
}

private struct HoverDetailModifier: ViewModifier {
    var text: String
    var alignment: Alignment

    @State private var isHovering = false
    @State private var showsDetail = false
    @State private var hoverTask: Task<Void, Never>?

    private var isForcedForSnapshot: Bool {
        guard let match = ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_HOVER"],
              !match.isEmpty
        else { return false }
        return text.localizedCaseInsensitiveContains(match)
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover(perform: updateHover)
            .overlay(alignment: alignment) {
                if showsDetail || isForcedForSnapshot {
                    ChartHoverLabel(text: text)
                        .offset(y: -28)
                }
            }
            .zIndex(showsDetail ? 100 : 0)
            .onDisappear {
                hoverTask?.cancel()
                showsDetail = false
            }
    }

    private func updateHover(_ hovering: Bool) {
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, isHovering else { return }
                showsDetail = true
            }
        } else {
            showsDetail = false
        }
    }
}

struct ResetSummaryHoverLabel: View {
    var summary: String
    var expirationHelp: String

    @State private var isHovering = false
    @State private var showsPopup = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Text(summary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 140, height: 26)
                    .contentShape(Rectangle())
                    .onHover(perform: updateHover)
            }
            .overlay(alignment: .bottomLeading) {
                if showsPopup {
                    ResetExpirationPopup(text: expirationHelp)
                        .offset(y: -18)
                        .transition(.opacity)
                }
            }
            .zIndex(showsPopup ? 10 : 0)
            .onDisappear {
                hoverTask?.cancel()
                showsPopup = false
            }
    }

    private func updateHover(_ hovering: Bool) {
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled, isHovering else { return }
                showsPopup = true
            }
        } else {
            showsPopup = false
        }
    }
}

struct ResetExpirationPopup: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .allowsHitTesting(false)
    }
}

struct UsageBar: View {
    var label: String
    var window: RateWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                if let refreshText {
                    Text(refreshText)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(percentText)
                        .monospacedDigit()
                        .frame(minWidth: 34, alignment: .trailing)
                    Text("remaining")
                }
            }
            .font(.caption)
            ProgressView(value: progress)
                .tint(.primary)
        }
    }

    private var percentText: String {
        guard let window else { return "--" }
        return DisplayFormatter.percent(window.remainingPercent)
    }

    private var refreshText: String? {
        guard let window else { return nil }
        if let resetsAt = window.resetsAt {
            return "Refreshes \(Self.formatResetDate(resetsAt))"
        }
        guard let resetDescription = window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resetDescription.isEmpty
        else { return nil }
        return "Refreshes \(Self.cleanResetDescription(resetDescription))"
    }

    private var progress: Double {
        guard let window else { return 0 }
        return max(0, min(1, window.remainingPercent / 100))
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = false
        formatter.dateFormat = "hh:mm a, MMM d"
        return formatter.string(from: date)
    }

    private static func cleanResetDescription(_ text: String) -> String {
        var cleaned = text
        for prefix in ["Resets at ", "Resets ", "Reset at ", "Reset "] {
            if cleaned.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
                cleaned.removeFirst(prefix.count)
                break
            }
        }
        if let timezoneStart = cleaned.range(of: " (") {
            cleaned.removeSubrange(timezoneStart.lowerBound..<cleaned.endIndex)
        }
        return cleaned
            .replacingOccurrences(of: " AM", with: "AM")
            .replacingOccurrences(of: " PM", with: "PM")
            .replacingOccurrences(of: "AM", with: " AM")
            .replacingOccurrences(of: "PM", with: " PM")
    }
}
