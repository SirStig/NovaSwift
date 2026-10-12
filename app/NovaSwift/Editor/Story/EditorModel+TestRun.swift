#if os(macOS)
import SwiftUI
import NovaSwiftKit

extension EditorModel {
    /// Apply (once) the setup a tool queued for the test run that just started.
    @MainActor func runSessionSetup(_ session: EditorTestSession) {
        let s = sessionSetup
        sessionSetup = nil
        s?(session)
    }

    /// Test-run a mission: start in a system where it is offered, force its
    /// availability bits, start it. Rides on the shell's `testRunRequest`.
    func requestMissionTest(_ id: Int) {
        let key = ResourceKey(NovaType.mission, id)
        var system: Int?
        let stel = intField("availStel", key, default: -1)
        if (128...2175).contains(stel) {
            system = effective.resources(of: NovaType.syst).first { SystRes($0).spobs.contains(stel) }?.id
        }
        var setBits: [Int] = [], clearBits: [Int] = []
        for t in ControlBitIndex.testBits(in: stringField("availBits", key)) {
            if t.negated { clearBits.append(t.bit) } else { setBits.append(t.bit) }
        }
        sessionSetup = { session in
            for b in setBits { session.setBit(b, "set") }
            for b in clearBits { session.setBit(b, "clear") }
            _ = session.startMission(id)
        }
        testRunRequest = EditorTestRunRequest(system: system)
    }
}
#endif
