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
///
/// This is the standalone sheet (Settings ▸ Support). The same content lives in
/// the developer console's **Report** tab — both are `BugReportPanel`.
struct BugReportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    /// Live-session context for the self-test (nil outside flight, which is fine
    /// — the data-set and pilot checks still run).
    var debug: DebugController?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                BugReportPanel(debug: debug, wide: geo.size.width >= 700)
            }
            .background(devPanelBackground.ignoresSafeArea())
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 760, minHeight: 520, idealHeight: 680, maxHeight: 900)
        #endif
    }
}

/// Near-black panel colour shared by the standalone bug-report sheet.
let devPanelBackground = Color(red: 0.045, green: 0.05, blue: 0.06)

/// The bug-report form + results, usable both as the Settings sheet's content
/// and as the console's Report tab. Two columns when `wide`:
///  * left — "Describe it" (framed editor, character count, Create Report) and
///    "What gets included" (icon list + privacy note);
///  * right — the freshly built "Report ready" card (file, path, content pills,
///    Show in folder / Share / Copy path, the summary text) above "Previous
///    reports" (cards with date + size, reveal/copy, two-press delete).
struct BugReportPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    var debug: DebugController?
    var wide: Bool

    @State private var note = ""
    @State private var bundle: BugReport.Bundle?
    @State private var building = false
    @State private var failure: String?
    @State private var previous: [URL] = []
    /// The report whose delete button has been pressed once.
    @State private var confirmDelete: URL?

    private static let included: [(symbol: String, title: String, detail: String)] = [
        ("doc.text", "Your description", "The note you write above"),
        ("person.crop.circle", "Pilot save", "Ship, outfits, cargo, missions, legal record, story bits"),
        ("list.bullet.rectangle", "Game log", "The last 15 minutes of the log, control-bit writes attributed to their source"),
        ("checkmark.seal.fill", "Self-test results", "The diagnostics battery, run just now"),
        ("info.circle", "Build & system info", "App version, device, OS and which plug-ins are enabled"),
    ]

    var body: some View {
        ScrollView {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) { describeCard; includedCard }
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 12) { resultColumn }
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        describeCard
                        resultColumn
                        includedCard
                    }
                }
            }
            .padding(14)
        }
        .onAppear { refreshPrevious() }
    }

    // MARK: Describe

    private var describeCard: some View {
        DevCard("Describe it", symbol: "pencil") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What happened? What did you expect instead?\nWhere were you, what were you flying, what did you click?",
                          text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(5...12)
                    .font(.system(size: 14 * devFontScale))
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(note.isEmpty ? devHairline : devConsoleGreen.opacity(0.6)))
                HStack(spacing: 10) {
                    Text("\(note.count) characters")
                        .font(.system(size: 11 * devFontScale))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 6)
                    createButton
                }
                Text("A rough note is fine. The details that are hard to describe (where you were, what you were flying, which story flags are set) are collected automatically.")
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5 * devFontScale))
                        .foregroundStyle(devConsoleOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var createButton: some View {
        CursorButton(action: build) {
            HStack(spacing: 8) {
                if building {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 13 * devFontScale, weight: .semibold))
                }
                Text(building ? "Collecting…" : "Create Report")
                    .font(.system(size: 14 * devFontScale, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(devConsoleGreen.opacity(building ? 0.55 : 1)))
            .contentShape(Rectangle())
        }
        .disabled(building)
    }

    // MARK: Included

    private var includedCard: some View {
        DevCard("What gets included", symbol: "doc.zipper", accent: devConsoleBlue) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.included.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        DevIconTile(symbol: item.symbol, tint: devConsoleBlue, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title)
                                .font(.system(size: 13 * devFontScale, weight: .medium))
                            Text(item.detail)
                                .font(.system(size: 11 * devFontScale))
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 13 * devFontScale))
                        .foregroundStyle(devConsoleGreen)
                    Text("No game data is included. None of your imported EV Nova files, artwork or sound is copied into the report; plug-ins are listed by name only.")
                        .font(.system(size: 11 * devFontScale))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder private var resultColumn: some View {
        if let bundle {
            readyCard(bundle)
        }
        previousCard
    }

    private func readyCard(_ bundle: BugReport.Bundle) -> some View {
        DevCard("Report ready", symbol: "checkmark.circle.fill", highlight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 20 * devFontScale))
                        .foregroundStyle(devConsoleGreen)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bundle.url.lastPathComponent)
                            .font(.system(size: 12 * devFontScale, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Text(bundle.url.deletingLastPathComponent().path)
                            .font(.system(size: 10 * devFontScale, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if !bundle.files.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 5, alignment: .leading)],
                              alignment: .leading, spacing: 5) {
                        ForEach(bundle.files, id: \.self) { name in
                            DevPill(text: name, color: devConsoleBlue, symbol: "doc.text")
                        }
                    }
                }
                HStack(spacing: 6) {
                    revealChip(bundle.url, title: "Show in folder")
                    DevChip(title: "Copy path", symbol: "doc.on.doc") { DevClipboard.copy(bundle.url.path) }
                    Spacer(minLength: 0)
                    DevChip(title: "Start over", symbol: "arrow.counterclockwise",
                            tint: .white.opacity(0.65)) {
                        self.bundle = nil
                        failure = nil
                    }
                }
                #if os(tvOS)
                Text("Pull the file off the device from the path above.")
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.45))
                #endif
                DevCaption(text: "What you're sending")
                ScrollView {
                    Text(bundle.summary)
                        .font(.system(size: 10 * devFontScale, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                        .padding(8)
                }
                .frame(maxHeight: 170)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(devHairline))
                Text("Attach it to TestFlight feedback, or send it however is easiest.")
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    /// "Show in folder" on the Mac, a share sheet on iOS, nothing on tvOS
    /// (which has neither — the path is shown instead).
    @ViewBuilder private func revealChip(_ url: URL, title: String) -> some View {
        #if os(macOS)
        DevChip(title: title, symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #elseif os(iOS)
        ShareLink(item: url) {
            DevChipLabel(title: "Share report", symbol: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        #else
        EmptyView()
        #endif
    }

    private var previousCard: some View {
        DevCard("Previous reports", symbol: "clock", accent: devConsoleOrange) {
            VStack(spacing: 8) {
                if previous.isEmpty {
                    DevEmptyState(kind: .reports, title: "No reports yet",
                                  hint: "Reports you create show up here, with the folder they were saved in.")
                } else {
                    ForEach(previous.prefix(8), id: \.self) { url in
                        previousRow(url)
                    }
                }
            }
        }
    }

    private func previousRow(_ url: URL) -> some View {
        let meta = Self.metadata(url)
        let confirming = confirmDelete == url
        return HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 18 * devFontScale))
                .foregroundStyle(devConsoleOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12 * devFontScale, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 10 * devFontScale))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            #if os(macOS)
            DevIconButton(symbol: "folder", help: "Show in folder", tint: devConsoleGreen) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            #elseif os(iOS)
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11 * devFontScale, weight: .semibold))
                    .frame(width: 28 * devFontScale, height: 26 * devFontScale)
                    .foregroundStyle(devConsoleGreen)
                    .background(RoundedRectangle(cornerRadius: 8).fill(devConsoleGreen.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(devConsoleGreen.opacity(0.18)))
            }
            .buttonStyle(.plain)
            #endif
            #if !os(tvOS)
            DevIconButton(symbol: "doc.on.doc", help: "Copy path", tint: devConsoleBlue) {
                DevClipboard.copy(url.path)
            }
            #endif
            if confirming {
                DevChip(title: "Delete?", symbol: "trash.fill", tint: devConsoleRed, filled: true) {
                    delete(url)
                }
            } else {
                DevIconButton(symbol: "trash", help: "Delete this report (press twice)", tint: devConsoleRed) {
                    confirmDelete = url
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(devHairline))
    }

    // MARK: Actions

    private static func metadata(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        let bytes = Int64(values?.fileSize ?? 0)
        return "\(date)  ·  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func refreshPrevious() {
        previous = BugReport.existingReports()
        if let confirmDelete, !previous.contains(confirmDelete) { self.confirmDelete = nil }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        confirmDelete = nil
        refreshPrevious()
    }

    private func build() {
        guard !building else { return }
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
            refreshPrevious()
        }
    }
}

/// The console's **Report** tab: `BugReportPanel` on the console's own dark
/// surface, wired to the live `DebugController` so the bundled self-test can
/// also check the flight session.
struct DevReportPane: View {
    @EnvironmentObject private var model: AppModel
    let debug: DebugController
    var wide: Bool

    var body: some View {
        BugReportPanel(debug: debug, wide: wide)
            .environmentObject(model.pilot)
    }
}
