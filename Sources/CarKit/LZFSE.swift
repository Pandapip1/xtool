import Foundation
import CLzfse

/// LZFSE compression through the vendored reference implementation.
enum LZFSE {
    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw CarError("cannot LZFSE-compress empty data") }
        // Worst case is a little over the input size (stored uncompressed).
        var output = Data(count: input.count + 4096)
        var scratch = [UInt8](repeating: 0, count: lzfse_encode_scratch_size())
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                lzfse_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    inp.bindMemory(to: UInt8.self).baseAddress!, inp.count,
                    &scratch
                )
            }
        }
        guard written > 0 else { throw CarError("LZFSE compression failed") }
        return output.prefix(written)
    }
}
