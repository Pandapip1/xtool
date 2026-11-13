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
        /// The system's own background for the appearance.
        case automatic
        /// From `start` to `stop`, in unit coordinates of the icon (y down).
        case linearGradient(colors: [Color], start: (x: Double, y: Double), stop: (x: Double, y: Double))

        public static func == (lhs: Fill, rhs: Fill) -> Bool {
            switch (lhs, rhs) {
            case (.solid(let a), .solid(let b)): a == b
            case (.automatic, .automatic): true
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
        /// Paints the image's shape with this instead of its own colors.
        public var fill: Fill?
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
        /// Refraction of what is behind the group's glass; nil when off.
        public var refraction: (strength: Double, depth: Double)?
    }

    /// The appearances an icon can specialize its properties for
    /// (`*-specializations` in icon.json).
    public enum Appearance: String, Sendable, CaseIterable {
        case light, dark, tinted
    }

    /// Icon Composer draws on a 1024-point square.
    public static let canvas = 1024.0

    /// The `.icon` this was read from.
    public let url: URL
    /// The appearance the properties below are resolved for.
    public let appearance: Appearance
    public var fill: Fill?
    /// Bottom-most first.
    public var groups: [Group]
    /// Every visible layer, bottom-most first.
    public var layers: [Layer] { groups.flatMap(\.layers) }
    /// The CoreUI color space of untagged colors in the layers' SVGs:
    /// 0 unspecified (sRGB), 3 Display P3.
    public var svgColorSpace: UInt32

    /// Reads the icon with its properties as they are in `appearance`.
    ///
    /// A property `p` can be given for each appearance as `p-specializations`:
    /// a list of `{"value": ...}`, `{"appearance": "dark", "value": ...}` and so
    /// on. A plain `p` takes precedence over that; otherwise the appearance's
    /// own entry, then the one without an appearance. The tinted appearance
    /// takes the light background, as actool does.
    public init(url: URL, appearance: Appearance = .light) throws {
        self.url = url
        self.appearance = appearance
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("icon.json")))
        guard let root = json as? [String: Any] else { throw CarError("\(url.lastPathComponent): icon.json is not an object") }

        func value(_ object: [String: Any], _ key: String, for appearance: Appearance = appearance) -> Any? {
            if let plain = object[key] { return plain }
            guard let entries = object["\(key)-specializations"] as? [[String: Any]] else { return nil }
            if appearance != .light,
               let entry = entries.first(where: { $0["appearance"] as? String == appearance.rawValue }) {
                return entry["value"]
            }
            return entries.first { $0["appearance"] == nil }?["value"]
        }

        fill = try Self.fill(value(root, "fill", for: appearance == .tinted ? .light : appearance))
        svgColorSpace = root["color-space-for-untagged-svg-colors"] as? String == "display-p3" ? 3 : 0

        func position(_ object: [String: Any]) -> (scale: Double, x: Double, y: Double) {
            let position = value(object, "position") as? [String: Any] ?? [:]
            let translation = position["translation-in-points"] as? [Double] ?? [0, 0]
            return (position["scale"] as? Double ?? 1, translation.first ?? 0, translation.dropFirst().first ?? 0)
        }

        // Groups and their layers are listed top-most first.
        var groups: [Group] = []
        for group in (root["groups"] as? [[String: Any]] ?? []).reversed() where value(group, "hidden") as? Bool != true {
            let groupOpacity = value(group, "opacity") as? Double ?? 1
            let groupPosition = position(group)
            var layers: [Layer] = []
            for layer in (group["layers"] as? [[String: Any]] ?? []).reversed() where value(layer, "hidden") as? Bool != true {
                guard let name = layer["image-name"] as? String else { continue }
                let own = position(layer)
                let opacity = value(layer, "opacity") as? Double ?? 1
                layers.append(Layer(
                    image: url.appendingPathComponent("Assets").appendingPathComponent(name),
                    // The group scales about the canvas center, then moves.
                    scale: own.scale * groupPosition.scale,
                    translation: (own.x * groupPosition.scale + groupPosition.x, own.y * groupPosition.scale + groupPosition.y),
                    opacity: opacity * groupOpacity,
                    ownOpacity: opacity,
                    glass: value(layer, "glass") as? Bool ?? true, // on unless turned off
                    blendMode: Self.blendModes[value(layer, "blend-mode") as? String ?? "normal"] ?? 0,
                    // "none" (and "automatic") leave the image's own colors.
                    fill: try Self.fill(value(layer, "fill")).flatMap { $0 == .automatic ? nil : $0 }
                ))
            }
            guard !layers.isEmpty else { continue }
            let translucency = value(group, "translucency") as? [String: Any]
            let shadow = value(group, "shadow") as? [String: Any]
            let refractivity = value(group, "refractivity") as? [String: Any]
            groups.append(Group(
                layers: layers,
                opacity: groupOpacity,
                combinedLighting: value(group, "lighting") as? String == "combined",
                blur: value(group, "blur-material") as? Double ?? 0,
                specular: value(group, "specular") as? Bool ?? true,
                translucency: translucency?["enabled"] as? Bool == false ? 0 : translucency?["value"] as? Double ?? 0.3,
                shadow: shadow?["kind"] as? String ?? "neutral",
                shadowOpacity: shadow?["opacity"] as? Double ?? 0.5,
                refraction: refractivity?["enabled"] as? Bool == true
                    ? (refractivity?["strength"] as? Double ?? 0, refractivity?["depth"] as? Double ?? 0) : nil
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
        let light = appearance == .light ? self : try IconComposerIcon(url: url, appearance: .light)
        let dark = try IconComposerIcon(url: url, appearance: .dark)
        let tinted = try IconComposerIcon(url: url, appearance: .tinted)
        return CarWriter.LayeredIcon(
            name: name,
            fill: try light.carFill(),
            groups: try light.carGroups(),
            dark: .init(fill: try dark.carFill(), groups: try dark.carGroups()),
            tinted: .init(fill: nil, groups: try tinted.carGroups())
        )
    }

    /// actool keeps three decimals, rounded as "%.3f" does (from the exact
    /// binary value, ties to even), stored as single precision. The system's
    /// rendering is sensitive enough to the difference to shift colors by
    /// about one level out of 255, so do the same.
    private static func carColor(_ color: Color) -> CarWriter.LayeredIcon.Color {
        func quantize(_ v: Double) -> Double { Double(Float(String(format: "%.3f", v))!) }
        let space = Color.spaces[color.space]!
        let components = color.space.hasSuffix("gray")
            ? [color.red, color.alpha] : [color.red, color.green, color.blue, color.alpha]
        return .init(space: space, components: components.map(quantize))
    }

    private static func carFill(_ fill: Fill) -> CarWriter.LayeredIcon.Fill {
        switch fill {
        case .solid(let c): .color(carColor(c))
        case .linearGradient(let colors, let start, let stop):
            .linearGradient(carColor(colors[0]), carColor(colors.count > 1 ? colors[1] : colors[0]), start: start, stop: stop)
        case .automatic: .automatic
        }
    }

    private func carFill() throws -> CarWriter.LayeredIcon.Fill? {
        fill.map(Self.carFill)
    }

    private func carGroups() throws -> [CarWriter.LayeredIcon.Group] {
        try groups.map { group in
            var result = CarWriter.LayeredIcon.Group(layers: try group.layers.map { layer in
                let data = try Data(contentsOf: layer.image)
                let image: CarWriter.LayeredIcon.Image
                let size: (Double, Double)
                switch layer.image.pathExtension.lowercased() {
                case "svg":
                    image = .svg(data, colorSpace: svgColorSpace)
                    size = Self.svgSize(String(decoding: data, as: UTF8.self)) ?? (Self.canvas, Self.canvas)
                case "png":
                    let png = try PNGDecoder.decode(data)
                    image = .bitmap(.init(scale: 1, width: png.width, height: png.height, pixels: png.pixels))
                    size = (Double(png.width), Double(png.height))
                default:
                    throw CarError("\(layer.image.lastPathComponent): unsupported icon layer image type")
                }
                let w = size.0 * layer.scale, h = size.1 * layer.scale
                // Origins round down and sizes to nearest, as actool's do.
                var result = CarWriter.LayeredIcon.Layer(
                    image: image,
                    x: Int(((Self.canvas - w) / 2 + layer.translation.x).rounded(.down)),
                    y: Int(((Self.canvas - h) / 2 + layer.translation.y).rounded(.down)),
                    width: Int(w.rounded()), height: Int(h.rounded())
                )
                result.blendMode = layer.blendMode
                result.opacity = layer.ownOpacity
                result.glass = layer.glass
                result.fill = layer.fill.map(Self.carFill)
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
            result.refraction = group.refraction
            return result
        }
    }

    /// A color, or an error naming it when it is not one Icon Composer writes.
    private static func color(_ text: String) throws -> Color {
        guard let color = Color(text) else { throw CarError("icon.json: unsupported color '\(text)'") }
        return color
    }

    /// A fill: an object with "solid" or "linear-gradient", or "automatic" (the
    /// system's), or "none" and anything else, nil.
    private static func fill(_ value: Any?) throws -> Fill? {
        if value as? String == "automatic" { return .automatic }
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
        // No fill is white; "automatic" the system's light gradient (both as actool has them).
        let white = Color("gray:1,1")!
        let systemLight = Fill.linearGradient(colors: [white, Color("gray:0.925,1")!], start: (0.5, 0), stop: (0.5, 1))
        let backgroundFill: Fill = switch fill {
        case nil: .solid(white)
        case .automatic?: systemLight
        case let fill?: fill
        }
        switch backgroundFill {
        case .solid(let color):
            let c = color.svg
            background = #"<rect x="\#(inset)" y="\#(inset)" width="\#(side)" height="\#(side)" fill="\#(c.color)" fill-opacity="\#(c.opacity)"/>"#
        case .linearGradient(let colors, let start, let stop):
            let stops = colors.enumerated().map { i, color in
                let c = color.svg
                let offset = colors.count == 1 ? 0 : Double(i) / Double(colors.count - 1)
                return #"<stop offset="\#(offset)" stop-color="\#(c.color)" stop-opacity="\#(c.opacity)"/>"#
            }.joined()
            defs += #"<linearGradient id="fill" x1="\#(start.x)" y1="\#(start.y)" x2="\#(stop.x)" y2="\#(stop.y)">\#(stops)</linearGradient>"#
            background = #"<rect x="\#(inset)" y="\#(inset)" width="\#(side)" height="\#(side)" fill="url(#fill)"/>"#
        case .automatic:
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
