import Foundation
import Testing
@testable import CarKit

struct IconComposerTests {
    private func icon(_ json: String, layer: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconComposerTests-\(UUID().uuidString).icon")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url.appendingPathComponent("icon.json"))
        try Data(layer.utf8).write(to: url.appendingPathComponent("Assets/Layer.svg"))
        return url
    }

    @Test func readsFillAndLayers() throws {
        let url = try icon("""
        {"fill":{"linear-gradient":["extended-srgb:1,0,0,1","srgb:0,0,1,0.5"],
                 "orientation":{"start":{"x":0.5,"y":0},"stop":{"x":0.5,"y":0.7}}},
         "groups":[
           {"layers":[{"image-name":"Layer.svg","position":{"scale":2,"translation-in-points":[10,-20]}}]},
           {"hidden":true,"layers":[{"image-name":"Layer.svg"}]}
         ]}
        """, layer: #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"/>"#)
        let icon = try IconComposerIcon(url: url)

        guard case .linearGradient(let colors, let start, let stop)? = icon.fill else {
            Issue.record("expected a gradient fill")
            return
        }
        #expect(colors.map(\.red) == [1, 0] && colors.map(\.alpha) == [1, 0.5])
        #expect(start == (0.5, 0) && stop == (0.5, 0.7))
        #expect(icon.layers.count == 1) // the hidden group is left out
        #expect(icon.layers[0].scale == 2 && icon.layers[0].translation == (10, -20))

        // 100x50 at scale 2, centered on the 1024 canvas, then translated.
        let svg = try icon.svg(size: 64, shape: .square)
        #expect(svg.contains(#"x="422.0" y="442.0" width="200.0" height="100.0""#))
    }

    @Test func svgSizeFromAttributesOrViewBox() {
        #expect(IconComposerIcon.svgSize(#"<svg width="12px" height="34">"#)! == (12, 34))
        #expect(IconComposerIcon.svgSize(#"<svg viewBox="0 0 512 256">"#)! == (512, 256))
    }

    @Test func icnsHasEveryEntry() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let pngs = Dictionary(ICNSWriter.entries.map { ($0.size, png) }, uniquingKeysWith: { a, _ in a })
        let icns = try ICNSWriter.write(pngs: pngs)
        #expect(icns.prefix(4) == Data("icns".utf8))
        #expect(icns.count == 8 + ICNSWriter.entries.count * (8 + png.count))
        #expect(icns.dropFirst(8).prefix(4) == Data("icp4".utf8))
    }
}

#if canImport(AppKit)
import AppKit

/// Layered icons are rendered by the system, so the check is what it draws.
struct LayeredIconTests {
    @Test func systemRendersLayeredIcon() throws {
        // A blue background with an opaque white 400pt square, glass off.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayeredIconTests-\(UUID().uuidString).icon")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data(#"""
        {"fill":{"solid":"srgb:0,0,1,1"},
         "groups":[{"layers":[{"image-name":"Square.svg","glass":false}],"shadow":{"kind":"none","opacity":0}}]}
        """#.utf8).write(to: url.appendingPathComponent("icon.json"))
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><rect width="400" height="400" fill="#fff"/></svg>"##.utf8)
            .write(to: url.appendingPathComponent("Assets/Square.svg"))

        var writer = CarWriter()
        writer.assets = [.layeredIcon(try IconComposerIcon(url: url).layeredIcon(name: "AppIcon"))]
        writer.deploymentTarget = "26.0"

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("LayeredIconTests-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try writer.serialize().write(to: app.appendingPathComponent("Contents/Resources/Assets.car"))
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleIconName": "AppIcon", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let icon = NSWorkspace.shared.icon(forFile: app.path)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()

        // The center is the white square; between it and the edge, the fill.
        // (Under the default icon style; others restyle the fill.)
        let center = try #require(rep.colorAt(x: 128, y: 128)?.usingColorSpace(.sRGB))
        let side = try #require(rep.colorAt(x: 44, y: 128)?.usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.9 && center.blueComponent > 0.9, "\(center)")
        #expect(side.blueComponent - side.redComponent > 0.2, "\(side)") // the material lightens the fill
    }
}
#endif
