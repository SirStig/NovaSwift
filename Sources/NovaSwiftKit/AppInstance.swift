import Foundation

/// Per-process instance identity, used to run **two copies of NovaSwift on one
/// machine** for local-multiplayer testing without them clobbering each other's
/// pilot saves.
///
/// Set the `NOVASWIFT_INSTANCE` environment variable (e.g. `2`) when launching a
/// second copy. That copy then keeps its **pilot saves** and instance-scoped
/// defaults in a suffixed location (`NovaSwift-2/…`, suite `novaswift-2`) while
/// still **sharing the imported game data** (the big BYO EV Nova files) with the
/// primary instance — so you import once and both instances play it. Unset (the
/// normal case) everything resolves to the plain `NovaSwift` store and
/// `UserDefaults.standard`, so shipping builds are completely unaffected.
///
/// See `scripts/run-two.sh` and `docs/MULTIPLAYER.md` → "Testing on one machine".
public enum AppInstance {
    /// The raw instance tag from the environment, trimmed; empty when unset.
    public static var tag: String {
        (ProcessInfo.processInfo.environment["NOVASWIFT_INSTANCE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this process is a secondary test instance.
    public static var isSecondary: Bool { !tag.isEmpty }

    /// `""` for the primary instance, `"-<tag>"` otherwise. Append to a folder or
    /// suite name to scope it to this instance.
    public static var suffix: String { isSecondary ? "-\(tag)" : "" }

    /// Application-Support subfolder for **pilot saves** — `NovaSwift` primary,
    /// `NovaSwift-<tag>` secondary. (Imported game data deliberately stays under
    /// plain `NovaSwift` so both instances share one import — see the type doc.)
    public static var saveFolderName: String { "NovaSwift\(suffix)" }

    /// Defaults store scoped to this instance: `.standard` for the primary, a
    /// per-instance suite for a secondary so the two don't fight over things like
    /// the selected pilot. Falls back to `.standard` if the suite can't open.
    public static var defaults: UserDefaults {
        guard isSecondary else { return .standard }
        return UserDefaults(suiteName: "novaswift\(suffix)") ?? .standard
    }
}
