import SwiftUI

/// Puts one view beside a target: above it, or below it when there's no room above, and
/// always inside the plan. No state, so a capsule can follow a finger without an extra pass.
struct PlanFloat: Layout {
    static let gap: CGFloat = 8

    let target: CGRect
    let insets: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let spot = Self.origin(for: size, beside: target, in: bounds.size, insets: insets)
        view.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), anchor: .topLeading,
                   proposal: ProposedViewSize(size))
    }

    static func origin(for size: CGSize, beside target: CGRect, in area: CGSize, insets: EdgeInsets) -> CGPoint {
        let above = target.minY - gap - size.height
        let y = above >= insets.top ? above : target.maxY + gap
        let lowest = max(insets.top, area.height - insets.bottom - size.height)
        let widest = max(gap, area.width - gap - size.width)
        return CGPoint(x: min(max(target.midX - size.width / 2, gap), widest), y: min(max(y, insets.top), lowest))
    }
}

/// Zones, the pin and what goes with them, drawn over the plan. This is the only view that
/// reads what a drag changes every frame, which keeps the map's expensive filters out of it.
/// Nothing here takes touches except the capsule buttons: `PlanTouches` hit-tests instead.
struct PickLayer: View {
    private struct ShownZone: Identifiable {
        let id: Int
        let map: CGRect
        let isActive: Bool
    }

    let touches: PlanTouches
    let plan: FloorPlan
    let t: PlanTransform
    let insets: EdgeInsets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var picks: Picks { touches.picks }

    private var shownZones: [ShownZone] {
        var list = picks.zones.enumerated().map { index, zone in
            let live = index == picks.editing ? picks.draft ?? zone : zone
            return ShownZone(id: index, map: live, isActive: index == picks.activeZone && !picks.adding)
        }
        if picks.adding, let draft = picks.draft {
            list.append(ShownZone(id: picks.zones.count, map: draft, isActive: true))
        }
        return list
    }

    private var pinTransition: AnyTransition {
        reduceMotion ? .opacity : .offset(y: -16).combined(with: .opacity)
    }

    var body: some View {
        let zones = shownZones
        ZStack(alignment: .topLeading) {
            ForEach(zones) { zone in
                zoneShape(t.toView(zone.map)).transition(.opacity)
            }
            if let active = zones.first(where: \.isActive) { zoneControls(active) }
            pinViews
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The same cap as the plan's labels. Much larger and the pin's two buttons are wider
        // than the plan, and one of them is the only way to choose Go Here.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18), value: zones.count)
        .animation(PickMotion.spring, value: picks.pin == nil)
    }

    // MARK: Zones

    private func zoneShape(_ rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Theme.cobalt.opacity(0.18))
            .overlay(shape.stroke(Theme.cobalt, lineWidth: contrast == .increased ? 3 : 2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func zoneControls(_ zone: ShownZone) -> some View {
        let rect = t.toView(zone.map)
        if !picks.adding {
            ForEach(ZoneCorner.shown(on: rect), id: \.self) { corner in
                handle(at: corner.point(in: rect))
            }
        }
        PlanFloat(target: rect, insets: insets) {
            sizeCapsule(zone)
        }
    }

    private func handle(at point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Theme.cobalt, lineWidth: 2.5))
            .frame(width: 12, height: 12)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func sizeCapsule(_ zone: ShownZone) -> some View {
        HStack(spacing: 2) {
            Text(PickWording.size(zone.map, pixelSize: plan.pixelSize))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 14)
                .padding(.trailing, picks.adding ? 14 : 0)
                .allowsHitTesting(false)
            if !picks.adding {
                Button {
                    withAnimation(PickMotion.settle) { picks.deleteZone(at: zone.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.slate)
                        .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .disabled(picks.sending)
                .accessibilityLabel("Delete Zone")
            }
        }
        .frame(minHeight: Metric.hitTarget)
        .background { floatBackground }
    }

    /// Only the buttons on a capsule take touches, so a drag can still start beside them.
    private var floatBackground: some View {
        Color.clear.glass(in: Capsule()).allowsHitTesting(false)
    }

    // MARK: Pin

    @ViewBuilder private var pinViews: some View {
        if let spot = picks.pinDrag ?? picks.pin {
            let tip = t.toView(spot)
            if picks.verb == .clean, picks.rules.zones, !picks.pinOffFloor { cleanSquare(around: spot) }
            PlanPin(faded: picks.pinOffFloor)
                .position(x: tip.x, y: tip.y - PlanPin.tipDrop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(pinTransition)
            pinCapsule(spot: spot, tip: tip)
        }
    }

    private func cleanSquare(around spot: CGPoint) -> some View {
        let rect = t.toView(Picks.square(around: spot, on: plan))
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Theme.cobalt.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func pinCapsule(spot: CGPoint, tip: CGPoint) -> some View {
        let top = PlanPin.headRise + PlanPin.headSize / 2
        let target = CGRect(x: tip.x - PlanPin.headSize / 2, y: tip.y - top, width: PlanPin.headSize, height: top + 3)
        if plan.noGo.contains(spot) {
            PlanFloat(target: target, insets: insets) { noGoCapsule }
        } else if picks.rules.zones, picks.rules.goTo {
            PlanFloat(target: target, insets: insets) { verbCapsule }
        }
    }

    private var noGoCapsule: some View {
        Text("No-go zone")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.rose)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(minHeight: Metric.hitTarget)
            .background { floatBackground }
            .allowsHitTesting(false)
    }

    /// These only choose what the primary says. They never move the robot. The whole capsule
    /// takes touches, because a near miss on its rim would otherwise be a tap on the plan, and
    /// that removes the pin these buttons are setting up.
    private var verbCapsule: some View {
        HStack(spacing: 0) {
            verbButton("Clean Here", .clean)
            verbButton("Go Here", .go)
        }
        .padding(3)
        .background { floatBackground }
        .contentShape(Capsule())
    }

    private func verbButton(_ title: String, _ verb: Picks.Verb) -> some View {
        let isOn = picks.verb == verb
        return Button {
            withAnimation(PickMotion.settle) { picks.setVerb(verb) }
        } label: {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: Metric.hitTarget - 6)
                .background(isOn ? Theme.cobalt.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(picks.sending)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
