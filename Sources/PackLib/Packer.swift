import Foundation
import XUtils
import Subprocess
import CarKit

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build() async throws {
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        if URL(fileURLWithPath: "Packages").dirExists {
            try FileManager.default.createSymbolicLink(
                atPath: packageDir.appendingPathComponent("Packages").path,
                withDestinationPath: "../../Packages"
            )
        }

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                \(plan.app.platform.packageDescription(version: plan.app.deploymentTarget)),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        let buildConfig = try await buildSettings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", ".build",
                    // resolving can cause SwiftPM to overwrite the root package deps
                    // with just the deps needed for the builder package (which is to
                    // say, any "dev dependencies" of the root package may be removed.)
                    // fortunately we've already resolved the root package by this point
                    // in order to dump the plan, so we can skip resolution here to skirt
                    // the issue.
                    "--disable-automatic-resolution",
                ],
            )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        let binPath: String
        switch buildSettings.buildSystem {
        case .swiftPM:
            binPath = "\(buildSettings.triple)/\(buildSettings.configuration.rawValue)"
        case .swiftBuild:
            let configuration = buildSettings.configuration.swiftBuildValue
            switch buildSettings.platform {
            case .macOS:
                // like Xcode, Swift Build puts macOS products in an
                // unsuffixed directory
                binPath = "out/Products/\(configuration)"
            case .iOS:
                let platformName = buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos"
                binPath = "out/Products/\(configuration)-\(platformName)"
            }
        }
        let binDir = URL(
            fileURLWithPath: ".build/\(binPath)",
            isDirectory: true
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    layout: product.layout(inApp: outputURL),
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        try await compileAssetCatalogs(in: outputURL)

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        binDir: URL,
        layout: BundleLayout,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        /// Copies a file from the package root into the bundle's resources.
        @Sendable func packFileToResources(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = layout.resources.appendingPathComponent(srcURL.lastPathComponent)
            try? FileManager.default.createDirectory(at: layout.resources, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        /// Copies a build product into `directory` (in the bundle), optionally renamed.
        @Sendable func packFile(
            srcName: String,
            into directory: URL,
            dstName: String? = nil,
            sign: Bool = false
        ) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = directory.appendingPathComponent(dstName ?? srcURL.lastPathComponent)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try? FileManager.default.createDirectory(at: layout.contents, withIntermediateDirectories: true)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle", into: resourceBundleDirectory(layout))
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(srcName: "\(name).framework", into: layout.frameworks, sign: true)
                    }
                case .library(let name):
                    try await packFile(srcName: "lib\(name).dylib", into: layout.frameworks, sign: true)
                case .root(let source):
                    try await packFileToResources(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToResources(srcName: iconPath)
            }
        }
        group.addTask {
            try await packFile(srcName: product.targetName, into: layout.executables, dstName: product.product)
        }
        group.addTask {
            var info = product.infoPlist

            if product.type == .application {
                if product.platform == .iOS {
                    info["UIRequiredDeviceCapabilities"] = ["arm64"]
                    info["LSRequiresIPhoneOS"] = true
                }
                info["CFBundleSupportedPlatforms"] = Packer.cfBundleSupportedPlatforms(for: buildSettings.triple)
            }

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = layout.infoPlist
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }

    static func cfBundleSupportedPlatforms(for triple: String) -> [String] {
        let components = triple.split(separator: "-").map(String.init)
        guard let appleIndex = components.firstIndex(of: "apple"),
              components.indices.contains(appleIndex + 1) else {
            return ["iPhoneOS"]
        }

        let os = components[appleIndex + 1].prefix { !$0.isNumber }
        switch os {
        case "ios" where components.contains("simulator"):
            return ["iPhoneSimulator"]
        case "ios":
            return ["iPhoneOS"]
        case "macos", "macosx":
            return ["MacOSX"]
        default:
            return ["iPhoneOS"]
        }
    }
}

extension Plan.Product {
    /// Where this product's executable finds its own Frameworks directory,
    /// and (for an extension) the host app's.
    private var frameworkSearchPaths: (own: String, host: String) {
        switch platform {
        case .iOS:
            // App.app/Frameworks; App.app/PlugIns/Ext.appex/Frameworks
            ("@executable_path/Frameworks", "@executable_path/../../Frameworks")
        case .macOS:
            // App.app/Contents/{MacOS,Frameworks};
            // App.app/Contents/PlugIns/Ext.appex/Contents/{MacOS,Frameworks}
            ("@executable_path/../Frameworks", "@executable_path/../../../../Frameworks")
        }
    }

    fileprivate var linkerSettings: String {
        let paths = frameworkSearchPaths
        return switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "\(paths.own)",
            ]),
        ]
        """
        case .appExtension: """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "\(paths.host)",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "\(paths.own)",
            ]),
        ]
        """
        }
    }
}

extension Packer {
    /// Where SwiftPM resource bundles go so that `Bundle.module` finds them.
    /// Swift Build's accessor looks in the main bundle's resources directory
    /// (Contents/Resources on macOS, the bundle root on iOS). SwiftPM's native
    /// build system only looks at the main bundle's own URL (and then at the
    /// absolute build directory), so for native Mac builds they have to sit at
    /// the top of the .app.
    func resourceBundleDirectory(_ layout: BundleLayout) -> URL {
        if layout.platform == .macOS && buildSettings.buildSystem == .swiftPM {
            return layout.root
        }
        return layout.resources
    }
}

extension Packer {
    /// Replaces the asset catalog sources (`*.xcassets`) packed into the app,
    /// whether at its top level or inside a resource bundle, with a compiled
    /// `Assets.car` in the same directory, built by CarKit rather than
    /// Apple's actool.
    func compileAssetCatalogs(in appURL: URL) async throws {
        var catalogsByDirectory: [URL: [URL]] = [:]
        let enumerator = FileManager.default.enumerator(
            at: appURL, includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "xcassets" else { continue }
            catalogsByDirectory[url.deletingLastPathComponent(), default: []].append(url)
            enumerator?.skipDescendants()
        }

        let (idioms, platformName, vectorScales) = switch buildSettings.platform {
        case .macOS: (["mac"], "macosx", [1, 2])
        case .iOS: (["iphone", "ipad"], buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos", [2, 3])
        }
        let resvg = catalogsByDirectory.isEmpty ? nil : try? await ToolRegistry.locate("resvg")

        for (directory, catalogs) in catalogsByDirectory {
            var compiler = AssetCatalog(idioms: idioms)
            compiler.vectorScales = vectorScales
            compiler.renderSVG = resvg.map(Self.svgRenderer(resvg:))
            for catalog in catalogs.sorted(by: { $0.path < $1.path }) {
                try compiler.add(catalogAt: catalog)
            }
            for warning in compiler.warnings {
                print("warning: asset catalog: \(warning)")
            }
            let car = try compiler.compile(deploymentTarget: plan.app.deploymentTarget, platform: platformName)
            try car.write(to: directory.appendingPathComponent("Assets.car"))
            try ensureInfoPlist(forBundleContaining: directory)
            for catalog in catalogs {
                try FileManager.default.removeItem(at: catalog)
            }
        }
    }
}

extension Packer {
    /// The system only loads a bundle's compiled asset catalog when the bundle
    /// has an identifier. SwiftPM's native build system makes resource bundles
    /// without an Info.plist, so give a flat `.bundle` one if it lacks it.
    fileprivate func ensureInfoPlist(forBundleContaining directory: URL) throws {
        guard directory.pathExtension == "bundle" else { return }
        let infoPlist = directory.appendingPathComponent("Info.plist")
        let nested = directory.appendingPathComponent("Contents/Info.plist")
        guard !FileManager.default.fileExists(atPath: infoPlist.path),
              !FileManager.default.fileExists(atPath: nested.path)
        else { return }
        let name = directory.deletingPathExtension().lastPathComponent
        let info: [String: Any] = [
            "CFBundleIdentifier": "\(plan.app.bundleID).resources.\(name)",
            "CFBundleName": name,
            "CFBundlePackageType": "BNDL",
            "CFBundleInfoDictionaryVersion": "6.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: infoPlist)
    }
}

extension Packer {
    /// Renders SVGs for asset catalogs with resvg (https://github.com/linebender/resvg).
    fileprivate static func svgRenderer(resvg: URL) -> AssetCatalog.SVGRenderer {
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
