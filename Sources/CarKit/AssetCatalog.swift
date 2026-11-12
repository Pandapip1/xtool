import Foundation

/// Reads asset catalog sources (`.xcassets` directories) and compiles them
/// into `Assets.car` data with CarWriter.
///
/// Supported so far: color sets and image sets of PNG or SVG files (SVGs need
/// `renderSVG`), for the `universal` (or platform) idiom and the default
/// appearance. Anything else is reported
/// through `warnings` and left out.
public struct AssetCatalog: Sendable {
    public private(set) var assets: [CarWriter.Asset] = []
    public private(set) var warnings: [String] = []

    /// Idioms to use, most specific first; `universal` always applies.
    public var idioms: [String]

    /// Renders an SVG file to PNG data at a scale (1 is its own size). SVG
    /// images are skipped, with a warning, when there is none.
    public typealias SVGRenderer = @Sendable (_ svg: URL, _ scale: Int) throws -> Data
    public var renderSVG: SVGRenderer?
    /// The scales bitmaps are rendered at for SVG images.
    public var vectorScales = [1, 2]

    public init(idioms: [String] = ["universal"]) {
        self.idioms = idioms
    }

    /// Adds every color set and image set in the catalog at `url`.
    public mutating func add(catalogAt url: URL) throws {
        try addGroup(at: url, namespace: "")
    }

    /// Adds an asset that does not come from a catalog, such as an app icon.
    public mutating func add(_ asset: CarWriter.Asset) {
        assets.append(asset)
    }

    /// Compiles everything added so far.
    public func compile(deploymentTarget: String, platform: String) throws -> Data {
        var writer = CarWriter()
        writer.assets = assets
        writer.deploymentTarget = deploymentTarget
        writer.platform = platform
        return try writer.serialize()
    }

    private mutating func addGroup(at url: URL, namespace: String) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries where entry.hasDirectoryPath || entry.isDirectory {
            let name = namespace + entry.deletingPathExtension().lastPathComponent
            switch entry.pathExtension {
            case "colorset":
                try addColorSet(at: entry, name: name)
            case "imageset":
                try addImageSet(at: entry, name: name)
            case "":
                // A group: its names are prefixed when it provides a namespace.
                let contents = try? Contents.load(from: entry)
                let providesNamespace = contents?.properties?.providesNamespace ?? false
                try addGroup(at: entry, namespace: providesNamespace ? name + "/" : namespace)
            default:
                warnings.append("\(entry.lastPathComponent): \(entry.pathExtension) sets are not supported yet")
            }
        }
    }

    // MARK: Contents.json

    private struct Contents: Decodable {
        struct Properties: Decodable {
            var providesNamespace: Bool?
            enum CodingKeys: String, CodingKey { case providesNamespace = "provides-namespace" }
        }
        struct Appearance: Decodable {}
        struct ColorEntry: Decodable {
            struct Color: Decodable {
                var colorSpace: String?
                var components: [String: Component]
                enum CodingKeys: String, CodingKey {
                    case colorSpace = "color-space"
                    case components
                }
            }
            var idiom: String?
            var color: Color?
            var appearances: [Appearance]?
        }
        struct ImageEntry: Decodable {
            var idiom: String?
            var filename: String?
            var scale: String?
            var appearances: [Appearance]?
        }

        var properties: Properties?
        var colors: [ColorEntry]?
        var images: [ImageEntry]?

        static func load(from directory: URL) throws -> Contents {
            let data = try Data(contentsOf: directory.appendingPathComponent("Contents.json"))
            return try JSONDecoder().decode(Contents.self, from: data)
        }
    }

    /// A color component as written in Contents.json: "0.500", "128", or "0x80".
    private struct Component: Decodable {
        var value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
                return
            }
            let text = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix("0x"), let byte = UInt8(text.dropFirst(2), radix: 16) {
                value = Double(byte) / 255
            } else if text.contains("."), let number = Double(text) {
                value = number
            } else if let byte = Int(text) {
                value = Double(byte) / 255
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad color component '\(text)'")
            }
        }
    }

    /// The entries for the most specific idiom present, default appearance only.
    private func select<Entry>(_ entries: [Entry], idiom: KeyPath<Entry, String?>, appearances: KeyPath<Entry, [Contents.Appearance]?>) -> [Entry] {
        let plain = entries.filter { ($0[keyPath: appearances] ?? []).isEmpty }
        for wanted in idioms + ["universal"] {
            let matching = plain.filter { ($0[keyPath: idiom] ?? "universal") == wanted }
            if !matching.isEmpty { return matching }
        }
        return []
    }

    // MARK: Sets

    private mutating func addColorSet(at url: URL, name: String) throws {
        let contents = try Contents.load(from: url)
        guard let entry = select(contents.colors ?? [], idiom: \.idiom, appearances: \.appearances).first,
              let color = entry.color
        else {
            warnings.append("\(name): no color for the default appearance")
            return
        }
        let c = color.components.mapValues(\.value)
        let space = color.colorSpace ?? "srgb"
        switch space {
        case "srgb", "extended-srgb":
            assets.append(.color(name: name, red: c["red"] ?? 0, green: c["green"] ?? 0, blue: c["blue"] ?? 0, alpha: c["alpha"] ?? 1))
        case "gray-gamma-22", "extended-gray":
            let white = c["white"] ?? 0
            assets.append(.color(name: name, red: white, green: white, blue: white, alpha: c["alpha"] ?? 1))
        default:
            warnings.append("\(name): color space \(space) is not supported yet; treating it as sRGB")
            assets.append(.color(name: name, red: c["red"] ?? 0, green: c["green"] ?? 0, blue: c["blue"] ?? 0, alpha: c["alpha"] ?? 1))
        }
    }

    private mutating func addImageSet(at url: URL, name: String) throws {
        let contents = try Contents.load(from: url)
        var bitmaps: [CarWriter.Bitmap] = []
        var svg: (url: URL, data: Data)?
        for entry in select(contents.images ?? [], idiom: \.idiom, appearances: \.appearances) {
            guard let filename = entry.filename else { continue }
            let scale = entry.scale.flatMap { Int($0.dropLast()) } ?? 1
            let file = url.appendingPathComponent(filename)
            switch file.pathExtension.lowercased() {
            case "png":
                let image = try PNGDecoder.decode(Data(contentsOf: file))
                bitmaps.append(.init(scale: scale, width: image.width, height: image.height, pixels: image.pixels))
            case "svg":
                svg = (file, try Data(contentsOf: file))
            default:
                warnings.append("\(name): \(file.pathExtension) images are not supported yet")
            }
        }
        if let svg {
            guard let renderSVG else {
                warnings.append("\(name): SVG images need an SVG renderer (resvg)")
                return
            }
            // The vector data, plus bitmaps for the platform's scales.
            let rendered = try vectorScales.map { scale in
                let image = try PNGDecoder.decode(renderSVG(svg.url, scale))
                return CarWriter.Bitmap(scale: scale, width: image.width, height: image.height, pixels: image.pixels)
            }
            assets.append(.vector(name: name, svg: svg.data, bitmaps: rendered))
        } else if bitmaps.isEmpty {
            warnings.append("\(name): no usable images")
        } else {
            assets.append(.image(name: name, bitmaps: bitmaps))
        }
    }
}

extension URL {
    fileprivate var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
