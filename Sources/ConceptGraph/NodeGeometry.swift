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

extension NodeGeometry {
    func rim(at center: CGPoint, padding: CGFloat = 0) -> [CGPoint] {
        (0..<28).map { i in
            let angle = CGFloat(i) * 2 * .pi / 28
            let dx = cos(angle), dy = sin(angle)
            let r = reach(dx: dx, dy: dy) + padding
            return CGPoint(x: center.x + dx * r, y: center.y + dy * r)
        }
    }
}

enum GroupBoundary {
    static func outline(_ input: [CGPoint]) -> [CGPoint] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 2 else { return points }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // Inset every edge by the dragged shape's extent along its outward normal.
    // The remaining polygon contains all centers where the bubble fits inside the hull.
    static func centerRegion(outline: [CGPoint], rim: [CGPoint]) -> [CGPoint] {
        var region = outline
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let nx = b.y - a.y, ny = a.x - b.x
            let inset = rim.map { $0.x * nx + $0.y * ny }.max() ?? 0
            func excess(_ p: CGPoint) -> CGFloat { (p.x - a.x) * nx + (p.y - a.y) * ny + inset }
            guard var prev = region.last else { break }
            var clipped: [CGPoint] = []
            for p in region {
                let e = excess(p), last = excess(prev)
                if (e > 0) != (last > 0) {
                    let t = last / (last - e)
                    clipped.append(CGPoint(x: prev.x + t * (p.x - prev.x), y: prev.y + t * (p.y - prev.y)))
                }
                if e <= 0 { clipped.append(p) }
                prev = p
            }
            region = clipped
        }
        return region
    }

    static func pressure(at p: CGPoint, region: [CGPoint]) -> CGPoint {
        var outside = false
        var nearest = p
        var best = CGFloat.infinity
        for i in region.indices {
            let a = region[i], b = region[(i + 1) % region.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            guard length2 > 0 else { continue }
            let px = p.x - a.x, py = p.y - a.y
            outside = outside || px * dy - py * dx > 0
            let t = max(0, min(1, (px * dx + py * dy) / length2))
            let q = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < best { best = d; nearest = q }
        }
        return outside ? CGPoint(x: p.x - nearest.x, y: p.y - nearest.y) : .zero
    }
}
