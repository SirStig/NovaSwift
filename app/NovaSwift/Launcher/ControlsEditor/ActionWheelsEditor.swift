import SwiftUI
import GameController

/// The Controller tab's "Action Wheels" page: each wheel's trigger button and
/// slots, plus a live warning for any action the current setup leaves
/// unreachable from the pad. Everything is a `CursorButton` /
/// `NovaMenuPicker`, so it works with the pad alone.
struct ActionWheelsEditor: View {
    @EnvironmentObject private var model: AppModel
    let pad: GCExtendedGamepad?

    /// The slot being re-assigned: pick an action from the chooser list.
    @State private var choosing: SlotRef?

    private struct SlotRef: Equatable { var wheel: String; var slot: Int }

    private var wheels: [ActionWheel] { model.actionWheels.wheels }

    var body: some View {
        if let ref = choosing {
            chooser(ref)
        } else {
            overview
        }
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold a wheel's button, flick the right stick toward a slot, release to use it. A quick tap still does the button's normal action. Ⓑ cancels.")
                    .novaFont(.caption).foregroundStyle(.secondary)
                let missing = ActionWheels.uncovered(bindings: model.padBindings, wheels: model.actionWheels)
                if !missing.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Not reachable from the controller", systemImage: "exclamationmark.triangle.fill")
                            .novaFont(.caption, weight: .semibold).foregroundStyle(.orange)
                        Text(missing.map(\.title).joined(separator: ", "))
                            .novaFont(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                ForEach(wheels) { wheel in card(wheel) }
                CursorButton {
                    mutate { $0.resetToDefaults() }
                } label: {
                    Label("Reset wheels to defaults", systemImage: "arrow.counterclockwise")
                        .novaFont(.body).foregroundStyle(.red)
                }
            }
            .padding(.trailing, 4)
        }
        .cursorScrollable()
    }

    private func card(_ wheel: ActionWheel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(wheel.title).novaFont(.body, weight: .bold).foregroundStyle(novaAmber)
            NovaMenuPicker(title: "Trigger", selection: triggerBinding(wheel),
                           options: triggerOptions(for: wheel)) { $0.displayName(on: pad) }
            if !ActionWheels.canTrigger(wheel.trigger, bindings: model.padBindings) {
                Text("That button is bound to a held control (fire, thrust, afterburner), so this wheel is off. Pick another trigger.")
                    .novaFont(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(wheel.slots.enumerated()), id: \.offset) { i, action in
                slotRow(wheel, index: i, action: action)
            }
            if wheel.slots.count < ActionWheel.slotRange.upperBound {
                CursorButton {
                    addSlot(to: wheel)
                } label: { EditorChip(text: "Add slot") }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))
    }

    private func slotRow(_ wheel: ActionWheel, index i: Int, action: GameAction) -> some View {
        HStack(spacing: 4) {
            Text("\(i + 1)").novaFont(.caption).foregroundStyle(.secondary).frame(width: 18)
            CursorButton { choosing = SlotRef(wheel: wheel.id, slot: i) } label: {
                HStack(spacing: 6) {
                    Image(systemName: action.icon).foregroundStyle(action.tint).frame(width: 20)
                    Text(action.title).novaFont(.body).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            iconButton("chevron.up", enabled: i > 0, label: "Move \(action.title) up") { moveSlot(wheel, i, by: -1) }
            iconButton("chevron.down", enabled: i < wheel.slots.count - 1, label: "Move \(action.title) down") { moveSlot(wheel, i, by: 1) }
            iconButton("minus.circle", enabled: wheel.slots.count > ActionWheel.slotRange.lowerBound,
                       label: "Remove \(action.title)") { removeSlot(wheel, i) }
        }
    }

    private func iconButton(_ symbol: String, enabled: Bool, label: String,
                            action: @escaping () -> Void) -> some View {
        CursorButton(action: { if enabled { action() } }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Chooser

    /// Every eligible action grouped by category, tap to assign.
    private func chooser(_ ref: SlotRef) -> some View {
        let wheel = wheels.first { $0.id == ref.wheel }
        let current = wheel.flatMap { $0.slots.indices.contains(ref.slot) ? $0.slots[ref.slot] : nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Slot \(ref.slot + 1) of \(wheel?.title ?? "")").novaFont(.body, weight: .bold)
                    .foregroundStyle(novaAmber)
                Spacer()
                CursorButton { choosing = nil } label: { EditorChip(text: "Back") }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(GameAction.Category.allCases) { category in
                        let actions = GameAction.allCases.filter {
                            $0.category == category && ActionWheels.isSlotEligible($0)
                        }
                        if !actions.isEmpty {
                            Text(category.rawValue.uppercased())
                                .novaFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                                .padding(.top, 8).padding(.bottom, 2)
                            ForEach(actions) { action in
                                CursorButton {
                                    setSlot(ref, to: action)
                                    choosing = nil
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: action.icon).foregroundStyle(action.tint).frame(width: 20)
                                        Text(action.title).novaFont(.body)
                                        Spacer(minLength: 0)
                                        if action == current {
                                            Image(systemName: "checkmark").foregroundStyle(novaAmber)
                                        }
                                    }
                                    .padding(.vertical, 3).padding(.horizontal, 6)
                                    .background(action == current ? novaAmber.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .cursorScrollable()
        }
        .cursorCancel { choosing = nil }
    }

    // MARK: Editing

    /// Buttons that may trigger `wheel`: not bound to a held control and not
    /// already another wheel's trigger.
    private func triggerOptions(for wheel: ActionWheel) -> [PadButton] {
        let others = Set(wheels.filter { $0.id != wheel.id }.map(\.trigger))
        return PadButton.allCases.filter {
            $0 == wheel.trigger
                || (ActionWheels.canTrigger($0, bindings: model.padBindings) && !others.contains($0))
        }
    }

    private func triggerBinding(_ wheel: ActionWheel) -> Binding<PadButton> {
        Binding(get: { wheel.trigger },
                set: { new in mutate { w in
                    guard let i = w.wheels.firstIndex(where: { $0.id == wheel.id }),
                          ActionWheels.canTrigger(new, bindings: model.padBindings) else { return }
                    w.wheels[i].trigger = new
                } })
    }

    private func mutate(_ change: (inout ActionWheels) -> Void) {
        change(&model.actionWheels)
        model.commitActionWheels()
    }

    private func edit(_ wheel: ActionWheel, _ change: (inout ActionWheel) -> Void) {
        mutate { w in
            guard let i = w.wheels.firstIndex(where: { $0.id == wheel.id }) else { return }
            change(&w.wheels[i])
        }
    }

    private func setSlot(_ ref: SlotRef, to action: GameAction) {
        mutate { w in
            guard let i = w.wheels.firstIndex(where: { $0.id == ref.wheel }),
                  w.wheels[i].slots.indices.contains(ref.slot) else { return }
            w.wheels[i].slots[ref.slot] = action
        }
    }

    private func moveSlot(_ wheel: ActionWheel, _ i: Int, by d: Int) {
        edit(wheel) { w in
            let j = i + d
            guard w.slots.indices.contains(i), w.slots.indices.contains(j) else { return }
            w.slots.swapAt(i, j)
        }
    }

    private func removeSlot(_ wheel: ActionWheel, _ i: Int) {
        edit(wheel) { w in
            guard w.slots.count > ActionWheel.slotRange.lowerBound, w.slots.indices.contains(i) else { return }
            w.slots.remove(at: i)
        }
    }

    /// Appends the first action the pad can't otherwise reach (else any
    /// eligible one not already on this wheel) and opens the chooser on it.
    private func addSlot(to wheel: ActionWheel) {
        guard wheel.slots.count < ActionWheel.slotRange.upperBound else { return }
        let missing = ActionWheels.uncovered(bindings: model.padBindings, wheels: model.actionWheels)
            .first(where: ActionWheels.isSlotEligible)
        let fallback = GameAction.allCases.first { ActionWheels.isSlotEligible($0) && !wheel.slots.contains($0) }
        guard let pick = missing ?? fallback else { return }
        edit(wheel) { $0.slots.append(pick) }
        choosing = SlotRef(wheel: wheel.id, slot: wheel.slots.count)
    }
}
