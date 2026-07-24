import AppKit

func onScreenWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let value = window[kCGWindowBounds as String] else { return nil }
    let dictionary = value as! CFDictionary
    var bounds = CGRect.zero
    return CGRectMakeWithDictionaryRepresentation(dictionary, &bounds) ? bounds : nil
}

func postClick(at point: CGPoint) {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left)?.post(tap: .cghidEventTap)
}

func agentUsageWindows(layer: Int) -> [(CGRect, [String: Any])] {
    onScreenWindows().compactMap { window in
        guard window[kCGWindowOwnerName as String] as? String == "AgentUsage",
              window[kCGWindowLayer as String] as? Int == layer,
              let bounds = windowBounds(window)
        else {
            return nil
        }
        return (bounds, window)
    }
}

let utilityCommand = CommandLine.arguments.dropFirst().first
if utilityCommand == "click-primary-status" {
    guard let status = agentUsageWindows(layer: 25)
        .map(\.0)
        .first(where: { $0.midX >= 0 && $0.midX < 1_800 && $0.midY >= 0 })
    else {
        fputs("Could not find the primary-display AgentUsage status item.\n", stderr)
        Foundation.exit(1)
    }
    postClick(at: CGPoint(x: status.midX, y: status.midY))
    Foundation.exit(0)
}

if utilityCommand == "close-popover" {
    if let popover = agentUsageWindows(layer: 101).map(\.0).first {
        guard let status = agentUsageWindows(layer: 25)
            .map(\.0)
            .filter({ abs($0.minX - popover.minX) < 4 })
            .min(by: { abs($0.midY - popover.minY) < abs($1.midY - popover.minY) })
        else {
            fputs("Could not find the status item attached to the open popover.\n", stderr)
            Foundation.exit(1)
        }
        postClick(at: CGPoint(x: status.midX, y: status.midY))
    }
    Foundation.exit(0)
}

if utilityCommand == "assert-primary-popover" {
    let found = agentUsageWindows(layer: 101)
        .map(\.0)
        .contains(where: { $0.midX >= 0 && $0.midX < 1_800 && $0.minY >= 0 })
    Foundation.exit(found ? 0 : 1)
}

enum WallpaperStyle: String {
    case light
    case mixed
    case dark
}

final class WallpaperView: NSView {
    let style: WallpaperStyle

    init(frame: NSRect, style: WallpaperStyle) {
        self.style = style
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let palette: (NSColor, NSColor, NSColor, NSColor) = {
            switch style {
            case .light:
                return (
                    NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.78, green: 0.88, blue: 0.90, alpha: 1),
                    NSColor(calibratedRed: 0.97, green: 0.88, blue: 0.77, alpha: 1),
                    NSColor(calibratedRed: 0.30, green: 0.54, blue: 0.61, alpha: 0.25)
                )
            case .mixed:
                return (
                    NSColor(calibratedRed: 0.15, green: 0.24, blue: 0.31, alpha: 1),
                    NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.69, alpha: 1),
                    NSColor(calibratedRed: 0.83, green: 0.62, blue: 0.43, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.18, alpha: 0.42)
                )
            case .dark:
                return (
                    NSColor(calibratedRed: 0.035, green: 0.06, blue: 0.09, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.23, alpha: 1),
                    NSColor(calibratedRed: 0.31, green: 0.18, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.28, alpha: 0.24)
                )
            }
        }()

        let gradient = NSGradient(colors: [palette.0, palette.1, palette.2])!
        gradient.draw(in: bounds, angle: style == .mixed ? -18 : 22)

        context.saveGState()
        context.setBlendMode(.softLight)
        let polygons: [[CGPoint]] = [
            [
                CGPoint(x: -0.10 * bounds.width, y: 0.12 * bounds.height),
                CGPoint(x: 0.40 * bounds.width, y: -0.08 * bounds.height),
                CGPoint(x: 0.24 * bounds.width, y: 0.72 * bounds.height)
            ],
            [
                CGPoint(x: 0.18 * bounds.width, y: 1.08 * bounds.height),
                CGPoint(x: 0.73 * bounds.width, y: 0.80 * bounds.height),
                CGPoint(x: 0.48 * bounds.width, y: 0.25 * bounds.height)
            ],
            [
                CGPoint(x: 0.56 * bounds.width, y: -0.08 * bounds.height),
                CGPoint(x: 1.08 * bounds.width, y: 0.18 * bounds.height),
                CGPoint(x: 0.84 * bounds.width, y: 0.84 * bounds.height)
            ],
            [
                CGPoint(x: 0.62 * bounds.width, y: 1.08 * bounds.height),
                CGPoint(x: 1.08 * bounds.width, y: 0.92 * bounds.height),
                CGPoint(x: 0.92 * bounds.width, y: 0.38 * bounds.height)
            ]
        ]
        let alphas: [CGFloat] = style == .light ? [0.18, 0.12, 0.16, 0.10] : [0.30, 0.18, 0.26, 0.16]
        for (index, points) in polygons.enumerated() {
            context.beginPath()
            context.move(to: points[0])
            context.addLine(to: points[1])
            context.addLine(to: points[2])
            context.closePath()
            context.setFillColor(palette.3.withAlphaComponent(alphas[index]).cgColor)
            context.fillPath()
        }
        context.restoreGState()

        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.white.withAlphaComponent(style == .dark ? 0.055 : 0.11).cgColor)
        let spacing: CGFloat = 34
        var offset: CGFloat = -bounds.height
        while offset < bounds.width {
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + bounds.height, y: bounds.height))
            offset += spacing
        }
        context.strokePath()
        context.restoreGState()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let style: WallpaperStyle
    var window: NSWindow?

    init(style: WallpaperStyle) {
        self.style = style
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5
        }) ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }

        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // The real SwiftUI popover is at layer 101 on macOS. Layer 100 keeps
        // this surface above ordinary app windows and strictly below it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = WallpaperView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size), style: style)
        window.orderFrontRegardless()
        self.window = window

        print("READY \(style.rawValue) \(NSStringFromRect(screen.visibleFrame))")
        fflush(stdout)
    }
}

let style = utilityCommand.flatMap(WallpaperStyle.init(rawValue:)) ?? .light
let app = NSApplication.shared
let delegate = AppDelegate(style: style)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
