import Foundation
import SceneKit
import NovaSwiftKit

/// What the demo pack upgrades, and with what.
enum DemoContent {
    struct Ship {
        /// The hull it stands in for (its base sprite is what gets upgraded).
        let shipID: Int
        let file: String
        let build: (MaterialKit) -> SCNNode
        var bake = GraphicsEnhancement.BakeSettings()
    }

    static let ships: [Ship] = [
        Ship(shipID: 128, file: "skiff", build: ShipDesigns.skiff),
        Ship(shipID: 133, file: "courier", build: ShipDesigns.courier),
        Ship(shipID: 141, file: "destroyer", build: ShipDesigns.destroyer),
    ]
}
