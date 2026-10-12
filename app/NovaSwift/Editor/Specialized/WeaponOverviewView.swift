#if os(macOS)
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// wëap overview: shot art, plain-language stats, DPS, carriers, and a firing-range
/// preview (lightweight canvas) plus a real "Test on range" run.
struct WeaponOverviewView: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey

    @State private var raw: WeapRes?
    @State private var line: ShipStatSheet.WeaponLine?
    @State private var shot: EditorDecodedSprite?
    @State private var carrierOutfit: Int?
    @State private var rangeShip = 128
    @State private var shipChoices: [PluginDocument.BrowserEntry] = []
    @State private var geometry: RangeGeometry?
    /// First result has landed (until then: skeleton, not "couldn't compute").
    @State private var loaded = false
    /// A newer result is being computed; the old numbers stay on screen.
    @State private var refreshing = false
    @StateObject private var loader = ShipLayersLoader()

    private struct TaskKey: Hashable { let key: ResourceKey; let revision: Int; let ship: Int }
    private struct Computed {
        let raw: WeapRes?; let line: ShipStatSheet.WeaponLine?; let carrier: Int?
        let shot: EditorDecodedSprite?; let geometry: RangeGeometry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let w = raw, let l = line {
                HStack(alignment: .top, spacing: 12) {
                    shotPreview(w, l).frame(width: 150, height: 150)
                    summary(w, l)
                }
                stats(w, l)
                ammoAndSub(w)
                carriers
                rangeSection(w, l)
            } else if !loaded {
                SkeletonForm(groups: 3)
            } else {
                EditorEmptyState(icon: "scope", title: "Couldn't compute this weapon", subtitle: "Use Form or Raw.")
            }
        }
        .overlay(alignment: .top) { EditorRefreshStrip(active: refreshing) }
        .task(id: TaskKey(key: key, revision: model.dataRevision, ship: rangeShip)) {
            // Everything heavy (stats, shot sprite decode, exit points) runs off-main; after
            // inline edits wait ~200 ms so typing coalesces, keeping the old numbers meanwhile.
            if loaded {
                refreshing = true
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            let ships = await env.cache.list(NovaType.ship, model).entries
            if Task.isCancelled { return }
            shipChoices = ships
            if !ships.contains(where: { $0.key.id == rangeShip }), let f = ships.first {
                rangeShip = f.key.id      // re-keys this task; the restarted run does the work
                return
            }
            let id = key.id, fromShip = rangeShip
            let r = await SpecCache.compute(model) { d -> Computed in
                let raw = d.game.weapon(id)
                let spec = d.galaxy.weaponSpec(id)
                var shot: EditorDecodedSprite?
                if let spin = raw?.graphicSpinID, let sheet = d.game.weaponSprite(spinID: spin) {
                    shot = EditorDecodedSprite(sheet)
                }
                func color(_ c: (r: Double, g: Double, b: Double)?, _ fallback: Color) -> Color {
                    c.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? fallback
                }
                let muzzle = d.galaxy.exitPoints(forShip: fromShip)?
                    .muzzleOffset(type: spec?.exitType ?? .gun, index: 0, angle: 0, nose: 20) ?? Vec2(0, 20)
                let geo = RangeGeometry(muzzle: muzzle, speed: spec?.projectileSpeed ?? 300,
                                        beamCore: color(spec?.beamColor, .white), beamGlow: color(spec?.coronaColor, .cyan))
                return Computed(raw: raw, line: ShipStatSheet.weaponLine(galaxy: d.galaxy, game: d.game, id: id, count: 1),
                                carrier: d.game.outfitInstalling(weapon: id), shot: shot, geometry: geo)
            }
            if Task.isCancelled { return }
            raw = r.raw; line = r.line; carrierOutfit = r.carrier; shot = r.shot; geometry = r.geometry
            loaded = true; refreshing = false
            await loader.load(model: model, id: fromShip)
        }
    }

    // MARK: Shot art

    @ViewBuilder
    private func shotPreview(_ w: WeapRes, _ l: ShipStatSheet.WeaponLine) -> some View {
        ZStack {
            CheckerboardBackground()
            if l.isBeam {
                let colors = (core: geometry?.beamCore ?? Color.white, glow: geometry?.beamGlow ?? Color.cyan)
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                    Canvas { ctx, size in
                        let pulse = 0.75 + 0.25 * sin(tl.date.timeIntervalSinceReferenceDate * 12)
                        drawBeam(ctx, from: CGPoint(x: size.width / 2, y: size.height - 14),
                                 to: CGPoint(x: size.width / 2, y: 14), weapon: w, scale: 1, pulse: pulse, colors: colors)
                    }
                }
            } else if let s = shot, s.sheet.frameCount > 0 {
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { tl in
                    let n = Int(tl.date.timeIntervalSinceReferenceDate * 12) % s.sheet.frameCount
                    if let cg = s.frame(n) {
                        Image(decorative: cg, scale: 1).interpolation(.none).resizable().scaledToFit().padding(12)
                    }
                }
            } else {
                Text(w.graphicSpinID == nil ? "No shot sprite" : "spïn missing").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
    }

    private func drawBeam(_ ctx: GraphicsContext, from: CGPoint, to: CGPoint, weapon w: WeapRes, scale: CGFloat,
                          pulse: Double, colors: (core: Color, glow: Color)) {
        let core = colors.core, glow = colors.glow
        let width = max(1.5, CGFloat(max(1, w.beamWidth)) * scale)
        var p = Path(); p.move(to: from); p.addLine(to: to)
        ctx.stroke(p, with: .color(glow.opacity(0.45 * pulse)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
        ctx.stroke(p, with: .color(core.opacity(pulse)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    // MARK: Summary & stats

    private func summary(_ w: WeapRes, _ l: ShipStatSheet.WeaponLine) -> some View {
        SpecSection(title: "Summary") {
            VStack(spacing: 4) {
                StatRow(label: "Guidance", value: l.guidance)
                StatRow(label: "DPS vs shields / armor", value: "\(SpecFormat.num(l.dpsShield)) / \(SpecFormat.num(l.dpsArmor))")
                StatRow(label: "Per shot", value: "\(SpecFormat.num(l.shieldDamage, 0)) / \(SpecFormat.num(l.armorDamage, 0))")
                StatRow(label: "Fire rate", value: l.reloadSeconds > 0 ? "\(SpecFormat.num(1 / l.reloadSeconds, 2))/s" : "every tick")
                StatRow(label: "Range", value: "\(Int(l.range)) px")
                if !l.isBeam {
                    StatRow(label: "Lifetime", value: "\(SpecFormat.num(Double(w.duration) / 30, 2)) s", note: "\(w.duration) frames")
                }
                if w.penetratesShields { StatRow(label: "Penetrates shields", value: "yes") }
            }
        }
    }

    private func stats(_ w: WeapRes, _ l: ShipStatSheet.WeaponLine) -> some View {
        SpecSection(title: "Stats", trailing: "edits are live") {
            VStack(spacing: 5) {
                InlineStat(model: model, key: key, field: "energyDamage", label: "Shield damage")
                InlineStat(model: model, key: key, field: "massDamage", label: "Armor damage")
                InlineStat(model: model, key: key, field: "reload", label: "Reload",
                           note: "\(SpecFormat.num(Double(w.reload) / 30, 2)) s")
                InlineStat(model: model, key: key, field: "duration", label: "Duration",
                           note: l.isBeam ? "pulse frames" : "\(SpecFormat.num(Double(w.duration) / 30, 2)) s")
                if l.isBeam {
                    InlineStat(model: model, key: key, field: "beamLength", label: "Beam length", note: "px = range")
                    InlineStat(model: model, key: key, field: "beamWidth", label: "Beam width")
                } else {
                    InlineStat(model: model, key: key, field: "speed", label: "Shot speed",
                               note: "\(SpecFormat.num(Double(w.speed) * 0.3)) px/s")
                    Text("Range = speed × duration = \(Int(l.range)) px").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                InlineStat(model: model, key: key, field: "inaccuracy", label: "Inaccuracy", note: "° spread")
                InlineStat(model: model, key: key, field: "blastRadius", label: "Blast radius", note: "px")
                InlineStat(model: model, key: key, field: "proxRadius", label: "Proximity radius", note: "px")
                InlineStat(model: model, key: key, field: "ionization", label: "Ionization")
                InlineStat(model: model, key: key, field: "impact", label: "Impact")
                if l.guidance.contains("Guided") || w.isGuided {
                    InlineStat(model: model, key: key, field: "guidedTurn", label: "Guided turn rate")
                }
                InlineStat(model: model, key: key, field: "burstCount", label: "Shots per burst")
                InlineStat(model: model, key: key, field: "burstReload", label: "Burst reload", note: "frames")
            }
        }
    }

    private func ammoAndSub(_ w: WeapRes) -> some View {
        SpecSection(title: "Ammo & sub-munitions") {
            VStack(alignment: .leading, spacing: 5) {
                if w.isFighterBay {
                    HStack { Text("Carried ship").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
                        ResourceChip(env: env, type: NovaType.ship, id: w.ammoType) }
                } else if w.ammoType >= 0 {
                    HStack { Text("Draws ammo from").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
                        ResourceChip(env: env, type: NovaType.weapon, id: 128 + w.ammoType) }
                    InlineStat(model: model, key: key, field: "maxAmmo", label: "Max ammo per launcher")
                } else if w.ammoType <= -1000 {
                    StatRow(label: "Burns fuel per shot", value: "\(SpecFormat.num(Double(abs(w.ammoType + 1000)) / 10, 1))")
                } else {
                    StatRow(label: "Ammo", value: "unlimited")
                }
                if w.hasSubmunition {
                    HStack { Text("Sub-munition ×\(w.subCount)").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
                        ResourceChip(env: env, type: NovaType.weapon, id: w.subID) }
                    StatRow(label: "Spread / recursion", value: "\(w.subTheta)° / \(w.subLimit)")
                }
                if let b = w.explosionBoomID {
                    HStack { Text("Hit explosion").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
                        ResourceChip(env: env, type: NovaType.boom, id: b) }
                }
            }
        }
    }

    private var carriers: some View {
        // Reference graph is built in the background once per document; a lookup afterwards.
        let refs = model.referencesReady ? model.document.references.usedBy(key) : []
        var seen = Set<ResourceKey>()
        let uniq = refs.map(\.source).filter { [NovaType.outfit, NovaType.ship, NovaType.weapon, NovaType.pers].contains($0.type) && seen.insert($0).inserted }
        return SpecSection(title: "Carried by", trailing: "outfits · ships · other weapons") {
            if !model.referencesReady {
                SkeletonBar(width: 200, height: 10)
            } else if uniq.isEmpty {
                Text("Nothing mounts this weapon.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ChipFlow {
                    ForEach(uniq.prefix(40), id: \.self) { k in ResourceChip(env: env, type: k.type, id: k.id) }
                }
            }
        }
    }

    // MARK: Firing range

    private func rangeSection(_ w: WeapRes, _ l: ShipStatSheet.WeaponLine) -> some View {
        SpecSection(title: "Firing range", trailing: "preview is schematic; the test run is the real thing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Fired from", selection: $rangeShip) {
                        ForEach(shipChoices.prefix(400), id: \.key) { e in
                            Text("#\(e.key.id) \(e.name)").tag(e.key.id)
                        }
                    }.frame(maxWidth: 300)
                    Spacer()
                    Button {
                        model.testRunRequest = EditorTestRunRequest(ship: rangeShip, giveWeapons: [key.id], rangeDummyHull: rangeShip)
                    } label: { Label("Test on range", systemImage: "scope") }
                        .buttonStyle(.borderedProminent).tint(novaAmber)
                        .disabled(carrierOutfit == nil)
                        .help(carrierOutfit == nil ? "No oütf installs this weapon, so it can't be mounted in a test run." :
                                "Fly this ship with the weapon mounted, god mode on, and a disabled dummy ahead")
                }
                RangeCanvas(weapon: w, line: l, shot: shot, geometry: geometry, layers: loader.layers)
                    .frame(height: 300)
            }
        }
    }
}

/// A schematic of the weapon being fired from a ship's real exit point at a dummy.
/// Per-(weapon, firing ship) numbers the schematic needs, computed off-main with the stats.
private struct RangeGeometry {
    var muzzle: Vec2
    var speed: Double
    var beamCore: Color
    var beamGlow: Color
}

private struct RangeCanvas: View {
    let weapon: WeapRes
    let line: ShipStatSheet.WeaponLine
    let shot: EditorDecodedSprite?
    let geometry: RangeGeometry?
    let layers: ShipLayerSet?

    var body: some View {
        let muzzle = geometry?.muzzle ?? Vec2(0, 20)
        let speed = max(30, line.isBeam ? 0 : (geometry?.speed ?? 300))
        let beamCore = geometry?.beamCore ?? Color.white
        let beamGlow = geometry?.beamGlow ?? Color.cyan
        let range = max(60, line.range)
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let origin = CGPoint(x: size.width / 2, y: size.height - 36)
                let pxPerWorld = max(0.05, (size.height - 80) / (range * 1.15))
                // range ring + target dummy at 85 % of range
                let targetY = origin.y - range * 0.85 * pxPerWorld
                var ring = Path(); ring.move(to: CGPoint(x: 0, y: origin.y - range * pxPerWorld))
                ring.addLine(to: CGPoint(x: size.width, y: origin.y - range * pxPerWorld))
                ctx.stroke(ring, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ctx.draw(Text("range \(Int(range)) px").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: size.width - 44, y: origin.y - range * pxPerWorld - 8))
                let target = CGPoint(x: origin.x, y: targetY)
                ctx.fill(Path(ellipseIn: CGRect(x: target.x - 10, y: target.y - 10, width: 20, height: 20)),
                         with: .color(.red.opacity(0.35)))
                ctx.stroke(Path(ellipseIn: CGRect(x: target.x - 10, y: target.y - 10, width: 20, height: 20)),
                           with: .color(.red.opacity(0.8)), lineWidth: 1.5)
                // ship
                if let layers {
                    ShipCompositor.draw(ctx, center: origin, zoom: max(0.5, min(2, pxPerWorld * 3)), layers: layers,
                                        heading: 0, altStep: 0, toggles: ShipLayerToggles())
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: origin.x - 6, y: origin.y - 6, width: 12, height: 12)), with: .color(.gray))
                }
                let muzzlePt = CGPoint(x: origin.x + muzzle.x * pxPerWorld * 3 / 3,
                                       y: origin.y - muzzle.y * pxPerWorld)
                if line.isBeam {
                    let pulse = 0.6 + 0.4 * sin(t * 14)
                    let end = CGPoint(x: muzzlePt.x, y: muzzlePt.y - range * pxPerWorld)
                    let beamEnd = CGPoint(x: end.x, y: max(end.y, targetY))
                    drawBeam(ctx, from: muzzlePt, to: beamEnd, pulse: pulse, scale: pxPerWorld, core: beamCore, glow: beamGlow)
                } else {
                    let reload = max(0.12, line.reloadSeconds)
                    let life = min(Double(weapon.duration) / 30.0, range / speed)
                    let live = Int(life / reload) + 2
                    let latest = Int(t / reload)
                    for i in 0..<live {
                        let n = latest - i
                        let age = t - Double(n) * reload
                        guard age >= 0, age <= life else { continue }
                        let spread = (Double((n &* 2654435761) % 1000) / 500 - 1) * Double(weapon.accuracy) * .pi / 180
                        let dist = speed * age
                        let x = muzzlePt.x + sin(spread) * dist * pxPerWorld
                        let y = muzzlePt.y - cos(spread) * dist * pxPerWorld
                        if let s = shot, s.sheet.frameCount > 0, let cg = s.frame(s.sheet.frameCount >= 36 ? Int((spread / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1) * Double(s.sheet.frameCount)) : Int(age * 12)) {
                            let wpx = CGFloat(s.sheet.frameWidth), hpx = CGFloat(s.sheet.frameHeight)
                            ctx.draw(Image(decorative: cg, scale: 1).interpolation(.none),
                                     in: CGRect(x: x - wpx / 2, y: y - hpx / 2, width: wpx, height: hpx))
                        } else {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(novaAmber))
                        }
                        if y <= targetY + 4, age > life * 0.5, weapon.blastRadius > 0 {
                            let r = CGFloat(weapon.blastRadius) * pxPerWorld
                            ctx.stroke(Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
                                       with: .color(.orange.opacity(0.4)), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .background { CheckerboardBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func drawBeam(_ ctx: GraphicsContext, from: CGPoint, to: CGPoint, pulse: Double, scale: CGFloat,
                          core: Color, glow: Color) {
        let width = max(1.5, CGFloat(max(1, weapon.beamWidth)) * scale)
        var p = Path(); p.move(to: from); p.addLine(to: to)
        ctx.stroke(p, with: .color(glow.opacity(0.45 * pulse)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
        ctx.stroke(p, with: .color(core.opacity(pulse)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
#endif
