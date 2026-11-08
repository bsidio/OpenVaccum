import SwiftUI

/// What a robot with no floor plan needs, following Valetudo's own welcome dialog. Getting this
/// wrong costs a whole run, because some robots only keep a plan if they're set up first.
struct FirstPlanGuide: View {
    let bottomInset: CGFloat
    /// Runs once the owner has confirmed.
    let onMappingPass: () -> Void
    @Environment(RobotStore.self) private var store
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24
    /// Offered only to a robot that had it off, and only ever turned on from here: turning it
    /// off deletes the plan, and Settings warns about that first.
    @State private var offersKeepPlan = false
    @State private var confirming = false

    private static let checks: [(symbol: String, text: String)] = [
        (DockGlyph.symbolName, "The robot is on its dock"),
        ("door.left.hand.open", "The doors to every room are open"),
        ("cable.connector", "No cables are loose on the floor"),
        ("nosign", "Anywhere it shouldn't go is blocked off")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heading
                if !store.state.isActive {
                    checklist
                    if offersKeepPlan { keepPlan }
                    nextStep
                    Text("Just restarted the robot? Its plan can take a minute or two to appear here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 8)
            .padding(.bottom, bottomInset + 8)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: store.switches[.persistentMap], initial: true) { _, on in
            if on == false { offersKeepPlan = true }
        }
    }

    private var heading: some View {
        VStack(spacing: 6) {
            Image(systemName: "map")
                .font(.system(size: 36))
                .foregroundStyle(Theme.slate)
                .accessibilityHidden(true)
            Text("No Floor Plan Yet")
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(store.state.isActive ? "It appears here once the robot sends it."
                                      : "The first step is to let the robot map your home. Before it starts, check that:")
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.checks, id: \.text) { check in
                HStack(spacing: 10) {
                    AppSymbol(name: check.symbol)
                        .foregroundStyle(Theme.cobalt)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                    Text(check.text)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(padding: 14, radius: Metric.controlRadius)
    }

    private var keepPlan: some View {
        Toggle(RobotSwitch.persistentMap.title, isOn: Binding(
            get: { store.switches[.persistentMap] ?? false },
            set: { if $0 { store.set(.persistentMap, to: true) } }))
            .disabled(store.switches[.persistentMap] == true)
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
            .tint(Theme.cobalt)
            .card(padding: 14, radius: Metric.controlRadius)
    }

    @ViewBuilder private var nextStep: some View {
        if store.has(Cap.mappingPass) {
            Button { confirming = true } label: {
                Text("Run a Mapping Pass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onCobalt)
                    .frame(maxWidth: .infinity, minHeight: Metric.hitTarget)
                    .background(Theme.cobalt.gradient, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(!store.connected)
            .confirmationDialog("Start a mapping pass?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Run a Mapping Pass", action: onMappingPass)
            } message: {
                Text("The robot drives around your home to make a new floor plan. If it already has one, this can replace it.")
            }
        } else if store.has(Cap.basic) {
            Text("Then start a clean. Let the robot finish and go back to its dock on its own, or the plan won't be saved.")
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
