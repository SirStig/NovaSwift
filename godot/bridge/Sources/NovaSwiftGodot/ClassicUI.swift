// Plain-Swift backend for the bridge's `// MARK: Classic UI` section in
// NovaWorld.swift (same split as Navigation.swift / Interactions.swift: `@Godot`
// registers only what is declared in the class body, so the callables there are
// one-line forwards into this file).
//
// This is the data side of godot/ui/classic/ — the authentic EV Nova UI kit:
// DLOG/DITL layouts, three-state button art, cölr palette, ïntf status-bar
// definition, STR# strings. Decoding and compositing are the shared NovaSwiftKit
// types the Apple app uses (DialogModels, ColorModels, InterfaceModels,
// ThreeStateButton, ClassicUIGeometry); this file only marshals them.

import Foundation
import NovaSwiftKit
import NovaSwiftStory

enum ClassicUIBackend {

    private static func hex(_ c: NovaColor) -> String {
        String(format: "#%02x%02x%02x", Int(c.r), Int(c.g), Int(c.b))
    }
    private static func rect(_ r: NovaRect) -> [Int] { [r.left, r.top, r.right, r.bottom] }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func kindName(_ k: DITLItemKind) -> String {
        switch k {
        case .userItem: return "user"
        case .button: return "button"
        case .checkbox: return "checkbox"
        case .resControl: return "control"
        case .statText: return "static"
        case .editText: return "edit"
        case .icon: return "icon"
        case .picture: return "picture"
        case .unknown: return "unknown"
        }
    }

    /// `{id, itemsID, hasDlog, title, w, h, designW, designH, focus, items:[{i, kind,
    /// l,t,r,b, text, res, enabled}]}`, or `{}` when neither a DLOG nor a DITL
    /// exists. w/h is the DLOG window size (the window the original centres);
    /// designW/H unions item overflow (DialogModels.designSize).
    static func dialog(_ game: NovaGame, _ id: Int) -> String {
        guard let d = game.dialog(id) else { return "{}" }
        let size = DITLLayout(id: id, dialog: d).windowSize(fallback: d.designSize)
        let items: [[String: Any]] = d.items.items.map { it in
            ["i": it.index, "kind": kindName(it.kind),
             "l": it.rect.left, "t": it.rect.top, "r": it.rect.right, "b": it.rect.bottom,
             "text": it.text, "res": it.resourceID ?? -1, "enabled": it.isEnabled]
        }
        return json(["id": id, "itemsID": d.items.id, "hasDlog": d.window != nil,
                     "title": d.window?.title ?? "", "w": size.width, "h": size.height,
                     "designW": d.designSize.width, "designH": d.designSize.height,
                     "focus": d.items.initialFocusIndex ?? -1, "items": items])
    }

    /// Per-rect `[up, down, left, right]` neighbour indices (-1 none) for a
    /// flat `[l,t,r,b, …]` array.
    static func focusNeighbours(_ flat: [Int32]) -> [Int32] {
        let rects = stride(from: 0, to: flat.count - 3, by: 4).map {
            ClassicUIGeometry.FocusRect(left: Int(flat[$0]), top: Int(flat[$0 + 1]),
                                        right: Int(flat[$0 + 2]), bottom: Int(flat[$0 + 3]))
        }
        return ClassicUIGeometry.focusNeighbours(rects).flatMap { $0.map(Int32.init) }
    }

    static func crispScale(frameW: Int, frameH: Int, viewW: Double, viewH: Double) -> Double {
        ClassicUIGeometry.crispScale(frameWidth: frameW, frameHeight: frameH,
                                     viewportWidth: viewW, viewportHeight: viewH)
    }

    // MARK: Buttons

    private static func image(_ game: NovaGame, _ id: Int) -> ThreeStateButtonRaster.Image? {
        guard let s = game.pictSheet(id) else { return nil }
        return .init(width: s.surfaceWidth, height: s.surfaceHeight, rgba: s.rgba)
    }

    private static func slice(_ game: NovaGame, _ state: ThreeStateButton.State, _ n: Int,
                              masked: Bool) -> ThreeStateButtonRaster.Image? {
        guard let art = image(game, ThreeStateButton.artID(state: state, slice: n)) else { return nil }
        guard masked else { return art }
        // a missing mask PICT leaves the slot opaque
        guard let mask = image(game, ThreeStateButton.maskID(state: state, slice: n)) else { return art }
        return ThreeStateButtonRaster.applyMask(mask, to: art)
    }

    /// The button PICT height (the middle slice), 25 in the stock data.
    static func buttonHeight(_ game: NovaGame) -> Int {
        image(game, ThreeStateButton.artID(state: .normal, slice: 1))?.height ?? 25
    }

    /// A finished `width`-wide button for `state` (0 normal, 1 pressed, 2 grey),
    /// RGBA8, `width * buttonHeight * 4` bytes. Labels are drawn by the frontend.
    static func buttonRGBA(_ game: NovaGame, width: Int, state: Int) -> [UInt8] {
        let st = ThreeStateButton.State(rawValue: max(0, min(2, state))) ?? .normal
        let h = buttonHeight(game)
        return ThreeStateButtonRaster.compose(
            width: width, height: h,
            left: slice(game, st, 0, masked: true),
            middle: slice(game, st, 1, masked: false),
            right: slice(game, st, 2, masked: true)).rgba
    }

    // MARK: Palette and status bar

    /// The `cölr` palette as JSON (`"#rrggbb"` colours). Pure-black decodes are
    /// reported as-is; the frontend applies the same "black means fallback"
    /// rule `NovaUITheme` does.
    static func colors(_ game: NovaGame) -> String {
        guard let c = game.colr() else { return "{}" }
        return json([
            "buttonUp": hex(c.buttonUp), "buttonDown": hex(c.buttonDown), "buttonGrey": hex(c.buttonGrey),
            "menuFont": c.menuFont, "menuFontSize": c.menuFontSize,
            "menuColor1": hex(c.menuColor1), "menuColor2": hex(c.menuColor2),
            "gridBright": hex(c.gridBright), "gridDim": hex(c.gridDim),
            "progressBar": rect(c.progressBar),
            "progBright": hex(c.progBright), "progDim": hex(c.progDim), "progOutline": hex(c.progOutline),
            "floatingMap": hex(c.floatingMap),
            "listText": hex(c.listText), "listBkgnd": hex(c.listBkgnd), "listHilite": hex(c.listHilite),
            "escortHilite": hex(c.escortHilite),
            "buttonFont": c.buttonFont, "buttonFontSize": c.buttonFontSz,
            "buttonPositions": c.buttonPositions.map { [Int($0.x), Int($0.y)] },
        ])
    }

    /// The `ïntf` id for a hull: its inherent govt's interface (Bible), else 128.
    static func interfaceID(_ game: NovaGame, shipType: Int) -> Int {
        guard let ship = game.ship(shipType) else { return 128 }
        let govtID = ship.inherentAttributesGovt >= 128 ? ship.inherentAttributesGovt : ship.inherentCombatGovt
        guard govtID >= 128, let iid = game.govt(govtID)?.interface, iid >= 128 else { return 128 }
        return game.interface(iid) != nil ? iid : 128
    }

    /// `{id, name, bgPict, bgW, bgH, bright, dim, radar, radarBright, radarDim, shield,
    /// shieldColor, armor, armorColor, fuel, fuelFull, fuelPartial, nav, weapon, target,
    /// cargo, font, fontSize, subtitleSize}`. Rects are `[l,t,r,b]` in the backdrop
    /// PICT's pixel space; the backdrop clamps to >= 128 and falls back to PICT 128
    /// (0x004cda50).
    static func interface(_ game: NovaGame, _ id: Int) -> String {
        guard let i = game.interface(id) ?? game.interface() else { return "{}" }
        var bg = max(128, i.backgroundPictID)
        if !game.hasPICT(bg) { bg = 128 }
        let sheet = game.pictSheet(bg)
        return json([
            "id": i.id, "name": i.name, "bgPict": bg,
            "bgW": sheet?.surfaceWidth ?? 0, "bgH": sheet?.surfaceHeight ?? 0,
            "bright": hex(i.brightText), "dim": hex(i.dimText),
            "radar": rect(i.radarArea), "radarBright": hex(i.brightRadar), "radarDim": hex(i.dimRadar),
            "shield": rect(i.shieldArea), "shieldColor": hex(i.shieldColor),
            "armor": rect(i.armorArea), "armorColor": hex(i.armorColor),
            "fuel": rect(i.fuelArea), "fuelFull": hex(i.fuelFull), "fuelPartial": hex(i.fuelPartial),
            "nav": rect(i.navArea), "weapon": rect(i.weaponArea),
            "target": rect(i.targetArea), "cargo": rect(i.cargoArea),
            "font": i.statusFont, "fontSize": i.statusFontSize, "subtitleSize": i.subtitleFontSize,
        ])
    }

    /// All strings of `STR#` `id` in order (entry n is index n-1), empty if absent.
    static func strings(_ game: NovaGame, _ id: Int) -> [String] {
        game.stringList(id)?.strings ?? []
    }

    // MARK: Main menu (AuthenticMainMenuView / MainMenuReadout)

    /// cölr #128's fallbacks, as the Apple view's (the base game's real values).
    private static let fallbackButtons: [(Int, Int)] = [(349, 400), (344, 464), (345, 528), (555, 401), (581, 464), (580, 528)]
    private static let fallbackSlides: [(Int, Int)] = [(343, 399), (337, 462), (337, 526)]
    private static let menuActions = ["new_pilot", "open_pilot", "quit", "enter_ship", "prefs", "about"]

    /// One frame of a `spïn` as its own RGBA tile. `mode` 0: the spïn's sheet (rlëD, or PICT +
    /// mask grid) -- the buttons and the rollover; 1: the spïn's sprite as an rlëD, else its PICT cut
    /// into `tilesDown` stacked tiles -- the logo and the shutter strips (kept RAW, as Apple does).
    static func spinTile(_ game: NovaGame, spin id: Int, frame: Int, mode: Int) -> (w: Int, h: Int, rgba: [UInt8])? {
        guard let spin = game.spin(id) else { return nil }
        if mode == 0 {
            guard let f = game.spinSheet(id)?.singleFrame(frame) else { return nil }
            return (f.frameWidth, f.frameHeight, f.rgba)
        }
        if let data = game.resources.resource(NovaType.rleD, spin.spriteID)?.data,
           let sheet = try? RLED.decode(data), let f = sheet.singleFrame(frame) {
            return (f.frameWidth, f.frameHeight, f.rgba)
        }
        guard let full = game.pictSheet(spin.spriteID) else { return nil }
        let w = spin.tileWidth > 0 ? min(spin.tileWidth, full.surfaceWidth) : full.surfaceWidth
        let h = spin.tileHeight > 0 ? min(spin.tileHeight, full.surfaceHeight) : full.surfaceHeight
        guard w > 0, h > 0 else { return nil }
        let count = spin.tilesDown > 0 ? spin.tilesDown : full.surfaceHeight / h
        guard frame >= 0, frame < count, (frame + 1) * h <= full.surfaceHeight else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = ((frame * h + row) * full.surfaceWidth) * 4
            out.replaceSubrange((row * w * 4)..<((row + 1) * w * 4), with: full.rgba[src..<(src + w * 4)])
        }
        return (w, h, out)
    }

    /// `[frameW, frameH, frameCount]` for a spïn in `mode` (see `spinTile`), or empty.
    static func spinInfo(_ game: NovaGame, spin id: Int, mode: Int) -> [Int32] {
        guard let spin = game.spin(id) else { return [] }
        if mode == 0 {
            guard let s = game.spinSheet(id) else { return [] }
            return [Int32(s.frameWidth), Int32(s.frameHeight), Int32(s.frameCount)]
        }
        if let data = game.resources.resource(NovaType.rleD, spin.spriteID)?.data,
           let s = try? RLED.decode(data) {
            return [Int32(s.frameWidth), Int32(s.frameHeight), Int32(s.frameCount)]
        }
        guard let full = game.pictSheet(spin.spriteID) else { return [] }
        let w = spin.tileWidth > 0 ? min(spin.tileWidth, full.surfaceWidth) : full.surfaceWidth
        let h = spin.tileHeight > 0 ? min(spin.tileHeight, full.surfaceHeight) : full.surfaceHeight
        guard h > 0 else { return [] }
        let count = spin.tilesDown > 0 ? spin.tilesDown : full.surfaceHeight / h
        return [Int32(w), Int32(h), Int32(count)]
    }

    /// The main menu's layout as JSON: `{bg, font, fontSize, color1, color2, buttons:[{action, x, y, w, h,
    /// spin}], logo:{x,y,spin}|null, slides:[{x,y,spin}], rollover:{x,y,w,h,spin}}` -- positions in the
    /// 1024x768 design space from cölr #128 (fallbacks = the base game's values).
    static func mainMenu(_ game: NovaGame) -> String {
        let colr = game.colr()
        let pos: [(Int, Int)] = colr.map { $0.buttonPositions.map { (Int($0.x), Int($0.y)) } } ?? fallbackButtons
        var buttons: [[String: Any]] = []
        for (i, spin) in [600, 601, 602, 603, 604, 605].enumerated() {
            guard let info = Optional(spinInfo(game, spin: spin, mode: 0)), info.count == 3, info[2] >= 2 else { continue }
            let p = pos[min(i, pos.count - 1)]
            buttons.append(["action": menuActions[i], "x": p.0, "y": p.1, "w": Int(info[0]), "h": Int(info[1]), "spin": spin])
        }
        let logoPoint = colr?.logo
        var logo: Any = NSNull()
        let li = spinInfo(game, spin: 606, mode: 1)
        if li.count == 3 {
            let lw = Int(li[0])
            let p = logoPoint.map { (Int($0.x), Int($0.y)) } ?? ((1024 - lw) / 2, 162)
            logo = ["x": p.0, "y": p.1, "spin": 606, "frame": Int(li[2]) - 1, "w": lw, "h": Int(li[1])]
        }
        let anchors: [(Int, Int)] = colr.map { [$0.slide1, $0.slide2, $0.slide3].map { (Int($0.x), Int($0.y)) } } ?? fallbackSlides
        var slides: [[String: Any]] = []
        for (i, spin) in [608, 609, 610].enumerated() {
            let si = spinInfo(game, spin: spin, mode: 1)
            guard si.count == 3, si[2] > 0 else { continue }
            slides.append(["x": anchors[i].0, "y": anchors[i].1, "spin": spin, "w": Int(si[0]), "h": Int(si[1]), "count": Int(si[2])])
        }
        let ri = spinInfo(game, spin: 607, mode: 0)
        let rp = colr?.rollover ?? CGPoint(x: 444, y: 465)
        let rollover: [String: Any] = ["x": Int(rp.x), "y": Int(rp.y), "spin": 607,
                                       "w": ri.count == 3 ? Int(ri[0]) : 136, "h": ri.count == 3 ? Int(ri[1]) : 98,
                                       "count": ri.count == 3 ? Int(ri[2]) : 0]
        return json(["bg": 8000, "font": colr?.menuFont ?? "", "fontSize": (colr?.menuFontSize ?? 0) > 0 ? colr!.menuFontSize : 9,
                     "color1": colr.map { hex($0.menuColor1) } ?? "#ff0000", "color2": colr.map { hex($0.menuColor2) } ?? "#800000",
                     "buttons": buttons, "logo": logo, "slides": slides, "rollover": rollover])
    }

    /// The targeting PICT of hull `id` (3000 + class, or the earlier class sharing its sprite), or -1.
    static func targetingPict(_ game: NovaGame, shipType id: Int) -> Int {
        if game.resources.resource(NovaType.pict, 3000 + id - 128) != nil { return 3000 + id - 128 }
        guard let base = game.shan(id)?.baseSpriteID,
              let donor = game.ships().map(\.id).sorted().first(where: { $0 < id && game.shan($0)?.baseSpriteID == base }),
              game.resources.resource(NovaType.pict, 3000 + donor - 128) != nil else { return -1 }
        return 3000 + donor - 128
    }

    /// The loaded-pilot readout as JSON `{lines:[{text, dx, baseline, label}], pict, centred}` for `save`
    /// (offsets from the menu centre, baselines too -- `MainMenuReadout`), or the single
    /// centred line for the no-pilot state when `save` is nil.
    static func menuReadout(_ game: NovaGame, save: PilotSave?) -> String {
        let s2002 = game.stringList(2002)
        func misc(_ i: Int) -> String { s2002?.string(at: i) ?? "" }
        guard let save else {
            return json(["lines": [], "pict": -1, "centred": misc(MainMenuReadout.noPilotString)])
        }
        let ship = game.ship(save.player.shipType)
        var lines: [[String: Any]] = []
        for line in MainMenuReadout.lines {
            var text = ""
            var label = false
            switch line.kind {
            case .label(let i): text = misc(i); label = true
            case .value(let f):
                switch f {
                case .pilotName: text = save.displayName
                case .shipName: text = save.snapshot.shipName
                case .shipClass: text = ship?.displayName ?? ""
                case .shipSubtitle: text = ship?.subtitle ?? ""
                case .combatRating: text = OriginalText(game: game).combatRating(save.player.combatRating)
                case .legalStatus: text = LegalStatus.label(inSystem: save.player.currentSystem, player: save.player, game: game)
                case .date:
                    let d = save.player.date
                    let ch = game.startingChar()
                    let s137 = game.stringList(137)
                    text = MainMenuReadout.date(day: d.day, month: d.month, year: d.year,
                                                prefix: ch?.datePrefix ?? "", suffix: ch?.dateSuffix ?? "",
                                                str137: { s137?.string(at: $0) })
                }
            }
            lines.append(["text": text, "dx": line.dx, "baseline": line.baselineDY, "label": label])
        }
        return json(["lines": lines, "pict": targetingPict(game, shipType: save.player.shipType), "centred": ""])
    }

    // MARK: Galaxy map frame (GalaxyMapView.classicSidePanel / originalStatusBar)

    /// The original map's text for system `id`: `{level, name, usable, government, legal, goods[], services[],
    /// ports[], hazards, date, known}`; the strings are the game's (STR# 2002), `known` = visited or charted.
    static func mapInfo(_ game: NovaGame, pilot: PlayerState, system id: Int) -> String {
        guard let sys = game.system(id) else { return "{}" }
        let text = OriginalText(game: game)
        let level = pilot.discoveryLevel(id)
        let usable = sys.spobs.compactMap { game.spob($0) }.filter {
            !$0.isUninhabited && $0.usableForTravel(destroyed: pilot.isStellarDestroyed($0.id))
        }
        let goodsSet = Set(usable.flatMap { game.commodityMarket(at: $0).map(\.commodity) })
        var goods = Commodity.allCases.filter { goodsSet.contains($0) }.map { game.commodityName($0) }
        if goods.isEmpty { goods = [text.misc(335)] }
        var services: [String] = []
        if usable.contains(where: { $0.hasCommodityExchange }) { services.append(text.misc(329)) }
        if usable.contains(where: { $0.hasOutfitter }) { services.append(text.misc(330)) }
        if usable.contains(where: { $0.hasShipyard }) { services.append(text.misc(331)) }
        let ports = sys.spobs.compactMap { game.spob($0) }
            .filter { !$0.isUninhabited && !pilot.isStellarDestroyed($0.id) }.map(\.displayName)
        var parts: [String] = []
        if sys.spobs.compactMap({ game.spob($0) }).contains(where: { $0.gravity != 0 }) { parts.append(text.misc(312)) }
        if sys.asteroidCount > 0 {
            parts.append("\(text.misc(sys.asteroidCount < 4 ? 313 : sys.asteroidCount < 7 ? 314 : 315)) \(text.misc(316))")
        }
        if sys.interference > 0 {
            parts.append("\(text.misc(sys.interference < 34 ? 317 : sys.interference < 67 ? 318 : 319)) \(text.misc(320))")
        }
        if sys.murk > 0 {
            parts.append("\(text.misc(sys.murk < 31 ? 321 : sys.murk < 61 ? 322 : 323)) \(text.misc(324))")
        }
        let joined = parts.isEmpty ? text.misc(335) : parts.joined(separator: ", ")
        let hazards = joined.prefix(1).uppercased() + joined.dropFirst()
        return json(["level": level, "name": sys.displayName, "usable": !usable.isEmpty,
                     "government": game.govt(sys.government)?.displayName ?? text.misc(333),
                     "legal": LegalStatus.label(inSystem: id, player: pilot, game: game),
                     "goods": goods, "services": services, "ports": ports, "hazards": hazards,
                     "date": text.date(for: pilot),
                     "labels": ["unknown": text.misc(310), "none": text.misc(335), "noServices": text.misc(332),
                                "ports": text.misc(309), "hazardsLabel": text.misc(311),
                                "government": text.misc(325), "legalLabel": text.misc(326),
                                "goodsLabel": text.misc(327), "servicesLabel": text.misc(328),
                                "noPorts": text.misc(334), "gatePrompt": text.misc(308),
                                "current": text.misc(337), "selected": text.misc(338),
                                "destination": text.misc(339), "gate": text.misc(340)]])
    }
}
