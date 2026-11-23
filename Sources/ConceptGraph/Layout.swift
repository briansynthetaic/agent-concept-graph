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

    var shape = NodeShape.circle
    var nodes: [Node] = []
    private var springs: [Spring] = []
    private var groupCount = 0

    private(set) var alpha = 1.0
    /// Raised while the user drags a bubble so the rest of the graph keeps responding.
    private var alphaTarget = 0.0
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

    private struct LocalDrag {
        var anchor: Int
        var followers: [(index: Int, dx: Double, dy: Double)]
        var members: Set<Int>
    }
    private var localDrag: LocalDrag?

    var isActive: Bool { localDrag != nil || alpha >= alphaMin || alphaTarget > 0 }

    func beginLocalDrag(_ anchor: Int) {
        stop()
        let origin = nodes[anchor]
        var followers: [(Int, Double, Double)] = []
        for i in nodes.indices {
            nodes[i].vx = 0
            nodes[i].vy = 0
            if origin.group >= 0, nodes[i].group == origin.group, i != anchor {
                followers.append((i, nodes[i].x - origin.x, nodes[i].y - origin.y))
            }
        }
        localDrag = LocalDrag(anchor: anchor, followers: followers, members: Set([anchor] + followers.map { $0.0 }))
    }

    func moveDraggedNode(_ index: Int, x: Double, y: Double) {
        nodes[index].pinned = true
        if let drag = localDrag {
            let dx = x - nodes[index].x, dy = y - nodes[index].y
            // Allow at most four graph units of trailing motion, shared by every follower.
            let length = hypot(dx, dy)
            let lag = length > 0 ? min(0.12, 4 / length) : 0
            moveLocally(index, x: x, y: y, members: drag.members)
            for follower in drag.followers {
                moveLocally(follower.index, x: x + follower.dx - dx * lag,
                            y: y + follower.dy - dy * lag, members: drag.members)
            }
        } else {
            nodes[index].x = x
            nodes[index].y = y
            alphaTarget = 0.25
        }
    }

    func endDrag() {
        localDrag = nil
        alphaTarget = 0
    }

    /// Sweep each moving outline along its path so a fast pointer can still shove
    /// a bubble between events. Only actual contacts propagate the displacement.
    private func moveLocally(_ index: Int, x: Double, y: Double, members: Set<Int>) {
        var moves = [(index, x, y)]
        var visited: Set<Int> = [index]
        var next = 0
        while next < moves.count {
            let (i, endX, endY) = moves[next]
            next += 1
            let start = nodes[i]
            let dx = endX - start.x, dy = endY - start.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { continue }
            nodes[i].x = endX
            nodes[i].y = endY
            let ux = dx / length, uy = dy / length
            for j in nodes.indices where !members.contains(j) && !nodes[j].pinned && !visited.contains(j) {
                let other = nodes[j]
                let forward = (other.x - start.x) * ux + (other.y - start.y) * uy
                guard forward >= 0 else { continue }
                let along = min(forward, length)
                var nx = other.x - (start.x + along * ux)
                var ny = other.y - (start.y + along * uy)
                let distance = hypot(nx, ny)
                if distance > 0.001 {
                    nx /= distance
                    ny /= distance
                } else if forward >= length {
                    nx = ux
                    ny = uy
                } else {
                    nx = -uy
                    ny = ux
                }
                let reach = shape.geometry(start.radius + other.radius).reach(dx: nx, dy: ny)
                let overlap = reach + collisionPadding - distance
                guard overlap > 0.001 else { continue }
                visited.insert(j)
                moves.append((j, other.x + nx * overlap, other.y + ny * overlap))
            }
        }
    }

    func setLinks(_ links: [Link]) {
        var degree = [Int](repeating: 0, count: nodes.count)
        for link in links {
            degree[link.source] += 1
            degree[link.target] += 1
        }
        springs = links.map { link in
            let a = nodes[link.source], b = nodes[link.target]
            let sameGroup = a.group == b.group
            let distance = shape.geometry(a.radius + b.radius).enclosingRadius + baseGap + link.gap + (sameGroup ? 0 : crossGroupGap)
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

    /// A complete restored arrangement stays exactly where the user left it.
    func stop() {
        localDrag = nil
        alpha = 0
        alphaTarget = 0
    }

    func settle(maxTicks: Int = 450, timeBudget: TimeInterval = .infinity) {
        alpha = 1
        let start = ProcessInfo.processInfo.systemUptime
        var ticks = 0
        while alpha >= alphaMin && ticks < maxTicks {
            tick()
            ticks += 1
            if ProcessInfo.processInfo.systemUptime - start >= timeBudget { break }
        }
    }

    func tick() {
        if let drag = localDrag {
            let anchor = nodes[drag.anchor]
            for follower in drag.followers {
                let node = nodes[follower.index]
                let dx = (anchor.x + follower.dx - node.x) * 0.12
                let dy = (anchor.y + follower.dy - node.y) * 0.12
                if hypot(dx, dy) > 0.001 {
                    moveLocally(follower.index, x: node.x + dx, y: node.y + dy, members: drag.members)
                }
            }
            return
        }
        alpha += (alphaTarget - alpha) * alphaDecay
        let count = nodes.count
        guard count > 0 else { return }

        let enclosingFactor = shape.geometry(1).enclosingRadius
        let arrowClearance = nodes.reduce(0) { max($0, $1.radius) } * enclosingFactor + 16
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
                    reach[g] = max(reach[g], (dx * dx + dy * dy).squareRoot() + n[i].radius * enclosingFactor)
                }

                // Accumulate each territory's translation once, then apply it to its members.
                var groupDX = [Double](repeating: 0, count: groupCount)
                var groupDY = [Double](repeating: 0, count: groupCount)
                for g in 0..<groupCount where size[g] > 0 {
                    for h in (g + 1)..<groupCount where size[h] > 0 {
                        var dx = centreX[h] - centreX[g], dy = centreY[h] - centreY[g]
                        if dx == 0 && dy == 0 { dx = 1 + Double(g); dy = 1 + Double(h) }
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let overlap = reach[g] + reach[h] + territoryPadding - distance
                        guard overlap > 0 else { continue }
                        let push = min(overlap, baseGap) / distance * 0.12 * alpha
                        let shareG = size[h] / (size[g] + size[h])
                        groupDX[g] -= dx * push * shareG
                        groupDY[g] -= dy * push * shareG
                        groupDX[h] += dx * push * (1 - shareG)
                        groupDY[h] += dy * push * (1 - shareG)
                    }
                }
                for i in 0..<count where n[i].group >= 0 {
                    let group = n[i].group
                    n[i].vx += groupDX[group]
                    n[i].vy += groupDY[group]
                }
                // Ungrouped bubbles against groups.
                for i in 0..<count where n[i].group < 0 {
                    for g in 0..<groupCount where size[g] > 0 {
                        var dx = n[i].x - centreX[g], dy = n[i].y - centreY[g]
                        if dx == 0 && dy == 0 { dx = 1; dy = 1 }
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let overlap = reach[g] + n[i].radius * enclosingFactor + territoryPadding - distance
                        guard overlap > 0 else { continue }
                        n[i].vx += dx / distance * min(overlap, baseGap) * 0.12 * alpha
                        n[i].vy += dy / distance * min(overlap, baseGap) * 0.12 * alpha
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
                let minX = min(ax, n[t].x) - arrowClearance, maxX = max(ax, n[t].x) + arrowClearance
                let minY = min(ay, n[t].y) - arrowClearance, maxY = max(ay, n[t].y) + arrowClearance
                for k in 0..<count where k != s && k != t {
                    guard n[k].x >= minX, n[k].x <= maxX, n[k].y >= minY, n[k].y <= maxY else { continue }
                    // Only the stretch between the two bubbles counts; their own rims are the collision force's job.
                    let along = min(0.9, max(0.1, ((n[k].x - ax) * ex + (n[k].y - ay) * ey) / length2))
                    var dx = n[k].x - (ax + ex * along)
                    var dy = n[k].y - (ay + ey * along)
                    var d2 = dx * dx + dy * dy
                    let outer = n[k].radius * enclosingFactor + 16
                    guard d2 < outer * outer else { continue }
                    let reach = shape.geometry(n[k].radius).reach(dx: dx, dy: dy) + 16
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
                        let radii = n[i].radius + n[j].radius
                        let outer = radii * enclosingFactor + collisionPadding
                        guard d2 < outer * outer else { continue }
                        // Both outlines have the same proportions. Their summed outline gives
                        // the contact distance in the direction joining the two centers.
                        let reach = shape.geometry(radii).reach(dx: dx, dy: dy) + collisionPadding
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
