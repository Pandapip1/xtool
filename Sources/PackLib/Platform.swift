import Foundation

/// The Apple platform an app is built for, as named by its target triple.
public enum Platform: Sendable, Hashable {
    /// iOS devices and the iOS Simulator.
    case iOS
    case macOS

    public init(triple: String) {
        let components = triple.split(separator: "-")
        guard let apple = components.firstIndex(of: "apple"),
              components.indices.contains(apple + 1)
        else {
            self = .iOS
            return
        }
        self = components[apple + 1].hasPrefix("macos") ? .macOS : .iOS
    }

    /// The name SwiftPM's `platforms:` list and `swift package describe` use.
    var packageName: String {
        switch self {
        case .iOS: "ios"
        case .macOS: "macos"
        }
    }

    /// The `SupportedPlatform` expression for a generated Package.swift.
    func packageDescription(version: String) -> String {
        switch self {
        case .iOS: ".iOS(\"\(version)\")"
        case .macOS: ".macOS(\"\(version)\")"
        }
    }
}

/// Where the parts of an app or extension bundle go.
///
/// iOS bundles are flat. macOS bundles keep everything under `Contents/`, with
/// the executable in `MacOS/` and resources in `Resources/`.
public struct BundleLayout: Sendable {
    /// The `.app` or `.appex` directory itself.
    public var root: URL
    public var platform: Platform

    public init(root: URL, platform: Platform) {
        self.root = root
        self.platform = platform
    }

    /// The directory holding Info.plist and the other bundle subdirectories.
    public var contents: URL {
        switch platform {
        case .iOS: root
        case .macOS: root.appendingPathComponent("Contents", isDirectory: true)
        }
    }

    public var infoPlist: URL {
        contents.appendingPathComponent("Info.plist", isDirectory: false)
    }

    public var executables: URL {
        switch platform {
        case .iOS: contents
        case .macOS: contents.appendingPathComponent("MacOS", isDirectory: true)
        }
    }

    public var resources: URL {
        switch platform {
        case .iOS: contents
        case .macOS: contents.appendingPathComponent("Resources", isDirectory: true)
        }
    }

    public var frameworks: URL {
        contents.appendingPathComponent("Frameworks", isDirectory: true)
    }

    public var plugIns: URL {
        contents.appendingPathComponent("PlugIns", isDirectory: true)
    }
}
