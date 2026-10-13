import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore

// Shared visual pieces for the Plug-ins hub: procedural space art, tinted banners,
// section headers, fact tiles, illustrations. Pure SwiftUI shapes and SF Symbols.

/// Accent used across the hub (matches the rest of the app's amber).
let pluginAccent = novaAmber
/// Colour for total conversions.
let pluginTCTint = Color(red: 0.45, green: 0.45, blue: 1.0)

/// Stable (not per-launch) seed so a plug-in keeps its sky.
func pluginArtSeed(_ id: String) -> Int {
    id.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 9973 } % 97 + 1
}

extension PluginFilter {
    var symbolName: String {
        switch self {
        case .popular: return "star.fill"
        case .recent: return "clock"
        case .totalConversions: return "sparkles"
        case .ships: return "airplane"
        case .story: return "book"
        case .graphics: return "photo"
        case .gameplay: return "slider.horizontal.3"
        case .installed: return "checkmark.circle.fill"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

/// Procedural backdrop: deep gradient, a big planet, a ring and a field of stars.
/// Deterministic for a given `seed` so a plug-in always gets the same sky.
struct PluginSpaceArt: View {
    var tint: Color = pluginTCTint
    var seed: Int = 1

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // Planet and ring sit toward the right.
            let r = min(h * 0.62, w * 0.3)
            let c = CGPoint(x: w * (0.78 + 0.05 * Double(seed % 3) / 2), y: h * 0.42)
            let planet = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: planet),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.55), tint.opacity(0.12)]),
                                           center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.3),
                                           startRadius: 0, endRadius: r * 1.2))
            // Small moon.
            let mr = r * 0.22
            let moon = CGRect(x: w * 0.42 - mr, y: h * 0.58 - mr, width: mr * 2, height: mr * 2)
            ctx.fill(Path(ellipseIn: moon), with: .color(tint.opacity(0.18)))
            // Ring: a tilted ellipse.
            var ring = Path(ellipseIn: CGRect(x: -r * 1.5, y: -r * 0.38, width: r * 3, height: r * 0.76))
            ring = ring.applying(CGAffineTransform(rotationAngle: -0.28).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            ctx.stroke(ring, with: .color(tint.opacity(0.65)), lineWidth: max(1.5, r * 0.035))
            // Stars from a tiny LCG.
            var state = UInt64(truncatingIfNeeded: seed) &* 2862933555777941757 &+ 3037000493
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 33) / Double(1 << 31)
            }
            for _ in 0..<34 {
                let x = next() * w, y = next() * h, s = 0.8 + next() * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)),
                         with: .color(.white.opacity(0.25 + next() * 0.5)))
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.03, green: 0.03, blue: 0.09),
                                    tint.opacity(0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .accessibilityHidden(true)
    }
}

/// Icon + title (+ optional trailing note) heading a section.
struct PluginSectionHeader: View {
    let symbol: String
    let title: String
    var note: String?
    var tint: Color = pluginAccent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).font(.headline)
            Text(title).font(.title3.weight(.semibold))
            if let note { Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

/// Tinted full-width card: offline, refreshing, update-all, failures.
struct PluginBanner<Trailing: View>: View {
    let symbol: String
    var tint: Color = pluginAccent
    let title: String
    var message: String?
    var showsSpinner = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.2))
                if showsSpinner { ProgressView() } else { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}

extension PluginBanner where Trailing == EmptyView {
    init(symbol: String, tint: Color = pluginAccent, title: String, message: String? = nil, showsSpinner: Bool = false) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, showsSpinner: showsSpinner) { EmptyView() }
    }
}

/// One fact on the detail page: icon tile, small label, bold value.
struct PluginFactTile: View {
    let symbol: String
    let label: String
    let value: String
    var tint: Color = pluginAccent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Card surface used for grouped content.
struct PluginCardSurface: ViewModifier {
    var tint: Color?
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.3)))
    }
}

extension View {
    func pluginCardSurface(tint: Color? = nil) -> some View { modifier(PluginCardSurface(tint: tint)) }
}

/// Puzzle piece in orbit: the empty-state illustration.
struct PluginEmptyIllustration: View {
    var symbol = "puzzlepiece.extension.fill"
    var tint: Color = pluginAccent

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1.5).frame(width: 118, height: 118)
            Circle().strokeBorder(tint.opacity(0.30), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
                .frame(width: 86, height: 86)
            Circle().fill(tint.opacity(0.16)).frame(width: 64, height: 64)
            Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(tint)
            Circle().fill(tint).frame(width: 7, height: 7).offset(x: 59 * 0.7071, y: -59 * 0.7071)
            Circle().fill(Color.white.opacity(0.5)).frame(width: 4, height: 4).offset(x: -43, y: 12)
        }
        .frame(width: 130, height: 130)
        .accessibilityHidden(true)
    }
}

/// Three stacked layers with an arrow: base game, plug-ins, later wins.
struct PluginLayerDiagram: View {
    private func diamond(_ rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let layerW = w * 0.62, layerH = h * 0.30
            let x0 = w - layerW - 4
            let colors: [Color] = [Color.white.opacity(0.55), Color.cyan, pluginAccent]
            for (i, color) in colors.enumerated() {
                let y = h - layerH - 6 - CGFloat(i) * h * 0.24
                let path = diamond(CGRect(x: x0, y: y, width: layerW, height: layerH))
                ctx.fill(path, with: .color(color.opacity(0.18)))
                ctx.stroke(path, with: .color(color), lineWidth: 1.5)
            }
            // Arrow pointing "later wins".
            var arrow = Path()
            arrow.move(to: CGPoint(x: 8, y: h - 8)); arrow.addLine(to: CGPoint(x: 8, y: 8))
            arrow.move(to: CGPoint(x: 2, y: 15)); arrow.addLine(to: CGPoint(x: 8, y: 7)); arrow.addLine(to: CGPoint(x: 14, y: 15))
            ctx.stroke(arrow, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        }
        .frame(width: 96, height: 84)
        .accessibilityHidden(true)
    }
}

/// Small pill label ("Enhancement", "Loads automatically", "Base").
struct PluginChip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.16), in: Capsule())
        .lineLimit(1)
    }
}

/// Download progress bar with a percentage, used on cards and in the detail action bar.
struct PluginProgressBar: View {
    let progress: Double?
    var body: some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress).tint(pluginAccent)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
                Text("Working...").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Reveal on disk (macOS)

/// Where an installed plug-in lives: its folder, else the folder holding its first file.
func pluginRevealURL(_ bundle: PluginBundle, pluginsRoot: URL) -> URL? {
    let fm = FileManager.default
    if let folder = bundle.folderURL, fm.fileExists(atPath: folder.path) { return folder }
    let byID = pluginsRoot.appendingPathComponent(bundle.id, isDirectory: true)
    if fm.fileExists(atPath: byID.path) { return byID }
    return bundle.allFileURLs.first
}

/// Short "where it came from" text: the folder name its files sit in.
func pluginSourceFolderName(_ bundle: PluginBundle) -> String {
    if let folder = bundle.folderURL { return folder.lastPathComponent }
    if let first = bundle.allFileURLs.first { return first.deletingLastPathComponent().lastPathComponent }
    return bundle.id
}
