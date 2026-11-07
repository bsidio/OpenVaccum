import SwiftUI

/// Mode, power and everything the dock can do.
struct ControlsSheet: View {
    private enum DockCommand { case empty, wash, dry }

    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 560
    /// Locks the dock tiles after a tap, so a second tap can't undo the first.
    @State private var sentCommand: DockCommand?
    /// Tiles widen with the text size, so the grid drops a column instead of breaking words.
    @ScaledMetric(relativeTo: .footnote) private var modeTileWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .footnote) private var dockTileWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .footnote) private var readingWidth: CGFloat = 150

    /// The navigation bar and home indicator around the scrolling content.
    private static let chromeHeight: CGFloat = 74

    private static let dockParts: [(key: String, title: String, symbol: String)] = [
        ("water_tank_clean", "Clean Water", "drop.fill"),
        ("water_tank_dirty", "Dirty Water", "drop.degreesign.fill"),
        ("detergent", "Detergent", "flask.fill"),
        ("dustbag", "Dust Bag", "trash.fill")
    ]

    private var dockState: String { store.state.dockStatus ?? "idle" }
    private var robotDocked: Bool { store.state.status == "docked" }

    private var hasDockActions: Bool {
        [Cap.autoEmpty, Cap.mopWash, Cap.mopDry].contains(where: store.has)
    }

    private var hasMopDock: Bool { store.has(Cap.mopWash) || store.has(Cap.mopDry) }
    private var supportedAttachments: [String] { store.info?.modelDetails?.supportedAttachments ?? [] }
    private var supportedDockParts: [String] { store.info?.modelDetails?.supportedDockComponents ?? [] }

    /// As strict as Valetudo's web page: a robot that doesn't say it's attached counts as not.
    private var mopAttached: Bool { store.state.mopAttached }

    /// Why the tiles are greyed out, when the reason isn't the job already running.
    private var dockNote: String? {
        guard hasDockActions else { return nil }
        if dockState == "error" { return "The dock has a problem. Check it before trying again." }
        if !robotDocked { return "These work while the robot is on its dock." }
        return hasMopDock && store.hasLoaded && !mopAttached ? "Attach the mop to wash or dry it." : nil
    }

    /// What the dock and robot report. It's usually all fine, so it shares one small card.
    private var readings: [Reading] {
        let parts = Self.dockParts.filter { store.state.dockParts[$0.key] != nil || supportedDockParts.contains($0.key) }
            .map { part in
                let value = store.state.dockParts[part.key] ?? "unknown"
                return Reading(id: part.key, title: part.title, value: Self.word(for: value), symbol: part.symbol,
                               tone: Self.tone(for: value))
            }
        guard !supportedAttachments.isEmpty else { return parts }
        let fitted = store.state.attachments.sorted { $0.key < $1.key }.map { type, attached -> Reading in
            let part = Attachment(type: type)
            return Reading(id: type, title: part.title, value: attached ? "Attached" : "Not Attached", symbol: part.symbol,
                           tone: attached ? .good : .neutral)
        }
        return parts + fitted
    }

    /// The job under way, or else the last one. One line, so every control still fits on the screen.
    private var runFigures: String? {
        guard store.has(Cap.currentStats) else { return nil }
        let run = store.currentRun
        // Below these they'd round to zero, which says nothing.
        let figures = [run.seconds.flatMap { $0 >= 30 ? CleaningFigures.duration($0) : nil },
                       run.squareCentimetres.flatMap { $0 >= 500 ? CleaningFigures.area($0) : nil }]
        let shown = figures.compactMap { $0 }
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    // Only what the current mode uses: mopping alone has no suction, and so on.
                    if store.state.mode != "mop" { powerSection(.fan) }
                    if store.state.mode != "vacuum" { powerSection(.water) }
                    if hasDockActions || !readings.isEmpty { dockSection }
                    if let runFigures {
                        // Driving by hand and going somewhere aren't runs, so the figures are from the last one.
                        ControlHeading(title: store.state.status == "cleaning" || store.state.isUnfinished ? "This Run" : "Last Run",
                                       value: runFigures)
                    }
                }
                .padding(Metric.gutter)
                .animation(.snappy(duration: 0.25), value: store.state.mode)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Theme.mist)
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The bar only offers this at rest, and a paused robot is an easy one to lose.
                if store.has(Cap.locate) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Locate", systemImage: "speaker.wave.2.fill", action: store.locate)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .modifier(ToastHost(toast: store.toast))
        }
        // Open at exactly the height of the controls, so nothing hides below the fold.
        .presentationDetents([.height(contentHeight + Self.chromeHeight)])
        .presentationDragIndicator(.visible)
        .task(id: sentCommand) { await releaseDockTiles() }
        .onChange(of: dockState) { sentCommand = nil }
    }

    /// Normally a change of dock state ends the wait. The dock can take a while to answer, so
    /// washing and drying wait as long as Valetudo's web page does. Emptying only needs to
    /// outlast the command.
    private func releaseDockTiles() async {
        guard let sentCommand else { return }
        try? await Task.sleep(for: .seconds(sentCommand == .empty ? 3 : 25))
        if !Task.isCancelled { self.sentCommand = nil }
    }

    private func send(_ command: DockCommand, _ action: () -> Void) {
        sentCommand = command
        action()
    }

    @ViewBuilder private var modeSection: some View {
        let modes = PresetKind.ordered(store.presets[.mode] ?? [])
        if !modes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                GroupTitle("Mode")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: modeTileWidth), spacing: 10)], spacing: 10) {
                    ForEach(modes, id: \.self) { mode in
                        ActionTile(title: PresetKind.label(mode), selected: store.state.mode == mode,
                                   action: { store.set(.mode, to: mode) }) {
                            ModeIcon(mode: mode)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func powerSection(_ kind: PresetKind) -> some View {
        let options = PresetKind.ordered(store.presets[kind] ?? [])
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // A level set some other way matches no option, so the picker alone would show nothing.
                let current = store.selected(kind).flatMap { options.contains($0) ? nil : PresetKind.label($0) }
                ControlHeading(title: kind.title, value: current)
                SlidingPicker(options: options, selection: store.selected(kind), title: PresetKind.label) {
                    store.set(kind, to: $0)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var dockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasDockActions || !store.state.dockParts.isEmpty {
                ControlHeading(title: "Dock", value: store.state.dockStatus.map(Self.dockWord),
                               tone: dockState == "error" ? .critical : .neutral)
            } else {
                GroupTitle("Attachments")
            }
            if hasDockActions {
                // These are the same rules as Valetudo's web page. The robot itself doesn't check
                // them, so a tap here is all that stands between the command and the firmware.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dockTileWidth), spacing: 10)], spacing: 10) {
                    if store.has(Cap.autoEmpty) {
                        DockButton(title: "Empty Bin", symbol: "arrow.up.bin.fill",
                                   busy: dockState == "emptying" || sentCommand == .empty) { send(.empty, store.emptyBin) }
                            .disabled(sentCommand == .empty || !robotDocked || !["idle", "pause"].contains(dockState))
                    }
                    if store.has(Cap.mopWash) {
                        let washing = dockState == "cleaning"
                        DockButton(title: washing ? "Stop Washing" : "Wash Mop", symbol: "bubbles.and.sparkles.fill",
                                   busy: washing || sentCommand == .wash) { send(.wash, washing ? store.stopWashingMop : store.washMop) }
                            .disabled(sentCommand != nil || !robotDocked || !mopAttached
                                      || !["idle", "cleaning", "pause"].contains(dockState))
                    }
                    if store.has(Cap.mopDry) {
                        let drying = dockState == "drying"
                        DockButton(title: drying ? "Stop Drying" : "Dry Mop", symbol: "fan.fill",
                                   busy: drying || sentCommand == .dry) { send(.dry, drying ? store.stopDryingMop : store.dryMop) }
                            .disabled(sentCommand != nil || !robotDocked || !mopAttached
                                      || !["idle", "drying", "pause"].contains(dockState))
                    }
                }
                if let dockNote {
                    Text(dockNote)
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !readings.isEmpty { ReadingsCard(readings: readings, columnWidth: readingWidth) }
        }
    }

    private static func dockWord(_ value: String) -> String {
        switch value {
        case "idle": return "Idle"
        case "pause": return "Paused"
        case "emptying": return "Emptying"
        case "cleaning": return "Washing"
        case "drying": return "Drying"
        case "error": return "Needs Attention"
        default: return "Unknown"
        }
    }

    private static func word(for value: String) -> String {
        switch value {
        case "ok": return "Good"
        case "empty": return "Empty"
        case "full": return "Full"
        case "missing": return "Missing"
        default: return "Unknown"
        }
    }

    private static func tone(for value: String) -> Tone {
        switch value {
        case "ok": return .good
        case "empty", "full", "missing": return .warning
        default: return .neutral
        }
    }
}

/// Everything the robot has raised, newest first, as Valetudo keeps it.
struct AlertsSheet: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: RobotEvent?
    @State private var answering: Set<String> = []

    private var earlierEvents: [RobotEvent] { store.events.filter(\.processed) }

    var body: some View {
        NavigationStack {
            List {
                if !store.openEvents.isEmpty {
                    Section("Needs Attention") {
                        ForEach(store.openEvents, content: row)
                    }
                }
                if !earlierEvents.isEmpty {
                    Section("Earlier") {
                        ForEach(earlierEvents, content: row)
                    }
                }
            }
            .textCase(nil)
            .themedList()
            .refreshable { await store.loadDetails() }
            .overlay {
                if store.events.isEmpty {
                    if !store.hasLoaded {
                        ProgressView()
                    } else if store.connected {
                        ContentUnavailableView("No Alerts", systemImage: "bell",
                                               description: Text("Anything that needs your attention shows up here."))
                    } else {
                        ContentUnavailableView("Can't Load Alerts", systemImage: store.readSymbol,
                                               description: Text(store.readAdvice))
                    }
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .modifier(ToastHost(toast: store.toast))
            .confirmationDialog("Reset this counter?", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                Button("Reset Counter") {
                    if let confirming { answer(confirming, with: "reset") }
                }
            } message: {
                Text("This restarts the countdown, so do the upkeep first.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ event: RobotEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(for: event), color: Self.color(for: event))
                    .opacity(event.processed ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.body.weight(.medium))
                        .strikethrough(event.processed)
                        .foregroundStyle(event.processed ? Theme.slate : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = detail(for: event) {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A robot clock running ahead of the phone's shouldn't read as the future.
                    if let date = event.date {
                        Text(min(date, .now), format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(Theme.slate)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if !event.processed {
                HStack(spacing: 8) {
                    switch event.style {
                    case .consumable:
                        Button("Mark as Done") { confirming = event }
                    case .pendingMap:
                        Button("Use New Plan") { answer(event, with: "yes") }
                        Button("Keep Current") { answer(event, with: "no") }
                    case .dismiss:
                        Button("Dismiss") { answer(event, with: "ok") }
                    }
                }
                .disabled(answering.contains(event.id))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.paper)
    }

    private func answer(_ event: RobotEvent, with reply: String) {
        answering.insert(event.id)
        Task {
            await store.answer(event, with: reply)
            answering.remove(event.id)
        }
    }

    /// The robot's own description is memory figures, so the one reason it reports gets plain words.
    private func detail(for event: RobotEvent) -> String? {
        guard event.kind == "ValetudoRuntimeErrorValetudoEvent" else { return nil }
        return event.reason == "memory_usage" ? "It was using too much memory." : event.description
    }

    private static func symbol(for event: RobotEvent) -> String {
        switch event.kind {
        case "ConsumableDepletedValetudoEvent":
            switch event.type {
            case "cleaning": return "sparkles"
            case "filter": return "line.3.horizontal.decrease"
            case "mop": return "drop.fill"
            case "detergent": return "flask.fill"
            case "bin": return "trash.fill"
            default: return "paintbrush.fill"
            }
        case "DustBinFullValetudoEvent": return "trash.fill"
        case "MopAttachmentReminderValetudoEvent": return "drop.fill"
        case "PendingMapChangeValetudoEvent": return "map.fill"
        case "ErrorStateValetudoEvent", "ValetudoRuntimeErrorValetudoEvent": return "exclamationmark.triangle.fill"
        case "ValetudoUpdatedValetudoEvent": return "arrow.down.circle.fill"
        default: return "bell.fill"
        }
    }

    private static func color(for event: RobotEvent) -> Color {
        switch event.kind {
        case "ErrorStateValetudoEvent", "ValetudoRuntimeErrorValetudoEvent": return .red
        case "PendingMapChangeValetudoEvent", "ValetudoUpdatedValetudoEvent": return .blue
        case "MopAttachmentReminderValetudoEvent": return .cyan
        default: return .orange
        }
    }
}

/// One short fact from the robot or its dock.
private struct Reading: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbol: String
    let tone: Tone
}

/// Facts that are usually all fine, kept small so every control still fits on the screen.
private struct ReadingsCard: View {
    let readings: [Reading]
    let columnWidth: CGFloat

    private func needsAttention(_ reading: Reading) -> Bool { reading.tone == .warning || reading.tone == .critical }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 16)], alignment: .leading, spacing: 8) {
            ForEach(readings) { reading in
                HStack(spacing: 7) {
                    Image(systemName: reading.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(reading.tone == .neutral ? Theme.slate : reading.tone.color)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(reading.title)
                        .foregroundStyle(Theme.slate)
                    Spacer(minLength: 4)
                    Text(reading.value)
                        .fontWeight(.semibold)
                        .foregroundStyle(needsAttention(reading) ? reading.tone.color : Theme.ink)
                }
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
    }
}

/// Something the dock can do. Flatter than the mode tiles, which are the sheet's main choice.
private struct DockButton: View {
    let title: String
    let symbol: String
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.cobalt)
                } else {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Metric.hitTarget + 4)
            .opacity(isEnabled ? 1 : 0.4)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityValue(busy ? "Working" : "")
    }
}

/// A section title with what it's reporting beside it.
private struct ControlHeading: View {
    let title: String
    let value: String?
    var tone = Tone.neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            GroupTitle(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tone.color)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How an attachment reads, by the type the robot reports.
private struct Attachment {
    let type: String

    var title: String {
        switch type {
        case "dustbin": return "Dust Bin"
        case "watertank": return "Water Tank"
        case "mop": return "Mop"
        default: return "Attachment"
        }
    }

    var symbol: String {
        switch type {
        case "dustbin": return "trash.fill"
        case "watertank": return "drop.circle.fill"
        default: return "drop.fill"
        }
    }
}

/// Each mode drawn from the same two parts, so the picture says what the name says:
/// air for vacuuming, a drop for mopping, joined by a plus or an arrow.
struct ModeIcon: View {
    let mode: String

    private static let vacuum = "wind"
    private static let mop = "drop.fill"

    var body: some View {
        switch mode {
        case "vacuum": Image(systemName: Self.vacuum)
        case "mop": Image(systemName: Self.mop)
        case "vacuum_and_mop": pair(joinedBy: "plus")
        case "vacuum_then_mop": pair(joinedBy: "arrow.right")
        default: Image(systemName: "circle.grid.2x2.fill")
        }
    }

    private func pair(joinedBy joiner: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: Self.vacuum).font(.system(size: 13, weight: .semibold))
            Image(systemName: joiner).font(.system(size: 7, weight: .black))
            Image(systemName: Self.mop).font(.system(size: 12, weight: .semibold))
        }
    }
}
