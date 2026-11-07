import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum ZoneCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Below this, on screen, four handles would leave no body to drag.
    private static let roomForFour: CGFloat = 66

    var opposite: ZoneCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    static func shown(on rect: CGRect) -> [ZoneCorner] {
        min(rect.width, rect.height) < roomForFour ? [.bottomRight] : allCases
    }
}

enum PlanHaptic {
    case selection, hold, warning, success

    @MainActor func play() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .hold: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

extension PlanTransform {
    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

private extension CGPoint {
    static func + (point: CGPoint, offset: CGSize) -> CGPoint {
        CGPoint(x: point.x + offset.width, y: point.y + offset.height)
    }

    func offset(to other: CGPoint) -> CGSize { CGSize(width: other.x - x, height: other.y - y) }
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
}

/// What every touch on Home's plan means. `TouchSurface` only reports what the fingers did,
/// so all of this can be tested without a screen. Positions in are in view points.
@MainActor
final class PlanTouches {
    enum Hit: Equatable { case handle(ZoneCorner), zone, pin, plan }

    private enum Session {
        case none
        case hold(start: CGPoint)
        case zone(grab: CGSize)
        case corner(anchor: CGPoint, grab: CGSize)
        case pin(grab: CGSize)
        case plan(start: CGPoint, canTeach: Bool)
    }

    /// How far off the floor a finger can land and still mean the floor.
    private static let floorReach: CGFloat = 22
    private static let obstacleReach: CGFloat = 22
    private static let stretchStart: CGFloat = 16
    private static let nextZoneOffset: CGFloat = 24
    /// A drag this long at fit zoom looks like someone trying to draw, so it earns the hold tip.
    private static let teachingDrag: CGFloat = 40

    let picks = Picks()

    var roomName: (String) -> String = { _ in "Room" }
    var onObstacle: (FloorPlan.Obstacle) -> Void = { _ in }
    var onRoomPicked: () -> Void = {}
    var onHeld: () -> Void = {}
    var onFailedDrag: () -> Void = {}
    var haptic: (PlanHaptic) -> Void = { $0.play() }
    var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    /// The Rooms sheet edits a list of rooms, so holds wait until it's closed.
    var sheetIsOpen = false

    private(set) var plan: FloorPlan?
    private(set) var transform: PlanTransform?
    private(set) var isZoomed = false
    private var visible = CGRect.zero
    private var session = Session.none
    private var waiting: (() -> Void)?

    /// Placing needs to know where the flat plan is on screen, which it can't until it's shown.
    func whenPlanIsShown(_ action: @escaping () -> Void) {
        waiting = action
    }

    func update(plan: FloorPlan, transform: PlanTransform, size: CGSize, insets: EdgeInsets, isZoomed: Bool) {
        self.plan = plan
        self.transform = transform
        self.isZoomed = isZoomed
        visible = CGRect(x: insets.leading, y: insets.top,
                         width: max(0, size.width - insets.leading - insets.trailing),
                         height: max(0, size.height - insets.top - insets.bottom))
        if picks.planIsZoomed != isZoomed { picks.planIsZoomed = isZoomed }
        if let waiting {
            self.waiting = nil
            // This runs while SwiftUI is drawing, when picks can't change yet.
            DispatchQueue.main.async { waiting() }
        }
    }

    /// Checks what's picked against a new map now, not when the primary is tapped.
    func planChanged(to plan: FloorPlan?) {
        picks.keepOnFloor(of: plan, reach: pixels(Self.floorReach))
    }

    // MARK: Hit-testing

    /// Pick views never take touches, so a pinch still works over a large zone. This asks what's under a finger instead.
    func hit(_ point: CGPoint) -> Hit {
        guard let transform else { return .plan }
        if isOnPin(point) { return .pin }
        guard let index = picks.activeZone, picks.zones.indices.contains(index) else { return .plan }
        let rect = transform.toView(picks.zones[index])
        if let corner = nearestHandle(to: point, on: rect) { return .handle(corner) }
        return rect.contains(point) ? .zone : .plan
    }

    /// A handle reaches a full finger's width outward, but only a third of the way in,
    /// or a small zone would be all handle with no body left to drag.
    private func nearestHandle(to point: CGPoint, on rect: CGRect) -> ZoneCorner? {
        let outward = Metric.hitTarget / 2
        let reach = rect.contains(point) ? min(outward, min(rect.width, rect.height) / 3) : outward
        return ZoneCorner.shown(on: rect)
            .map { (corner: $0, at: $0.point(in: rect)) }
            .filter { abs($0.at.x - point.x) <= reach && abs($0.at.y - point.y) <= reach }
            .min { point.distance(to: $0.at) < point.distance(to: $1.at) }?.corner
    }

    private func isOnPin(_ point: CGPoint) -> Bool {
        guard let pin = picks.pin, let transform else { return false }
        let tip = transform.toView(pin)
        let reach = Metric.hitTarget / 2
        let top = tip.y - PlanPin.headRise - reach
        return CGRect(x: tip.x - reach, y: top, width: reach * 2, height: tip.y + reach - top).contains(point)
    }

    private func zone(at point: CGPoint) -> Int? {
        guard let transform else { return nil }
        if let active = picks.activeZone, picks.zones.indices.contains(active),
           transform.toView(picks.zones[active]).contains(point) { return active }
        return picks.zones.lastIndex { transform.toView($0).contains(point) }
    }

    private func obstacle(at point: CGPoint) -> FloorPlan.Obstacle? {
        guard let plan, let transform else { return nil }
        let map = transform.toMap(point)
        let reach = Self.obstacleReach / transform.scale
        return plan.obstacles
            .filter { hypot($0.point.x - map.x, $0.point.y - map.y) <= reach }
            .min { $0.point.distance(to: map) < $1.point.distance(to: map) }
    }

    /// The drawn label first, because a small room's label can be bigger than the room.
    /// Then the room under the finger, then one just out of reach, which catches walls and doorways.
    func room(at point: CGPoint) -> String? {
        guard let plan, let transform else { return nil }
        if let id = roomLabel(at: point) { return id }
        let map = transform.toMap(point)
        if let id = plan.roomID(at: map) { return id }
        return plan.nearestFloor(to: map, within: pixels(Self.floorReach)).flatMap(plan.roomID(at:))
    }

    private func roomLabel(at point: CGPoint) -> String? {
        guard let plan, let transform else { return nil }
        let hits = plan.rooms.compactMap { room -> (id: String, distance: CGFloat)? in
            let centre = transform.toView(room.label)
            var size = PlanLabel.size(of: room.name, mark: mark(for: room.id))
            let box = transform.toView(room.path.boundingRect)
            if min(box.width, box.height) < Metric.hitTarget { size.height = max(size.height, Metric.hitTarget) }
            let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            return frame.contains(point) ? (room.id, centre.distance(to: point)) : nil
        }
        return hits.min { $0.distance < $1.distance }?.id
    }

    private func mark(for id: String) -> String? {
        guard let index = picks.rooms.firstIndex(of: id) else { return nil }
        return picks.rules.roomOrder ? "\(index + 1)" : "0"
    }

    private func pixels(_ points: CGFloat) -> Int {
        Int((points / (transform?.scale ?? 1)).rounded())
    }

    /// Stretches stop at what's on screen, because the plan doesn't scroll under the finger.
    private func clamped(_ point: CGPoint) -> CGPoint {
        visible.isEmpty ? point : Picks.clamp(point, to: visible)
    }

    // MARK: Tap

    func tap(at point: CGPoint) {
        guard !picks.sending else {
            if let found = obstacle(at: point) { onObstacle(found) }
            return
        }
        if picks.pin != nil {
            if !isOnPin(point) { withAnimation(PickMotion.settle) { picks.clear() } }
            return
        }
        if tapZones(at: point) { return }
        if let found = obstacle(at: point) {
            onObstacle(found)
        } else if picks.rules.rooms, let id = room(at: point) {
            pick(room: id)
        }
    }

    /// True when the tap was spent on a zone, so it goes no further.
    private func tapZones(at point: CGPoint) -> Bool {
        guard !picks.zones.isEmpty else { return false }
        if let index = zone(at: point) {
            picks.activate(zone: index)
            return true
        }
        guard picks.activeZone != nil else { return false }
        picks.deactivateZone()
        return true
    }

    /// Tapping a room, from the plan, the sheet or VoiceOver. Nothing here starts the robot.
    func pick(room id: String) {
        guard !picks.sending else { return }
        if picks.rules.working {
            picks.say(PickNote.working)
        } else if !picks.zones.isEmpty {
            picks.say(PickNote.clearZones)
        } else if picks.pin != nil {
            picks.clear()
            announce("Pin removed.")
        } else {
            picks.toggle(id)
            haptic(.selection)
            onRoomPicked()
            announce(toggleSpeech(for: id))
        }
    }

    private func toggleSpeech(for id: String) -> String {
        let state = picks.rooms.contains(id) ? "picked" : "not picked"
        let job = picks.rooms.isEmpty ? nil : picks.bar(name: roomName).primary?.titles.first
        return "\(roomName(id)) \(state)." + (job.map { " \($0) available." } ?? "")
    }

    // MARK: Hold

    /// False when a hold claimed nothing, which leaves that finger free to move the plan.
    var ownsTheTouch: Bool {
        switch session {
        case .none, .plan: return false
        default: return true
        }
    }

    func holdBegan(at point: CGPoint) {
        guard let plan, let transform, !picks.sending, !sheetIsOpen else { return }
        guard hit(point) == .plan else {
            // A slow start on something movable is still a drag, not a request for something new.
            haptic(.hold)
            dragBegan(from: point, at: point)
            return
        }
        guard picks.rules.canPin,
              let spot = plan.nearestFloor(to: transform.toMap(point), within: pixels(Self.floorReach)) else { return }
        guard !picks.rules.working else {
            picks.say(PickNote.working)
            return
        }
        guard picks.beginHold(at: spot, on: plan) else {
            refuseZone()
            return
        }
        haptic(.hold)
        onHeld()
        session = .hold(start: point)
    }

    func holdMoved(to point: CGPoint) {
        guard case .hold(let start) = session else {
            dragMoved(to: point)
            return
        }
        guard let plan, let transform else { return }
        let finger = transform.toMap(clamped(point))
        if !picks.rules.zones {
            picks.dragPin(to: finger, on: plan)
        } else if start.distance(to: point) > Self.stretchStart {
            picks.stretch(to: finger, on: plan)
        } else {
            picks.unstretch(on: plan)
        }
    }

    func holdEnded() {
        guard case .hold = session else {
            dragEnded()
            return
        }
        session = .none
        if let plan { withAnimation(PickMotion.spring) { picks.endHold(on: plan) } }
    }

    // MARK: Drag

    /// `down` is where the finger landed, and `now` is where it's got to. True if something was grabbed.
    @discardableResult
    func dragBegan(from down: CGPoint, at now: CGPoint) -> Bool {
        guard let plan, let transform, !picks.sending else { return false }
        let finger = transform.toMap(now)
        switch hit(down) {
        case .handle(let corner):
            guard let index = picks.activeZone else { return false }
            let rect = picks.zones[index]
            picks.beginEdit(zone: index)
            session = .corner(anchor: corner.opposite.point(in: rect), grab: finger.offset(to: corner.point(in: rect)))
            return true
        case .zone:
            guard let index = picks.activeZone else { return false }
            picks.beginEdit(zone: index)
            session = .zone(grab: finger.offset(to: picks.zones[index].origin))
            return true
        case .pin:
            guard let pin = picks.pin else { return false }
            picks.grabPin()
            session = .pin(grab: finger.offset(to: pin))
            return true
        case .plan:
            let onFloor = plan.nearestFloor(to: transform.toMap(down), within: 0) != nil
            session = .plan(start: down, canTeach: !isZoomed && onFloor)
            return false
        }
    }

    func dragMoved(to point: CGPoint) {
        guard let plan, let transform else { return }
        switch session {
        case .zone(let grab):
            picks.moveEdit(to: transform.toMap(point) + grab, on: plan)
        case .corner(let anchor, let grab):
            picks.resizeEdit(from: anchor, to: transform.toMap(clamped(point)) + grab, on: plan)
        case .pin(let grab):
            picks.dragPin(to: transform.toMap(point) + grab, on: plan)
        case .plan(let start, true) where start.distance(to: point) >= Self.teachingDrag:
            session = .plan(start: start, canTeach: false)
            onFailedDrag()
        default:
            break
        }
    }

    func dragEnded() {
        defer { session = .none }
        guard let plan else { return }
        switch session {
        case .zone, .corner: withAnimation(PickMotion.spring) { picks.endEdit(on: plan) }
        case .pin: withAnimation(PickMotion.spring) { picks.endPinDrag() }
        default: break
        }
    }

    /// A second finger landed, or the system took the touch away.
    func cancel() {
        if case .none = session { return }
        session = .none
        withAnimation(PickMotion.spring) { picks.cancelGesture() }
    }

    // MARK: Placing without a gesture

    /// Everything a hold can do also has a route here, for the + menu and for VoiceOver.
    func dropPin() {
        guard let spot = placement() else { return }
        if withAnimation(PickMotion.spring, { picks.dropPin(at: spot) }) { announce(pinSpeech(at: spot) + ".") }
    }

    func addZone() {
        guard !picks.zonesAtLimit else {
            refuseZone()
            return
        }
        if let last = picks.zones.last {
            addZone(after: last)
        } else if let spot = placement() {
            place(zoneAt: spot)
        }
    }

    func dropPin(in room: FloorPlan.Room) {
        guard let plan, let spot = plan.nearestFloor(to: room.label, within: 4), picks.dropPin(at: spot) else { return }
        announce("Pin in \(room.name).")
    }

    func addZone(in room: FloorPlan.Room) {
        guard !picks.zonesAtLimit else {
            refuseZone()
            return
        }
        guard let plan, let spot = plan.nearestFloor(to: room.label, within: 4) else { return }
        place(zoneAt: spot)
    }

    /// Where the floating buttons put things. Anything that can't reach the floor is refused.
    private func placement() -> CGPoint? {
        guard let plan, let transform else { return nil }
        let centre = transform.toMap(CGPoint(x: visible.midX, y: visible.midY))
        guard let spot = Picks.placement(on: plan, after: picks.rooms.last, near: centre) else {
            picks.say(PickNote.spotOffFloor)
            return nil
        }
        return spot
    }

    private func place(zoneAt spot: CGPoint) {
        guard let plan else { return }
        let rect = Picks.square(around: spot, on: plan)
        guard plan.hasFloor(in: rect) else {
            picks.say(PickNote.zoneOffFloor)
            return
        }
        add(rect)
    }

    private func addZone(after last: CGRect) {
        guard let plan, let transform else { return }
        guard let rect = Picks.nextZone(after: last, offset: Self.nextZoneOffset / transform.scale, on: plan) else {
            picks.say(PickNote.zoneOffFloor)
            return
        }
        add(rect)
    }

    private func add(_ rect: CGRect) {
        if withAnimation(PickMotion.settle, { picks.addZone(rect) }) { announce(speech(for: rect)) }
    }

    private func refuseZone() {
        haptic(.warning)
        picks.say(PickNote.zoneLimit(picks.rules.maxZones))
    }

    // MARK: Speech

    func name(of zone: CGRect) -> String? { roomName(at: CGPoint(x: zone.midX, y: zone.midY)) }

    func roomName(at point: CGPoint) -> String? {
        guard let plan else { return nil }
        let id = plan.roomID(at: point) ?? plan.nearestFloor(to: point, within: 20).flatMap(plan.roomID(at:))
        return plan.rooms.first { $0.id == id }?.name
    }

    func speech(for zone: CGRect) -> String {
        let size = PickWording.size(zone, pixelSize: plan?.pixelSize ?? 5, spoken: true)
        return name(of: zone).map { "Zone in \($0), \(size)" } ?? "Zone, \(size)"
    }

    func pinSpeech(at point: CGPoint) -> String {
        roomName(at: point).map { "Pin in \($0)" } ?? "Pin"
    }
}

/// Measures a room's label the way `PlanCanvas` draws it.
enum PlanLabel {
    static let padding = CGSize(width: 12, height: 4)
    static let capsuleFont = Font.caption.weight(.semibold)

    private static var font: UIFont {
        let current = UIApplication.shared.preferredContentSizeCategory
        let capped = min(current, UIContentSizeCategory.extraExtraExtraLarge)
        let traits = UITraitCollection(preferredContentSizeCategory: capped)
        let size = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).pointSize
        return .systemFont(ofSize: size, weight: .semibold)
    }

    /// `mark` is the number or checkmark a picked room shows before its name.
    @MainActor static func size(of name: String, mark: String?) -> CGSize {
        let text = (mark.map { "\($0) " } ?? "") + name
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: measured.width + padding.width, height: measured.height + padding.height)
    }
}

/// The arithmetic of pinching, kept apart so it can be tested.
enum PlanZoom {
    static func clamp(_ zoom: CGFloat) -> CGFloat { min(6, max(1, zoom)) }

    /// `pan' = v - c - (v0 - c - pan0) * ratio`. The map point under the fingers at `start` stays under them at `now`.
    static func pan(start: CGPoint, now: CGPoint, centre: CGPoint, pan: CGSize, ratio: CGFloat) -> CGSize {
        CGSize(width: now.x - centre.x - (start.x - centre.x - pan.width) * ratio,
               height: now.y - centre.y - (start.y - centre.y - pan.height) * ratio)
    }
}

/// A transparent layer over Home's plan that reports what the fingers do. Touches are read in
/// UIKit because a SwiftUI gesture on a zone would block pinch there, and couldn't see a second
/// finger land elsewhere. iOS 17 has no `UIGestureRecognizerRepresentable`.
struct TouchSurface: UIViewRepresentable {
    let touches: PlanTouches
    let plan: FloorPlan
    let transform: PlanTransform
    let size: CGSize
    let insets: EdgeInsets
    let zoom: CGFloat
    let pan: CGSize
    let onCamera: (CGFloat, CGSize) -> Void
    let onCameraEnd: () -> Void

    var centre: CGPoint {
        CGPoint(x: insets.leading + (size.width - insets.leading - insets.trailing) / 2,
                y: insets.top + (size.height - insets.top - insets.bottom) / 2)
    }

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
        touches.update(plan: plan, transform: transform, size: size, insets: insets, isZoomed: zoom > 1.01)
    }

    /// The map can vanish under a finger, and then the lift never reaches anyone.
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.surface.touches.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let holdDuration: TimeInterval = 0.45
        private static let holdMovement: CGFloat = 10

        private struct Pinch {
            let zoom: CGFloat
            let pan: CGSize
            let location: CGPoint
        }

        var surface: TouchSurface
        private let tap = UITapGestureRecognizer()
        private let hold = UILongPressGestureRecognizer()
        private let drag = UIPanGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private let watch = FingerWatch()
        private var down = CGPoint.zero
        private var panStart = CGSize.zero
        private var movesPlan = false
        /// Where a finger rested before panning, if its hold claimed nothing.
        private var restingGrip: CGPoint?
        private var pinchStart: Pinch?
        private var pinchFingersChanged = false

        init(surface: TouchSurface) {
            self.surface = surface
        }

        func attach(to view: UIView) {
            tap.addTarget(self, action: #selector(tapped))
            hold.addTarget(self, action: #selector(held))
            drag.addTarget(self, action: #selector(dragged))
            pinch.addTarget(self, action: #selector(pinched))
            hold.minimumPressDuration = Self.holdDuration
            hold.allowableMovement = Self.holdMovement
            drag.maximumNumberOfTouches = 1
            // A hold fails at touch-up or at 10pt of movement, so these two wait on it
            // without adding any delay, and a hold and a pan can never fight.
            tap.require(toFail: hold)
            drag.require(toFail: hold)
            watch.onFirstFinger = { [weak self] in self?.down = $0 }
            watch.onSecondFinger = { [weak self] in self?.cancelOneFinger() }
            watch.onFingerLifted = { [weak self] in self?.pinchFingersChanged = true }
            for recognizer in [tap, hold, drag, pinch, watch] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        nonisolated func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                recognizer === pinch || other === pinch || recognizer === watch || other === watch
            }
        }

        /// Toggling `isEnabled` is UIKit's way to cancel a recognizer mid-gesture.
        private func cancelOneFinger() {
            for recognizer in [tap, hold, drag] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            pinchFingersChanged = true
            surface.touches.cancel()
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { surface.touches.tap(at: recognizer.location(in: recognizer.view)) }
        }

        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                surface.touches.holdBegan(at: point)
                beginRestingPan(at: point)
            case .changed:
                if let restingGrip {
                    panPlan(by: CGPoint(x: point.x - restingGrip.x, y: point.y - restingGrip.y))
                } else {
                    surface.touches.holdMoved(to: point)
                }
            case .ended:
                if !endRestingPan() { surface.touches.holdEnded() }
            case .cancelled, .failed:
                if !endRestingPan() { surface.touches.cancel() }
            default:
                break
            }
        }

        /// A hold that's begun has already beaten the pan, so one that claimed nothing has to
        /// move the plan itself, or resting before a pan would look like a frozen map.
        private func beginRestingPan(at point: CGPoint) {
            guard surface.touches.isZoomed, !surface.touches.ownsTheTouch else { return }
            restingGrip = point
            panStart = surface.pan
        }

        /// True if this hold was panning, so there's nothing else to finish.
        private func endRestingPan() -> Bool {
            guard restingGrip != nil else { return false }
            restingGrip = nil
            surface.onCameraEnd()
            return true
        }

        @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                let grabbed = surface.touches.dragBegan(from: down, at: point)
                movesPlan = !grabbed && surface.touches.isZoomed
                panStart = surface.pan
                recognizer.setTranslation(.zero, in: recognizer.view)
            case .changed:
                if movesPlan {
                    panPlan(by: recognizer.translation(in: recognizer.view))
                } else {
                    surface.touches.dragMoved(to: point)
                }
            case .ended:
                if movesPlan { surface.onCameraEnd() }
                surface.touches.dragEnded()
            case .cancelled, .failed:
                if movesPlan { surface.onCameraEnd() }
                surface.touches.cancel()
            default:
                break
            }
        }

        private func panPlan(by moved: CGPoint) {
            surface.onCamera(surface.zoom, CGSize(width: panStart.width + moved.x, height: panStart.height + moved.y))
        }

        private func startPinch(_ recognizer: UIPinchGestureRecognizer) {
            pinchStart = Pinch(zoom: surface.zoom, pan: surface.pan, location: recognizer.location(in: recognizer.view))
            pinchFingersChanged = false
        }

        @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                cancelOneFinger()
                startPinch(recognizer)
            case .changed:
                zoom(recognizer)
            case .ended, .cancelled, .failed:
                pinchStart = nil
                surface.onCameraEnd()
            default:
                break
            }
        }

        private func zoom(_ recognizer: UIPinchGestureRecognizer) {
            // With one finger lifted the location jumps to that finger, so wait.
            guard recognizer.numberOfTouches >= 2 else { return }
            // The location is the middle of the fingers, so a change of fingers would move the
            // plan. iOS 26 keeps a pinch alive through one, so start again from here. This comes
            // from `FingerWatch`, because a finger that stays still sends the pinch no updates.
            if pinchFingersChanged {
                recognizer.scale = 1
                startPinch(recognizer)
            }
            guard let start = pinchStart else { return }
            let zoom = PlanZoom.clamp(start.zoom * recognizer.scale)
            let pan = PlanZoom.pan(start: start.location, now: recognizer.location(in: recognizer.view),
                                   centre: surface.centre, pan: start.pan, ratio: zoom / start.zoom)
            surface.onCamera(zoom, pan)
        }
    }
}

/// Never recognizes anything. It's the one place that sees the first finger land, for hit-testing
/// where a drag began, and a second finger join, even while another gesture owns the first.
private final class FingerWatch: UIGestureRecognizer {
    var onFirstFinger: (CGPoint) -> Void = { _ in }
    var onSecondFinger: () -> Void = {}
    var onFingerLifted: () -> Void = {}
    private var fingers = 0

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = fingers
        fingers += touches.count
        if before == 0, let first = touches.first { onFirstFinger(first.location(in: view)) }
        // Every finger after the first: cancelling re-arms the one-finger recognizers, so a third
        // finger on a live pinch would otherwise count as a fresh one-finger tap, hold or drag.
        if fingers >= 2 { onSecondFinger() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        fingers -= touches.count
        onFingerLifted()
        if fingers <= 0 { state = .failed }
    }

    override func reset() {
        super.reset()
        fingers = 0
    }

    override func canPrevent(_ recognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by recognizer: UIGestureRecognizer) -> Bool { false }
}
