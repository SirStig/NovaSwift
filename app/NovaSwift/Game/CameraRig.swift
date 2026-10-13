import CoreGraphics
import QuartzCore

/// How the in-flight camera frames the player's ship. Presentation only:
/// nothing here moves, steers or hits anything. `classic` is the original's
/// camera exactly (fixed, north up, the ship dead centre) and the default.
enum CameraView: String, Codable, CaseIterable, Identifiable {
    /// The original: north up, the ship centred.
    case classic
    /// North up, the view drifting ahead of the ship along its flight path.
    case lookAhead
    /// The view turns with the ship, which always points up the screen.
    case shipUp
    /// Live 3D only: the playfield tilted away from you and turning with the
    /// ship, the camera low behind it. Falls back to `shipUp` without live 3D.
    case chase

    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classic"
        case .lookAhead: return "Look ahead"
        case .shipUp: return "Ship up"
        case .chase: return "Chase (3D)"
        }
    }

    /// The views on offer: chase only when ships draw in live 3D.
    static func available(live3D: Bool) -> [CameraView] {
        live3D ? allCases : allCases.filter { $0 != .chase }
    }

    /// What actually draws: chase needs live 3D.
    func effective(live3D: Bool) -> CameraView { self == .chase && !live3D ? .shipUp : self }

    var rotatesWithShip: Bool { self == .shipUp || self == .chase }
}

/// The chase view's tilt: the playfield laid back like a table, seen in
/// perspective. Applied as a 3D transform on the scene's view layer, so the
/// game draws exactly as always and is only composited at an angle.
///
/// Coordinates are view points relative to the view's centre, y toward the
/// top of the screen. A point at height `y` sits `y·sin t` behind the screen
/// plane and is seen from `eye` points in front of it.
struct CameraTilt: Equatable {
    /// Tilt, radians (0 = flat, the classic view).
    var angle: Double
    /// Eye distance as a multiple of the view's height (perspective strength).
    static let eyeFactor = 1.2
    /// Tilts allowed, degrees. Past ~40° the far edge needs too much overscan.
    static let range: ClosedRange<Double> = 15...40

    var isFlat: Bool { abs(angle) < 1e-4 }

    /// How much bigger than the visible play area the view must be drawn so
    /// the tilted plane still covers it to the corners (width, height).
    var overscan: CGSize {
        guard !isFlat else { return CGSize(width: 1, height: 1) }
        let k2 = 2 * Self.eyeFactor, s = sin(angle), c = cos(angle)
        return CGSize(width: (k2 + s) / k2, height: (k2 + s) / (k2 * c))
    }

    /// Where a point of the (untilted) view lands on screen.
    func project(_ p: CGPoint, viewHeight h: CGFloat) -> CGPoint {
        guard !isFlat else { return p }
        let d = Self.eyeFactor * Double(h), y = Double(p.y)
        let k = d / (d + y * sin(angle))
        return CGPoint(x: Double(p.x) * k, y: y * cos(angle) * k)
    }

    /// The point of the (untilted) view drawn at screen point `q`.
    func unproject(_ q: CGPoint, viewHeight h: CGFloat) -> CGPoint {
        guard !isFlat else { return q }
        let d = Self.eyeFactor * Double(h), yq = Double(q.y)
        let denom = d * cos(angle) - yq * sin(angle)
        guard denom > 1e-6 else { return CGPoint(x: q.x, y: .greatestFiniteMagnitude) }   // above the horizon
        let y = yq * d / denom
        let k = d / (d + y * sin(angle))
        return CGPoint(x: Double(q.x) / k, y: y)
    }

    /// The layer transform drawing this tilt, about the layer's centre.
    /// - Parameters:
    ///   - anchorOffset: the layer's centre minus its anchor point, in layer
    ///     coordinates (AppKit anchors layer-backed views at a corner).
    ///   - yUp: whether the layer's y axis points up the screen (macOS) or
    ///     down (iOS).
    func layerTransform(bounds: CGSize, anchorOffset: CGPoint, yUp: Bool) -> CATransform3D {
        guard !isFlat else { return CATransform3DIdentity }
        var persp = CATransform3DIdentity
        persp.m34 = -1 / (CGFloat(Self.eyeFactor) * bounds.height)
        // Top of the screen recedes (−z): y up → rotate by −t; y down → +t.
        let r = CATransform3DMakeRotation(CGFloat(yUp ? -angle : angle), 1, 0, 0)
        let toCentre = CATransform3DMakeTranslation(-anchorOffset.x, -anchorOffset.y, 0)
        let back = CATransform3DMakeTranslation(anchorOffset.x, anchorOffset.y, 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DConcat(toCentre, r), persp), back)
    }
}

/// Eases the camera between views: its rotation and its offset from the ship.
/// One per scene; `classic` settles back to exactly the original framing.
struct CameraRig {
    /// Camera rotation (the camera node's `zRotation`), radians.
    private(set) var rotation: Double = 0
    /// Camera position minus the ship's, world units.
    private(set) var offset: CGVector = .zero
    /// Tilt currently drawn, radians (eases in and out with the chase view).
    private(set) var tilt: Double = 0

    /// Advance one frame.
    /// - Parameters:
    ///   - heading: the ship's (render) heading, radians clockwise from north.
    ///   - velocity: the ship's velocity, world units per second.
    ///   - viewSize: the visible play area in world units (zoom applied).
    ///   - tiltAngle: the chase tilt setting, radians.
    mutating func update(view: CameraView, heading: Double, velocity: CGVector, maxSpeed: Double,
                         viewSize: CGSize, tiltAngle: Double, dt: Double) {
        let dt = max(0, min(dt, 0.1))
        // Rotation: north up, or the ship's heading up (camera turned by −heading).
        let targetRot = view.rotatesWithShip ? -heading : 0
        var dr = (targetRot - rotation).truncatingRemainder(dividingBy: 2 * .pi)
        if dr > .pi { dr -= 2 * .pi }
        if dr < -.pi { dr += 2 * .pi }
        rotation += dr * min(1, dt * 7)
        rotation = rotation.truncatingRemainder(dividingBy: 2 * .pi)

        // Offset: none, ahead along the flight path, or ahead along the nose.
        let short = Double(min(viewSize.width, viewSize.height))
        var target = CGVector.zero
        switch view {
        case .classic, .shipUp:
            break
        case .lookAhead:
            let lead = 0.3 * short
            let frac = maxSpeed > 0 ? min(1, hypot(Double(velocity.dx), Double(velocity.dy)) / maxSpeed) : 0
            let len = hypot(Double(velocity.dx), Double(velocity.dy))
            if len > 1e-3 {
                target = CGVector(dx: Double(velocity.dx) / len * lead * frac, dy: Double(velocity.dy) / len * lead * frac)
            }
        case .chase:
            let lead = 0.24 * Double(viewSize.height)
            target = CGVector(dx: sin(heading) * lead, dy: cos(heading) * lead)
        }
        let follow = min(1, dt * (view == .chase ? 8 : 2.5))
        offset.dx += (target.dx - offset.dx) * follow
        offset.dy += (target.dy - offset.dy) * follow
        if view == .classic, abs(offset.dx) < 0.05, abs(offset.dy) < 0.05 { offset = .zero }
        if view == .classic, abs(rotation) < 1e-4 { rotation = 0 }

        let targetTilt = view == .chase ? tiltAngle : 0
        tilt += (targetTilt - tilt) * min(1, dt * 5)
        if abs(tilt - targetTilt) < 1e-4 { tilt = targetTilt }
    }

    /// Jump straight to the target framing (a new system, a launch).
    mutating func snap(view: CameraView, heading: Double, viewSize: CGSize, tiltAngle: Double) {
        rotation = 0; offset = .zero; tilt = 0
        // A long step settles every eased value at once.
        for _ in 0..<40 { update(view: view, heading: heading, velocity: .zero, maxSpeed: 0,
                                 viewSize: viewSize, tiltAngle: tiltAngle, dt: 0.1) }
    }
}
