import Foundation
import Testing
import CarKit

#if canImport(AppKit)
import AppKit

/// Writes catalogs and reads them back through the system's own loaders,
/// which is what decides whether the format is right.
struct CarWriterTests {
    /// A bundle directory holding `car` as its compiled asset catalog.
    private func bundle(containing car: Data) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarWriterTests-\(UUID().uuidString).bundle")
        let resources = dir.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Contents/Info.plist"))
        try car.write(to: resources.appendingPathComponent("Assets.car"))
        return try #require(Bundle(path: dir.path))
    }

    @Test func color() throws {
        var writer = CarWriter()
        writer.assets = [.color(name: "Accent", red: 0.25, green: 0.5, blue: 0.75, alpha: 1)]
        let bundle = try bundle(containing: writer.serialize())

        let color = try #require(NSColor(named: "Accent", bundle: bundle)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0.25) < 0.001)
        #expect(abs(color.greenComponent - 0.5) < 0.001)
        #expect(abs(color.blueComponent - 0.75) < 0.001)
        #expect(color.alphaComponent == 1)
    }

    @Test func bitmap() throws {
        // 2x1: opaque blue, then half-transparent red (premultiplied BGRA)
        let pixels = Data([255, 0, 0, 255, 0, 0, 128, 128])
        var writer = CarWriter()
        writer.assets = [.image(name: "Dots", bitmaps: [.init(scale: 1, width: 2, height: 1, pixels: pixels)])]
        let bundle = try bundle(containing: writer.serialize())

        let image = try #require(bundle.image(forResource: "Dots"))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cgImage.width == 2 && cgImage.height == 1)
        #expect(cgImage.colorSpace?.name == CGColorSpace.sRGB)
        let decoded = try #require(cgImage.dataProvider?.data as Data?)
        #expect(Array(decoded.prefix(8)) == Array(pixels))
    }

    @Test func manyAssetsSpanSeveralTreeLeaves() throws {
        // More entries than fit in one tree leaf, and identifiers above 255,
        // which is where the byte order and numeric order of keys part ways.
        var writer = CarWriter()
        writer.assets = (0..<1200).map {
            .color(name: "C\($0)", red: Double($0 % 256) / 255, green: 0, blue: 0, alpha: 1)
        }
        let bundle = try bundle(containing: writer.serialize())

        for i in 0..<1200 {
            let color = try #require(NSColor(named: "C\(i)", bundle: bundle)?.usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - Double(i % 256) / 255) < 0.001, "C\(i)")
        }
    }
}
#endif
