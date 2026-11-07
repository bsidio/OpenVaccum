import SwiftUI

/// The shared floor plan: draws the map, handles pinch and pan, and reports taps and drags.
/// The floor plan editor adds its layers through `overlay`. Home passes `touches` instead:
/// UIKit then takes every touch, and picks draw in `pickLayer`, above the map's filters.
struct PlanCanvas: View {
    let plan: FloorPlan
    var selected: Set<String> = []
    var active = false
    /// Keeps the rooms of an unfinished job marked, though the robot isn't moving.
    var paused = false
    var showsRobot = true
    /// Restrictions, annotations and what the robot is working on. The editor turns these off
    /// because it draws its own copies, and until they're saved those can differ from the plan.
    var showsRestrictions = true
    var showsLabels = true
    /// When true, one finger draws instead of panning.
    var drawing = false
    /// Space to keep clear for controls floating over the plan.
    var insets = EdgeInsets()
    var overlay: (GraphicsContext, PlanTransform) -> Void = { _, _ in }
    var onTap: (CGPoint, PlanTransform) -> Void = { _, _ in }
    var onDraw: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onDrawEnd: () -> Void = {}
    var touches: PlanTouches? = nil
    /// Picked rooms in cleaning order. Empty if the robot can't follow one, so labels show a checkmark.
    var order: [String] = []
    var pickLayer: ((PlanTransform) -> AnyView)? = nil
    /// Raises the Fit button, to clear anything floating above the plan's bottom inset.
    var fitLift: CGFloat = 0

    /// Not private so a test can start zoomed in, where labels change.
    @State var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let t = PlanTransform(bounds: plan.bounds, size: geo.size, insets: insets, zoom: zoom, pan: pan)
            let gestures: GestureMask = touches == nil ? .all : .none
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(context, t)
                    overlay(context, t)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { onTap(t.toMap($0.location), t) }, including: gestures)
                .simultaneousGesture(dragGesture(t), including: gestures)
                .simultaneousGesture(pinchGesture, including: gestures)

                if let touches {
                    TouchSurface(touches: touches, plan: plan, transform: t, size: geo.size, insets: insets,
                                 zoom: zoom, pan: pan, onCamera: moveCamera, onCameraEnd: settleCamera)
                        .accessibilityHidden(true)
                    PlanChildren(touches: touches, plan: plan, t: t)
                        .allowsHitTesting(false)
                }

                if showsRobot, let robot = plan.robot {
                    RobotMarker(active: active, heading: plan.heading)
                        .position(t.toView(robot))
                        .animation(reduceMotion || zoom != zoomBase ? nil : .linear(duration: 2), value: robot)
                        .allowsHitTesting(false)
                }

                if let pickLayer { pickLayer(t) }

                if zoom > 1.01 || pan != .zero {
                    Button(action: resetCamera) {
                        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                            .glass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel("Fit the floor plan to the screen")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, insets.bottom + 8 + fitLift)
                }
            }
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floor plan with \(plan.roomCount)")
    }

    private func moveCamera(zoom newZoom: CGFloat, pan newPan: CGSize) {
        zoom = newZoom
        pan = newPan
    }

    private func settleCamera() {
        zoomBase = zoom
        panBase = pan
        if zoom <= 1.01 { resetCamera() }
    }

    /// A Canvas can't animate, so this always snaps. Anything drawn above the plan would otherwise
    /// drift across the wrong rooms on its way to a map that's already there.
    private func resetCamera() {
        zoom = 1
        zoomBase = 1
        pan = .zero
        panBase = .zero
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(6, max(1, zoomBase * $0.magnification)) }
            .onEnded { _ in
                zoomBase = zoom
                if zoom <= 1.01 { resetCamera() }
            }
    }

    private func dragGesture(_ t: PlanTransform) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if drawing {
                    onDraw(t.toMap(value.startLocation), t.toMap(value.location))
                } else if zoom > 1.01 {
                    pan = CGSize(width: panBase.width + value.translation.width,
                                 height: panBase.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if drawing { onDrawEnd() } else { panBase = pan }
            }
    }

    /// Roughly how wide a robot cleans, in centimetres.
    private static let cleaningWidth: CGFloat = 30
    /// How far in a room's label gains its second line.
    private static let detailZoom: CGFloat = 2.5

    /// The map arrives as coarse pixels. Blurring a shape and then cutting it at half
    /// opacity gives a smooth outline, which looks far better than a staircase.
    private func smooth(_ path: Path, _ color: Color, cut: Double, softness: CGFloat, in context: GraphicsContext, _ t: PlanTransform) {
        var layer = context
        layer.addFilter(.blur(radius: 0.5))
        layer.addFilter(.alphaThreshold(min: cut, color: color))
        layer.addFilter(.blur(radius: softness))
        layer.drawLayer { inner in
            inner.concatenate(t.affine)
            inner.fill(path, with: .color(.black), style: FillStyle(antialiased: false))
        }
    }

    /// A flag left in the map doesn't count while the robot is idle.
    private func isInJob(_ room: FloorPlan.Room) -> Bool { room.active && (active || paused) }

    private func draw(_ context: GraphicsContext, _ t: PlanTransform) {
        var map = context
        map.concatenate(t.affine)
        let softness = max(0.8, t.scale * 0.55)
        let strong = context.environment.colorSchemeContrast == .increased

        // The whole home sits on a soft shadow, so it reads as an object on the page. A blur
        // this wide hides any staircase, so the outline doesn't need smoothing first. It would
        // be black on black in dark mode, so that skips the work.
        if !plan.footprint.isEmpty, context.environment.colorScheme == .light {
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.16), radius: 14, y: 5, options: .shadowOnly))
            shadowed.concatenate(t.affine)
            shadowed.fill(plan.footprint, with: .color(.black), style: FillStyle(antialiased: false))
        }
        if !plan.floor.isEmpty { smooth(plan.floor, Theme.floor, cut: 0.5, softness: softness, in: context, t) }

        for room in plan.rooms {
            let picked = selected.contains(room.id)
            let color = picked ? Theme.selected : Theme.rooms[room.palette]
            context.drawLayer { layer in
                // Increase Contrast edges a picked room rather than filling it with cobalt, which
                // would swallow everything else in that colour: the split line, the trail, a pin.
                if isInJob(room) || (picked && strong) {
                    // The room's colour, cut further in than the room's edge, leaves a line of
                    // cobalt inside the walls. A glow outside them hides behind the next room.
                    // Much past a quarter of a room's width, the line would fill the room.
                    let reach = min(max(strong ? 5 : 3.3, softness), room.span * t.scale / 4)
                    smooth(room.path, Theme.cobalt, cut: 0.5, softness: softness, in: layer, t)
                    smooth(room.path, color, cut: 0.82, softness: reach, in: layer, t)
                } else {
                    smooth(room.path, color, cut: 0.5, softness: softness, in: layer, t)
                }
                // Source-atop keeps the floor texture inside the room's smooth outline.
                var texture = layer
                texture.blendMode = .sourceAtop
                texture.concatenate(t.affine)
                texture.stroke(room.texture, with: .color(Theme.ink.opacity(0.07)), lineWidth: 0.7 / t.scale)
            }
        }
        Self.drawCarpets(of: plan, in: context, t)

        // The band is about as wide as the robot, so it shows the floor it has covered.
        map.stroke(plan.trail, with: .color(Theme.cobalt.opacity(strong ? 0.35 : 0.2)),
                   style: StrokeStyle(lineWidth: Self.cleaningWidth / plan.pixelSize, lineCap: .round, lineJoin: .round))
        smooth(plan.walls, Theme.wall, cut: 0.36, softness: softness * 0.6, in: context, t)
        map.stroke(plan.predicted, with: .color(Theme.cobalt.opacity(strong ? 1 : 0.7)),
                   style: StrokeStyle(lineWidth: 1.6 / t.scale, lineCap: .round, dash: [5 / t.scale, 5 / t.scale]))

        if showsRestrictions { Self.drawRestrictions(of: plan, in: context, t) }

        let markerSize = min(26, 17 + t.scale * 0.6)
        for obstacle in plan.obstacles {
            let p = t.toView(obstacle.point)
            let badge = Path(ellipseIn: CGRect(x: p.x - markerSize / 2, y: p.y - markerSize / 2, width: markerSize, height: markerSize))
            context.fill(badge, with: .color(Theme.obstacle))
            context.stroke(badge, with: .color(Theme.floor), lineWidth: 1.5)
            context.draw(Text(Image(systemName: obstacle.symbol))
                .font(.system(size: markerSize * 0.52, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78)), at: p)
        }

        if showsLabels {
            for room in plan.rooms { drawLabel(room, in: context, t, strong: strong) }
        }

        // Above the labels, in the web interface's order: this is what's happening now.
        if showsRestrictions { Self.drawJob(of: plan, in: context, t) }

        if let dock = plan.dock {
            let p = t.toView(dock)
            let box = Path(roundedRect: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18), cornerRadius: 5)
            context.fill(box, with: .color(Theme.floor))
            context.stroke(box, with: .color(Theme.wall), lineWidth: 2)
            context.draw(Text(Image(systemName: "bolt.fill")).font(.system(size: 10)).foregroundStyle(Theme.wall), at: p)
        }
    }

    private func drawLabel(_ room: FloorPlan.Room, in context: GraphicsContext, _ t: PlanTransform, strong: Bool) {
        let picked = selected.contains(room.id)
        let label = context.resolve(labelText(room, picked: picked))
        let size = label.measure(in: CGSize(width: 200, height: 40))
        let detail = zoom >= Self.detailZoom ? context.resolve(detailText(room, picked: picked)) : nil
        let detailSize = detail?.measure(in: CGSize(width: 200, height: 40)) ?? .zero

        // The name stays put when the second line appears below it, and the corners keep their size.
        let p = t.toView(room.label)
        let lineHeight = size.height + PlanLabel.padding.height
        let width = max(size.width, detailSize.width) + PlanLabel.padding.width
        let backing = CGRect(x: p.x - width / 2, y: p.y - lineHeight / 2, width: width, height: lineHeight + detailSize.height)
        let pill = Path(roundedRect: backing, cornerRadius: lineHeight / 2)
        context.fill(pill, with: .color(picked ? Theme.cobalt : Theme.floor.opacity(strong ? 1 : 0.78)))
        if isInJob(room) { context.stroke(pill, with: .color(Theme.cobalt), lineWidth: 1.5) }
        context.draw(label, at: p)
        if let detail { context.draw(detail, at: CGPoint(x: p.x, y: p.y + (size.height + detailSize.height) / 2)) }
    }

    /// Neither selection nor a running job relies on colour alone. A picked room also shows its
    /// number or a checkmark, and a room in the job shows the symbol the app uses for cleaning.
    private func labelText(_ room: FloorPlan.Room, picked: Bool) -> Text {
        if picked {
            let mark = order.firstIndex(of: room.id).map { Text("\($0 + 1)") } ?? Text(Image(systemName: "checkmark"))
            return (mark + Text(" \(room.name)")).font(PlanLabel.capsuleFont).foregroundStyle(Theme.onCobalt)
        }
        let name = Text(room.name).foregroundStyle(Theme.ink)
        guard isInJob(room) else { return name.font(PlanLabel.capsuleFont) }
        return (Text(Image(systemName: "sparkles")).foregroundStyle(Theme.cobalt) + Text(" ") + name).font(PlanLabel.capsuleFont)
    }

    private func detailText(_ room: FloorPlan.Room, picked: Bool) -> Text {
        Text(Self.detail(of: room)).font(.caption2).foregroundStyle(picked ? Theme.onCobalt : Theme.quietInk)
    }

    /// What a label adds when zoomed in: the two facts the web interface shows there.
    static func detail(of room: FloorPlan.Room, locale: Locale = .current) -> String {
        let feet = locale.measurementSystem == .us
        let area = (feet ? room.area * 10.7639 : room.area).formatted(.number.precision(.significantDigits(2)).locale(locale))
        return "\(area) \(feet ? "sq ft" : "m²") · ID \(room.id)"
    }

    // MARK: Structures

    /// Everything on the plan that isn't the floor itself, for a surface with no labels to
    /// keep clear of. `PlanCanvas` draws these two halves apart, with its labels between them.
    /// The 3D model turns `showsTarget` off, because a pin painted on its floor can hide behind a wall.
    static func drawStructures(of plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform, showsTarget: Bool = true) {
        drawRestrictions(of: plan, in: context, t)
        drawJob(of: plan, in: context, t, showsTarget: showsTarget)
    }

    private static func drawRestrictions(of plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform) {
        for shape in plan.restrictions + plan.annotations { draw(shape, in: context, t) }
    }

    /// Green, as on the web interface, because zones and squares still being picked are cobalt.
    /// A picked zone has a solid edge and a picked square has no fill, so colour isn't the only
    /// difference from these.
    private static func drawJob(of plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform, showsTarget: Bool = true) {
        let strong = context.environment.colorSchemeContrast == .increased
        var map = context
        map.concatenate(t.affine)
        map.fill(plan.activeZones, with: .color(Theme.working.opacity(strong ? 0.28 : 0.16)))
        map.stroke(plan.activeZones, with: .color(Theme.working),
                   style: StrokeStyle(lineWidth: (strong ? 3 : 2) / t.scale, lineCap: .round, lineJoin: .round,
                                      dash: [7 / t.scale, 5 / t.scale]))
        if showsTarget, let target = plan.goToTarget { PlanPin.draw(at: t.toView(target), in: context) }
    }

    /// Carpets the robot found, hatched both ways as on the web interface.
    static func drawCarpets(of plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform) {
        var hatch = context
        hatch.concatenate(t.affine)
        hatch.clip(to: plan.carpets)
        hatch.stroke(plan.carpetHatch, with: .color(Theme.ink.opacity(0.16)), lineWidth: 0.7 / t.scale)
    }

    /// Draws a wall, zone or annotation in its own colour.
    static func draw(_ shape: PlanShape, highlighted: Bool = false, in context: GraphicsContext, _ t: PlanTransform) {
        var map = context
        map.concatenate(t.affine)
        let strong = context.environment.colorSchemeContrast == .increased
        let color: Color
        switch shape.kind {
        case .wall, .noGo: color = Theme.rose
        case .noMop: color = .purple
        case .threshold, .curtain, .ramp: color = Theme.amber
        }
        let fill = strong ? (highlighted ? 0.5 : 0.28) : (highlighted ? 0.32 : 0.16)
        if !shape.kind.isLine { map.fill(shape.path, with: .color(color.opacity(fill))) }
        map.stroke(shape.path, with: .color(color),
                   style: StrokeStyle(lineWidth: (highlighted ? 4 : strong ? 3.5 : 2.5) / t.scale, lineCap: .round,
                                      dash: shape.kind == .curtain ? [6 / t.scale, 5 / t.scale] : []))
    }
}

/// The robot, drawn like the location puck in Maps: a dot with a heading beam.
struct RobotMarker: View {
    let active: Bool
    let heading: Double
    /// Free to run past 360, so a turn through north doesn't unwind the long way round.
    @State private var shownHeading: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(active: Bool, heading: Double) {
        self.active = active
        self.heading = heading
        _shownHeading = State(initialValue: heading)
    }

    /// The shortest turn between two headings in degrees, signed. 355 to 5 is 10, not -350.
    static func turn(from old: Double, to new: Double) -> Double {
        (new - old).remainder(dividingBy: 360)
    }

    var body: some View {
        ZStack {
            HeadingBeam()
                .fill(RadialGradient(colors: [Theme.cobalt.opacity(0.55), Theme.cobalt.opacity(0)],
                                     center: .center, startRadius: 6, endRadius: 34))
                .frame(width: 68, height: 68)
                .rotationEffect(.degrees(shownHeading))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: shownHeading)

            if active && !reduceMotion {
                Circle()
                    .stroke(Theme.cobalt, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .phaseAnimator([false, true]) { view, grown in
                        view.scaleEffect(grown ? 2.1 : 1).opacity(grown ? 0 : 0.7)
                    } animation: { grown in
                        grown ? .easeOut(duration: 1.6) : nil
                    }
            }

            Circle()
                .fill(Theme.cobalt.gradient)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .accessibilityHidden(true)
        .onChange(of: heading) { old, new in shownHeading += Self.turn(from: old, to: new) }
    }
}

/// A wedge pointing up from the centre.
private struct HeadingBeam: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: rect.width / 2, startAngle: .degrees(-122), endAngle: .degrees(-58), clockwise: false)
        path.closeSubpath()
        return path
    }
}
