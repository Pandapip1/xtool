import Foundation

/// Writes Apple "BOM store" files: numbered data blocks, named variables
/// pointing at blocks, and B-trees built from blocks. Compiled asset catalogs
/// (`Assets.car`) are BOM stores. See Documentation/Formats/AssetCatalog.md.
///
/// Everything in the container itself is big-endian.
public struct BOMWriter: Sendable {
    /// Block 0 is reserved and empty.
    private var blocks: [Data] = [Data()]
    private var variables: [(name: String, block: UInt32)] = []

    /// The usual size of a tree node in bytes, as written by the system tools.
    public static let defaultNodeSize = 4096

    /// A tree entry's key: usually a block of its own, but some trees (such
    /// as a catalog's BITMAPKEYS) store a 32-bit value in the key slot.
    public enum TreeKey: Sendable {
        case block(Data)
        case inline(UInt32)
    }

    public init() {}

    /// Stores `data` as a new block and returns its index.
    @discardableResult
    public mutating func addBlock(_ data: Data) -> UInt32 {
        blocks.append(data)
        return UInt32(blocks.count - 1)
    }

    /// Names a block. Variables are written in the order they're added.
    public mutating func setVariable(_ name: String, block: UInt32) {
        precondition(name.utf8.count <= 255, "BOM variable names are at most 255 bytes")
        variables.append((name, block))
    }

    /// Stores a B-tree of `entries` (already sorted by key) and returns the
    /// index of its `tree` block. `flag` is the last byte of the tree header,
    /// which the system writes as 1 for trees with inline keys.
    public mutating func addTree(
        _ entries: [(key: TreeKey, value: Data)],
        nodeSize: Int = defaultNodeSize,
        flag: UInt8 = 0
    ) -> UInt32 {
        // A node is a 12-byte header plus 8 bytes per entry.
        let capacity = (nodeSize - 12) / 8

        // Leaves first: their indices are needed for the forward/backward
        // links and the root, so reserve them, then fill them in.
        let chunks = stride(from: 0, to: max(entries.count, 1), by: capacity).map {
            Array(entries[$0..<min($0 + capacity, entries.count)])
        }
        let leafIndices = chunks.map { _ in addBlock(Data()) }
        var lastKeys: [UInt32] = []

        for (i, chunk) in chunks.enumerated() {
            var node = Data()
            node.appendBigEndian(UInt16(1)) // is_leaf
            node.appendBigEndian(UInt16(chunk.count))
            node.appendBigEndian(i + 1 < leafIndices.count ? leafIndices[i + 1] : 0) // forward
            node.appendBigEndian(i > 0 ? leafIndices[i - 1] : 0) // backward
            var lastKey: UInt32 = 0
            for entry in chunk {
                let valueIndex = addBlock(entry.value)
                lastKey = switch entry.key {
                case .block(let data): addBlock(data)
                case .inline(let value): value
                }
                node.appendBigEndian(valueIndex)
                node.appendBigEndian(lastKey)
            }
            blocks[Int(leafIndices[i])] = node.padded(to: nodeSize)
            lastKeys.append(lastKey)
        }

        let root: UInt32
        if leafIndices.count == 1 {
            root = leafIndices[0]
        } else {
            // B+-tree branch: one separator per leaf but the last (its last
            // key), and one more child pointer than separators.
            precondition(leafIndices.count <= capacity, "tree too large for one branch level")
            var node = Data()
            node.appendBigEndian(UInt16(0)) // is_leaf
            node.appendBigEndian(UInt16(leafIndices.count - 1))
            node.appendBigEndian(UInt32(0))
            node.appendBigEndian(UInt32(0))
            for (leaf, key) in zip(leafIndices.dropLast(), lastKeys.dropLast()) {
                node.appendBigEndian(leaf)
                node.appendBigEndian(key)
            }
            node.appendBigEndian(leafIndices.last!)
            node.appendBigEndian(UInt32(0))
            root = addBlock(node.padded(to: nodeSize))
        }

        var tree = Data("tree".utf8)
        tree.appendBigEndian(UInt32(1)) // version
        tree.appendBigEndian(root)
        tree.appendBigEndian(UInt32(nodeSize))
        tree.appendBigEndian(UInt32(entries.count))
        tree.append(flag)
        return addBlock(tree)
    }

    /// The complete file.
    public func serialize() -> Data {
        let headerSize = 512

        // Variables: count, then (block, name length, name) each.
        var vars = Data()
        vars.appendBigEndian(UInt32(variables.count))
        for variable in variables {
            vars.appendBigEndian(variable.block)
            vars.append(UInt8(variable.name.utf8.count))
            vars.append(contentsOf: variable.name.utf8)
        }

        // Block data, each aligned to 16 bytes, after the header.
        var body = Data()
        var addresses: [(address: UInt32, length: UInt32)] = []
        for block in blocks {
            if block.isEmpty {
                addresses.append((0, 0))
                continue
            }
            body.pad(toMultipleOf: 16)
            addresses.append((UInt32(headerSize + body.count), UInt32(block.count)))
            body.append(block)
        }
        body.pad(toMultipleOf: 16)

        let varsOffset = headerSize + body.count
        var tail = vars
        tail.pad(toMultipleOf: 16)
        let indexOffset = varsOffset + tail.count

        // Block index: count, (address, length) pairs, then an empty free list.
        var index = Data()
        index.appendBigEndian(UInt32(addresses.count))
        for entry in addresses {
            index.appendBigEndian(entry.address)
            index.appendBigEndian(entry.length)
        }
        index.appendBigEndian(UInt32(0))

        var header = Data("BOMStore".utf8)
        header.appendBigEndian(UInt32(1)) // version
        header.appendBigEndian(UInt32(blocks.count))
        header.appendBigEndian(UInt32(indexOffset))
        header.appendBigEndian(UInt32(index.count))
        header.appendBigEndian(UInt32(varsOffset))
        header.appendBigEndian(UInt32(vars.count))

        var file = header.padded(to: headerSize)
        file.append(body)
        file.append(tail)
        file.append(index)
        return file
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func pad(toMultipleOf alignment: Int) {
        let remainder = count % alignment
        if remainder != 0 { append(Data(count: alignment - remainder)) }
    }

    func padded(to size: Int) -> Data {
        count >= size ? self : self + Data(count: size - count)
    }
}
