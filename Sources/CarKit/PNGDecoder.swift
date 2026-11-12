import Foundation

/// A minimal PNG decoder producing premultiplied BGRA, the layout catalog
/// bitmaps use. Handles 8-bit grayscale, gray+alpha, RGB, RGBA and palette
/// images (with tRNS transparency), non-interlaced. Color profiles are
/// ignored: pixels are taken to be sRGB.
public enum PNGDecoder {
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        /// Premultiplied BGRA, rows tightly packed.
        public var pixels: Data
    }

    public static func decode(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw CarError("not a PNG file")
        }

        var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var compressed = Data()

        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(UInt32(bigEndian: bytes[offset..<offset + 4]))
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let start = offset + 8
            guard start + length + 4 <= bytes.count else { throw CarError("truncated PNG chunk \(type)") }
            let body = bytes[start..<start + length]
            switch type {
            case "IHDR":
                width = Int(UInt32(bigEndian: body.prefix(4)))
                height = Int(UInt32(bigEndian: body.dropFirst(4).prefix(4)))
                bitDepth = Int(body[start + 8])
                colorType = Int(body[start + 9])
                interlace = Int(body[start + 12])
            case "PLTE": palette = Array(body)
            case "tRNS": transparency = Array(body)
            case "IDAT": compressed.append(contentsOf: body)
            case "IEND": offset = bytes.count
            default: break
            }
            offset = start + length + 4 // skip CRC
        }

        guard width > 0, height > 0 else { throw CarError("PNG has no image header") }
        guard bitDepth == 8 else { throw CarError("unsupported PNG bit depth \(bitDepth) (only 8)") }
        guard interlace == 0 else { throw CarError("interlaced PNGs are not supported") }
        let channels: Int
        switch colorType {
        case 0: channels = 1 // gray
        case 2: channels = 3 // RGB
        case 3: channels = 1 // palette index
        case 4: channels = 2 // gray + alpha
        case 6: channels = 4 // RGBA
        default: throw CarError("unsupported PNG color type \(colorType)")
        }

        let stride = width * channels
        let raw = [UInt8](try Inflate.decompress(compressed, expectedSize: (stride + 1) * height))
        let rows = try unfilter(raw, stride: stride, height: height, bytesPerPixel: channels)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let r, g, b, a: UInt8
            let p = i * channels
            switch colorType {
            case 0: (r, g, b, a) = (rows[p], rows[p], rows[p], 255)
            case 2: (r, g, b, a) = (rows[p], rows[p + 1], rows[p + 2], 255)
            case 3:
                let index = Int(rows[p])
                guard index * 3 + 2 < palette.count else { throw CarError("PNG palette index out of range") }
                (r, g, b) = (palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2])
                a = index < transparency.count ? transparency[index] : 255
            case 4: (r, g, b, a) = (rows[p], rows[p], rows[p], rows[p + 1])
            default: (r, g, b, a) = (rows[p], rows[p + 1], rows[p + 2], rows[p + 3])
            }
            // premultiply, with rounding
            func pm(_ c: UInt8) -> UInt8 { UInt8((Int(c) * Int(a) + 127) / 255) }
            pixels[i * 4] = pm(b)
            pixels[i * 4 + 1] = pm(g)
            pixels[i * 4 + 2] = pm(r)
            pixels[i * 4 + 3] = a
        }
        return Image(width: width, height: height, pixels: Data(pixels))
    }

    /// Undoes PNG's per-row filters; returns the rows without filter bytes.
    private static func unfilter(_ raw: [UInt8], stride: Int, height: Int, bytesPerPixel bpp: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            let filter = raw[y * (stride + 1)]
            let src = y * (stride + 1) + 1
            let dst = y * stride
            for x in 0..<stride {
                let value = raw[src + x]
                let left = x >= bpp ? Int(out[dst + x - bpp]) : 0
                let up = y > 0 ? Int(out[dst - stride + x]) : 0
                let upLeft = (x >= bpp && y > 0) ? Int(out[dst - stride + x - bpp]) : 0
                let predicted: Int
                switch filter {
                case 0: predicted = 0
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    predicted = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                default: throw CarError("bad PNG filter type \(filter)")
                }
                out[dst + x] = UInt8(truncatingIfNeeded: Int(value) + predicted)
            }
        }
        return out
    }
}

extension UInt32 {
    fileprivate init<C: Collection>(bigEndian bytes: C) where C.Element == UInt8 {
        self = bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}
