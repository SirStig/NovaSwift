import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Minimal iOS/macOS-agnostic wrapper for loading a bundled screenshot file
/// into a SwiftUI `Image`. Used by the plug-in store's thumbnail/carousel
/// views, which load images by file path (from `PluginCatalog.screenshotURL`)
/// rather than by asset-catalog name.
struct PlatformImage {
    #if canImport(UIKit)
    private let backing: UIImage
    #elseif canImport(AppKit)
    private let backing: NSImage
    #endif

    init?(contentsOfFile path: String) {
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        backing = image
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        backing = image
        #else
        return nil
        #endif
    }

    var swiftUIImage: Image {
        #if canImport(UIKit)
        Image(uiImage: backing)
        #elseif canImport(AppKit)
        Image(nsImage: backing)
        #endif
    }
}
