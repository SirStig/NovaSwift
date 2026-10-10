import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

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

    private enum Step { case scenario, name, shipName }
    @State private var step: Step = .scenario
    @State private var name = ""
    /// The second name field, `<PNN>` (0x0048a7e0).
    @State private var nickname = ""
    /// The ship name asked for after the dialog (0x00489d70), `<PSN>`.
    @State private var shipName = ""
    @State private var defaultsFilled = false
    @State private var isMale = true
    @State private var strictPlay = false
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
                case .shipName: shipNameDialog
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear {
            if scenarios.count <= 1 { step = .name }
            fillDefaults()
        }
    }

    // With one scenario there's no picker — jump to the name step (real behavior).
    private var effectiveStep: Step { scenarios.count <= 1 && step == .scenario ? .name : step }

    /// The fields open prefilled from STR# 128 (0x00489d70).
    private func fillDefaults() {
        guard !defaultsFilled, let game = model.data.game else { return }
        defaultsFilled = true
        name = PilotFactory.defaultName(.pilot, game: game)
        nickname = PilotFactory.defaultName(.nickname, game: game)
    }

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
        if classicChrome { return AnyView(classicNameDialog) }
        return AnyView(modernNameDialog)
    }

    private var classicChrome: Bool { !model.settings.modernDialogs && model.data.game != nil }

    /// DLOG/DITL 3102 in the native window: OK (0), Cancel (1), Strict Play
    /// (3), "Full Name:"/"Nickname:" (4/5) with their edit fields (7/8) and
    /// the gender pop-up (10).
    private var classicNameDialog: some View {
        ClassicDITLDialog(
            game: model.data.game, graphics: model.uiGraphics, id: 3102,
            fallbackSize: CGSize(width: 360, height: 220),
            checks: [3: $strictPlay],
            edits: [7: $name, 8: $nickname],
            actions: [0: confirmName, 1: cancelName],
            popups: [10: (labels: ["Male", "Female"],
                          selection: Binding(get: { isMale ? 0 : 1 }, set: { isMale = $0 == 0 }))],
            defaultItem: 0, cancelItem: 1)
    }

    private func cancelName() {
        if scenarios.count > 1 { step = .scenario } else { onClose() }
    }

    private func confirmName() {
        // A name or nickname over 24 characters beeps and is refused.
        guard name.count <= PilotFactory.maxNameLength,
              nickname.count <= PilotFactory.maxNameLength else {
            model.audio.play(.uiError)
            return
        }
        if let game = model.data.game { shipName = PilotFactory.defaultName(.ship, game: game) }
        step = .shipName
    }

    private var modernNameDialog: some View {
        let scenario = scenarios[min(scenarioIndex, scenarios.count - 1)]
        return NovaDialog(title: "Create a New Pilot", width: 400, buttons: [
            NovaDialogButton(title: "Cancel") {
                if scenarios.count > 1 { step = .scenario } else { onClose() }
            },
            NovaDialogButton(title: "Create", isDefault: true, enabled: true) {
                // A name or nickname over 24 characters beeps and is refused.
                guard name.count <= PilotFactory.maxNameLength,
                      nickname.count <= PilotFactory.maxNameLength else {
                    model.audio.play(.uiError)
                    return
                }
                if let game = model.data.game { shipName = PilotFactory.defaultName(.ship, game: game) }
                step = .shipName
            },
        ]) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    NovaText("Full Name:", size: 13, width: 84)
                    NovaTextField(placeholder: "Captain", text: $name,
                                  padSuggestions: { PilotNames.suggestions() })
                    // Rather not type (especially with a controller)? Roll one.
                    CursorButton {
                        model.audio.play(.uiSelect)
                        name = PilotNames.random()
                    } label: {
                        Image(systemName: "dice")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(novaAmber)
                            .frame(width: 34, height: 34)
                            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.3)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.novaPlain)
                }

                HStack(spacing: 10) {
                    NovaText("Nickname:", size: 13, width: 84)
                    NovaTextField(placeholder: "", text: $nickname)
                }

                HStack(spacing: 12) {
                    NovaText("Gender:", size: 13, width: 84)
                    NovaSegmentedPicker(selection: $isMale, options: [true, false]) {
                        $0 ? "Male" : "Female"
                    }
                    .frame(width: 200)
                }
                // The original's "Strict Play" checkbox (DITL control 4), off by
                // default: no speed bonus, and death without a pod is permanent.
                Toggle("Strict Play", isOn: $strictPlay)
                    .toggleStyle(NovaToggleStyle())
                    .frame(width: 200)
                // A one-line reminder of what this scenario starts you with.
                NovaText(summary(scenario), size: 11, color: .secondary)
            }
        }
    }

    /// The ship-name prompt after the pilot dialog (0x00489d70): STR# 2002
    /// #121 and the hull's name. Cancelling abandons the new pilot.
    private var shipNameDialog: some View {
        classicChrome ? AnyView(classicShipNameDialog) : AnyView(modernShipNameDialog)
    }

    /// DLOG/DITL 3001 "Text Input": the prompt (2), the name field (4, 64
    /// characters at most — longer input beeps), OK (0) and Cancel (5).
    private var classicShipNameDialog: some View {
        let scenario = scenarios[min(scenarioIndex, scenarios.count - 1)]
        let prompt = model.data.game.map { PilotFactory.shipNamePrompt(scenario: scenario, game: $0) } ?? ""
        return ClassicDITLDialog(
            game: model.data.game, graphics: model.uiGraphics, id: 3001,
            fallbackSize: CGSize(width: 360, height: 140),
            texts: [2: prompt], edits: [4: $shipName],
            actions: [0: {
                guard shipName.utf8.count <= 64 else { model.audio.play(.uiError); return }
                start(scenario)
            }, 5: { onClose() }],
            defaultItem: 0, cancelItem: 5)
    }

    private var modernShipNameDialog: some View {
        let scenario = scenarios[min(scenarioIndex, scenarios.count - 1)]
        let prompt = model.data.game.map { PilotFactory.shipNamePrompt(scenario: scenario, game: $0) } ?? ""
        return NovaDialog(title: "", width: 400, buttons: [
            NovaDialogButton(title: "Cancel") { onClose() },
            NovaDialogButton(title: "OK", isDefault: true, enabled: true) { start(scenario) },
        ]) {
            VStack(alignment: .leading, spacing: 10) {
                NovaText(prompt, size: 13, width: 360)
                NovaTextField(placeholder: "", text: $shipName)
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
        _ = model.createPilot(name: name, isMale: isMale, strictPlay: strictPlay, scenario: scenario,
                              nickname: nickname, shipName: shipName)
        onClose()
        if scenario.introSlides.isEmpty && scenario.introTextID == nil {
            // No intro to play — go straight to the flight-training offer.
            model.offerTutorialAfterNewPilot()
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
