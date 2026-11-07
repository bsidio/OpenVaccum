import SwiftUI

/// What VoiceOver finds on Home's plan: rooms, zones, the pin, obstacles, the robot's destination, the dock and the robot,
/// in that order. A Canvas has nothing to touch, so these invisible views stand in for what it draws.
/// They're a real layer rather than `accessibilityChildren`, whose views are never laid out and
/// so have no frames, which leaves explore-by-touch with nothing to find.
/// A view of its own, so a pick changing doesn't rebuild the map beneath it.
struct PlanChildren: View {
    private static let roomSize = CGSize(width: 88, height: 44)
    private static let pointSize = CGSize(width: 44, height: 44)

    let touches: PlanTouches
    let plan: FloorPlan
    let t: PlanTransform

    private var picks: Picks { touches.picks }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(plan.rooms.enumerated()), id: \.element.id) { index, room in
                roomElement(room)
                    .accessibilitySortPriority(600 - Double(index))
                    .position(t.toView(room.label))
            }
            ForEach(Array(picks.zones.enumerated()), id: \.offset) { index, zone in
                let rect = t.toView(zone)
                zoneElement(zone, index: index, size: rect.size)
                    .accessibilitySortPriority(500 - Double(index))
                    .position(x: rect.midX, y: rect.midY)
            }
            if let pin = picks.pin {
                pinElement(pin).accessibilitySortPriority(400).position(t.toView(pin))
            }
            ForEach(Array(plan.obstacles.enumerated()), id: \.element.id) { index, obstacle in
                obstacleElement(obstacle)
                    .accessibilitySortPriority(300 - Double(index))
                    .position(t.toView(obstacle.point))
            }
            if let target = plan.goToTarget {
                marker("Robot's destination").accessibilitySortPriority(250).position(t.toView(target))
            }
            if let dock = plan.dock {
                marker("Dock").accessibilitySortPriority(200).position(t.toView(dock))
            }
            if let robot = plan.robot {
                marker("Robot").accessibilitySortPriority(100).position(t.toView(robot))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// Everything here must be finished before `position`, which fills its parent
    /// and would give the element the whole plan as its frame.
    private func area(_ size: CGSize) -> some View {
        Rectangle().fill(.clear).frame(width: size.width, height: size.height)
    }

    private func roomValue(_ id: String) -> String {
        guard let index = picks.rooms.firstIndex(of: id) else { return "Not picked" }
        return picks.rules.roomOrder ? "Picked, \(PickWording.ordinal(index + 1))" : "Picked"
    }

    /// A robot that can't clean by room has nothing to offer here but the name.
    @ViewBuilder private func roomElement(_ room: FloorPlan.Room) -> some View {
        let element = area(Self.roomSize)
            .accessibilityElement()
            .accessibilityLabel(room.name)
            .accessibilityActions { roomActions(room) }
        if picks.rules.rooms {
            element
                .accessibilityValue(roomValue(room.id))
                .accessibilityAddTraits(picks.rooms.contains(room.id) ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { touches.pick(room: room.id) }
        } else {
            element
        }
    }

    // SwiftUI hands actions to VoiceOver last first, so these are written in reverse.

    /// These only place things. Only the primary can start the robot.
    @ViewBuilder private func roomActions(_ room: FloorPlan.Room) -> some View {
        if !picks.rules.working, !picks.sending {
            if picks.rules.zones {
                Button("Add Zone Here") { touches.addZone(in: room) }
            }
            if picks.rules.canPin, picks.zones.isEmpty {
                Button("Drop Pin Here") { touches.dropPin(in: room) }
            }
        }
    }

    private func zoneElement(_ zone: CGRect, index: Int, size: CGSize) -> some View {
        area(size)
            .accessibilityElement()
            .accessibilityLabel(touches.speech(for: zone))
            .accessibilityAddTraits(index == picks.activeZone ? .isSelected : [])
            .accessibilityAction { picks.activate(zone: index) }
            .accessibilityActions { zoneActions(index) }
    }

    @ViewBuilder private func zoneActions(_ index: Int) -> some View {
        let step = PickSize.voiceStep
        if !picks.sending {
            Button("Delete") { picks.deleteZone(at: index) }
            Button("Smaller") { resize(index, by: -step) }
            Button("Larger") { resize(index, by: step) }
            Button("Move Right") { nudge(index, dx: step) }
            Button("Move Left") { nudge(index, dx: -step) }
            Button("Move Down") { nudge(index, dy: step) }
            Button("Move Up") { nudge(index, dy: -step) }
        }
    }

    private func nudge(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 0) {
        if picks.nudgeZone(index, dx: dx, dy: dy, on: plan) { speakSize(index) }
    }

    private func resize(_ index: Int, by step: CGFloat) {
        if picks.growZone(index, by: step, on: plan) { speakSize(index) }
    }

    private func speakSize(_ index: Int) {
        touches.announce(PickWording.size(picks.zones[index], pixelSize: plan.pixelSize, spoken: true))
    }

    private func pinElement(_ pin: CGPoint) -> some View {
        area(Self.pointSize)
            .accessibilityElement()
            .accessibilityLabel(touches.pinSpeech(at: pin))
            .accessibilityActions { pinActions }
    }

    /// A map with no rooms has no room actions to move a pin with, and nothing here may need a gesture.
    @ViewBuilder private var pinActions: some View {
        let step = PickSize.voiceStep
        if !picks.sending {
            Button("Move Right") { movePin(dx: step) }
            Button("Move Left") { movePin(dx: -step) }
            Button("Move Down") { movePin(dy: step) }
            Button("Move Up") { movePin(dy: -step) }
        }
    }

    private func movePin(dx: CGFloat = 0, dy: CGFloat = 0) {
        if picks.nudgePin(dx: dx, dy: dy, on: plan), let pin = picks.pin {
            touches.announce(touches.pinSpeech(at: pin) + ".")
        }
    }

    private func obstacleElement(_ obstacle: FloorPlan.Obstacle) -> some View {
        area(Self.pointSize)
            .accessibilityElement()
            .accessibilityLabel("\(obstacle.title), opens photo")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { touches.onObstacle(obstacle) }
    }

    private func marker(_ label: String) -> some View {
        area(Self.pointSize)
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}
