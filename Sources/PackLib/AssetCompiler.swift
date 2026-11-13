import Foundation
import CarKit
import XUtils

/// Compiles asset catalogs and Icon Composer app icons with CarKit, rather
/// than Apple's actool: what the packer does for apps it builds, and
/// `xtool assets compile` does for any app.
public struct AssetCompiler: Sendable {
    public var platform: Platform
    /// "macosx", "iphoneos" or "iphonesimulator".
    public var platformName: String
    public var deploymentTarget: String

    public init(platform: Platform, simulator: Bool = false, deploymentTarget: String) {
        self.platform = platform
        self.platformName = switch platform {
        case .macOS: "macosx"
        case .iOS: simulator ? "iphonesimulator" : "iphoneos"
        }
        self.deploymentTarget = deploymentTarget
    }

    /// The asset catalog name of an app's layered icon, when it has one: an
    /// Icon Composer icon on macOS. (iOS still gets a flat PNG.)
    public static func layeredIconName(iconPath: String, platform: Platform) -> String? {
        let url = URL(fileURLWithPath: iconPath)
        guard platform == .macOS, url.pathExtension == "icon" else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `Assets.car` data for `catalogs`, plus the layered renditions of
    /// `appIcon` (named after it) when there is one. SVG images are rendered
    /// with `resvg`, and skipped with a warning without it.
    public func compile(catalogs: [URL], appIcon: URL? = nil, resvg: URL?) throws -> Data {
        var compiler = AssetCatalog(idioms: platform == .macOS ? ["mac"] : ["iphone", "ipad"])
        compiler.vectorScales = platform == .macOS ? [1, 2] : [2, 3]
        compiler.renderSVG = resvg.map(Self.svgRenderer(resvg:))
        for catalog in catalogs.sorted(by: { $0.path < $1.path }) {
            try compiler.add(catalogAt: catalog)
        }
        if let appIcon, let name = Self.layeredIconName(iconPath: appIcon.path, platform: platform) {
            compiler.add(.layeredIcon(try IconComposerIcon(url: appIcon).layeredIcon(name: name)))
        }
        for warning in compiler.warnings {
            print("warning: asset catalog: \(warning)")
        }
        return try compiler.compile(deploymentTarget: deploymentTarget, platform: platformName)
    }

    /// Renders an Icon Composer icon flat, with resvg: a full `.icns` on macOS
    /// (for systems before layered icons), a 1024-pixel square PNG on iOS
    /// (which masks icons itself). Returns the file's name, which is the
    /// icon's name plus the extension, written into `directory`.
    @discardableResult
    public func renderFlatIcon(_ iconURL: URL, into directory: URL, resvg: URL) throws -> String {
        let icon = try IconComposerIcon(url: iconURL)
        let name = iconURL.deletingPathExtension().lastPathComponent
        let render = Self.svgRenderer(resvg: resvg)

        func png(size: Int, shape: IconComposerIcon.Shape) throws -> Data {
            let svg = FileManager.default.temporaryDirectory
                .appendingPathComponent("xtool-icon-\(UUID().uuidString).svg")
            defer { try? FileManager.default.removeItem(at: svg) }
            try Data(icon.svg(size: size, shape: shape).utf8).write(to: svg)
            return try render(svg, 1)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch platform {
        case .macOS:
            var pngs: [Int: Data] = [:]
            for size in Set(ICNSWriter.entries.map(\.size)) {
                pngs[size] = try png(size: size, shape: .macOS)
            }
            try ICNSWriter.write(pngs: pngs).write(to: directory.appendingPathComponent("\(name).icns"))
            return "\(name).icns"
        case .iOS:
            try png(size: 1024, shape: .square).write(to: directory.appendingPathComponent("\(name).png"))
            return "\(name).png"
        }
    }

    /// Renders SVGs for asset catalogs with resvg (https://github.com/linebender/resvg).
    public static func svgRenderer(resvg: URL) -> AssetCatalog.SVGRenderer {
        { svg, scale in
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("xtool-svg-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: output) }
            let process = Process()
            process.executableURL = resvg
            process.arguments = ["--zoom", "\(scale)", svg.path, output.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StringError("resvg failed to render \(svg.lastPathComponent)")
            }
            return try Data(contentsOf: output)
        }
    }
}
