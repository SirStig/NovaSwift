import Foundation

/// The root directory NovaSwift persists into (imported game data, plug-ins,
/// pilot saves). Application Support on macOS/iOS. tvOS's sandbox only allows
/// writing inside Caches, so the same tree lives there instead — the system
/// may purge it under storage pressure, which the Apple TV setup flow warns
/// about (game data can always be re-sent over Wi-Fi).
enum NovaStorage {
    static var root: URL {
        #if os(tvOS)
        (try? FileManager.default.url(for: .cachesDirectory,
                                      in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #else
        (try? FileManager.default.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #endif
    }
}
