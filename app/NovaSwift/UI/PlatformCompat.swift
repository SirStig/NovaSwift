import SwiftUI
import UniformTypeIdentifiers

/// Cross-platform shims for SwiftUI modifiers that don't exist on tvOS, so
/// call sites stay clean instead of sprouting `#if os(tvOS)` at every use.
#if os(tvOS)
/// Minimal focus-friendly stand-in for SwiftUI's `Stepper`, which doesn't
/// exist on tvOS: the label with −/+ buttons the remote can click. Being
/// module-local, it shadows the unavailable SwiftUI type at existing call
/// sites (the debug suite, trade UI) without changes there.
struct Stepper<V: Strideable>: View {
    private let title: LocalizedStringKey
    @Binding private var value: V
    private let range: ClosedRange<V>?
    private let step: V.Stride
    private let onIncrement: (() -> Void)?
    private let onDecrement: (() -> Void)?

    init(_ titleKey: LocalizedStringKey, value: Binding<V>,
         in range: ClosedRange<V>, step: V.Stride = 1) {
        self.title = titleKey
        self._value = value
        self.range = range
        self.step = step
        self.onIncrement = nil
        self.onDecrement = nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            button("minus") {
                if let onDecrement { onDecrement(); return }
                let next = value.advanced(by: -step)
                if let range { value = max(next, range.lowerBound) } else { value = next }
            }
            button("plus") {
                if let onIncrement { onIncrement(); return }
                let next = value.advanced(by: step)
                if let range { value = min(next, range.upperBound) } else { value = next }
            }
        }
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 26)
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .cursorClickable(action)
    }

    fileprivate init(_ titleKey: LocalizedStringKey, value: Binding<V>,
                     range: ClosedRange<V>?, step: V.Stride,
                     onIncrement: (() -> Void)?, onDecrement: (() -> Void)?) {
        self.title = titleKey
        self._value = value
        self.range = range
        self.step = step
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
    }
}

extension Stepper where V == Int {
    /// The closure-driven variant (`onIncrement`/`onDecrement`).
    init(_ titleKey: LocalizedStringKey,
         onIncrement: (() -> Void)?, onDecrement: (() -> Void)?) {
        self.init(titleKey, value: .constant(0), range: nil, step: 1,
                  onIncrement: onIncrement, onDecrement: onDecrement)
    }
}

/// `Slider` stand-in for tvOS, backed by `NovaSlider` (whose tvOS body is a
/// −/+ stepped track). `onEditingChanged` fires after each discrete step.
struct Slider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        NovaSlider(value: $value, range: range)
            .onChange(of: value) { onEditingChanged(false) }
    }
}
#endif

extension View {
    /// `.scrollContentBackground(.hidden)` where available; no-op on tvOS.
    @ViewBuilder
    func novaHiddenScrollContentBackground() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// `.fileImporter` where available; no-op on tvOS, which has no document
    /// picker — there, game data arrives over local Wi-Fi via `WebImportServer`
    /// and the Data Setup wizard's Apple TV path instead.
    @ViewBuilder
    func novaFileImporter(isPresented: Binding<Bool>,
                          allowedContentTypes: [UTType],
                          allowsMultipleSelection: Bool = false,
                          onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        self.fileImporter(isPresented: isPresented,
                          allowedContentTypes: allowedContentTypes,
                          allowsMultipleSelection: allowsMultipleSelection,
                          onCompletion: onCompletion)
        #endif
    }
}
