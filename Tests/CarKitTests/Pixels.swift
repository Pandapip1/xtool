import Foundation
#if canImport(AppKit)
import AppKit

/// The image's pixels as premultiplied RGBA bytes in sRGB, whatever layout
/// the system decoded it into (CoreUI hands back BGRA for uncompressed
/// renditions and RGBA for LZFSE ones).
func rgbaPixels(of image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}
#endif
