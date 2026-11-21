import Foundation

/// A small force-directed layout in the style of d3-force: velocity Verlet
/// integration with a cooling `alpha`. Agents never supply coordinates; this is
/// what turns a list of concepts and relationships into a picture.
///
/// Everything is deterministic (no randomness), so the same graph always opens
/// with the same arrangement.
final class ForceLayout {
    struct Node {
        var x: Double
        var y: Double
        var vx = 0.0
        var vy = 0.0
        var radius: Double
        /// Index of the node's group, or -1.
        var group: Int
        /// Pinned nodes are held where the user dropped them.
        var pinned = false
    }

    struct Link {
        var source: Int
        var target: Int
        /// Extra room to leave between the two bubbles, e.g. for an arrow label.
        var gap: Double
    }

    private struct Spring {
        var source: Int
        var target: Int
        var distance: Double
        var strength: Double
        var bias: Double
    }

    var nodes: [Node] = []
    private var springs: [Spring] = []
    private var groupCount = 0

    private(set) var alpha = 1.0
    /// Raised while the user drags a bubble so the rest of the graph keeps responding.
    var alphaTarget = 0.0
    private let alphaMin = 0.001
    private let alphaDecay = 1 - pow(0.001, 1.0 / 300.0)
    private let velocityDecay = 0.6

    // Tuning. Distances are in graph units, where a mid-sized bubble has a radius of about 46.
    private let chargePerRadius = 24.0
    private let crossGroupCharge = 1.4
    private let baseGap = 54.0
    private let crossGroupGap = 34.0
    private let collisionPadding = 16.0
    private let gravityX = 0.026
    private let gravityY = 0.075
    private let cohesion = 0.16
    private let territoryPadding = 26.0

    var isActive: Bool { alpha >= alphaMin || alphaTarget > 0 }

    func setLinks(_ links: [Link]) {
        var degree = [Int](repeating: 0, count: nodes.count)
        for link in links {
            degree[link.source] += 1
            degree[link.target] += 1
        }
        springs = links.map { link in
            let a = nodes[link.source], b = nodes[link.target]
            let sameGroup = a.group == b.group
            let distance = a.radius + b.radius + baseGap + link.gap + (sameGroup ? 0 : crossGroupGap)
            let ds = Double(degree[link.source]), dt = Double(degree[link.target])
            let strength = (sameGroup ? 1.0 : 0.4) / min(ds, dt)
            return Spring(source: link.source, target: link.target, distance: distance,
                          strength: strength, bias: ds / (ds + dt))
        }
        groupCount = (nodes.map(\.group).max() ?? -1) + 1
    }

    /// Wakes the simulation up after a change.
    func reheat(_ value: Double) {
        alpha = max(alpha, value)
    }

    /// Runs to rest. Used before the window first appears so the user never sees the tangle.
    func settle(maxTicks: Int = 450) {
        alpha = 1
        var ticks = 0
        while alpha >= alphaMin && ticks < maxTicks {
            tick()
            ticks += 1
        }
    }

    func tick() {
        alpha += (alphaTarget - alpha) * alphaDecay
        let count = nodes.count
        guard count > 0 else { return }

        nodes.withUnsafeMutableBufferPointer { n in
            // Springs along relationships.
            for spring in springs {
                let s = spring.source, t = spring.target
                var dx = n[t].x + n[t].vx - n[s].x - n[s].vx
                var dy = n[t].y + n[t].vy - n[s].y - n[s].vy
                if dx == 0 && dy == 0 { dx = 0.01 * Double(s + 1); dy = 0.01 * Double(t + 1) }
                let length = (dx * dx + dy * dy).squareRoot()
                let k = (length - spring.distance) / length * alpha * spring.strength
                dx *= k
                dy *= k
                n[t].vx -= dx * spring.bias
                n[t].vy -= dy * spring.bias
                n[s].vx += dx * (1 - spring.bias)
                n[s].vy += dy * (1 - spring.bias)
            }

            // Every bubble repels every other; bubbles in different groups repel harder,
            // which is what opens up visible space between clusters.
            for i in 0..<count {
                var fx = 0.0, fy = 0.0
                for j in 0..<count where j != i {
                    var dx = n[j].x - n[i].x
                    var dy = n[j].y - n[i].y
                    if dx == 0 && dy == 0 { dx = 0.5 + Double(i % 7); dy = 0.5 + Double(j % 5) }
                    var d2 = dx * dx + dy * dy
                    let near = n[i].radius + n[j].radius
                    if d2 < near * near { d2 = (near * near * d2).squareRoot() }
                    var strength = -chargePerRadius * n[j].radius
                    if n[i].group != n[j].group { strength *= crossGroupCharge }
                    fx += dx * strength / d2
                    fy += dy * strength / d2
                }
                n[i].vx += fx * alpha
                n[i].vy += fy * alpha
            }

            // A gentle pull to the middle keeps disconnected pieces on screen. It is
            // stronger vertically so graphs settle wider than tall, like the window.
            for i in 0..<count {
                n[i].vx -= n[i].x * gravityX * alpha
                n[i].vy -= n[i].y * gravityY * alpha
            }

            // Groups are regions. Members drift toward their group's centre, and each group
            // claims a disc of territory that other groups (and ungrouped bubbles) are pushed
            // out of, so the outline drawn around a group never swallows a stranger.
            if groupCount > 0 {
                var sumX = [Double](repeating: 0, count: groupCount)
                var sumY = [Double](repeating: 0, count: groupCount)
                var size = [Double](repeating: 0, count: groupCount)
                for i in 0..<count where n[i].group >= 0 {
                    sumX[n[i].group] += n[i].x
                    sumY[n[i].group] += n[i].y
                    size[n[i].group] += 1
                }
                var centreX = [Double](repeating: 0, count: groupCount)
                var centreY = [Double](repeating: 0, count: groupCount)
                for g in 0..<groupCount where size[g] > 0 {
                    centreX[g] = sumX[g] / size[g]
                    centreY[g] = sumY[g] / size[g]
                }
                var reach = [Double](repeating: 0, count: groupCount)
                for i in 0..<count where n[i].group >= 0 {
                    let g = n[i].group
                    if size[g] > 1 {
                        n[i].vx += (centreX[g] - n[i].x) * cohesion * alpha
                        n[i].vy += (centreY[g] - n[i].y) * cohesion * alpha
                    }
                    let dx = n[i].x - centreX[g], dy = n[i].y - centreY[g]
                    reach[g] = max(reach[g], (dx * dx + dy * dy).squareRoot() + n[i].radius)
                }

                // Group against group.
                for g in 0..<groupCount where size[g] > 0 {
                    for h in (g + 1)..<groupCount where size[h] > 0 {
                        var dx = centreX[h] - centreX[g], dy = centreY[h] - centreY[g]
                        if dx == 0 && dy == 0 { dx = 1 + Double(g); dy = 1 + Double(h) }
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let overlap = reach[g] + reach[h] + territoryPadding - distance
                        guard overlap > 0 else { continue }
                        let push = overlap / distance * 0.12
                        let shareG = size[h] / (size[g] + size[h])
                        for i in 0..<count {
                            if n[i].group == g {
                                n[i].vx -= dx * push * shareG
                                n[i].vy -= dy * push * shareG
                            } else if n[i].group == h {
                                n[i].vx += dx * push * (1 - shareG)
                                n[i].vy += dy * push * (1 - shareG)
                            }
                        }
                    }
                }
                // Ungrouped bubbles against groups.
                for i in 0..<count where n[i].group < 0 {
                    for g in 0..<groupCount where size[g] > 0 {
                        var dx = n[i].x - centreX[g], dy = n[i].y - centreY[g]
                        if dx == 0 && dy == 0 { dx = 1; dy = 1 }
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let overlap = reach[g] + n[i].radius + territoryPadding - distance
                        guard overlap > 0 else { continue }
                        n[i].vx += dx / distance * overlap * 0.12
                        n[i].vy += dy / distance * overlap * 0.12
                    }
                }
            }

            // An arrow should not run through a bubble it has nothing to do with: bubbles
            // sitting on someone else's arrow are nudged off it, and the arrow bends away.
            for spring in springs {
                let s = spring.source, t = spring.target
                let ax = n[s].x, ay = n[s].y
                let ex = n[t].x - ax, ey = n[t].y - ay
                let length2 = ex * ex + ey * ey
                guard length2 > 1 else { continue }
                for k in 0..<count where k != s && k != t {
                    // Only the stretch between the two bubbles counts; their own rims are the collision force's job.
                    let along = min(0.9, max(0.1, ((n[k].x - ax) * ex + (n[k].y - ay) * ey) / length2))
                    var dx = n[k].x - (ax + ex * along)
                    var dy = n[k].y - (ay + ey * along)
                    let reach = n[k].radius + 16
                    var d2 = dx * dx + dy * dy
                    guard d2 < reach * reach else { continue }
                    if d2 < 0.01 {
                        // Dead centre on the line: step off sideways.
                        let length = length2.squareRoot()
                        dx = -ey / length
                        dy = ex / length
                        d2 = 1
                    }
                    let distance = d2.squareRoot()
                    let push = (reach - distance) / distance * 0.22
                    n[k].vx += dx * push
                    n[k].vy += dy * push
                    n[s].vx -= dx * push * 0.5 * (1 - along)
                    n[s].vy -= dy * push * 0.5 * (1 - along)
                    n[t].vx -= dx * push * 0.5 * along
                    n[t].vy -= dy * push * 0.5 * along
                }
            }

            // Bubbles never overlap.
            for _ in 0..<3 {
                for i in 0..<count {
                    for j in (i + 1)..<count {
                        var dx = n[i].x + n[i].vx - n[j].x - n[j].vx
                        var dy = n[i].y + n[i].vy - n[j].y - n[j].vy
                        if dx == 0 && dy == 0 { dx = 0.5; dy = 0.5 }
                        let d2 = dx * dx + dy * dy
                        let reach = n[i].radius + n[j].radius + collisionPadding
                        guard d2 < reach * reach else { continue }
                        let distance = d2.squareRoot()
                        let push = (reach - distance) / distance * 0.7
                        dx *= push
                        dy *= push
                        let ri2 = n[i].radius * n[i].radius, rj2 = n[j].radius * n[j].radius
                        let share = rj2 / (ri2 + rj2)
                        n[i].vx += dx * share
                        n[i].vy += dy * share
                        n[j].vx -= dx * (1 - share)
                        n[j].vy -= dy * (1 - share)
                    }
                }
            }

            for i in 0..<count {
                if n[i].pinned {
                    n[i].vx = 0
                    n[i].vy = 0
                    continue
                }
                n[i].vx = max(-90, min(90, n[i].vx * velocityDecay))
                n[i].vy = max(-90, min(90, n[i].vy * velocityDecay))
                n[i].x += n[i].vx
                n[i].y += n[i].vy
            }
        }
    }

    /// Deterministic starting point for the i-th node: a sunflower spiral around the origin.
    static func seed(_ index: Int) -> (x: Double, y: Double) {
        let radius = 90.0 * (0.5 + Double(index)).squareRoot()
        let angle = Double(index) * Double.pi * (3 - 5.0.squareRoot())
        return (radius * cos(angle), radius * sin(angle))
    }
}
