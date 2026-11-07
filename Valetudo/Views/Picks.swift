import SwiftUI

/// What the robot can do and what it's doing, so nothing is offered that it can't carry out.
struct PickRules: Equatable {
    var rooms = false
    var zones = false
    var goTo = false
    var roomOrder = false
    var maxZones = 1
    var maxRoomPasses = 1
    var maxZonePasses = 1
    var basic = false
    var locate = false
    var reachable = true
    var working = false
    /// A job is waiting to carry on: paused, or left at the dock to recharge.
    var paused = false
    /// Stop has something to end while the robot is resting, such as an error.
    var stoppable = false
    /// Driving by hand has no pause.
    var manual = false

    var canPin: Bool { zones || goTo }
}

extension PickRules {
    @MainActor init(_ store: RobotStore) {
        self.init()
        let plan = store.plan.flatMap { $0.isEmpty ? nil : $0 }
        rooms = store.has(Cap.rooms) && !(plan?.rooms.isEmpty ?? store.rooms.isEmpty)
        zones = store.has(Cap.zones)
        goTo = store.has(Cap.goTo)
        roomOrder = store.roomOrderSupported
        maxZones = max(1, store.maxZones)
        maxRoomPasses = max(1, store.maxRoomPasses)
        maxZonePasses = max(1, store.maxZonePasses)
        basic = store.has(Cap.basic)
        locate = store.has(Cap.locate)
        reachable = store.connected
        working = store.state.isActive
        paused = store.state.isUnfinished
        stoppable = store.state.canStop
        manual = store.state.status == "manual_control"
    }
}

/// Sizes the design gives in real distances, in centimetres.
enum PickSize {
    static let zoneSide: CGFloat = 150
    static let minimumSide: CGFloat = 20
    static let voiceStep: CGFloat = 25
}

/// Short animations shared by the bar and the plan, which all respect Reduce Motion.
enum PickMotion {
    private static var calm: Animation { .easeInOut(duration: 0.15) }
    static var settle: Animation { UIAccessibility.isReduceMotionEnabled ? calm : .snappy(duration: 0.22) }
    static var spring: Animation { UIAccessibility.isReduceMotionEnabled ? calm : .spring(response: 0.3, dampingFraction: 0.62) }
}

/// Everything the notes above the bar can say.
enum PickNote {
    static let working = "Pause first to choose something else."
    static let clearZones = "Clear zones to pick rooms."
    static let zoneOffFloor = "Draw the zone on the floor plan"
    static let spotOffFloor = "Pick a spot on the floor plan"
    static let startedAlone = "Cleaning started, so your picks were cleared."
    /// Working also covers moving and manual control, where "cleaning" wouldn't be true.
    static let movedAlone = "The robot started moving, so your picks were cleared."

    static func zoneLimit(_ count: Int) -> String {
        count == 1 ? "This robot cleans one zone at a time." : "This robot cleans up to \(count) zones at once."
    }

    static func gone(_ names: [String]) -> String {
        "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "is" : "are") no longer on the plan."
    }
}

/// The words on the bar. A bare number and a sign read as a zoom level, so counts are spelled out.
enum PickWording {
    static func times(_ count: Int) -> String {
        switch count {
        case ...1: return "Once"
        case 2: return "Twice"
        default: return "\(count) Times"
        }
    }

    private static func suffix(_ passes: Int) -> String { passes > 1 ? " \(times(passes))" : "" }
    private static func shortest(_ passes: Int) -> String { "Clean\(suffix(passes))" }

    // Each list runs widest first, for `ViewThatFits` to work down.
    static func roomTitles(names: [String], passes: Int) -> [String] {
        let end = suffix(passes)
        if names.count == 1 { return ["Clean \(names[0])\(end)", "Clean Room\(end)", shortest(passes)] }
        return ["Clean \(names.count) Rooms\(end)", "Clean Rooms\(end)", shortest(passes)]
    }

    static func zoneTitles(count: Int, passes: Int) -> [String] {
        let end = suffix(passes)
        if count == 1 { return ["Clean Zone\(end)", shortest(passes)] }
        return ["Clean \(count) Zones\(end)", "Clean Zones\(end)", shortest(passes)]
    }

    static func pinTitles(passes: Int) -> [String] { ["Clean Here\(suffix(passes))", shortest(passes)] }

    /// The whole job, for VoiceOver: "Clean Kitchen, then Hall, twice".
    static func spokenRooms(names: [String], ordered: Bool, passes: Int) -> String {
        let list = ordered ? names.joined(separator: ", then ") : names.formatted(.list(type: .and))
        return "Clean \(list)" + spokenCount(passes)
    }

    static func spokenCount(_ passes: Int) -> String { passes > 1 ? ", \(times(passes).lowercased())" : "" }

    /// "1.6 by 2.1 m", or feet where people measure in feet.
    static func size(_ rect: CGRect, pixelSize: CGFloat, locale: Locale = .current, spoken: Bool = false) -> String {
        let feet = locale.measurementSystem == .us
        let divisor: CGFloat = feet ? 30.48 : 100
        let unit = feet ? (spoken ? "feet" : "ft") : (spoken ? "metres" : "m")
        func side(_ length: CGFloat) -> String {
            Double(length * pixelSize / divisor).formatted(.number.precision(.fractionLength(1)).locale(locale))
        }
        return "\(side(rect.width)) by \(side(rect.height)) \(unit)"
    }

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// A room's place in the order, for VoiceOver.
    static func ordinal(_ position: Int) -> String {
        if ordinals.indices.contains(position - 1) { return ordinals[position - 1] }
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: position as NSNumber) ?? "\(position)"
    }
}

/// What's chosen on the plan. The robot's API runs one kind of job at a time, so one kind
/// exists at a time: rooms, zones or a pin. Rooms set aside by a pin or zone wait in
/// `heldRooms`, and come back when that pin or zone goes.
///
/// Anything a drag updates every frame lives in `draft` and `pinDrag`, not `zones` and `pin`,
/// so only the pick layer reads it and a drag never rebuilds the bar or the floor plan.
///
/// The lock on a job in flight lives here, not on each control, so no route can get round it:
/// while `sending`, nothing changes, and a refused job leaves exactly what was sent.
@MainActor @Observable
final class Picks {
    enum Kind: Equatable { case nothing, rooms, zones, pin }
    enum Verb: Equatable { case clean, go }

    /// What the primary sends.
    enum Job: Equatable {
        case start
        case rooms([String], passes: Int)
        case zones([CGRect], passes: Int)
        case go(CGPoint)
    }

    struct Note: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    private struct Saved {
        var rooms: [String]
        let zones: [CGRect]
        let activeZone: Int?
        let pin: CGPoint?
        let verb: Verb
        var heldRooms: [String]
    }

    private static let backgroundLimit: TimeInterval = 300

    var rules = PickRules()

    private(set) var rooms: [String] = []
    private(set) var zones: [CGRect] = []
    private(set) var activeZone: Int?
    private(set) var pin: CGPoint?
    private(set) var verb = Verb.clean
    private(set) var heldRooms: [String] = []
    private(set) var sending = false
    private(set) var note: Note?
    /// Set by the touch surface and the layout. These only move the note clear of what's
    /// floating above the bar, and they live here so that doesn't rebuild the plan.
    var planIsZoomed = false
    var floatHeight: CGFloat = 0

    /// The rectangle under the finger. With `editing` set, it stands in for that zone until lift.
    private(set) var draft: CGRect?
    private(set) var editing: Int?
    /// A hold is making a new zone, so the bar treats it as one already.
    private(set) var adding = false
    /// Where a dragged pin is right now. `pin` keeps its last spot on the floor.
    private(set) var pinDrag: CGPoint?
    private(set) var pinOffFloor = false

    private var wantedPasses = 1

    @ObservationIgnored private var saved: Saved?
    @ObservationIgnored private var holdStart: CGPoint?
    @ObservationIgnored private var lastFloor: CGPoint?
    @ObservationIgnored private var backgrounded: Date?

    var kind: Kind {
        if pin != nil { return .pin }
        if !zones.isEmpty || adding { return .zones }
        return rooms.isEmpty ? .nothing : .rooms
    }

    var maxPasses: Int {
        switch kind {
        case .nothing: return 1
        case .rooms: return rules.maxRoomPasses
        case .zones: return rules.maxZonePasses
        case .pin: return verb == .clean && rules.zones ? rules.maxZonePasses : 1
        }
    }

    /// Clamped to whatever the current kind of pick allows. The wish itself is kept,
    /// so held rooms get their count back if a zone with a lower limit is cleared.
    var passes: Int {
        get { min(wantedPasses, maxPasses) }
        set { if !sending { wantedPasses = newValue } }
    }

    /// A zone still being stretched counts, or lifting it could pass the robot's limit.
    var zonesAtLimit: Bool { zones.count + (adding ? 1 : 0) >= rules.maxZones }

    /// A finger is still changing the picks, so what's drawn isn't what's stored yet.
    private var isMidGesture: Bool { saved != nil || editing != nil || pinDrag != nil }

    var clearSymbol: String { heldRooms.isEmpty ? "xmark" : "arrow.uturn.backward" }

    var clearLabel: String {
        guard !heldRooms.isEmpty else { return "Clear" }
        return kind == .pin ? "Clear Pin and Return to Rooms" : "Clear Zones and Return to Rooms"
    }

    // MARK: Rooms

    /// Tap order is cleaning order, so taking one out renumbers the rest.
    func toggle(_ id: String) {
        guard !sending, pin == nil, zones.isEmpty else { return }
        if let index = rooms.firstIndex(of: id) { rooms.remove(at: index) } else { rooms.append(id) }
        settle()
    }

    func selectAll(_ ids: [String]) {
        guard !sending, !rules.working, pin == nil, zones.isEmpty else { return }
        rooms += ids.filter { !rooms.contains($0) }
    }

    func moveRooms(from offsets: IndexSet, to destination: Int) {
        guard !sending else { return }
        rooms.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Rooms are kept by id through a map refresh. Returns the ones that vanished.
    func keepRooms(in ids: Set<String>) -> [String] {
        // A hold's snapshot too, or cancelling it would bring a vanished room back.
        saved?.rooms.removeAll { !ids.contains($0) }
        saved?.heldRooms.removeAll { !ids.contains($0) }
        let gone = (rooms + heldRooms).filter { !ids.contains($0) }
        guard !gone.isEmpty else { return [] }
        rooms.removeAll { !ids.contains($0) }
        heldRooms.removeAll { !ids.contains($0) }
        settle()
        return gone
    }

    // MARK: Pin

    /// False means nothing changed.
    @discardableResult
    func dropPin(at spot: CGPoint) -> Bool {
        guard !sending, zones.isEmpty else { return false }
        setRoomsAside()
        place(pin: spot)
        return true
    }

    func setVerb(_ verb: Verb) {
        if !sending { self.verb = verb }
    }

    /// For VoiceOver. `dx` and `dy` are in centimetres. False means there's no floor there.
    @discardableResult
    func nudgePin(dx: CGFloat, dy: CGFloat, on plan: FloorPlan) -> Bool {
        guard !sending, let pin else { return false }
        let moved = CGPoint(x: pin.x + dx / plan.pixelSize, y: pin.y + dy / plan.pixelSize)
        guard plan.nearestFloor(to: moved, within: 0) != nil else {
            say(PickNote.spotOffFloor)
            return false
        }
        self.pin = moved
        return true
    }

    /// A finger resting on the pin is already a gesture, or the primary could send this spot
    /// and the pin then move while the job is out.
    func grabPin() {
        guard let pin else { return }
        pinDrag = pin
        lastFloor = pin
    }

    func dragPin(to point: CGPoint, on plan: FloorPlan) {
        guard let pin else { return }
        if pinDrag == nil { lastFloor = pin }
        let spot = Self.clamp(point, to: plan.bounds)
        let onFloor = plan.nearestFloor(to: spot, within: 0) != nil
        if onFloor { lastFloor = spot }
        pinDrag = spot
        if pinOffFloor == onFloor { pinOffFloor = !onFloor }
    }

    func endPinDrag() {
        if pinDrag != nil, let lastFloor { pin = lastFloor }
        pinDrag = nil
        pinOffFloor = false
        lastFloor = nil
    }

    func pinIsBlocked(on plan: FloorPlan?) -> Bool {
        guard let plan, let pin else { return false }
        return plan.noGo.contains(pin) || plan.nearestFloor(to: pin, within: 0) == nil
    }

    private func place(pin spot: CGPoint) {
        if pin == nil { verb = rules.zones ? .clean : .go }
        pin = spot
    }

    // MARK: Zones

    /// Adds a zone as the active one. False means nothing changed, usually because of the robot's limit.
    @discardableResult
    func addZone(_ rect: CGRect) -> Bool {
        guard !sending, !zonesAtLimit else { return false }
        setRoomsAside()
        pin = nil
        zones.append(rect)
        activeZone = zones.count - 1
        return true
    }

    func activate(zone index: Int) {
        guard !sending, zones.indices.contains(index) else { return }
        activeZone = index
    }

    func deactivateZone() { activeZone = nil }

    /// The last zone to go brings back any held rooms.
    func deleteZone(at index: Int) {
        guard !sending, !adding else { return }
        removeZone(at: index)
    }

    private func removeZone(at index: Int) {
        guard zones.indices.contains(index) else { return }
        zones.remove(at: index)
        activeZone = activeZone.flatMap { Self.position($0, afterRemoving: index) }
        if let edit = editing {
            // A drag on this zone ends here, and one on a later zone follows it down the list.
            editing = Self.position(edit, afterRemoving: index)
            if editing == nil { draft = nil }
        }
        if zones.isEmpty { rooms = takeHeldRooms() }
        settle()
    }

    private static func position(_ position: Int, afterRemoving index: Int) -> Int? {
        position == index ? nil : (position > index ? position - 1 : position)
    }

    func beginEdit(zone index: Int) {
        guard zones.indices.contains(index) else { return }
        editing = index
        draft = zones[index]
    }

    func moveEdit(to origin: CGPoint, on plan: FloorPlan) {
        guard editing != nil, let rect = draft else { return }
        draft = Self.fit(CGRect(origin: origin, size: rect.size), in: plan.bounds)
    }

    func resizeEdit(from anchor: CGPoint, to corner: CGPoint, on plan: FloorPlan) {
        guard editing != nil else { return }
        draft = Self.rect(from: anchor, to: corner, on: plan)
    }

    /// A zone left with no floor goes back to where it started.
    func endEdit(on plan: FloorPlan) {
        guard let index = editing, let rect = draft else { return }
        editing = nil
        draft = nil
        guard zones.indices.contains(index) else { return }
        if plan.hasFloor(in: rect) { zones[index] = rect } else { say(PickNote.zoneOffFloor) }
    }

    /// For VoiceOver. `dx` and `dy` are in centimetres. False means there's no floor there.
    @discardableResult
    func nudgeZone(_ index: Int, dx: CGFloat, dy: CGFloat, on plan: FloorPlan) -> Bool {
        guard !sending, zones.indices.contains(index) else { return false }
        let moved = zones[index].offsetBy(dx: dx / plan.pixelSize, dy: dy / plan.pixelSize)
        return commit(Self.fit(moved, in: plan.bounds), at: index, on: plan)
    }

    /// For VoiceOver. Grows both sides by `step` centimetres, or shrinks them if it's negative.
    @discardableResult
    func growZone(_ index: Int, by step: CGFloat, on plan: FloorPlan) -> Bool {
        guard !sending, zones.indices.contains(index) else { return false }
        let rect = zones[index]
        let smallest = PickSize.minimumSide / plan.pixelSize
        let width = max(rect.width + step / plan.pixelSize, smallest)
        let height = max(rect.height + step / plan.pixelSize, smallest)
        let grown = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return commit(Self.fit(grown, in: plan.bounds), at: index, on: plan)
    }

    private func commit(_ rect: CGRect, at index: Int, on plan: FloorPlan) -> Bool {
        guard plan.hasFloor(in: rect) else {
            say(PickNote.zoneOffFloor)
            return false
        }
        zones[index] = rect
        return true
    }

    // MARK: Touch and hold

    /// Starts a hold on a spot already known to be floor. False means the zone limit stopped it.
    func beginHold(at spot: CGPoint, on plan: FloorPlan) -> Bool {
        if kind == .zones, zonesAtLimit { return false }
        saved = snapshot()
        holdStart = spot
        if kind == .zones {
            adding = true
            draft = Self.square(around: spot, on: plan)
        } else {
            setRoomsAside()
            place(pin: spot)
        }
        return true
    }

    /// The finger has moved far enough to mean a zone, with the start point as one corner.
    func stretch(to corner: CGPoint, on plan: FloorPlan) {
        guard let holdStart else { return }
        if pin != nil { pin = nil }
        if !adding { adding = true }
        draft = Self.rect(from: holdStart, to: corner, on: plan)
    }

    /// The finger came back, so it's a pin again, or a default zone if zones already exist.
    func unstretch(on plan: FloorPlan) {
        guard let holdStart, let saved, adding else { return }
        if saved.zones.isEmpty {
            adding = false
            draft = nil
            pin = holdStart
        } else {
            draft = Self.square(around: holdStart, on: plan)
        }
    }

    func endHold(on plan: FloorPlan) {
        defer {
            saved = nil
            holdStart = nil
        }
        if pinDrag != nil { endPinDrag() }
        guard adding else { return }
        adding = false
        let rect = draft
        draft = nil
        if let rect, plan.hasFloor(in: rect) {
            zones.append(rect)
            activeZone = zones.count - 1
        } else {
            restore()
            say(PickNote.zoneOffFloor)
        }
    }

    /// A second finger or an interruption: everything goes back to before the gesture.
    func cancelGesture() {
        restore()
        saved = nil
        holdStart = nil
        adding = false
        editing = nil
        draft = nil
        pinDrag = nil
        pinOffFloor = false
        lastFloor = nil
    }

    // MARK: Clearing

    /// Rooms just clear. A pin or zones clear and give back any rooms they were holding.
    func clear() {
        if !sending { discard() }
    }

    private func discard() {
        let back = kind == .rooms ? [] : heldRooms
        endGesture()
        rooms = back
        zones = []
        activeZone = nil
        pin = nil
        heldRooms = []
        settle()
    }

    /// Starts over, discarding held rooms too. The job they were waiting for has gone.
    func reset() {
        endGesture()
        rooms = []
        zones = []
        activeZone = nil
        pin = nil
        heldRooms = []
        wantedPasses = 1
    }

    func robotStartedAlone(cleaning: Bool = true) {
        guard kind != .nothing else { return }
        reset()
        say(cleaning ? PickNote.startedAlone : PickNote.movedAlone)
    }

    func enteredBackground(at date: Date = .now) { backgrounded = date }

    func becameActive(at date: Date = .now) {
        defer { backgrounded = nil }
        if let backgrounded, date.timeIntervalSince(backgrounded) >= Self.backgroundLimit { reset() }
    }

    // MARK: Map refresh

    /// A new map can take the floor away from a pin or zone. A pin moves to floor within `reach`
    /// map pixels if there is any. Anything else left with no floor goes, with a note, and held
    /// rooms come back if that was the last of it. With no plan at all, neither can stay.
    func keepOnFloor(of plan: FloorPlan?, reach: Int) {
        guard kind == .pin || kind == .zones else { return }
        guard let plan, !plan.isEmpty else {
            say(pin == nil ? PickNote.zoneOffFloor : PickNote.spotOffFloor)
            discard()
            return
        }
        // A gesture has its own check at lift, and the next refresh catches anything it leaves.
        guard !isMidGesture else { return }
        keepPin(on: plan, reach: reach)
        keepZones(on: plan)
    }

    private func keepPin(on plan: FloorPlan, reach: Int) {
        guard let spot = pin, plan.nearestFloor(to: spot, within: 0) == nil else { return }
        if let floor = plan.nearestFloor(to: spot, within: reach) {
            pin = floor
        } else {
            discard()
            say(PickNote.spotOffFloor)
        }
    }

    private func keepZones(on plan: FloorPlan) {
        let lost = zones.indices.filter { !plan.hasFloor(in: zones[$0]) }
        guard !lost.isEmpty else { return }
        lost.reversed().forEach(removeZone)
        say(PickNote.zoneOffFloor)
    }

    // MARK: Sending

    /// What the primary will send, checked once more against the current plan so nothing
    /// off the floor can reach the robot, however it got here. Nil if it can't send yet: a
    /// second finger can reach the primary mid-gesture, and what's drawn must be what's sent.
    func job(on plan: FloorPlan?) -> Job? {
        guard !isMidGesture else { return nil }
        switch kind {
        case .nothing: return .start
        case .rooms: return .rooms(rooms, passes: passes)
        case .zones: return zoneJob(on: plan)
        case .pin: return pinJob(on: plan)
        }
    }

    private func zoneJob(on plan: FloorPlan?) -> Job? {
        guard let plan, !zones.isEmpty, zones.allSatisfy(plan.hasFloor(in:)) else {
            say(PickNote.zoneOffFloor)
            return nil
        }
        return .zones(zones, passes: passes)
    }

    private func pinJob(on plan: FloorPlan?) -> Job? {
        guard let plan, let pin, plan.nearestFloor(to: pin, within: 0) != nil, !plan.noGo.contains(pin) else {
            say(PickNote.spotOffFloor)
            return nil
        }
        return verb == .go ? .go(pin) : .zones([Self.square(around: pin, on: plan)], passes: passes)
    }

    func beginSending() { sending = true }

    /// Picks clear only once the robot has accepted the job.
    func finishSending(accepted: Bool) {
        sending = false
        if accepted { reset() }
    }

    /// Sends a job, and stays locked until the robot has answered and, if it said yes, had
    /// `limit` to report that it started. Without that wait a robot slow to report would show
    /// the idle bar again, and a second tap on Clean All would start a whole-home clean.
    func deliver(_ job: Job, to store: RobotStore, within limit: Duration = .seconds(3)) async -> Bool {
        let accepted = await store.send(job)
        if accepted { await store.waitForWork(limit: limit) }
        finishSending(accepted: accepted)
        return accepted
    }

    // MARK: Notes

    func say(_ text: String) { note = Note(text: text) }

    func dismiss(_ shown: Note) {
        if note?.id == shown.id { note = nil }
    }

    // MARK: Geometry

    /// A default square, moved inward if it would cross the plan's edge.
    static func square(around centre: CGPoint, on plan: FloorPlan) -> CGRect {
        let side = PickSize.zoneSide / plan.pixelSize
        let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        return fit(rect, in: plan.bounds)
    }

    /// The rectangle between two corners, no smaller than the minimum and never past the
    /// plan's edge. Thin rectangles grow toward the finger rather than being dropped.
    static func rect(from start: CGPoint, to end: CGPoint, on plan: FloorPlan) -> CGRect {
        let smallest = PickSize.minimumSide / plan.pixelSize
        let a = clamp(start, to: plan.bounds), b = clamp(end, to: plan.bounds)
        let width = max(abs(b.x - a.x), smallest), height = max(abs(b.y - a.y), smallest)
        let rect = CGRect(x: b.x < a.x ? a.x - width : a.x, y: b.y < a.y ? a.y - height : a.y,
                          width: width, height: height)
        return fit(rect, in: plan.bounds)
    }

    static func fit(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width), height = min(rect.height, bounds.height)
        return CGRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(rect.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// A default zone beside the last one, so both can be seen. It tries each diagonal,
    /// because the first may run into the plan's edge or off the floor.
    static func nextZone(after last: CGRect, offset: CGFloat, on plan: FloorPlan) -> CGRect? {
        let side = PickSize.zoneSide / plan.pixelSize
        for (dx, dy) in [(offset, offset), (-offset, offset), (offset, -offset), (-offset, -offset)] {
            let spot = CGRect(x: last.minX + dx, y: last.minY + dy, width: side, height: side)
            let rect = fit(spot, in: plan.bounds)
            if rect != last, plan.hasFloor(in: rect) { return rect }
        }
        return nil
    }

    /// Where the + puts something: on the last picked room's label, or else the room label
    /// nearest the middle of the view, because a home's geometric centre is often a void.
    static func placement(on plan: FloorPlan, after room: String?, near centre: CGPoint) -> CGPoint? {
        let label = plan.rooms.first { $0.id == room }?.label
            ?? plan.rooms.min { distance($0.label, centre) < distance($1.label, centre) }?.label
        return anyFloor(near: label ?? centre, on: plan)
    }

    /// The nearest floor at any distance. The search widens in steps because it costs the
    /// square of the radius, and starts inside the plan in case the view is panned far away.
    private static func anyFloor(near point: CGPoint, on plan: FloorPlan) -> CGPoint? {
        let start = clamp(point, to: plan.bounds)
        let limit = Int(hypot(plan.bounds.width, plan.bounds.height).rounded(.up))
        var radius = 8
        while radius < limit {
            if let spot = plan.nearestFloor(to: start, within: radius) { return spot }
            radius *= 4
        }
        return plan.nearestFloor(to: start, within: limit)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Private

    private func setRoomsAside() {
        guard !rooms.isEmpty else { return }
        heldRooms = rooms
        rooms = []
    }

    private func takeHeldRooms() -> [String] {
        defer { heldRooms = [] }
        return heldRooms
    }

    private func snapshot() -> Saved {
        Saved(rooms: rooms, zones: zones, activeZone: activeZone, pin: pin, verb: verb, heldRooms: heldRooms)
    }

    private func restore() {
        guard let saved else { return }
        rooms = saved.rooms
        zones = saved.zones
        activeZone = saved.activeZone
        pin = saved.pin
        verb = saved.verb
        heldRooms = saved.heldRooms
    }

    private func endGesture() {
        saved = nil
        cancelGesture()
    }

    private func settle() {
        if kind == .nothing { wantedPasses = 1 }
    }
}

extension RobotStore {
    /// What starting this job sends. Cleaning everything has no request worth showing.
    func request(for job: Picks.Job) -> JobRequest? {
        switch job {
        case .start: return nil
        case .rooms(let ids, let passes): return .rooms(ids, passes: passes, customOrder: roomOrderSupported)
        case .zones(let zones, let passes): return plan.map { .zones(zones, passes: passes, pixelSize: $0.pixelSize) }
        case .go(let point): return plan.map { .go(to: point, pixelSize: $0.pixelSize) }
        }
    }

    func send(_ job: Picks.Job) async -> Bool {
        switch job {
        case .start: return await start()
        case .rooms(let ids, let passes): return await clean(rooms: ids, passes: passes)
        case .zones(let zones, let passes): return await clean(zones: zones, passes: passes)
        case .go(let point): return await go(to: point)
        }
    }
}
