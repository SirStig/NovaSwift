import SwiftUI
import NovaSwiftKit

/// The "New Pilot" flow, presented as an authentic EV Nova dialog over the title
/// backdrop. Like the real game: when the data defines a single scenario it goes
/// straight to name entry; when a plug-in adds more, a scenario-select step comes
/// first. On start the pilot is created from the chosen `chär`, the story intro
/// plays, then the game begins.
struct NewPilotView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog. Injected by the presenter (the menu shows dialogs as
    /// full-screen overlays, not macOS sheets, so there's no `@Environment(\.dismiss)`
    /// to lean on) — see `AuthenticMainMenuView.dialogOverlay`.
    var onClose: () -> Void = {}

    private enum Step { case scenario, name }
    @State private var step: Step = .scenario
    @State private var name = ""
    @State private var isMale = true
    @State private var scenarioIndex = 0

    private var scenarios: [CharRes] { model.data.game?.selectableScenarios() ?? [] }

    var body: some View {
        Group {
            if scenarios.isEmpty {
                noDataDialog
            } else {
                switch effectiveStep {
                case .scenario: scenarioDialog
                case .name:     nameDialog
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear { if scenarios.count <= 1 { step = .name } }
    }

    // With one scenario there's no picker — jump to the name step (real behavior).
    private var effectiveStep: Step { scenarios.count <= 1 ? .name : step }

    // MARK: Scenario select

    private var scenarioDialog: some View {
        NovaDialog(title: "Select a Scenario", width: 500, buttons: [
            NovaDialogButton(title: "Cancel") { onClose() },
            NovaDialogButton(title: "Continue", isDefault: true) { step = .name },
        ]) {
            VStack(spacing: 8) {
                ForEach(Array(scenarios.enumerated()), id: \.element.id) { i, ch in
                    NovaSelectRow(title: ch.displayName, selected: i == scenarioIndex) {
                        NovaText(summary(ch), size: 11,
                                 color: i == scenarioIndex ? Color(white: 0.15) : .secondary)
                    } action: {
                        model.audio.play(.uiSelect); scenarioIndex = i
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    // MARK: Name entry

    // Real layout ground truth: DITL #3102 "new New Pilot" (the single-scenario
    // variant — item 12's "character popup" sits off-canvas at top=277 against a
    // 213-tall window, i.e. unused here; #3101 is the multi-scenario twin with
    // that popup on-canvas instead). #3102's live items are internally consistent
    // with its DLOG bounds (326x213), unlike #3100 "New Pilot"'s stale DLOG rect
    // and its resControl pointing at a CNTL 128 that doesn't exist anywhere in the
    // data — #3100 reads as vestigial, #3102 as the real shipped dialog. Its title
    // is content, not a window title (DLOG title=""): statText item 11,
    // "Create a new pilot:". Item 4 "Full Name:" (84w) sits beside its editText
    // (item 7) on the same row (both top=36) rather than stacked above it, and
    // CNTL 500 "gender popup" (item 10, 200x20) is its own row below.
    private var nameDialog: some View {
        let scenario = scenarios[min(scenarioIndex, scenarios.count - 1)]
        return NovaDialog(title: "Create a New Pilot", width: 400, buttons: [
            NovaDialogButton(title: "Cancel") {
                if scenarios.count > 1 { step = .scenario } else { onClose() }
            },
            NovaDialogButton(title: "Create", isDefault: true, enabled: true) {
                start(scenario)
            },
        ]) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    NovaText("Full Name:", size: 13, width: 84)
                    NovaTextField(placeholder: "Captain", text: $name)
                }

                HStack(spacing: 12) {
                    NovaText("Gender:", size: 13, width: 84)
                    Picker("", selection: $isMale) {
                        Text("Male").tag(true); Text("Female").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                // A one-line reminder of what this scenario starts you with.
                NovaText(summary(scenario), size: 11, color: .secondary)
            }
        }
    }

    private var noDataDialog: some View {
        NovaDialog(title: "No Scenarios", width: 420, buttons: [
            NovaDialogButton(title: "OK", isDefault: true) { onClose() },
        ]) {
            NovaText("No starting scenarios were found. Import your EV Nova data first.",
                     size: 13, width: 360)
        }
    }

    // MARK: Actions

    private func start(_ scenario: CharRes) {
        _ = model.createPilot(name: name, isMale: isMale, scenario: scenario)
        onClose()
        if scenario.introSlides.isEmpty && scenario.introTextID == nil {
            model.beginPlay()
        } else {
            // Presented full-screen at the RootView level, outside this dialog's
            // sheet frame — see AppModel.pendingIntro.
            model.pendingIntro = scenario
        }
    }

    private func summary(_ ch: CharRes) -> String {
        let ship = model.data.game?.ship(ch.shipID)?.name ?? "ship"
        return "\(ch.cash.formatted()) cr · \(ship) · \(ch.startDay)/\(ch.startMonth)/\(ch.startYear)\(ch.dateSuffix)"
    }
}
