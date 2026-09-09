import SwiftUI

/// "Report a Bug": describe what happened, then hand a diagnostic bundle to the
/// share sheet (TestFlight feedback, mail, Discord, wherever).
///
/// The point of this screen is that a bug report should carry the *state*, not
/// just a screenshot and a sentence. `BugReport.make` assembles the pilot save,
/// the recent log (including every control-bit write and what set it) and the
/// self-test results; all this view does is collect the one thing the app can't
/// know — what the player expected to happen — and get the file off the device.
///
/// The finished summary is shown before sharing on purpose: the reporter can see
/// exactly what they're about to send, rather than being asked to trust it.
struct BugReportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    /// Live-session context for the self-test (nil outside flight, which is fine
    /// — the data-set and pilot checks still run).
    var debug: DebugController?
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var bundle: BugReport.Bundle?
    @State private var building = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let bundle {
                    readySection(bundle)
                    summarySection(bundle)
                } else {
                    describeSection
                    contentsSection
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 680, maxHeight: 900)
        #endif
    }

    // MARK: Compose

    private var describeSection: some View {
        Section {
            TextField("What happened? What did you expect instead?",
                      text: $note, axis: .vertical)
                .lineLimit(4...10)
                .font(.system(size: 14))
            Button {
                build()
            } label: {
                HStack(spacing: 8) {
                    if building { ProgressView().controlSize(.small) }
                    Text(building ? "Collecting…" : "Create Report")
                        .fontWeight(.semibold)
                }
            }
            .disabled(building)
        } header: {
            Text("Describe it")
        } footer: {
            Text("A rough note is fine — the details that are hard to describe (where you were, what you were flying, which story flags are set) are collected automatically.")
        }
    }

    private var contentsSection: some View {
        Section {
            row("doc.text", "Your description")
            row("person.crop.square", "Pilot save — ship, outfits, cargo, missions, legal record, story bits")
            row("list.bullet.rectangle", "Last 15 minutes of the game log")
            row("checkmark.seal", "Self-test results")
            row("info.circle", "App version, device, OS, and which plug-ins are enabled")
        } header: {
            Text("What gets included")
        } footer: {
            Text("No game data is included — none of your imported EV Nova files, artwork or sound is copied into the report. Plug-ins are listed by name only.")
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13))
    }

    // MARK: Share

    private func readySection(_ bundle: BugReport.Bundle) -> some View {
        Section {
            #if os(tvOS)
            // No share sheet on tvOS — surface the path so it can be pulled off
            // the device another way.
            Text(bundle.url.path).font(.system(size: 11, design: .monospaced))
            #else
            ShareLink(item: bundle.url) {
                Label("Share Report", systemImage: "square.and.arrow.up")
                    .fontWeight(.semibold)
            }
            #endif
            Button("Start Over") {
                self.bundle = nil
                failure = nil
            }
        } header: {
            Text("Ready")
        } footer: {
            Text("Attach it to TestFlight feedback, or send it however is easiest. It's also saved in the app's Documents/Diagnostics folder as \(bundle.url.lastPathComponent).")
        }
    }

    private func summarySection(_ bundle: BugReport.Bundle) -> some View {
        Section {
            ScrollView {
                Text(bundle.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
            }
            .frame(maxHeight: 320)
        } header: {
            Text("What you're sending")
        }
    }

    private func build() {
        building = true
        failure = nil
        model.audio.play(.uiSelect)
        Task {
            do {
                bundle = try await BugReport.make(note: note, model: model,
                                                  pilot: pilot, debug: debug)
            } catch {
                failure = "Couldn't build the report: \(error.localizedDescription)"
            }
            building = false
        }
    }
}
