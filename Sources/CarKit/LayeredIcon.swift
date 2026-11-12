import Foundation

/// Encodes a `CarWriter.LayeredIcon` as the renditions the system renders app
/// icons from (see "Layered icons" in Documentation/Formats/AssetCatalog.md):
///
/// - `<name>` (part 245): the stack, one per appearance: the background fill,
///   then one entry per group, with each group's material settings.
/// - `<name>/Group`, `<name>/Group-2`, ... (part 246): a group's image layers,
///   with their frames, blend modes, opacity and glass.
/// - `<name>_Assets/Layer-N` (part 181): each layer's image, SVG or bitmap.
/// - `<name>_Assets/Color-N` (217) and `Gradient-1`, `system-dark` (247):
///   the fills, referred to by key or by name.
struct LayeredIconParts {
    typealias Icon = CarWriter.LayeredIcon

    struct Named {
        var name: String
        /// The part the name's facet points at.
        var part: CarWriter.Part
        var renditions: [(key: [UInt16], value: Data)]
    }

    let icon: Icon

    init(_ icon: Icon) {
        self.icon = icon
    }

    private var prefix: String { icon.name + "_Assets/" }

    /// The default background: white.
    private static let defaultFill = Icon.Color.gray(1)
    /// The dark appearance's background, whatever the icon's own fill.
    private static let darkFill = Icon.Fill.linearGradient(
        Icon.Color(space: 2, components: [Double(Float(0.192)), 1]),
        Icon.Color(space: 2, components: [Double(Float(0.078)), 1]),
        start: (0.5, 0), stop: (0.5, 1)
    )

    private func groupName(_ index: Int) -> String {
        index == 0 ? "\(icon.name)/Group" : "\(icon.name)/Group-\(index + 1)"
    }

    private func layerName(_ group: Int, _ layer: Int) -> String {
        "\(prefix)Layer-\(group + 1)-\(layer + 1)"
    }

    /// Every color the icon refers to, named in order of first use.
    private var colors: [(name: String, color: Icon.Color)] {
        var list: [Icon.Color] = []
        func add(_ color: Icon.Color) { if !list.contains(color) { list.append(color) } }
        for fill in [icon.fill ?? .color(Self.defaultFill), Self.darkFill] {
            switch fill {
            case .color(let color): add(color)
            case .linearGradient(let from, let to, _, _): add(from); add(to)
            }
        }
        for group in icon.groups {
            for layer in group.layers {
                if let fill = layer.fill { add(fill) }
            }
        }
        return list.enumerated().map { ("\(prefix)Color-\($0 + 1)", $1) }
    }

    private func colorName(_ color: Icon.Color) -> String {
        colors.first { $0.color == color }!.name
    }

    private var lightFillName: String {
        switch icon.fill ?? .color(Self.defaultFill) {
        case .color(let color): colorName(color)
        case .linearGradient: prefix + "Gradient-1"
        }
    }

    var names: [String] {
        var names = [icon.name]
        names += icon.groups.indices.map(groupName)
        for (g, group) in icon.groups.enumerated() {
            names += group.layers.indices.map { layerName(g, $0) }
        }
        names += colors.map(\.name)
        if case .linearGradient? = icon.fill { names.append(prefix + "Gradient-1") }
        names.append(prefix + "system-dark")
        return names
    }

    func renditions(writer: CarWriter, identifiers: [String: UInt16]) throws -> [Named] {
        func id(_ name: String) -> UInt16 { identifiers[name]! }
        var result: [Named] = []

        // Images.
        for (g, group) in icon.groups.enumerated() {
            for (l, layer) in group.layers.enumerated() {
                let name = layerName(g, l)
                let key = writer.key(part: .bitmap, identifier: id(name), scale: 1)
                let value = switch layer.image {
                case .svg(let svg): try writer.vectorRendition(name: "image.svg", svg: svg)
                case .bitmap(let bitmap): try writer.bitmapRendition(name: "image.png", bitmap)
                }
                result.append(Named(name: name, part: .bitmap, renditions: [(key, value)]))
            }
        }

        // Colors and gradients.
        for (name, color) in colors {
            result.append(Named(name: name, part: .color, renditions: [(
                writer.key(part: .color, identifier: id(name), scale: 1),
                writer.colorRendition(name: name, components: color.components, space: color.space)
            )]))
        }
        var gradients: [(String, Icon.Fill)] = [(prefix + "system-dark", Self.darkFill)]
        if let fill = icon.fill, case .linearGradient = fill { gradients.append((prefix + "Gradient-1", fill)) }
        for (name, fill) in gradients {
            result.append(Named(name: name, part: .gradient, renditions: [(
                writer.key(part: .gradient, identifier: id(name), scale: 1),
                gradientRendition(writer, name: name, fill)
            )]))
        }

        // Groups, then the stack, for each appearance with its own look.
        let appearances: [CarWriter.Appearance] = [.dark, .light, .tintable]
        for (g, group) in icon.groups.enumerated() {
            let name = groupName(g)
            result.append(Named(name: name, part: .layerGroup, renditions: appearances.map { appearance in
                (writer.key(part: .layerGroup, identifier: id(name), scale: 1, appearance: appearance),
                 groupRendition(writer, group, group: g, identifiers: identifiers))
            }))
        }
        result.append(Named(name: icon.name, part: .layeredImage, renditions: appearances.map { appearance in
            let fill: (part: CarWriter.Part, name: String) = switch (appearance, icon.fill) {
            case (.dark, _): (.gradient, prefix + "system-dark")
            case (_, .linearGradient?): (.gradient, lightFillName)
            default: (.color, lightFillName)
            }
            return (
                writer.key(part: .layeredImage, identifier: id(icon.name), scale: 1, appearance: appearance),
                stackRendition(writer, fill: (fill.part, id(fill.name)), identifiers: identifiers)
            )
        }))
        return result
    }

    // MARK: Renditions

    private enum Info: UInt32 {
        case layers = 0x3f4
        case uti = 0x3ed
        case materials = 0x3fc
        case effects = 0x3fd
        case reserved = 0x3fe
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

    private func stackRendition(_ writer: CarWriter, fill: (part: CarWriter.Part, identifier: UInt16), identifiers: [String: UInt16]) -> Data {
        let count = 1 + icon.groups.count
        var layers = layerEntry(part: fill.part, identifier: fill.identifier)
        var materials = Data(count: 8) + string("")
        var effects = Data(count: 20)
        for (g, group) in icon.groups.enumerated() {
            layers += layerEntry(opacity: group.opacity, part: .layerGroup, identifier: identifiers[groupName(g)]!)

            materials.appendLittleEndian(UInt32(group.combinedLighting ? 0 : 2))
            materials.appendLittleEndian(Float(group.blur).bitPattern)
            materials += string("")

            effects.appendLittleEndian(UInt32(group.specular ? 1 : 0))
            effects.appendLittleEndian(Float(group.translucency).bitPattern)
            effects.appendLittleEndian(group.shadow.rawValue)
            effects.appendLittleEndian(Float(group.shadowOpacity).bitPattern)
            effects.appendLittleEndian(UInt32(0))
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
            + self.info(.reserved, count: count, Data(count: 12 * count))
            + utiInfo
        return dataRendition(writer, name: icon.name + ".iconstack", size: 1024, layout: 0x3fb, info: info)
    }

    private func groupRendition(_ writer: CarWriter, _ group: Icon.Group, group g: Int, identifiers: [String: UInt16]) -> Data {
        var layers = Data(), materials = Data()
        for (l, layer) in group.layers.enumerated() {
            layers += layerEntry(
                frame: (layer.x, layer.y, layer.width, layer.height), blendMode: layer.blendMode,
                opacity: layer.opacity, part: .bitmap, identifier: identifiers[layerName(g, l)]!
            )
            materials.appendLittleEndian(UInt32(layer.glass ? 1 : 0))
            materials.appendLittleEndian(UInt32(0))
            materials += string(layer.fill.map(colorName) ?? "")
        }
        let count = group.layers.count
        let info = self.info(.layers, count: count, layers)
            + self.info(.materials, count: count, materials)
            + self.info(.effects, count: count, Data(count: 20 * count))
            + self.info(.reserved, count: count, Data(count: 12 * count))
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
