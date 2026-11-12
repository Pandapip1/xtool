import Foundation
import CZlib

/// zlib-format (RFC 1950) decompression through the system zlib, for PNG
/// image data.
enum Inflate {
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        var length = uLongf(expectedSize)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                uncompress(
                    out.bindMemory(to: Bytef.self).baseAddress, &length,
                    inp.bindMemory(to: Bytef.self).baseAddress, uLong(input.count)
                )
            }
        }
        guard status == Z_OK, Int(length) == expectedSize else {
            throw CarError("corrupt image data (zlib status \(status), \(length) of \(expectedSize) bytes)")
        }
        return output
    }
}
