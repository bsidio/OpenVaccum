import SwiftUI

/// What the robot's camera can see from where it is, drawn on the floor plan. Sight lines stop
/// at the first thing that isn't open floor, so walls cut the view off as they do in real life.
enum CameraCone {
    /// Robots don't report these, so they're a fair guess for a wide-angle front camera.
    private static let width = Angle.degrees(100)
    private static let reach: CGFloat = 400

    /// The outline in map pixels, or nil without a robot to look from.
    static func outline(in plan: FloorPlan) -> [CGPoint]? {
        guard let robot = plan.robot else { return nil }
        let rays = 48
        let distance = reach / plan.pixelSize
        var points = [robot]
        for ray in 0...rays {
            let spread = width.degrees * (Double(ray) / Double(rays) - 0.5)
            // A heading of 0 faces the top of the map.
            let angle = Angle.degrees(plan.heading + spread - 90).radians
            points.append(plan.sightEnd(from: robot, angle: angle, reach: distance))
        }
        return points
    }

    static func draw(for plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform) {
        guard let points = outline(in: plan), let robot = plan.robot else { return }
        var cone = Path()
        cone.addLines(points.map(t.toView))
        cone.closeSubpath()
        let centre = t.toView(robot)
        let fade = Gradient(colors: [Theme.cobalt.opacity(0.5), Theme.cobalt.opacity(0.06)])
        context.fill(cone, with: .radialGradient(fade, center: centre, startRadius: 0,
                                                 endRadius: reach / plan.pixelSize * t.scale))
    }
}
