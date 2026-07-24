#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 5 else {
    fputs(
        "usage: compose-real-app-triptych.swift DAY.png WEEK.png CUMULATIVE.png OUTPUT.png\n",
        stderr)
    Foundation.exit(2)
}

let sourceURLs = CommandLine.arguments[1...3].map(URL.init(fileURLWithPath:))
let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])
let sources = sourceURLs.compactMap {
    NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

guard sources.count == 3 else {
    fputs("Could not decode one or more source screenshots.\n", stderr)
    Foundation.exit(1)
}

let panelWidth = 650
let outputWidth = panelWidth * 3
let outputHeight = 888
let panelLean: CGFloat = 30

let captureScale: CGFloat = 0.68
let outputTopBarHeight: CGFloat = 48
let popoverTop: CGFloat = 48
let sourceStatusRect = CGRect(x: 2_568, y: 0, width: 350, height: 88)
let sourcePopoverRect = CGRect(x: 2_568, y: 90, width: 720, height: 1_190)

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

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(
        x: destination.minX,
        y: 0,
        width: destination.width,
        height: outputTopBarHeight))

    let panelCenterX = CGFloat(index * panelWidth) + CGFloat(panelWidth) / 2
    let popoverDestination = CGRect(
        x: panelCenterX - sourcePopoverRect.width * captureScale / 2,
        y: popoverTop,
        width: sourcePopoverRect.width * captureScale,
        height: sourcePopoverRect.height * captureScale)

    if let status = source.cropping(to: sourceStatusRect) {
        let statusScale = outputTopBarHeight / sourceStatusRect.height
        drawTopLeft(
            context,
            image: status,
            destination: CGRect(
                x: popoverDestination.minX,
                y: 0,
                width: sourceStatusRect.width * statusScale,
                height: outputTopBarHeight))
    }

    if let popover = source.cropping(to: sourcePopoverRect) {
        let popoverPath = CGPath(
            roundedRect: popoverDestination,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 9),
            blur: 18,
            color: NSColor.black.withAlphaComponent(0.24).cgColor)
        context.addPath(popoverPath)
        context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(popoverPath)
        context.clip()
        drawTopLeft(context, image: popover, destination: popoverDestination)
        context.restoreGState()
    }

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
