import Foundation
import ArgumentParser
import PackLib
import XUtils

struct AssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assets",
        abstract: "Compile asset catalogs and app icons without Xcode",
        subcommands: [AssetsCompileCommand.self]
    )
}

struct AssetsCompileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile",
        abstract: "Compile asset catalogs and an Icon Composer app icon",
        discussion: """
        Does for any app bundle what `xtool dev build` does for its own, in \
        place of Xcode's actool: writes Assets.car into the output directory \
        (normally the app's Resources), from the given catalogs and, with \
        --app-icon, the icon's layered renditions, which the system renders \
        with its materials (Liquid Glass). The icon is also rendered flat, as \
        an .icns on macOS for older systems or a PNG on iOS.

        Set the Info.plist keys this prints (CFBundleIconName, \
        CFBundleIconFile) for the system to use the icon. SVG images and flat \
        icon renders need resvg on PATH.
        """
    )

    enum PlatformName: String, ExpressibleByArgument, CaseIterable {
        case macos, ios, iossimulator
    }

    @Option(name: .shortAndLong, help: "Directory to write Assets.car and the icon render into")
    var output: String

    @Option(name: .customLong("app-icon"), help: "An Icon Composer (.icon) app icon")
    var appIcon: String?

    @Option(help: "The platform to compile for")
    var platform: PlatformName = .macos

    @Option(name: .customLong("minimum-deployment-target"), help: "The app's minimum OS version")
    var deploymentTarget: String?

    @Argument(help: "Asset catalogs (.xcassets) to compile")
    var catalogs: [String] = []

    func run() async throws {
        let platform: Platform = self.platform == .macos ? .macOS : .iOS
        let compiler = AssetCompiler(
            platform: platform,
            simulator: self.platform == .iossimulator,
            deploymentTarget: deploymentTarget ?? (platform == .macOS ? "11.0" : "14.0")
        )
        if let appIcon, URL(fileURLWithPath: appIcon).pathExtension != "icon" {
            throw StringError("--app-icon must be an Icon Composer (.icon) file, got '\(appIcon)'")
        }
        let resvg = try? await ToolRegistry.locate("resvg")
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let iconURL = appIcon.map { URL(fileURLWithPath: $0) }
        let car = try compiler.compile(
            catalogs: catalogs.map { URL(fileURLWithPath: $0) }, appIcon: iconURL, resvg: resvg
        )
        try car.write(to: outputURL.appendingPathComponent("Assets.car"))

        var keys: [(String, String)] = []
        if let iconURL {
            guard let resvg else { throw StringError("rendering \(iconURL.lastPathComponent) needs resvg on PATH") }
            let file = try compiler.renderFlatIcon(iconURL, into: outputURL, resvg: resvg)
            if let name = AssetCompiler.layeredIconName(iconPath: iconURL.path, platform: platform) {
                keys.append(("CFBundleIconName", name))
            }
            keys.append(("CFBundleIconFile", URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent))
        }
        for (key, value) in keys {
            print("\(key) = \(value)")
        }
    }
}
