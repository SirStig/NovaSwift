import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The first-run **bring-your-own-data** setup assistant: a paged, graphical,
/// device-aware wizard that walks a complete newcomer from "what is this?" all
/// the way to a successful import, one small idea per screen.
///
/// It replaces the old terse launcher guide card + `ImportDataView` dialog and
/// is the single import surface everywhere (launcher first-run, and re-import
/// from Settings / the main menus via `startAtImport`). It renders inside the
/// game's own `NovaDialog` chrome so it matches every other dialog and degrades
/// gracefully before any game art exists.
///
/// Legal footing (mirrors `docs/GET_THE_DATA.md`): NovaSwift never bundles,
/// hosts, or generates EV Nova data or registration codes — it only *reads*
/// data the user already legally owns. The "I don't have it yet" branch points
/// out to legitimate community tools (Decoder Ring for owner registration, the
/// modern-macOS "EV Nova mod 4" build) and never to game data.
struct DataSetupWizard: View {
    @EnvironmentObject private var model: AppModel

    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}
    /// Callers that already have data (Settings / main-menu re-import) pass
    /// `true` to skip the whole guide and land straight on the Import step.
    var startAtImport: Bool

    @State private var step: WizardStep
    @State private var owns: Bool?
    @State private var device: SetupDevice = .current
    @State private var importing = false
    @State private var message: String?

    init(onClose: @escaping () -> Void = {}, startAtImport: Bool = false) {
        self.onClose = onClose
        self.startAtImport = startAtImport
        _owns = State(initialValue: startAtImport ? true : nil)
        _step = State(initialValue: startAtImport ? .importData : .welcome)
    }

    var body: some View {
        NovaDialog(title: step.title, width: 500, buttons: footerButtons) {
            VStack(alignment: .leading, spacing: 16) {
                if step != .success { progressHeader }
                stepBody
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .data],
                      allowsMultipleSelection: false,
                      onCompletion: handleImport)
    }

    // MARK: Flow / navigation

    /// The active linear path through the wizard, adapting to the ownership
    /// answer and the target device. Drives Back/Next and the progress dots.
    private var sequence: [WizardStep] {
        if startAtImport { return [.importData, .success] }
        switch owns {
        case .some(true):
            var s: [WizardStep] = [.welcome, .ownership, .locate]
            if device.isMobile { s.append(.transfer) }
            s += [.importData, .success]
            return s
        case .some(false):
            var s: [WizardStep] = [.welcome, .ownership, .acquireIntro, .acquireRegister, .acquireRun, .locate]
            if device.isMobile { s.append(.transfer) }
            s += [.importData, .success]
            return s
        case .none:
            return [.welcome, .ownership]
        }
    }

    private var currentIndex: Int { sequence.firstIndex(of: step) ?? 0 }

    private func goNext() {
        let seq = sequence
        guard let i = seq.firstIndex(of: step), i + 1 < seq.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = seq[i + 1] }
    }

    private func goBack() {
        let seq = sequence
        guard let i = seq.firstIndex(of: step), i > 0 else { onClose(); return }
        withAnimation(.easeInOut(duration: 0.2)) { step = seq[i - 1] }
    }

    /// Answer the ownership branch and advance to whatever now follows it.
    private func choose(_ value: Bool) {
        owns = value
        let seq = sequence
        if let i = seq.firstIndex(of: .ownership), i + 1 < seq.count {
            withAnimation(.easeInOut(duration: 0.2)) { step = seq[i + 1] }
        }
    }

    /// Switch the target device; if the current step falls out of the new path
    /// (e.g. Transfer only exists on mobile), fall back to Locate.
    private func setDevice(_ d: SetupDevice) {
        device = d
        if !sequence.contains(step) { step = .locate }
    }

    // MARK: Footer buttons (live on the dialog's control strip)

    private var footerButtons: [NovaDialogButton] {
        switch step {
        case .ownership:
            return [backButton]
        case .importData:
            return [backButton, NovaDialogButton(title: "Choose Data…", isDefault: true) { importing = true }]
        case .success:
            return [NovaDialogButton(title: "Play", isDefault: true) { onClose() }]
        default:
            return [backButton, NovaDialogButton(title: "Next", isDefault: true) { goNext() }]
        }
    }

    private var backButton: NovaDialogButton {
        let isFirst = currentIndex == 0
        return NovaDialogButton(title: isFirst ? "Close" : "Back") {
            isFirst ? onClose() : goBack()
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let src = try result.get().first else { return }
            let count = try DataImporter.importBase(from: src, into: model.data.importedBaseDir)
            model.data.reload()
            message = "Imported \(count) file(s)."
            if model.data.hasBaseData {
                withAnimation(.easeInOut(duration: 0.2)) { step = .success }
            }
        } catch {
            message = "That didn't work — \(error.localizedDescription). Try picking the whole game folder."
        }
    }

    // MARK: Progress header

    private var progressHeader: some View {
        let seq = sequence
        let i = currentIndex
        return HStack(spacing: 6) {
            ForEach(0..<seq.count, id: \.self) { n in
                Capsule()
                    .fill(n == i ? novaAmber : Color.white.opacity(0.18))
                    .frame(width: n == i ? 18 : 6, height: 6)
            }
            Spacer()
            Text("Step \(i + 1) of \(seq.count)")
                .novaFont(.caption, size: 11)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Per-step content

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .welcome:
            scaffold {
                AppLogo().frame(width: 96, height: 96)
            } text: {
                Text("**NovaSwift** is the engine — it runs EV Nova on your \(device.label). The game's data (ships, missions, art and sound) is copyrighted, so it isn't bundled in.")
                    .novaFont(.body)
                Text("You bring your own copy once — like slotting a cartridge into a console. Your files stay on this \(device.label) and are never uploaded or changed.")
                    .novaFont(.body).foregroundStyle(.secondary)
                Button {
                    model.audio.play(.uiSelect)
                    owns = true
                    withAnimation(.easeInOut(duration: 0.2)) { step = .importData }
                } label: {
                    Text("I already have my files ready — skip to import")
                        .novaFont(.caption, weight: .semibold)
                        .foregroundStyle(novaAmber)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

        case .ownership:
            scaffold {
                WizardIcon(systemName: "questionmark.circle.fill")
            } text: {
                Text("First things first — do you already have EV Nova, or the data files from it?")
                    .novaFont(.body)
                ownershipChoices
            }

        case .acquireIntro:
            scaffold {
                WizardIcon(systemName: "archivebox.fill")
            } text: {
                Text("EV Nova isn't sold in any store anymore — Ambrosia Software closed, and it was never released on Steam, GOG, or the App Store.")
                    .novaFont(.body)
                Text("If you owned it before, you can still register and run your own copy. NovaSwift can't give you the game — it only runs data you legally own.")
                    .novaFont(.body).foregroundStyle(.secondary)
                Text("Owning and registering EV Nova is fine; sharing its data files is not. NovaSwift never includes the game — it just reads yours.")
                    .novaFont(.caption).foregroundStyle(.tertiary)
            }

        case .acquireRegister:
            scaffold {
                WizardIcon(systemName: "key.fill")
            } text: {
                Text("**Decoder Ring**, released in 2023 by Ambrosia's former president Andrew Welch, creates a valid registration code for a copy you own. It's the community-blessed way to register on a modern Mac.")
                    .novaFont(.body)
                externalLink("Find Decoder Ring", url: NovaLinks.evstuff)
            }

        case .acquireRun:
            scaffold {
                WizardIcon(systemName: "desktopcomputer")
            } text: {
                Text("To play on a modern Mac, the community **“EV Nova mod 4”** build runs on current macOS, including Apple Silicon. Install it and launch it once.")
                    .novaFont(.body)
                Text("After that you'll have the game's **Nova Files** folder ready to import — that's the next step.")
                    .novaFont(.body).foregroundStyle(.secondary)
                externalLink("EV Nova community build", url: NovaLinks.evstuff)
            }

        case .locate:
            scaffold {
                FolderGlyph()
            } text: {
                locateText
                deviceSwitcher
            }

        case .transfer:
            scaffold {
                TransferGlyph(device: device)
            } text: {
                Text("Get the **Nova Files** folder onto your \(device.label):")
                    .novaFont(.body)
                bulletRow("dot.radiowaves.left.and.right", "AirDrop it from a Mac")
                bulletRow("folder", "Or drop it into the Files app (e.g. iCloud Drive)")
                bulletRow("square.and.arrow.up", "Or use Share → NovaSwift from another app")
                Text("It'll be waiting in the file browser on the next step.")
                    .novaFont(.caption).foregroundStyle(.secondary)
                deviceSwitcher
            }

        case .importData:
            scaffold {
                WizardIcon(systemName: "square.and.arrow.down.fill")
            } text: {
                importText
                if let message {
                    Text(message).novaFont(.caption).foregroundStyle(.secondary)
                }
                Text(model.data.status).novaFont(.caption).foregroundStyle(.tertiary)
                deviceSwitcher
            }

        case .success:
            scaffold {
                WizardIcon(systemName: "checkmark.seal.fill")
            } text: {
                Text("Your data is imported and lives on this \(device.label). Tap **Play** to launch EV Nova.")
                    .novaFont(.body)
                if let message {
                    Text(message).novaFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Device-specific copy kept out of the switch for readability.

    private var locateText: Text {
        switch device {
        case .mac:
            return Text("On your Mac, find your EV Nova app. Right-click it → **Show Package Contents** if needed. Inside is a folder called **Nova Files** — that folder, or any file ending in **.ndat**, is your data.")
        case .iPhone, .iPad:
            return Text("On a Mac or PC, open EV Nova and find its **Nova Files** folder — or the **.ndat** (Mac) / **.rez** (Windows) files inside it. You'll move those to your \(device.label) next.")
        }
    }

    private var importText: Text {
        switch device {
        case .mac:
            return Text("Tap **Choose Data…** below and pick your EV Nova **application folder** (or its Nova Files folder, or a single .ndat file). Picking the whole folder also grabs the original soundtrack and Charcoal/Geneva fonts.")
        case .iPhone, .iPad:
            return Text("Tap **Choose Data…** below and pick the folder — or .ndat/.rez file — you just moved over. Picking the whole game folder also grabs the soundtrack and fonts.")
        }
    }

    // MARK: Shared layout + small components

    /// A step's layout: a large centred graphic over left-aligned body text.
    private func scaffold<G: View, T: View>(@ViewBuilder graphic: () -> G,
                                            @ViewBuilder text: () -> T) -> some View {
        VStack(spacing: 16) {
            graphic()
                .frame(maxWidth: .infinity, minHeight: 130)
            VStack(alignment: .leading, spacing: 10) { text() }
                .novaFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ownershipChoices: some View {
        VStack(spacing: 10) {
            choiceButton(icon: "checkmark.circle.fill",
                         title: "Yes — I own it or have the files",
                         subtitle: "Go straight to importing") { choose(true) }
            choiceButton(icon: "questionmark.circle.fill",
                         title: "Not yet, or I'm not sure",
                         subtitle: "Show me how to get it") { choose(false) }
        }
        .padding(.top, 2)
    }

    private func choiceButton(icon: String, title: String, subtitle: String,
                              action: @escaping () -> Void) -> some View {
        Button { model.audio.play(.uiSelect); action() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(novaAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).novaFont(.body, weight: .bold).foregroundStyle(.white)
                    Text(subtitle).novaFont(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(novaAmber.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }

    private func bulletRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13)).foregroundStyle(novaAmber).frame(width: 18)
            Text(text).novaFont(.caption).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
    }

    private func externalLink(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right.square")
                .novaFont(.caption, weight: .semibold)
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(novaAmber))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var deviceSwitcher: some View {
        HStack(spacing: 8) {
            Text("On:").novaFont(.caption).foregroundStyle(.tertiary)
            ForEach(SetupDevice.allCases, id: \.self) { d in
                Button { model.audio.play(.uiSelect); setDevice(d) } label: {
                    Label(d.label, systemImage: d.icon)
                        .labelStyle(.titleAndIcon)
                        .novaFont(.caption, weight: d == device ? .bold : .regular)
                        .foregroundStyle(d == device ? .black : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(d == device ? novaAmber : Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

// MARK: - Step model

private enum WizardStep {
    case welcome, ownership, acquireIntro, acquireRegister, acquireRun
    case locate, transfer, importData, success

    /// Rendered as the dialog's amber title bar.
    var title: String {
        switch self {
        case .welcome:         return "Welcome to NovaSwift"
        case .ownership:       return "Do you have EV Nova?"
        case .acquireIntro:    return "Getting EV Nova"
        case .acquireRegister: return "Register your copy"
        case .acquireRun:      return "Get it running"
        case .locate:          return "Find your Nova Files"
        case .transfer:        return "Move the files over"
        case .importData:      return "Import your data"
        case .success:         return "You're all set"
        }
    }
}

/// The device the player is setting up on. Auto-detected, but switchable in the
/// guide so someone reading on their phone can follow the Mac steps and vice
/// versa. Replaces the old two-case `GuidePlatform`.
enum SetupDevice: CaseIterable {
    case mac, iPhone, iPad

    var isMobile: Bool { self != .mac }

    var label: String {
        switch self {
        case .mac:    return "Mac"
        case .iPhone: return "iPhone"
        case .iPad:   return "iPad"
        }
    }

    var icon: String {
        switch self {
        case .mac:    return "laptopcomputer"
        case .iPhone: return "iphone"
        case .iPad:   return "ipad"
        }
    }

    static var current: SetupDevice {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }
}

// MARK: - Illustration glyphs

/// A large SF Symbol in the amber accent inside a soft glowing disc — the
/// default step illustration when no bespoke drawing is warranted.
private struct WizardIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [.white, novaAmber],
                                            startPoint: .top, endPoint: .bottom))
            .frame(width: 118, height: 118)
            .background(Circle().fill(novaAmber.opacity(0.12)))
            .overlay(Circle().strokeBorder(novaAmber.opacity(0.35), lineWidth: 1))
    }
}

/// A drawn amber folder labelled "Nova Files" with two data-file chips beneath —
/// so the player recognises exactly what they're hunting for.
private struct FolderGlyph: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 74))
                    .foregroundStyle(LinearGradient(colors: [novaAmber, novaAmber.opacity(0.72)],
                                                    startPoint: .top, endPoint: .bottom))
                Text("Nova Files")
                    .novaFont(.caption, weight: .bold, size: 10)
                    .foregroundStyle(.black.opacity(0.75))
                    .offset(y: 9)
            }
            HStack(spacing: 8) {
                DataFileChip(ext: ".ndat")
                DataFileChip(ext: ".rez")
            }
        }
    }
}

/// A small file glyph with its extension — the individual data files a player
/// might see instead of (or inside) the Nova Files folder.
private struct DataFileChip: View {
    let ext: String
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "doc.fill")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.85))
            Text(ext).novaFont(.caption, weight: .bold, size: 9).foregroundStyle(novaAmber)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
    }
}

/// Mac → (AirDrop) → phone/tablet: the "move your files over" motif.
private struct TransferGlyph: View {
    let device: SetupDevice
    var body: some View {
        HStack(spacing: 14) {
            deviceImage("laptopcomputer")
            VStack(spacing: 3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22)).foregroundStyle(novaAmber)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            }
            deviceImage(device == .iPad ? "ipad" : "iphone")
        }
    }

    private func deviceImage(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 46))
            .foregroundStyle(LinearGradient(colors: [.white, novaAmber],
                                            startPoint: .top, endPoint: .bottom))
    }
}
