import SwiftUI

/// What the floating bar shows. Worked out apart from the view so every state can be tested.
struct BarModel: Equatable {
    enum Icon: String, Identifiable {
        case clear, passes, stop, dock, locate, controls
        var id: String { rawValue }
    }

    struct Primary: Equatable {
        /// Widest first, for `ViewThatFits`.
        var titles: [String]
        var symbol: String
        var spoken: String
        var pauses = false
        var busy = false
        var enabled = true
        /// A long press shows the request this job sends.
        var connects = false
    }

    var icons: [Icon]
    var primary: Primary?
}

extension Picks {
    /// `name` turns a room's id into its name.
    func bar(name: (String) -> String, pinBlocked: Bool = false) -> BarModel {
        var model = rules.working ? runningBar : kind == .nothing ? restingBar : pickBar(name: name, pinBlocked: pinBlocked)
        // Once the robot is moving, Pause comes first. Its answer to us can take a while yet.
        if sending, !rules.working {
            let symbol = model.primary?.symbol ?? "play.fill"
            model.primary = .init(titles: ["Starting"], symbol: symbol, spoken: "Starting", busy: true, enabled: false)
        }
        return model
    }

    private var runningBar: BarModel {
        let primary = BarModel.Primary(titles: ["Pause"], symbol: "pause.fill", spoken: "Pause", pauses: true, enabled: rules.reachable)
        return BarModel(icons: (rules.basic ? [.stop, .dock] : []) + [.controls], primary: rules.basic && !rules.manual ? primary : nil)
    }

    private var restingBar: BarModel {
        guard !rules.paused else {
            let primary = BarModel.Primary(titles: ["Resume"], symbol: "play.fill", spoken: "Resume", enabled: rules.reachable)
            return BarModel(icons: (rules.basic ? [.stop, .dock] : []) + [.controls], primary: rules.basic ? primary : nil)
        }
        let title = rules.rooms ? "Clean All" : "Clean"
        let primary = BarModel.Primary(titles: [title], symbol: "play.fill", spoken: title, enabled: rules.reachable)
        let basics: [BarModel.Icon] = rules.stoppable ? [.stop, .dock] : [.dock]
        let icons = (rules.basic ? basics : []) + (rules.locate ? [.locate] : []) + [.controls]
        return BarModel(icons: icons, primary: rules.basic ? primary : nil)
    }

    private func pickBar(name: (String) -> String, pinBlocked: Bool) -> BarModel {
        let icons: [BarModel.Icon] = [.clear] + (maxPasses > 1 ? [.passes] : []) + [.controls]
        var primary = pickPrimary(name: name)
        primary.enabled = rules.reachable && !pinBlocked
        primary.connects = true
        return BarModel(icons: icons, primary: primary)
    }

    private func pickPrimary(name: (String) -> String) -> BarModel.Primary {
        let count = passes
        switch kind {
        case .pin where verb == .go:
            return .init(titles: ["Go Here"], symbol: "location.fill", spoken: "Go Here")
        case .pin:
            return .init(titles: PickWording.pinTitles(passes: count), symbol: "play.fill",
                         spoken: "Clean Here" + PickWording.spokenCount(count))
        case .zones:
            let titles = PickWording.zoneTitles(count: zones.count + (adding ? 1 : 0), passes: count)
            return .init(titles: titles, symbol: "play.fill", spoken: titles[0])
        default:
            let names = rooms.map(name)
            return .init(titles: PickWording.roomTitles(names: names, passes: count), symbol: "play.fill",
                         spoken: PickWording.spokenRooms(names: names, ordered: rules.roomOrder, passes: count))
        }
    }
}

/// Starting labels ignore taps for half a second after they change, so the second tap of a
/// double tap on Pause can't land on Resume. Anything that stops the robot skips this.
struct StartGuard {
    static let delay: TimeInterval = 0.5

    /// How long taps are ignored after a change.
    let delay: TimeInterval
    private var changed: Date?

    init(delay: TimeInterval = Self.delay) { self.delay = delay }

    mutating func labelChanged(at date: Date = .now) { changed = date }

    func allowsStart(at date: Date = .now) -> Bool {
        guard let changed else { return true }
        return date.timeIntervalSince(changed) >= delay
    }
}

/// The floating bar. The plan is for picking and this is for acting: only its primary can start the robot.
struct HomeBar: View {
    let picks: Picks
    @Binding var height: CGFloat
    let onGo: () -> Void
    let onControls: () -> Void
    @Environment(RobotStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledIcon: CGFloat = 46
    /// When picks clear, Stop or Dock moves into the place Clear had, so a second tap meant for
    /// Clear would reach the robot. Clearing invites taps in a row ("Clear Pin and Return to
    /// Rooms", then "Clear"), slower than a double tap, so these wait a full second.
    @State private var rowGuard = StartGuard(delay: 1)

    /// Capped so three icons and the passes control still share a row at the largest text size.
    private var largeIcon: CGFloat { min(scaledIcon, 58) }

    var body: some View {
        let model = picks.bar(name: store.roomName, pinBlocked: picks.pinIsBlocked(on: store.plan))
        Group {
            if typeSize.isAccessibilitySize {
                twoRows(model)
            } else {
                // A narrow phone can run out of width a size or two before that.
                ViewThatFits(in: .horizontal) {
                    oneRow(model)
                    twoRows(model)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .onChange(of: model.icons) { rowGuard.labelChanged() }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.22), value: model)
    }

    /// Liquid Glass takes no touches of its own, and a touch that misses a button here must
    /// not reach the plan underneath, where a tap could remove the pin it was aiming to use.
    private func surface<S: Shape, Content: View>(_ shape: S, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(6)
            .glass(in: shape)
            .contentShape(shape)
    }

    private func oneRow(_ model: BarModel) -> some View {
        surface(Capsule()) {
            HStack(spacing: 4) {
                icons(model, side: 46)
                rowPrimary(model)
            }
        }
    }

    /// The frame hands all the spare width to the primary, and keeps its trailing edge still.
    /// The hidden copy is the narrowest the primary can be, so one row only gives up when even
    /// that can't fit, not as soon as the longest wording can't. The real one adapts in the overlay.
    @ViewBuilder private func rowPrimary(_ model: BarModel) -> some View {
        if let primary = model.primary {
            PrimaryLabel(model: primary, title: primary.titles.last ?? "", showsSymbol: false)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .overlay(alignment: .trailing) { self.primary(model) }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func twoRows(_ model: BarModel) -> some View {
        surface(RoundedRectangle(cornerRadius: 28, style: .continuous)) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    icons(model, side: largeIcon)
                    Spacer(minLength: 0)
                }
                primary(model, wraps: true)
            }
        }
    }

    private func icons(_ model: BarModel, side: CGFloat) -> some View {
        ForEach(model.icons) { icon($0, side: side).transition(.opacity) }
    }

    @ViewBuilder private func primary(_ model: BarModel, wraps: Bool = false) -> some View {
        if let primary = model.primary {
            BarPrimary(model: primary, wraps: wraps, picks: picks, onPause: store.pause, onGo: onGo)
        }
    }

    private func guarded(_ action: @escaping () -> Void) -> () -> Void {
        { if rowGuard.allowsStart() { action() } }
    }

    @ViewBuilder private func icon(_ icon: BarModel.Icon, side: CGFloat) -> some View {
        switch icon {
        case .clear:
            RemoteIcon(symbol: picks.clearSymbol, label: picks.clearLabel, side: side) {
                withAnimation(PickMotion.settle) { picks.clear() }
            }
            .disabled(picks.sending)
        case .passes:
            PassesMenu(picks: picks).layoutPriority(1)
        case .stop:
            RemoteIcon(symbol: "stop.fill", label: "Stop", side: side, action: guarded(store.stop)).disabled(!store.connected)
        case .dock:
            RemoteIcon(symbol: DockGlyph.symbolName, label: "Dock", side: side, action: guarded(store.dock))
                .disabled(!store.connected || !store.state.canDock)
        case .locate:
            RemoteIcon(symbol: "speaker.wave.2.fill", label: "Locate", side: side, action: guarded(store.locate)).disabled(!store.connected)
        case .controls:
            RemoteIcon(symbol: "slider.horizontal.3", label: "Controls", side: side, action: onControls)
            if store.connected, let level = store.state.battery {
                BarBattery(level: level, charging: store.state.charging)
            }
        }
    }
}

/// The filled button that does the job. The bar and the Rooms sheet share it.
struct BarPrimary: View {
    let model: BarModel.Primary
    var wraps = false
    let picks: Picks
    let onPause: () -> Void
    let onGo: () -> Void
    @Environment(RobotStore.self) private var store
    @State private var startGuard = StartGuard()
    @State private var request: JobRequest?
    @ScaledMetric(relativeTo: .subheadline) private var twoLines: CGFloat = 42

    var body: some View {
        Button(action: tapped) {
            if wraps { wrapping } else { oneLine }
        }
        .buttonStyle(.pressable)
        .disabled(!model.enabled)
        .onChange(of: model.titles) { startGuard.labelChanged() }
        .accessibilityLabel(model.spoken)
        .accessibilityInputLabels(model.titles + [model.spoken])
        .contentShape(.contextMenuPreview, Capsule())
        .contextMenu {
            if model.connects {
                Button("Connect with Other Apps", systemImage: "link") {
                    request = picks.job(on: store.plan).flatMap(store.request(for:))
                }
            }
        }
        // Here, not on Home, so it also opens from the Rooms sheet.
        .sheet(item: $request) { ConnectSheet(request: $0) }
    }

    private var oneLine: some View {
        ViewThatFits(in: .horizontal) {
            // By position, not by text, so a changing word animates in place.
            // The symbol goes before any words do, because the words name the job.
            ForEach(model.titles.indices, id: \.self) { index in
                PrimaryLabel(model: model, title: model.titles[index])
                PrimaryLabel(model: model, title: model.titles[index], showsSymbol: false)
            }
        }
    }

    /// Each title but the last is free to take as many lines as it needs, because one held to
    /// two lines always fits, cut off, and the words lost that way would be the count.
    private var wrapping: some View {
        HeightLimit(limit: max(twoLines, PrimaryLabel.height) + PrimaryLabel.wrappedPadding * 2) {
            ViewThatFits(in: .vertical) {
                ForEach(model.titles.indices, id: \.self) { index in
                    PrimaryLabel(model: model, title: model.titles[index], wraps: true,
                                 lines: index == model.titles.count - 1 ? 2 : nil)
                }
            }
        }
    }

    private func tapped() {
        if model.pauses {
            onPause()
        } else if startGuard.allowsStart() {
            onGo()
        }
    }
}

/// How the primary looks, apart from what it does.
private struct PrimaryLabel: View {
    static let height: CGFloat = 46
    static let wrappedPadding: CGFloat = 4

    let model: BarModel.Primary
    let title: String
    var showsSymbol = true
    var wraps = false
    var lines: Int? = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if model.busy {
                ProgressView().tint(Theme.onCobalt).controlSize(.small).accessibilityHidden(true)
            } else if showsSymbol {
                Image(systemName: model.symbol).contentTransition(.symbolEffect(.replace))
            }
            Text(title)
                .lineLimit(lines)
                .multilineTextAlignment(.center)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
        }
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: !wraps, vertical: wraps)
        .foregroundStyle(Theme.onCobalt)
        .padding(.horizontal, 15)
        .frame(minHeight: Self.height)
        .frame(maxWidth: wraps ? .infinity : nil)
        .padding(.vertical, wraps ? Self.wrappedPadding : 0)
        .background(Theme.cobalt.gradient, in: Capsule())
        .opacity(model.enabled || model.busy ? 1 : 0.45)
    }
}

/// Offers its child `limit` of height, but takes up only what the child uses. A plain
/// `frame(maxHeight:)` would stretch to the limit, leaving a one-line title in a two-line button.
private struct HeightLimit: Layout {
    let limit: CGFloat

    private func offer(_ width: CGFloat?) -> ProposedViewSize { ProposedViewSize(width: width, height: limit) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(offer(proposal.width)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: offer(bounds.width))
    }
}

/// How many times to clean, in words, because a bare number and a sign read like a zoom level.
struct PassesMenu: View {
    let picks: Picks

    private var count: Binding<Int> {
        Binding(get: { picks.passes }, set: { picks.passes = $0 })
    }

    var body: some View {
        Menu {
            // A Section's header is dropped around a Picker, so plain text carries the title.
            Text("How Many Times?")
            Picker("How Many Times?", selection: count) {
                ForEach(1...max(1, picks.maxPasses), id: \.self) { Text(PickWording.times($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(PickWording.times(picks.passes))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.slate)
            }
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            // Only ever needed at the largest sizes on a narrow phone, to stay inside the bar.
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(Theme.track, in: Capsule())
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        // The bar is low on the screen, and a count should still read from one upward.
        .menuOrder(.fixed)
        .disabled(picks.sending)
        .accessibilityLabel("How many times")
        .accessibilityValue(PickWording.times(picks.passes))
        .accessibilityInputLabels(["How many times", PickWording.times(picks.passes)])
    }
}

/// A round symbol button inside the bar.
private struct RemoteIcon: View {
    let symbol: String
    let label: String
    var side: CGFloat = 46
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            AppSymbol(name: symbol)
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Theme.ink)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

extension RobotStore {
    /// The sheet can pick rooms when the plan failed to load, so `rooms` is the fallback.
    func roomName(_ id: String) -> String {
        plan?.rooms.first { $0.id == id }?.name ?? rooms.first { $0.id == id }?.title ?? "Room"
    }
}
