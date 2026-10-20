import AppKit
import Foundation
import ImageIO

func fail(_ message: String, status: Int32) -> Never {
    fputs(message + "\n", stderr)
    exit(status)
}

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    fail("Usage: render <symbol-name> <output.png> [foreground-rrggbb]", status: 64)
}

let name = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let foreground: NSColor
if CommandLine.arguments.count == 4 {
    let hex = CommandLine.arguments[3].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
        fail("Invalid foreground color; expected RRGGBB", status: 64)
    }
    foreground = NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1
    )
} else {
    foreground = NSColor(calibratedWhite: 0.55, alpha: 1)
}
guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
    fail("unavailable", status: 3)
}

let configuration = NSImage.SymbolConfiguration(pointSize: 176, weight: .regular)
let image = symbol.withSymbolConfiguration(configuration) ?? symbol
let canvas = NSSize(width: 256, height: 256)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("Could not allocate an SF Symbol bitmap", status: 1)
}

bitmap.size = canvas
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    NSGraphicsContext.restoreGraphicsState()
    fail("Could not create an SF Symbol drawing context", status: 1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high

let sourceSize = image.size
guard sourceSize.width > 0, sourceSize.height > 0 else {
    fail("SF Symbol has an invalid size", status: 1)
}
let scale = min((canvas.width * 0.8) / sourceSize.width, (canvas.height * 0.8) / sourceSize.height)
let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
let destination = NSRect(
    x: (canvas.width - drawSize.width) / 2,
    y: (canvas.height - drawSize.height) / 2,
    width: drawSize.width,
    height: drawSize.height
)
image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let mask = bitmap.cgImage else {
    fail("Could not create an SF Symbol mask", status: 1)
}
guard
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let tintContext = CGContext(
        data: nil,
        width: Int(canvas.width),
        height: Int(canvas.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fail("Could not create an SF Symbol tint context", status: 1)
}
let canvasRect = CGRect(origin: .zero, size: canvas)
tintContext.draw(mask, in: canvasRect)
tintContext.setBlendMode(.sourceIn)
tintContext.setFillColor(foreground.cgColor)
tintContext.fill(canvasRect)
guard let tintedImage = tintContext.makeImage() else {
    fail("Could not create a tinted SF Symbol image", status: 1)
}
let pngData = NSMutableData()
guard let destination = CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil) else {
    fail("Could not create an SF Symbol PNG encoder", status: 1)
}
CGImageDestinationAddImage(destination, tintedImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("Could not encode the SF Symbol as PNG", status: 1)
}

do {
    try (pngData as Data).write(to: output, options: .atomic)
} catch {
    fail("Could not write SF Symbol PNG: \(error.localizedDescription)", status: 1)
}
