// NovaEditor — Godot façade over the shared plug-in document (PluginDocument and the
// editing types in NovaSwiftKit). The Apple UI is SwiftUI and stays on macOS; this class
// is the same document, undo stack, schemas, galaxy math, story graph and linter, crossed
// as JSON and byte buffers. godot/editor/ draws it.
//
// `@Callable` methods live in this class body (SwiftGodot does not export extension methods).

import Foundation
import SwiftGodot
import NovaSwiftEngine
import NovaSwiftKit

@Godot
class NovaEditor: RefCounted {

    private weak var world: NovaWorld?
    private var doc = PluginDocument(name: "Untitled Plug-in")
    private var fileURL: URL?
    private var rootURL: URL?
    private var format: PluginFormat = .rez
    /// Installed plug-in this document was opened from, excluded from the base merge.
    private var installedID: String = ""
    private var lastError = ""

    private var lintAt = -1
    private var lintRows: [[String: Any]] = []
    private var storyAt = -1
    private var storyJSON: [String: Any] = [:]
    private var galaxyAt = -1
    private var galaxyJSON: [String: Any] = [:]
    private var sheetKey = ""
    private var sheet: SpriteSheet?
    private var sheetPNG: Data?

    // MARK: Session

    @Callable(autoSnakeCase: true) func attach(world: NovaWorld) { self.world = world }

    /// Fresh layer over the already-loaded game (or an empty base when nothing is loaded).
    @Callable(autoSnakeCase: true) func newDocument() -> String {
        doc = PluginDocument(name: "Untitled Plug-in", base: liveBase(excluding: nil))
        fileURL = nil
        rootURL = nil
        format = .rez
        installedID = ""
        lastError = ""
        dropCaches()
        return status()
    }

    @Callable(autoSnakeCase: true) func openPath(path: String) -> String {
        do {
            try open(URL(fileURLWithPath: path), excluding: nil)
            lastError = ""
        } catch {
            lastError = String(describing: error)
        }
        return status()
    }

    /// Open an installed plug-in by id. Its own records are the layer, not the base.
    @Callable(autoSnakeCase: true) func openInstalled(id: String) -> String {
        do {
            guard let bundle = PluginRuntime.shared.plugins.first(where: { $0.id == id }) else {
                throw PluginDocumentError.notFound(ResourceKey(NovaType.ship, 0))
            }
            let layout = PluginBundleLoader.layout(of: bundle)
            let loaded = try PluginBundleLoader.load(layout)
            doc = PluginDocument.open(files: loaded.files, defaultName: bundle.name, base: liveBase(excluding: id))
            rootURL = layout.root
            fileURL = nil
            installedID = id
            format = .rez
            lastError = ""
            dropCaches()
        } catch {
            lastError = error is PluginDocumentError ? "No installed plug-in \"\(id)\"." : String(describing: error)
        }
        return status()
    }

    @Callable(autoSnakeCase: true) func installed() -> String {
        let rows: [[String: Any]] = PluginRuntime.shared.plugins.map {
            ["id": $0.id, "name": $0.name, "enabled": $0.isEnabled, "totalConversion": $0.isTotalConversion]
        }
        return Self.json(rows)
    }

    @Callable(autoSnakeCase: true) func save() -> String {
        do {
            if doc.usesFolderLayout, let root = rootURL {
                let plan = doc.makeSavePlan(rewriteAll: false, embedPacksInFile: false, embedMetadata: true)
                try plan.write(to: root)
                doc.didSave(plan)
            } else if let url = fileURL {
                try doc.save(to: url, format: format)
            } else {
                lastError = "Save As to choose a file."
                return status()
            }
            lastError = ""
        } catch {
            lastError = String(describing: error)
        }
        return status()
    }

    /// Write to `path` and make it the document's file. `asFolder` saves the multi-file plan.
    @Callable(autoSnakeCase: true) func saveAs(path: String, asFolder: Bool) -> String {
        let url = URL(fileURLWithPath: path)
        do {
            if asFolder || doc.usesFolderLayout {
                if !doc.usesFolderLayout {
                    let name = url.lastPathComponent.isEmpty ? "Plug-in.rez" : url.lastPathComponent
                    doc.collapseSources(to: name, format: format)
                }
                let root = asFolder ? url : (rootURL ?? url.deletingLastPathComponent())
                let plan = doc.makeSavePlan(rewriteAll: true, embedPacksInFile: false, embedMetadata: true)
                try plan.write(to: root)
                doc.didSave(plan)
                rootURL = root
                fileURL = nil
            } else {
                let ext = url.pathExtension.lowercased()
                format = (ext == "ndat" || ext == "classic") ? .classic : .rez
                try doc.save(to: url, format: format)
                fileURL = url
                rootURL = nil
            }
            installedID = ""
            lastError = ""
        } catch {
            lastError = String(describing: error)
        }
        return status()
    }

    /// A copy at `path`. The open file and the dirty flag stay as they are.
    @Callable(autoSnakeCase: true) func exportCopy(path: String) -> String {
        do {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let fmt: PluginFormat = (ext == "ndat" || ext == "classic") ? .classic : .rez
            try doc.exportData(format: fmt).write(to: url, options: .atomic)
            lastError = ""
        } catch {
            lastError = String(describing: error)
        }
        return status()
    }

    /// Copy a `.rez` of this plug-in into the user Plug-ins folder.
    @Callable(autoSnakeCase: true) func install() -> String {
        do {
            let safe = Self.fileName(doc.name)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(safe + ".rez")
            try doc.exportData(format: .rez).write(to: tmp, options: .atomic)
            let id = try PluginRuntime.shared.importPlugin(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            lastError = ""
            var o = statusObject()
            o["installedId"] = id
            return Self.json(o)
        } catch {
            lastError = String(describing: error)
            return status()
        }
    }

    @Callable(autoSnakeCase: true) func setPluginInfo(name: String, author: String, version: String, notes: String) -> String {
        if doc.name != name { doc.name = name }
        if doc.author != author { doc.author = author }
        if doc.version != version { doc.version = version }
        if doc.notes != notes { doc.notes = notes }
        return status()
    }

    @Callable(autoSnakeCase: true) func status() -> String { Self.json(statusObject()) }

    @Callable(autoSnakeCase: true) func undo() -> String {
        _ = doc.undo(); dropCaches(); return status()
    }
    @Callable(autoSnakeCase: true) func redo() -> String {
        _ = doc.redo(); dropCaches(); return status()
    }

    // MARK: Types, browse, edits

    @Callable(autoSnakeCase: true) func types() -> String {
        var rows: [[String: Any]] = []
        var seen = Set<NovaSwiftKit.FourCharCode>()
        for t in ResourceSchemas.knownTypes {
            guard seen.insert(t).inserted else { continue }
            rows.append(typeRow(t))
        }
        for t in doc.effective.types where seen.insert(t).inserted {
            rows.append(typeRow(t))
        }
        return Self.json(rows)
    }

    @Callable(autoSnakeCase: true) func browse(type: String, query: String) -> String {
        guard let t = code(type) else { return "[]" }
        let q = query.lowercased()
        let rows: [[String: Any]] = doc.browse(t).compactMap { e in
            let name = e.name.isEmpty ? "#\(e.key.id)" : e.name
            if !q.isEmpty, !name.lowercased().contains(q), !"\(e.key.id)".contains(q) { return nil }
            return ["id": e.key.id, "name": name, "prov": prov(e.provenance),
                    "plugin": pluginOf(e.provenance)] as [String: Any]
        }
        return Self.json(rows)
    }

    @Callable(autoSnakeCase: true) func create(type: String, name: String) -> String {
        guard let t = code(type) else { return fail("Unknown type.") }
        do {
            let id = try doc.create(t, name: name)
            dropCaches()
            lastError = ""
            return Self.json(["ok": true, "id": id])
        } catch {
            return fail(String(describing: error))
        }
    }

    @Callable(autoSnakeCase: true) func duplicate(type: String, id: Int) -> String {
        guard let t = code(type) else { return fail("Unknown type.") }
        do {
            let nid = try doc.duplicate(t, id)
            dropCaches()
            lastError = ""
            return Self.json(["ok": true, "id": nid])
        } catch {
            return fail(String(describing: error))
        }
    }

    @Callable(autoSnakeCase: true) func remove(type: String, id: Int) -> String {
        guard let t = code(type) else { return fail("Unknown type.") }
        if doc.remove(t, id) { dropCaches(); lastError = "" } else { lastError = "That resource is not in this plug-in." }
        return status()
    }

    @Callable(autoSnakeCase: true) func revert(type: String, id: Int) -> String {
        guard let t = code(type) else { return fail("Unknown type.") }
        if doc.revertToBase(t, id) { dropCaches(); lastError = "" } else { lastError = "Nothing to revert." }
        return status()
    }

    @Callable(autoSnakeCase: true) func renumber(type: String, id: Int, to: Int, rewrite: Bool) -> String {
        guard let t = code(type) else { return fail("Unknown type.") }
        do {
            _ = try doc.renumber(t, from: id, to: to, rewriteReferences: rewrite, moveCompanions: true)
            dropCaches()
            lastError = ""
            return Self.json(["ok": true, "id": to])
        } catch {
            return fail(String(describing: error))
        }
    }

    @Callable(autoSnakeCase: true) func rename(type: String, id: Int, name: String) -> String {
        guard let t = code(type), let r = doc.resource(t, id) else { return fail("No such resource.") }
        let next = Resource(type: r.type, id: r.id, name: name, attributes: r.attributes, data: r.data)
        if doc.put(next, label: "Rename \(t.stringValue) #\(id)") { dropCaches(); lastError = "" }
        else { lastError = "Couldn't rename." }
        return status()
    }

    // MARK: Inspector

    @Callable(autoSnakeCase: true) func inspect(type: String, id: Int) -> String {
        guard let t = code(type), let r = doc.resource(t, id) else { return "{}" }
        let kind = ResourceSchemas.editorKind(for: t)
        let p = doc.provenance(t, id)
        var o: [String: Any] = [
            "type": t.stringValue, "typeName": ResourceSchemas.displayName(for: t),
            "id": id, "name": r.name, "prov": prov(p), "plugin": pluginOf(p),
            "kind": kind.rawValue, "bytes": r.data.count,
            "inPlugin": doc.layerResource(t, id) != nil,
        ]
        if kind == .form, let schema = ResourceSchemas.schema(for: t) {
            let data = schema.padded(r.data)
            let values = schema.readAll(from: data)
            o["groups"] = schema.groups
            o["fields"] = schema.fields.map { fieldJSON($0) }
            var encoded: [String: Any] = [:]
            var names: [String: String] = [:]
            for f in schema.fields {
                guard let v = values[f.key] else { continue }
                encoded[f.key] = encode(v)
                if let ref = resolvedRef(f, value: v, values: values), let target = doc.resource(ref.0, ref.1) {
                    names[f.key] = target.name.isEmpty ? "#\(ref.1)" : target.name
                }
            }
            o["values"] = encoded
            o["refNames"] = names
        }
        if kind == .text { o["text"] = textPayload(t, r.data) }
        if kind == .raw || kind == .form {
            o["hex"] = hex(r.data, limit: 65536)
            o["hexEditable"] = r.data.count <= 65536
        }
        if let schema = ResourceSchemas.schema(for: t), let under = doc.base.resource(t, id), kind == .form {
            let changes = ResourceDiff.fieldChanges(schema: schema, base: under.data, new: r.data) { ty, i in
                doc.resource(ty, i)?.name
            }
            o["diff"] = changes.prefix(40).map { c -> [String: Any] in
                ["key": c.key, "label": c.label, "group": c.group, "old": c.oldText, "new": c.newText, "summary": c.summaryText]
            }
            o["diffSummary"] = ResourceDiff.summary(changes)
        }
        return Self.json(o)
    }

    /// `{uses:[{type,id,field,name}], usedBy:[…]}`. Builds the reference graph on first use.
    @Callable(autoSnakeCase: true) func references(type: String, id: Int) -> String {
        guard let t = code(type) else { return "{}" }
        let key = ResourceKey(t, id)
        func row(_ ref: ResourceReference, outbound: Bool) -> [String: Any] {
            let other = outbound ? ref.target : ref.source
            let name = doc.resource(other.type, other.id)?.name ?? ""
            return ["type": other.type.stringValue, "id": other.id, "field": ref.fieldKey,
                    "name": name.isEmpty ? "#\(other.id)" : name]
        }
        let graph = doc.references
        return Self.json(["uses": graph.uses(key).map { row($0, outbound: true) },
                          "usedBy": graph.usedBy(key).map { row($0, outbound: false) }] as [String: Any])
    }

    /// `valueJSON` is one field value: `{"t":"int","v":1}` and the other shapes `encode` writes.
    @Callable(autoSnakeCase: true) func setField(type: String, id: Int, key: String, valueJSON: String) -> String {
        guard let t = code(type), let value = decodeValue(valueJSON) else { return fail("Bad value.") }
        if doc.setValue(value, field: key, of: t, id) { dropCaches(); lastError = "" }
        else { lastError = "That field can't be set." }
        return status()
    }

    @Callable(autoSnakeCase: true) func setFieldElement(type: String, id: Int, key: String, index: Int, valueJSON: String) -> String {
        guard let t = code(type), let schema = ResourceSchemas.schema(for: t), let f = schema.field(key),
              let r = doc.resource(t, id), let value = decodeValue(valueJSON),
              case var .array(items) = FieldCodec.read(f, from: schema.padded(r.data)) else { return fail("Not an array field.") }
        let pad: FieldValue = value
        while items.count <= index { items.append(pad) }
        guard index >= 0 else { return fail("Bad index.") }
        items[index] = value
        if doc.setValue(.array(items), field: key, of: t, id) { dropCaches(); lastError = "" }
        else { lastError = "Couldn't write the array." }
        return status()
    }

    /// Text editors. `payloadJSON` is `{strings:[…]}`, `{text}`, or `{text,picture,movie,flags}`.
    @Callable(autoSnakeCase: true) func setText(type: String, id: Int, payloadJSON: String) -> String {
        guard let t = code(type), let r = doc.resource(t, id),
              let obj = parse(payloadJSON) as? [String: Any] else { return fail("Bad text.") }
        let data: Data
        if t == NovaType.strList {
            let strings = (obj["strings"] as? [String]) ?? []
            data = TextResourceCodec.encodeStringList(strings.map { TextResourceCodec.stored($0) })
        } else if t == NovaSwiftKit.FourCharCode("STR ") {
            data = TextResourceCodec.encodeString(TextResourceCodec.stored(obj["text"] as? String ?? ""))
        } else if t == NovaType.desc || ResourceSchemas.editorKind(for: t) == .text && ResourceSchemas.schema(for: t)?.type == NovaType.desc {
            var rec = DescRecord(r.data)
            if let text = obj["text"] as? String { rec.text = TextResourceCodec.stored(text) }
            if let p = intOf(obj["picture"]) { rec.pictureID = p }
            if let m = obj["movie"] as? String { rec.movieFile = m }
            if let f = intOf(obj["flags"]) { rec.flags = f }
            data = rec.encode()
        } else if t == NovaSwiftKit.FourCharCode("TEXT") {
            data = Data(FieldCodec.macRoman(TextResourceCodec.stored(obj["text"] as? String ?? "")))
        } else if ResourceSchemas.editorKind(for: t) == .text, let text = obj["text"] as? String {
            data = Data(FieldCodec.macRoman(TextResourceCodec.stored(text)))
        } else {
            return fail("This type isn't edited as text.")
        }
        let next = Resource(type: r.type, id: r.id, name: r.name, attributes: r.attributes, data: data)
        if doc.put(next, label: "Edit text") { dropCaches(); lastError = "" } else { lastError = "Couldn't write the text." }
        return status()
    }

    /// Replace the resource bytes from a hex string (spaces ignored). Refuses past 64 KB.
    @Callable(autoSnakeCase: true) func setHex(type: String, id: Int, hex: String) -> String {
        guard let t = code(type), let r = doc.resource(t, id) else { return fail("No such resource.") }
        guard r.data.count <= 65536 else { return fail("This resource is too large to edit as hex.") }
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0, let data = dataFromHex(cleaned) else { return fail("Hex isn't valid.") }
        let next = Resource(type: r.type, id: r.id, name: r.name, attributes: r.attributes, data: data)
        if doc.put(next, label: "Edit bytes") { dropCaches(); lastError = "" } else { lastError = "Couldn't write the bytes." }
        return status()
    }

    @Callable(autoSnakeCase: true) func graphicInfo(type: String, id: Int) -> String {
        guard let t = code(type), let r = doc.resource(t, id) else { return "{}" }
        loadSheet(t, id, r.data)
        if let png = sheetPNG {
            return Self.json(["png": true, "bytes": png.count, "frames": 1] as [String: Any])
        }
        guard let s = sheet else { return Self.json(["png": false, "frames": 0, "error": "Couldn't decode."] as [String: Any]) }
        return Self.json(["png": false, "w": s.frameWidth, "h": s.frameHeight, "frames": s.frameCount,
                          "columns": s.columns, "rows": s.rows] as [String: Any])
    }

    /// One frame as RGBA8, or the raw PNG bytes when `graphic_info` says `png`.
    @Callable(autoSnakeCase: true) func graphicFrame(type: String, id: Int, frame: Int) -> PackedByteArray {
        guard let t = code(type), let r = doc.resource(t, id) else { return PackedByteArray() }
        loadSheet(t, id, r.data)
        if let png = sheetPNG { return PackedByteArray([UInt8](png)) }
        guard let s = sheet else { return PackedByteArray() }
        if s.frameCount <= 1 { return PackedByteArray(s.rgba) }
        guard let one = s.singleFrame(min(max(0, frame), s.frameCount - 1)) else { return PackedByteArray() }
        return PackedByteArray(one.rgba)
    }

    @Callable(autoSnakeCase: true) func soundInfo(type: String, id: Int) -> String {
        guard let t = code(type), let r = doc.resource(t, id) else { return "{}" }
        do {
            let snd = try SndDecoder.decode(r.data)
            return Self.json(["rate": snd.sampleRate, "frames": snd.frameCount, "seconds": snd.duration] as [String: Any])
        } catch {
            return Self.json(["error": String(describing: error)] as [String: Any])
        }
    }

    @Callable(autoSnakeCase: true) func soundPcm(type: String, id: Int) -> PackedByteArray {
        guard let t = code(type), let r = doc.resource(t, id), let snd = try? SndDecoder.decode(r.data) else {
            return PackedByteArray()
        }
        return PackedByteArray(snd.pcm16LE())
    }

    // MARK: Galaxy, system, story, lint

    @Callable(autoSnakeCase: true) func galaxy() -> String {
        if galaxyAt == doc.changeCount, !galaxyJSON.isEmpty { return Self.json(galaxyJSON) }
        let game = NovaGame(doc.effective)
        let palette = GovernmentMapPalette(game: game)
        let systems: [[String: Any]] = game.systems().map { s in
            let p = doc.provenance(NovaType.syst, s.id)
            let c = palette.color(for: s.government)
            return ["id": s.id, "name": s.name, "x": s.x, "y": s.y, "govt": s.government,
                    "links": s.links, "spobs": s.spobs.count, "prov": prov(p),
                    "r": c[0], "g": c[1], "b": c[2]] as [String: Any]
        }
        let nebulae: [[String: Any]] = game.nebulae().map {
            ["id": $0.id, "name": $0.name, "x": $0.x, "y": $0.y, "w": $0.width, "h": $0.height] as [String: Any]
        }
        galaxyJSON = ["systems": systems, "nebulae": nebulae]
        galaxyAt = doc.changeCount
        return Self.json(galaxyJSON)
    }

    @Callable(autoSnakeCase: true) func galaxyMove(id: Int, x: Int, y: Int) -> String {
        if doc.setValue(.point(x, y), field: "position", of: NovaType.syst, id) { dropCaches(); lastError = "" }
        else { lastError = "Couldn't move that system." }
        return status()
    }

    @Callable(autoSnakeCase: true) func galaxyLink(a: Int, b: Int, link: Bool) -> String {
        if link {
            switch SystemLinkEditing.link(doc, a, b) {
            case .linked, .alreadyLinked: lastError = ""
            case .invalid: lastError = "Those systems can't be linked."
            case .full(let id): lastError = "System #\(id) has no free link slot."
            }
        } else if !SystemLinkEditing.unlink(doc, a, b) {
            lastError = "Those systems aren't linked."
        } else {
            lastError = ""
        }
        dropCaches()
        return status()
    }

    @Callable(autoSnakeCase: true) func systemInfo(id: Int) -> String {
        let game = NovaGame(doc.effective)
        guard let s = game.system(id) else { return "{}" }
        let links: [[String: Any]] = s.links.map { lid in
            ["id": lid, "name": game.system(lid)?.name ?? "#\(lid)"] as [String: Any]
        }
        let stellars: [[String: Any]] = s.spobs.compactMap { sid in
            guard let sp = game.spob(sid) else { return nil }
            return ["id": sid, "name": sp.name, "x": sp.x, "y": sp.y, "govt": sp.government] as [String: Any]
        }
        let bg = s.backgroundColor
        return Self.json(["id": s.id, "name": s.name, "x": s.x, "y": s.y, "govt": s.government,
                          "govtName": game.govt(s.government)?.name ?? (s.government < 0 ? "Independent" : "#\(s.government)"),
                          "links": links, "stellars": stellars,
                          "r": Int(bg.r), "g": Int(bg.g), "b": Int(bg.b)] as [String: Any])
    }

    @Callable(autoSnakeCase: true) func systemAddStellar(system: Int, spob: Int) -> String {
        if SystemLinkEditing.addStellar(doc, system: system, spob: spob) { dropCaches(); lastError = "" }
        else { lastError = "Couldn't add that stellar (16 slots, or it isn't a spöb)." }
        return status()
    }

    @Callable(autoSnakeCase: true) func systemRemoveStellar(system: Int, spob: Int) -> String {
        if SystemLinkEditing.removeStellar(doc, system: system, spob: spob) { dropCaches(); lastError = "" }
        else { lastError = "That stellar isn't in the system." }
        return status()
    }

    @Callable(autoSnakeCase: true) func stellarMove(id: Int, x: Int, y: Int) -> String {
        if doc.setValue(.point(x, y), field: "position", of: NovaType.spob, id) { dropCaches(); lastError = "" }
        else { lastError = "Couldn't move that stellar." }
        return status()
    }

    /// Mission / cron graph plus a short bit index. Cached until the document changes.
    @Callable(autoSnakeCase: true) func story() -> String {
        if storyAt == doc.changeCount, !storyJSON.isEmpty { return Self.json(storyJSON) }
        let touched = layerKeys()
        let index = ControlBitIndex(doc.effective, touched: touched)
        let graph = StoryGraph(collection: doc.effective, index: index, touched: touched)
        let nodes: [[String: Any]] = graph.nodes.map { n in
            ["id": n.id, "res": n.key.id, "type": n.key.type.stringValue, "name": n.name,
             "x": Double(n.x), "y": Double(n.y), "cron": n.isCron, "touched": n.touched,
             "dead": n.deadEnd, "unreachable": n.unreachable,
             "story": n.storyline ?? ""] as [String: Any]
        }
        let edges: [[String: Any]] = graph.edges.map { e in
            let kind = e.kind == .enables ? "enables" : e.kind == .disables ? "disables" : "starts"
            return ["from": e.from, "to": e.to, "bit": e.bit, "kind": kind, "field": e.field] as [String: Any]
        }
        var bits: [[String: Any]] = []
        for bit in index.usedBits.prefix(400) {
            let refs = index.references(bit: bit)
            bits.append(["bit": bit, "status": index.status(of: bit).rawValue, "n": refs.count,
                         "touched": index.pluginTouchedBits.contains(bit)])
        }
        storyJSON = ["nodes": nodes, "edges": edges, "bits": bits,
                     "width": Double(graph.bounds.width), "height": Double(graph.bounds.height),
                     "components": graph.componentCount, "bitCount": index.usedBits.count]
        storyAt = doc.changeCount
        return Self.json(storyJSON)
    }

    @Callable(autoSnakeCase: true) func bitRefs(bit: Int) -> String {
        let index = ControlBitIndex(doc.effective, touched: layerKeys())
        let rows: [[String: Any]] = index.references(bit: bit).map {
            ["type": $0.key.type.stringValue, "id": $0.key.id, "field": $0.fieldLabel,
             "role": $0.role.rawValue, "name": doc.resource($0.key.type, $0.key.id)?.name ?? ""] as [String: Any]
        }
        return Self.json(rows)
    }

    @Callable(autoSnakeCase: true) func lint() -> String {
        if lintAt != doc.changeCount {
            lintRows = PluginLinter.lint(doc).map { issue in
                ["severity": Self.severity(issue.severity), "code": issue.code,
                 "type": issue.key.type.stringValue, "id": issue.key.id,
                 "field": issue.fieldKey ?? "", "message": issue.message] as [String: Any]
            }
            lintAt = doc.changeCount
        }
        let errors = lintRows.filter { $0["severity"] as? String == "error" }.count
        let warnings = lintRows.filter { $0["severity"] as? String == "warning" }.count
        return Self.json(["issues": lintRows, "errors": errors, "warnings": warnings] as [String: Any])
    }

    @Callable(autoSnakeCase: true) func changes() -> String {
        var rows: [[String: Any]] = []
        for t in doc.layer.types {
            for r in doc.layer.resources(of: t) {
                let under = doc.base.resource(t, r.id)
                var summary = under == nil ? "New resource" : "Override"
                if let under, let schema = ResourceSchemas.schema(for: t), schema.editorKind == .form {
                    let diff = ResourceDiff.fieldChanges(schema: schema, base: under.data, new: r.data) { ty, i in
                        doc.resource(ty, i)?.name
                    }
                    summary = ResourceDiff.summary(diff)
                } else if let under, under.data == r.data, under.name == r.name {
                    summary = "Identical to base"
                }
                rows.append(["type": t.stringValue, "typeName": ResourceSchemas.displayName(for: t),
                             "id": r.id, "name": r.name.isEmpty ? "#\(r.id)" : r.name,
                             "prov": under == nil ? "new" : "override", "summary": summary])
            }
        }
        rows.sort { (a, b) in
            let ta = a["type"] as? String ?? "", tb = b["type"] as? String ?? ""
            if ta != tb { return ta < tb }
            return (a["id"] as? Int ?? 0) < (b["id"] as? Int ?? 0)
        }
        return Self.json(rows)
    }

    /// Layer records whose base copy already belongs to another plug-in.
    @Callable(autoSnakeCase: true) func conflicts() -> String {
        var rows: [[String: Any]] = []
        for t in doc.layer.types {
            for r in doc.layer.resources(of: t) {
                guard let under = doc.base.resource(t, r.id), !under.pluginID.isEmpty else { continue }
                rows.append(["type": t.stringValue, "id": r.id, "name": r.name, "plugin": under.pluginID])
            }
        }
        return Self.json(rows)
    }

    @Callable(autoSnakeCase: true) func bundle() -> String {
        let files: [[String: Any]] = doc.sourceFiles.map {
            ["name": $0, "pack": $0.hasPrefix(PluginDocument.packPrefix)] as [String: Any]
        }
        return Self.json(["files": files, "primary": doc.primaryFile ?? "",
                          "folder": doc.usesFolderLayout, "format": format.rawValue,
                          "path": fileURL?.path ?? rootURL?.path ?? ""] as [String: Any])
    }

    /// Hand the merged view to `world` and swap in a sandbox pilot. The shell then builds the world.
    @Callable(autoSnakeCase: true) func beginTest(world: NovaWorld, baseDir: String, systemID: Int, shipType: Int) -> Bool {
        world.editorBeginTest(resources: doc.effective, baseDir: baseDir, systemID: systemID, shipType: shipType)
    }

    // MARK: Private

    private func open(_ url: URL, excluding: String?) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw PluginBundleError.unreadable(file: url.lastPathComponent, reason: "not found")
        }
        let base = liveBase(excluding: excluding)
        if isDir.boolValue {
            let layout: PluginLayout
            if PluginBundleLoader.isGraphicsPack(url) {
                layout = PluginBundleLoader.layout(ofPack: url)
            } else if let folder = PluginBundleLoader.layout(ofFolder: url) {
                layout = folder
            } else {
                throw PluginBundleError.unreadable(file: url.lastPathComponent, reason: "not a plug-in folder")
            }
            let loaded = try PluginBundleLoader.load(layout)
            doc = PluginDocument.open(files: loaded.files, defaultName: layout.name, base: base)
            rootURL = layout.root
            fileURL = nil
        } else {
            doc = try PluginDocument.open(url: url, base: base)
            fileURL = url
            rootURL = nil
            let ext = url.pathExtension.lowercased()
            format = (ext == "ndat" || ext == "classic") ? .classic : .rez
        }
        installedID = excluding ?? ""
        dropCaches()
    }

    /// Loaded game when the open plug-in is not part of it; otherwise a fresh merge that leaves it out.
    private func liveBase(excluding id: String?) -> ResourceCollection {
        if let id, !id.isEmpty { return PluginRuntime.shared.editorBase(excluding: id) }
        if let loaded = world?.dbgGame?.resources { return loaded }
        let scanned = PluginRuntime.shared.editorBase(excluding: nil)
        return scanned.totalCount > 0 ? scanned : ResourceCollection()
    }

    private func statusObject() -> [String: Any] {
        [
            "name": doc.name, "author": doc.author, "version": doc.version, "notes": doc.notes,
            "dirty": doc.isDirty, "canUndo": doc.canUndo, "canRedo": doc.canRedo,
            "undo": doc.undoLabel ?? "", "redo": doc.redoLabel ?? "",
            "path": fileURL?.path ?? "", "folder": rootURL?.path ?? "",
            "format": format.rawValue, "installed": installedID,
            "multiFile": doc.usesFolderLayout, "error": lastError,
            "change": doc.changeCount,
        ]
    }

    private func fail(_ message: String) -> String {
        lastError = message
        return Self.json(["ok": false, "error": message])
    }

    private func dropCaches() {
        lintAt = -1
        storyAt = -1
        galaxyAt = -1
        sheetKey = ""
        sheet = nil
        sheetPNG = nil
    }

    private func typeRow(_ t: NovaSwiftKit.FourCharCode) -> [String: Any] {
        let all = doc.effective.resources(of: t).count
        let changed = doc.layer.resources(of: t).count
        return ["type": t.stringValue, "name": ResourceSchemas.displayName(for: t),
                "kind": ResourceSchemas.editorKind(for: t).rawValue,
                "count": all, "changed": changed]
    }

    private func layerKeys() -> Set<ResourceKey> {
        var keys = Set<ResourceKey>()
        for t in doc.layer.types {
            for r in doc.layer.resources(of: t) { keys.insert(ResourceKey(t, r.id)) }
        }
        return keys
    }

    private func code(_ s: String) -> NovaSwiftKit.FourCharCode? { NovaSwiftKit.FourCharCode(s) }

    private func prov(_ p: Provenance?) -> String {
        switch p {
        case .base: return "base"
        case .new: return "new"
        case .override: return "override"
        case .otherPlugin: return "plugin"
        case nil: return "missing"
        }
    }

    private func pluginOf(_ p: Provenance?) -> String {
        if case let .otherPlugin(id) = p { return id }
        return ""
    }

    private func fieldJSON(_ f: SchemaField) -> [String: Any] {
        var o: [String: Any] = [
            "key": f.key, "label": f.label, "group": f.group, "help": f.help,
            "kind": kindTag(f.kind), "count": f.count, "width": f.kind.byteSize,
        ]
        if let min = f.minValue { o["min"] = min }
        if let max = f.maxValue { o["max"] = max }
        switch f.kind {
        case let .int(_, signed), let .enumeration(_, signed): o["signed"] = signed
        case let .ref(t, base): o["ref"] = t.stringValue; o["refBase"] = base
        default: break
        }
        if !f.flagBits.isEmpty {
            o["flags"] = f.flagBits.map { ["mask": $0.mask, "label": $0.label] as [String: Any] }
        }
        if !f.options.isEmpty {
            o["options"] = f.options.prefix(48).map { opt -> [String: Any] in
                var d: [String: Any] = ["label": opt.label, "start": opt.start, "end": opt.end == Int.max ? opt.start : opt.end]
                if let t = opt.refType { d["ref"] = t.stringValue }
                return d
            }
        }
        if let ctx = f.contextual { o["selector"] = ctx.selector }
        return o
    }

    private func kindTag(_ k: FieldKind) -> String {
        switch k {
        case .int: return "int"
        case .flags: return "flags"
        case .enumeration: return "enum"
        case .ref: return "ref"
        case .cString: return "cstring"
        case .pString: return "pstring"
        case .color: return "color"
        case .ncb: return "ncb"
        case .blob: return "blob"
        case .point: return "point"
        case .rect: return "rect"
        case .mask64: return "mask64"
        case .bits: return "bits"
        }
    }

    private func encode(_ v: FieldValue) -> [String: Any] {
        switch v {
        case let .int(n): return ["t": "int", "v": n]
        case let .uint64(n): return ["t": "u64", "v": String(format: "0x%llX", n)]
        case let .string(s): return ["t": "str", "v": s]
        case let .color(r, g, b): return ["t": "color", "r": Int(r), "g": Int(g), "b": Int(b)]
        case let .bytes(d):
            let shown = d.prefix(32)
            return ["t": "bytes", "n": d.count, "hex": shown.map { String(format: "%02X", $0) }.joined(separator: " ")]
        case let .point(x, y): return ["t": "point", "x": x, "y": y]
        case let .rect(top, left, bottom, right):
            return ["t": "rect", "top": top, "left": left, "bottom": bottom, "right": right]
        case let .array(items): return ["t": "array", "v": items.map { encode($0) }]
        }
    }

    private func decodeValue(_ json: String) -> FieldValue? {
        guard let obj = parse(json) as? [String: Any] else { return nil }
        return decodeObject(obj)
    }

    private func decodeObject(_ obj: [String: Any]) -> FieldValue? {
        switch obj["t"] as? String {
        case "int": return intOf(obj["v"]).map { .int($0) }
        case "u64":
            let s = (obj["v"] as? String) ?? ""
            let hex = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
            return UInt64(hex, radix: 16).map { .uint64($0) } ?? intOf(obj["v"]).map { .uint64(UInt64($0)) }
        case "str": return .string(obj["v"] as? String ?? "")
        case "color":
            return .color(r: UInt8(intOf(obj["r"]) ?? 0), g: UInt8(intOf(obj["g"]) ?? 0), b: UInt8(intOf(obj["b"]) ?? 0))
        case "bytes":
            let hex = (obj["hex"] as? String) ?? ""
            return dataFromHex(hex.filter { !$0.isWhitespace }).map { .bytes($0) }
        case "point":
            return .point(intOf(obj["x"]) ?? 0, intOf(obj["y"]) ?? 0)
        case "rect":
            return .rect(intOf(obj["top"]) ?? 0, intOf(obj["left"]) ?? 0, intOf(obj["bottom"]) ?? 0, intOf(obj["right"]) ?? 0)
        case "array":
            let raw = obj["v"] as? [[String: Any]] ?? []
            return .array(raw.compactMap { decodeObject($0) })
        default: return nil
        }
    }

    private func resolvedRef(_ f: SchemaField, value: FieldValue, values: [String: FieldValue]) -> (NovaSwiftKit.FourCharCode, Int)? {
        guard case let .int(n) = value else { return nil }
        let selector = f.contextual.flatMap { values[$0.selector]?.intValue }
        return f.reference(for: n, selector: selector)
    }

    private func textPayload(_ t: NovaSwiftKit.FourCharCode, _ data: Data) -> [String: Any] {
        if t == NovaType.strList {
            return ["mode": "list", "strings": TextResourceCodec.decodeStringList(data).map { TextResourceCodec.display($0) }]
        }
        if t == NovaSwiftKit.FourCharCode("STR ") {
            return ["mode": "string", "text": TextResourceCodec.display(TextResourceCodec.decodeString(data))]
        }
        if t == NovaType.desc {
            let rec = DescRecord(data)
            return ["mode": "desc", "text": TextResourceCodec.display(rec.text), "picture": rec.pictureID,
                    "movie": rec.movieFile, "flags": rec.flags, "trailer": rec.hasTrailer]
        }
        let text = String(macRoman: data)
        return ["mode": "plain", "text": TextResourceCodec.display(text)]
    }

    private func loadSheet(_ t: NovaSwiftKit.FourCharCode, _ id: Int, _ data: Data) {
        let key = "\(t.rawValue)/\(id)/\(doc.changeCount)"
        if key == sheetKey { return }
        sheetKey = key
        sheet = nil
        sheetPNG = nil
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { sheetPNG = data; return }
        sheet = Self.decodeGraphic(t, data)
    }

    private static func decodeGraphic(_ t: NovaSwiftKit.FourCharCode, _ data: Data) -> SpriteSheet? {
        if t == NovaType.rleD { return try? RLED.decode(data) }
        if t == NovaType.rle8 { return try? RLE8.decode(data) }
        if t == NovaType.pict { return try? PICT.decode(data) }
        if t == NovaType.cicn { return try? CICN.decode(data) }
        if t == NovaType.ppat || t == NovaType.ppatAlt { return try? PixPat.decode(data) }
        return try? ClassicIcon.decode(type: t, data: data)
    }

    private func hex(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func dataFromHex(_ cleaned: String) -> Data? {
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return cleaned.isEmpty ? Data() : nil }
        var out = Data()
        out.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    private func intOf(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private func parse(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled Plug-in" : s
    }

    private static func severity(_ s: LintIssue.Severity) -> String {
        switch s {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
