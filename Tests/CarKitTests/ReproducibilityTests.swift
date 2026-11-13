import Foundation
import Testing
import CarKit

/// Compiled catalogs depend only on their contents: not on the order assets
/// are added in, the time, or the process (whose hash seed differs per run;
/// that part is checked by compiling in separate processes, not here).
struct ReproducibilityTests {
    private func assets() -> [CarWriter.Asset] {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>"#.utf8)
        var layer = CarWriter.LayeredIcon.Layer(image: .svg(svg), x: 0, y: 0, width: 8, height: 8)
        layer.fill = .color(.sRGB(1, 0, 0))
        let icon = CarWriter.LayeredIcon(
            name: "AppIcon",
            fill: .linearGradient(.sRGB(0, 0, 1), .gray(0.5), start: (0.5, 0), stop: (0.5, 1)),
            groups: [.init(layers: [layer]), .init(layers: [layer, layer])]
        )
        let pixels = Data(repeating: 0x80, count: 4 * 4 * 4)
        return [
            .color(name: "Accent", red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
            .image(name: "Dots", bitmaps: [.init(scale: 2, width: 4, height: 4, pixels: pixels),
                                          .init(scale: 1, width: 4, height: 4, pixels: pixels)]),
            .vector(name: "Leaf", svg: svg, bitmaps: [.init(scale: 1, width: 4, height: 4, pixels: pixels)]),
            .layeredIcon(icon),
        ] + (0..<300).map { .color(name: "C\($0)", red: Double($0 % 256) / 255, green: 0, blue: 0, alpha: 1) }
    }

    @Test func sameBytesWhateverTheOrder() throws {
        var writer = CarWriter()
        writer.assets = assets()
        let expected = try writer.serialize()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            writer.assets = assets().shuffled(using: &generator)
            #expect(try writer.serialize() == expected)
        }
    }
}
