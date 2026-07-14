import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: render-dmg-volume-icon.swift <app-icon.icns> <output.png>\n".utf8)
    )
    exit(64)
}

guard let appIcon = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("Could not load the app icon.\n".utf8))
    exit(66)
}

let dimension = 1_024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: dimension,
    height: dimension,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))

let bodyRect = CGRect(x: 128, y: 116, width: 768, height: 804)
let bodyPath = CGPath(
    roundedRect: bodyRect,
    cornerWidth: 116,
    cornerHeight: 116,
    transform: nil
)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -24), blur: 34, color: NSColor.black.withAlphaComponent(0.42).cgColor)
context.addPath(bodyPath)
context.clip()
let bodyGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(calibratedRed: 0.38, green: 0.48, blue: 0.64, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.24, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    bodyGradient,
    start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
    end: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
    options: []
)
context.restoreGState()

context.addPath(bodyPath)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
context.setLineWidth(4)
context.strokePath()

let badgeRect = CGRect(x: 282, y: 348, width: 460, height: 460)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
appIcon.draw(
    in: badgeRect,
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

let baseRect = CGRect(x: 108, y: 78, width: 808, height: 210)
let basePath = CGPath(
    roundedRect: baseRect,
    cornerWidth: 96,
    cornerHeight: 96,
    transform: nil
)
context.saveGState()
context.addPath(basePath)
context.clip()
let baseGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(calibratedWhite: 0.97, alpha: 1).cgColor,
        NSColor(calibratedWhite: 0.64, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    baseGradient,
    start: CGPoint(x: baseRect.midX, y: baseRect.maxY),
    end: CGPoint(x: baseRect.midX, y: baseRect.minY),
    options: []
)
context.restoreGState()

context.addPath(basePath)
context.setStrokeColor(NSColor(calibratedWhite: 0.2, alpha: 0.75).cgColor)
context.setLineWidth(4)
context.strokePath()

context.saveGState()
context.setShadow(offset: .zero, blur: 12, color: NSColor.systemPink.withAlphaComponent(0.8).cgColor)
context.setFillColor(NSColor.systemPink.cgColor)
context.fillEllipse(in: CGRect(x: 826, y: 136, width: 34, height: 34))
context.restoreGState()
context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
context.setLineWidth(3)
context.strokeEllipse(in: CGRect(x: 826, y: 136, width: 34, height: 34))

guard let image = context.makeImage() else { exit(1) }
let representation = NSBitmapImageRep(cgImage: image)
guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
