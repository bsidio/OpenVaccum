import SwiftUI
import TipKit

/// The round buttons floating above the bar. A new one goes in `body`, and its height and
/// gap go in `reserved` so the Fit button stays clear of it.
struct PlanColumn: View {
    static let reserved = (Metric.hitTarget + spacing) * 2
    private static let spacing: CGFloat = 8

    let touches: PlanTouches
    let hasPlan: Bool
    @Binding var in3D: Bool
    let onRooms: () -> Void

    var body: some View {
        VStack(spacing: Self.spacing) {
            ViewToggle(picks: touches.picks, hasPlan: hasPlan, in3D: $in3D)
            PlusButton(touches: touches, hasPlan: hasPlan, in3D: $in3D, onRooms: onRooms)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 14)
    }
}

/// What the + can do for this robot right now.
enum PlusOption: CaseIterable {
    case rooms, zone, pin

    var title: String {
        switch self {
        case .rooms: return "Rooms"
        case .zone: return "Add Zone"
        case .pin: return "Drop Pin"
        }
    }

    var symbol: String {
        switch self {
        case .rooms: return "list.bullet"
        case .zone: return "rectangle.dashed"
        case .pin: return "mappin"
        }
    }

    static func available(_ rules: PickRules, hasPlan: Bool) -> [PlusOption] {
        allCases.filter { option in
            switch option {
            case .rooms: return rules.rooms
            case .zone: return hasPlan && rules.zones
            case .pin: return hasPlan && rules.canPin
            }
        }
    }
}

extension Picks {
    /// Hidden while working, because the plan can't pick then, and while a pin exists,
    /// because there's nothing to add to one.
    func showsPlus(hasPlan: Bool) -> Bool {
        !rules.working && pin == nil && !PlusOption.available(rules, hasPlan: hasPlan).isEmpty
    }
}

/// Switches between the flat plan and the 3D model. Pins and zones only exist on the flat
/// plan, so while there's one to see, the plan stays flat.
private struct ViewToggle: View {
    let picks: Picks
    let hasPlan: Bool
    @Binding var in3D: Bool

    private var isNeededFlat: Bool { picks.kind == .pin || picks.kind == .zones }

    var body: some View {
        Group {
            if hasPlan, !isNeededFlat {
                Button { in3D.toggle() } label: {
                    Text(in3D ? "2D" : "3D")
                        .font(.subheadline.weight(.bold))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .foregroundStyle(Theme.ink)
                        .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .glass(in: Circle(), interactive: true)
                .accessibilityLabel(in3D ? "Show the Flat Floor Plan" : "Show the Floor Plan in 3D")
                .accessibilityInputLabels([in3D ? "2D" : "3D"])
            }
        }
        .onChange(of: isNeededFlat) { _, needed in
            if needed { in3D = false }
        }
    }
}

/// One button for everything a gesture can do, so no capability ever needs a gesture.
private struct PlusButton: View {
    let touches: PlanTouches
    let hasPlan: Bool
    @Binding var in3D: Bool
    let onRooms: () -> Void

    private var picks: Picks { touches.picks }

    var body: some View {
        let options = PlusOption.available(picks.rules, hasPlan: hasPlan)
        if picks.showsPlus(hasPlan: hasPlan) {
            content(options)
                .disabled(picks.sending)
                .popoverTip(HoldTip(hasZones: picks.rules.zones), arrowEdge: .bottom)
        }
    }

    @ViewBuilder private func content(_ options: [PlusOption]) -> some View {
        if !picks.zones.isEmpty {
            GlassIconButton(symbol: "plus", label: "Add Zone", tint: picks.zonesAtLimit ? Theme.faint : Theme.ink,
                            action: touches.addZone)
        } else if let only = options.first, options.count == 1 {
            GlassIconButton(symbol: only == .rooms ? only.symbol : "plus", label: only.title) { run(only) }
        } else {
            menu(options)
        }
    }

    private func menu(_ options: [PlusOption]) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { run(option) } label: { Label(option.title, systemImage: option.symbol) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                .contentShape(Circle())
                .glass(in: Circle(), interactive: true)
        }
        // The button sits low on the screen, and the first choice must stay first.
        .menuOrder(.fixed)
        .accessibilityLabel("Add")
    }

    private func run(_ option: PlusOption) {
        switch option {
        case .rooms: onRooms()
        case .zone: placeOnFlatPlan(touches.addZone)
        case .pin: placeOnFlatPlan(touches.dropPin)
        }
    }

    private func placeOnFlatPlan(_ place: @escaping () -> Void) {
        guard in3D else { return place() }
        in3D = false
        touches.whenPlanIsShown(place)
    }
}
