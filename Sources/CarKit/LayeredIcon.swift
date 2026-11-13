import Foundation

/// Encodes a `CarWriter.LayeredIcon` as the renditions the system renders app
/// icons from (see "Layered icons" in Documentation/Formats/AssetCatalog.md):
///
/// - `<name>` (part 245): the stack, one per appearance (dark, light,
///   tintable): the background fill, then one entry per group, with each
///   group's material settings.
/// - `<name>/Group`, `<name>/Group-2`, ... (part 246), per appearance: a
///   group's image layers, with their frames, blend modes, opacity, glass and
///   fills.
/// - `<name>_Assets/Layer-N` (part 181): each distinct layer image.
/// - `<name>_Assets/Color-N` (217) and `Gradient-N`, `system-light`,
///   `system-dark` (247): the fills, referred to by key or by name.
struct LayeredIconParts {
    typealias Icon = CarWriter.LayeredIcon

    struct Named {
        var name: String
        /// The part the name's facet points at.
        var part: CarWriter.Part
        var renditions: [(key: [UInt16], value: Data)]
    }

    /// One appearance's background and groups.
    struct Look {
        var appearance: CarWriter.Appearance
        var fill: Icon.Fill
        var groups: [Icon.Group]
    }

    let icon: Icon
    let looks: [Look]

    // Names, in order of first use.
    private var images: [Icon.Image] = []
    private var colors: [Icon.Color] = []
    private var gradients: [(name: String, fill: Icon.Fill)] = []

    /// The default background: white.
    private static let white = Icon.Fill.color(.gray(1))
    /// The system's backgrounds, which actool writes as these gradients.
    private static let systemLight = Icon.Fill.linearGradient(
        Icon.Color(space: 2, components: [1, 1]),
        Icon.Color(space: 2, components: [Double(Float(0.925)), 1]),
        start: (0.5, 0), stop: (0.5, 1)
    )
    private static let systemDark = Icon.Fill.linearGradient(
        Icon.Color(space: 2, components: [Double(Float(0.192)), 1]),
        Icon.Color(space: 2, components: [Double(Float(0.078)), 1]),
        start: (0.5, 0), stop: (0.5, 1)
    )

    init(_ icon: Icon) {
        self.icon = icon
        let light: Icon.Fill = switch icon.fill {
        case nil: Self.white
        case .automatic?: Self.systemLight
        case let fill?: fill
        }
        let dark: Icon.Fill = switch icon.dark?.fill {
        case nil, .automatic?: Self.systemDark
        case let fill?: fill
        }
        looks = [
            Look(appearance: .dark, fill: dark, groups: icon.dark?.groups ?? icon.groups),
            Look(appearance: .light, fill: light, groups: icon.groups),
            Look(appearance: .tintable, fill: light, groups: icon.tinted?.groups ?? icon.groups),
        ]

        // Collect what the looks use, so each gets one name.
        for look in looks {
            add(look.fill, background: true)
            for group in look.groups {
                for layer in group.layers {
                    if !images.contains(layer.image) { images.append(layer.image) }
                    if let fill = layer.fill { add(fill, background: false) }
                }
            }
        }
    }

    private var prefix: String { icon.name + "_Assets/" }

    private mutating func add(_ fill: Icon.Fill, background: Bool) {
        func addColor(_ color: Icon.Color) { if !colors.contains(color) { colors.append(color) } }
        switch fill {
        case .color(let color):
            addColor(color)
        case .linearGradient(let from, let to, _, _):
            addColor(from)
            addColor(to)
            guard gradientName(fill) == nil else { return }
            let name = switch Self.key(fill) {
            case Self.key(Self.systemDark): prefix + "system-dark"
            case Self.key(Self.systemLight): prefix + "system-light"
            default: prefix + "Gradient-\(gradients.filter { !$0.name.hasSuffix("system-dark") && !$0.name.hasSuffix("system-light") }.count + 1)"
            }
            gradients.append((name, fill))
        case .automatic:
            break
        }
    }

    private static func key(_ fill: Icon.Fill) -> String {
        switch fill {
        case .color(let c): "c\(c.space)\(c.components)"
        case .linearGradient(let a, let b, let s, let e): "g\(a.space)\(a.components)\(b.space)\(b.components)\(s)\(e)"
        case .automatic: "auto"
        }
    }

    private func gradientName(_ fill: Icon.Fill) -> String? {
        gradients.first { Self.key($0.fill) == Self.key(fill) }?.name
    }

    private func colorName(_ color: Icon.Color) -> String {
        "\(prefix)Color-\(colors.firstIndex(of: color)! + 1)"
    }

    /// The rendition a fill refers to: a color or a gradient.
    private func reference(_ fill: Icon.Fill) -> (part: CarWriter.Part, name: String)? {
        switch fill {
        case .color(let color): (.color, colorName(color))
        case .linearGradient: (.gradient, gradientName(fill)!)
        case .automatic: nil
        }
    }

    private func imageName(_ image: Icon.Image) -> String {
        "\(prefix)Layer-\(images.firstIndex(of: image)! + 1)"
    }

    private func groupName(_ index: Int) -> String {
        index == 0 ? "\(icon.name)/Group" : "\(icon.name)/Group-\(index + 1)"
    }

    private var groupCount: Int { looks.map(\.groups.count).max() ?? 0 }

    var names: [String] {
        [icon.name]
            + (0..<groupCount).map(groupName)
            + images.map(imageName)
            + colors.map(colorName)
            + gradients.map(\.name)
    }

    func renditions(writer: CarWriter, identifiers: [String: UInt16]) throws -> [Named] {
        func id(_ name: String) -> UInt16 { identifiers[name]! }
        var result: [Named] = []

        for image in images {
            let name = imageName(image)
            let value = switch image {
            case .svg(let svg, let colorSpace): try writer.vectorRendition(name: "image.svg", svg: svg, colorSpace: colorSpace)
            case .bitmap(let bitmap): try writer.bitmapRendition(name: "image.png", bitmap)
            }
            result.append(Named(name: name, part: .bitmap, renditions: [
                (writer.key(part: .bitmap, identifier: id(name), scale: 1), value),
            ]))
        }
        for color in colors {
            let name = colorName(color)
            result.append(Named(name: name, part: .color, renditions: [(
                writer.key(part: .color, identifier: id(name), scale: 1),
                writer.colorRendition(name: name, components: color.components, space: color.space)
            )]))
        }
        for (name, fill) in gradients {
            result.append(Named(name: name, part: .gradient, renditions: [(
                writer.key(part: .gradient, identifier: id(name), scale: 1),
                gradientRendition(writer, name: name, fill)
            )]))
        }

        // Groups, then the stack, for each appearance.
        for g in 0..<groupCount {
            let name = groupName(g)
            let renditions = looks.compactMap { look -> (key: [UInt16], value: Data)? in
                guard look.groups.indices.contains(g) else { return nil }
                return (writer.key(part: .layerGroup, identifier: id(name), scale: 1, appearance: look.appearance),
                        groupRendition(writer, look.groups[g], identifiers: identifiers))
            }
            result.append(Named(name: name, part: .layerGroup, renditions: renditions))
        }
        result.append(Named(name: icon.name, part: .layeredImage, renditions: looks.map { look in
            (writer.key(part: .layeredImage, identifier: id(icon.name), scale: 1, appearance: look.appearance),
             stackRendition(writer, look, identifiers: identifiers))
        }))
        return result
    }

    // MARK: Renditions

    private enum Info: UInt32 {
        case layers = 0x3f4
        case uti = 0x3ed
        case materials = 0x3fc
        case effects = 0x3fd
        case refraction = 0x3fe
    }

    private func info(_ type: Info, count: Int, _ body: Data) -> Data {
        var record = Data()
        record.appendLittleEndian(UInt32(count))
        record.appendLittleEndian(UInt32(0))
        record += body
        var data = Data()
        data.appendLittleEndian(type.rawValue)
        data.appendLittleEndian(UInt32(record.count))
        return data + record
    }

    /// A layer entry: frame, blend mode, opacity, and the key of what it draws.
    private func layerEntry(
        frame: (Int, Int, Int, Int) = (0, 0, 0, 0), blendMode: UInt32 = 0, opacity: Double = 1,
        part: CarWriter.Part, identifier: UInt16
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0))
        for value in [frame.0, frame.1, frame.2, frame.3] { data.appendLittleEndian(UInt32(bitPattern: Int32(value))) }
        data.appendLittleEndian(blendMode)
        data.appendLittleEndian(Float(opacity).bitPattern)
        // A rendition key as (attribute, value) pairs, ending with (0, 0).
        let pairs: [(CarWriter.Attribute, UInt16)] = [(.element, CarWriter.element), (.part, part.rawValue), (.identifier, identifier)]
        data.appendLittleEndian(UInt32(pairs.count * 4 + 4))
        for (attribute, value) in pairs {
            data.appendLittleEndian(attribute.rawValue)
            data.appendLittleEndian(value)
        }
        data.appendLittleEndian(UInt32(0))
        return data
    }

    /// A length-prefixed, NUL-terminated string.
    private func string(_ text: String) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(text.utf8.count + 1))
        data.append(contentsOf: text.utf8)
        data.append(0)
        return data
    }

    private func dataRendition(_ writer: CarWriter, name: String, size: Int, layout: UInt16, info: Data) -> Data {
        var payload = Data("DWAR".utf8) // 'RAWD', empty
        payload.appendLittleEndian(UInt32(0))
        payload.appendLittleEndian(UInt32(0))
        return writer.rendition(
            name: name, flags: 0, width: size, height: size, scale: 1,
            pixelFormat: "DATA", colorSpace: 0, layout: layout,
            info: info + writer.info(.composition, [0, 0x3f80_0000]) + writer.info(.uti, [1]),
            payload: payload
        )
    }

    private func stackRendition(_ writer: CarWriter, _ look: Look, identifiers: [String: UInt16]) -> Data {
        let count = 1 + look.groups.count
        let fill = reference(look.fill)!
        var layers = layerEntry(part: fill.part, identifier: identifiers[fill.name]!)
        var materials = Data(count: 8) + string("")
        var effects = Data(count: 20)
        var refraction = Data(count: 12)
        for (g, group) in look.groups.enumerated() {
            layers += layerEntry(opacity: group.opacity, part: .layerGroup, identifier: identifiers[groupName(g)]!)

            materials.appendLittleEndian(UInt32(group.combinedLighting ? 0 : 2))
            materials.appendLittleEndian(Float(group.blur).bitPattern)
            materials += string("")

            effects.appendLittleEndian(UInt32(group.specular ? 1 : 0))
            effects.appendLittleEndian(Float(group.translucency).bitPattern)
            effects.appendLittleEndian(group.shadow.rawValue)
            effects.appendLittleEndian(Float(group.shadowOpacity).bitPattern)
            effects.appendLittleEndian(UInt32(0))

            refraction.appendLittleEndian(Float(group.refraction?.strength ?? 0).bitPattern)
            refraction.appendLittleEndian(Float(group.refraction?.depth ?? 0).bitPattern)
            refraction.appendLittleEndian(UInt32(0))
        }
        var uti = Data()
        let type = "public.layeredimage"
        uti.appendLittleEndian(UInt32(type.utf8.count + 1))
        uti.appendLittleEndian(UInt32(0))
        uti.append(contentsOf: type.utf8)
        uti.append(0)
        var utiInfo = Data()
        utiInfo.appendLittleEndian(Info.uti.rawValue)
        utiInfo.appendLittleEndian(UInt32(uti.count))
        utiInfo += uti

        let info = self.info(.layers, count: count, layers)
            + self.info(.materials, count: count, materials)
            + self.info(.effects, count: count, effects)
            + self.info(.refraction, count: count, refraction)
            + utiInfo
        return dataRendition(writer, name: icon.name + ".iconstack", size: 1024, layout: 0x3fb, info: info)
    }

    private func groupRendition(_ writer: CarWriter, _ group: Icon.Group, identifiers: [String: UInt16]) -> Data {
        var layers = Data(), materials = Data()
        for layer in group.layers {
            layers += layerEntry(
                frame: (layer.x, layer.y, layer.width, layer.height), blendMode: layer.blendMode,
                opacity: layer.opacity, part: .bitmap, identifier: identifiers[imageName(layer.image)]!
            )
            materials.appendLittleEndian(UInt32(layer.glass ? 1 : 0))
            materials.appendLittleEndian(UInt32(0))
            materials += string(layer.fill.flatMap(reference)?.name ?? "")
        }
        let count = group.layers.count
        let info = self.info(.layers, count: count, layers)
            + self.info(.materials, count: count, materials)
            + self.info(.effects, count: count, Data(count: 20 * count))
            + self.info(.refraction, count: count, Data(count: 12 * count))
        return dataRendition(writer, name: "IconGroup", size: 0, layout: 0x3fc, info: info)
    }

    private func gradientRendition(_ writer: CarWriter, name: String, _ fill: Icon.Fill) -> Data {
        guard case .linearGradient(let from, let to, let start, let stop) = fill else { return Data() }
        var payload = Data("ARGG".utf8)
        payload.appendLittleEndian(UInt32(2)) // version
        payload.appendLittleEndian(UInt32(1)) // linear
        payload.appendLittleEndian(UInt32(0))
        for value in [start.x, start.y, stop.x, stop.y] { payload.appendLittleEndian(Float(value).bitPattern) }
        for (location, color) in [(0.0, from), (1.0, to)] {
            payload.appendLittleEndian(Float(location).bitPattern)
            payload += string(colorName(color))
        }
        return writer.rendition(
            name: name, flags: 0, width: 0, height: 0, scale: 0,
            pixelFormat: "", colorSpace: 0, layout: 0x3fd,
            info: writer.info(.composition, [0, 0]) + writer.info(.uti, [1]),
            payload: payload
        )
    }
}
