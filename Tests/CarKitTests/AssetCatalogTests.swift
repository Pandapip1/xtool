import Foundation
import Testing
import CarKit

#if canImport(AppKit)
import AppKit

/// Compiles catalog sources and loads the result through AppKit.
struct AssetCatalogTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AssetCatalogTests-\(UUID().uuidString)")

    private func write(_ json: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    /// A bundle whose compiled catalog comes from the catalog at `catalog`.
    private func compiledBundle(_ catalog: URL) throws -> (Bundle, [String]) {
        var compiler = AssetCatalog(idioms: ["mac"])
        try compiler.add(catalogAt: catalog)
        let car = try compiler.compile(deploymentTarget: "14.0", platform: "macosx")

        let dir = root.appendingPathComponent("Test.bundle")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.\(UUID().uuidString)"], format: .xml, options: 0
        ).write(to: dir.appendingPathComponent("Contents/Info.plist"))
        try car.write(to: dir.appendingPathComponent("Contents/Resources/Assets.car"))
        return (try #require(Bundle(path: dir.path)), compiler.warnings)
    }

    @Test func colorsInEveryNotation() throws {
        try write("""
        {"colors":[{"idiom":"universal","color":{"color-space":"srgb",
          "components":{"red":"0.500","green":"128","blue":"0x40","alpha":"1.000"}}}]}
        """, to: "Assets.xcassets/Mixed.colorset/Contents.json")
        try write(#"{"properties":{"provides-namespace":true}}"#, to: "Assets.xcassets/Brand/Contents.json")
        try write("""
        {"colors":[{"idiom":"universal","color":{"color-space":"gray-gamma-22",
          "components":{"white":"1.000","alpha":"0.500"}}}]}
        """, to: "Assets.xcassets/Brand/Mist.colorset/Contents.json")

        let (bundle, warnings) = try compiledBundle(root.appendingPathComponent("Assets.xcassets"))
        #expect(warnings.isEmpty)

        let mixed = try #require(NSColor(named: "Mixed", bundle: bundle)?.usingColorSpace(.sRGB))
        #expect(abs(mixed.redComponent - 0.5) < 0.002)
        #expect(abs(mixed.greenComponent - 128.0 / 255) < 0.002)
        #expect(abs(mixed.blueComponent - 64.0 / 255) < 0.002)

        let mist = try #require(NSColor(named: "Brand/Mist", bundle: bundle)?.usingColorSpace(.sRGB))
        #expect(abs(mist.redComponent - 1) < 0.002)
        #expect(abs(mist.alphaComponent - 0.5) < 0.002)
    }

    @Test func pngImageSet() throws {
        // 2x1 PNG: opaque red, then 50% green (straight alpha in the file).
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 8, bitsPerPixel: 32
        ))
        let raw = try #require(rep.bitmapData)
        for (i, byte) in [255, 0, 0, 255, 0, 255, 0, 128].enumerated() { raw[i] = UInt8(byte) }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let imageset = root.appendingPathComponent("Assets.xcassets/Swatch.imageset")
        try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)
        try png.write(to: imageset.appendingPathComponent("swatch.png"))
        try write("""
        {"images":[{"idiom":"universal","filename":"swatch.png","scale":"1x"}]}
        """, to: "Assets.xcassets/Swatch.imageset/Contents.json")

        let (bundle, warnings) = try compiledBundle(root.appendingPathComponent("Assets.xcassets"))
        #expect(warnings.isEmpty)
        let image = try #require(bundle.image(forResource: "Swatch"))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cgImage.width == 2 && cgImage.height == 1)
        let decoded = try #require(cgImage.dataProvider?.data as Data?)
        // premultiplied BGRA: red; then green at half alpha (255 * 128 / 255 = 128)
        #expect(Array(decoded.prefix(8)) == [0, 0, 255, 255, 0, 128, 0, 128])
    }
}
#endif
