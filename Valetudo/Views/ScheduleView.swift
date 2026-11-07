import SwiftUI

struct ScheduleView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: RoutineDraft?
    @State private var confirmRun: Routine?
    @State private var confirmDelete: Routine?
    @State private var read = ReadCheck.checking
    @State private var showLogin = false

    private enum ReadCheck { case checking, fine, failed }
    private enum Phase { case loading, failed, ready }

    private var phase: Phase {
        if !store.routines.isEmpty { return .ready }
        if !store.hasLoaded { return .loading }
        switch read {
        case .checking: return .loading
        case .failed: return .failed
        case .fine: return .ready
        }
    }

    /// The store sorts by the robot's UTC clock. People read these in local time.
    private var routines: [Routine] {
        store.routines.sorted {
            let a = $0.local, b = $1.local
            return (a.hour, a.minute, $0.id) < (b.hour, b.minute, $1.id)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading routines")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    failure
                case .ready:
                    list
                }
            }
            .background(Theme.mist)
            .navigationTitle("Schedule")
            .toolbar {
                // With no routines, the empty state's button is the one way in.
                if !store.routines.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editing = RoutineDraft() } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add Routine")
                    }
                }
            }
            .task(id: [store.hasLoaded, store.connected, store.routines.isEmpty, store.capabilities.isEmpty]) { await checkRead() }
            // Nothing polls these, and they can change on the robot's web page.
            .task {
                await store.loadSchedule()
                await store.loadRooms()
            }
            .sheet(item: $editing) { RoutineEditor(draft: $0) }
            .sheet(isPresented: $showLogin) { SignInSheet() }
        }
    }

    // MARK: States

    private var failure: some View {
        ContentUnavailableView {
            Label("Can't Load Routines", systemImage: store.readSymbol)
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Routines", systemImage: "calendar.badge.clock")
        } description: {
            Text("Add a routine and the robot will clean on its own, even when this app is closed.")
        } actions: {
            Button { editing = RoutineDraft() } label: {
                Text("Add Routine").foregroundStyle(Theme.onCobalt)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .frame(minHeight: 320)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// The store keeps quiet when a read fails, and an empty list looks just like having no
    /// routines. Asking once more tells them apart, so "No Routines" is never a guess.
    private func checkRead() async {
        guard store.hasLoaded else { return }
        guard store.routines.isEmpty else {
            read = .fine
            return
        }
        guard !store.capabilities.isEmpty, store.connected else {
            read = .failed
            return
        }
        guard let found = await readRoutines() else {
            if !Task.isCancelled { read = .failed }
            return
        }
        // Routines aren't polled, so if only the store's read failed, nothing else would fetch them.
        if !found.isEmpty { await store.loadSchedule() }
        if !Task.isCancelled { read = found.isEmpty || !store.routines.isEmpty ? .fine : .failed }
    }

    private func readRoutines() async -> [String: Routine]? {
        try? await store.client.get("/timers", as: [String: Routine].self)
    }

    private func retry() async {
        read = .checking
        // With no capabilities the first connection failed, so nothing else can load yet.
        if store.capabilities.isEmpty {
            await store.loadEverything()
        } else {
            await store.loadSchedule()
        }
        await checkRead()
        if read == .failed {
            store.notify(store.reachable ? "These routines still didn't arrive" : "Still can't reach the robot",
                         symbol: "exclamationmark.triangle.fill", seconds: 4.5, isProblem: true)
        }
    }

    /// The store keeps the old list when a read fails, so a refresh has to say when that happened.
    private func refresh() async {
        await store.loadSchedule()
        await store.loadRooms()
        await checkRead()
        guard !store.routines.isEmpty else { return }
        let succeeded = await readRoutines() != nil
        if !succeeded, !Task.isCancelled {
            store.notify("Couldn't refresh. These routines may be out of date.",
                         symbol: "exclamationmark.triangle.fill", seconds: 4.5, isProblem: true)
        }
    }

    // MARK: Content

    private var list: some View {
        List {
            if !store.connected {
                Section {
                    Banner(text: store.needsLogin ? "The robot's login has changed. Changes won't save until you sign in again."
                                                  : "Can't reach the robot. Changes may not save.",
                           action: store.needsLogin ? { showLogin = true } : nil)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if NextClean.find(in: store.routines, after: .now) != nil {
                Section {
                    TimelineView(.everyMinute) { context in
                        if let next = NextClean.find(in: store.routines, after: context.date) {
                            NextCleanRow(next: next, now: context.date, rooms: store.rooms)
                        }
                    }
                }
            }

            if store.routines.isEmpty {
                Section { emptyState }
            } else {
                Section {
                    ForEach(routines) { routineRow($0) }
                } header: {
                    Text("Routines")
                } footer: {
                    Text(RobotClock.routineNote)
                }
            }

            if let hours = store.quietHours {
                QuietHoursSection(hours: hours) { store.save($0) }
            } else if store.has(Cap.quietHours), store.hasLoaded {
                QuietHoursFailedSection { await store.loadSchedule() }
            }
        }
        .themedList()
        .refreshable { await refresh() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.routines)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.quietHours)
        .modifier(RoutineDialogs(run: $confirmRun, delete: $confirmDelete))
    }

    /// Opens the robot's own copy, because saving replaces what's there with what's in the
    /// form, and the list here can be older than a change made on the web page.
    private func edit(_ routine: Routine) {
        guard store.connected else {
            editing = RoutineDraft(routine)
            return
        }
        Task {
            if let latest = try? await store.client.get("/timers/\(routine.id)", as: Routine.self) {
                editing = RoutineDraft(latest)
                return
            }
            // It may have been deleted elsewhere. If so, this takes the row away instead.
            await store.loadSchedule()
            if store.routines.contains(where: { $0.id == routine.id }) { editing = RoutineDraft(routine) }
        }
    }

    private func routineRow(_ routine: Routine) -> some View {
        RoutineRow(routine: routine, rooms: store.rooms,
                   onEdit: { edit(routine) },
                   onToggle: { store.setEnabled(routine, $0) })
            // No full swipe on either edge: one would start the robot, the other can't be undone.
            // System colours, because swipe labels are white and Theme's dark-mode tints are light.
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { confirmRun = routine } label: { Label("Run Now", systemImage: "play.fill") }
                    .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Not a destructive role, which would slide the row away before the dialog is answered.
                Button { confirmDelete = routine } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
            .contextMenu {
                Button { confirmRun = routine } label: { Label("Run Now", systemImage: "play.fill") }
                Button { edit(routine) } label: { Label("Edit", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { confirmDelete = routine } label: { Label("Delete", systemImage: "trash") }
            }
    }
}

/// The two actions that can't be taken back. Every way of reaching them asks here first.
private struct RoutineDialogs: ViewModifier {
    @Environment(RobotStore.self) private var store
    @Binding var run: Routine?
    @Binding var delete: Routine?
    var onConfirm: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Run this routine now?", isPresented: isShowing($run),
                                titleVisibility: .visible, presenting: run) { routine in
                if routine.canRun {
                    Button("Run Now") {
                        store.runNow(routine)
                        onConfirm()
                    }
                }
            } message: { routine in
                Text(routine.runNotice(rooms: store.rooms))
            }
            .confirmationDialog("Delete this routine?", isPresented: isShowing($delete),
                                titleVisibility: .visible, presenting: delete) { routine in
                Button("Delete Routine", role: .destructive) {
                    store.delete(routine)
                    onConfirm()
                }
            } message: { routine in
                Text("\(routine.reference) is removed from the robot. This can't be undone.")
            }
    }

    private func isShowing(_ item: Binding<Routine?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

// MARK: - Reading routines

private extension Routine {
    var local: (days: [Int], hour: Int, minute: Int) {
        RobotTime.toLocal(days: dow, hour: hour, minute: minute)
    }

    var name: String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }

    var date: Date {
        let parts = local
        return RoutineDraft.date(hour: parts.hour, minute: parts.minute)
    }

    var time: String { date.formatted(date: .omitted, time: .shortened) }

    /// How a sentence names this routine, which may not have a name of its own.
    var reference: String { name.map { "“\($0)”" } ?? "The \(time) routine" }

    /// Valetudo skips any other action without an error, so running one would look like it worked.
    var canRun: Bool { ["full_cleanup", "segment_cleanup"].contains(action.type) }

    func area(rooms: [RoomRef]) -> String {
        switch action.type {
        case "full_cleanup": return "Whole Home"
        case "segment_cleanup": return RoomNames.text(ids: action.params.segment_ids ?? [], rooms: rooms)
        default: return "Action Not Available"
        }
    }

    func runNotice(rooms: [RoomRef]) -> String {
        switch action.type {
        case "full_cleanup": return "\(reference) starts right away and the robot cleans your whole home."
        case "segment_cleanup": return "\(reference) starts right away and the robot cleans \(area(rooms: rooms))."
        default: return "\(reference) has an action that no longer exists, so the robot won't do anything."
        }
    }

    /// What this routine sets before it starts, in the order the editor shows them.
    var settings: [String] {
        PresetKind.allCases.compactMap { kind in
            guard let value = pre_actions?.first(where: { $0.type == kind.preAction })?.params.value else { return nil }
            let label = PresetKind.label(value)
            return kind == .mode ? label : "\(kind.title) \(label)"
        }
    }
}

private enum RoomNames {
    static func text(ids: [String], rooms: [RoomRef]) -> String {
        guard !ids.isEmpty else { return "No Rooms" }
        return ids.map { id in rooms.first { $0.id == id }?.title ?? "Room \(id)" }.joined(separator: ", ")
    }
}

/// Days use the robot's numbering, where 0 is Sunday, which is also the order of Calendar's symbols.
private enum Weekdays {
    /// All seven, starting from the first day of the week where this person lives.
    static var ordered: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { ($0 + first) % 7 }
    }

    static func summary(_ days: Set<Int>) -> String {
        switch days {
        case []: return "No Days"
        case Set(0...6): return "Every Day"
        case Set(1...5): return "Weekdays"
        case [0, 6]: return "Weekends"
        default: break
        }
        if days.count == 1, let day = days.first { return Calendar.current.weekdaySymbols[day] }
        return ordered.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0] }.joined(separator: ", ")
    }
}

/// When the robot will next clean by itself.
private struct NextClean {
    let date: Date
    let routine: Routine

    /// Worked out in UTC, as the robot does, or it would be an hour out across a clock change.
    static func find(in routines: [Routine], after now: Date) -> NextClean? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return routines.filter { $0.enabled && $0.canRun }
            .flatMap { routine in
                routine.dow.compactMap { day -> NextClean? in
                    let match = DateComponents(hour: routine.hour, minute: routine.minute, weekday: day + 1)
                    return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
                        .map { NextClean(date: $0, routine: routine) }
                }
            }
            .min { $0.date < $1.date }
    }

    func phrase(now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
    }
}

/// The robot runs on UTC and ignores daylight saving, which matters whenever a time is set.
private enum RobotClock {
    static var clocksChangeHere: Bool { TimeZone.current.nextDaylightSavingTimeTransition != nil }

    static var zoneName: String {
        TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier
    }

    static func text(hour: Int, minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    static var routineNote: String {
        let needsTime = "Routines only run while the robot knows the correct time."
        guard clocksChangeHere else { return needsTime }
        return "The robot keeps these times in UTC, a world clock with no daylight saving. After the clocks change, "
            + "a routine runs an hour earlier or later until you set its time again. \(needsTime)"
    }
}

// MARK: - Rows

private struct NextCleanRow: View {
    let next: NextClean
    let now: Date
    let rooms: [RoomRef]
    @ScaledMetric(relativeTo: .title2) private var disc: CGFloat = 46

    private var detail: String {
        [next.routine.name, next.routine.area(rooms: rooms)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .symbolRenderingMode(.hierarchical)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
                .frame(width: disc, height: disc)
                .background(Theme.cobalt.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next Clean")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
                Text(next.phrase(now: now))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(detail)
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

private struct RoutineRow: View {
    let routine: Routine
    let rooms: [RoomRef]
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 44

    /// Clock's look: AM and PM sit small beside the digits. 24-hour locales have neither.
    private var time: AttributedString {
        var text = routine.date.formatted(.dateTime.hour().minute().attributed)
        for run in text.runs where run.dateField == .amPM {
            text[run.range].font = .system(size: timeSize * 0.5, weight: .light)
        }
        return text
    }

    private var detail: String {
        ([Weekdays.summary(Set(routine.local.days)), routine.area(rooms: rooms)] + routine.settings)
            .joined(separator: " · ")
    }

    private var toggleLabel: String {
        routine.name.map { "\($0), \(routine.time)" } ?? "Routine at \(routine.time)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(time)
                        .font(.system(size: timeSize, weight: .light))
                        .foregroundStyle(routine.enabled ? Theme.ink : Theme.slate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let name = routine.name {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(routine.enabled ? Theme.ink : Theme.slate)
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits this routine")

            Toggle(toggleLabel, isOn: Binding(get: { routine.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
    }
}

// MARK: - Quiet hours

private struct QuietHoursTitle: View {
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "moon.fill", color: .indigo)
            Text("Quiet Hours")
        }
    }
}

private struct QuietHoursSection: View {
    let hours: QuietHours
    let onChange: (QuietHours) -> Void
    /// Holds what the wheels show until they settle, so one spin is one write to the robot.
    @State private var settling: QuietHours?
    @State private var pendingWrite: Task<Void, Never>?

    private var shown: QuietHours { settling ?? hours }

    private func clock(_ time: QuietHours.Clock) -> Date {
        let local = RobotTime.toLocal(days: [0], hour: time.hour, minute: time.minute)
        return RoutineDraft.date(hour: local.hour, minute: local.minute)
    }

    private func robotClock(_ date: Date) -> QuietHours.Clock {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let utc = RobotTime.toRobot(days: [0], hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        return .init(hour: utc.hour, minute: utc.minute)
    }

    private var note: String {
        let effect = "What changes depends on your robot. It usually won't resume an interrupted clean "
            + "until these hours end, and the dock may stay quiet."
        guard shown.enabled else { return effect }
        let start = RobotClock.text(hour: shown.start.hour, minute: shown.start.minute)
        let end = RobotClock.text(hour: shown.end.hour, minute: shown.end.minute)
        let stored = "The robot stores these hours as \(start) – \(end) UTC"
        return "\(effect) \(stored)" + (RobotClock.clocksChangeHere ? ", so they shift by an hour when the clocks change." : ".")
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { shown.enabled }, set: {
                var next = shown
                next.enabled = $0
                write(next)
            })) {
                QuietHoursTitle()
            }
            if shown.enabled {
                DatePicker("From", selection: Binding(get: { clock(shown.start) }, set: {
                    var next = shown
                    next.start = robotClock($0)
                    settle(next)
                }), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: Binding(get: { clock(shown.end) }, set: {
                    var next = shown
                    next.end = robotClock($0)
                    settle(next)
                }), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text(note)
        }
    }

    private func settle(_ next: QuietHours) {
        settling = next
        pendingWrite?.cancel()
        // Not tied to this view's lifetime, so leaving the tab mid-spin still saves the choice.
        pendingWrite = Task {
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { write(next) }
        }
    }

    private func write(_ next: QuietHours) {
        pendingWrite?.cancel()
        onChange(next)
        settling = nil
    }
}

/// Stands in when the setting couldn't be read, so no made-up times can be saved over the real ones.
private struct QuietHoursFailedSection: View {
    let retry: () async -> Void
    @State private var retrying = false

    var body: some View {
        Section {
            HStack {
                QuietHoursTitle()
                Spacer(minLength: 8)
                if retrying {
                    ProgressView()
                } else {
                    Button("Try Again") {
                        Task {
                            retrying = true
                            await retry()
                            retrying = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Try Loading Quiet Hours Again")
                }
            }
        } footer: {
            Text("Couldn't read quiet hours from the robot.")
        }
    }
}

// MARK: - Editing

/// A routine in local time while it's being edited.
struct RoutineDraft: Identifiable, Equatable {
    let id: String
    let isNew: Bool
    var enabled = true
    var label = ""
    var days: Set<Int> = Set(0...6)
    var time = RoutineDraft.date(hour: 9, minute: 0)
    var wholeHome = true
    /// In cleaning order. Older robots follow this order even with `customOrder` off.
    var rooms: [String] = []
    var customOrder = false
    var passes = 1
    var presets: [PresetKind: String] = [:]
    private(set) var hasUnknownAction = false
    private var otherPreActions: [Routine.PreAction] = []

    init() {
        id = UUID().uuidString
        isNew = true
    }

    init(_ routine: Routine) {
        id = routine.id
        isNew = false
        enabled = routine.enabled
        label = routine.label ?? ""
        let local = RobotTime.toLocal(days: routine.dow, hour: routine.hour, minute: routine.minute)
        days = Set(local.days)
        time = Self.date(hour: local.hour, minute: local.minute)
        wholeHome = routine.action.type != "segment_cleanup"
        hasUnknownAction = !routine.canRun
        rooms = routine.action.params.segment_ids ?? []
        passes = routine.action.params.iterations ?? 1
        customOrder = routine.action.params.custom_order ?? false
        for action in routine.pre_actions ?? [] {
            if let kind = PresetKind.allCases.first(where: { $0.preAction == action.type }) {
                presets[kind] = action.params.value
            } else {
                otherPreActions.append(action)
            }
        }
    }

    static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    static let maxLabelLength = 24

    /// Valetudo counts UTF-16 units, so counting characters would let it cut an emoji in half.
    static func clipped(_ label: String) -> String {
        var length = 0
        return String(label.prefix { character in
            length += character.utf16.count
            return length <= maxLabelLength
        })
    }

    var canSave: Bool { !days.isEmpty && (wholeHome || !rooms.isEmpty) }

    mutating func toggle(room id: String) {
        if rooms.contains(id) {
            rooms.removeAll { $0 == id }
        } else {
            rooms.append(id)
        }
    }

    func routine() -> Routine {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let utc = RobotTime.toRobot(days: Array(days), hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        let params = wholeHome
            ? Routine.Params()
            : Routine.Params(segment_ids: rooms, iterations: passes, custom_order: customOrder)
        let trimmed = Self.clipped(label.trimmingCharacters(in: .whitespaces))
        // A fixed order, so the robot applies these the same way every time.
        let chosen = PresetKind.allCases.compactMap { kind in
            presets[kind].map { Routine.PreAction(type: kind.preAction, params: .init(value: $0)) }
        }
        return Routine(
            id: id, enabled: enabled, label: trimmed.isEmpty ? nil : trimmed,
            dow: utc.days, hour: utc.hour, minute: utc.minute,
            action: .init(type: wholeHome ? "full_cleanup" : "segment_cleanup", params: params),
            pre_actions: otherPreActions + chosen)
    }
}

/// The reason Save is off, shown right beside the control that fixes it.
private struct SaveBlocker: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: Tone.warning.symbol)
            .foregroundStyle(Tone.warning.color)
    }
}

private struct DayPicker: View {
    @Binding var days: Set<Int>
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: typeSize.isAccessibilitySize ? 4 : 7)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Weekdays.ordered, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Theme.onCobalt : Theme.slate)
                        .frame(maxWidth: .infinity, minHeight: Metric.hitTarget)
                        .background {
                            Circle()
                                .fill(on ? Theme.cobalt : Theme.track)
                                .padding(2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: days)
    }
}

/// Numbers a picked room when the order is the owner's to set.
private struct OrderBadge: View {
    let place: Int
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 24

    var body: some View {
        Text(place.formatted())
            .font(.footnote.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Theme.onCobalt)
            .padding(.horizontal, 4)
            .frame(minWidth: size, minHeight: size)
            .background(Theme.cobalt, in: Capsule())
            .accessibilityHidden(true)
    }
}

private struct RoutineEditor: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: RoutineDraft
    @State private var saving = false
    @State private var orderSupported = false
    @State private var confirmRun: Routine?
    @State private var confirmDelete: Routine?
    @State private var confirmDiscard = false
    /// Tiles widen with the text size, so the grid drops a column instead of breaking words.
    @ScaledMetric(relativeTo: .footnote) private var modeTileWidth: CGFloat = 76
    private let original: RoutineDraft

    private struct RoomProperties: Decodable { let customOrderSupport: Bool? }

    /// Valetudo's own order, because robots list their levels however they like.
    private static let levels = ["off", "min", "low", "medium", "high", "max", "turbo"]

    init(draft: RoutineDraft) {
        _draft = State(initialValue: draft)
        original = draft
    }

    private var hasChanges: Bool { draft != original }

    /// The stored flag alone isn't enough: numbers mean nothing on a robot that can't follow them.
    private var showsOrder: Bool { orderSupported && draft.customOrder }

    /// The routine as the robot has it. Run Now runs this, not what's on screen.
    private var saved: Routine? { store.routines.first { $0.id == draft.id } }

    private var supportsRooms: Bool {
        !store.rooms.isEmpty && (store.scheduleProperties?.supportedActions?.contains("segment_cleanup") ?? false)
    }

    /// Picked rooms the floor plan no longer has.
    private var missingRooms: [String] {
        let known = Set(store.rooms.map(\.id))
        return draft.rooms.filter { !known.contains($0) }
    }

    private var presetKinds: [PresetKind] {
        PresetKind.allCases.filter {
            (store.scheduleProperties?.supportedPreActions ?? []).contains($0.preAction) && !(store.presets[$0] ?? []).isEmpty
        }
    }

    /// Mopping alone has no suction and vacuuming alone has no water, as in Controls.
    /// A value already set stays visible, so nothing the routine does is hidden.
    private func applies(_ kind: PresetKind) -> Bool {
        if draft.presets[kind] != nil { return true }
        switch (kind, draft.presets[.mode]) {
        case (.fan, "mop"), (.water, "vacuum"): return false
        default: return true
        }
    }

    private var levelKinds: [PresetKind] { presetKinds.filter { $0 != .mode && applies($0) } }

    /// What a routine can pick. Valetudo leaves out `custom`, which is only ever a robot's own
    /// state. A value this robot no longer lists stays, so opening a routine never blanks it.
    private func choices(for kind: PresetKind) -> [String] {
        let offered = (store.presets[kind] ?? []).filter { $0 != "custom" }
        var list = kind == .mode ? PresetKind.ordered(offered) : Self.byLevel(offered)
        if let stored = draft.presets[kind], !list.contains(stored) { list.append(stored) }
        return list
    }

    private static func byLevel(_ names: [String]) -> [String] {
        func rank(_ name: String) -> Int { levels.firstIndex(of: name) ?? levels.count }
        return names.sorted { rank($0) < rank($1) }
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle(draft.isNew ? "New Routine" : "Edit Routine")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .modifier(ToastHost(toast: store.toast))
                .modifier(RoutineDialogs(run: $confirmRun, delete: $confirmDelete, onConfirm: { dismiss() }))
                .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                }
                .task { await loadRoomDetails() }
        }
        // A stray swipe shouldn't throw away changes, or lose sight of a save that's under way.
        .interactiveDismissDisabled(hasChanges || saving)
    }

    private var form: some View {
        Form {
            timeSection
            nameSection
            daySection
            if draft.hasUnknownAction { unknownActionNotice }
            areaSection
            modeSection
            levelSection
            actionSections
        }
        .themedList()
        .scrollDismissesKeyboard(.interactively)
        .disabled(saving)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: draft.wholeHome)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: draft.presets[.mode])
        .sensoryFeedback(.selection, trigger: draft.rooms)
        .sensoryFeedback(.selection, trigger: draft.presets)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if hasChanges { confirmDiscard = true } else { dismiss() }
            }
            .disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if saving {
                ProgressView().accessibilityLabel("Saving")
            } else {
                Button("Save", action: save).disabled(!draft.canSave)
            }
        }
    }

    // MARK: Saving

    private func save() {
        saving = true
        Task {
            let accepted = await send(draft.routine())
            saving = false
            if accepted { dismiss() }
        }
    }

    /// Waits for the robot's answer, so a refused save leaves the form open with everything in it.
    private func send(_ routine: Routine) async -> Bool {
        let client = store.client
        do {
            if draft.isNew {
                try await client.send("POST", "/timers", encoding: routine)
            } else {
                try await client.send("PUT", "/timers/\(routine.id)", encoding: routine)
            }
        } catch is CancellationError {
            return false
        } catch {
            store.report(error)
            return false
        }
        await store.loadSchedule()
        store.notify(draft.isNew ? "Routine added" : "Routine saved")
        return true
    }

    /// The store's room list can be older than the floor plan, and a room added since
    /// shouldn't be called missing.
    private func loadRoomDetails() async {
        guard store.has(Cap.rooms) else { return }
        await store.loadRooms()
        let properties = try? await store.client.get("\(Cap.root)/\(Cap.rooms)/properties", as: RoomProperties.self)
        orderSupported = properties?.customOrderSupport ?? false
    }

    // MARK: Sections

    private var timeSection: some View {
        Section {
            DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } footer: {
            let robot = draft.routine()
            Text("\(RobotClock.zoneName). The robot stores this as \(RobotClock.text(hour: robot.hour, minute: robot.minute)) UTC.")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Name (Optional)", text: $draft.label)
                .submitLabel(.done)
                .onChange(of: draft.label) { _, new in
                    let clipped = RoutineDraft.clipped(new)
                    if clipped != new { draft.label = clipped }
                }
            Toggle("Enabled", isOn: $draft.enabled)
        }
    }

    private var daySection: some View {
        Section {
            DayPicker(days: $draft.days)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text("Days")
        } footer: {
            if draft.days.isEmpty {
                SaveBlocker("Choose at least one day.")
            } else {
                Text(Weekdays.summary(draft.days))
            }
        }
    }

    private var unknownActionNotice: some View {
        Section {
            Banner(text: "This routine's action no longer exists, so the robot skips it. Saving turns it into a normal clean.")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var areaSection: some View {
        if supportsRooms {
            Section {
                Picker("Area", selection: $draft.wholeHome) {
                    Text("Whole Home").tag(true)
                    Text("Rooms").tag(false)
                }
                .pickerStyle(.segmented)
                if !draft.wholeHome {
                    ForEach(store.rooms) { room in roomRow(room) }
                    ForEach(missingRooms, id: \.self) { id in missingRoomRow(id) }
                    if store.maxRoomPasses > 1 {
                        Stepper(value: $draft.passes, in: 1...store.maxRoomPasses) {
                            Text(draft.passes == 1 ? "1 Pass" : "\(draft.passes) Passes")
                                .contentTransition(.numericText())
                        }
                    }
                    if orderSupported {
                        Toggle("Use Custom Order", isOn: $draft.customOrder)
                    }
                }
            } header: {
                Text("What to Clean")
            } footer: {
                if !draft.wholeHome {
                    if draft.rooms.isEmpty {
                        SaveBlocker("Choose at least one room.")
                    } else if showsOrder {
                        Text("Tap rooms in the order you want them cleaned.")
                    }
                }
            }
        } else if !draft.wholeHome {
            // The room list didn't load, but this routine still has rooms worth keeping.
            Section {
                LabeledContent("Rooms", value: RoomNames.text(ids: draft.rooms, rooms: store.rooms))
            } header: {
                Text("What to Clean")
            } footer: {
                if draft.rooms.isEmpty {
                    SaveBlocker("This routine has no rooms, and the robot's room list isn't available.")
                } else {
                    Text("These rooms stay as they are. The robot's room list isn't available right now.")
                }
            }
        }
    }

    private func position(of id: String) -> Int? {
        draft.rooms.firstIndex(of: id).map { $0 + 1 }
    }

    private func roomRow(_ room: RoomRef) -> some View {
        let place = position(of: room.id)
        return Button {
            draft.toggle(room: room.id)
        } label: {
            HStack {
                Text(room.title).foregroundStyle(Theme.ink)
                Spacer()
                if let place, showsOrder {
                    OrderBadge(place: place)
                } else if place != nil {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.cobalt)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(place != nil ? .isSelected : [])
        .accessibilityValue(showsOrder ? place.map { "Number \($0) in the order" } ?? "" : "")
    }

    /// There's nothing to tick for a room that's gone, so it gets a way out of its own.
    private func missingRoomRow(_ id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Room \(id)").foregroundStyle(Theme.ink)
                Text("No longer on the floor plan")
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let place = position(of: id), showsOrder {
                OrderBadge(place: place)
            }
            Button("Remove") { draft.toggle(room: id) }
                .buttonStyle(.borderless)
                .tint(Theme.rose)
                .accessibilityLabel("Remove Room \(id)")
        }
    }

    private var presetNote: Text {
        Text("Current Setting uses whatever the robot is set to when the routine starts.")
    }

    /// The same tiles and pictures as Controls, so a mode looks the same wherever it's chosen.
    /// Current Setting goes last: four tiles fit a row, and a fifth in front would split the modes.
    @ViewBuilder private var modeSection: some View {
        if presetKinds.contains(.mode) {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: modeTileWidth), spacing: 10)], spacing: 10) {
                    ForEach(choices(for: .mode), id: \.self) { mode in
                        ActionTile(title: PresetKind.label(mode), selected: draft.presets[.mode] == mode,
                                   action: { draft.presets[.mode] = mode }) {
                            ModeIcon(mode: mode)
                        }
                    }
                    ActionTile(title: "Current Setting", selected: draft.presets[.mode] == nil,
                               action: { draft.presets[.mode] = nil }) {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Mode")
            } footer: {
                if levelKinds.isEmpty { presetNote }
            }
        }
    }

    @ViewBuilder private var levelSection: some View {
        if !levelKinds.isEmpty {
            Section {
                ForEach(levelKinds) { kind in
                    Picker(kind.title, selection: Binding(get: { draft.presets[kind] }, set: { draft.presets[kind] = $0 })) {
                        Text("Current Setting").tag(String?.none)
                        ForEach(choices(for: kind), id: \.self) { Text(PresetKind.label($0)).tag(String?.some($0)) }
                    }
                }
            } header: {
                Text("Settings for This Routine")
            } footer: {
                presetNote
            }
        }
    }

    @ViewBuilder private var actionSections: some View {
        if !draft.isNew, let saved {
            Section {
                Button { confirmRun = saved } label: { Label("Run Now", systemImage: "play.fill") }
                    .disabled(hasChanges)
            } footer: {
                if hasChanges {
                    Text("Save your changes first. Run Now uses the routine as it's saved on the robot.")
                }
            }
            Section {
                Button("Delete Routine", role: .destructive) { confirmDelete = saved }
            }
        }
    }
}
