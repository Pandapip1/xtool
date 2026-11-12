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
        /// The color space as Icon Composer names it.
        public var space: String
        public var red, green, blue, alpha: Double

        /// Icon Composer's color spaces and CoreUI's numbers for them; these
        /// are all actool accepts.
        static let spaces: [String: UInt32] = [
            "srgb": 1, "gray": 2, "display-p3": 3, "extended-srgb": 4, "extended-gray": 6,
        ]

        /// "extended-srgb:0.2,0.78,0.35,1.0", "display-p3:...", "gray:0.5,1.0", ...
        /// (The flattened SVG treats every space as sRGB.)
        init?(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, Self.spaces[String(parts[0])] != nil else { return nil }
            space = String(parts[0])
            let values = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch (space.hasSuffix("gray"), values.count) {
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
        /// Scale and offset of the image's center from the canvas center, in
        /// points, with the group's position applied.
        public var scale: Double
        public var translation: (x: Double, y: Double)
        public var opacity: Double
        /// Opacity before the group's own is applied.
        public var ownOpacity: Double
        public var glass: Bool
        /// A `CGBlendMode` value.
        public var blendMode: UInt32
        /// Paints the image's shape in this color.
        public var fill: Color?
    }

    public struct Group: Sendable {
        /// Bottom-most first.
        public var layers: [Layer]
        public var opacity: Double
        public var combinedLighting: Bool
        public var blur: Double
        public var specular: Bool
        /// 0 when translucency is off.
        public var translucency: Double
        /// "neutral", "layer-color" or "none".
        public var shadow: String
        public var shadowOpacity: Double
    }

    /// Icon Composer draws on a 1024-point square.
    public static let canvas = 1024.0

    public var fill: Fill?
    /// Bottom-most first.
    public var groups: [Group]
    /// Every visible layer, bottom-most first.
    public var layers: [Layer] { groups.flatMap(\.layers) }

    public init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("icon.json")))
        guard let root = json as? [String: Any] else { throw CarError("\(url.lastPathComponent): icon.json is not an object") }

        fill = try Self.fill(root["fill"])

        func position(_ object: [String: Any]) -> (scale: Double, x: Double, y: Double) {
            let position = object["position"] as? [String: Any] ?? [:]
            let translation = position["translation-in-points"] as? [Double] ?? [0, 0]
            return (position["scale"] as? Double ?? 1, translation.first ?? 0, translation.dropFirst().first ?? 0)
        }

        // Groups and their layers are listed top-most first.
        var groups: [Group] = []
        for group in (root["groups"] as? [[String: Any]] ?? []).reversed() where group["hidden"] as? Bool != true {
            let groupOpacity = group["opacity"] as? Double ?? 1
            let groupPosition = position(group)
            var layers: [Layer] = []
            for layer in (group["layers"] as? [[String: Any]] ?? []).reversed() where layer["hidden"] as? Bool != true {
                guard let name = layer["image-name"] as? String else { continue }
                let own = position(layer)
                let opacity = layer["opacity"] as? Double ?? 1
                var fill: Color?
                if let object = layer["fill"] as? [String: Any], let solid = object["solid"] as? String {
                    fill = try Self.color(solid)
                }
                layers.append(Layer(
                    image: url.appendingPathComponent("Assets").appendingPathComponent(name),
                    // The group scales about the canvas center, then moves.
                    scale: own.scale * groupPosition.scale,
                    translation: (own.x * groupPosition.scale + groupPosition.x, own.y * groupPosition.scale + groupPosition.y),
                    opacity: opacity * groupOpacity,
                    ownOpacity: opacity,
                    glass: layer["glass"] as? Bool ?? true, // on unless turned off
                    blendMode: Self.blendModes[layer["blend-mode"] as? String ?? "normal"] ?? 0,
                    fill: fill
                ))
            }
            guard !layers.isEmpty else { continue }
            let translucency = group["translucency"] as? [String: Any]
            let shadow = group["shadow"] as? [String: Any]
            groups.append(Group(
                layers: layers,
                opacity: groupOpacity,
                combinedLighting: group["lighting"] as? String == "combined",
                blur: group["blur-material"] as? Double ?? 0,
                specular: group["specular"] as? Bool ?? true,
                translucency: translucency?["enabled"] as? Bool == false ? 0 : translucency?["value"] as? Double ?? 0.3,
                shadow: shadow?["kind"] as? String ?? "neutral",
                shadowOpacity: shadow?["opacity"] as? Double ?? 0.5
            ))
        }
        self.groups = groups
    }

    /// Icon Composer's blend mode names, as `CGBlendMode` values.
    static let blendModes: [String: UInt32] = [
        "normal": 0, "multiply": 1, "screen": 2, "overlay": 3, "darken": 4, "lighten": 5,
        "color-dodge": 6, "color-burn": 7, "soft-light": 8, "hard-light": 9, "difference": 10,
        "exclusion": 11, "hue": 12, "saturation": 13, "color": 14, "luminosity": 15,
        "plus-darker": 26, "plus-lighter": 27,
    ]

    /// The icon as layers and materials that the system renders itself, for
    /// an asset catalog.
    public func layeredIcon(name: String) throws -> CarWriter.LayeredIcon {
        // actool keeps three decimals, rounded as "%.3f" does (from the exact
        // binary value, ties to even), stored as single precision. The
        // system's rendering is sensitive enough to the difference to shift
        // colors by about one level out of 255, so do the same.
        func quantize(_ v: Double) -> Double { Double(Float(String(format: "%.3f", v))!) }
        func color(_ color: Color) -> CarWriter.LayeredIcon.Color {
            let space = Color.spaces[color.space]!
            let components = color.space.hasSuffix("gray")
                ? [color.red, color.alpha] : [color.red, color.green, color.blue, color.alpha]
            return .init(space: space, components: components.map(quantize))
        }
        let fill: CarWriter.LayeredIcon.Fill? = switch fill {
        case .solid(let c)?: .color(color(c))
        case .linearGradient(let colors, let start, let stop)?:
            .linearGradient(color(colors[0]), color(colors.count > 1 ? colors[1] : colors[0]), start: start, stop: stop)
        case nil: nil
        }
        return CarWriter.LayeredIcon(name: name, fill: fill, groups: try groups.map { group in
            var result = CarWriter.LayeredIcon.Group(layers: try group.layers.map { layer in
                let data = try Data(contentsOf: layer.image)
                let image: CarWriter.LayeredIcon.Image
                let size: (Double, Double)
                switch layer.image.pathExtension.lowercased() {
                case "svg":
                    image = .svg(data)
                    size = Self.svgSize(String(decoding: data, as: UTF8.self)) ?? (Self.canvas, Self.canvas)
                case "png":
                    let png = try PNGDecoder.decode(data)
                    image = .bitmap(.init(scale: 1, width: png.width, height: png.height, pixels: png.pixels))
                    size = (Double(png.width), Double(png.height))
                default:
                    throw CarError("\(layer.image.lastPathComponent): unsupported icon layer image type")
                }
                let w = size.0 * layer.scale, h = size.1 * layer.scale
                var result = CarWriter.LayeredIcon.Layer(
                    image: image,
                    x: Int(((Self.canvas - w) / 2 + layer.translation.x).rounded()),
                    y: Int(((Self.canvas - h) / 2 + layer.translation.y).rounded()),
                    width: Int(w.rounded()), height: Int(h.rounded())
                )
                result.blendMode = layer.blendMode
                result.opacity = layer.ownOpacity
                result.glass = layer.glass
                result.fill = layer.fill.map(color)
                return result
            })
            result.opacity = group.opacity
            result.combinedLighting = group.combinedLighting
            result.blur = group.blur
            result.specular = group.specular
            result.translucency = group.translucency
            result.shadow = switch group.shadow {
            case "none": .none
            case "layer-color": .layerColor
            default: .neutral
            }
            result.shadowOpacity = group.shadowOpacity
            return result
        })
    }

    /// A color, or an error naming it when it is not one Icon Composer writes.
    private static func color(_ text: String) throws -> Color {
        guard let color = Color(text) else { throw CarError("icon.json: unsupported color '\(text)'") }
        return color
    }

    private static func fill(_ value: Any?) throws -> Fill? {
        guard let fill = value as? [String: Any] else { return nil }
        if let solid = fill["solid"] as? String {
            return .solid(try color(solid))
        }
        if let stops = fill["linear-gradient"] as? [String] {
            let colors = try stops.map(color)
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
