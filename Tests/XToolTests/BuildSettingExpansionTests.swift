import Foundation
import Testing
@testable import PackLib

struct BuildSettingExpansionTests {
    let settings = ["EXECUTABLE_NAME": "My App", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app"]

    @Test func expandsBothSyntaxesAndModifiers() {
        var unknown: Set<String> = []
        let expanded = BuildSettingExpansion.expand(string: "$(EXECUTABLE_NAME) ${PRODUCT_BUNDLE_IDENTIFIER}.$(EXECUTABLE_NAME:rfc1034identifier)/$(EXECUTABLE_NAME:c99extidentifier)", settings: settings, unknown: &unknown)
        #expect(expanded == "My App com.example.app.My-App/My_App")
        #expect(unknown.isEmpty)
    }

    @Test func leavesUnknownSettingsAndLoneDollars() {
        var unknown: Set<String> = []
        let expanded = BuildSettingExpansion.expand(string: "$(AppIdentifierPrefix)com.example.shared costs $5", settings: settings, unknown: &unknown)
        #expect(expanded == "$(AppIdentifierPrefix)com.example.shared costs $5")
        #expect(unknown == ["AppIdentifierPrefix"])
    }

    @Test func expandsNestedValues() {
        var unknown: Set<String> = []
        let plist: [String: Sendable] = [
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["$(PRODUCT_BUNDLE_IDENTIFIER)"]] as [String: Sendable]] as [Sendable],
            "Count": 3,
        ]
        let expanded = BuildSettingExpansion.expand(plist, settings: settings, unknown: &unknown)
        #expect(expanded["CFBundleExecutable"] as? String == "My App")
        let types = expanded["CFBundleURLTypes"] as? [Sendable]
        let schemes = (types?.first as? [String: Sendable])?["CFBundleURLSchemes"] as? [Sendable]
        #expect(schemes?.first as? String == "com.example.app")
        #expect(expanded["Count"] as? Int == 3)
    }
}
