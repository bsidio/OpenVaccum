import SceneKit
import SwiftUI

/// The floor plan as a small architectural model, which a finger can turn and tilt.
struct DollhouseView: View {
    let plan: FloorPlan
    /// Rooms that are picked, in cleaning order.
    var picked: [String] = []
    /// False when the robot can't follow an order, so picked rooms show a checkmark.
    var numbered = true
    var active = false
    /// Keeps the rooms of an unfinished job marked, though the robot isn't moving.
    var paused = false
    var trailStyle = PlanCanvas.TrailStyle.band
    var bottomInset: CGFloat = 0
    /// Raises the reset button, to clear anything floating above the bottom inset.
    var resetLift: CGFloat = 0
    var onRoom: (String) -> Void = { _ in }
    var onObstacle: (FloorPlan.Obstacle) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moved = false
    @State private var resets = 0

    var body: some View {
        GeometryReader { geo in
            DollhouseScene(plan: plan, picked: picked, numbered: numbered, active: active, paused: paused,
                           trailStyle: trailStyle, scheme: scheme, reduceMotion: reduceMotion,
                           size: CGSize(width: geo.size.width, height: max(1, geo.size.height - bottomInset)),
                           resets: resets, onMoved: { moved = $0 }, onRoom: onRoom, onObstacle: onObstacle)
                .frame(height: max(1, geo.size.height - bottomInset))
        }
        .overlay(alignment: .bottomTrailing) {
            if moved {
                Button {
                    moved = false
                    resets += 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                        .glass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Reset the View")
                .padding(.trailing, 14)
                .padding(.bottom, bottomInset + resetLift + 8)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: moved)
        .accessibilityElement()
        .accessibilityLabel("3D floor plan with \(plan.roomCount)")
        .accessibilityActions {
            ForEach(plan.rooms) { room in
                Button(picked.contains(room.id) ? "Remove \(room.name)" : "Pick \(room.name)") { onRoom(room.id) }
            }
            ForEach(plan.obstacles) { obstacle in
                Button("Show \(obstacle.title)") { onObstacle(obstacle) }
            }
        }
    }
}

private struct DollhouseScene: UIViewRepresentable {
    let plan: FloorPlan
    let picked: [String]
    let numbered: Bool
    let active: Bool
    let paused: Bool
    let trailStyle: PlanCanvas.TrailStyle
    let scheme: ColorScheme
    let reduceMotion: Bool
    let size: CGSize
    let resets: Int
    let onMoved: (Bool) -> Void
    let onRoom: (String) -> Void
    let onObstacle: (FloorPlan.Obstacle) -> Void

    func makeCoordinator() -> DollhouseModel { DollhouseModel() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let model = context.coordinator
        model.onRoom = onRoom
        model.onObstacle = onObstacle
        model.onMoved = onMoved
        model.show(plan, picked: picked, numbered: numbered, active: active, paused: paused,
                   trailStyle: trailStyle, scheme: scheme, reduceMotion: reduceMotion, size: size)
        model.reset(to: resets)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: DollhouseModel) {
        coordinator.stop()
    }
}

/// Outlines for the model, built away from the main thread because tracing takes a moment.
private struct DollhouseShape {
    let walls: [[CGPoint]]
    let base: [[CGPoint]]

    init(_ plan: FloorPlan) {
        var wallMask = PlanMask(plan.walls, in: plan.bounds)
        wallMask.soften()
        // A low cut, because softening thins walls that are only a pixel or two wide.
        walls = wallMask.outlines(at: 0.34, minimumArea: 3)

        var whole = Path()
        whole.addPath(plan.floor)
        whole.addPath(plan.walls)
        for room in plan.rooms { whole.addPath(room.path) }
        var baseMask = PlanMask(whole, in: plan.bounds)
        baseMask.soften(passes: 3)
        base = baseMask.outlines(at: 0.42, minimumArea: 60)
    }
}

/// The colours of the model, which follow the app's light and dark palettes.
private struct DollhouseColors {
    let page, base, wallSide, wallTop, cobalt, marker: UIColor

    init(_ scheme: ColorScheme) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        func resolve(_ color: Color) -> UIColor { UIColor(color).resolvedColor(with: traits) }
        page = resolve(Theme.mist)
        base = resolve(Theme.floor)
        wallTop = resolve(Theme.wall)
        wallSide = scheme == .dark ? UIColor(white: 0.46, alpha: 1) : UIColor(white: 0.97, alpha: 1)
        cobalt = resolve(Theme.cobalt)
        marker = resolve(Theme.obstacle)
    }
}

@MainActor
private final class DollhouseModel: NSObject {
    /// In metres. Walls stop low, like a model with its roof and upper walls lifted away.
    private static let wallHeight: CGFloat = 0.6
    private static let baseDepth: CGFloat = 0.16
    private static let fieldOfView: CGFloat = 22
    private static let restingElevation: Float = 60 * .pi / 180
    private static let restingAzimuth: Float = -14 * .pi / 180
    /// The camera stays above the model: its underside has nothing to show.
    private static let elevations: ClosedRange<Float> = (30 * .pi / 180)...(88 * .pi / 180)

    /// Where the camera is, as a position on a sphere around `target`.
    private struct Pose {
        var azimuth: Float
        var elevation: Float
        var distance: Float
        var target = SIMD3<Float>(repeating: 0)
    }

    /// A pose being moved to, one display frame at a time.
    private struct Glide {
        let from: Pose
        let to: Pose
        let duration: Double
        var elapsed: Double = 0
    }

    var onRoom: (String) -> Void = { _ in }
    var onObstacle: (FloorPlan.Obstacle) -> Void = { _ in }
    var onMoved: (Bool) -> Void = { _ in }

    private weak var view: SCNView?
    private let scene = SCNScene()
    private let camera = SCNNode()
    private let key = SCNNode()
    private let ambient = SCNNode()
    private let baseNode = SCNNode()
    private let floorNode = SCNNode()
    private let wallsRoot = SCNNode()
    private let groundNode = SCNNode()
    private let labels = SCNNode()
    private let markers = SCNNode()
    private let robot = SCNNode()
    private let pulse = SCNNode()
    private let robotShell: SCNShape = {
        let radius: CGFloat = 0.3
        let outline = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        // The default tolerance suits shapes metres across, and turns a disc this small into a square.
        outline.flatness = 0.004
        let shape = SCNShape(path: outline, extrusionDepth: 0.14)
        shape.chamferRadius = 0.04
        return shape
    }()

    private var plan: FloorPlan?
    private var picked: [String] = []
    private var numbered = true
    private var active = false
    private var paused = false
    private var trailStyle = PlanCanvas.TrailStyle.band
    /// Whether a job's rooms are marked. The robot's own pulse only follows `active`.
    private var inJob: Bool { active || paused }
    private var builtWalls: Path?
    private var builtBounds: CGRect?
    private var building = false
    private var hasShape = false
    private var introduced = false
    private var scheme: ColorScheme = .light
    private var reduceMotion = false
    private var size: CGSize = .zero
    private var surface: SurfaceKey?
    private var outline = Path()
    private var labelKey: [String] = []
    private var markerKey: [String] = []
    private var robotAngle: Float = 0
    private var pulsing = false

    private var pose = Pose(azimuth: restingAzimuth, elevation: restingElevation, distance: 40)
    private var moved = false
    private var resets = 0
    private var pinchStart: Float = 40
    private var spin: Float = 0
    private var glide: Glide?
    private var ticker: CADisplayLink?

    private struct SurfaceKey: Equatable {
        let trail: Path
        let trailStyle: PlanCanvas.TrailStyle
        let picked: [String]
        let active: Bool
        let rooms: [String]
        let scheme: ColorScheme
        let structures: [Path]
        let floors: [Path]
        let palette: [Int]
    }

    private var metres: CGFloat { (plan?.pixelSize ?? 5) / 100 }

    private func place(_ p: CGPoint, height: CGFloat = 0) -> SCNVector3 {
        guard let bounds = plan?.bounds else { return SCNVector3Zero }
        return SCNVector3(Float((p.x - bounds.midX) * metres), Float(height), Float((p.y - bounds.midY) * metres))
    }

    private func mapPoint(_ v: SCNVector3) -> CGPoint? {
        guard let bounds = plan?.bounds else { return nil }
        return CGPoint(x: CGFloat(v.x) / metres + bounds.midX, y: CGFloat(v.z) / metres + bounds.midY)
    }

    // MARK: Setup

    func attach(to view: SCNView) {
        self.view = view
        view.scene = scene
        // Every iPhone that runs this app has this family. The GPU of an older simulator doesn't,
        // and it draws nothing at all with multisampling, despite saying it's supported.
        view.antialiasingMode = view.device?.supportsFamily(.apple4) == true ? .multisampling4X : .none
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.isAccessibilityElement = false

        let lens = SCNCamera()
        lens.fieldOfView = Self.fieldOfView
        lens.zNear = 0.5
        lens.zFar = 500
        camera.camera = lens
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 540
        sun.castsShadow = true
        sun.shadowMode = .forward
        sun.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 5
        sun.shadowColor = UIColor(white: 0, alpha: 0.4)
        // Fitted to the model in `apply`. The automatic fit shades the page around it.
        sun.automaticallyAdjustsShadowProjection = false
        sun.zNear = 1
        sun.zFar = 200
        key.light = sun
        key.eulerAngles = SCNVector3(-1.02, -0.62, 0)
        key.simdPosition = key.simdWorldFront * -80
        scene.rootNode.addChildNode(key)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 540
        ambient.light = fill
        scene.rootNode.addChildNode(ambient)

        for node in [baseNode, floorNode, wallsRoot, groundNode, labels, markers, robot] {
            scene.rootNode.addChildNode(node)
        }
        buildRobot()

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let turn = UIPanGestureRecognizer(target: self, action: #selector(turned))
        turn.maximumNumberOfTouches = 1
        view.addGestureRecognizer(turn)
        let shift = UIPanGestureRecognizer(target: self, action: #selector(shifted))
        shift.minimumNumberOfTouches = 2
        shift.delegate = self
        view.addGestureRecognizer(shift)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    func stop() {
        endMotion()
        view?.scene?.isPaused = true
    }

    // MARK: Updating

    func show(_ plan: FloorPlan, picked: [String], numbered: Bool, active: Bool, paused: Bool,
              trailStyle: PlanCanvas.TrailStyle, scheme: ColorScheme, reduceMotion: Bool, size: CGSize) {
        let restyled = scheme != self.scheme
        self.plan = plan
        self.picked = picked
        self.numbered = numbered
        self.active = active
        self.paused = paused
        self.trailStyle = trailStyle
        self.scheme = scheme
        self.reduceMotion = reduceMotion
        if size != self.size {
            self.size = size
            if hasShape { frameCamera() }
        }

        let colors = DollhouseColors(scheme)
        scene.background.contents = colors.page
        robotShell.firstMaterial?.diffuse.contents = colors.cobalt
        pulse.geometry?.firstMaterial?.diffuse.contents = colors.cobalt

        if builtWalls != plan.walls || builtBounds != plan.bounds || restyled {
            buildShape(plan, colors: colors)
        }
        guard hasShape else { return }
        paintSurface(plan, picked: picked, active: inJob, colors: colors)
        placeLabels(plan, picked: picked, numbered: numbered)
        placeMarkers(plan, colors: colors)
        moveRobot(plan, active: active)
    }

    private func buildShape(_ plan: FloorPlan, colors: DollhouseColors) {
        guard !building else { return }
        building = true
        Task { [weak self] in
            let shape = await Task.detached(priority: .userInitiated) { DollhouseShape(plan) }.value
            guard let self else { return }
            self.building = false
            self.builtWalls = plan.walls
            self.builtBounds = plan.bounds
            self.apply(shape, plan: plan, colors: colors)
            self.hasShape = true
            self.surface = nil
            self.markerKey = []
            self.labelKey = []
            self.frameCamera()
            // Picks can change while the shape is being traced, so these are the latest.
            self.paintSurface(plan, picked: self.picked, active: self.inJob, colors: colors)
            self.placeLabels(plan, picked: self.picked, numbered: self.numbered)
            self.placeMarkers(plan, colors: colors)
            self.moveRobot(plan, active: self.active)
            self.introduce()
        }
    }

    private func bezier(_ loops: [[CGPoint]], in plan: FloorPlan) -> UIBezierPath {
        let path = UIBezierPath()
        path.usesEvenOddFillRule = true
        let scale = plan.pixelSize / 100
        for loop in loops {
            guard let first = loop.first else { continue }
            func metres(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x - plan.bounds.midX) * scale, y: (p.y - plan.bounds.midY) * scale)
            }
            path.move(to: metres(first))
            for point in loop.dropFirst() { path.addLine(to: metres(point)) }
            path.close()
        }
        path.flatness = 0.02
        return path
    }

    private func matte(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = color
        return material
    }

    private func apply(_ shape: DollhouseShape, plan: FloorPlan, colors: DollhouseColors) {
        // A quarter turn about X lays a shape flat: its x stays x, and its y becomes the scene's z.
        let flat = SCNVector3(Float.pi / 2, 0, 0)

        outline = Path()
        for loop in shape.base {
            outline.addLines(loop)
            outline.closeSubpath()
        }

        let base = SCNShape(path: bezier(shape.base, in: plan), extrusionDepth: Self.baseDepth)
        base.materials = [matte(colors.base)]
        baseNode.geometry = base
        baseNode.eulerAngles = flat
        baseNode.position = SCNVector3(0, Float(-Self.baseDepth / 2), 0)

        wallsRoot.childNodes.forEach { $0.removeFromParentNode() }
        let walls = SCNShape(path: bezier(shape.walls, in: plan), extrusionDepth: Self.wallHeight)
        // Front, back, then sides. Laid flat, the back faces up: a dark cut along the wall
        // tops, which reads just like the lines on the 2D plan.
        walls.materials = [matte(colors.wallSide), matte(colors.wallTop), matte(colors.wallSide)]
        let wallNode = SCNNode(geometry: walls)
        wallNode.eulerAngles = flat
        wallNode.position = SCNVector3(0, Float(Self.wallHeight / 2), 0)
        wallNode.name = "walls"
        wallsRoot.addChildNode(wallNode)

        let width = plan.bounds.width * metres, depth = plan.bounds.height * metres
        key.light?.orthographicScale = hypot(width, depth) * 0.62
        let floor = SCNPlane(width: width, height: depth)
        let surface = SCNMaterial()
        surface.lightingModel = .lambert
        surface.transparencyMode = .aOne
        surface.writesToDepthBuffer = false
        floor.materials = [surface]
        floorNode.geometry = floor
        floorNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        floorNode.position = SCNVector3(0, 0.002, 0)
        floorNode.name = "floor"

        let reach = max(width, depth) * 3
        let ground = SCNPlane(width: reach, height: reach)
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        ground.materials = [catcher]
        groundNode.geometry = ground
        groundNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        groundNode.position = SCNVector3(0, Float(-Self.baseDepth), 0)
    }

    private func paintSurface(_ plan: FloorPlan, picked: [String], active: Bool, colors: DollhouseColors) {
        let key = SurfaceKey(trail: plan.trail, trailStyle: trailStyle, picked: picked, active: active,
                             rooms: plan.rooms.filter(\.active).map(\.id), scheme: scheme,
                             structures: [plan.carpets, plan.noGo, plan.noMop, plan.virtualWalls, plan.activeZones]
                                 + plan.annotations.map(\.path),
                             floors: plan.rooms.flatMap { [$0.path, $0.texture] },
                             palette: plan.rooms.map(\.palette))
        guard key != surface else { return }
        surface = key

        let longest: CGFloat = 2048
        let scale = longest / max(plan.bounds.width, plan.bounds.height)
        let size = CGSize(width: plan.bounds.width * scale, height: plan.bounds.height * scale)
        let renderer = ImageRenderer(content:
            FloorSurface(plan: plan, picked: Set(picked), active: active, trailStyle: trailStyle, outline: outline)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        renderer.isOpaque = false
        floorNode.geometry?.firstMaterial?.diffuse.contents = renderer.uiImage
    }

    // MARK: Labels and markers

    private func billboard(_ image: UIImage?, name: String, at position: SCNVector3, order: Int) -> SCNNode {
        let node = SCNNode()
        guard let image else { return node }
        // Sized so a label is about its natural point size at the resting view.
        let unit = pointSize
        let plane = SCNPlane(width: image.size.width * unit, height: image.size.height * unit)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]
        node.geometry = plane
        node.name = name
        node.position = position
        node.renderingOrder = order
        node.castsShadow = false
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    /// How many metres one point covers at the distance of the resting view.
    private var pointSize: CGFloat {
        let visible = 2 * CGFloat(restingDistance) * tan(Self.fieldOfView / 2 * .pi / 180)
        return visible / max(size.height, 1)
    }

    private func picture<Content: View>(_ content: Content) -> UIImage? {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }

    private func placeLabels(_ plan: FloorPlan, picked: [String], numbered: Bool) {
        let key = plan.rooms.map {
            "\($0.id):\($0.name):\($0.label):\(picked.firstIndex(of: $0.id) ?? -1):\(numbered):\(inJob && $0.active):\(scheme)"
        }
        guard key != labelKey else { return }
        labelKey = key
        labels.childNodes.forEach { $0.removeFromParentNode() }
        for room in plan.rooms {
            let position = picked.firstIndex(of: room.id).map { $0 + 1 }
            let tag = RoomTag(name: room.name, picked: position != nil, order: numbered ? position : nil,
                              working: inJob && room.active)
            let node = billboard(picture(tag), name: "room:\(room.id)",
                                 at: place(room.label, height: Self.wallHeight * 0.55), order: 200)
            labels.addChildNode(node)
        }
    }

    private func placeMarkers(_ plan: FloorPlan, colors: DollhouseColors) {
        let key = plan.obstacles.map { "\($0.id):\($0.symbol):\($0.point)" }
            + ["\(String(describing: plan.dock)):\(plan.isDocked):\(String(describing: plan.goToTarget)):\(scheme)"]
        guard key != markerKey else { return }
        markerKey = key
        markers.childNodes.forEach { $0.removeFromParentNode() }
        for obstacle in plan.obstacles {
            let node = billboard(picture(MarkerBadge(symbol: obstacle.symbol, fill: Theme.obstacle, ink: .black.opacity(0.78))),
                                 name: "obstacle:\(obstacle.id)", at: place(obstacle.point, height: 0.5), order: 150)
            markers.addChildNode(node)
        }
        // While the robot sits on its dock, the badge would only hide it.
        if let dock = plan.dock, !plan.isDocked {
            let node = billboard(picture(MarkerBadge(symbol: DockGlyph.symbolName, fill: Theme.floor, ink: Theme.wall)),
                                 name: "dock", at: place(dock, height: 0.45), order: 140)
            markers.addChildNode(node)
        }
        if let target = plan.goToTarget {
            let node = billboard(picture(MarkerBadge(symbol: "mappin", fill: Theme.cobalt, ink: Theme.onCobalt)),
                                 name: "target", at: place(target, height: 0.5), order: 160)
            markers.addChildNode(node)
        }
    }

    // MARK: Robot

    private func buildRobot() {
        let colors = DollhouseColors(.light)
        let body = robotShell
        body.materials = [matte(colors.cobalt)]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.renderingOrder = 100
        bodyNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        bodyNode.position = SCNVector3(0, 0.09, 0)
        robot.addChildNode(bodyNode)

        let turret = SCNCylinder(radius: 0.11, height: 0.07)
        turret.materials = [matte(.white)]
        let turretNode = SCNNode(geometry: turret)
        turretNode.renderingOrder = 101
        turretNode.position = SCNVector3(0, 0.19, 0)
        robot.addChildNode(turretNode)

        // Marks the robot's front.
        let nose = UIBezierPath()
        nose.move(to: CGPoint(x: 0, y: -0.26))
        nose.addLine(to: CGPoint(x: 0.08, y: -0.14))
        nose.addLine(to: CGPoint(x: -0.08, y: -0.14))
        nose.close()
        let noseShape = SCNShape(path: nose, extrusionDepth: 0.012)
        noseShape.materials = [matte(.white)]
        let noseNode = SCNNode(geometry: noseShape)
        noseNode.renderingOrder = 102
        noseNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        noseNode.position = SCNVector3(0, 0.166, 0)
        robot.addChildNode(noseNode)

        let ring = SCNTorus(ringRadius: 0.4, pipeRadius: 0.012)
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = colors.cobalt
        ring.materials = [glow]
        pulse.geometry = ring
        // Seen through walls too, so you can always find it.
        for material in [body.firstMaterial, turret.firstMaterial, noseShape.firstMaterial, glow] {
            material?.readsFromDepthBuffer = false
        }
        pulse.position = SCNVector3(0, 0.03, 0)
        pulse.opacity = 0
        pulse.castsShadow = false
        robot.addChildNode(pulse)
    }

    private func moveRobot(_ plan: FloorPlan, active: Bool) {
        robot.isHidden = plan.robot == nil
        guard let point = plan.robot else { return }

        // Take the short way round when the heading passes north.
        let target = -Float(plan.heading * .pi / 180)
        var turn = (target - robotAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if turn > .pi { turn -= 2 * .pi }
        if turn < -.pi { turn += 2 * .pi }
        robotAngle += turn

        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion || !introduced ? 0 : 2
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
        robot.position = place(point)
        robot.eulerAngles = SCNVector3(0, robotAngle, 0)
        SCNTransaction.commit()

        let shouldPulse = active && !reduceMotion
        guard shouldPulse != pulsing else { return }
        pulsing = shouldPulse
        pulse.removeAllActions()
        pulse.opacity = 0
        if shouldPulse {
            let reset = SCNAction.run { node in
                node.scale = SCNVector3(1, 1, 1)
                node.opacity = 0.7
            }
            let grow = SCNAction.group([.scale(to: 2.1, duration: 1.6), .fadeOut(duration: 1.6)])
            grow.timingMode = .easeOut
            pulse.runAction(.repeatForever(.sequence([reset, grow])))
        }
    }

    // MARK: Camera

    private var restingPose: Pose {
        Pose(azimuth: Self.restingAzimuth, elevation: Self.restingElevation, distance: restingDistance)
    }

    /// How far back the camera sits for the whole model to fit, tilted, in the view.
    private var restingDistance: Float {
        guard let bounds = plan?.bounds, size.width > 0, size.height > 0 else { return 40 }
        let tangent = tan(Float(Self.fieldOfView) / 2 * .pi / 180)
        let aspect = Float(size.width / size.height)
        let width = Float(bounds.width * metres), depth = Float(bounds.height * metres)
        // Turning the model shows its diagonal, so leave room for the corners.
        let spin = abs(sin(Self.restingAzimuth)), straight = abs(cos(Self.restingAzimuth))
        let across = width * straight + depth * spin
        let along = (depth * straight + width * spin) * sin(Self.restingElevation)
        return max(along / 2 / tangent, across / 2 / (tangent * aspect)) * 1.04
    }

    private func aim() {
        let eye = SIMD3<Float>(sin(pose.azimuth) * cos(pose.elevation), sin(pose.elevation),
                               cos(pose.azimuth) * cos(pose.elevation)) * pose.distance
        let forward = simd_normalize(-eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        camera.simdTransform = simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(pose.target + eye, 1))
    }

    private func frameCamera() {
        if !moved && glide == nil { pose = restingPose }
        aim()
    }

    /// Starts from above, matching the 2D plan, then tips over as the walls rise.
    private func introduce() {
        guard !introduced else { return }
        introduced = true
        guard !reduceMotion else { return }

        let duration = 0.9
        var above = restingPose
        above.azimuth = 0
        above.elevation = .pi / 2 - 0.001
        pose = above
        aim()
        move(to: restingPose, duration: duration)

        wallsRoot.scale = SCNVector3(1, 0.02, 1)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        wallsRoot.scale = SCNVector3(1, 1, 1)
        SCNTransaction.commit()
    }

    func reset(to count: Int) {
        guard count != resets else { return }
        resets = count
        moved = false
        endMotion()
        // Turn back the short way, however many times the model went round.
        pose.azimuth = Self.restingAzimuth + remainder(pose.azimuth - Self.restingAzimuth, 2 * .pi)
        if reduceMotion {
            pose = restingPose
            aim()
        } else {
            move(to: restingPose, duration: 0.5)
        }
    }

    private func move(to end: Pose, duration: Double) {
        glide = Glide(from: pose, to: end, duration: duration)
        startTicking()
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
    }

    private func endMotion() {
        ticker?.invalidate()
        ticker = nil
        glide = nil
        spin = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let step = link.targetTimestamp - link.timestamp
        if var current = glide {
            current.elapsed += step
            let linear = Float(min(1, current.elapsed / current.duration))
            let t = linear * linear * (3 - 2 * linear)
            func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
            pose = Pose(azimuth: mix(current.from.azimuth, current.to.azimuth),
                        elevation: mix(current.from.elevation, current.to.elevation),
                        distance: mix(current.from.distance, current.to.distance),
                        target: current.from.target + (current.to.target - current.from.target) * t)
            glide = linear < 1 ? current : nil
        } else {
            // A flicked model slows to a stop, like the globe in Maps.
            pose.azimuth += spin * Float(step)
            spin *= pow(0.03, Float(step))
        }
        aim()
        if glide == nil && abs(spin) < 0.03 { endMotion() }
    }

    private func noteMoved() {
        guard !moved else { return }
        moved = true
        onMoved(true)
    }

    // MARK: Touch

    @objc private func turned(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .began { endMotion() }
        // A drag across the whole screen is about half a turn.
        let speed = Float.pi / Float(max(view.bounds.width, 1))
        let drag = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        pose.azimuth -= Float(drag.x) * speed
        pose.elevation = min(Self.elevations.upperBound, max(Self.elevations.lowerBound, pose.elevation + Float(drag.y) * speed * 0.7))
        aim()
        noteMoved()
        if gesture.state == .ended, !reduceMotion {
            spin = -Float(gesture.velocity(in: view).x) * speed * 0.6
            if abs(spin) > 0.2 { startTicking() } else { spin = 0 }
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            endMotion()
            pinchStart = pose.distance
        }
        let fit = restingDistance
        pose.distance = min(fit * 1.2, max(fit * 0.25, pinchStart / Float(max(gesture.scale, 0.01))))
        aim()
        noteMoved()
    }

    @objc private func shifted(_ gesture: UIPanGestureRecognizer) {
        guard let view, let bounds = plan?.bounds else { return }
        if gesture.state == .began { endMotion() }
        let drag = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        let visible = 2 * pose.distance * tan(Float(Self.fieldOfView) / 2 * .pi / 180)
        let perPoint = visible / Float(max(view.bounds.height, 1))
        let right = SIMD3<Float>(cos(pose.azimuth), 0, -sin(pose.azimuth))
        let ahead = SIMD3<Float>(-sin(pose.azimuth), 0, -cos(pose.azimuth))
        var target = pose.target - right * Float(drag.x) * perPoint + ahead * Float(drag.y) * perPoint / sin(pose.elevation)
        // Keep the model in view, however far it's dragged.
        let halfWidth = Float(bounds.width * metres) / 2, halfDepth = Float(bounds.height * metres) / 2
        target.x = min(halfWidth, max(-halfWidth, target.x))
        target.z = min(halfDepth, max(-halfDepth, target.z))
        pose.target = target
        aim()
        noteMoved()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let view, let plan else { return }
        let hits = view.hitTest(gesture.location(in: view), options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ])

        for hit in hits {
            guard let name = hit.node.name else { continue }
            if name.hasPrefix("obstacle:") {
                let id = String(name.dropFirst("obstacle:".count))
                if let obstacle = plan.obstacles.first(where: { $0.id == id }) { onObstacle(obstacle) }
                return
            }
            if name.hasPrefix("room:") {
                onRoom(String(name.dropFirst("room:".count)))
                return
            }
        }

        // A wall or doorway counts as the room beside it, so taps don't need to be exact.
        let surfaces = hits.filter { $0.node === floorNode || $0.node.name == "walls" }
        guard let hit = surfaces.first, let point = mapPoint(hit.worldCoordinates) else { return }
        let reach = Int((60 / plan.pixelSize).rounded())
        if let id = plan.roomID(at: point) ?? plan.nearestFloor(to: point, within: reach).flatMap(plan.roomID(at:)) {
            onRoom(id)
        }
    }
}

// MARK: Surfaces

/// The floor of the model: the same colours and textures as the 2D plan, without its markers.
private struct FloorSurface: View {
    let plan: FloorPlan
    let picked: Set<String>
    let active: Bool
    let trailStyle: PlanCanvas.TrailStyle
    /// The edge of the model. Floors are grown to run under the walls, and this stops them there.
    let outline: Path

    var body: some View {
        Canvas { context, size in
            let t = PlanTransform(bounds: plan.bounds, size: size)
            context.clip(to: outline.applying(t.affine), style: FillStyle(eoFill: true))
            var map = context
            map.concatenate(t.affine)
            let softness = max(0.8, t.scale * 0.55)

            for room in plan.rooms {
                let color = picked.contains(room.id) ? Theme.selected : Theme.rooms[room.palette]
                var roomContext = context
                if active && room.active {
                    roomContext.addFilter(.shadow(color: Theme.cobalt.opacity(0.75), radius: 40))
                }
                roomContext.drawLayer { layer in
                    var cut = layer
                    cut.addFilter(.blur(radius: 0.5))
                    cut.addFilter(.alphaThreshold(min: 0.5, color: color))
                    cut.addFilter(.blur(radius: softness))
                    cut.drawLayer { inner in
                        inner.concatenate(t.affine)
                        inner.fill(room.path, with: .color(.black), style: FillStyle(antialiased: false))
                        // Grown a little so floors run under the walls, with no gap to see through.
                        inner.stroke(room.path, with: .color(.black), lineWidth: 2.4)
                    }
                    var texture = layer
                    texture.blendMode = .sourceAtop
                    texture.concatenate(t.affine)
                    texture.stroke(room.texture, with: .color(Theme.ink.opacity(0.09)), lineWidth: 0.9 / t.scale)
                }
            }

            // Sized as on a phone. In the texture's own points, lines would be hairlines.
            var phone = context
            phone.scaleBy(x: 5, y: 5)
            let phoneSize = PlanTransform(bounds: plan.bounds, size: CGSize(width: size.width / 5, height: size.height / 5))

            PlanCanvas.drawCarpets(of: plan, in: phone, phoneSize)
            PlanCanvas.drawTrail(of: plan, style: trailStyle, in: map, pointSize: 5 / t.scale,
                                 strong: context.environment.colorSchemeContrast == .increased)
            PlanCanvas.drawStructures(of: plan, in: phone, phoneSize, showsTarget: false)
        }
    }
}

private struct RoomTag: View {
    let name: String
    let picked: Bool
    /// Its place in the cleaning order, for a robot that follows one.
    let order: Int?
    /// Part of the job under way, marked as on the flat plan. A glow here would hide behind the walls.
    let working: Bool

    private var title: Text {
        if let order { return Text("\(order)  \(name)") }
        if picked { return Text("\(Image(systemName: "checkmark"))  \(name)") }
        return working ? Text("\(Text(Image(systemName: "sparkles")).foregroundColor(Theme.cobalt))  \(name)") : Text(name)
    }

    var body: some View {
        title
            .font(.caption.weight(.semibold))
            .foregroundStyle(picked ? Theme.onCobalt : Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(picked ? AnyShapeStyle(Theme.cobalt) : AnyShapeStyle(Theme.floor.opacity(0.9)), in: Capsule())
            .fixedSize()
    }
}

private struct MarkerBadge: View {
    let symbol: String
    let fill: Color
    let ink: Color

    var body: some View {
        AppSymbol(name: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 22, height: 22)
            .background(fill, in: Circle())
            .overlay(Circle().stroke(Theme.floor, lineWidth: 1.5))
    }
}

extension DollhouseModel: UIGestureRecognizerDelegate {
    /// Pinching and moving with two fingers happen together.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension FloorPlan {
    var isDocked: Bool {
        guard let robot, let dock else { return false }
        return hypot(robot.x - dock.x, robot.y - dock.y) * pixelSize < 60
    }
}
