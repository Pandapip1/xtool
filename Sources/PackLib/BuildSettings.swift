import Foundation
import Subprocess
import XUtils
import Superutils

public struct BuildSettings: Sendable {
    private static let customBinDir =
        // this is the same option used by SwiftPM itself for dev builds
        ProcessInfo.processInfo.environment["SWIFTPM_CUSTOM_BIN_DIR"].map { FilePath($0) }

    public var packagePath: String
    public let configuration: BuildConfiguration
    public let triple: String
    public let buildSystem: BuildSystem
    public let customOptions: [String]

    public var sdkOptions: [String]
    public var sdkEnvironment: [Environment.Key: String?]

    private var configOptions: [String] {
        return [
            "--configuration", configuration.rawValue,
            "--build-system", buildSystem.pmName,
            "--package-path", packagePath,
        ]
    }

    private var resolvedBaseOptions: [String] {
        configOptions + sdkOptions + customOptions
    }

    /// The platform the app is being built for.
    public var platform: Platform {
        Platform(triple: triple)
    }

    public init(
        configuration: BuildConfiguration,
        triple: String,
        buildSystem: BuildSystem? = nil,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.customOptions = options
        self.triple = triple
        self.buildSystem = if let buildSystem { buildSystem } else { try await .default() }

        #if os(macOS)
        // Building for the Mac on a Mac is a native build: the host SDK is the
        // right one, and SDKROOT is how a non-Xcode toolchain is pointed at it.
        let nativeMacBuild = Platform(triple: triple) == .macOS
        #else
        let nativeMacBuild = false
        #endif

        self.sdkEnvironment = nativeMacBuild ? [:] : [
            // xcrun passes an SDKROOT that messes with our sdk configuration
            "SDKROOT": nil,
        ]

        switch self.buildSystem {
        case .swiftPM where nativeMacBuild:
            // No separate Swift SDK to select.
            self.sdkOptions = ["--triple", triple]
        case .swiftPM:
            // on macOS we don't explicitly install a Swift SDK but
            // SwiftPM vends "implicit" Darwin SDKs as of Swift 6.1,
            // i.e. we can pass `--swift-sdk arm64-apple-ios` and it
            // just works. See:
            // https://github.com/swiftlang/swift-package-manager/pull/6828
            self.sdkOptions = ["--swift-sdk", triple]
        case .swiftBuild:
            self.sdkOptions = ["--triple", triple]
            #if !os(macOS)
            let darwinSDK = try DarwinSDK.current()
                .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
            self.sdkOptions += [
                "--toolset", "\(darwinSDK.bundle.path)/toolset-swb.json",
            ]
            self.sdkEnvironment.merge([
                "XCODE_EXTRA_PLATFORM_FOLDERS": "\(darwinSDK.bundle.path)/Developer/Platforms",
                // SWB looks for dsymutil in the PATH. Other stuff (lld, libtool) is handled by toolset-swb.json.
                "PATH": "\(darwinSDK.bundle.path)/toolset/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
            ]) { $1 }
            #endif
        }
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The toolchain's `tool`: the one on PATH when that is a real toolchain
    /// (from swift.org, swiftly, Nix, ...), or the one xcrun selects when PATH
    /// only has Apple's /usr/bin trampoline (the usual Xcode setup), so
    /// Xcode or the Command Line Tools aren't required.
    private static func locateTool(_ tool: String) async throws -> FilePath {
        if let onPath = try? await ToolRegistry.locate(tool),
           onPath.deletingLastPathComponent().standardizedFileURL.path != "/usr/bin" {
            return try FilePath(onPath).orThrow(StringError("Got bad path for \(tool) executable"))
        }
        return try await FilePath(xcrun(["-f", tool]))
    }

    private static let _swiftURL = Task {
        try await locateTool("swift")
    }

    public static func swiftURL() async throws -> FilePath {
        try await _swiftURL.value
    }

    private static let _swiftcURL = Task {
        try await locateTool("swiftc")
    }

    public static func swiftcURL() async throws -> FilePath {
        try await _swiftcURL.value
    }
    #else
    public static func swiftURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swift")).orThrow(StringError("Got bad path for swift executable"))
    }

    public static func swiftcURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swiftc")).orThrow(StringError("Got bad path for swiftc executable"))
    }
    #endif

    public func withPackagePath(_ path: String) -> Self {
        var copy = self
        copy.packagePath = path
        return copy
    }

    public func swiftPMInvocation(
        forTool tool: String,
        arguments: [String],
    ) async throws -> Subprocess.Configuration {
        let executable: Executable
        let baseArguments: [String]
        if let customBinDir = Self.customBinDir {
            executable = .path(customBinDir.appending("swift-\(tool)"))
            baseArguments = []
        } else {
            #if os(macOS)
            // xcrun/libxcrun (via the /usr/bin/swift trampoline) is very trigger-happy
            // to add SDKROOT=.../MacOSX.sdk to our invocations. We avoid this by
            // 1) invoking the real swift executable (located with `xcrun -f`) and
            // 2) explicitly removing SDKROOT from the env, as it may be inherited
            // through a parent process (e.g. `swift run xtool`).
            executable = .path(try await Self.swiftURL())
            #else
            executable = .name("swift")
            #endif
            baseArguments = [tool]
        }

        return Configuration(
            executable: executable,
            arguments: .init(baseArguments + resolvedBaseOptions + arguments),
            environment: .inherit.updating(sdkEnvironment),
            platformOptions: .withGracefulShutDown,
        )
    }

    // loosely based on
    // https://github.com/swiftlang/sourcekit-lsp/blob/c55899a/Sources/BuildServerIntegration/ExternalBuildServerAdapter.swift#L92
    private var baseBuildServerArguments: [String] {
        return [
            "experimental-build-server",
            "--disable-automatic-resolution",
            "--scratch-path", ".build/index-build",
            // this requires Swift 6.4 but we need 6.4 on Linux anyway, for the platform toolset fixes
            "--experimental-skip-acquiring-lock",
        ]
    }

    public var buildServerArguments: [String] {
        ["package"] + baseBuildServerArguments + resolvedBaseOptions
    }

    public func buildServerInvocation() async throws -> Subprocess.Configuration {
        try await swiftPMInvocation(forTool: "package", arguments: baseBuildServerArguments)
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release

    var swiftBuildValue: String {
        switch self {
        case .debug: "Debug"
        case .release: "Release"
        }
    }
}

public enum BuildSystem: Sendable {
    case swiftPM
    case swiftBuild

    public static func `default`() async throws -> Self {
        // An explicit choice, e.g. to sidestep a toolchain whose `codesign`
        // Swift Build can't use: XTOOL_BUILD_SYSTEM=native|swiftbuild.
        switch ProcessInfo.processInfo.environment["XTOOL_BUILD_SYSTEM"] {
        case "native": return .swiftPM
        case "swiftbuild": return .swiftBuild
        case nil, "": break
        case let other?:
            throw StringError("XTOOL_BUILD_SYSTEM must be 'native' or 'swiftbuild', not '\(other)'")
        }
        if try await SwiftVersion.current.supportsSwiftBuild {
            return .swiftBuild
        } else {
            return .swiftPM
        }
    }

    var pmName: String {
        switch self {
        case .swiftPM: "native"
        case .swiftBuild: "swiftbuild"
        }
    }
}
