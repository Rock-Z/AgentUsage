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

    /// Accents must read against the popover: darker than a light background
    /// and lighter than a dark one, for every hue, colorfulness, and tone.
    @Test(arguments: [false, true])
    func everyChoiceStaysReadable(dark: Bool) {
        for hue in stride(from: 0.0, through: 1, by: 1.0 / 24) {
            for chroma in stride(from: 0.0, through: 1, by: 0.25) {
                for tone in stride(from: -1.0, through: 1, by: 0.5) {
                    let luminance = relativeLuminance(AccentChoice.nsColor(hue: hue, chroma: chroma, tone: tone, dark: dark))
                    if dark {
                        #expect(luminance >= 0.17, "hue \(hue) chroma \(chroma) tone \(tone)")
                    } else {
                        #expect(luminance <= 0.52, "hue \(hue) chroma \(chroma) tone \(tone)")
                    }
                }
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
        let yellow = AccentChoice.nsColor(hue: 0.27, chroma: 1, tone: 1, dark: false).usingColorSpace(.sRGB)!
        #expect(navy < 0.08, "a dark navy is reachable")
        #expect(yellow.redComponent > 0.75 && yellow.greenComponent > 0.65 && yellow.blueComponent < 0.2,
                "a clear yellow is reachable, even in light mode")
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
