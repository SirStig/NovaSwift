import SwiftUI
import NovaSwiftKit

/// The story intro shown when a new pilot is created: the scenario's `chär`
/// intro PICTs as a timed slideshow (tap or click to advance early), followed by
/// the intro `dësc` text. Rendered from the player's own data via the existing
/// `PICT` decoder. `onFinish` fires when the sequence completes or is skipped.
struct IntroSequenceView: View {
    @EnvironmentObject private var model: AppModel
    let scenario: CharRes
    var onFinish: () -> Void

    /// Slideshow pages: the intro PICTs, then an optional text page (id = -1).
    private struct Page: Identifiable { let id: Int; let pictID: Int?; let delay: Int }

    @State private var index = 0

    private var pages: [Page] {
        var p = scenario.introSlides.enumerated().map { i, s in
            Page(id: i, pictID: s.pictID, delay: max(2, min(s.delaySeconds, 7)))
        }
        if scenario.introTextID != nil, !introText.isEmpty {
            p.append(Page(id: 9_000, pictID: nil, delay: 0))   // text page (manual advance)
        }
        return p
    }

    private var introText: String {
        scenario.introTextID.map { model.data.game?.descText($0) ?? "" } ?? ""
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let page = pages.indices.contains(index) ? pages[index] : nil {
                pageView(page)
                    .id(index)
                    .transition(.opacity)
            }
            skipButton
        }
        .novaResponsive()
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .animation(.easeInOut(duration: 0.4), value: index)
        // Auto-advance picture pages after their delay; text waits for a tap.
        .task(id: index) {
            guard let page = pages.indices.contains(index) ? pages[index] : nil,
                  page.pictID != nil, page.delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(page.delay) * 1_000_000_000)
            if !Task.isCancelled { advance() }
        }
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        if let pid = page.pictID, let cg = pict(pid) {
            Image(decorative: cg, scale: 1)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .padding(20)
        } else if let pid = page.pictID {
            // PICT missing/undecodable — keep the sequence moving with a placeholder.
            Color.black.onAppear { _ = pid }
        } else {
            ScrollView {
                Text(introText)
                    .novaFont(.body)
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .padding(32)
                    .frame(maxWidth: 640)
            }
        }
    }

    private var skipButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(isLastPage ? "Begin" : "Skip") {
                    model.audio.play(.uiSelect); onFinish()
                }
                .buttonStyle(.plain)
                .novaFont(.button)
                .foregroundStyle(isLastPage ? .black : .white)
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(
                    Capsule().fill(isLastPage
                        ? LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .padding(24)
            }
        }
    }

    private var isLastPage: Bool { index >= pages.count - 1 }

    private func advance() {
        model.audio.play(.uiSelect)
        if index >= pages.count - 1 { onFinish() }
        else { index += 1 }
    }

    private func pict(_ id: Int) -> CGImage? {
        guard let d = model.data.game?.resources.resource(NovaType.pict, id)?.data,
              let sheet = try? PICT.decode(d) else { return nil }
        return sheet.makeCGImage()
    }
}
