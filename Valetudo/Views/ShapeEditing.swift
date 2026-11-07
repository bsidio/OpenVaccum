import SwiftUI

/// The part of a selected shape that a finger has hold of.
enum ShapeGrip: Equatable {
    case body
    /// An end of a line or a corner of an area, by its place in `points`.
    case point(Int)
    case rotation
}

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

    var length: CGFloat { hypot(x, y) }
    var angle: CGFloat { atan2(y, x) }
    var unit: CGPoint? { length > 0.001 ? self * (1 / length) : nil }

    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    func midpoint(to other: CGPoint) -> CGPoint { (self + other) * 0.5 }
}

/// Moving, resizing and turning, in map pixels. The rules are Valetudo's own: lines and
/// ramps turn in 5 degree steps, and no side gets shorter than 5 map pixels.
extension PlanShape {
    private static let angleStep = CGFloat.pi / 36
    private static let shortestAllowed: CGFloat = 5
    /// How far the rotation grip sits past the ramp's edge, in view points.
    private static let rotationGripDistance: CGFloat = 34

    private static func snapped(_ angle: CGFloat) -> CGFloat {
        (angle / angleStep).rounded() * angleStep
    }

    /// Top left first and then clockwise, as `ValetudoRestrictedZone` documents, whichever
    /// way the drag went. Ramps take their direction from this order too.
    static func rectangle(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
        return [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
    }

    static func snappedEnd(from fixed: CGPoint, to target: CGPoint, atLeast shortest: CGFloat = 0) -> CGPoint {
        let offset = target - fixed
        let angle = snapped(offset.angle)
        return fixed + CGPoint(x: cos(angle), y: sin(angle)) * max(offset.length, shortest)
    }

    /// A shape from the robot with the wrong number of points can be shown and deleted, but not adjusted.
    var isComplete: Bool { points.count == (kind.isLine ? 2 : 4) }

    /// A sliver can't be grabbed afterwards, so each side counts, not just the overall size.
    var isBigEnough: Bool { shortestSide >= Self.shortestAllowed }

    private var centre: CGPoint {
        points.reduce(CGPoint.zero) { $0 + $1 } * (1 / CGFloat(max(points.count, 1)))
    }

    private var shortestSide: CGFloat {
        guard isComplete else { return 0 }
        let first = (points[1] - points[0]).length
        return kind.isLine ? first : min(first, (points[3] - points[0]).length)
    }

    /// Past the edge the ramp's arrows point at, so turning it feels like steering them.
    func rotationGrip(scale: CGFloat) -> CGPoint? {
        guard kind == .ramp, isComplete, let outward = (points[0] - points[3]).unit else { return nil }
        return frontEdge + outward * (Self.rotationGripDistance / scale)
    }

    private var frontEdge: CGPoint { points[0].midpoint(to: points[1]) }

    /// What a touch at `point` would pick up, or nil if it missed the shape.
    func grip(at point: CGPoint, scale: CGFloat) -> ShapeGrip? {
        guard isComplete else { return nil }
        let finger = Metric.hitTarget / 2 / scale
        if let grip = rotationGrip(scale: scale), (point - grip).length <= finger { return .rotation }
        // Grips shrink on a shape that's small on screen, so its middle can still be dragged.
        let reach = min(finger, shortestSide / 3)
        let nearest = points.indices.min { (points[$0] - point).length < (points[$1] - point).length }
        if let nearest, (points[nearest] - point).length <= reach { return .point(nearest) }
        return contains(point, tolerance: finger) ? .body : nil
    }

    /// Where the points go when `grip` is dragged. Always worked out from the shape as the
    /// drag found it, so rounding can't build up along the way.
    func adjusted(_ grip: ShapeGrip, from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let shift = end - start
        switch grip {
        case .body:
            return points.map { $0 + shift }
        case .point(let index):
            return kind.isLine ? movingEnd(index, to: points[index] + shift) : movingCorner(index, to: points[index] + shift)
        case .rotation:
            return turned(by: (end - centre).angle - (start - centre).angle)
        }
    }

    private func movingEnd(_ index: Int, to target: CGPoint) -> [CGPoint] {
        var result = points
        result[index] = Self.snappedEnd(from: points[1 - index], to: target, atLeast: Self.shortestAllowed)
        return result
    }

    /// The opposite corner stays put, and the sides keep their directions, so a turned ramp
    /// stays a rectangle. A corner can't cross over, so the order of the points never changes.
    private func movingCorner(_ corner: Int, to target: CGPoint) -> [CGPoint] {
        let far = (corner + 2) % 4
        let fixed = points[far]
        let across = (points[1] - points[0]).unit ?? CGPoint(x: 1, y: 0)
        let down = (points[3] - points[0]).unit ?? CGPoint(x: -across.y, y: across.x)
        let right: CGFloat = corner == 1 || corner == 2 ? 1 : -1
        let below: CGFloat = corner >= 2 ? 1 : -1
        let offset = target - fixed
        let width = across * (right * max(Self.shortestAllowed, right * offset.dot(across)))
        let height = down * (below * max(Self.shortestAllowed, below * offset.dot(down)))
        var result = points
        result[far ^ 1] = fixed + width
        result[3 - far] = fixed + height
        result[corner] = fixed + width + height
        return result
    }

    /// Turns the whole shape about its middle, landing on the nearest 5 degree step.
    func turned(by delta: CGFloat) -> [CGPoint] {
        guard isComplete else { return points }
        let direction = (points[1] - points[0]).angle
        let turn = Self.snapped(direction + delta) - direction
        let middle = centre
        return points.map { point in
            let offset = point - middle
            return middle + CGPoint(x: offset.x * cos(turn) - offset.y * sin(turn),
                                    y: offset.x * sin(turn) + offset.y * cos(turn))
        }
    }

    /// Grows or shrinks about the middle, refusing to go below the smallest size.
    func scaled(by factor: CGFloat) -> [CGPoint] {
        guard shortestSide * factor >= Self.shortestAllowed else { return points }
        let middle = centre
        return points.map { middle + ($0 - middle) * factor }
    }

    /// Chevrons along a ramp, tips towards its first edge, in Valetudo's proportions.
    var rampArrows: Path {
        var path = Path()
        guard kind == .ramp, shortestSide >= 1,
              let across = (points[1] - points[0]).unit,
              let along = (points[3] - points[0]).unit else { return path }
        let width = min((points[1] - points[0]).length * 0.75, 50)
        let height = width / 2
        let spacing = height * 1.4
        let rows = Int(((points[3] - points[0]).length / spacing).rounded(.up))
        for row in 0...rows {
            let middle = frontEdge + along * (height * 0.75 + CGFloat(row) * spacing)
            let base = middle + along * (height / 2)
            path.move(to: base - across * (width / 2))
            path.addLine(to: middle - along * (height / 2))
            path.addLine(to: base + across * (width / 2))
        }
        return path
    }
}

/// Marks only the editor needs on top of a shape.
enum ShapeMarks {
    static func arrows(on shape: PlanShape, color: Color, in context: GraphicsContext, _ t: PlanTransform) {
        var map = context
        map.concatenate(t.affine)
        map.clip(to: shape.path)
        map.stroke(shape.rampArrows, with: .color(color),
                   style: StrokeStyle(lineWidth: 2 / t.scale, lineCap: .round, lineJoin: .round))
    }

    static func grips(on shape: PlanShape, color: Color, in context: GraphicsContext, _ t: PlanTransform) {
        guard shape.isComplete else { return }
        for point in shape.points {
            let p = t.toView(point)
            let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            context.fill(dot, with: .color(color))
            context.stroke(dot, with: .color(Theme.floor), lineWidth: 2)
        }
        guard let grip = shape.rotationGrip(scale: t.scale) else { return }
        let p = t.toView(grip)
        var stem = Path()
        stem.move(to: t.toView(shape.points[0]).midpoint(to: t.toView(shape.points[1])))
        stem.addLine(to: p)
        context.stroke(stem, with: .color(color), lineWidth: 2)
        let disc = Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
        context.fill(disc, with: .color(Theme.floor))
        context.stroke(disc, with: .color(color), lineWidth: 2)
        context.draw(Text(Image(systemName: "arrow.clockwise"))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color), at: p)
    }
}
