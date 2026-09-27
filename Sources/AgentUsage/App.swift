import Foundation
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AgentUsageApplicationDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var updateController = UpdateController()

    init() {
        if CommandLine.arguments.contains("--probe-once") {
            ProbeCommand.run()
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                store: store,
                updateController: updateController)
                .frame(width: 360)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AgentUsageApplicationDelegate: NSObject, NSApplicationDelegate {
    private var revealTask: Task<Void, Never>?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        revealMenuBarExtra(after: 0.35)
        return false
    }

    private func revealMenuBarExtra(after delay: TimeInterval = 0.05) {
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
                for attempt in 0..<20 {
                    try Task.checkCancellation()
                    if self.isMenuBarExtraVisible {
                        return
                    }
                    if let button = self.statusBarButton(),
                       let action = button.action
                    {
                        _ = NSApp.sendAction(
                            action,
                            to: button.target,
                            from: button)
                        NSApp.activate()
                        return
                    }
                    if attempt < 19 {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private var isMenuBarExtraVisible: Bool {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? Int32 == getpid()
                && $0[kCGWindowLayer as String] as? Int == 101
        }
    }

    private func statusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let contentView = window.contentView,
               let button = statusBarButton(in: contentView)
            {
                return button
            }
        }

        let statusItemsSelector = NSSelectorFromString("_statusItems")
        guard NSStatusBar.system.responds(to: statusItemsSelector),
              let result = NSStatusBar.system.perform(statusItemsSelector)
        else { return nil }

        let value = result.takeUnretainedValue()
        let statusItems: [NSStatusItem]
        if let items = value as? [NSStatusItem] {
            statusItems = items
        } else if let pointerArray = value as? NSPointerArray {
            statusItems = pointerArray.allObjects.compactMap { $0 as? NSStatusItem }
        } else {
            return nil
        }
        return statusItems.compactMap(\.button).first
    }

    private func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) {
                return button
            }
        }
        return nil
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var states: [Provider: ProviderState] = [
        .codex: ProviderState(),
        .claude: ProviderState(),
    ]
    @AppStorage("refreshSeconds") var refreshSeconds = 60
    @AppStorage("trackCodex") var trackCodex = true
    @AppStorage("trackClaude") var trackClaude = true
    @AppStorage("menuMetric") private var menuMetricRaw = MenuMetric.limits.rawValue
    @AppStorage("menuProvider") private var menuProviderRaw = MenuProviderSelection.combined.rawValue
    @AppStorage("menuDisplayMode") private var menuDisplayModeRaw = MenuDisplayMode.ring.rawValue

    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private let fetchers: [Provider: any UsageFetching] = [
        .codex: CodexUsageFetcher(),
        .claude: ClaudeUsageFetcher(),
    ]

    var menuMetrics: Set<MenuMetric> {
        get { MenuMetric.set(stored: menuMetricRaw) }
        set { menuMetricRaw = MenuMetric.stored(newValue) }
    }

    var menuProvider: MenuProviderSelection {
        get { MenuProviderSelection(rawValue: menuProviderRaw) ?? .combined }
        set { menuProviderRaw = newValue.rawValue }
    }

    var menuDisplayMode: MenuDisplayMode {
        get { MenuDisplayMode(rawValue: menuDisplayModeRaw) ?? .ring }
        set { menuDisplayModeRaw = newValue.rawValue }
    }

    var trackedProviders: [Provider] {
        Provider.allCases.filter { isTracking($0) }
    }


    init() {
        let defaults = UserDefaults.standard
        FirstLaunchSettings.applyIfNeeded(
            defaults: defaults,
            availableProviders: FirstLaunchSettings.locallyAvailableProviders(),
            hasLaunchedBefore: defaults.bool(forKey: "SUHasLaunchedBefore"))
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
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(providers: self.trackedProviders)
            self.refreshTask = nil
        }
    }

    func refresh(provider: Provider) {
        guard isTracking(provider) else { return }
        guard states[provider]?.isRefreshing != true else { return }
        Task { [weak self] in
            await self?.refresh(providers: [provider])
        }
    }

    func isTracking(_ provider: Provider) -> Bool {
        return switch provider {
        case .codex: trackCodex
        case .claude: trackClaude
        }
    }

    /// Keeps at least one provider enabled.
    func setTracking(_ provider: Provider, _ enabled: Bool) {
        guard let selection = MenuProviderSelection(codex: trackCodex, claude: trackClaude)
            .setting(provider, enabled)
        else { return }
        setEnabledProviders(selection)
    }

    func isShown(_ provider: Provider) -> Bool {
        isTracking(provider) && menuProvider.providers.contains(provider)
    }

    /// Only enabled providers can be shown, and at least one always is.
    func setShown(_ provider: Provider, _ shown: Bool) {
        guard isTracking(provider),
              let selection = MenuProviderSelection(
                  codex: isShown(.codex), claude: isShown(.claude))
                  .setting(provider, shown)
        else { return }
        menuProvider = selection
    }

    private func setEnabledProviders(_ selection: MenuProviderSelection) {
        let previouslyTracked = Set(trackedProviders)
        trackCodex = selection == .codex || selection == .combined
        trackClaude = selection == .claude || selection == .combined

        menuProvider = menuProvider.constrained(to: trackedProviders)

        for provider in Provider.allCases {
            if isTracking(provider) {
                if !previouslyTracked.contains(provider) {
                    refresh(provider: provider)
                }
            } else {
                states[provider] = ProviderState()
            }
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
                    state.error = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                states[provider] = state
            }
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateController: UpdateController
    @StateObject private var launchAtLoginController = LaunchAtLoginController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("optionsExpanded") private var optionsExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let refreshIntervals = [5, 15, 30, 60, 300, 900, 1_800, 3_600]
    /// Popover width minus its horizontal padding.
    private static let contentWidth: CGFloat = 336
    private static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Dev"
    fileprivate static let periodPickerWidth: CGFloat = 252

    private var visualTheme: UsageVisualTheme {
        UsageVisualTheme(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                ForEach(Provider.allCases) { provider in
                    if provider != Provider.allCases.first {
                        Divider()
                    }
                    // Header tooltips hang downward, so earlier sections draw on top.
                    let stackOrder = Double(Provider.allCases.count - (Provider.allCases.firstIndex(of: provider) ?? 0))
                    if store.isTracking(provider) {
                        providerSection(provider)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .zIndex(stackOrder)
                    } else {
                        DisabledProviderRow(provider: provider) {
                            store.setTracking(provider, true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .zIndex(stackOrder)
                    }
                }
            }
            .zIndex(1)
            Divider()
            optionsSection
        }
        .background(.regularMaterial)
        // The menu bar popover's corner radius (measured on macOS 26), so
        // concentric shapes such as the last row's highlight follow it.
        .containerShape(RoundedRectangle(cornerRadius: 15))
        .foregroundStyle(visualTheme.textColor)
        .tint(visualTheme.accentColor)
        .environment(
            \.usageVisualTheme,
            visualTheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("AgentUsage")
                    .font(.headline)
                Text("v\(Self.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: LayoutSpacing.section) {
            ProviderCard(
                provider: provider,
                state: store.states[provider] ?? ProviderState(),
                isShown: store.isShown(provider),
                // The only provider in the menu bar stays there.
                canToggleShown: store.menuProvider.providers.filter(store.isShown) != [provider],
                toggleShown: { store.setShown(provider, !store.isShown(provider)) },
                // The last enabled provider stays on.
                disable: store.trackedProviders == [provider]
                    ? nil
                    : { store.setTracking(provider, false) },
                refresh: { store.refresh(provider: provider) })
            if provider == .codex,
               let activity = store.states[.codex]?.snapshot?.codexActivity
            {
                CodexActivityView(activity: activity)
            }
        }
    }

    private var optionsSection: some View {
        VStack(spacing: 0) {
            Button {
                toggleOptions()
            } label: {
                HStack {
                    Text("Options")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .rotationEffect(
                            .degrees(optionsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityValue(optionsExpanded ? "Expanded" : "Collapsed")
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if optionsExpanded {
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Keeps the sliding options from drawing over the header above.
        .clipped()
    }

    private func toggleOptions() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            optionsExpanded.toggle()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            let metrics = store.menuMetrics
            let mode = store.menuDisplayMode
            VStack(alignment: .leading, spacing: 7) {
                // Switch pairs share columns; labels keep their full width.
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 7) {
                    GridRow {
                        optionLabel("Menu bar")
                        switchCell("Limits") { metricSwitch("Limits", .limits, metrics: metrics) }
                        switchCell("Credits") { metricSwitch("Credits", .credits, metrics: metrics) }
                        // Takes the spare width so the pairs stay compact.
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                    Divider()
                    GridRow {
                        optionLabel("Style")
                        switchCell("Ring", isDimmed: !metrics.contains(.limits)) {
                            SettingsSwitch(
                                title: "Ring",
                                isOn: Binding(
                                    get: { mode.showsRing },
                                    set: { setDisplay(ring: $0, percentage: mode.showsPercentage) }),
                                isLocked: mode == .ring || !metrics.contains(.limits))
                        }
                        switchCell("Percentage", isDimmed: !metrics.contains(.limits)) {
                            SettingsSwitch(
                                title: "Percentage",
                                isOn: Binding(
                                    get: { mode.showsPercentage },
                                    set: { setDisplay(ring: mode.showsRing, percentage: $0) }),
                                isLocked: mode == .percentage || !metrics.contains(.limits))
                        }
                    }
                }
                Divider()
                optionRow("Refresh") {
                    Slider(
                        value: Binding(
                            get: { Double(refreshIntervalIndex) },
                            set: { setRefreshInterval(index: Int($0.rounded())) }),
                        in: 0...Double(Self.refreshIntervals.count - 1),
                        step: 1
                    ) {
                        Text("Refresh interval")
                    } onEditingChanged: { editing in
                        if !editing { store.restartTimer() }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityValue(refreshIntervalLabel)
                    Text(refreshIntervalLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Divider()
                optionRow("Startup") {
                    Text("Open at login")
                        .accessibilityHidden(true)
                    Spacer()
                    SettingsSwitch(
                        title: "Open at login",
                        isOn: Binding(
                            get: { launchAtLoginController.isEnabled },
                            set: { launchAtLoginController.setEnabled($0) }))
                }
            }
            .onAppear {
                launchAtLoginController.refresh()
            }

            if let errorMessage = launchAtLoginController.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(visualTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                FooterActionButton(
                    title: updateController.actionTitle,
                    width: Self.contentWidth,
                    textColor: visualTheme.textColor,
                    hoverFill: visualTheme.controlTrack) {
                    updateController.performAction()
                }
                .disabled(!updateController.canPerformAction)
                FooterActionButton(
                    title: "Quit AgentUsage",
                    width: Self.contentWidth,
                    textColor: visualTheme.textColor,
                    hoverFill: visualTheme.controlTrack,
                    isLastRow: true) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, -8)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func optionLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .frame(width: 64, alignment: .leading)
    }

    /// A row label, then the row's controls filling the rest of the width.
    private func optionRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            optionLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label and its switch as two grid cells, so switches line up in columns.
    /// Labels keep their natural width; columns grow to fit rather than truncate.
    @ViewBuilder
    private func switchCell(
        _ title: String,
        isDimmed: Bool = false,
        @ViewBuilder control: () -> some View
    ) -> some View {
        Text(title)
            .foregroundStyle(isDimmed ? .tertiary : .primary)
            .fixedSize()
            .accessibilityHidden(true)
        control()
            .padding(.trailing, 14)
    }

    /// Limits and credits are independent, but at least one stays on.
    private func metricSwitch(_ title: String, _ metric: MenuMetric, metrics: Set<MenuMetric>) -> SettingsSwitch {
        SettingsSwitch(
            title: title,
            isOn: Binding(
                get: { metrics.contains(metric) },
                set: { on in
                    var next = metrics
                    if on { next.insert(metric) } else { next.remove(metric) }
                    if !next.isEmpty { store.menuMetrics = next }
                }),
            isLocked: metrics == [metric])
    }

    private func setDisplay(ring: Bool, percentage: Bool) {
        if let mode = MenuDisplayMode(ring: ring, percentage: percentage) {
            store.menuDisplayMode = mode
        }
    }

    private var refreshIntervalIndex: Int {
        Self.refreshIntervals.enumerated().min {
            abs($0.element - store.refreshSeconds) < abs($1.element - store.refreshSeconds)
        }?.offset ?? 3
    }

    private var refreshIntervalLabel: String {
        let seconds = store.refreshSeconds
        return switch seconds {
        case ..<60: "\(seconds)s"
        case ..<3_600: "\(seconds / 60)m"
        default: "1h"
        }
    }

    private func setRefreshInterval(index: Int) {
        let seconds = Self.refreshIntervals[min(max(index, 0), Self.refreshIntervals.count - 1)]
        guard seconds != store.refreshSeconds else { return }
        store.refreshSeconds = seconds
    }
}

private struct FooterActionButton: View {
    var title: String
    var width: CGFloat
    var textColor: Color
    var hoverFill: Color
    /// The last row's highlight follows the window's rounded bottom corners.
    var isLastRow = false
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(textColor.opacity(isEnabled ? 1 : 0.45))
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background {
                    highlightShape
                        .fill(isHovering && isEnabled ? hoverFill : .clear)
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovering = hovering
            }
        }
    }

    private var highlightShape: AnyShape {
        if #available(macOS 26.0, *), isLastRow {
            AnyShape(ConcentricRectangle(
                topLeadingCorner: 6,
                topTrailingCorner: 6,
                bottomLeadingCorner: .concentric,
                bottomTrailingCorner: .concentric))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// A capsule segmented control whose selection slides between segments.
/// AppKit's segmented control neither animates its selection nor, through
/// SwiftUI's Picker, fills a set width. The track is a plain fill: the popover
/// is already glass, and glass layered on glass stands out against wallpaper.
private struct NativeSegmentedPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let selected = option == selection
        return Button {
            guard !selected else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) {
                selection = option
            }
        } label: {
            Text(label(option))
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if selected {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A mini native switch. Locked switches cannot change, e.g. the last one on.
private struct SettingsSwitch: View {
    var title: String
    @Binding var isOn: Bool
    var isLocked = false

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isLocked)
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Image(nsImage: MenuBarStatusImageRenderer.image(
            entries: entries,
            displayMode: store.menuDisplayMode))
            .renderingMode(.original)
            .help(helpText)
    }

    private var entries: [MenuBarStatusEntry] {
        store.menuProvider.providers.map { provider in
            MenuBarStatusEntry(
                provider: provider,
                snapshot: store.states[provider]?.snapshot,
                metrics: store.menuMetrics)
        }
    }

    private var helpText: String {
        let entries = entries
        guard entries.count > 1 else { return entries.first?.summary ?? "No usage data" }
        return entries
            .map { "\($0.provider.displayName): \($0.summary)" }
            .joined(separator: "; ")
    }
}

enum MenuBarStatusImageRenderer {
    private static let ringDiameter: CGFloat = 18
    private static let ringTextSpacing: CGFloat = 4
    private static let providerSpacing: CGFloat = 8
    private static let multilineFontSize: CGFloat = 9.5
    private static let multilineLineHeight: CGFloat = 10
    private static let multilineTextVerticalOffset: CGFloat = -1.25
    private static let singleLineTextVerticalOffset: CGFloat = -0.75

    /// Several entries are drawn side by side, one per provider.
    static func image(
        entries: [MenuBarStatusEntry],
        displayMode: MenuDisplayMode) -> NSImage
    {
        let images = entries.map { image(entry: $0, displayMode: displayMode) }
        return images.count == 1 ? images[0] : sideBySideImage(images)
    }

    /// Draws, left to right: the limit ring, the limit percentages, and credits.
    private static func image(
        entry: MenuBarStatusEntry,
        displayMode: MenuDisplayMode) -> NSImage
    {
        let showsRing = !entry.limits.isEmpty && displayMode.showsRing
        let texts = [displayMode.showsPercentage ? entry.percentText : nil, entry.amountText]
            .compactMap { $0 }
        let textSizes = texts.map { self.textSize($0) }
        var parts = textSizes.map(\.width)
        if showsRing { parts.insert(Self.ringDiameter, at: 0) }
        let width = max(18, parts.reduce(0, +) + Self.ringTextSpacing * CGFloat(max(0, parts.count - 1)))
        let height = max(18, textSizes.map(\.height).max() ?? 0)
        let size = NSSize(width: ceil(width), height: ceil(height))

        return NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            var x: CGFloat = 0
            if showsRing, let outer = entry.limits.first {
                let progressRect = NSRect(
                    x: 0,
                    y: (rect.height - Self.ringDiameter) / 2,
                    width: Self.ringDiameter,
                    height: Self.ringDiameter)
                if entry.limits.count > 1 {
                    self.drawNestedProgress(
                        outerRemainingPercent: outer.remainingPercent,
                        innerRemainingPercent: entry.limits[1].remainingPercent,
                        in: progressRect)
                } else {
                    self.drawProgress(remainingPercent: outer.remainingPercent, in: progressRect)
                }
                x = Self.ringDiameter + Self.ringTextSpacing
            }
            for (text, textSize) in zip(texts, textSizes) {
                self.drawText(text, at: CGPoint(x: x, y: (rect.height - textSize.height) / 2))
                x += textSize.width + Self.ringTextSpacing
            }
            return true
        }
    }

    private static func sideBySideImage(_ images: [NSImage]) -> NSImage {
        let spacing = Self.providerSpacing
        let width = images.reduce(0) { $0 + $1.size.width }
            + spacing * CGFloat(max(0, images.count - 1))
        let height = images.map(\.size.height).max() ?? Self.ringDiameter
        return NSImage(size: NSSize(width: ceil(width), height: ceil(height)), flipped: false) { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(
                    at: NSPoint(x: x, y: (height - image.size.height) / 2),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
                x += image.size.width + spacing
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
            self.styledLine(text, attributes: self.textAttributes(for: text)).draw(
                with: NSRect(
                    origin: CGPoint(
                        x: point.x,
                        y: point.y + Self.singleLineTextVerticalOffset),
                    size: size),
                options: [.usesLineFragmentOrigin])
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
            self.styledLine(line, attributes: attributes).draw(at: linePoint)
        }
    }

    /// Limit names recede in the secondary color so the percentages stand out.
    private static func styledLine(
        _ line: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let styled = NSMutableAttributedString(string: line, attributes: attributes)
        if let space = line.range(of: " ", options: .backwards) {
            styled.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(line.startIndex..<space.lowerBound, in: line))
        }
        return styled
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

/// Card header controls share one glyph size and frame so they line up.
private struct HeaderIconButton: View {
    static let size: CGFloat = 18

    var systemImage: String
    var isActive = true
    /// Short text shown on hover.
    var tooltip: String
    /// The fuller description read by VoiceOver.
    var label: String
    /// Tall glyphs such as the pin need a smaller size to match round ones.
    var glyphSize: CGFloat = 13
    var action: () -> Void

    @State private var showsTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(isActive ? .primary : .tertiary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .accessibilityLabel(label)
        // System tooltips appear late or not at all in a menu bar popover.
        .overlay(alignment: .topTrailing) {
            if showsTooltip {
                ChartHoverLabel(text: tooltip)
                    .offset(y: Self.size + 4)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            hoverTask?.cancel()
            guard hovering else {
                withAnimation(.easeOut(duration: 0.1)) { showsTooltip = false }
                return
            }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.1)) { showsTooltip = true }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            showsTooltip = false
        }
    }
}

/// A disabled provider collapses to one line so it can be turned back on in place.
private struct DisabledProviderRow: View {
    var provider: Provider
    var enable: () -> Void
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        // Same structure as a card header: "Off" sits where the plan does.
        HStack(alignment: .center, spacing: LayoutSpacing.section) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(theme.textColor)
            }
            Spacer()
            HeaderIconButton(
                systemImage: "power",
                isActive: false,
                tooltip: "Turn on",
                label: "Turn on \(provider.displayName)",
                action: enable)
        }
    }
}

struct ProviderCard: View {
    var provider: Provider
    var state: ProviderState
    var isShown: Bool
    var canToggleShown: Bool
    var toggleShown: () -> Void
    var disable: (() -> Void)?
    var refresh: () -> Void
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutSpacing.section) {
            providerHeader
                .zIndex(1)

            VStack(alignment: .leading, spacing: LayoutSpacing.related) {
                ForEach(state.snapshot?.limits ?? []) { limit in
                    UsageBar(label: limit.title, limit: limit)
                }
                if state.snapshot?.limits.isEmpty != false {
                    UsageBar(label: "Limits", limit: nil)
                }
                if provider == .codex,
                   let activity = state.snapshot?.codexActivity
                {
                    codexTokenSummary(activity)
                }
                amountRow
            }

            if let error = state.error {
                if provider == .claude,
                   error == "Unexpected response: Claude credential does not contain an OAuth access token."
                {
                    (Text("**Claude is signed out.** Run ")
                        + Text(Image(nsImage: Self.signInCommandBadge))
                            .baselineOffset(-3)
                        + Text(" in Terminal, then refresh."))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Claude is signed out. Run claude auth login in Terminal, then refresh.")
                }
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static var signInCommandBadge: NSImage {
        let command = NSAttributedString(
            string: "claude auth login",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        let textSize = command.size()
        let size = NSSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height) + 2)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            command.draw(at: NSPoint(x: 4, y: 1))
            return true
        }
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: LayoutSpacing.compact) {
            // Text shares a baseline; the icon buttons center on the row.
            HStack(alignment: .center, spacing: LayoutSpacing.section) {
                HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
                    Text(provider.displayName)
                        .font(.headline)
                    if let planText = state.snapshot?.plan {
                        Text(planText)
                            .font(.caption)
                            .foregroundStyle(theme.textColor)
                    }
                    Spacer(minLength: LayoutSpacing.related)
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(theme.textColor)
                        .lineLimit(1)
                }
                headerControls
            }
            if provider == .codex {
                Text(streakText)
                    .font(.caption)
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
            }
        }
    }

    private var headerControls: some View {
        HStack(spacing: LayoutSpacing.related) {
            HeaderIconButton(
                systemImage: isShown ? "pin.fill" : "pin",
                isActive: isShown,
                tooltip: isShown ? "Unpin from menu bar" : "Pin to menu bar",
                label: isShown
                    ? "Unpin \(provider.displayName) from menu bar"
                    : "Pin \(provider.displayName) to menu bar",
                glyphSize: 10.5,
                action: toggleShown)
                .disabled(!canToggleShown)
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: HeaderIconButton.size, height: HeaderIconButton.size)
            } else {
                HeaderIconButton(
                    systemImage: "arrow.clockwise",
                    tooltip: "Refresh",
                    label: "Refresh \(provider.displayName)",
                    action: refresh)
            }
            HeaderIconButton(
                systemImage: "power",
                tooltip: "Turn off",
                label: "Turn off \(provider.displayName)",
                action: { disable?() })
                // The last enabled provider stays on.
                .disabled(disable == nil)
        }
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

    private var amountValueText: String {
        DisplayFormatter.amountText(state.snapshot) ?? "--"
    }

    private func codexTokenSummary(_ activity: CodexActivitySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
            Text("Tokens")
                .foregroundStyle(theme.textColor)
            Spacer(minLength: LayoutSpacing.related)
            Text(tokenSummaryText(activity))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func tokenSummaryText(_ activity: CodexActivitySnapshot) -> String {
        let lifetime = DisplayFormatter.compactTokens(activity.lifetimeTokens)
        let peakValue = DisplayFormatter.compactTokens(activity.peakDailyTokens)
        guard let peak = activity.peakDailyTokens,
              let day = activity.dailyUsage.first(where: { $0.tokens == peak }),
              let date = day.date
        else { return "\(lifetime) all time · \(peakValue) peak" }
        let peakDate = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(lifetime) all time · \(peakValue) peak on \(peakDate)"
    }

    @ViewBuilder
    private var amountRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutSpacing.related) {
            if provider == .codex {
                ResetSummaryHoverLabel(
                    summary: resetSummaryText,
                    expirationHelp: resetExpirationHelp)
            } else {
                Text(" ")
                    .accessibilityHidden(true)
            }
            Spacer(minLength: LayoutSpacing.related)
            Text("Credits: \(amountValueText)")
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .trailing)
        }
        .font(.caption)
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
    @State private var period = CodexActivityPeriod.daily

    var body: some View {
        VStack(spacing: ChartLayout.selectorSpacing) {
            NativeSegmentedPicker(
                selection: $period,
                options: CodexActivityPeriod.allCases,
                label: \.rawValue)
            .accessibilityLabel("Activity period")
            .frame(width: MenuContentView.periodPickerWidth)
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

    private var weeklyBuckets: [TokenWeekBucket] {
        // Bars are as narrow as heatmap days, so match the heatmap's 26 weeks.
        TokenWeekBucket.calendarWeeks(from: sortedDays, minimumCount: 26)
    }

}

private struct TokenPlotPoint: Identifiable {
    var date: Date
    var tokens: Int64

    var id: Date { date }

    var label: String {
        let date = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) – \(DisplayFormatter.compactTokens(tokens))"
    }
}

private struct TokenCumulativePath: Shape {
    var points: [TokenPlotPoint]
    var maximumValue: Double

    var animatableData: Double {
        get { maximumValue }
        set { maximumValue = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, maximumValue > 0 else { return path }
        for (index, point) in points.enumerated() {
            let x = rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let fraction = min(1, Double(point.tokens) / maximumValue)
            let y = rect.height * (1 - CGFloat(fraction))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private enum ChartLayout {
    static let selectorSpacing: CGFloat = 10
    static let plotHeight: CGFloat = 88
    static let timelineHeight: CGFloat = 110
    static let axisLabelWidth: CGFloat = 20
    static let axisSpacing: CGFloat = LayoutSpacing.compact
    static let weekdayLabelWidth: CGFloat = 10
    static let ruleWidth: CGFloat = 1
    static let tooltipHalfWidth: CGFloat = 76
    static let heatmapHoverOutlineWidth: CGFloat = 1.5
    static let heatmapHoverBleed: CGFloat = heatmapHoverOutlineWidth / 2 + 0.5
    static let hoverAnimation = Animation.easeOut(duration: 0.10)
    static let scaleAnimation = Animation.easeInOut(duration: 0.20)
    static let heatmapHoverAnimation = Animation.easeOut(duration: 0.045)
    static let scrollIndicatorFadeDuration = 0.08
    static let legendRevealDelay = 0.10
}

private struct UsageVisualTheme: Equatable {
    var colorScheme: ColorScheme
    var contrast: ColorSchemeContrast

    // System semantic colors resolve against the effective AppKit appearance
    // and retain vibrancy when composited over the window's local material.
    private var semanticPrimary: Color { Color(nsColor: .textColor) }
    private var semanticSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    private var semanticTertiary: Color { Color(nsColor: .tertiaryLabelColor) }

    var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.31, green: 0.61, blue: 0.84)
            : Color(red: 0.16, green: 0.47, blue: 0.74)
    }

    private var contrastBoost: Double {
        contrast == .increased ? 0.08 : 0
    }

    // Semantic primary keeps vibrancy, so text adapts to whatever shows through the popover.
    var textColor: Color { .primary }

    var errorText: Color {
        Color(nsColor: .systemRed).opacity(contrast == .increased ? 1 : 0.88)
    }

    var emptyMark: Color { semanticPrimary.opacity(0.07 + contrastBoost / 2) }
    var dataMark: Color { accentColor.opacity(min(1, 0.88 + contrastBoost)) }
    var usageFill: Color { accentColor.opacity(min(1, 0.82 + contrastBoost)) }
    var usageTrack: Color { semanticPrimary.opacity(0.10 + contrastBoost / 2) }
    var controlTrack: Color { semanticPrimary.opacity(0.12 + contrastBoost / 2) }
    var controlTick: Color { semanticSecondary.opacity(0.55 + contrastBoost) }
    var chartRule: Color { Color(nsColor: .separatorColor) }
    var scrollIndicator: Color { semanticSecondary.opacity(0.55 + contrastBoost) }
    var popupBorder: Color { semanticTertiary.opacity(0.45 + contrastBoost) }
    var controlShadow: Color { Color(nsColor: .shadowColor).opacity(0.16) }
    var hoverFill: Color { accentColor.opacity(0.10 + contrastBoost / 2) }
    var hoverOutline: Color { accentColor }

    func heatmapMark(normalized: Double) -> Color {
        accentColor.opacity(
            min(1, 0.18 + contrastBoost + min(max(normalized, 0), 1) * 0.70))
    }
}

private struct UsageVisualThemeKey: EnvironmentKey {
    static let defaultValue = UsageVisualTheme(
        colorScheme: .light,
        contrast: .standard)
}

private extension EnvironmentValues {
    var usageVisualTheme: UsageVisualTheme {
        get { self[UsageVisualThemeKey.self] }
        set { self[UsageVisualThemeKey.self] = newValue }
    }
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
    @Environment(\.usageVisualTheme) private var theme

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
        .foregroundStyle(theme.textColor)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// Hides the date legend and shows the scroll indicator while a chart scrolls.
@MainActor
private final class ChartScrollChrome: ObservableObject {
    @Published private(set) var legendHidden = false
    @Published private(set) var indicatorVisible = false
    private var legendRevealTask: Task<Void, Never>?

    func phaseChanged(_ isScrolling: Bool) {
        legendRevealTask?.cancel()
        if isScrolling {
            legendHidden = true
            withAnimation(.linear(duration: 0.04)) {
                indicatorVisible = true
            }
        } else {
            withAnimation(.easeOut(duration: ChartLayout.scrollIndicatorFadeDuration)) {
                indicatorVisible = false
            }
            legendRevealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(ChartLayout.legendRevealDelay))
                guard !Task.isCancelled else { return }
                self?.legendHidden = false
            }
        }
    }

    func cancel() {
        legendRevealTask?.cancel()
    }
}

/// Maximum and zero labels beside a vertical rule.
private struct ChartValueAxis: View {
    var maximum: Int64
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        VStack(alignment: .trailing) {
            Text(DisplayFormatter.compactAxisTokens(maximum))
            Spacer()
            Text("0")
        }
        .font(.caption2)
        .foregroundStyle(theme.textColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: ChartLayout.axisLabelWidth, height: ChartLayout.plotHeight)
        Rectangle()
            .fill(theme.chartRule)
            .frame(width: ChartLayout.ruleWidth, height: ChartLayout.plotHeight)
    }
}

private struct ChartScrollIndicator: View {
    var viewport: ChartViewport
    var isVisible: Bool
    @Environment(\.usageVisualTheme) private var theme

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
                .fill(theme.scrollIndicator)
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
    let columnSpacing = LayoutSpacing.compact * 3 / 8
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
    private let targetDates: [Date]
    private let positionPersistence: ChartPositionPersistence
    @State private var scrollTarget: Date?
    @State private var viewport = ChartViewport()
    @StateObject private var chrome = ChartScrollChrome()
    @Environment(\.usageVisualTheme) private var theme

    init(
        days: [TokenUsageDay],
        positionPersistence: ChartPositionPersistence =
            ChartPositionPersistence()
    ) {
        let model = HeatmapModel(days: days)
        let targetDates = (0..<model.weekCount).map { week in
            min(model.points[min(week * 7 + 6, model.points.count - 1)].date,
                model.latestDate)
        }
        self.model = model
        self.targetDates = targetDates
        self.positionPersistence = positionPersistence
        _scrollTarget = State(initialValue: positionPersistence.restoredPosition(
            for: CodexActivityPeriod.daily.id,
            availableDates: targetDates))
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
        let visibleMaximum = max(visiblePoints.map(\.tokens).max() ?? 0, 1)
        let scaleMaximum = DisplayFormatter.roundedAxisMaximum(visibleMaximum)
        let intensityLegendWidth = ChartLayout.axisLabelWidth
            + LayoutSpacing.compact
            + metrics.cellSize
        let legendDates = threeDates(weekRange.map { week in
            let index = min(week * 7 + 3, model.points.count - 1)
            return min(model.points[index].date, model.latestDate)
        })

        GeometryReader { geometry in
            let availablePlotWidth = max(
                1,
                geometry.size.width
                    - ChartLayout.weekdayLabelWidth
                    - intensityLegendWidth
                    - metrics.labelSpacing * 2)
            let weekStride = metrics.cellSize + metrics.columnSpacing
            let visibleWeekCount = max(
                1,
                Int(floor(
                    (availablePlotWidth + metrics.columnSpacing) / weekStride)))
            let plotWidth = metrics.cellSize * CGFloat(visibleWeekCount)
                + metrics.columnSpacing * CGFloat(visibleWeekCount - 1)
            let trailingGap = metrics.labelSpacing
                + max(0, availablePlotWidth - plotWidth)
            let heatmapHoverBleed = ChartLayout.heatmapHoverBleed

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: metrics.rowSpacing) {
                    let weekdayLabels = ["M", "", "W", "", "F", "", "S"]
                    ForEach(weekdayLabels.indices, id: \.self) { index in
                        Text(weekdayLabels[index])
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textColor)
                            .frame(
                                width: ChartLayout.weekdayLabelWidth,
                                height: metrics.cellSize,
                                alignment: .center)
                        }
                    }
                    .padding(.vertical, heatmapHoverBleed)
                Color.clear
                    .frame(width: metrics.labelSpacing, height: 1)
                ZStack(alignment: .bottom) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                HeatmapGrid(
                                    model: model,
                                    metrics: metrics,
                                    maximum: Double(scaleMaximum))
                                HeatmapHoverOverlay(
                                    model: model,
                                    metrics: metrics,
                                    viewport: viewport,
                                    plotSize: CGSize(
                                        width: metrics.contentWidth,
                                        height: ChartLayout.plotHeight))
                                HStack(spacing: metrics.columnSpacing) {
                                    ForEach(targetDates, id: \.self) { date in
                                        Color.clear
                                            .frame(
                                                width: metrics.cellSize,
                                                height: 1)
                                            .id(date)
                                    }
                                }
                                .scrollTargetLayout()
                                .allowsHitTesting(false)
                            }
                            .frame(width: metrics.contentWidth, height: ChartLayout.plotHeight)
                            .padding(.vertical, heatmapHoverBleed)
                            .frame(
                                width: metrics.contentWidth,
                                height: ChartLayout.plotHeight + heatmapHoverBleed * 2)
                            .frame(height: ChartLayout.timelineHeight, alignment: .top)
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $scrollTarget, anchor: .trailing)
                    .scrollTargetBehavior(CellSnapScrollTargetBehavior(
                        step: metrics.cellSize + metrics.columnSpacing))
                    .trackChartScroll(
                        viewport: $viewport,
                        unitWidth: metrics.cellSize + metrics.columnSpacing,
                        phaseChanged: chrome.phaseChanged)

                    ChartScrollIndicator(
                        viewport: viewport,
                        isVisible: chrome.indicatorVisible)
                        .padding(.horizontal, 2)
                    ChartDateLegend(dates: legendDates, isHidden: chrome.legendHidden)
                        .padding(.horizontal, 2)
                }
                .frame(width: plotWidth)

                Color.clear
                    .frame(width: trailingGap, height: 1)
                HeatmapIntensityLegend(
                    maximum: scaleMaximum,
                    swatchSize: metrics.cellSize,
                    rowSpacing: metrics.rowSpacing)
                    .frame(width: intensityLegendWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily token activity")
        .onChange(of: scrollTarget) { _, newValue in
            positionPersistence.save(
                newValue,
                for: CodexActivityPeriod.daily.id)
        }
        .onDisappear(perform: chrome.cancel)
    }
}

private struct HeatmapGrid: View {
    let model: HeatmapModel
    let metrics: HeatmapMetrics
    let maximum: Double
    @Environment(\.usageVisualTheme) private var theme

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
        .animation(ChartLayout.scaleAnimation, value: maximum)
        .animation(ChartLayout.scaleAnimation, value: model.points.map(\.tokens))
    }

    private func color(for value: Int64) -> Color {
        guard value > 0 else { return theme.emptyMark }
        let normalized = min(1, sqrt(Double(value) / maximum))
        return theme.heatmapMark(normalized: normalized)
    }
}

private struct HeatmapIntensityLegend: View {
    let maximum: Int64
    let swatchSize: CGFloat
    let rowSpacing: CGFloat
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: LayoutSpacing.compact) {
            VStack(alignment: .trailing) {
                Text(DisplayFormatter.compactAxisTokens(maximum))
                Spacer()
                Text("0")
            }
            .font(.system(size: 9))
            .foregroundStyle(theme.textColor)
            .lineLimit(1)
            .frame(width: ChartLayout.axisLabelWidth, height: ChartLayout.plotHeight)

            VStack(spacing: rowSpacing) {
                ForEach(Array((0..<7).reversed()), id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level == 0
                            ? theme.emptyMark
                            : theme.heatmapMark(
                                normalized: Double(level) / 6))
                        .frame(width: swatchSize, height: swatchSize)
                }
            }
        }
        .frame(width: legendWidth, height: ChartLayout.plotHeight, alignment: .topTrailing)
        .contentTransition(.opacity)
        .animation(ChartLayout.scaleAnimation, value: maximum)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Heatmap intensity from 0 to \(DisplayFormatter.compactAxisTokens(maximum)) tokens")
    }

    private var legendWidth: CGFloat {
        ChartLayout.axisLabelWidth + LayoutSpacing.compact + swatchSize
    }

}

private struct HeatmapHoverOverlay: View {
    let model: HeatmapModel
    let metrics: HeatmapMetrics
    let viewport: ChartViewport
    let plotSize: CGSize
    @State private var hoveredIndex: Int?
    @State private var highlightedIndex: Int
    @Environment(\.usageVisualTheme) private var theme

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
        _hoveredIndex = State(initialValue: nil)
        _highlightedIndex = State(initialValue: 0)
    }

    var body: some View {
        let activeIndex = hoveredIndex
        ZStack(alignment: .topLeading) {
            Color.clear

            let center = metrics.cellCenter(at: highlightedIndex)
            RoundedRectangle(cornerRadius: 2)
                .stroke(theme.hoverOutline, lineWidth: ChartLayout.heatmapHoverOutlineWidth)
                .frame(width: metrics.cellSize, height: metrics.cellSize)
                .position(center)
                .opacity(activeIndex == nil ? 0 : 1)
                .scaleEffect(activeIndex == nil ? 0.92 : 1)
                .animation(ChartLayout.heatmapHoverAnimation, value: activeIndex != nil)

            if let activeIndex, model.points.indices.contains(activeIndex) {
                let activeCenter = metrics.cellCenter(at: activeIndex)
                let tooltipText = model.points[activeIndex].label
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

    private func updateHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        if let index {
            highlightedIndex = index
        }
        hoveredIndex = index
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
    private let positionPersistence: ChartPositionPersistence
    @State private var scrollTarget: Date?
    @State private var hoveredIndex: Int?
    @State private var viewport = ChartViewport()
    @StateObject private var chrome = ChartScrollChrome()
    @Environment(\.usageVisualTheme) private var theme

    init(
        buckets: [TokenWeekBucket],
        positionPersistence: ChartPositionPersistence =
            ChartPositionPersistence()
    ) {
        self.buckets = buckets
        self.positionPersistence = positionPersistence
        _scrollTarget = State(initialValue: positionPersistence.restoredPosition(
            for: CodexActivityPeriod.weekly.id,
            availableDates: buckets.map(\.startDate)))
    }

    var body: some View {
        let range = visibleIndexRange(
            count: buckets.count,
            viewport: viewport,
            defaultVisibleCount: 24)
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
            ChartValueAxis(maximum: maximumValue)
            GeometryReader { geometry in
                // Each bar is exactly one heatmap day cell wide, with the same gap.
                let cell = HeatmapMetrics(
                    size: CGSize(width: 0, height: ChartLayout.plotHeight),
                    weekCount: 1)
                let columnWidth = cell.cellSize + cell.columnSpacing
                let barsWidth = columnWidth * CGFloat(max(1, buckets.count))
                // Too few weeks to fill the chart: keep bars at the recent (trailing) edge.
                let contentWidth = max(barsWidth, geometry.size.width)
                let leadingInset = contentWidth - barsWidth

                ZStack(alignment: .bottom) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(buckets.indices, id: \.self) { index in
                                    Color.clear
                                        .frame(width: columnWidth, height: 1)
                                        .id(buckets[index].startDate)
                                }
                            }
                            .scrollTargetLayout()
                            .frame(width: contentWidth, height: ChartLayout.plotHeight, alignment: .trailing)
                            .overlay(alignment: .topLeading) {
                                ZStack(alignment: .topLeading) {
                                    let activeIndex = hoveredIndex
                                    let highlightIndex = activeIndex ?? 0
                                    Rectangle()
                                        .fill(theme.hoverFill)
                                        .frame(width: columnWidth, height: ChartLayout.plotHeight)
                                        .position(
                                            x: leadingInset + (CGFloat(highlightIndex) + 0.5) * columnWidth,
                                            y: ChartLayout.plotHeight / 2)
                                        .opacity(activeIndex == nil ? 0 : 1)
                                        .animation(ChartLayout.hoverAnimation, value: hoveredIndex)

                                    HStack(alignment: .bottom, spacing: 0) {
                                        ForEach(buckets.indices, id: \.self) { index in
                                            let bucket = buckets[index]
                                            let fraction = CGFloat(
                                                Double(bucket.tokens) / Double(maximumValue))
                                            RoundedRectangle(cornerRadius: 1.5)
                                                .fill(theme.dataMark)
                                                .frame(width: cell.cellSize)
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
                                        alignment: .bottomTrailing)
                                    .animation(
                                        ChartLayout.scaleAnimation,
                                        value: maximumValue)

                                    if let activeIndex, buckets.indices.contains(activeIndex) {
                                        let centerX = leadingInset + (CGFloat(activeIndex) + 0.5) * columnWidth
                                        ChartHoverLabel(text: weekHelp(buckets[activeIndex]))
                                            .position(
                                                x: viewportTooltipX(
                                                    centerX,
                                                    viewport: viewport,
                                                    contentWidth: contentWidth),
                                                y: 12)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    updateHoveredIndex(bucketIndex(
                                        at: location.x - leadingInset,
                                        width: barsWidth))
                                case .ended:
                                    updateHoveredIndex(nil)
                                }
                            }
                            .frame(height: ChartLayout.timelineHeight, alignment: .top)
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $scrollTarget, anchor: .trailing)
                    .scrollTargetBehavior(CellSnapScrollTargetBehavior(step: columnWidth))
                    .trackChartScroll(
                        viewport: $viewport,
                        unitWidth: columnWidth,
                        phaseChanged: chrome.phaseChanged)

                    ChartScrollIndicator(
                        viewport: viewport,
                        isVisible: chrome.indicatorVisible)
                        .padding(.horizontal, 2)
                    ChartDateLegend(dates: legendDates, isHidden: chrome.legendHidden)
                        .padding(.horizontal, 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekly token activity")
        .onChange(of: scrollTarget) { _, newValue in
            positionPersistence.save(
                newValue,
                for: CodexActivityPeriod.weekly.id)
        }
        .onDisappear(perform: chrome.cancel)
    }

    private func weekHelp(_ bucket: TokenWeekBucket) -> String {
        let start = bucket.startDate.formatted(.dateTime.month(.abbreviated).day())
        let end = bucket.endDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(start)–\(end) · \(DisplayFormatter.compactTokens(bucket.tokens))"
    }

    private func bucketIndex(at x: CGFloat, width: CGFloat) -> Int? {
        guard !buckets.isEmpty, width > 0, x >= 0, x <= width else { return nil }
        return min(Int(x / width * CGFloat(buckets.count)), buckets.count - 1)
    }

    private func updateHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
    }
}

private struct TokenCumulativeLine: View {
    private let points: [TokenPlotPoint]
    private let positionPersistence: ChartPositionPersistence
    @State private var hoverLocation: CGPoint?
    @State private var scrollTarget: Date?
    @State private var viewport = ChartViewport()
    @StateObject private var chrome = ChartScrollChrome()
    @Environment(\.usageVisualTheme) private var theme

    init(
        days: [TokenUsageDay],
        positionPersistence: ChartPositionPersistence =
            ChartPositionPersistence()
    ) {
        var total: Int64 = 0
        let points: [TokenPlotPoint] = days
            .sorted { $0.startDate < $1.startDate }
            .compactMap { day in
            guard let date = day.date else { return nil }
            total += day.tokens
            return TokenPlotPoint(date: date, tokens: total)
            }
        self.points = points
        self.positionPersistence = positionPersistence
        _hoverLocation = State(initialValue: nil)
        _scrollTarget = State(initialValue: positionPersistence.restoredPosition(
            for: CodexActivityPeriod.cumulative.id,
            availableDates: points.map(\.date)))
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
            ChartValueAxis(maximum: maximumValue)
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
                                TokenCumulativePath(
                                    points: points,
                                    maximumValue: Double(maximumValue))
                                .stroke(
                                    theme.dataMark,
                                    style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                                .animation(
                                    ChartLayout.scaleAnimation,
                                    value: maximumValue)

                                if let activeLocation,
                                   let activeIndex,
                                   points.indices.contains(activeIndex)
                                {
                                    Rectangle()
                                        .fill(theme.scrollIndicator)
                                        .frame(width: 1, height: ChartLayout.plotHeight)
                                        .position(
                                            x: activeLocation.x,
                                            y: ChartLayout.plotHeight / 2)

                                    Circle()
                                        .fill(theme.hoverOutline)
                                        .overlay(Circle().stroke(
                                            .background,
                                            lineWidth: 1.5))
                                        .frame(width: 7, height: 7)
                                        .position(
                                            x: activeLocation.x,
                                            y: interpolatedY(
                                                at: activeLocation.x,
                                                points: points,
                                                maximumValue: maximumValue,
                                                size: plotSize))
                                        .animation(
                                            ChartLayout.scaleAnimation,
                                            value: maximumValue)

                                    ChartHoverLabel(text: points[activeIndex].label)
                                        .position(
                                            x: tooltipX(
                                                activeLocation.x,
                                                contentWidth: contentWidth),
                                            y: 12)
                                }

                                HStack(spacing: 0) {
                                    ForEach(points) { point in
                                        Color.clear
                                            .frame(
                                                width: contentWidth
                                                    / CGFloat(max(1, points.count)),
                                                height: 1)
                                            .id(point.date)
                                    }
                                }
                                .scrollTargetLayout()
                                .allowsHitTesting(false)
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
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $scrollTarget, anchor: .trailing)
                    .trackChartScroll(
                        viewport: $viewport,
                        unitWidth: contentWidth / CGFloat(max(1, points.count)),
                        phaseChanged: chrome.phaseChanged)

                    ChartScrollIndicator(
                        viewport: viewport,
                        isVisible: chrome.indicatorVisible)
                        .padding(.horizontal, 2)
                    ChartDateLegend(dates: legendDates, isHidden: chrome.legendHidden)
                        .padding(.horizontal, 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cumulative token activity")
        .onChange(of: scrollTarget) { _, newValue in
            positionPersistence.save(
                newValue,
                for: CodexActivityPeriod.cumulative.id)
        }
        .onDisappear(perform: chrome.cancel)
    }


    private func resolvedHoverLocation(in size: CGSize) -> CGPoint? {
        guard let hoverLocation else { return nil }
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

private struct ChartHoverLabel: View {
    var text: String
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(theme.textColor)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, LayoutSpacing.inset)
            .padding(.vertical, LayoutSpacing.compact)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.popupBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 5, x: 0, y: 2)
            .allowsHitTesting(false)
    }
}

struct ResetSummaryHoverLabel: View {
    var summary: String
    var expirationHelp: String

    @State private var isHovering = false
    @State private var showsPopup = false
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        Text(summary)
            .foregroundStyle(theme.textColor)
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
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.textColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.popupBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .allowsHitTesting(false)
    }
}

struct UsageBar: View {
    var label: String
    var limit: UsageLimit?
    @Environment(\.usageVisualTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundStyle(theme.textColor)
                if let refreshText {
                    Text(refreshText)
                        .foregroundStyle(theme.textColor)
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
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.usageTrack)
                    Capsule()
                        .fill(theme.usageFill)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) remaining")
            .accessibilityValue(percentText)
        }
    }

    private var percentText: String {
        guard let limit else { return "--" }
        return DisplayFormatter.percent(limit.remainingPercent)
    }

    private var refreshText: String? {
        limit?.resetsAt.map { "Refreshes \(DisplayFormatter.rateLimitResetDate($0))" }
    }

    private var progress: Double {
        guard let limit else { return 0 }
        return max(0, min(1, limit.remainingPercent / 100))
    }
}
