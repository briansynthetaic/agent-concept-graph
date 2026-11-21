import AppKit

enum ViewerPreferences {
    // The standalone renderer and the app bundle share one preferences domain.
    private static let domain = "local.concept-graph.viewer"
    static let defaults = Bundle.main.bundleIdentifier == domain ? UserDefaults.standard : UserDefaults(suiteName: domain)!
}

enum NodeShape: Int, CaseIterable {
    case circle, rectangle

    func geometry(_ radius: CGFloat) -> NodeGeometry { NodeGeometry(shape: self, radius: radius) }
}

struct NodeGeometry {
    let shape: NodeShape
    let radius: CGFloat
    var halfWidth: CGFloat { shape == .circle ? radius : radius * 1.45 }
    var halfHeight: CGFloat { shape == .circle ? radius : radius * 0.82 }
    var enclosingRadius: CGFloat { shape == .circle ? radius : hypot(halfWidth, halfHeight) }
    var labelWidth: CGFloat { shape == .circle ? radius * 1.56 : halfWidth * 2 - 16 }
    private var corner: CGFloat { radius * 0.32 }

    func path(at center: CGPoint, padding: CGFloat = 0) -> CGPath {
        let rect = CGRect(x: center.x - halfWidth - padding, y: center.y - halfHeight - padding,
                          width: 2 * (halfWidth + padding), height: 2 * (halfHeight + padding))
        if shape == .circle { return CGPath(ellipseIn: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: corner + padding, cornerHeight: corner + padding, transform: nil)
    }

    /// Intersection of a ray from the center with a straight side or the rounded corner.
    func reach(dx: CGFloat, dy: CGFloat) -> CGFloat {
        guard shape == .rectangle else { return radius }
        let length = max(hypot(dx, dy), 0.000001)
        let x = abs(dx) / length, y = abs(dy) / length
        let side = min(halfWidth / max(x, 0.000001), halfHeight / max(y, 0.000001))
        let cx = halfWidth - corner, cy = halfHeight - corner
        if side * x <= cx || side * y <= cy { return side }
        let projection = cx * x + cy * y
        return projection + sqrt(max(0, corner * corner - pow(cx * y - cy * x, 2)))
    }

    func contains(dx: CGFloat, dy: CGFloat) -> Bool {
        hypot(dx, dy) <= reach(dx: dx, dy: dy)
    }
}
