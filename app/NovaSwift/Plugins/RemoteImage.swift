import SwiftUI
import NovaSwiftPluginStore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An image loaded from a catalog URL through `RemoteImageCache` (memory + disk),
/// with a placeholder while loading or when the URL is missing or fails.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            guard let data = try? await RemoteImageCache.shared.data(for: url) else { return }
            #if canImport(UIKit)
            if let ui = UIImage(data: data) { image = Image(uiImage: ui) }
            #elseif canImport(AppKit)
            if let ns = NSImage(data: data) { image = Image(nsImage: ns) }
            #endif
        }
    }
}
