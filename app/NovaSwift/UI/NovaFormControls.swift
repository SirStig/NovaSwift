import SwiftUI

/// Authentic-chrome replacements for stock `Toggle`/`Slider`/`Picker`, sharing
/// `NovaDialog.swift`'s dark-panel/amber visual language (the same
/// convention `NovaSelectRow`/`NovaDialogButton` already use) rather than
/// system controls. SwiftUI has no public `SliderStyle` and no arbitrary
/// custom `PickerStyle`, so only the toggle is a real style conformance —
/// the slider and pickers are standalone replacement views swapped in at
/// their call sites.

/// Checkbox-style `ToggleStyle` — apply once via `.toggleStyle(NovaToggleStyle())`
/// on a container to reskin every descendant `Toggle` without touching each
/// call site.
struct NovaToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? novaAmber : Color(white: 0.08))
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(configuration.isOn ? novaAmber : Color(white: 0.4), lineWidth: 1)
                    )
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                configuration.label
                    .novaFont(.body)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Drag-driven slider (amber-filled track + circular thumb) replacing the
/// stock `Slider` — swapped in at `sliderRow`'s one chokepoint in
/// `SettingsView`, so it covers every slider row without per-call-site changes.
struct NovaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    // A raw `DragGesture` — unlike native `Slider` — doesn't automatically
    // stop responding under an ambient `.disabled()`, so this reads it
    // explicitly (sliderRow's disabled audio-volume sliders rely on it).
    @Environment(\.isEnabled) private var isEnabled

    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 16

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let inset = thumbDiameter / 2
            let travel = max(0, geo.size.width - thumbDiameter)
            let thumbCenterX = inset + fraction * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.22))
                    .frame(height: trackHeight)
                    .padding(.horizontal, inset)
                Capsule()
                    .fill(novaAmber)
                    .frame(width: max(0, thumbCenterX - inset), height: trackHeight)
                    .padding(.leading, inset)
                Circle()
                    .fill(novaAmber)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .position(x: thumbCenterX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        let x = min(max(drag.location.x - inset, 0), travel)
                        let f = travel > 0 ? x / travel : 0
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: thumbDiameter)
    }
}

/// A manual row of tappable segments — amber-filled + black text when
/// selected, dark + white otherwise (the same convention `NovaSelectRow`
/// uses) — replacing `Picker(...).pickerStyle(.segmented)`.
struct NovaSegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .novaFont(.caption, weight: .semibold)
                        .foregroundStyle(isSelected ? .black : .white)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? novaAmber : Color(white: 0.14),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A row with a trailing popup-style value chip (current selection + chevron)
/// that opens a native `Menu` — replacing the default (`.menu`-style) `Picker`.
/// Uses a real `Menu` for the open/close interaction and accessibility, with
/// only the closed-state chip custom-drawn to match the dialog's chrome.
struct NovaMenuPicker<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack {
            Text(title).novaFont(.body).foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label(selection)).novaFont(.body).foregroundStyle(.white)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(novaAmber)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.35)))
            }
            .menuStyle(.borderlessButton)
            .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}
