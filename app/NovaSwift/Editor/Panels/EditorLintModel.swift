#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Runs `PluginLinter` off the main actor, debounced on document changes.
@MainActor
final class EditorLintModel: ObservableObject {
    @Published private(set) var issues: [LintIssue] = []
    @Published private(set) var isRunning = false
    @Published private(set) var byResource: [ResourceKey: [LintIssue]] = [:]

    private var task: Task<Void, Never>?
    private var generation = 0

    var errorCount: Int { issues.lazy.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.lazy.filter { $0.severity == .warning }.count }

    func schedule(_ model: EditorModel, delay: Duration = .milliseconds(700)) {
        task?.cancel()
        generation += 1
        let gen = generation
        let doc = model.document
        let layer = doc.layer, eff = doc.effective, base = doc.base
        isRunning = true
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .utility) {
                PluginLinter.lint(layer: layer, effective: eff, base: base)
            }.value
            guard let self, gen == self.generation, !Task.isCancelled else { return }
            self.issues = result
            self.byResource = Dictionary(grouping: result, by: \.key)
            self.isRunning = false
        }
    }
}
#endif
