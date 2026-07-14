import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-dmg-background.swift <output.png|tiff>\n".utf8))
    exit(64)
}

let width = 660
let height = 400
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}

context.setFillColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

context.setStrokeColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1)
context.setLineWidth(8)
context.setLineCap(.round)
context.setLineJoin(.round)
context.beginPath()
context.move(to: CGPoint(x: 322, y: 220))
context.addLine(to: CGPoint(x: 342, y: 200))
context.addLine(to: CGPoint(x: 322, y: 180))
context.strokePath()

guard let image = context.makeImage() else { exit(1) }
let representation = NSBitmapImageRep(cgImage: image)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileType: NSBitmapImageRep.FileType = outputURL.pathExtension.lowercased() == "tiff" ? .tiff : .png
guard let data = representation.representation(using: fileType, properties: [:]) else { exit(1) }
try data.write(to: outputURL, options: .atomic)
