import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: check_render <image.png> <foreground-rrggbb>")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let hex = CommandLine.arguments[2]
guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
    fail("Invalid expected foreground color")
}
guard
    let source = CGImageSourceCreateWithURL(url, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ),
    let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
else {
    fail("Could not decode rendered SF Symbol PNG")
}

context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let expected = [Int((value >> 16) & 0xff), Int((value >> 8) & 0xff), Int(value & 0xff)]
var matching = 0
var black = 0
var transparent = 0
for y in 0..<image.height {
    for x in 0..<image.width {
        let offset = (y * image.width + x) * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let alpha = Int(pixels[offset + 3])
        if alpha == 0 {
            transparent += 1
        } else if alpha > 250 {
            if abs(red - expected[0]) <= 1 && abs(green - expected[1]) <= 1 && abs(blue - expected[2]) <= 1 {
                matching += 1
            }
            if red < 5 && green < 5 && blue < 5 {
                black += 1
            }
        }
    }
}

guard matching > 100 else {
    fail("Rendered symbol did not use the requested foreground color")
}
guard black == 0 else {
    fail("Rendered symbol contains opaque black pixels")
}
guard transparent > 0 else {
    fail("Rendered symbol lost transparent areas")
}
let center = (image.height / 2 * image.width + image.width / 2) * 4
guard pixels[center + 3] == 0 else {
    fail("Filled symbol lost its transparent cutout")
}

print("Tint and transparency passed (\(matching) matching, \(transparent) transparent pixels)")
