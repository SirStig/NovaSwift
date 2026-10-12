#if os(macOS)
import SwiftUI
import CoreGraphics
import NovaSwiftKit
import NovaSwiftEngine

/// Stellar graphics, keyed by the spöb `type` value (spïn id = 1000 + type): frame 0 for
/// still drawing plus EVERY frame for animated stellars (`StellarAnimationClock` picks one),
/// decoded off-main from a snapshot of the effective collection; nothing is decoded while
/// drawing. One `NovaGame` is shared by every sprite decode of a revision (it is rebuilt only
/// by `invalidate()`). With HD on, the HD frames from `EditorHD` replace the classic ones once
/// the HD layer for the collection is ready (a second, later publish; classic shows meanwhile).
@MainActor
final class StellarSpriteCache: ObservableObject {
    struct Entry {
        /// Frame 0 (HD when available).
        let image: CGImage
        /// The classic logical size in points; HD images are drawn into this rect.
        let size: CGSize
        /// All frames (just `[image]` for a still sprite).
        var frames: [CGImage]
        var isHD = false
        var isAnimatable: Bool { frames.count > 1 }
    }

    private var entries: [Int: Entry] = [:]
    private var missing: Set<Int> = []
    private var loading: Set<Int> = []
    private var generation = 0
    private var shared = SharedGame()
    @Published private(set) var version = 0

    private weak var app: AppModel?
    private var hdBase: ResourceCollection?
    private var ownsHD = false

    /// Types of resources whose change invalidates sprites (incl. the HD attachments).
    static let relevant: Set<NovaSwiftKit.FourCharCode> = [
        NovaType.spin, NovaType.rleD, NovaType.pict, NovaType.rle8,
        GraphicsEnhancementType.descriptor, GraphicsEnhancementType.blob,
    ]

    /// Enable HD thumbnails (the user's setting decides at decode time).
    func bindHD(app: AppModel, base: ResourceCollection?) {
        let first = self.app == nil
        self.app = app
        hdBase = base
        // Sprites decoded before HD was bound would stay classic: decode them again.
        if first, !entries.isEmpty || !loading.isEmpty { invalidate() }
    }

    /// Release the HD layer hold (call from `onDisappear`).
    func teardown() {
        guard ownsHD else { return }
        ownsHD = false
        EditorHD.shared.release(self, app: app)
    }

    func invalidate() {
        generation += 1
        shared = SharedGame()
        entries.removeAll(); missing.removeAll(); loading.removeAll()
        version += 1
    }

    /// Already-decoded entry; never starts a load (safe to call from layout code).
    func peek(type: Int) -> Entry? { entries[type] }

    /// Cached sprite, or nil (a load is started; `version` bumps when it lands).
    func entry(type: Int, collection: @autoclosure () -> ResourceCollection) -> Entry? {
        if let e = entries[type] { return e }
        if type < 0 || missing.contains(type) || loading.contains(type) { return nil }
        loading.insert(type)
        let snapshot = collection()
        let gen = generation
        let box = shared
        var hd: EditorHD.Inputs?
        if let app, app.settings.hdGraphics {
            hd = EditorHD.inputs(app: app, base: hdBase)
            if !ownsHD { ownsHD = true; EditorHD.shared.acquire(self) }
        }
        let hdInputs = hd
        Task.detached(priority: .userInitiated) { [weak self] in
            let game = box.game(for: snapshot)
            guard let sheet = game.spinSheet(1000 + type), let first = sheet.frameCGImage(0) else {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.loading.remove(type); self.missing.insert(type); self.version += 1
                }
                return
            }
            // Cap runaway sheets: the layout canvas never needs more than this to animate.
            let count = min(sheet.frameCount, 64)
            var frames: [CGImage] = [first]
            if count > 1 { for i in 1..<count { if let f = sheet.frameCGImage(i) { frames.append(f) } } }
            let size = CGSize(width: sheet.frameWidth, height: sheet.frameHeight)
            let classic = Entry(image: first, size: size, frames: frames)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.loading.remove(type)
                self.entries[type] = classic
                self.version += 1
            }
            // HD upgrade: install/prepare the HD layer for this collection (shared with the
            // preview — a no-op when it is already current), then swap in the HD frames.
            guard let hdInputs, hdInputs.settings.hdGraphics else { return }
            EditorHD.shared.ensure(collection: snapshot, game: game, inputs: hdInputs)
            guard HDGraphics.shared.isActive else { return }
            var hdFrames: [CGImage] = []
            for i in 0..<count {
                guard let f = HDGraphics.shared.frameImage(for: sheet, frame: i) else { return }
                hdFrames.append(f)
            }
            guard let hdFirst = hdFrames.first else { return }
            let upgraded = Entry(image: hdFirst, size: size, frames: hdFrames, isHD: true)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen, self.entries[type] != nil else { return }
                self.entries[type] = upgraded
                self.version += 1
            }
        }
        return nil
    }
}

/// One `NovaGame` per cache revision, shared by every detached sprite decode.
private final class SharedGame: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: NovaGame?
    func game(for collection: ResourceCollection) -> NovaGame {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let g = NovaGame(collection)
        cached = g
        return g
    }
}

// MARK: - Stellar frame animation

/// The animation fields of one spöb (`AnimDelay`, `FirstFrameBias`, `Flags2`, `CustPicID`) —
/// nil for a still stellar, and for one that only animates while destroyed (an intact stellar
/// rests on frame 0, as in the game).
struct StellarAnimParams: Equatable, Sendable {
    var delay: Int
    var bias: Int
    var flags2: UInt32
    var custPic: Int

    init?(_ r: Resource) {
        let s = SpobRes(r)
        guard s.isAnimated, !s.animatesOnlyWhenDestroyed else { return nil }
        delay = s.animationDelay; bias = s.frame0Bias; flags2 = s.flags2; custPic = s.landingPictID
    }
}

/// Steps one `StellarAnimator` (the engine's port of the original's frame logic, the same type
/// `GameScene` animates stellars with) per animated stellar, in 30 Hz ticks of wall-clock
/// time. Call `advance(to:)` once per timeline date, then `frame(...)` for each stellar that is
/// actually on screen — off-screen stellars don't step.
final class StellarAnimationClock {
    private struct Slot {
        var params: StellarAnimParams
        var frameCount: Int
        var animator: StellarAnimator
    }
    private var slots: [Int: Slot] = [:]
    private var last: Date?
    private var ticks = 0.0

    func advance(to date: Date) {
        if let last { ticks = min(max(0, date.timeIntervalSince(last)), 0.5) * 30 } else { ticks = 0 }
        last = date
    }

    func reset() { slots.removeAll(); last = nil; ticks = 0 }

    /// The frame of spöb `id` now (0 for a single-frame sheet).
    func frame(spob id: Int, params: StellarAnimParams, frameCount: Int) -> Int {
        guard frameCount > 1 else { return 0 }
        var slot: Slot
        if let existing = slots[id], existing.params == params, existing.frameCount == frameCount {
            slot = existing
        } else {
            slot = Slot(params: params, frameCount: frameCount,
                        animator: StellarAnimator(frameCount: frameCount, delay: max(0, params.delay),
                                                  bias: params.bias, flags2: params.flags2, custPic: params.custPic))
        }
        let f = slot.animator.step(ticks: ticks, engaged: false) { Int.random(in: 0..<max(1, $0)) }
        slots[id] = slot
        return min(max(0, f), frameCount - 1)
    }
}

/// A searchable pick-list in a popover (for the 1.5k systems / hundreds of stellars).
/// The item list is gathered once when the popover opens and pre-lowercased, so typing
/// only filters a cached array.
struct MapSearchPicker<Label: View>: View {
    let items: () -> [(id: Int, name: String)]
    let onPick: (Int) -> Void
    @ViewBuilder var label: Label
    @State private var shown = false
    @State private var query = ""
    @State private var cache: [Row] = []

    private struct Row { let id: Int; let name: String; let lower: String }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(cache.prefix(80)) }
        return Array(cache.lazy.filter { $0.lower.contains(q) || String($0.id) == q }.prefix(80))
    }

    var body: some View {
        Button {
            query = ""
            cache = items().map { Row(id: $0.id, name: $0.name, lower: $0.name.lowercased()) }
            shown = true
        } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                let rows = self.rows
                VStack(spacing: 6) {
                    TextField("Search\u{2026}", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.id) { r in
                                Button { shown = false; onPick(r.id) } label: {
                                    HStack {
                                        Text(r.name).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        Text("#\(r.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 3).padding(.horizontal, 6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if rows.isEmpty { Text("No matches").font(.caption).foregroundStyle(.secondary).padding(8) }
                        }
                    }
                    .frame(height: 260)
                }
                .padding(10).frame(width: 280)
            }
    }
}
#endif
