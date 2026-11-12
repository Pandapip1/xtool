import ExampleSupport
import SwiftUI

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            Color("Accent", bundle: .module)
                .task {
                    checkColor()
                    checkImage()
                    Example.pass()
                }
        }
    }
}

#if canImport(AppKit)
import AppKit

private func checkColor() {
    guard let color = NSColor(named: "Accent", bundle: .module)?.usingColorSpace(.sRGB) else {
        fatalError("Missing Accent color")
    }
    let components = [color.redComponent, color.greenComponent, color.blueComponent]
    guard zip(components, [0.25, 0.5, 0.75]).allSatisfy({ abs($0 - $1) < 0.01 }) else {
        fatalError("Wrong Accent color: \(components)")
    }
}

private func checkImage() {
    guard let image = Bundle.module.image(forResource: "Swatch") else {
        fatalError("Missing Swatch image")
    }
    guard image.size == CGSize(width: 1, height: 1) else {
        fatalError("Wrong Swatch size: \(image.size)")
    }
}
#else
import UIKit

private func checkColor() {
    guard let color = UIColor(named: "Accent", in: .module, compatibleWith: nil) else {
        fatalError("Missing Accent color")
    }
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    guard zip([red, green, blue], [0.25, 0.5, 0.75]).allSatisfy({ abs($0 - $1) < 0.01 }) else {
        fatalError("Wrong Accent color: \([red, green, blue])")
    }
}

private func checkImage() {
    guard let image = UIImage(named: "Swatch", in: .module, compatibleWith: nil) else {
        fatalError("Missing Swatch image")
    }
    guard image.size == CGSize(width: 1, height: 1) else {
        fatalError("Wrong Swatch size: \(image.size)")
    }
}
#endif
