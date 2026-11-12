import Foundation

/// An Icon Composer document (`.icon`: `icon.json` plus `Assets/`), flattened
/// into a single SVG that an SVG renderer turns into app icon images.
///
/// Supported: the background fill (solid colors and linear gradients), and
/// each layer's image (SVG or PNG), position, scale, opacity and visibility.
/// The system's material effects (glass, shadows, translucency, specular
/// highlights) are not reproduced; the icon looks like it would with them
/// turned off.
public struct IconComposerIcon: Sendable {
    public struct Color: Sendable, Equatable {
        public var red, green, blue, alpha: Double

        /// "extended-srgb:0.2,0.78,0.35,1.0", "srgb:...", "display-p3:...",
        /// "gray:0.5,1.0" (display P3 is taken as sRGB).
        init?(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let values = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch (parts[0].hasSuffix("gray"), values.count) {
            case (true, 2): (red, green, blue, alpha) = (values[0], values[0], values[0], values[1])
            case (false, 4): (red, green, blue, alpha) = (values[0], values[1], values[2], values[3])
            default: return nil
            }
        }

        var svg: (color: String, opacity: String) {
            func channel(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            return ("rgb(\(channel(red)),\(channel(green)),\(channel(blue)))", String(format: "%.4f", alpha))
        }
    }

    public enum Fill: Sendable, Equatable {
        case solid(Color)
        /// From `start` to `stop`, in unit coordinates of the icon (y down).
        case linearGradient(colors: [Color], start: (x: Double, y: Double), stop: (x: Double, y: Double))

        public static func == (lhs: Fill, rhs: Fill) -> Bool {
            switch (lhs, rhs) {
            case (.solid(let a), .solid(let b)): a == b
            case (.linearGradient(let a, let s1, let e1), .linearGradient(let b, let s2, let e2)):
                a == b && s1 == s2 && e1 == e2
            default: false
            }
        }
    }

    public struct Layer: Sendable {
        public var image: URL
        public var scale: Double
        /// Offset of the image's center from the canvas center, in points.
        public var translation: (x: Double, y: Double)
        public var opacity: Double
    }

    /// Icon Composer draws on a 1024-point square.
    public static let canvas = 1024.0

    public var fill: Fill?
    /// Bottom-most first.
    public var layers: [Layer]

    public init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("icon.json")))
        guard let root = json as? [String: Any] else { throw CarError("\(url.lastPathComponent): icon.json is not an object") }

        fill = Self.fill(root["fill"])

        // Groups and their layers are listed top-most first.
        var layers: [Layer] = []
        for group in (root["groups"] as? [[String: Any]] ?? []).reversed() where group["hidden"] as? Bool != true {
            let groupOpacity = group["opacity"] as? Double ?? 1
            for layer in (group["layers"] as? [[String: Any]] ?? []).reversed() where layer["hidden"] as? Bool != true {
                guard let name = layer["image-name"] as? String else { continue }
                let position = layer["position"] as? [String: Any] ?? [:]
                let translation = position["translation-in-points"] as? [Double] ?? [0, 0]
                layers.append(Layer(
                    image: url.appendingPathComponent("Assets").appendingPathComponent(name),
                    scale: position["scale"] as? Double ?? 1,
                    translation: (translation.first ?? 0, translation.dropFirst().first ?? 0),
                    opacity: (layer["opacity"] as? Double ?? 1) * groupOpacity
                ))
            }
        }
        self.layers = layers
    }

    private static func fill(_ value: Any?) -> Fill? {
        guard let fill = value as? [String: Any] else { return nil }
        if let solid = fill["solid"] as? String, let color = Color(solid) {
            return .solid(color)
        }
        if let stops = fill["linear-gradient"] as? [String] {
            let colors = stops.compactMap(Color.init)
            let orientation = fill["orientation"] as? [String: [String: Double]] ?? [:]
            let start = orientation["start"] ?? ["x": 0.5, "y": 0]
            let stop = orientation["stop"] ?? ["x": 0.5, "y": 1]
            guard !colors.isEmpty else { return nil }
            return .linearGradient(
                colors: colors,
                start: (start["x"] ?? 0.5, start["y"] ?? 0),
                stop: (stop["x"] ?? 0.5, stop["y"] ?? 1)
            )
        }
        return nil
    }

    public enum Shape: Sendable {
        /// The full square, for platforms that mask icons themselves (iOS).
        case square
        /// macOS: an 824-point rounded square centered on the 1024 grid.
        case macOS
    }

    /// The flattened icon as an SVG of `size` × `size` pixels.
    public func svg(size: Int, shape: Shape) throws -> String {
        let (inset, side, radius): (Double, Double, Double) = switch shape {
        case .square: (0, Self.canvas, 0)
        case .macOS: (100, 824, 185.4)
        }

        var defs = """
        <clipPath id="shape"><rect x="\(inset)" y="\(inset)" width="\(side)" height="\(side)" rx="\(radius)"/></clipPath>
        """
        var background = ""
        switch fill {
        case .solid(let color)?:
            let c = color.svg
            background = #"<rect x="\#(inset)" y="\#(inset)" width="\#(side)" height="\#(side)" fill="\#(c.color)" fill-opacity="\#(c.opacity)"/>"#
        case .linearGradient(let colors, let start, let stop)?:
            let stops = colors.enumerated().map { i, color in
                let c = color.svg
                let offset = colors.count == 1 ? 0 : Double(i) / Double(colors.count - 1)
                return #"<stop offset="\#(offset)" stop-color="\#(c.color)" stop-opacity="\#(c.opacity)"/>"#
            }.joined()
            defs += #"<linearGradient id="fill" x1="\#(start.x)" y1="\#(start.y)" x2="\#(stop.x)" y2="\#(stop.y)">\#(stops)</linearGradient>"#
            background = #"<rect x="\#(inset)" y="\#(inset)" width="\#(side)" height="\#(side)" fill="url(#fill)"/>"#
        case nil:
            break
        }

        var images = ""
        for layer in layers {
            let (width, height, uri) = try Self.embed(layer.image)
            let w = width * layer.scale, h = height * layer.scale
            let x = (Self.canvas - w) / 2 + layer.translation.x
            let y = (Self.canvas - h) / 2 + layer.translation.y
            images += #"<image x="\#(x)" y="\#(y)" width="\#(w)" height="\#(h)" opacity="\#(layer.opacity)" href="\#(uri)"/>"#
        }

        let contentScale = side / Self.canvas
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(Self.canvas) \(Self.canvas)">
        <defs>\(defs)</defs>
        <g clip-path="url(#shape)">\(background)<g transform="translate(\(inset) \(inset)) scale(\(contentScale))">\(images)</g></g>
        </svg>
        """
    }

    /// The image's natural size in points and a data URI for it.
    private static func embed(_ url: URL) throws -> (Double, Double, String) {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "svg":
            let size = svgSize(String(decoding: data, as: UTF8.self)) ?? (canvas, canvas)
            return (size.0, size.1, "data:image/svg+xml;base64," + data.base64EncodedString())
        case "png":
            let image = try PNGDecoder.decode(data)
            return (Double(image.width), Double(image.height), "data:image/png;base64," + data.base64EncodedString())
        default:
            throw CarError("\(url.lastPathComponent): unsupported icon layer image type")
        }
    }

    /// The width and height of an SVG document (from its attributes, else viewBox).
    static func svgSize(_ svg: String) -> (Double, Double)? {
        guard let open = svg.range(of: "<svg"), let close = svg[open.upperBound...].range(of: ">") else { return nil }
        let tag = String(svg[open.upperBound..<close.lowerBound])
        func attribute(_ name: String) -> String? {
            guard let start = tag.range(of: " \(name)=\"") else { return nil }
            return tag[start.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        func number(_ text: String?) -> Double? {
            text.flatMap { Double($0.trimmingCharacters(in: .letters.union(.whitespaces))) }
        }
        if let width = number(attribute("width")), let height = number(attribute("height")) {
            return (width, height)
        }
        let box = attribute("viewBox")?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        if let box, box.count == 4 { return (box[2], box[3]) }
        return nil
    }
}

/// Writes Apple icon files (`.icns`): a header and PNG entries by type code.
public enum ICNSWriter {
    /// The entry types for each pixel size of a full macOS icon set.
    public static let entries: [(type: String, size: Int)] = [
        ("icp4", 16), ("icp5", 32), ("ic11", 32), ("icp6", 64), ("ic12", 64),
        ("ic07", 128), ("ic08", 256), ("ic13", 256), ("ic09", 512), ("ic14", 512), ("ic10", 1024),
    ]

    /// `pngs` maps pixel sizes to PNG data; every size in `entries` is required.
    public static func write(pngs: [Int: Data]) throws -> Data {
        var body = Data()
        for entry in entries {
            guard let png = pngs[entry.size] else { throw CarError("icns: missing \(entry.size)px image") }
            body.append(contentsOf: entry.type.utf8)
            body.appendBigEndian(UInt32(8 + png.count))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.appendBigEndian(UInt32(8 + body.count))
        return file + body
    }
}
