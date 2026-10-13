import SwiftUI

/// Shared building blocks for the developer console's panes — the SwiftUI
/// counterpart of the Godot `DevUI` helpers (cards with icon tiles, pills,
/// chips, switches, sparklines and empty-state art). Everything is drawn with
/// SF Symbols and plain shapes, so there are no image assets and it all scales
/// with `devFontScale` (tvOS).
///
/// Interactive pieces go through `CursorButton`, the same wrapper the rest of
/// the dev console uses, so the controller cursor can press them and tvOS keeps
/// them out of the focus engine.

// MARK: - Icon tile

/// A tinted rounded square holding one SF Symbol — the little coloured tile at
/// the head of every card.
struct DevIconTile: View {
    let symbol: String
    var tint: Color = devConsoleGreen
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5 * devFontScale, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size * devFontScale, height: size * devFontScale)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.16)))
    }
}

// MARK: - Pill

/// A coloured status capsule ("SET", "needs clear", "×3", "PASS" …).
struct DevPill: View {
    let text: String
    var color: Color = devConsoleGreen
    var symbol: String?
    var solid = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5 * devFontScale, weight: .bold))
            }
            Text(text)
                .font(.system(size: 9.5 * devFontScale, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        .foregroundStyle(solid ? Color.black.opacity(0.85) : color)
        .background(Capsule().fill(solid ? color.opacity(0.9) : color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(solid ? Color.clear : color.opacity(0.3)))
        .fixedSize()
    }
}

// MARK: - Card

/// A titled card: icon tile + title (and optional trailing widgets) over a
/// hairline, then the body. `highlight` tints it green (used for "Report ready").
struct DevCard<Trailing: View, Content: View>: View {
    let title: String
    let symbol: String
    var accent: Color = devConsoleGreen
    var highlight = false
    let trailing: Trailing
    let content: Content

    init(_ title: String, symbol: String, accent: Color = devConsoleGreen, highlight: Bool = false,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.highlight = highlight
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                DevIconTile(symbol: symbol, tint: accent)
                Text(title)
                    .font(.system(size: 14 * devFontScale, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            Rectangle().fill(devHairline).frame(height: 1)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(highlight ? devConsoleGreen.opacity(0.07) : .white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(highlight ? devConsoleGreen.opacity(0.4) : devHairline))
    }
}

extension DevCard where Trailing == EmptyView {
    init(_ title: String, symbol: String, accent: Color = devConsoleGreen, highlight: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(title, symbol: symbol, accent: accent, highlight: highlight,
                  trailing: { EmptyView() }, content: content)
    }
}

let devHairline = Color.white.opacity(0.075)

// MARK: - Chips and buttons

/// The look of a `DevChip`, without the button — so a `ShareLink` or `Menu`
/// can wear the same chrome.
struct DevChipLabel: View {
    let title: String
    var symbol: String?
    var tint: Color = devConsoleGreen
    var filled = false
    var expand = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10 * devFontScale, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 10.5 * devFontScale, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: expand ? .infinity : nil)
        .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(filled ? tint : tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(filled ? Color.clear : tint.opacity(0.28)))
        .contentShape(Rectangle())
    }
}

/// A tinted, rounded action chip with an optional leading symbol. `filled`
/// makes it the solid primary style.
struct DevChip: View {
    let title: String
    var symbol: String?
    var tint: Color = devConsoleGreen
    var filled = false
    var expand = false
    let action: () -> Void

    var body: some View {
        CursorButton(action: action) {
            DevChipLabel(title: title, symbol: symbol, tint: tint, filled: filled, expand: expand)
        }
    }
}

/// A square icon-only button.
struct DevIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white.opacity(0.7)
    var active = false
    let action: () -> Void

    var body: some View {
        CursorButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11 * devFontScale, weight: .semibold))
                .frame(width: 28 * devFontScale, height: 26 * devFontScale)
                .foregroundStyle(active ? devConsoleGreen : tint)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? devConsoleGreen.opacity(0.18) : tint.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? devConsoleGreen.opacity(0.4) : tint.opacity(0.18)))
                .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .help(help)
        #endif
        .accessibilityLabel(help)
    }
}

/// A filter chip with a coloured dot and (optionally) a live count.
struct DevFilterChip: View {
    let title: String
    let color: Color
    let active: Bool
    var count: Int?
    var symbol: String?
    let action: () -> Void

    var body: some View {
        CursorButton(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9.5 * devFontScale, weight: .bold))
                } else {
                    Circle().fill(active ? color : color.opacity(0.35))
                        .frame(width: 8 * devFontScale, height: 8 * devFontScale)
                }
                Text(title)
                    .font(.system(size: 10.5 * devFontScale, weight: .semibold, design: .rounded))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5 * devFontScale, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? color : .white.opacity(0.35))
            .background(Capsule().fill(active ? color.opacity(0.17) : .white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(active ? color.opacity(0.55) : .white.opacity(0.12)))
            .contentShape(Capsule())
        }
    }
}

// MARK: - Switch

/// The capsule on/off switch used by the Tools cards. Purely visual — the
/// caller wraps it in a `CursorButton` that submits the console command.
struct DevSwitch: View {
    let isOn: Bool

    var body: some View {
        let w = 40 * devFontScale, h = 22 * devFontScale
        Capsule()
            .fill(isOn ? devConsoleGreen.opacity(0.85) : .white.opacity(0.14))
            .frame(width: w, height: h)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.black.opacity(0.78) : Color.white.opacity(0.85))
                    .padding(3)
            }
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

// MARK: - Search field

/// The framed search field the browsers and the console filter share. The
/// border lights up green while it has focus.
struct DevSearchField: View {
    @Binding var text: String
    let placeholder: String
    #if !os(tvOS)
    @FocusState private var focused: Bool
    #endif

    init(text: Binding<String>, placeholder: String) {
        _text = text
        self.placeholder = placeholder
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12 * devFontScale))
                .foregroundStyle(.white.opacity(0.5))
            #if os(tvOS)
            TVCursorTextField(placeholder: placeholder, text: $text)
            #else
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12 * devFontScale, design: .rounded))
                .foregroundStyle(.white)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            #endif
            if !text.isEmpty {
                CursorButton { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12 * devFontScale))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.38)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(searchBorder))
    }

    private var searchBorder: Color {
        #if os(tvOS)
        return .white.opacity(0.11)
        #else
        return focused ? devConsoleGreen.opacity(0.85) : .white.opacity(0.11)
        #endif
    }
}

// MARK: - Sparkline

/// A tiny rolling line chart (no Charts dependency) for the metric tiles. The
/// series is left-anchored and grows to `capacity` samples, like the Godot one.
struct DevSparkline: View {
    let values: [Double]
    var color: Color = devConsoleGreen
    var capacity = 60

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let series = Array(values.suffix(capacity))
        guard series.count > 1 else { return [] }
        let hi = max(series.max() ?? 0, 0.001)
        let step = size.width / CGFloat(max(capacity - 1, 1))
        return series.enumerated().map { index, value in
            let y = size.height - 2 - (size.height - 4) * CGFloat(value / hi)
            return CGPoint(x: step * CGFloat(index), y: y)
        }
    }
}

// MARK: - Empty state

/// Decorative empty-state art, drawn with a `Canvas` in a fixed 150×112 space
/// and scaled to fit.
struct DevIllustration: View {
    enum Kind { case reports, log, search, list }
    let kind: Kind

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 150, size.height / 112)
            context.translateBy(x: (size.width - 150 * scale) / 2, y: (size.height - 112 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            draw(&context)
        }
        .aspectRatio(150.0 / 112.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func draw(_ c: inout GraphicsContext) {
        let accent = devConsoleGreen
        let faint = Color.white.opacity(0.05)
        let stroke = Color.white.opacity(0.16)
        switch kind {
        case .reports:
            c.fill(Path(ellipseIn: CGRect(x: 34, y: 94, width: 92, height: 12)), with: .color(faint))
            let tilt = CGAffineTransform(translationX: 60, y: 54).rotated(by: -8 * .pi / 180).translatedBy(x: -60, y: -54)
            let back = Path(roundedRect: CGRect(x: 30, y: 20, width: 62, height: 74), cornerRadius: 9).applying(tilt)
            c.fill(back, with: .color(faint))
            c.stroke(back, with: .color(stroke), lineWidth: 1.5)
            let page = Path(roundedRect: CGRect(x: 52, y: 14, width: 66, height: 78), cornerRadius: 9)
            c.fill(page, with: .color(Color(red: 0.063, green: 0.078, blue: 0.094)))
            c.stroke(page, with: .color(accent.opacity(0.55)), lineWidth: 1.8)
            for (y, w) in [(34.0, 42.0), (46.0, 42.0), (58.0, 26.0)] {
                var line = Path()
                line.move(to: CGPoint(x: 64, y: y))
                line.addLine(to: CGPoint(x: 64 + w, y: y))
                c.stroke(line, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
            let badge = Path(ellipseIn: CGRect(x: 89, y: 61, width: 30, height: 30))
            c.fill(badge, with: .color(accent.opacity(0.16)))
            c.stroke(badge, with: .color(accent), lineWidth: 1.8)
            var tick = Path()
            tick.move(to: CGPoint(x: 97.5, y: 76.5))
            tick.addLine(to: CGPoint(x: 102, y: 81))
            tick.addLine(to: CGPoint(x: 110.5, y: 72))
            c.stroke(tick, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        case .log:
            let win = Path(roundedRect: CGRect(x: 20, y: 18, width: 110, height: 74), cornerRadius: 10)
            c.fill(win, with: .color(Color(red: 0.063, green: 0.078, blue: 0.094)))
            c.stroke(win, with: .color(stroke), lineWidth: 1.5)
            var bar = Path()
            bar.move(to: CGPoint(x: 20, y: 34))
            bar.addLine(to: CGPoint(x: 130, y: 34))
            c.stroke(bar, with: .color(.white.opacity(0.1)), lineWidth: 1)
            for (x, col) in [(32.0, devConsoleRed), (41.0, devConsoleOrange), (50.0, accent)] {
                c.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 23.5, width: 5, height: 5)), with: .color(col.opacity(0.75)))
            }
            var prompt = Path()
            prompt.move(to: CGPoint(x: 32, y: 48))
            prompt.addLine(to: CGPoint(x: 40, y: 54))
            prompt.addLine(to: CGPoint(x: 32, y: 60))
            c.stroke(prompt, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            var dash = Path()
            dash.move(to: CGPoint(x: 48, y: 68))
            dash.addLine(to: CGPoint(x: 92, y: 68))
            c.stroke(dash, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            c.fill(Path(roundedRect: CGRect(x: 48, y: 51, width: 8, height: 14), cornerRadius: 2),
                   with: .color(accent.opacity(0.8)))
        case .search:
            let lens = Path(ellipseIn: CGRect(x: 40, y: 22, width: 56, height: 56))
            c.fill(lens, with: .color(.white.opacity(0.04)))
            c.stroke(lens, with: .color(.white.opacity(0.22)), lineWidth: 5)
            var handle = Path()
            handle.move(to: CGPoint(x: 90, y: 72))
            handle.addLine(to: CGPoint(x: 114, y: 96))
            c.stroke(handle, with: .color(accent.opacity(0.8)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            var dash = Path()
            dash.move(to: CGPoint(x: 56, y: 50))
            dash.addLine(to: CGPoint(x: 80, y: 50))
            c.stroke(dash, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        case .list:
            for (i, alpha) in [0.07, 0.05, 0.035].enumerated() {
                c.fill(Path(roundedRect: CGRect(x: 28, y: 22 + CGFloat(i) * 24, width: 94, height: 16), cornerRadius: 6),
                       with: .color(.white.opacity(alpha)))
            }
        }
    }
}

/// Illustration + title + hint, centred.
struct DevEmptyState: View {
    let kind: DevIllustration.Kind
    let title: String
    var hint: String?

    var body: some View {
        VStack(spacing: 4) {
            DevIllustration(kind: kind)
                .frame(width: 150 * devFontScale, height: 112 * devFontScale)
            Text(title)
                .font(.system(size: 14 * devFontScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            if let hint {
                Text(hint)
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

// MARK: - Misc

/// Small dim all-caps caption ("CATEGORIES", "QUICK", "FRAME BREAKDOWN").
struct DevCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9 * devFontScale, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
    }
}
