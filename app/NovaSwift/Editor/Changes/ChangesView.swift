#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// The editor's landing screen for an opened plug-in: a header summary and every resource the
/// plug-in adds or overrides, grouped by category, with plain-language summaries of what changed,
/// HD / 3D replacements resolved to the game objects they upgrade, and conflicts with other
/// enabled plug-ins. All derived data is computed off the main actor (ChangesModel,
/// EditorHDIndex); until it lands the view shows skeletons, afterwards a refresh strip.
struct ChangesView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var changes = ChangesModel()
    @ObservedObject private var hd: EditorHDIndex

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", new = "New", override = "Overrides"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var kind: KindFilter = .all
    @State private var hideUnchanged = false
    @State private var collapsed: Set<String> = []
    @State private var collapseSeeded = false
    /// Filtered copy of the snapshot's sections (equal to it when no filter is active).
    @State private var shown: [ChangeSection] = []
    @State private var shownRevision = -1

    init(model: EditorModel) {
        self.model = model
        _hd = ObservedObject(wrappedValue: EditorHDIndex.shared(for: model))
    }

    private struct RefreshKey: Hashable { let rev: Int; let ready: Bool; let conflicts: Int }
    private struct FilterKey: Hashable {
        let search: String; let kind: KindFilter; let hideUnchanged: Bool; let rev: Int
    }
    private struct DetailKey: Hashable { let category: ChangeCategory; let rev: Int; let open: Bool }

    private static let conflictsID = "conflicts"
    /// Sections longer than this start collapsed.
    private static let autoCollapseAbove = 80

    var body: some View {
        VStack(spacing: 0) {
            // Opaque and above the list, so the pinned section headers of the
            // lazy list can never draw over the title / search row.
            header
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(white: 0.11))
                .zIndex(1)
            Divider().overlay(alignment: .top) {
                EditorRefreshStrip(active: changes.busy && changes.snapshot != nil)
            }
            .zIndex(1)
            content
                .clipped()
        }
        .background(Color(white: 0.11))
        .task(id: RefreshKey(rev: model.dataRevision, ready: model.dataReady, conflicts: model.conflicts.count)) {
            await changes.refresh(model)
        }
        .task(id: RefreshKey(rev: model.dataRevision, ready: model.dataReady, conflicts: 0)) {
            // Let the change list land first; the owner walk is the slower of the two.
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            await hd.refresh(model)
        }
        .task(id: FilterKey(search: search, kind: kind, hideUnchanged: hideUnchanged,
                            rev: changes.snapshot?.revision ?? -1)) { await applyFilter() }
        .onChange(of: ObjectIdentifier(model.document)) { _, _ in
            changes.reset(); shown = []; shownRevision = -1; collapseSeeded = false; collapsed = []
        }
        .onChange(of: changes.snapshot?.revision, initial: true) { _, _ in seedCollapse() }
    }

    // MARK: Header

    private var header: some View {
        let snap = changes.snapshot
        let bundle = model.bundle
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("What this plug-in changes").font(.system(size: 16, weight: .semibold))
                    Text(bundle?.name ?? model.document.name)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if bundle?.isTotalConversion == true {
                    chip("Total Conversion", icon: "globe", color: .purple)
                        .help("This plug-in replaces the base game; its own data files are the base.")
                }
                Spacer()
            }
            if let snap {
                ChipFlow(spacing: 6) {
                    chip("\(snap.newCount) new", icon: "plus.circle.fill", color: .green)
                        .onTapGesture { kind = kind == .new ? .all : .new }
                    chip("\(snap.overrideCount) overridden", icon: "arrow.triangle.2.circlepath", color: novaAmber)
                        .onTapGesture { kind = kind == .override ? .all : .override }
                    if snap.identicalCount > 0 {
                        chip("\(snap.identicalCount) unchanged", icon: "equal.circle", color: .gray)
                            .help("Overrides whose data matches the base exactly")
                    }
                    chip("\(snap.hdCount) HD / 3D", icon: "cube", color: .cyan)
                    chip("\(snap.stringListEdits) string-list edits", icon: "textformat", color: .blue)
                    if !snap.conflicts.isEmpty || !model.conflicts.isEmpty {
                        chip("\(snap.conflicts.count) conflicts", icon: "exclamationmark.triangle.fill", color: .orange)
                    }
                    if let b = bundle, !b.otherFiles.isEmpty {
                        chip("\(b.otherFiles.count) bundle files", icon: "folder", color: .secondary)
                            .onTapGesture { model.tool = .bundleFiles }
                    }
                    if let b = bundle, !b.graphicsPacks.isEmpty {
                        chip("\(b.graphicsPacks.count) .nsx pack\(b.graphicsPacks.count == 1 ? "" : "s")", icon: "shippingbox", color: .cyan)
                    }
                }
            } else {
                HStack(spacing: 8) { SkeletonBar(width: 70, height: 18); SkeletonBar(width: 100, height: 18); SkeletonBar(width: 80, height: 18) }
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                    TextField("Search changes by name or id", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Picker("", selection: $kind) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Toggle("Hide unchanged", isOn: $hideUnchanged).toggleStyle(.checkbox).font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .contentShape(Capsule())
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !model.dataReady || changes.snapshot == nil {
            SkeletonList(rows: 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let snap = changes.snapshot, snap.totalChanges == 0, snap.conflicts.isEmpty {
            EditorEmptyState(icon: "checkmark.seal", title: "No changes yet",
                             subtitle: "This plug-in doesn't add or override anything.\nUse Resources to create or edit something.")
        } else {
            list
        }
    }

    private var list: some View {
        let conflicts = filteredConflicts()
        let hdRows = filteredHD()
        let categories = shown.filter { $0.category != .hd }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !conflicts.isEmpty { conflictsSection(conflicts) }
                ForEach(categories) { section in categorySection(section) }
                if (changes.snapshot?.hdCount ?? 0) > 0 { hdSection(hdRows) }
            }
            .padding(.bottom, 24)
        }
    }

    private func conflictsSection(_ rows: [ConflictRow]) -> some View {
        Section {
            if !collapsed.contains(Self.conflictsID) {
                ForEach(rows) { ConflictRowView(model: model, row: $0) }
            }
        } header: {
            sectionHeader(id: Self.conflictsID, title: "Conflicts", icon: "exclamationmark.triangle.fill",
                          tint: .orange, count: rows.count, detail: "defined by other enabled plug-ins")
        }
    }

    private func categorySection(_ section: ChangeSection) -> some View {
        let id = section.category.rawValue
        let open = !collapsed.contains(id)
        return Section {
            if open {
                ForEach(section.rows) { r in
                    ChangeRowView(model: model, row: r, detail: changes.details[r.key])
                }
            }
        } header: {
            sectionHeader(id: id, title: id, icon: section.category.icon, tint: novaAmber,
                          count: section.rows.count, detail: counts(section))
                .task(id: DetailKey(category: section.category, rev: changes.snapshot?.revision ?? -1, open: open)) {
                    guard open else { return }
                    await changes.loadDetails(section.category, model: model)
                }
        }
    }

    private func hdSection(_ rows: [HDAttachmentInfo]) -> some View {
        let id = ChangeCategory.hd.rawValue
        let resolved = hd.result != nil
        return Section {
            if !collapsed.contains(id) {
                if !resolved {
                    SkeletonList(rows: 4).frame(height: 120)
                } else if rows.isEmpty {
                    Text("No HD / 3D attachments match.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(14)
                } else {
                    ForEach(rows) { HDRowView(model: model, info: $0) }
                }
            }
        } header: {
            sectionHeader(id: id, title: "HD & 3D", icon: ChangeCategory.hd.icon, tint: .cyan,
                          count: resolved ? rows.count : (changes.snapshot?.hdCount ?? 0),
                          detail: "resolved to the planets, ships and weapons they upgrade")
        }
    }

    private func counts(_ s: ChangeSection) -> String {
        var parts: [String] = []
        if s.newCount > 0 { parts.append("\(s.newCount) new") }
        if s.overrideCount > 0 { parts.append("\(s.overrideCount) overridden") }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(id: String, title: String, icon: String, tint: Color, count: Int, detail: String) -> some View {
        let isCollapsed = collapsed.contains(id)
        return Button {
            if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.15))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Filtering

    private var lowerQuery: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func filteredConflicts() -> [ConflictRow] {
        guard let snap = changes.snapshot else { return [] }
        let q = lowerQuery
        if q.isEmpty { return snap.conflicts }
        return snap.conflicts.filter { $0.lowerName.contains(q) || String($0.key.id).contains(q) || $0.others.contains { $0.lowercased().contains(q) } }
    }

    private func filteredHD() -> [HDAttachmentInfo] {
        guard let r = hd.result else { return [] }
        let q = lowerQuery
        return r.attachments.filter { a in
            guard a.inLayer else { return false }
            if kind == .override { return false }   // HD art is always an addition
            if q.isEmpty { return true }
            return String(a.spriteID).contains(q) || a.owners.contains { $0.title.lowercased().contains(q) }
        }
    }

    private func applyFilter() async {
        guard let snap = changes.snapshot else { return }
        let q = lowerQuery, k = kind, hide = hideUnchanged
        if q.isEmpty, k == .all, !hide { shown = snap.sections; shownRevision = snap.revision; return }
        if shownRevision >= 0 { try? await Task.sleep(for: .milliseconds(120)) }
        if Task.isCancelled { return }
        let sections = snap.sections
        let out = await Task.detached(priority: .userInitiated) { () -> [ChangeSection] in
            sections.compactMap { s in
                let rows = s.rows.filter { r in
                    if k == .new, r.kind != .new { return false }
                    if k == .override, r.kind != .override { return false }
                    if hide, r.identical { return false }
                    return q.isEmpty || r.lowerName.contains(q) || String(r.key.id).contains(q)
                        || r.key.type.stringValue.lowercased().contains(q)
                }
                return rows.isEmpty ? nil : ChangeSection(category: s.category, rows: rows)
            }
        }.value
        if Task.isCancelled { return }
        shown = out; shownRevision = snap.revision
    }

    /// First time a snapshot lands: long sections start collapsed (graphics overrides can be 4k rows).
    private func seedCollapse() {
        guard !collapseSeeded, let snap = changes.snapshot else { return }
        collapseSeeded = true
        var openedOne = false
        for s in snap.sections where s.category != .hd {
            if s.rows.count > Self.autoCollapseAbove || (openedOne && s.rows.count > 25) {
                collapsed.insert(s.category.rawValue)
            } else { openedOne = true }
        }
        if snap.conflicts.count > Self.autoCollapseAbove { collapsed.insert(Self.conflictsID) }
    }
}

// MARK: - Rows

private struct KindBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(color).background(color.opacity(0.14), in: Capsule())
    }
}

/// One new / overridden resource.
struct ChangeRowView: View {
    let model: EditorModel
    let row: ChangeRow
    let detail: ChangeDetail?

    private static let graphicTypes: Set<NovaSwiftKit.FourCharCode> = [NovaType.rleD, NovaType.pict, NovaType.cicn, NovaType.ppat, NovaType.ppatAlt]

    private struct ThumbID: Hashable { let key: ResourceKey; let rev: Int; let isBase: Bool }

    var body: some View {
        Button { model.navigate(to: row.key) } label: {
            HStack(spacing: 10) {
                if Self.graphicTypes.contains(row.key.type) { thumbs }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name.isEmpty ? "—" : row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .foregroundStyle(row.name.isEmpty ? .tertiary : .primary)
                        if row.identical { KindBadge(text: "unchanged", color: .gray) }
                    }
                    if let detail {
                        if !detail.summary.isEmpty {
                            Text(detail.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    } else {
                        SkeletonBar(width: CGFloat(120 + (row.key.id * 13) % 140), height: 8)
                    }
                }
                Spacer(minLength: 8)
                Text(row.key.type.stringValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Text("#\(row.key.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
                KindBadge(text: row.kind.rawValue, color: row.kind == .new ? .green : novaAmber)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(row.key.type.stringValue) #\(row.key.id) in Resources")
    }

    @ViewBuilder private var thumbs: some View {
        let key = row.key, rev = model.dataRevision
        let new = model.document.layerResource(key.type, key.id)?.data
        let old = row.kind == .override ? model.base.resource(key.type, key.id)?.data : nil
        HStack(spacing: 4) {
            if let old {
                AsyncThumb(id: ThumbID(key: key, rev: rev, isBase: true), size: 38) {
                    ChangeThumbCache.shared.classic(type: key.type, id: key.id, data: old)
                }
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let new {
                AsyncThumb(id: ThumbID(key: key, rev: rev, isBase: false), size: 38) {
                    ChangeThumbCache.shared.classic(type: key.type, id: key.id, data: new)
                }
            }
        }
    }
}

/// One conflicting key.
private struct ConflictRowView: View {
    let model: EditorModel
    let row: ConflictRow
    var body: some View {
        Button { model.navigate(to: row.key) } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name.isEmpty ? "—" : row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(row.text).font(.system(size: 11)).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(row.key.type.stringValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Text("#\(row.key.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One HD / 3D attachment, resolved to the game objects it upgrades.
struct HDRowView: View {
    let model: EditorModel
    let info: HDAttachmentInfo

    private struct ThumbID: Hashable { let sprite: Int; let rev: Int }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                classicThumb
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                hdThumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if info.owners.count > 1 {
                        Text("Also: " + info.owners.dropFirst().prefix(4).map(\.title).joined(separator: ", ")
                             + (info.owners.count > 5 ? ", …" : ""))
                            .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                KindBadge(text: info.attachment.kind == .model ? "3D" : "HD", color: .cyan)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(info.owners.isEmpty ? "Nothing in the game draws this sprite" : "Open the HD / 3D tab")
    }

    private var subtitle: String {
        var parts = ["sprite #\(info.spriteID)", info.kindText,
                     ByteCountFormatter.string(fromByteCount: Int64(info.attachment.assetByteCount), countStyle: .file)]
        if info.owners.isEmpty { parts.append("no owner found") }
        return parts.joined(separator: " · ")
    }

    private var classicData: (type: NovaSwiftKit.FourCharCode, data: Data)? {
        let id = info.spriteID
        if let r = model.base.resource(NovaType.rleD, id) { return (NovaType.rleD, r.data) }
        if let r = model.base.resource(NovaType.pict, id) { return (NovaType.pict, r.data) }
        if let r = model.effective.resource(NovaType.rleD, id) { return (NovaType.rleD, r.data) }
        if let r = model.effective.resource(NovaType.pict, id) { return (NovaType.pict, r.data) }
        return nil
    }

    @ViewBuilder private var classicThumb: some View {
        if let c = classicData {
            AsyncThumb(id: ThumbID(sprite: info.spriteID, rev: model.dataRevision), size: 44) {
                ChangeThumbCache.shared.classic(type: c.type, id: info.spriteID, data: c.data, maxPixel: 88)
            }
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(width: 44, height: 44)
                .overlay(Text("—").foregroundStyle(.tertiary))
        }
    }

    @ViewBuilder private var hdThumb: some View {
        if info.attachment.kind == .model {
            ModelThumb(size: 44)
        } else if let blobID = info.attachment.blobID,
                  let blob = model.effective.resource(GraphicsEnhancementType.blob, blobID)?.data {
            let desc = info.attachment.descriptor, c = classicData, sprite = info.spriteID
            AsyncThumb(id: ThumbID(sprite: sprite, rev: model.dataRevision), size: 44) {
                ChangeThumbCache.shared.hdSprite(spriteID: sprite, png: blob, descriptor: desc, classic: c, maxPixel: 88)
            }
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(width: 44, height: 44)
                .overlay(Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange))
                .help("The descriptor's asset (NSbl) is missing")
        }
    }

    private func open() {
        if let t = info.target {
            model.navigate(to: t)
            model.requestedInspectorTab = SpecTab.hd.rawValue
        } else {
            let rle = ResourceKey(NovaType.rleD, info.spriteID), pict = ResourceKey(NovaType.pict, info.spriteID)
            if model.effective.resource(rle.type, rle.id) != nil { model.navigate(to: rle); model.requestedInspectorTab = SpecTab.hd.rawValue }
            else if model.effective.resource(pict.type, pict.id) != nil { model.navigate(to: pict); model.requestedInspectorTab = SpecTab.hd.rawValue }
            else { model.navigate(to: ResourceKey(GraphicsEnhancementType.descriptor, info.spriteID)) }
        }
    }
}
#endif
