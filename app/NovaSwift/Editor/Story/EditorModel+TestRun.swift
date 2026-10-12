#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// "Run the game with this set up": which system to start in, bits to force,
/// and a mission to start once the sandbox session is running.
struct TestRunRequest: Equatable, Identifiable {
    let id = UUID()
    var system: Int?
    var mission: Int?
    var setBits: [Int] = []
    var clearBits: [Int] = []

    @MainActor func apply(to session: EditorTestSession) {
        for b in setBits { session.setBit(b, "set") }
        for b in clearBits { session.setBit(b, "clear") }
        if let m = mission { _ = session.startMission(m) }
    }
}

extension EditorModel {
    /// Test-run a mission: start in a system where it is offered, force its
    /// availability bits, start it.
    func requestMissionTest(_ id: Int) {
        let key = ResourceKey(NovaType.mission, id)
        var req = TestRunRequest(mission: id)
        let stel = intField("availStel", key, default: -1)
        let systems = effective.resources(of: NovaType.syst)
        if (128...2175).contains(stel) {
            req.system = systems.first { SystRes($0).spobs.contains(stel) }?.id
        }
        let avail = stringField("availBits", key)
        for t in ControlBitIndex.testBits(in: avail) {
            if t.negated { req.clearBits.append(t.bit) } else { req.setBits.append(t.bit) }
        }
        testRunRequest = req
    }
}

/// Zero-size view the shell embeds so it re-renders when a tool posts a request.
struct TestRunRequestWatcher: View {
    @ObservedObject var model: EditorModel
    var onRequest: (TestRunRequest) -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.testRunRequest) { _, req in
                guard let req else { return }
                model.testRunRequest = nil
                onRequest(req)
            }
    }
}
#endif
