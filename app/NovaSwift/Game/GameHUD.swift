import SwiftUI

/// Live HUD state, updated by `GameScene` (throttled) and read by `GameHUDView`.
@MainActor
final class GameHUDModel: ObservableObject {
    @Published var shipName = ""
    @Published var speed = 0
    @Published var maxSpeed = 1
    @Published var shield = 1.0     // 0…1
    @Published var armor = 1.0      // 0…1
    @Published var fuel = 1.0       // 0…1
    @Published var jumps = 0        // whole hyperjumps of fuel remaining
    /// The ship's total fuel capacity in raw units (EV Nova charges 100 per
    /// hyperjump). Lets the fuel gauge segment itself into whole-jump units —
    /// full jumps painted in `ïntf.fuelFull`, the leftover partial jump in
    /// `ïntf.fuelPartial` — exactly as the original status bar draws it. 0 when
    /// no ship state is pushed yet, which collapses the gauge to a single fill.
    @Published var maxFuel = 0.0
    /// Ion charge as a fraction of the ship's `ionizeMax` (0…1). 0 for a ship
    /// that can't be ionized or is fully discharged — the HUD hides the bar then.
    @Published var ionization = 0.0
    /// True once ion charge reaches the threshold that impairs the ship (the
    /// engine's `Ship.isIonized`) — the HUD flags it so the player knows why
    /// their controls/weapons are sluggish.
    @Published var ionized = false
    @Published var thrusting = false
    @Published var afterburning = false
    @Published var headingDegrees = 0.0
    @Published var controllerConnected = false
    @Published var systemName = ""
    // Loadout readout.
    @Published var weaponName = ""      // active primary weapon (empty = unarmed)
    @Published var weaponAmmo = -1      // rounds left; -1 = unlimited / n/a
    @Published var cargoUsed = 0
    @Published var cargoCapacity = 0
    /// The player's credit balance, shown in the status bar's bottom readout
    /// (the HUD abbreviates it, e.g. "6.08M"). Pushed from the container at
    /// build/departure and whenever an in-flight event changes it (plunder,
    /// hull repairs).
    @Published var credits = 0
    /// Cargo hold contents by commodity, display-ready (name already resolved
    /// — e.g. via `NovaGame.commodityName` — matching how `weaponName` etc.
    /// arrive pre-resolved rather than as raw ids). Mirrors the per-commodity
    /// breakdown `World`'s ship `cargo: [Int: Int]` dictionary already tracks
    /// for the Trade screen; zero-ton entries are omitted. Empty when no
    /// per-commodity source is wired up yet — `cargoUsed`/`cargoCapacity`
    /// above remain the source of truth for the aggregate tonnage.
    @Published var cargoByCommodity: [(name: String, tons: Int)] = []
    /// Non-empty while a landable stellar object is in reach (shown as a prompt).
    @Published var landPrompt = ""
    /// Structured land-prompt state (drives the platform-specific prompt: a
    /// keyboard hint on macOS, a tappable Land pill on iOS). `landName` empty =
    /// no landable stellar in reach.
    @Published var landName = ""
    @Published var landReady = false   // in range AND slow enough to set down now
    /// The rolling bottom-left message log — the calendar date on each jump/land,
    /// hail replies, mission notices, etc. Each entry fades out on its own timer,
    /// exactly like EV Nova's on-screen message strip.
    @Published var messages: [HUDMessage] = []

    /// Post a transient message to the bottom-left log. It appears immediately
    /// and fades away after a few seconds; the log keeps only the most recent
    /// few so it never grows without bound.
    func post(_ text: String) {
        guard !text.isEmpty else { return }
        let msg = HUDMessage(text: text)
        withAnimation(.easeOut(duration: 0.2)) { messages.append(msg) }
        if messages.count > 6 { messages.removeFirst(messages.count - 6) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeIn(duration: 0.6)) { self?.messages.removeAll { $0.id == msg.id } }
        }
    }
    /// The player's locked target, if any (empty name = no target locked).
    @Published var targetName = ""
    /// The locked target's `shïp` resource id, for rendering its red target-
    /// display silhouette (see `ShipSilhouetteView`). -1 / nil when the target
    /// isn't a ship (e.g. a selected planet) or nothing is locked.
    @Published var targetShipTypeID: Int?
    @Published var targetShield = 1.0   // 0…1
    @Published var targetArmor = 1.0    // 0…1
    @Published var targetHostile = false
    /// The target's government, e.g. "Trader" (`gövt.TargetCode`).
    @Published var targetGovtLabel = ""
    /// `shïp.Subtitle` (Nova Bible) — a short descriptor shown under the
    /// target's name on the target readout, e.g. a hull's class tagline.
    /// Empty = the target's ship type defines none.
    @Published var targetSubtitle = ""
    /// `shïp.Flags` 0x0100 (Bible: "Show % armor on target display instead of
    /// 'Shields Down'") — once `targetShield` hits 0, show `targetArmor`
    /// instead of literal "Shields Down" text.
    @Published var targetShowArmorWhenShieldsDown = false
    /// `shïp.Flags` 0x0200 (Bible: "Don't show armor or shield state on
    /// status display") — omit the shield/armor line entirely for this target.
    @Published var targetHidesShieldArmorLine = false
    /// The click-selected planet/station nav destination, if any — independent
    /// of the ship target above (empty name = none selected).
    @Published var navTargetName = ""
    @Published var navTargetLandable = false
    /// The plotted hyperspace course, if any — the real `ïntf.NavArea` "navigation
    /// display" (Nova Bible), distinct from `navTargetName` above (a nearby
    /// planet/station selection for landing, not a hyperspace destination).
    @Published var navCourseSystemName = ""
    @Published var navCourseJumps = 0
    /// Ship contacts in normalized [-1, 1] radar space (out-of-range ships are omitted).
    @Published var blips: [RadarContact] = []
    /// Stellar-object contacts (planets/stations) in normalized radar space.
    @Published var planetBlips: [RadarContact] = []
}

/// One transient entry in the bottom-left message log.
struct HUDMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// How a radar contact relates to the player, driving its dot color: red for a
/// hostile, yellow for a neutral that's neither friend nor foe, green for
/// something the player owns/is allied with, grey for anything disabled,
/// uninhabited, or otherwise non-functional (drifting hulks, dead stations).
enum RadarRelationship {
    case hostile, neutral, friendlyOrOwned, disabled

    var color: Color {
        switch self {
        case .hostile: return Color(red: 0.95, green: 0.3, blue: 0.25)      // red
        // Neutral contacts read grey on EV Nova's scope, not yellow — yellow
        // over-signalled every independent ship/world as "notable".
        case .neutral: return Color(white: 0.7)
        case .friendlyOrOwned: return Color(red: 0.4, green: 0.9, blue: 0.4) // green
        case .disabled: return Color(white: 0.4)
        }
    }
}

/// One contact (ship or stellar object) on the radar scope, in normalized
/// [-1, 1] space.
struct RadarContact {
    var x: CGFloat
    var y: CGFloat
    var relationship: RadarRelationship
}

/// The player marker at the centre of the radar: a slim needle arrow pointing
/// "up" in its rect, meant to be rotated to the ship's heading.
struct RadarPlayerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))                // nose
        p.addLine(to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.92))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.68)) // tail notch
        p.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.92))
        p.closeSubpath()
        return p
    }
}

/// The Nova Swift modern flight HUD (our own artwork — not EV Nova's `ïntf`):
/// a compact right-hand sidebar of stacked panels — system/credits, radar,
/// ship status, nav/course, target — echoing the original's right-side status
/// bar layout in a modern style.
struct GameHUDView: View {
    @ObservedObject var model: GameHUDModel
    var showRadar: Bool = true
    /// "Larger HUD" accessibility setting — scales the whole sidebar up.
    var largerHUD: Bool = false
    /// "High-contrast HUD" accessibility setting — darker panels, brighter edges.
    var highContrast: Bool = false

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let sidebarW: CGFloat = 196

    private var panel: Color { Color.black.opacity(highContrast ? 0.75 : 0.42) }
    private var edge: Color { .white.opacity(highContrast ? 0.4 : 0.12) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                systemPanel
                if showRadar { radarPanel }
                statusPanel
                navPanel
                targetPanel
            }
            .frame(width: sidebarW)
            // "Larger HUD" scales the whole stack up, anchored to the top-right
            // corner so it still hugs the edge.
            .scaleEffect(largerHUD ? 1.28 : 1.0, anchor: .topTrailing)
            .padding(.top, 12).padding(.trailing, 12)
        }
        .allowsHitTesting(false)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
    }

    /// A rounded panel wrapper shared by every sidebar block.
    private func box<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: sidebarW, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(edge))
    }

    /// Ship name, current system, credits and cargo — the "you & where you are"
    /// block missing from the old layout.
    private var systemPanel: some View {
        box {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.shipName.isEmpty ? "SHIP" : model.shipName.uppercased())
                    .font(.system(.footnote, design: .monospaced).weight(.bold))
                    .foregroundStyle(amber).lineLimit(1)
                if !model.systemName.isEmpty {
                    infoRow("location.fill", model.systemName)
                }
                infoRow("dollarsign.circle", creditString(model.credits))
                if model.cargoCapacity > 0 {
                    infoRow("shippingbox", "\(model.cargoUsed) / \(model.cargoCapacity) t")
                }
            }
        }
    }

    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var radarPanel: some View {
        box { radar.frame(maxWidth: .infinity) }
    }

    /// Shield / armor / fuel bars plus a compact flight line (speed, heading,
    /// weapon, thrust/burn).
    private var statusPanel: some View {
        box {
            VStack(alignment: .leading, spacing: 6) {
                bar("SHIELD", model.shield, Color.cyan)
                bar("ARMOR", model.armor, amber)
                bar(model.jumps > 0 ? "FUEL · \(model.jumps) JUMP\(model.jumps == 1 ? "" : "S")" : "FUEL",
                    model.fuel, Color.green)
                // Ion charge — only while there's a charge to show (most fights
                // never ionize the player, so an always-on bar would be clutter).
                if model.ionization > 0.001 {
                    bar(model.ionized ? "ION · IONIZED" : "ION",
                        model.ionization, Color(red: 0.6, green: 0.4, blue: 1.0))
                }
                HStack(spacing: 8) {
                    Label("\(model.speed)", systemImage: "gauge.with.dots.needle.67percent")
                    Text("\(Int(model.headingDegrees))°")
                    Spacer(minLength: 0)
                    if model.afterburning {
                        Image(systemName: "flame.circle.fill").foregroundStyle(.orange)
                    } else if model.thrusting {
                        Image(systemName: "flame.fill").foregroundStyle(amber)
                    }
                    if model.controllerConnected {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                if !model.weaponName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "scope").font(.system(size: 9))
                        Text(model.weaponAmmo >= 0 ? "\(model.weaponName) ×\(model.weaponAmmo)" : model.weaponName)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.cyan)
                }
            }
        }
    }

    /// The plotted hyperspace course or the selected-planet landing readout.
    @ViewBuilder
    private var navPanel: some View {
        if !model.navCourseSystemName.isEmpty {
            box {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("COURSE")
                    Text(model.navCourseSystemName.uppercased())
                        .font(.system(size: 11, design: .monospaced).weight(.semibold)).lineLimit(1)
                    Text("\(model.navCourseJumps) JUMP\(model.navCourseJumps == 1 ? "" : "S")")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        } else if !model.navTargetName.isEmpty {
            box {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("DESTINATION")
                    Text(model.navTargetName.uppercased())
                        .font(.system(size: 11, design: .monospaced).weight(.semibold)).lineLimit(1)
                    Text(model.navTargetLandable ? "Landable" : "No clearance")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The locked ship target (name / govt / shield / armor).
    @ViewBuilder
    private var targetPanel: some View {
        if !model.targetName.isEmpty {
            box {
                VStack(alignment: .leading, spacing: 5) {
                    sectionLabel("TARGET")
                    Text(model.targetName.uppercased())
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(model.targetHostile ? Color(red: 0.95, green: 0.35, blue: 0.3) : .white)
                        .lineLimit(1)
                    if !model.targetGovtLabel.isEmpty {
                        Text(model.targetGovtLabel)
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if !model.targetHidesShieldArmorLine {
                        bar("SHIELD", model.targetShield, Color.cyan)
                        bar("ARMOR", model.targetArmor, amber)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 8, design: .monospaced).weight(.bold))
            .foregroundStyle(.secondary).tracking(1)
    }

    private func bar(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * max(0, min(1, value))))
                }
            }
            .frame(height: 7)
        }
    }

    /// Abbreviated credit balance, e.g. "6.08M", "12.4k", "840".
    private func creditString(_ c: Int) -> String {
        if c >= 1_000_000 { return String(format: "%.2fM cr", Double(c) / 1_000_000) }
        if c >= 10_000 { return String(format: "%.1fk cr", Double(c) / 1000) }
        return "\(c) cr"
    }

    private var radar: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.3))
            Circle().strokeBorder(amber.opacity(0.5), lineWidth: 1)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).scaleEffect(0.6)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 5
                for b in model.planetBlips {
                    let rect = CGRect(x: c.x + b.x * r - 2.5, y: c.y + b.y * r - 2.5, width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: rect), with: .color(b.relationship.color))
                }
                for b in model.blips {
                    let rect = CGRect(x: c.x + b.x * r - 1.5, y: c.y + b.y * r - 1.5, width: 3, height: 3)
                    ctx.fill(Path(ellipseIn: rect), with: .color(b.relationship.color))
                }
            }
            ZStack {
                RadarPlayerArrow().fill(.cyan)
                RadarPlayerArrow().stroke(.white.opacity(0.8), lineWidth: 0.5)
            }
            .frame(width: 9, height: 12)
            .rotationEffect(.degrees(model.headingDegrees))
        }
        .frame(width: 120, height: 120)
    }
}
