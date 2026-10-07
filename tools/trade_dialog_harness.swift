import AppKit
import CoreText
import SwiftUI

// Compile this file with the real TradeQuantityPrompt.swift and NovaFont.swift.
// These shims retain native control visuals, excluding the game's controller
// registry and AppModel dependencies. No game bootstrap or storage is linked.
let novaAmber = Color(red: 1, green: 0.7, blue: 0.28)

private struct ControlBounds: Equatable {
    let kind: String
    let frame: CGRect
}

private struct ControlBoundsKey: PreferenceKey {
    static var defaultValue: [ControlBounds] = []
    static func reduce(value: inout [ControlBounds], nextValue: () -> [ControlBounds]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BoundsProbe: View {
    let kind: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ControlBoundsKey.self, value: [
                ControlBounds(kind: kind, frame: geometry.frame(in: .named("dialog")))
            ])
        }
    }
}

struct NovaTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder)
            .font(.custom(NovaFontRole.body.family, size: NovaFontRole.body.baseSize))
            .foregroundColor(.secondary))
            .textFieldStyle(.plain)
            .novaFont(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.3)))
            .background(BoundsProbe(kind: "field"))
    }
}

struct NovaPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.plain)
            .background(BoundsProbe(kind: "footer"))
    }
}

extension PrimitiveButtonStyle where Self == NovaPlainButtonStyle {
    static var novaPlain: NovaPlainButtonStyle { NovaPlainButtonStyle() }
}

private final class Observation {
    var controls: [ControlBounds] = []
}

private struct Scenario {
    let name: String
    let title: String
    let upper: Int
    let initial: Int
    let unit: String
    let scale: CGFloat
}

private func settle(_ host: NSView) {
    for _ in 0..<8 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
    }
}

private func object(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

private func run(_ scenario: Scenario, output: URL) throws -> [String: Any] {
    let observation = Observation()
    let dialog = TradeQuantityPrompt(title: scenario.title, range: 1...scenario.upper,
                                     initial: scenario.initial, unitLabel: scenario.unit,
                                     onConfirm: { _ in }, onCancel: {})
        .environment(\.novaUIScale, scenario.scale)
        .preferredColorScheme(.dark)
        .coordinateSpace(name: "dialog")
        .onPreferenceChange(ControlBoundsKey.self) { observation.controls = $0 }
    let host = NSHostingView(rootView: dialog)
    host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    settle(host)
    let fitting = host.fittingSize
    // Mimic the initial sheet's intrinsic sizing: the content must fit the
    // actual hosting bounds, not merely report a plausible preferred size.
    host.frame = CGRect(origin: .zero, size: CGSize(width: max(1, fitting.width),
                                                    height: max(1, fitting.height)))
    settle(host)
    let bounds = CGRect(origin: .zero, size: host.frame.size)
    let controls = observation.controls.map { control -> [String: Any] in
        let tolerance = bounds.insetBy(dx: -0.5, dy: -0.5)
        return ["kind": control.kind, "frame": object(control.frame),
                "insideHostingBounds": tolerance.contains(control.frame)]
    }
    let footer = observation.controls.filter { $0.kind == "footer" }
    let footerFits = footer.count == 2 && footer.allSatisfy {
        bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame)
            && $0.frame.width > 0 && $0.frame.height > 0
    }
    let imageURL = output.appendingPathComponent(scenario.name + ".png")
    var rendered = false
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) {
        host.cacheDisplay(in: bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: imageURL)
            rendered = true
        }
    }
    return ["scenario": scenario.name, "title": scenario.title,
            "upperBound": scenario.upper, "initialQuantity": scenario.initial,
            "unit": scenario.unit, "uiScale": scenario.scale,
            "fittingSize": ["width": fitting.width, "height": fitting.height],
            "hostingBounds": object(bounds), "controls": controls,
            "footerFits": footerFits, "snapshot": rendered ? imageURL.path : NSNull()]
}

@main
private enum TradeDialogHarness {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fatalError("Usage: trade-dialog-harness OUTPUT_DIRECTORY [FONT_FILE ...]")
        }
        // No app activation, window, save, preferences, data import or cloud
        // integration. NSHostingView is measured/rendered entirely offscreen.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Register the checkout's bundled fallback fonts for this process only,
        // so snapshots use the same typography without touching system fonts.
        var fonts: [[String: Any]] = []
        for file in CommandLine.arguments.dropFirst(2) {
            let url = URL(fileURLWithPath: file)
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            fonts.append(["file": file, "registered": registered,
                          "error": error.map { String(describing: $0.takeRetainedValue()) } ?? NSNull()])
        }
        NovaFontAvailability.reset()
        var scenarios: [Scenario] = []
        for scale: CGFloat in [1, 1.4] {
            let suffix = scale == 1 ? "normal" : "large"
            scenarios.append(Scenario(name: "buy-\(suffix)", title: "How many Food?",
                                      upper: 100, initial: 10, unit: "tons", scale: scale))
            scenarios.append(Scenario(name: "sell-\(suffix)", title: "How many Luxury Goods?",
                                      upper: 1_000_000, initial: 999_999, unit: "tons", scale: scale))
            scenarios.append(Scenario(name: "outfitter-\(suffix)",
                                      title: "How many heavily reinforced thermal shielding reinforcement systems?",
                                      upper: 1_000_000, initial: 1, unit: "items", scale: scale))
        }
        let results = try scenarios.map { try run($0, output: output) }
        let report: [String: Any] = ["mode": "offscreen NSHostingView; activation prohibited",
                                     "processFonts": fonts,
                                     "bodyFontFamily": NovaFontRole.body.family,
                                     "scenarios": results]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("layout.json"))
        print(String(decoding: json, as: UTF8.self))
    }
}
