import SwiftUI

/// A one-time, contextual in-game hint — an inline, highlighted, dismissible tip
/// shown the first time the player reaches a moment that benefits from a nudge
/// (their first landing, first look at the Mission BBS, and so on). Every hint is
/// gated by the "Tutorial hints" setting and shown at most once, so it stays
/// helpful without becoming noise.
struct GameHint: Identifiable, Equatable {
    /// Stable id — also the persistence key suffix, so it must never change once
    /// shipped or the hint would re-appear for players who've already seen it.
    let id: String
    let title: String
    let systemImage: String
    let message: String
}

/// Remembers which contextual hints the player has already dismissed. Backed by
/// `UserDefaults` so a hint fires only once per install (independent of pilots).
enum HintTracker {
    private static func key(_ id: String) -> String { "novaswift.hint.\(id)" }

    static func seen(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }
    static func markSeen(_ id: String) { UserDefaults.standard.set(true, forKey: key(id)) }

    /// Clear every hint's seen-state so they all show again — wired to a
    /// "Reset hints" affordance in Settings.
    static func resetAll() {
        for hint in GameHints.all { UserDefaults.standard.removeObject(forKey: key(hint.id)) }
    }
}

/// The catalog of contextual hints. Keeping them in one place makes it easy to
/// add more and to reset them all at once.
enum GameHints {
    static let spaceportServices = GameHint(
        id: "spaceport.services", title: "Welcome to the spaceport",
        systemImage: "building.2.fill",
        message: "Visit the Mission BBS and the Bar to find jobs and meet people, the Trade Center to buy and sell cargo, and the Outfitter or Shipyard to upgrade your ship. Tap Leave to take off again.")

    static let missionBBS = GameHint(
        id: "missionBBS.howto", title: "Taking a job",
        systemImage: "list.bullet.rectangle.fill",
        message: "Select a listing to read its briefing, then Accept to take the job. Cargo and courier missions pay when you deliver — watch for any deadline.")

    static let outfitter = GameHint(
        id: "outfitter.howto", title: "Upgrading your ship",
        systemImage: "wrench.and.screwdriver.fill",
        message: "Outfits install permanently — afterburners, shields, weapons and cargo space. Some need free mass or a specific hull, so check the description before you buy.")

    static let all: [GameHint] = [spaceportServices, missionBBS, outfitter]
}

/// The inline hint card itself: an amber-accented, dismissible banner in the EV
/// Nova HUD idiom. Deliberately quiet — it explains, then gets out of the way.
struct HintBanner: View {
    let hint: GameHint
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: hint.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(novaAmber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(hint.title)
                    .novaFont(.body, weight: .bold).foregroundStyle(novaAmber)
                Text(hint.message)
                    .novaFont(.caption).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.novaPlain)
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(novaAmber.opacity(0.4)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

extension View {
    /// Presents `hint` as a top banner over this view when `active` is true and
    /// the hint hasn't been dismissed before. Dismissal (tap ✕ or "Got it")
    /// records it as seen so it never returns. `active` should already fold in
    /// the "Tutorial hints" setting and any context gate (e.g. "on the hub").
    func gameHint(_ hint: GameHint, active: Bool,
                  dismissed: Binding<Bool>) -> some View {
        overlay(alignment: .top) {
            if active && !dismissed.wrappedValue && !HintTracker.seen(hint.id) {
                HintBanner(hint: hint) {
                    HintTracker.markSeen(hint.id)
                    dismissed.wrappedValue = true
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(50)
            }
        }
    }
}
