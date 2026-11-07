import SwiftUI

/// A room as the sheet lists it. `palette` is its place in the plan's colours, and it's nil
/// when the plan failed to load and the names came from the robot's room list instead.
struct RoomChoice: Identifiable, Equatable {
    let id: String
    let name: String
    var palette: Int?

    /// Its id in the Other Rooms section. With one id in both sections `List` moves the row across
    /// when it's picked, and it keeps that section's no-drag setting, so it never gets a handle.
    var otherRowID: String { "other-\(id)" }
}

/// The list route to picking rooms, and the recommended one with VoiceOver. It stays open
/// over the plan, and plan taps behind it update the same list.
struct RoomsSheet: View {
    /// A detent counts as settled after its animation, so the plan refits once, not on every frame of a drag.
    private static let settleTime: Duration = .milliseconds(350)

    let touches: PlanTouches
    let rooms: [RoomChoice]
    @Binding var obstacle: FloorPlan.Obstacle?
    let onGo: () -> Void
    /// Reports the sheet's top edge at `.medium`, and nil at `.large`, where the plan is covered anyway.
    let onSettle: (CGFloat?) -> Void
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent = PresentationDetent.medium
    @State private var top: CGFloat = 0

    private var picks: Picks { touches.picks }
    private var ordered: Bool { picks.rules.roomOrder }
    private var picked: [RoomChoice] { picks.rooms.compactMap { id in rooms.first { $0.id == id } } }
    private var others: [RoomChoice] { rooms.filter { !picks.rooms.contains($0.id) } }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Rooms")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { pinnedRow }
                .modifier(ToastHost(toast: store.toast))
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { top = $0 }
        // At these sizes the pinned row alone would fill `.medium`, leaving no rooms to see.
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        .task(id: detent) {
            try? await Task.sleep(for: Self.settleTime)
            if !Task.isCancelled { onSettle(detent == .medium ? top : nil) }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .sheet(item: $obstacle) { ObstacleSheet(obstacle: $0) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if others.isEmpty {
                Button("Deselect All") { picks.clear() }.disabled(picks.sending)
            } else {
                Button("Select All") { picks.selectAll(rooms.map(\.id)) }
                    .disabled(picks.sending || picks.rules.working)
            }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private var list: some View {
        List {
            if !picked.isEmpty {
                Section(ordered ? "Clean in This Order" : "Picked") {
                    ForEach(Array(picked.enumerated()), id: \.element.id) { index, room in
                        row(room, position: index + 1).moveDisabled(picks.sending)
                    }
                    .onMove(perform: ordered ? { picks.moveRooms(from: $0, to: $1) } : nil)
                }
            }
            if !others.isEmpty {
                Section("Other Rooms") {
                    ForEach(others, id: \.otherRowID) { row($0, position: nil).moveDisabled(true) }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .themedList()
    }

    private func row(_ room: RoomChoice, position: Int?) -> some View {
        Button {
            touches.pick(room: room.id)
        } label: {
            HStack(spacing: 12) {
                if let palette = room.palette {
                    Circle()
                        .fill(Theme.rooms[palette % Theme.rooms.count])
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
                        .frame(width: 14, height: 14)
                }
                if let position { mark(position) }
                Text(room.name).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.paper)
        .accessibilityLabel(room.name)
        .accessibilityValue(value(position))
        .accessibilityAddTraits(position == nil ? [] : .isSelected)
        .accessibilityActions { moveActions(position) }
    }

    @ViewBuilder private func mark(_ position: Int) -> some View {
        if ordered {
            Text("\(position)")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.cobalt)
        } else {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
        }
    }

    private func value(_ position: Int?) -> String {
        guard let position else { return "Not picked" }
        return ordered ? "Picked, \(PickWording.ordinal(position))" : "Picked"
    }

    @ViewBuilder private func moveActions(_ position: Int?) -> some View {
        if ordered, !picks.sending, let position {
            if position > 1 {
                Button("Move Up") { picks.moveRooms(from: [position - 1], to: position - 2) }
            }
            if position < picks.rooms.count {
                Button("Move Down") { picks.moveRooms(from: [position - 1], to: position + 1) }
            }
        }
    }

    /// Stacked at the largest sizes, because this row sets the sheet's width, and a row too
    /// wide for the screen would push the whole list off both edges with it.
    private var pinnedRow: some View {
        let primary = picks.bar(name: store.roomName).primary
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    passes
                    if let primary { BarPrimary(model: primary, wraps: true, picks: picks, onPause: store.pause, onGo: onGo) }
                }
            } else {
                HStack(spacing: 8) {
                    passes
                    Spacer(minLength: 0)
                    if let primary { BarPrimary(model: primary, picks: picks, onPause: store.pause, onGo: onGo) }
                }
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var passes: some View {
        if picks.maxPasses > 1 { PassesMenu(picks: picks) }
    }
}
