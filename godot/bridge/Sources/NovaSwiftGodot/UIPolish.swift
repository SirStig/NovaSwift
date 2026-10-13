// Plain-Swift backend for the bridge's `// MARK: UI polish` section in NovaWorld.swift
// (same split as ClassicUI.swift): the About Nova text and the generic `dësc` dialog
// ids. The layout rule itself is the shared `DescDialogLayout`; the header mirrors
// the Apple app's `AboutNovaText` (app/NovaSwift/Launcher/Branding.swift).

import Foundation
import NovaSwiftKit

enum UIPolishBackend {
    static let repoPath = "github.com/SirStig/NovaSwift"

    /// Classic Mac `\r` line endings -> `\n`, and `<REG>` -> "EV Nova Community"
    /// (NovaSwift has no registration; `FUN_004d45a0`).
    static func descText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "<REG>", with: "EV Nova Community")
    }

    /// `AboutNovaText.text(game:)`.
    static func aboutText(descText raw: String, version: String) -> String {
        let header = """
        NovaSwift \(version)
             A free, unofficial port by Joshua Kac (SirStig).
             Not affiliated with or endorsed by Ambrosia Software or ATMOS.
             \(repoPath)


        """
        return header + descText(raw)
    }

    static func descInfo() -> String {
        let info: [String: Int] = [
            "textDialog": DescDialogLayout.textDialogID, "pictDialog": DescDialogLayout.pictDialogID,
            "top": DescDialogLayout.topPict, "body": DescDialogLayout.bodyPict,
            "bottom": DescDialogLayout.bottomPict, "backdrop": DescDialogLayout.pictBackdrop,
            "minText": DescDialogLayout.minTextHeight,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
