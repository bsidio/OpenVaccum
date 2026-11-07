import SwiftUI

/// Valetudo's Robot Coverage Map: the robot's path drawn thick, so anywhere it missed stands
/// out. It stays live during a clean, and nothing can be tapped.
struct CoverageMapView: View {
    /// Valetudo's width, in map pixels, so the band grows with the plan as you zoom.
    private static let pathWidth: CGFloat = 5

    @Environment(RobotStore.self) private var store
    @State private var attempt = 0
    @State private var loaded = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.mist.ignoresSafeArea())
            .navigationTitle("Robot Coverage Map")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                await store.refreshFloorPlan()
                loaded = true
            }
    }

    @ViewBuilder private var content: some View {
        if let plan = store.plan, !plan.isEmpty {
            VStack(spacing: 0) {
                Banner(text: plan.trail.isEmpty
                       ? "The robot's path appears here once it starts moving."
                       : "The thick line shows where the robot has been. Gaps are places it didn't reach.",
                       tone: .neutral)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                PlanCanvas(plan: plan, active: store.connected && store.state.isActive,
                           paused: store.connected && store.state.isUnfinished, showsLabels: false,
                           insets: EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14),
                           overlay: { context, t in Self.drawPath(of: plan, in: context, t) })
                    // A Canvas has nothing for VoiceOver to land on without this.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Robot coverage map")
                    .accessibilityValue(plan.trail.isEmpty ? "No path yet" : "Shows the robot's path")
            }
        } else if store.plan != nil {
            ContentUnavailableView {
                Label("No Floor Plan Yet", systemImage: "map")
            } description: {
                Text(store.planAdvice)
            }
        } else if loaded {
            ContentUnavailableView {
                Label("Can't Load Floor Plan", systemImage: store.readSymbol)
            } description: {
                Text(store.readAdvice)
            } actions: {
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.bordered)
                    .tint(Theme.cobalt)
            }
        } else {
            ProgressView("Loading floor plan")
        }
    }

    /// One stroke, so overlapping passes stay a single even colour and only gaps show through.
    private static func drawPath(of plan: FloorPlan, in context: GraphicsContext, _ t: PlanTransform) {
        var map = context
        map.concatenate(t.affine)
        map.stroke(plan.trail, with: .color(Theme.cobalt.opacity(0.8)),
                   style: StrokeStyle(lineWidth: pathWidth, lineCap: .round, lineJoin: .round))
        map.stroke(plan.predicted, with: .color(Theme.ink.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.6 / t.scale, lineCap: .round, dash: [5 / t.scale, 5 / t.scale]))
    }
}
