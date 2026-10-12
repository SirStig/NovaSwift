#if os(macOS)
import SwiftUI
import NovaSwiftKit

private enum SidebarItem: Hashable {
    case tool(EditorModel.Tool)
    case type(NovaSwiftKit.FourCharCode)
}

/// Left column: project header, tools, and the searchable resource-type list.
struct EditorSidebar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var lint: EditorLintModel
    @State private var search = ""

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                model.tool == .resources ? model.selectedType.map { .type($0) } ?? .tool(.resources) : .tool(model.tool)
            },
            set: { new in
                guard let new else { return }
                switch new {
                case let .tool(t):
                    model.tool = t
                case let .type(t):
                    model.tool = .resources
                    if model.selectedType != t { model.selectedType = t; model.selection = nil }
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: selection) {
                Section("Tools") {
                    toolRow(.resources, "Resources", "tray.full")
                    toolRow(.galaxy, "Galaxy Map", "map")
                    toolRow(.system, "Star System", "sparkles")
                    toolRow(.story, "Story & Bits", "point.3.connected.trianglepath.dotted")
                    toolRow(.lint, "Validation", "checkmark.shield", badge: lint.errorCount + lint.warningCount,
                            badgeColor: lint.errorCount > 0 ? .red : .orange)
                    toolRow(.project, "Project & Export", "shippingbox")
                }
                Section {
                    ForEach(filteredStats) { s in typeRow(s) }
                } header: {
                    HStack {
                        Text("Resource Types")
                        Spacer()
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            searchField
        }
        .background(Color(white: 0.09))
    }

    private var filteredStats: [EditorTypeStat] {
        let all = store.cache.stats(model)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) || $0.type.stringValue.lowercased().contains(q) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill").foregroundStyle(novaAmber).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.document.name.isEmpty ? "Untitled" : model.document.name)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if model.document.isDirty {
                        Circle().fill(novaAmber).frame(width: 7, height: 7).help("Unsaved changes")
                    }
                }
                Text(model.fileURL?.lastPathComponent ?? "Not saved yet")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Filter types", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) { Divider() }
    }

    private func toolRow(_ tool: EditorModel.Tool, _ title: String, _ icon: String,
                         badge: Int = 0, badgeColor: Color = .secondary) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if badge > 0 {
                Text("\(badge)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(badgeColor, in: Capsule())
            }
        }
        .tag(SidebarItem.tool(tool))
    }

    private func typeRow(_ s: EditorTypeStat) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(s.name).lineLimit(1)
                Text(s.type.stringValue).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if s.new > 0 { miniBadge("+\(s.new)", .green).help("\(s.new) new in this plug-in") }
            if s.overridden > 0 { miniBadge("~\(s.overridden)", novaAmber).help("\(s.overridden) overridden") }
            Text("\(s.total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .tag(SidebarItem.type(s.type))
    }

    private func miniBadge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(c)
            .padding(.horizontal, 4).padding(.vertical, 1).background(c.opacity(0.15), in: Capsule())
    }
}
#endif
