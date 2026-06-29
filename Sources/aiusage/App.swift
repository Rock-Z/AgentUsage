import Foundation
import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store = UsageStore()

    init() {
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

        Settings {
            SettingsPane(store: store)
                .frame(width: 420)
                .padding()
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var states: [Provider: ProviderState] = [
        .codex: ProviderState(),
        .claude: ProviderState(),
    ]
    @AppStorage("refreshSeconds") var refreshSeconds = 300
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
        guard menuMetric == .billingDollars || menuBarWindow == nil else { return nil }
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
                try? await Task.sleep(for: .seconds(seconds))
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

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 10) {
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
                        Text(metric.label).tag(metric)
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
        }
        .font(.callout)
        .padding(12)
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
        if let outer = store.menuBarWindow,
           let inner = store.menuBarInnerWindow,
           store.menuMetric == .bothPercent
        {
            return "5h \(DisplayFormatter.percent(outer.remainingPercent)) left, 7d \(DisplayFormatter.percent(inner.remainingPercent)) left"
        }
        if let window = store.menuBarWindow, store.menuMetric != .billingDollars {
            return "\(DisplayFormatter.percent(window.remainingPercent)) left"
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
        let showsProgress = metric != .billingDollars && window != nil
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

            if let window, showsRing {
                let progressRect = NSRect(
                    x: 0,
                    y: (rect.height - Self.ringDiameter) / 2,
                    width: Self.ringDiameter,
                    height: Self.ringDiameter)
                if metric == .bothPercent, let innerWindow {
                    self.drawNestedProgress(
                        outerRemainingPercent: window.remainingPercent,
                        innerRemainingPercent: innerWindow.remainingPercent,
                        in: progressRect)
                } else {
                    self.drawProgress(
                        remainingPercent: window.remainingPercent,
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

struct ProviderCard: View {
    var provider: Provider
    var state: ProviderState
    var isTracking: Bool
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
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

            UsageBar(label: "5h", window: state.snapshot?.fiveHour)
            UsageBar(label: "7d", window: state.snapshot?.sevenDay)

            amountRow

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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ResetSummaryHoverLabel(
                    summary: resetSummaryText,
                    expirationHelp: resetExpirationHelp)
                Spacer(minLength: 8)
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

struct SettingsPane: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Picker("Refresh", selection: $store.refreshSeconds) {
                Text("Manual").tag(0)
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
                Text("15 minutes").tag(900)
            }
            .onChange(of: store.refreshSeconds) { _, _ in
                store.restartTimer()
            }

            Picker("Menu provider", selection: Binding(
                get: { store.menuProvider },
                set: { store.menuProvider = $0 }))
            {
                ForEach(MenuProviderSelection.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Picker("Menu metric", selection: Binding(
                get: { store.menuMetric },
                set: { store.menuMetric = $0 }))
            {
                ForEach(MenuMetric.allCases) { metric in
                    Text(metric.label).tag(metric)
                }
            }

            Picker("Display mode", selection: Binding(
                get: { store.menuDisplayMode },
                set: { store.menuDisplayMode = $0 }))
            {
                ForEach(MenuDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }
}
