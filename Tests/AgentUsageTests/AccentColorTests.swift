import AppKit
import Testing
@testable import AgentUsage

struct AccentColorTests {
    @Test func storedChoicesRoundTrip() {
        #expect(AccentChoice(stored: "") == .system, "no setting follows the system accent")
        #expect(AccentChoice(stored: "system") == .system)
        #expect(AccentChoice(stored: "0.2,0.5") == .system, "the earlier two-part format is dropped")
        let custom = AccentChoice.custom(hue: 0.25, chroma: 0.5, tone: -0.3)
        #expect(AccentChoice(stored: custom.stored) == custom)
        #expect(AccentChoice(stored: "1.4,-2,3") == .custom(hue: 1, chroma: 0, tone: 1), "values are clamped")
    }

    /// Every accent reaches 3:1, the WCAG minimum for graphics, against the
    /// popover: a light one in light mode and a dark one in dark mode.
    @Test(arguments: [false, true])
    func everyAccentContrastsWithThePopover(dark: Bool) {
        let popover = dark ? 0.025 : 0.75
        for choice in Self.choices + [.system] {
            let contrast = Self.contrast(relativeLuminance(choice.nsColor(dark: dark)), popover)
            #expect(contrast >= 3, "\(choice.stored) at \(contrast)")
        }
    }

    /// Marks drawn on the accent, like the pace marker, contrast with it and
    /// keep its hue, with one polarity per appearance as in Material's on-colors.
    @Test(arguments: [false, true])
    func inkContrastsWithTheAccentInItsHue(dark: Bool) {
        for choice in Self.choices + [.system] {
            let accent = choice.nsColor(dark: dark)
            let ink = choice.inkColor(dark: dark)
            #expect(Self.contrast(relativeLuminance(accent), relativeLuminance(ink)) >= 3, "\(choice.stored)")
            #expect((relativeLuminance(ink) > relativeLuminance(accent)) == !dark, "light ink in light mode")
            let accentLCH = AccentChoice.oklch(accent)
            let inkLCH = AccentChoice.oklch(ink)
            if accentLCH.chroma > 0.05 {
                let difference = abs(accentLCH.hue - inkLCH.hue)
                #expect(min(difference, 1 - difference) < 0.03, "\(choice.stored) ink keeps the hue")
            }
        }
    }

    /// Perceptual lightness keeps hues equally strong: at the default tone,
    /// yellow and blue differ far less in luminance than in plain HSB.
    @Test func huesShareLightnessAtDefaultTone() {
        let yellow = relativeLuminance(AccentChoice.nsColor(hue: 0.25, chroma: 1, tone: 0, dark: false))
        let blue = relativeLuminance(AccentChoice.nsColor(hue: 0.73, chroma: 1, tone: 0, dark: false))
        #expect(abs(yellow - blue) < 0.12)
    }

    @Test func toneReachesDarkAndLightColors() {
        let navy = relativeLuminance(AccentChoice.nsColor(hue: 0.73, chroma: 0.6, tone: -1, dark: false))
        #expect(navy < 0.08, "a dark navy is reachable")
        let yellow = AccentChoice.nsColor(hue: 0.27, chroma: 1, tone: 1, dark: true).usingColorSpace(.sRGB)!
        #expect(yellow.redComponent > 0.75 && yellow.greenComponent > 0.65 && yellow.blueComponent < 0.2,
                "a clear yellow is reachable in dark mode")
        let gold = AccentChoice.nsColor(hue: 0.27, chroma: 1, tone: 1, dark: false).usingColorSpace(.sRGB)!
        #expect(gold.redComponent > gold.greenComponent && gold.greenComponent > gold.blueComponent,
                "and deepens to gold in light mode")
    }

    private static let choices: [AccentChoice] = stride(from: 0.0, through: 1, by: 1.0 / 24).flatMap { hue in
        stride(from: 0.0, through: 1, by: 0.25).flatMap { chroma in
            stride(from: -1.0, through: 1, by: 0.5).map { tone in
                AccentChoice.custom(hue: hue, chroma: chroma, tone: tone)
            }
        }
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func presetsAreDistinct() {
        let stored = AccentChoice.presets.map(\.choice.stored)
        #expect(Set(stored).count == stored.count)
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}

struct AccentHistoryTests {
    private let blue = AccentChoice.custom(hue: 0.7, chroma: 0.8, tone: 0)
    private let red = AccentChoice.custom(hue: 0.08, chroma: 0.8, tone: 0)
    private let navy = AccentChoice.custom(hue: 0.7, chroma: 0.5, tone: -0.7)

    @Test func undoAndRedoStepThroughRecordedActions() {
        var history = AccentHistory(.system)
        #expect(!history.canUndo && !history.canRedo)
        history.record(blue)
        history.record(red)
        #expect(history.undo() == blue)
        #expect(history.undo() == .system)
        #expect(history.undo() == nil, "nothing before the first state")
        #expect(history.redo() == blue)
        #expect(history.redo() == red)
        #expect(history.redo() == nil)
    }

    @Test func recordingAfterUndoDropsTheRedoBranch() {
        var history = AccentHistory(.system)
        history.record(blue)
        history.record(red)
        _ = history.undo()
        history.record(navy)
        #expect(!history.canRedo)
        #expect(history.undo() == blue)
    }

    @Test func repeatedValuesAreNotSeparateSteps() {
        var history = AccentHistory(blue)
        history.record(blue)
        #expect(!history.canUndo, "a drag released where it started is not an action")
    }
}
