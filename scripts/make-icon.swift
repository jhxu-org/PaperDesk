import AppKit
import ImageIO

// Package the approved logo at exact pixel sizes, independent of the display's Retina scale.
guard (3...4).contains(CommandLine.arguments.count) else {
    fatalError("Usage: swift make-icon.swift SOURCE.png OUTPUT_DIRECTORY [EXTENSION_ICON_DIRECTORY]")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
      logo.width == logo.height, logo.width >= 1024 else {
    fatalError("The app icon source must be a square image of at least 1024 pixels.")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Unable to create app icon bitmap.")
        }
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Unable to encode app icon bitmap.")
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
if CommandLine.arguments.count == 4 {
    let extensionDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    // The extension uses the same approved brand asset at exact non-Retina pixel dimensions.
    for pixels in [16, 32, 48, 128] {
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try data.write(to: extensionDirectory.appendingPathComponent("icon\(pixels).png"), options: .atomic)
    }
}
