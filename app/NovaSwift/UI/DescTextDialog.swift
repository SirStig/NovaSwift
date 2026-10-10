import SwiftUI
import NovaSwiftKit

/// The original's generic `dësc` reader (see `DescDialogLayout`): text-only
/// on PICT 8524/8525/8526 sized to the text, or the `dësc` picture beside the
/// text on backdrop PICT 8527. Item rects come from DITL 3003/3004, so a TC's
/// own layout takes effect. White text on black, one OK button (item 1).
///
/// With modern dialog chrome (or before any data import) it falls back to the
/// port's `NovaDialog`.
struct DescTextDialog: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let text: String
    /// The `dësc` graphic (PICT id); < 128 or nil = text only.
    var graphicID: Int? = nil
    let onClose: () -> Void

    @State private var textHeight: CGFloat = 0

    var body: some View {
        if !model.settings.modernDialogs, let graphics = model.uiGraphics, let game = model.data.game,
           let layout = authenticLayout(game: game) {
            authentic(graphics: graphics, layout: layout)
        } else {
            NovaDialog(title: title.isEmpty ? "Mission" : title, width: 480,
                       buttons: [NovaDialogButton(title: "OK", isDefault: true) { onClose() }]) {
                Text(text)
                    .novaFont(.body)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Layout {
        let size: CGSize
        let ok: CGRect, text: CGRect, picture: CGRect?
        let withPicture: Bool
    }

    private func rect(_ r: NovaRect) -> CGRect {
        CGRect(x: r.left, y: r.top, width: r.width, height: r.height)
    }

    private func authenticLayout(game: NovaGame) -> Layout? {
        let withPicture = DescDialogLayout.usesPicture(graphicID: graphicID)
            && game.resources.resource(NovaType.pict, graphicID ?? 0) != nil
        let id = withPicture ? DescDialogLayout.pictDialogID : DescDialogLayout.textDialogID
        guard let dlg = game.dialog(id), dlg.items.items.count >= 3 else { return nil }
        let items = dlg.items.items
        let size = dlg.window.map { CGSize(width: $0.bounds.width, height: $0.bounds.height) }
            ?? CGSize(width: 441, height: 313)
        return Layout(size: size, ok: rect(items[0].rect), text: rect(items[2].rect),
                      picture: withPicture ? rect(items[1].rect) : nil, withPicture: withPicture)
    }

    @ViewBuilder private func authentic(graphics: SpaceportGraphics, layout: Layout) -> some View {
        let shrink: CGFloat = layout.withPicture ? 0 : CGFloat(DescDialogLayout.shrink(
            textHeight: Int(textHeight.rounded(.up)), textItemHeight: Int(layout.text.height)))
        let size = CGSize(width: layout.size.width, height: layout.size.height - shrink)
        GeometryReader { geo in
            let scale = novaFrameScale(frame: size, viewport: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                backdrop(graphics, layout: layout, height: size.height)
                if let pr = layout.picture, let id = graphicID, let pict = graphics.pict(id) {
                    Image(decorative: pict, scale: 1)
                        .frame(width: pr.width, height: pr.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: pr.minX, y: pr.minY)
                }
                textItem(layout.text, height: layout.text.height - shrink)
                NovaButton(graphics: graphics, title: "OK",
                           width: max(0, layout.ok.width - 26)) { onClose() }
                    .offset(x: layout.ok.minX, y: layout.ok.minY - shrink)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .cursorScaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private func backdrop(_ g: SpaceportGraphics, layout: Layout, height: CGFloat) -> some View {
        if layout.withPicture {
            if let back = g.pict(DescDialogLayout.pictBackdrop) {
                Image(decorative: back, scale: 1)
            }
        } else {
            let top = g.pict(DescDialogLayout.topPict)
            let topH = CGFloat(top?.height ?? 0)
            if let body = g.pict(DescDialogLayout.bodyPict) {
                Image(decorative: body, scale: 1).offset(y: topH)
            }
            if let top { Image(decorative: top, scale: 1) }
            if let bottom = g.pict(DescDialogLayout.bottomPict) {
                Image(decorative: bottom, scale: 1).offset(y: height - CGFloat(bottom.height))
            }
        }
    }

    /// Item 3: white wrapped text on black, scrolling when it overflows.
    private func textItem(_ r: CGRect, height: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .novaFont(.body, size: 12)
                .foregroundStyle(.white)
                .frame(width: r.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { p in
                    Color.clear.onAppear { textHeight = p.size.height }
                        .onChange(of: p.size.height) { _, h in textHeight = h }
                })
        }
        .cursorScrollable()
        .frame(width: r.width, height: max(0, height))
        .background(Color.black)
        .offset(x: r.minX, y: r.minY)
    }
}
