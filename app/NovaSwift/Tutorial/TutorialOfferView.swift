import SwiftUI

/// Offered to a brand-new pilot right after their scenario intro: a short,
/// skippable prompt to take flight training before the game begins. Uses the
/// authentic dialog chrome so it sits naturally over the main menu.
struct TutorialOfferView: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    var body: some View {
        NovaDialog(title: "Flight Training", width: 460, buttons: [
            NovaDialogButton(title: "Skip") { onSkip() },
            NovaDialogButton(title: "Start Training", isDefault: true) { onStart() },
        ]) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New to the cockpit? Take a short practice flight to learn how to fly, fight, switch weapons and land your ship.")
                    .novaFont(.body).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It won't affect your pilot, and you can skip it any time.")
                    .novaFont(.caption).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
