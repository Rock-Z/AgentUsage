#!/usr/bin/env swift

import AppKit
import CoreImage

// With --imitate-glass, the inputs are offscreen renders: transparent popover
// content and a bare menu bar icon. The popover glass and the open-item
// highlight are then imitated. Without it, the inputs are real screen captures.
var arguments = Array(CommandLine.arguments.dropFirst())
let imitatesGlass = arguments.first == "--imitate-glass"
if imitatesGlass { arguments.removeFirst() }

guard arguments.count == 7 else {
    fputs(
        "usage: compose-real-app-triptych.swift [--imitate-glass] "
            + "DAY-STATUS.png DAY-POPOVER.png WEEK-STATUS.png WEEK-POPOVER.png "
            + "CUMULATIVE-STATUS.png CUMULATIVE-POPOVER.png OUTPUT.png\n",
        stderr)
    Foundation.exit(2)
}

let images = arguments[0...5].compactMap {
    NSImage(contentsOf: URL(fileURLWithPath: $0))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}
let outputURL = URL(fileURLWithPath: arguments[6])

guard images.count == 6 else {
    fputs("Could not decode one or more source screenshots.\n", stderr)
    Foundation.exit(1)
}
/// Each panel's menu bar icon and popover, captured separately at any scale.
let sources = stride(from: 0, to: 6, by: 2).map { (status: images[$0], popover: images[$0 + 1]) }

let panelWidth = 650
let outputWidth = panelWidth * 3
let outputHeight = 888
let panelLean: CGFloat = 30

let outputTopBarHeight: CGFloat = 48
let popoverTop: CGFloat = 48
let popoverBottomMargin: CGFloat = 24
/// The popover's width and corner radius in points, used to derive capture density.
let popoverPointWidth: CGFloat = 360
let popoverCornerRadius: CGFloat = 15
/// Popover size in the output, per point of the real popover.
let preferredPointScale: CGFloat = 1.36

func panelPath(index: Int) -> CGPath {
    let left = CGFloat(index * panelWidth)
    let right = CGFloat((index + 1) * panelWidth)
    let points: [CGPoint] = switch index {
    case 0:
        [
            CGPoint(x: left, y: 0),
            CGPoint(x: right + panelLean, y: 0),
            CGPoint(x: right - panelLean, y: CGFloat(outputHeight)),
            CGPoint(x: left, y: CGFloat(outputHeight)),
        ]
    case 1:
        [
            CGPoint(x: left + panelLean, y: 0),
            CGPoint(x: right + panelLean, y: 0),
            CGPoint(x: right - panelLean, y: CGFloat(outputHeight)),
            CGPoint(x: left - panelLean, y: CGFloat(outputHeight)),
        ]
    default:
        [
            CGPoint(x: left + panelLean, y: 0),
            CGPoint(x: right, y: 0),
            CGPoint(x: right, y: CGFloat(outputHeight)),
            CGPoint(x: left - panelLean, y: CGFloat(outputHeight)),
        ]
    }

    let path = CGMutablePath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
}

func drawTopLeft(_ context: CGContext, image: CGImage, destination: CGRect) {
    context.saveGState()
    context.translateBy(x: destination.minX, y: destination.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: destination.size))
    context.restoreGState()
}

func drawWallpaper(_ context: CGContext, index: Int, destination: CGRect) {
    let colors: [CGColor]
    switch index {
    case 0:
        colors = [
            NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.98, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.78, green: 0.88, blue: 0.90, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.97, green: 0.88, blue: 0.77, alpha: 1).cgColor,
        ]
    case 1:
        colors = [
            NSColor(calibratedRed: 0.15, green: 0.24, blue: 0.31, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.69, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.83, green: 0.62, blue: 0.43, alpha: 1).cgColor,
        ]
    default:
        colors = [
            NSColor(calibratedRed: 0.035, green: 0.06, blue: 0.09, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.23, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.31, green: 0.18, blue: 0.28, alpha: 1).cgColor,
        ]
    }

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 0.58, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: destination.minX, y: destination.maxY),
        end: CGPoint(x: destination.maxX, y: destination.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let polygonColor = index == 2
        ? NSColor(calibratedRed: 0.65, green: 0.39, blue: 0.31, alpha: 0.15)
        : NSColor.white.withAlphaComponent(index == 0 ? 0.10 : 0.13)
    let polygons: [[CGPoint]] = [
        [
            CGPoint(x: destination.minX - 80, y: destination.height * 0.18),
            CGPoint(x: destination.midX + 140, y: destination.minY - 40),
            CGPoint(x: destination.midX - 100, y: destination.height * 0.72),
        ],
        [
            CGPoint(x: destination.minX + 90, y: destination.maxY + 50),
            CGPoint(x: destination.maxX + 60, y: destination.height * 0.80),
            CGPoint(x: destination.midX + 30, y: destination.height * 0.27),
        ],
        [
            CGPoint(x: destination.midX, y: destination.minY - 40),
            CGPoint(x: destination.maxX + 80, y: destination.height * 0.24),
            CGPoint(x: destination.maxX - 80, y: destination.height * 0.86),
        ],
    ]
    context.setBlendMode(.softLight)
    context.setFillColor(polygonColor.cgColor)
    for points in polygons {
        context.beginPath()
        context.move(to: points[0])
        context.addLine(to: points[1])
        context.addLine(to: points[2])
        context.closePath()
        context.fillPath()
    }
    context.setBlendMode(.normal)

    context.setStrokeColor(
        NSColor.white.withAlphaComponent(index == 2 ? 0.055 : 0.10).cgColor)
    context.setLineWidth(1)
    var offset = destination.minX - destination.height
    while offset < destination.maxX {
        context.move(to: CGPoint(x: offset, y: destination.minY))
        context.addLine(to: CGPoint(x: offset + destination.height, y: destination.maxY))
        offset += 27
    }
    context.strokePath()
}

/// The panel's wallpaper, heavily blurred, for the imitated glass.
func blurredWallpaper(index: Int, destination: CGRect) -> CGImage? {
    let width = Int(destination.width)
    let height = Int(destination.height)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let local = graphics.cgContext
    local.translateBy(x: 0, y: CGFloat(height))
    local.scaleBy(x: 1, y: -1)
    local.translateBy(x: -destination.minX, y: 0)
    drawWallpaper(local, index: index, destination: destination)
    NSGraphicsContext.restoreGraphicsState()
    guard let input = CIImage(bitmapImageRep: rep) else { return nil }
    let blurred = input.clampedToExtent()
        .applyingGaussianBlur(sigma: 28)
        .cropped(to: input.extent)
        .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
    return CIContext().createCGImage(blurred, from: input.extent)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: outputWidth,
    pixelsHigh: outputHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0),
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    fatalError("Could not allocate output bitmap.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Could not create output graphics context.")
}
context.translateBy(x: 0, y: CGFloat(outputHeight))
context.scaleBy(x: 1, y: -1)
context.setShouldAntialias(true)
context.setFillColor(NSColor.black.cgColor)
context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

for (index, source) in sources.enumerated() {
    let destinationWidth = CGFloat(panelWidth) + panelLean * 2
    let destination = CGRect(
        x: CGFloat(index * panelWidth) - panelLean,
        y: 0,
        width: destinationWidth,
        height: CGFloat(outputHeight))

    context.saveGState()
    context.addPath(panelPath(index: index))
    context.clip()

    drawWallpaper(context, index: index, destination: destination)
    // The last panel shows dark mode; the others light.
    let isDark = index == sources.count - 1

    // A translucent menu bar over the wallpaper, like macOS 26.
    context.setFillColor((isDark
        ? NSColor(white: 0, alpha: 0.35)
        : NSColor(white: 1, alpha: 0.35)).cgColor)
    context.fill(CGRect(
        x: destination.minX,
        y: 0,
        width: destination.width,
        height: outputTopBarHeight))

    // Scale by points, not pixels, so 1x and 2x captures compose alike, and
    // shrink if a tall popover would not fit below the menu bar.
    let popover = source.popover
    let pixelsPerPoint = CGFloat(popover.width) / popoverPointWidth
    let fitHeight = (CGFloat(outputHeight) - popoverTop - popoverBottomMargin)
        / (CGFloat(popover.height) / pixelsPerPoint)
    let pointScale = min(preferredPointScale, fitHeight)
    let imageScale = pointScale / pixelsPerPoint
    let panelCenterX = CGFloat(index * panelWidth) + CGFloat(panelWidth) / 2
    let popoverDestination = CGRect(
        x: panelCenterX - CGFloat(popover.width) * imageScale / 2,
        y: popoverTop,
        width: CGFloat(popover.width) * imageScale,
        height: CGFloat(popover.height) * imageScale)

    // The menu bar icon at the popover's scale (both come from the same
    // display density), centered in the menu bar and aligned with the popover.
    let status = source.status
    let statusSize = CGSize(
        width: CGFloat(status.width) * imageScale,
        height: CGFloat(status.height) * imageScale)
    let statusDestination = CGRect(
        x: popoverDestination.minX,
        y: (outputTopBarHeight - statusSize.height) / 2,
        width: statusSize.width,
        height: statusSize.height)
    if imitatesGlass {
        // macOS highlights a menu bar item while its popover is open.
        let pillHeight = 25 * pointScale
        let pill = CGRect(
            x: statusDestination.minX,
            y: (outputTopBarHeight - pillHeight) / 2,
            width: statusDestination.width,
            height: pillHeight)
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pillHeight / 2,
            cornerHeight: pillHeight / 2,
            transform: nil))
        context.setFillColor(NSColor.white.withAlphaComponent(isDark ? 0.16 : 0.4).cgColor)
        context.fillPath()
    }
    drawTopLeft(context, image: status, destination: statusDestination)

    let cornerRadius = popoverCornerRadius * pointScale
    let popoverPath = CGPath(
        roundedRect: popoverDestination,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: 9),
        blur: 18,
        color: NSColor.black.withAlphaComponent(0.24).cgColor)
    context.addPath(popoverPath)
    context.setFillColor(imitatesGlass
        ? NSColor.black.withAlphaComponent(0.01).cgColor
        : NSColor.white.withAlphaComponent(0.95).cgColor)
    context.fillPath()
    context.restoreGState()

    if imitatesGlass {
        // Glass: the wallpaper behind the popover, blurred and tinted, with an edge highlight.
        context.saveGState()
        context.addPath(popoverPath)
        context.clip()
        if let blurred = blurredWallpaper(index: index, destination: destination) {
            drawTopLeft(context, image: blurred, destination: destination)
        }
        context.setFillColor((isDark
            ? NSColor(white: 0.12, alpha: 0.62)
            : NSColor(white: 0.97, alpha: 0.62)).cgColor)
        context.fill(popoverDestination)
        context.restoreGState()
        context.saveGState()
        context.addPath(popoverPath)
        context.setStrokeColor(NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.55).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(popoverPath)
    context.clip()
    drawTopLeft(context, image: popover, destination: popoverDestination)
    context.restoreGState()

    context.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode output PNG.")
}
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
