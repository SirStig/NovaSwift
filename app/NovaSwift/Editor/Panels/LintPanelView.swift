#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Validation tool: PluginLinter results grouped by severity.
struct LintPanelView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var lint: EditorLintModel
    @ObservedObject var ui: EditorUIState
    @State private var filter: Filter = .all
    @State private var search = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", errors = "Errors", warnings = "Warnings", info = "Info"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Validation").font(.system(size: 15, weight: .semibold))
                if lint.isRunning { ProgressView().controlSize(.small) }
                Text("\(lint.errorCount) errors · \(lint.warningCount) warnings").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 280).labelsHidden()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Button { lint.schedule(model, delay: .milliseconds(10)) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-run now")
            }
            .padding(12)
            Divider()
            if shown.isEmpty {
                EditorEmptyState(icon: lint.issues.isEmpty ? "checkmark.seal" : "line.3.horizontal.decrease.circle",
                                 title: lint.issues.isEmpty ? "No problems found" : "Nothing matches the filter",
                                 subtitle: lint.issues.isEmpty ? "Only this plug-in's own resources are checked." : "")
            } else {
                List {
                    ForEach([LintIssue.Severity.error, .warning, .info], id: \.self) { sev in
                        let items = shown.filter { $0.severity == sev }
                        if !items.isEmpty {
                            Section(title(sev) + " (\(items.count))") {
                                ForEach(items) { i in row(i) }
                            }
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .background(Color(white: 0.11))
    }

    private var shown: [LintIssue] {
        let q = search.lowercased()
        return lint.issues.filter { i in
            switch filter {
            case .all: break
            case .errors: if i.severity != .error { return false }
            case .warnings: if i.severity != .warning { return false }
            case .info: if i.severity != .info { return false }
            }
            return q.isEmpty || i.message.lowercased().contains(q) || i.key.description.lowercased().contains(q)
        }
    }

    private func title(_ s: LintIssue.Severity) -> String {
        switch s { case .error: return "Errors"; case .warning: return "Warnings"; case .info: return "Info" }
    }

    private func row(_ i: LintIssue) -> some View {
        Button {
            ui.rawMode = false
            model.navigate(to: i.key)
            ui.focusField = i.fieldKey
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: i.severity == .error ? "xmark.octagon.fill" : i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(i.severity == .error ? Color.red : i.severity == .warning ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text("\(i.key.type.stringValue) #\(i.key.id)" + (i.fieldKey.map { " · \($0)" } ?? "") + " · \(i.code)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
#endif
