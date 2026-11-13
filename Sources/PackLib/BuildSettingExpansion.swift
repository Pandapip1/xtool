import Foundation

/// Expands Xcode build setting references, `$(NAME)` and `${NAME}`, in
/// property list values, as Xcode does when it processes an Info.plist.
/// A reference may carry a modifier: `$(NAME:rfc1034identifier)` (other
/// characters become `-`) or `$(NAME:c99extidentifier)` (they become `_`).
/// References to settings not in `settings` are left as they are and
/// reported in `unknown`.
enum BuildSettingExpansion {
    static func expand(_ value: [String: Sendable], settings: [String: String], unknown: inout Set<String>) -> [String: Sendable] {
        value.mapValues { expand($0, settings: settings, unknown: &unknown) }
    }

    static func expand(_ value: Sendable, settings: [String: String], unknown: inout Set<String>) -> Sendable {
        switch value {
        case let string as String:
            return expand(string: string, settings: settings, unknown: &unknown)
        case let array as [Sendable]:
            return array.map { expand($0, settings: settings, unknown: &unknown) }
        case let dictionary as [String: Sendable]:
            return expand(dictionary, settings: settings, unknown: &unknown)
        default:
            return value
        }
    }

    static func expand(string: String, settings: [String: String], unknown: inout Set<String>) -> String {
        var result = ""
        var rest = Substring(string)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            let afterDollar = rest.index(after: dollar)
            guard afterDollar < rest.endIndex, let close = closing(for: rest[afterDollar]),
                  let end = rest[afterDollar...].firstIndex(of: close)
            else {
                result.append("$")
                rest = rest[afterDollar...]
                continue
            }
            let reference = rest[rest.index(after: afterDollar)..<end]
            let parts = reference.split(separator: ":", maxSplits: 1)
            let name = String(parts.first ?? "")
            if let value = settings[name] {
                result += apply(modifier: parts.count > 1 ? String(parts[1]) : nil, to: value)
            } else {
                unknown.insert(name)
                result += rest[dollar...end]
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    private static func closing(for open: Character) -> Character? {
        switch open {
        case "(": ")"
        case "{": "}"
        default: nil
        }
    }

    private static func apply(modifier: String?, to value: String) -> String {
        let replacement: Character
        let kept: Set<Character>
        switch modifier {
        case "rfc1034identifier": (replacement, kept) = ("-", ["-", "."])
        case "c99extidentifier", "identifier": (replacement, kept) = ("_", ["_"])
        default: return value
        }
        return String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber) || kept.contains($0) ? $0 : replacement })
    }
}
