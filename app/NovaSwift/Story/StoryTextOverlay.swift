import SwiftUI

/// The story-text dialog (`Ui_RunTravelSelectionDialog` 0x004982a0): every
/// text the story engine shows — a briefing, a completion or failure text, a
/// no-room refusal — is a modal dialog of its own, so two texts raised by one
/// event are both shown, in order. `AppGameServices` queues them; this shows
/// the head of that queue and OK moves on to the next.
struct StoryTextOverlay: View {
    @ObservedObject var services: AppGameServices

    var body: some View {
        if let story = services.storyText {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                NovaDialog(title: story.title.isEmpty ? "Mission" : story.title,
                           width: 480,
                           buttons: [NovaDialogButton(title: "OK", isDefault: true) {
                               services.storyText = nil
                           }]) {
                    Text(story.text)
                        .novaFont(.body)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        }
    }
}
