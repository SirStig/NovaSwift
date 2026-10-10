import SwiftUI
import SpriteKit
import NovaSwiftKit

/// HD / 3D tester: every enhancement the loaded graphics packs supply, its
/// state and memory, and a turntable showing the classic sprite next to its
/// HD replacement — scrub or spin the heading, bank, fire the engines, light
/// the running lights, zoom in — plus "spawn in this system" to see it in
/// flight. Opened from the dev console's HD / 3D section (or `hd view`).
struct HDViewerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var debug: DebugController
    @Environment(\.dismiss) private var dismiss

    @State private var status = HDGraphics.shared.status()
    @State private var selected: Int?
    @StateObject private var stage = HDViewerStage()

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                entryList.frame(width: 300)
                Divider()
                preview
            }
            .navigationTitle("HD / 3D Viewer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { refresh(); load() } }
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            refresh()
            if selected == nil { selected = status.entries.first?.spriteID }
            load()
        }
        .onChange(of: selected) { _, _ in load() }
    }

    private func refresh() { status = HDGraphics.shared.status() }

    private func load() {
        guard let id = selected, let game = model.data.game else { return }
        stage.load(spriteID: id, game: game)
    }

    // MARK: List

    private var entryList: some View {
        List(selection: $selected) {
            Section {
                LabeledContent("HD graphics", value: status.enabled ? "on" : "off")
                LabeledContent("Detail", value: "\(Int(status.maxScale))×")
                LabeledContent("Texture memory", value: String(format: "%.1f MB", Double(status.totalBytes) / 1_048_576))
                if !status.enabled {
                    Text("HD is off, so the HD side stays empty until you turn it on (dev tools ▸ HD / 3D).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Enhancements (\(status.entries.count))") {
                ForEach(status.entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("sprite \(e.spriteID)").font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(e.state.rawValue)
                                .font(.caption.bold())
                                .foregroundStyle(e.state == .ready ? .green : e.state == .failed ? .red : .secondary)
                        }
                        Text("\(e.kind.rawValue) · \(e.origin)"
                             + (e.pixelScale.map { String(format: " · %.0f×", $0) } ?? "")
                             + (e.bytes > 0 ? String(format: " · %.1f MB", Double(e.bytes) / 1_048_576) : "")
                             + (e.layers.isEmpty ? "" : " · " + e.layers.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(e.spriteID)
                }
            }
            if !status.problems.isEmpty {
                Section("Problems") {
                    ForEach(status.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 10) {
            SpriteView(scene: stage.scene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            controls.padding(.horizontal).padding(.bottom, 10)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stage.caption).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if stage.framesPerSet > 1 {
                HStack {
                    Toggle("Spin", isOn: $stage.spinning).toggleStyle(.switch).fixedSize()
                    Slider(value: Binding(get: { Double(stage.heading) },
                                          set: { stage.spinning = false; stage.heading = Int($0) }),
                           in: 0...Double(max(1, stage.framesPerSet - 1)), step: 1)
                    Text("heading \(stage.heading)/\(stage.framesPerSet)").font(.caption.monospacedDigit()).frame(width: 110)
                }
                Picker("Bank", selection: $stage.set) {
                    ForEach(0..<max(1, stage.setCount), id: \.self) { i in
                        Text(i == 0 ? "Level" : i == 1 ? "Bank left" : i == 2 ? "Bank right" : "Set \(i)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(stage.setCount < 2)
            }
            HStack(spacing: 14) {
                Toggle("Thrust", isOn: $stage.thrust).disabled(!stage.hasEngine)
                Toggle("Lights", isOn: $stage.lights).disabled(!stage.hasLights)
                Toggle("Classic side", isOn: $stage.showClassic)
                HStack {
                    Text("Zoom")
                    Slider(value: $stage.zoom, in: 1...8).frame(width: 140)
                    Text(String(format: "%.1f×", stage.zoom)).font(.caption.monospacedDigit()).frame(width: 36)
                }
            }
            if !stage.shipIDs.isEmpty {
                HStack(spacing: 8) {
                    Text("Spawn in this system:").font(.caption)
                    ForEach(stage.shipIDs.prefix(4), id: \.self) { id in
                        Menu("ship \(id)") {
                            Button("Neutral") { _ = debug.scene?.debugSpawnShip(hull: id, as: .neutral) }
                            Button("Escort") { _ = debug.scene?.debugSpawnShip(hull: id, as: .escort) }
                            Button("Hostile") { _ = debug.scene?.debugSpawnShip(hull: id, as: .hostile) }
                        }
                        .fixedSize()
                    }
                    if debug.scene == nil { Text("(fly into a system first)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// The viewer's turntable: classic frame on the left, HD on the right, both
/// with the hull's effect layers stacked the way the game stacks them.
@MainActor
final class HDViewerStage: ObservableObject {
    let scene: SKScene = {
        let s = SKScene(size: CGSize(width: 800, height: 420))
        s.scaleMode = .resizeFill
        s.backgroundColor = .black
        s.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return s
    }()

    @Published var heading = 0 { didSet { apply() } }
    @Published var set = 0 { didSet { apply() } }
    @Published var thrust = false { didSet { apply() } }
    @Published var lights = true { didSet { apply() } }
    @Published var showClassic = true { didSet { apply() } }
    @Published var zoom = 3.0 { didSet { apply() } }
    @Published var spinning = true { didSet { updateSpin() } }
    @Published private(set) var framesPerSet = 1
    @Published private(set) var setCount = 1
    @Published private(set) var hasEngine = false
    @Published private(set) var hasLights = false
    @Published private(set) var caption = ""
    @Published private(set) var shipIDs: [Int] = []

    private struct Side {
        var base: [SKTexture] = []
        var engine: [SKTexture] = []
        var lights: [SKTexture] = []
        var weapons: [SKTexture] = []
    }
    private var classic = Side(), hd = Side()
    private var nodes: [String: SKSpriteNode] = [:]
    private var labels: [SKLabelNode] = []
    private var timer: Timer?

    func load(spriteID: Int, game: NovaGame) {
        guard let sheet = game.spriteSheet(spriteID: spriteID, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) else {
            caption = "sprite \(spriteID): no classic sheet (PICT sprites load on first sight in flight)"
            return
        }
        // Frame layout from a hull that uses this sprite, if any.
        let users = game.ships().filter { game.shan($0.id)?.baseSpriteID == spriteID }.map(\.id)
        shipIDs = users
        if let shan = users.first.flatMap({ game.shan($0) }) {
            framesPerSet = max(1, min(shan.framesPerSet, sheet.frameCount))
            setCount = max(1, sheet.frameCount / framesPerSet)
        } else {
            framesPerSet = sheet.frameCount; setCount = 1
        }
        func classicFrames(_ s: SpriteSheet?) -> [SKTexture] {
            guard let s else { return [] }
            return s.frameCGImages(0..<s.frameCount).map { let t = SKTexture(cgImage: $0.image); t.filteringMode = .nearest; return t }
        }
        func overlaySheet(_ id: Int?) -> SpriteSheet? {
            id.flatMap { game.spriteSheet(spriteID: $0, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) }
        }
        let ids = HDGraphics.shared.overlayIDs(forBase: spriteID)
        let engine = overlaySheet(ids[.engine]), light = overlaySheet(ids[.lights]), weap = overlaySheet(ids[.weapons])
        classic = Side(base: classicFrames(sheet), engine: classicFrames(engine),
                       lights: classicFrames(light), weapons: classicFrames(weap))
        hd = Side(base: HDGraphics.shared.frames(for: sheet) ?? [],
                  engine: engine.flatMap { HDGraphics.shared.frames(for: $0) } ?? [],
                  lights: light.flatMap { HDGraphics.shared.frames(for: $0) } ?? [],
                  weapons: weap.flatMap { HDGraphics.shared.frames(for: $0) } ?? [])
        hasEngine = !classic.engine.isEmpty || !hd.engine.isEmpty
        hasLights = !classic.lights.isEmpty || !hd.lights.isEmpty
        heading = 0; set = 0
        caption = "sprite \(spriteID) · \(sheet.frameWidth)×\(sheet.frameHeight) · \(sheet.frameCount) frames"
            + (users.isEmpty ? "" : " · hull of ship \(users.map(String.init).joined(separator: ", "))")
            + (hd.base.isEmpty ? " · HD not ready or off" : "")
        buildNodes()
        updateSpin()
        apply()
    }

    private func buildNodes() {
        scene.removeAllChildren()
        nodes = [:]; labels = []
        for side in ["classic", "hd"] {
            for layer in ["base", "engine", "lights", "weapons"] {
                let n = SKSpriteNode()
                n.blendMode = layer == "base" ? .alpha : .add
                n.zPosition = layer == "base" ? 0 : 1
                scene.addChild(n)
                nodes["\(side).\(layer)"] = n
            }
            let label = SKLabelNode(fontNamed: "Menlo-Bold")
            label.fontSize = 12
            label.fontColor = side == "hd" ? SKColor(red: 0.3, green: 1, blue: 0.55, alpha: 1) : SKColor(white: 0.75, alpha: 1)
            label.text = side == "hd" ? "HD / 3D" : "Classic"
            scene.addChild(label)
            labels.append(label)
        }
    }

    private func updateSpin() {
        timer?.invalidate(); timer = nil
        guard spinning, framesPerSet > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.heading = (self.heading + 1) % max(1, self.framesPerSet)
            }
        }
    }

    private func apply() {
        let frame = set * framesPerSet + heading
        let spacing = showClassic ? scene.size.width / 4 : 0
        for (side, data, x) in [("classic", classic, -spacing), ("hd", hd, spacing)] {
            let visible = side == "hd" || showClassic
            for (layer, frames, on) in [("base", data.base, true), ("engine", data.engine, thrust),
                                        ("lights", data.lights, lights), ("weapons", data.weapons, false)] {
                guard let n = nodes["\(side).\(layer)"] else { continue }
                guard visible, on, !frames.isEmpty else { n.isHidden = true; continue }
                let t = frames[OriginalRendering.wrappedFrame(frame, count: frames.count)]
                n.texture = t
                n.size = t.size()
                n.setScale(zoom)
                n.position = CGPoint(x: x, y: 10)
                n.isHidden = false
            }
        }
        for (i, label) in labels.enumerated() {
            label.isHidden = i == 0 && !showClassic
            label.position = CGPoint(x: i == 0 ? -spacing : spacing, y: -scene.size.height / 2 + 14)
        }
    }

    deinit { timer?.invalidate() }
}
