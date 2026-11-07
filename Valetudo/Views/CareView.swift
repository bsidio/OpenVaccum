import SwiftUI

struct CareView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var resetting: Consumable?
    @State private var confirming = false
    @State private var read = ReadCheck.checking
    @State private var showLogin = false

    private enum ReadCheck { case checking, fine, failed }
    private enum Phase { case loading, failed, empty, ready }

    private var parts: [Consumable] { store.consumables.filter { !$0.isCleaningTask } }
    private var cleaningTasks: [Consumable] { store.consumables.filter(\.isCleaningTask) }
    private var stats: [HistoryStat] { HistoryStat.all(from: store.total) }
    private var hasContent: Bool { !store.consumables.isEmpty || !stats.isEmpty }

    private var phase: Phase {
        if hasContent { return .ready }
        if !store.hasLoaded { return .loading }
        switch read {
        case .checking: return .loading
        case .failed: return .failed
        case .fine: return .empty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading: loading
                case .failed: failure
                case .empty: empty
                case .ready: list
                }
            }
            .background(Theme.mist)
            .navigationTitle("Care")
            .task(id: [store.hasLoaded, store.connected, hasContent, store.capabilities.isEmpty]) { await checkReads() }
            .sheet(isPresented: $showLogin) { SignInSheet() }
            .confirmationDialog("Reset \(resetting?.title ?? "This Item")?", isPresented: $confirming,
                                titleVisibility: .visible, presenting: resetting) { item in
                Button("Reset Counter") {
                    store.markDone(item)
                }
            } message: { item in
                Text(item.isCleaningTask
                     ? "Do this after cleaning. It restarts the countdown."
                     : "Do this after fitting a new one. It restarts the countdown.")
            }
        }
    }

    // MARK: States

    private var loading: some View {
        ProgressView("Loading parts")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failure: some View {
        ContentUnavailableView {
            Label("Can't Load Care Details", systemImage: store.readSymbol)
        } description: {
            Text(store.readAdvice)
        } actions: {
            Button {
                if store.needsLogin { showLogin = true } else { Task { await retry() } }
            } label: {
                Text(store.needsLogin ? "Sign In" : "Try Again").foregroundStyle(Theme.onCobalt)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing to Track", systemImage: "heart.text.square")
        } description: {
            Text("This robot doesn't report part wear or cleaning history.")
        }
    }

    /// The store keeps quiet when a read fails, so an empty screen could mean either "this
    /// robot has nothing to report" or "the read failed". Asking once more tells them apart.
    private func checkReads() async {
        guard store.hasLoaded else { return }
        guard !hasContent else {
            read = .fine
            return
        }
        guard !store.capabilities.isEmpty, store.connected else {
            read = .failed
            return
        }
        let succeeded = await readsSucceed()
        if !Task.isCancelled { read = succeeded ? .fine : .failed }
    }

    private func readsSucceed() async -> Bool {
        do {
            if store.has(Cap.consumables) {
                _ = try await store.client.get("\(Cap.root)/\(Cap.consumables)", as: [Consumable].self)
            }
            if store.has(Cap.totalStats) {
                _ = try await store.client.get("\(Cap.root)/\(Cap.totalStats)", as: [DataPoint].self)
            }
            return true
        } catch {
            return false
        }
    }

    private func retry() async {
        read = .checking
        // With no capabilities the first connection failed, so nothing else can load yet.
        if store.capabilities.isEmpty {
            await store.loadEverything()
        } else {
            await store.loadDetails()
        }
        await checkReads()
        if read == .failed {
            store.notify(store.reachable ? "These details still didn't arrive" : "Still can't reach the robot",
                         symbol: "exclamationmark.triangle.fill", seconds: 4.5, isProblem: true)
        }
    }

    /// The store keeps the old figures when a read fails, so a refresh has to say when that happened.
    private func refresh() async {
        await store.loadDetails()
        let succeeded = await readsSucceed()
        if !succeeded, !Task.isCancelled {
            store.notify("Couldn't refresh. These details may be out of date.",
                         symbol: "exclamationmark.triangle.fill", seconds: 4.5, isProblem: true)
        }
    }

    // MARK: Content

    private var status: CareStatus {
        CareStatus(reachable: store.reachable,
                   parts: store.consumables.map { ($0, $0.tone(life: store.life(of: $0))) },
                   dockNotices: store.dockNotices.map(\.text))
    }

    private var list: some View {
        List {
            let summary = status
            if store.needsLogin {
                Section {
                    Banner(text: RobotStore.loginAdvice, tone: .critical, action: { showLogin = true })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !store.consumables.isEmpty || summary.tone != .good {
                Section {
                    StatusRow(status: summary)
                        .listRowBackground(summary.needsAttention ? summary.tone.color.opacity(0.12) : Theme.paper)
                }
            }
            partSection("To Replace", items: parts, footer: "Tap a part after fitting a new one to restart its countdown.")
            partSection("To Clean", items: cleaningTasks, footer: "Tap an item after cleaning it to restart its countdown.")
            if !stats.isEmpty {
                historySection
                achievementsSection
            }
        }
        .themedList()
        .refreshable { await refresh() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: status)
    }

    @ViewBuilder
    private func partSection(_ title: String, items: [Consumable], footer: String) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    PartButton(item: item, life: store.life(of: item)) {
                        resetting = item
                        confirming = true
                    }
                }
            } header: {
                Text(title)
            } footer: {
                Text(footer)
            }
        }
    }

    private var historySection: some View {
        Section("History") {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(stats) { StatTile(value: $0.value, label: $0.kind.label, symbol: $0.kind.symbol, tint: $0.kind.tint) }
            }
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: stats.map(\.value))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var achievementsSection: some View {
        Section("Achievements") {
            ForEach(stats) { stat in
                NavigationLink {
                    AchievementsView(kind: stat.kind)
                } label: {
                    AchievementRow(kind: stat.kind, amount: stat.amount)
                }
                .accessibilityHint("Shows every achievement for this total")
            }
        }
    }
}

// MARK: - Status

/// The one-line answer to "does the robot need anything from me?".
private struct CareStatus: Equatable {
    let tone: Tone
    let symbol: String
    let title: String
    let detail: String

    var needsAttention: Bool { tone == .warning || tone == .critical }

    /// Dock notices count too, so this never says all is well while Home asks for a refill.
    init(reachable: Bool, parts: [(item: Consumable, tone: Tone)], dockNotices: [String]) {
        guard reachable else {
            tone = .neutral
            symbol = "wifi.exclamationmark"
            title = "Can't Reach the Robot"
            detail = "These details may be out of date."
            return
        }
        let due = parts.filter { $0.tone == .critical }.map(\.item.title)
        let low = parts.filter { $0.tone == .warning }.map(\.item.title)
        let count = due.count + low.count + dockNotices.count
        guard count > 0 else {
            tone = .good
            symbol = Tone.good.symbol
            title = "Everything Looks Good"
            detail = "Nothing needs replacing or cleaning right now."
            return
        }
        tone = due.isEmpty ? .warning : .critical
        symbol = tone.symbol
        title = count == 1 ? "1 Item Needs Attention" : "\(count) Items Need Attention"
        let names = due + low
        let lines = (names.isEmpty ? [] : [names.formatted(.list(type: .and))]) + dockNotices
        detail = lines.joined(separator: "\n")
    }
}

private struct StatusRow: View {
    let status: CareStatus
    @ScaledMetric(relativeTo: .title2) private var disc: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: status.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(status.tone.color)
                .symbolEffect(.bounce, value: reduceMotion ? "" : status.title)
                .frame(width: disc, height: disc)
                .background(status.tone.color.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Parts

private struct PartButton: View {
    let item: Consumable
    let life: Double?
    let action: () -> Void

    private var tone: Tone { item.tone(life: life) }

    private var name: some View {
        Text(item.title)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var timeLeft: some View {
        Text(item.timeLeft)
            .font(.subheadline.weight(tone == .critical ? .semibold : .regular))
            .foregroundStyle(tone == .warning || tone == .critical ? tone.color : Theme.slate)
            .contentTransition(.numericText())
    }

    private var spokenValue: String {
        guard let life else { return item.timeLeft }
        return "\(item.timeLeft), \(life.clampedToUnit.formatted(.percent.precision(.fractionLength(0))))"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: item.symbol, color: item.tileColor)
                VStack(alignment: .leading, spacing: 7) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            name
                            Spacer(minLength: 0)
                            timeLeft
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            name
                            timeLeft
                        }
                    }
                    if let life {
                        Gauge(value: life.clampedToUnit) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(tone.color)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityLabel(item.title)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Asks before restarting its countdown")
    }
}

private extension Double {
    var clampedToUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

private extension Consumable {
    var timeLeft: String { remaining.value <= 0 ? "Due now" : remainingText }

    func tone(life: Double?) -> Tone {
        if remaining.value <= 0 { return .critical }
        guard let life else { return .neutral }
        return life < 0.15 ? .warning : .good
    }

    var symbol: String {
        switch (type, subType) {
        case ("brush", "main"): return "paintbrush.fill"
        case ("brush", _): return "paintbrush.pointed.fill"
        case ("filter", _): return "line.3.horizontal.decrease"
        case ("mop", _): return "drop.fill"
        case ("detergent", _): return "flask.fill"
        case ("bin", _): return "trash.fill"
        case ("cleaning", "sensor"): return "sensor.fill"
        case ("cleaning", "wheel"): return "circle.circle.fill"
        case ("cleaning", _): return "sparkles"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    /// System colours, because white symbols don't read on Theme's light dark-mode tints.
    var tileColor: Color {
        switch type {
        case "filter": return .teal
        case "mop": return .cyan
        case "detergent": return .purple
        case "bin": return .brown
        case "cleaning": return .blue
        default: return .indigo
        }
    }
}

// MARK: - History

private struct HistoryStat: Identifiable {
    let kind: Achievement.Kind
    let amount: Double
    var id: Achievement.Kind { kind }

    static func all(from total: [String: Double]) -> [HistoryStat] {
        Achievement.Kind.allCases.compactMap { kind in
            total[kind.rawValue].map { HistoryStat(kind: kind, amount: $0) }
        }
    }

    var value: String {
        switch kind {
        case .time: return CleaningFigures.duration(amount)
        case .area: return CleaningFigures.area(amount)
        case .count: return amount.formatted(.number.precision(.fractionLength(0)))
        }
    }

}

/// How cleaning time and area read, in the history here and for a run in Controls.
enum CleaningFigures {
    static func duration(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours < 1 {
            return Measurement(value: (seconds / 60).rounded(), unit: UnitDuration.minutes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
        }
        return Measurement(value: hours, unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(hours < 100 ? 1 : 0))))
    }

    static func area(_ squareCm: Double) -> String {
        let squareMetres = squareCm / 10_000
        return Measurement(value: squareMetres, unit: UnitArea.squareMeters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(squareMetres < 100 ? 1 : 0))))
    }
}
