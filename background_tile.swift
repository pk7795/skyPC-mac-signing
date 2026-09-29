#!/usr/bin/env swift

import AppKit
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: \(message)\n").utf8))
    exit(1)
}

guard (5...6).contains(CommandLine.arguments.count),
      let columns = Int(CommandLine.arguments[3]), columns > 0,
      let rows = Int(CommandLine.arguments[4]), rows > 0 else {
    fail("usage: background_tile.swift INPUT OUTPUT COLUMNS ROWS [repeat|mirror]")
}
let mode = CommandLine.arguments.count == 6 ? CommandLine.arguments[5] : "mirror"
guard mode == "repeat" || mode == "mirror" else {
    fail("mode must be repeat or mirror")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot decode input image")
}

let tileWidth = image.width
let tileHeight = image.height
let width = tileWidth * columns
let height = tileHeight * rows
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fail("cannot allocate output canvas")
}

context.interpolationQuality = .high
for row in 0..<rows {
    for column in 0..<columns {
        context.saveGState()
        let x = CGFloat(column * tileWidth)
        let y = CGFloat((rows - row - 1) * tileHeight)
        context.translateBy(x: x, y: y)
        if mode == "mirror" && column.isMultiple(of: 2) == false {
            context.translateBy(x: CGFloat(tileWidth), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if mode == "mirror" && row.isMultiple(of: 2) == false {
            context.translateBy(x: 0, y: CGFloat(tileHeight))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
        context.restoreGState()
    }
}

guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.tiff.identifier as CFString,
        1,
        nil
      ) else {
    fail("cannot create output image")
}

let properties: [CFString: Any] = [
    kCGImagePropertyDPIWidth: 144,
    kCGImagePropertyDPIHeight: 144,
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFCompression: 5  // LZW
    ]
]
CGImageDestinationAddImage(destination, result, properties as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot write output image")
}

print("PASS: \(mode)-tiled \(columns)x\(rows), \(width)x\(height) pixels at 144 DPI")
