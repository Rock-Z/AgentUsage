import AppKit
import SwiftUI

/// The app's accent: the macOS accent color, or a point on the Arc-style pad
/// plus a tone.
///
/// As in Arc, the pad chooses hue (x) and colorfulness (y) while lightness
/// comes from the appearance, the way Apple's system colors have a light and a
/// dark variant. Colors are built in OKLCH, a perceptual space, so every hue
/// reads equally strong at the same lightness. The tone slider shifts
/// lightness darker or lighter within limits that keep 3:1 contrast with the
/// popover, so light mode has no pastels: yellow deepens to gold, as macOS's
/// own colors do.
enum AccentChoice: Equatable, Sendable {
    case system
    /// All components are 0...1 except `tone`, which is -1 (darker) ... 1 (lighter).
    case custom(hue: Double, chroma: Double, tone: Double)

    static func clamped(hue: Double, chroma: Double, tone: Double = 0) -> AccentChoice {
        .custom(
            hue: min(max(hue, 0), 1),
            chroma: min(max(chroma, 0), 1),
            tone: min(max(tone, -1), 1))
    }

    /// Reads "system" or "hue,chroma,tone"; anything else follows the system.
    init(stored: String) {
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        self = parts.count == 3 ? .clamped(hue: parts[0], chroma: parts[1], tone: parts[2]) : .system
    }

    var stored: String {
        switch self {
        case .system: "system"
        case let .custom(hue, chroma, tone): "\(hue),\(chroma),\(tone)"
        }
    }

    static let presets: [(name: String, choice: AccentChoice)] = [
        ("Blue", .custom(hue: 0.71, chroma: 0.75, tone: 0)),
        ("Purple", .custom(hue: 0.84, chroma: 0.7, tone: 0)),
        ("Pink", .custom(hue: 0.97, chroma: 0.7, tone: 0.25)),
        ("Red", .custom(hue: 0.08, chroma: 0.85, tone: 0)),
        ("Orange", .custom(hue: 0.14, chroma: 0.8, tone: 0.2)),
        ("Yellow", .custom(hue: 0.27, chroma: 1, tone: 1)),
        ("Green", .custom(hue: 0.41, chroma: 0.7, tone: 0)),
        ("Teal", .custom(hue: 0.53, chroma: 0.6, tone: 0)),
        ("Navy", .custom(hue: 0.73, chroma: 0.55, tone: -0.7)),
        ("Graphite", .custom(hue: 0.7, chroma: 0.08, tone: -0.2)),
    ]

    func color(dark: Bool) -> Color {
        Color(nsColor: nsColor(dark: dark))
    }

    /// The accent for an appearance. The macOS accent keeps its hue and
    /// colorfulness but is brought into the same readable lightness range.
    func nsColor(dark: Bool) -> NSColor {
        let (lightness, chroma, hue) = oklch(dark: dark)
        let rgb = Self.srgb(lightness: lightness, chroma: chroma, hue: hue)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    /// Ink for marks drawn on the accent: its own hue, pale in light mode and
    /// deep in dark mode, like Material's on-primary colors. One polarity per
    /// appearance, so the ink never flips as the accent changes.
    func inkColor(dark: Bool) -> NSColor {
        let hue = oklch(dark: dark).hue
        let rgb = Self.srgb(lightness: dark ? 0.26 : 0.97, relativeChroma: 0.35, hue: hue)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    private func oklch(dark: Bool) -> (lightness: Double, chroma: Double, hue: Double) {
        switch self {
        case let .custom(hue, chroma, tone):
            let lightness = Self.lightness(tone: tone, dark: dark)
            return (lightness, chroma * Self.maximumChroma(lightness: lightness, hue: hue), hue)
        case .system:
            // The system accent varies by appearance; resolve it for this one.
            var resolved = NSColor.controlAccentColor
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? resolved
            }
            let system = Self.oklch(resolved)
            let range = Self.lightnessRange(dark: dark)
            let lightness = min(max(system.lightness, range.lowerBound), range.upperBound)
            return (lightness, min(system.chroma, Self.maximumChroma(lightness: lightness, hue: system.hue)), system.hue)
        }
    }

    /// OKLCH lightness for the appearance, shifted by tone within the range
    /// that keeps 3:1 contrast with a light or dark popover.
    static func lightness(tone: Double, dark: Bool) -> Double {
        let range = lightnessRange(dark: dark)
        let middle = (range.lowerBound + range.upperBound) / 2
        return middle + min(max(tone, -1), 1) * (range.upperBound - range.lowerBound) / 2
    }

    static func lightnessRange(dark: Bool) -> ClosedRange<Double> {
        dark ? 0.64...0.88 : 0.38...0.58
    }

    static func nsColor(hue: Double, chroma: Double, tone: Double, dark: Bool) -> NSColor {
        let rgb = srgb(lightness: lightness(tone: tone, dark: dark), relativeChroma: chroma, hue: hue)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    typealias RGB = (r: Double, g: Double, b: Double)

    /// OKLCH to sRGB with chroma relative to the most colorful color the
    /// screen can show for that hue and lightness, so 1 is always a hue's most
    /// vivid version and the field has no gamut-edge lobes.
    static func srgb(lightness: Double, relativeChroma: Double, hue: Double) -> RGB {
        srgb(lightness: lightness, chroma: relativeChroma * maximumChroma(lightness: lightness, hue: hue), hue: hue)
    }

    /// An in-gamut OKLCH color (chroma no greater than `maximumChroma`).
    static func srgb(lightness: Double, chroma: Double, hue: Double) -> RGB {
        encode(linearSRGB(lightness: lightness, chroma: chroma, hue: hue) ?? (lightness, lightness, lightness))
    }

    /// The most colorful chroma the screen can show for a hue and lightness.
    static func maximumChroma(lightness: Double, hue: Double) -> Double {
        var low = 0.0
        var high = 0.4
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if linearSRGB(lightness: lightness, chroma: middle, hue: hue) != nil {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// Linear sRGB, or nil when out of gamut (Björn Ottosson's OKLab matrices).
    private static func linearSRGB(lightness: Double, chroma: Double, hue: Double) -> RGB? {
        let a = chroma * cos(hue * 2 * .pi)
        let b = chroma * sin(hue * 2 * .pi)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let rgb = (
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        let tolerance = 1e-4
        let inGamut = [rgb.r, rgb.g, rgb.b].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        return inGamut ? rgb : nil
    }

    /// OKLCH of a color, with hue as a fraction of a turn.
    static func oklch(_ color: NSColor) -> (lightness: Double, chroma: Double, hue: Double) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0.5, 0, 0) }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(srgb.redComponent), linear(srgb.greenComponent), linear(srgb.blueComponent))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(bb, a) / (2 * .pi)
        return (lightness, hypot(a, bb), hue < 0 ? hue + 1 : hue)
    }

    private static func encode(_ rgb: RGB) -> RGB {
        func gamma(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return (gamma(rgb.r), gamma(rgb.g), gamma(rgb.b))
    }
}

/// Undo history for accent changes: one entry per completed action (a
/// preset click, a finished drag, a System toggle), not per drag update.
struct AccentHistory: Equatable {
    private var entries: [AccentChoice]
    private var index = 0

    init(_ initial: AccentChoice) {
        entries = [initial]
    }

    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < entries.count - 1 }

    /// Records the result of an action; an unchanged value is not a step.
    mutating func record(_ choice: AccentChoice) {
        guard choice != entries[index] else { return }
        entries = Array(entries[...index]) + [choice]
        index += 1
    }

    mutating func undo() -> AccentChoice? {
        guard canUndo else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func redo() -> AccentChoice? {
        guard canRedo else { return nil }
        index += 1
        return entries[index]
    }
}

/// The Options accent cells: a System switch that follows the macOS accent,
/// and a color pill that opens the picker once System is off. Placed in a
/// GridRow, the four views line up with the other options' label and switch
/// columns. The last custom color
/// is remembered, so turning System back off restores it.
struct AccentOptionRow: View {
    @Binding var choice: AccentChoice
    /// Whether a click at this point, in the window's coordinates, closes the
    /// picker at once instead of fading it out.
    var closesPickerAtOnce: (CGPoint) -> Bool = { _ in false }
    @AppStorage("accentCustomColor") private var lastCustomRaw = AccentChoice.presets[0].choice.stored
    @State private var isPicking = false
    /// Lives as long as the Options popover, across picker opens.
    @State private var history: AccentHistory?
    @Environment(\.colorScheme) private var colorScheme

    private var lastCustom: AccentChoice {
        let stored = AccentChoice(stored: lastCustomRaw)
        return stored == .system ? AccentChoice.presets[0].choice : stored
    }

    var body: some View {
        let followsSystem = choice == .system
        Group {
            Text("System")
                .fixedSize()
                .accessibilityHidden(true)
            Toggle("Follow system accent color", isOn: Binding(
                get: { followsSystem },
                set: { system in apply(system ? .system : lastCustom) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.trailing, 14)
            Text("Color")
                .fixedSize()
                .foregroundStyle(followsSystem ? .tertiary : .primary)
                .accessibilityHidden(true)
            Button {
                isPicking.toggle()
            } label: {
                Capsule()
                    .fill(choice.color(dark: colorScheme == .dark))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 30, height: 16)
                    .opacity(followsSystem ? 0.45 : 1)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(followsSystem)
            .help(followsSystem ? "Turn off System to choose a color" : "Choose a color")
            .accessibilityLabel("Accent color")
            .background(PickerPopover(isPresented: $isPicking, closesAtOnce: closesPickerAtOnce) {
                AccentPickerPanel(
                    choice: $choice,
                    record: { record($0) },
                    undo: undo,
                    redo: redo)
            })
        }
        .onChange(of: choice) { _, newValue in
            if newValue != .system { lastCustomRaw = newValue.stored }
        }
    }

    /// Sets the choice as one undoable action.
    private func apply(_ newValue: AccentChoice) {
        var current = history ?? AccentHistory(choice)
        choice = newValue
        current.record(newValue)
        history = current
    }

    /// Records a completed action whose value the picker has already set.
    /// `before` is the choice when the action started.
    private func record(_ action: (before: AccentChoice, after: AccentChoice)) {
        var current = history ?? AccentHistory(action.before)
        current.record(action.after)
        history = current
    }

    private func undo() {
        guard var current = history, let previous = current.undo() else { return }
        history = current
        choice = previous
    }

    private func redo() {
        guard var current = history, let next = current.redo() else { return }
        history = current
        choice = next
    }
}

/// Shows the picker in an AppKit popover beside the view it backs.
///
/// SwiftUI's `.popover` finishes dismissing about half a second after its
/// window closes, and resizing the menu bar window in that time (as the
/// Options fold does) folds from the wrong edge. An `NSPopover` is gone as
/// soon as it closes.
private struct PickerPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var closesAtOnce: (CGPoint) -> Bool
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.close = { isPresented = false }
        coordinator.closesAtOnce = closesAtOnce
        coordinator.anchor = view
        if let host = coordinator.popover?.contentViewController as? NSHostingController<Content> {
            host.rootView = content()
        }
        if isPresented, coordinator.popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: content())
            popover.delegate = coordinator
            coordinator.popover = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
        } else if !isPresented {
            coordinator.popover?.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var close: () -> Void = {}
        var closesAtOnce: (CGPoint) -> Bool = { _ in false }
        weak var anchor: NSView?

        /// A fading popover holds on to key status for about half a second,
        /// and a menu bar window resized meanwhile grows or shrinks from the
        /// wrong edge. Clicks that resize it close the popover at once.
        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown,
               let host = hostingView,
               event.window === host.window
            {
                // SwiftUI's global coordinates are the hosting view's.
                popover.animates = !closesAtOnce(host.convert(event.locationInWindow, from: nil))
            }
            return true
        }

        private var hostingView: NSView? {
            sequence(first: anchor, next: { $0?.superview })
                .compactMap { $0 }
                .last { String(describing: type(of: $0)).contains("HostingView") }
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            close()
        }
    }
}

/// Arc-style picker: preset swatches, a dot-grid color field whose handle
/// picks hue (x) and colorfulness (y), and a tone slider below.
struct AccentPickerPanel: View {
    @Binding var choice: AccentChoice
    /// Called once per completed action with the choice before and after it.
    var record: ((before: AccentChoice, after: AccentChoice)) -> Void = { _ in }
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    /// The choice when the current drag began, for its undo step.
    @State private var dragStart: AccentChoice?
    /// The handle follows every pointer move from this local state; the stored
    /// choice, which recolors the popover, is written at most every
    /// `commitInterval` and once when the drag ends.
    @State private var dragChoice: AccentChoice?
    /// The tone while its slider is dragged, committed like pad drags.
    @State private var dragTone: Double?
    @State private var lastCommit = Date.distantPast
    @Environment(\.colorScheme) private var colorScheme

    private static let commitInterval: TimeInterval = 0.05
    private static let swatchSize: CGFloat = 20
    private static let swatchSpacing: CGFloat = 5
    /// As wide as the row of preset swatches above it.
    static let padSize = CGSize(
        width: CGFloat(AccentChoice.presets.count) * (swatchSize + 5)
            + CGFloat(AccentChoice.presets.count - 1) * swatchSpacing,
        height: 150)

    private var isDark: Bool { colorScheme == .dark }
    private var shown: AccentChoice {
        guard let dragTone, case let .custom(hue, chroma, _) = dragChoice ?? choice else {
            return dragChoice ?? choice
        }
        return .custom(hue: hue, chroma: chroma, tone: dragTone)
    }
    /// A system choice starts the pad and slider from a neutral blue.
    private var editable: (hue: Double, chroma: Double, tone: Double) {
        if case let .custom(hue, chroma, tone) = shown { return (hue, chroma, tone) }
        return (0.71, 0.75, dragTone ?? 0)
    }

    /// Writes the stored choice at most every `commitInterval` while dragging.
    private func commitThrottled(_ picked: AccentChoice) {
        let now = Date()
        if now.timeIntervalSince(lastCommit) >= Self.commitInterval {
            choice = picked
            lastCommit = now
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Self.swatchSpacing) {
                ForEach(AccentChoice.presets, id: \.name) { preset in
                    swatch(name: preset.name, choice: preset.choice)
                }
            }
            pad
            toneSlider
        }
        .padding(14)
        .background {
            // No Edit menu in a menu bar app, so bind the shortcuts here.
            Group {
                Button("Undo", action: undo).keyboardShortcut("z", modifiers: .command)
                Button("Redo", action: redo).keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func swatch(name: String, choice option: AccentChoice) -> some View {
        let selected = option == choice
        return Button {
            let before = choice
            choice = option
            record((before, option))
        } label: {
            Circle()
                .fill(option.color(dark: isDark))
                .padding(2.5)
                .overlay {
                    Circle().strokeBorder(selected ? Color.primary.opacity(0.55) : .clear, lineWidth: 1.5)
                }
                .frame(width: Self.swatchSize + 5, height: Self.swatchSize + 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pad: some View {
        let size = Self.padSize
        let current = editable
        return ZStack(alignment: .topLeading) {
            // Recomputed only when tone or appearance changes, never while dragging.
            Image(nsImage: ColorFieldImage.image(tone: current.tone, dark: isDark))
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay(DotGrid())
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))

            if shown != .system {
                Circle()
                    .fill(shown.color(dark: isDark))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .frame(width: 24, height: 24)
                    .position(Self.point(hue: current.hue, chroma: current.chroma, in: size))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = choice }
                let picked = Self.choice(at: value.location, in: size, tone: current.tone)
                dragChoice = picked
                commitThrottled(picked)
            }
            .onEnded { value in
                let picked = Self.choice(at: value.location, in: size, tone: current.tone)
                choice = picked
                record((dragStart ?? picked, picked))
                dragStart = nil
                dragChoice = nil
            })
        .accessibilityElement()
        .accessibilityLabel("Color field")
        .accessibilityHint("Drag to choose a hue and how colorful it is, or pick a swatch above.")
    }

    /// Arc's second control: shifts the accent darker or lighter.
    private var toneSlider: some View {
        let current = editable
        return HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { current.tone },
                    set: { tone in
                        if dragStart == nil { dragStart = choice }
                        dragTone = tone
                        commitThrottled(.clamped(hue: current.hue, chroma: current.chroma, tone: tone))
                    }),
                in: -1...1
            ) {
                Text("Tone")
            } onEditingChanged: { editing in
                guard !editing, let tone = dragTone else { return }
                let picked = AccentChoice.clamped(hue: current.hue, chroma: current.chroma, tone: tone)
                choice = picked
                record((dragStart ?? picked, picked))
                dragStart = nil
                dragTone = nil
            }
            .labelsHidden()
            .controlSize(.small)
            // AppKit's focus ring would stay where the thumb was when focused.
            .focusable(false)
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tone, darker to lighter")
    }

    /// Hue runs left to right; colorfulness runs from vivid at the top to muted at the bottom.
    static func choice(at point: CGPoint, in size: CGSize, tone: Double) -> AccentChoice {
        .clamped(
            hue: Double(point.x / size.width),
            chroma: Double(1 - point.y / size.height),
            tone: tone)
    }

    static func point(hue: Double, chroma: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: hue * size.width, y: (1 - chroma) * size.height)
    }
}

/// The pad's color field as a small bitmap, cached per tone and appearance.
/// It is drawn once and scaled up smoothly; the field is smooth, so a coarse
/// grid of samples looks identical to per-pixel colors.
enum ColorFieldImage {
    private static let columns = 96
    private static let rows = 40
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(tone: Double, dark: Bool) -> NSImage {
        // Tone is quantized so slider drags reuse images instead of piling them up.
        let key = "\(Int((tone * 40).rounded()))-\(dark)"
        if let cached = cache[key] { return cached }
        let lightness = AccentChoice.lightness(tone: tone, dark: dark)
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        // The gamut limit depends only on hue, so it is found once per column.
        for column in 0..<columns {
            let hue = (Double(column) + 0.5) / Double(columns)
            let limit = AccentChoice.maximumChroma(lightness: lightness, hue: hue)
            for row in 0..<rows {
                let relative = 1 - (Double(row) + 0.5) / Double(rows)
                let rgb = AccentChoice.srgb(lightness: lightness, chroma: relative * limit, hue: hue)
                let offset = (row * columns + column) * 4
                pixels[offset] = UInt8((rgb.r * 255).rounded())
                pixels[offset + 1] = UInt8((rgb.g * 255).rounded())
                pixels[offset + 2] = UInt8((rgb.b * 255).rounded())
            }
        }
        let cgImage = CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let image = NSImage(cgImage: cgImage, size: NSSize(width: columns, height: rows))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Arc's dot grid over the color field.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 12
            var x = spacing / 2
            while x < size.width {
                var y = spacing / 2
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(.white.opacity(0.22)))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
