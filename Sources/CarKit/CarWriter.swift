import Foundation

/// Writes compiled asset catalogs (`Assets.car`). The layout follows the
/// observations in Documentation/Formats/AssetCatalog.md; fields are
/// little-endian inside the BOM container's blocks.
public struct CarWriter: Sendable {
    public struct Bitmap: Sendable {
        public var scale: Int
        public var width: Int
        public var height: Int
        /// Premultiplied BGRA, 8 bits per channel, rows tightly packed.
        public var pixels: Data

        public init(scale: Int, width: Int, height: Int, pixels: Data) {
            self.scale = scale
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    public enum Asset: Sendable {
        case image(name: String, bitmaps: [Bitmap])
        /// An SVG, kept as vector data, plus bitmaps rendered from it for the
        /// sizes and scales that use them.
        case vector(name: String, svg: Data, bitmaps: [Bitmap])
        /// sRGB components, 0...1.
        case color(name: String, red: Double, green: Double, blue: Double, alpha: Double)
        /// A layered app icon (from Icon Composer), which the system renders
        /// itself, with its materials, for each appearance.
        case layeredIcon(LayeredIcon)

        var name: String {
            switch self {
            case .image(let name, _), .vector(let name, _, _), .color(let name, _, _, _, _): name
            case .layeredIcon(let icon): icon.name
            }
        }
    }

    /// A layered icon: a background fill under groups of image layers, each
    /// group drawn as one piece of material. Lists run bottom-most first.
    public struct LayeredIcon: Sendable {
        public struct Color: Sendable, Equatable {
            /// CoreUI's color space numbers: 1 sRGB, 4 extended sRGB, 2 gray,
            /// 6 extended gray.
            public var space: UInt32
            public var components: [Double]

            public init(space: UInt32, components: [Double]) {
                self.space = space
                self.components = components
            }

            public static func sRGB(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
                Color(space: 4, components: [r, g, b, a])
            }
            public static func gray(_ white: Double, _ alpha: Double = 1) -> Color {
                Color(space: 6, components: [white, alpha])
            }
        }

        public enum Fill: Sendable {
            case color(Color)
            /// From `start` to `stop` in unit coordinates of the icon, y down.
            case linearGradient(Color, Color, start: (x: Double, y: Double), stop: (x: Double, y: Double))
        }

        public enum Image: Sendable {
            case svg(Data)
            case bitmap(Bitmap)
        }

        public struct Layer: Sendable {
            public var image: Image
            /// Where the image is drawn on the 1024-point canvas, y down.
            public var x: Int, y: Int, width: Int, height: Int
            /// A `CGBlendMode` value (0 normal, 1 multiply, 2 screen, ...).
            public var blendMode: UInt32 = 0
            public var opacity: Double = 1
            public var glass = false
            /// Paints the image's shape in this color instead of its own.
            public var fill: Color?

            public init(image: Image, x: Int, y: Int, width: Int, height: Int) {
                self.image = image
                (self.x, self.y, self.width, self.height) = (x, y, width, height)
            }
        }

        public struct Group: Sendable {
            public enum Shadow: UInt32, Sendable {
                case none = 0
                case layerColor = 2
                case neutral = 3
            }

            public var layers: [Layer]
            public var opacity: Double = 1
            /// Light the group's layers as one shape rather than each on its own.
            public var combinedLighting = false
            public var blur: Double = 0
            public var specular = true
            /// 0 when translucency is off.
            public var translucency: Double = 0.3
            public var shadow = Shadow.neutral
            public var shadowOpacity: Double = 0.5

            public init(layers: [Layer]) {
                self.layers = layers
            }
        }

        public var name: String
        /// Nil leaves the default (white) background.
        public var fill: Fill?
        public var groups: [Group]

        public init(name: String, fill: Fill?, groups: [Group]) {
            self.name = name
            self.fill = fill
            self.groups = groups
        }
    }

    /// Rendition key attributes, in key-format order (as Xcode 27 writes them).
    enum Attribute: UInt16, CaseIterable {
        case appearance = 7
        case localization = 13
        case element = 1
        case part = 2
        case size = 3
        case identifier = 17
        case idiom = 11
        case scale = 12
    }

    enum Part: UInt16 {
        case vector = 42
        /// Bitmaps, and the SVG images of layered icons.
        case bitmap = 181
        case color = 217
        case layeredImage = 245
        case layerGroup = 246
        case gradient = 247
    }

    /// Values of the appearance attribute, named in the APPEARANCEKEYS table.
    enum Appearance: UInt16, CaseIterable {
        case system = 0
        case dark = 1
        case light = 8
        case tintable = 10

        var name: String {
            switch self {
            case .system: "NSAppearanceNameSystem"
            case .dark: "NSAppearanceNameDarkAqua"
            case .light: "NSAppearanceNameAqua"
            case .tintable: "ISAppearanceTintable"
            }
        }
    }

    /// Fixed value of the `element` attribute in every key.
    static let element: UInt16 = 85

    /// Bitmap payload compression. 0 is uncompressed, 4 is LZFSE; zlib is not
    /// decoded at all. See the format notes.
    static let compressionLZFSE: UInt32 = 4

    public var assets: [Asset] = []
    public var deploymentTarget = "11.0"
    public var platform = "macosx"

    public init() {}

    public func serialize() throws -> Data {
        // Names get small sequential identifiers; any unique u16 works.
        let names = assets.flatMap { asset in
            if case .layeredIcon(let icon) = asset { return LayeredIconParts(icon).names }
            return [asset.name]
        }.sorted()
        guard Set(names).count == names.count else {
            throw CarError("asset names must be unique")
        }
        let identifiers = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, UInt16($0 + 1)) })

        var renditions: [(key: [UInt16], value: Data)] = []
        var facets: [(name: String, value: Data)] = []
        var bitmapKeys: [(identifier: UInt16, scales: Set<Int>)] = []
        var usesAppearances = false

        for asset in assets {
            let identifier = identifiers[asset.name]!
            switch asset {
            case .layeredIcon(let icon):
                usesAppearances = true
                let parts = LayeredIconParts(icon)
                for named in try parts.renditions(writer: self, identifiers: identifiers) {
                    renditions.append(contentsOf: named.renditions)
                    facets.append((named.name, facet(part: named.part, identifier: identifiers[named.name]!)))
                    bitmapKeys.append((identifiers[named.name]!, [1]))
                }
            case .image(let name, let bitmaps):
                for bitmap in bitmaps {
                    renditions.append((
                        key(part: .bitmap, identifier: identifier, scale: bitmap.scale),
                        try bitmapRendition(name: name, bitmap)
                    ))
                }
                facets.append((name, facet(part: .bitmap, identifier: identifier)))
                bitmapKeys.append((identifier, Set(bitmaps.map(\.scale))))
            case .vector(let name, let svg, let bitmaps):
                renditions.append((
                    key(part: .vector, identifier: identifier, scale: 1),
                    try vectorRendition(name: name, svg: svg)
                ))
                for bitmap in bitmaps {
                    renditions.append((
                        key(part: .bitmap, identifier: identifier, scale: bitmap.scale),
                        try bitmapRendition(name: name, bitmap, fromVector: true)
                    ))
                }
                facets.append((name, facet(part: .bitmap, identifier: identifier)))
                bitmapKeys.append((identifier, Set(bitmaps.map(\.scale))))
            case .color(let name, let red, let green, let blue, let alpha):
                renditions.append((
                    key(part: .color, identifier: identifier, scale: 1),
                    colorRendition(name: name, components: [red, green, blue, alpha])
                ))
                facets.append((name, facet(part: .color, identifier: identifier)))
                bitmapKeys.append((identifier, [1]))
            }
        }

        // Rendition keys sort by their encoded bytes (little-endian u16s, so not
        // numerically once a value passes 255): the system binary-searches
        // them that way. Names sort lexically.
        func keyBytes(_ key: [UInt16]) -> [UInt8] { key.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }
        renditions.sort { keyBytes($0.key).lexicographicallyPrecedes(keyBytes($1.key)) }
        facets.sort { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        bitmapKeys.sort { $0.identifier < $1.identifier }

        var bom = BOMWriter()
        bom.setVariable("CARHEADER", block: bom.addBlock(header(renditionCount: renditions.count)))
        bom.setVariable("RENDITIONS", block: bom.addTree(renditions.map { entry in
            var key = Data()
            for value in entry.key { key.appendLittleEndian(value) }
            return (.block(key), entry.value)
        }))
        bom.setVariable("FACETKEYS", block: bom.addTree(facets.map { (.block(Data($0.name.utf8)), $0.value) }))
        bom.setVariable("KEYFORMAT", block: bom.addBlock(keyFormat()))
        bom.setVariable("EXTENDED_METADATA", block: bom.addBlock(metadata()))
        // BITMAPKEYS: 1 KiB nodes, keyed by the name identifier itself.
        bom.setVariable("BITMAPKEYS", block: bom.addTree(bitmapKeys.map { entry in
            (.inline(UInt32(entry.identifier)), bitmapKeyValue(scales: entry.scales))
        }, nodeSize: 1024, flag: 1))
        if usesAppearances {
            // Appearance names to the values keys use, sorted by name.
            let appearances = Appearance.allCases.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
            bom.setVariable("APPEARANCEKEYS", block: bom.addTree(appearances.map { appearance in
                var value = Data()
                value.appendLittleEndian(appearance.rawValue)
                return (.block(Data(appearance.name.utf8)), value)
            }))
        }
        return bom.serialize()
    }

    // MARK: Tables

    func header(renditionCount: Int) -> Data {
        var data = Data("RATC".utf8)
        data.appendLittleEndian(UInt32(1011)) // CoreUI version
        data.appendLittleEndian(UInt32(17)) // storage version
        data.appendLittleEndian(UInt32(0)) // timestamp
        data.appendLittleEndian(UInt32(renditionCount))
        data.append(Data("xtool\n".utf8).padded(to: 128))
        data.append(Data("xtool".utf8).padded(to: 256))
        data.append(Data(count: 16)) // UUID
        data.appendLittleEndian(UInt32(0)) // checksum
        data.appendLittleEndian(UInt32(2)) // schema version
        data.appendLittleEndian(UInt32(1)) // color space
        data.appendLittleEndian(UInt32(1)) // key semantics
        return data
    }

    func keyFormat() -> Data {
        var data = Data("tmfk".utf8)
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(Attribute.allCases.count))
        for attribute in Attribute.allCases {
            data.appendLittleEndian(UInt32(attribute.rawValue))
        }
        return data
    }

    func metadata() -> Data {
        var strings = Data()
        for string in [deploymentTarget, platform, "xtool"] {
            strings.append(contentsOf: string.utf8)
            strings.append(0)
        }
        return Data("META".utf8) + strings.padded(to: 1024)
    }

    func key(part: Part, identifier: UInt16, scale: Int, appearance: Appearance = .system) -> [UInt16] {
        Attribute.allCases.map { attribute in
            switch attribute {
            case .element: Self.element
            case .part: part.rawValue
            case .identifier: identifier
            case .scale: UInt16(scale)
            case .appearance: appearance.rawValue
            case .localization, .size, .idiom: 0
            }
        }
    }

    func facet(part: Part, identifier: UInt16) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt16(0)) // hot spot x
        data.appendLittleEndian(UInt16(0)) // hot spot y
        let attributes: [(Attribute, UInt16)] = [
            (.element, Self.element), (.part, part.rawValue), (.identifier, identifier),
        ]
        data.appendLittleEndian(UInt16(attributes.count))
        for (attribute, value) in attributes {
            data.appendLittleEndian(attribute.rawValue)
            data.appendLittleEndian(value)
        }
        return data
    }

    /// One mask per key attribute: which values the name's renditions use.
    func bitmapKeyValue(scales: Set<Int>) -> Data {
        var data = Data()
        for field: UInt32 in [1, 0, 36, UInt32(Attribute.allCases.count)] {
            data.appendLittleEndian(field)
        }
        for attribute in Attribute.allCases {
            let mask: UInt32 = switch attribute {
            case .scale: scales.reduce(0) { $0 | (1 << UInt32($1)) }
            case .localization, .size, .idiom: 1 // always 0
            case .appearance, .element, .part, .identifier: .max // as observed
            }
            data.appendLittleEndian(mask)
        }
        return data
    }

    // MARK: Renditions

    enum InfoType: UInt32 {
        case slices = 0x3e9
        case metrics = 0x3eb
        case composition = 0x3ec
        case uti = 0x3ee
        case bytesPerRow = 0x3ef
    }

    func info(_ type: InfoType, _ fields: [UInt32]) -> Data {
        var data = Data()
        data.appendLittleEndian(type.rawValue)
        data.appendLittleEndian(UInt32(fields.count * 4))
        for field in fields { data.appendLittleEndian(field) }
        return data
    }

    func rendition(
        name: String, flags: UInt32, width: Int, height: Int, scale: Int,
        pixelFormat: String, colorSpace: UInt32, layout: UInt16, info: Data, payload: Data
    ) -> Data {
        var data = Data("ISTC".utf8) // 'CTSI', little-endian
        data.appendLittleEndian(UInt32(1)) // version
        data.appendLittleEndian(flags)
        data.appendLittleEndian(UInt32(width))
        data.appendLittleEndian(UInt32(height))
        data.appendLittleEndian(UInt32(scale * 100))
        data.append(Data(pixelFormat.utf8.reversed()).padded(to: 4))
        data.appendLittleEndian(colorSpace)
        data.appendLittleEndian(UInt32(0)) // modification time
        data.appendLittleEndian(layout)
        data.appendLittleEndian(UInt16(0))
        data.append(Data(name.utf8.prefix(127)).padded(to: 128))
        data.appendLittleEndian(UInt32(info.count))
        data.appendLittleEndian(UInt32(1)) // bitmap count
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(payload.count))
        return data + info + payload
    }

    func bitmapRendition(name: String, _ bitmap: Bitmap, fromVector: Bool = false) throws -> Data {
        // colorSpace 1 is sRGB (0 would be Generic RGB).
        let bytesPerRow = bitmap.width * 4
        guard bitmap.pixels.count == bytesPerRow * bitmap.height else {
            throw CarError("\(name): expected \(bytesPerRow * bitmap.height) bytes of pixels")
        }
        let width = UInt32(bitmap.width), height = UInt32(bitmap.height)
        var info = Data()
        info += self.info(.slices, [1, 0, 0, width, height])
        info += self.info(.metrics, [1, 0, 0, 0, 0, width, height])
        info += self.info(.composition, [0, 0x3f80_0000]) // blend mode, opacity 1.0
        info += self.info(.uti, [1])
        info += self.info(.bytesPerRow, [UInt32(bytesPerRow)])

        var payload = Data("MLEC".utf8) // 'CELM'
        payload.appendLittleEndian(UInt32(0)) // flags (bit 0: chunked)
        let compressed = try LZFSE.compress(bitmap.pixels)
        payload.appendLittleEndian(Self.compressionLZFSE)
        payload.appendLittleEndian(UInt32(compressed.count))
        payload += compressed

        return rendition(
            // bitmaps rendered from a vector carry flags 0x114 rather than 0x10
            name: name, flags: fromVector ? 0x114 : 0x10, width: bitmap.width, height: bitmap.height, scale: bitmap.scale,
            pixelFormat: "ARGB", colorSpace: 1, layout: 0xc, info: info, payload: payload
        )
    }

    func vectorRendition(name: String, svg: Data) throws -> Data {
        var info = Data()
        info += self.info(.composition, [0, 0x3f80_0000])
        info += self.info(.uti, [1])

        let compressed = try LZFSE.compress(svg)
        var payload = Data("DWAR".utf8) // 'RAWD'
        payload.appendLittleEndian(UInt32(1)) // version
        payload.appendLittleEndian(UInt32(compressed.count))
        payload += compressed
        return rendition(
            name: name, flags: 4, width: 0, height: 0, scale: 0,
            pixelFormat: "SVG ", colorSpace: 0, layout: 9, info: info, payload: payload
        )
    }

    func colorRendition(name: String, components: [Double], space: UInt32 = 1) -> Data {
        var info = Data()
        info += self.info(.composition, [0, 0])
        info += self.info(.uti, [1])

        var payload = Data("RLOC".utf8) // 'COLR'
        payload.appendLittleEndian(UInt32(1)) // version
        payload.appendLittleEndian(space) // color space: 1 sRGB (see LayeredIcon.Color)
        payload.appendLittleEndian(UInt32(components.count))
        for component in components {
            payload.appendLittleEndian(component.bitPattern)
        }
        return rendition(
            name: name, flags: 0, width: 0, height: 0, scale: 0,
            pixelFormat: "", colorSpace: 0, layout: 0x3f1, info: info, payload: payload
        )
    }
}

public struct CarError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}
