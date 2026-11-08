import Foundation
import Observation

/// Everything the app knows about the connected robot.
@MainActor @Observable
final class RobotStore {
    let client: Client

    private(set) var toast: Toast?
    private var toastTask: Task<Void, Never>?

    private(set) var reachable = true
    /// A load has finished, even a failed one, so screens can say what's missing. It goes back
    /// to false for a fresh start, because screens treat false as loading.
    private(set) var hasLoaded = false
    private(set) var info: RobotInfo?
    private(set) var version: String?
    private(set) var capabilities: Set<String> = []
    private(set) var state = RobotState()
    private(set) var plan: FloorPlan?
    /// The last fetch of the map failed, which isn't the same as there being no map.
    private(set) var mapLoadFailed = false
    /// The robot turned this phone away, so its login has changed since this phone saved it.
    private(set) var needsLogin = false
    /// Counts every new map. An obstacle getting a name doesn't change the map, so it isn't one.
    private(set) var planRevision = 0
    private(set) var presets: [PresetKind: [String]] = [:]
    private(set) var rooms: [RoomRef] = []
    private(set) var routines: [Routine] = []
    private(set) var scheduleProperties: ScheduleProperties?
    private(set) var quietHours: QuietHours?
    private(set) var consumables: [Consumable] = []
    private(set) var switches: [RobotSwitch: Bool] = [:]
    private(set) var volume: Double?
    private(set) var currentRun = RunStatistics()
    private(set) var total: [String: Double] = [:]
    private(set) var events: [RobotEvent] = []
    private(set) var maxRoomPasses = 1
    private(set) var roomOrderSupported = false
    private(set) var maxZonePasses = 1
    private(set) var maxZones = 1
    private(set) var friendlyName = ""
    private(set) var choices: [ChoiceSetting: (value: String, options: [String])] = [:]
    private(set) var cameraInstalled = false
    private(set) var cameraEnabled = false
    private(set) var cameraInstallPath: String?
    private(set) var pendingMap = false
    private var consumableMax: [String: Double] = [:]
    private var build: VersionInfo?
    private let spotter: ObstacleSpotter

    /// The full load under way. Anyone else who wants one waits for this one.
    private var fullLoad: Task<Void, Never>?
    /// The last one didn't get through everything, or the robot has changed since.
    private var needsFullLoad = true
    /// The robot stopped answering partway through a full load, so the rest is being skipped.
    private var loadStalled = false
    /// The polls have ended, so the app has moved on and nothing should start a load by itself.
    private var stopped = false
    /// Routes only an update can change, once they've answered. A full load reads them again.
    private var answeredOnce: Set<String> = []

    /// Changes on screen that the robot hasn't finished answering.
    private var changes: [Field: Change] = [:]
    /// Moves on as changes start and end, so a read can tell whether one overlapped it.
    private var changeClock = 0
    private var lastChange: [Field: Int] = [:]

    /// Status reads are numbered as they start, because every command ends with one, and it can
    /// pass a poll on the way back. An older one can't replace a newer one.
    private var stateReads = 0
    private var shownStateRead = 0
    /// The newest run of `loadDetails`. An older one still reading has nothing newer to show.
    private var detailReads = 0

    /// Map reads are numbered the same way.
    private var mapGeneration = 0
    private var shownGeneration = 0
    private var shownMap: RawMap?
    /// When Valetudo's placeholder first came back over a real plan, and how long to ignore it.
    private var placeholderSince: ContinuousClock.Instant?
    private let restartGrace: Duration

    init(client: Client, spotter: ObstacleSpotter? = nil, restartGrace: Duration = .seconds(120)) {
        self.client = client
        self.spotter = spotter ?? ObstacleSpotter()
        self.restartGrace = restartGrace
    }

    var displayName: String {
        let name = friendlyName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Your robot" : name
    }

    /// Answering, and letting this phone in. `reachable` alone stays true behind a refused login.
    var connected: Bool { reachable && !needsLogin }

    nonisolated static let loginAdvice = "The robot's login has changed. Sign in again to keep using it."

    /// Why a screen has nothing to show, once a read has come back empty-handed.
    var readAdvice: String {
        if needsLogin { return Self.loginAdvice }
        return reachable ? "The robot is answering, but this didn't arrive." : "Check that the robot is on and on the same network as this phone."
    }

    var readSymbol: String {
        if needsLogin { return "person.crop.circle.badge.exclamationmark" }
        return reachable ? "exclamationmark.triangle" : "wifi.exclamationmark"
    }

    /// For a screen still showing what it read earlier.
    var staleAdvice: String {
        if needsLogin { return "The robot's login has changed, so this may be out of date." }
        return reachable ? "The robot didn't send this just now, so it may be out of date." : "Can't reach the robot, so this may be out of date."
    }

    var openEvents: [RobotEvent] { events.filter { !$0.processed } }

    func has(_ capability: String) -> Bool { capabilities.contains(capability) }

    func selected(_ kind: PresetKind) -> String? { state[kind] }

    /// How much life is left, from 0 to 1, when the robot reports a maximum.
    func life(of consumable: Consumable) -> Double? {
        if consumable.remaining.unit == "percent" { return consumable.remaining.value / 100 }
        guard let max = consumableMax[consumable.id], max > 0 else { return nil }
        return min(1, consumable.remaining.value / max)
    }

    /// Plain-language status, used as the headline on the Home tab.
    var sentence: String {
        let n = displayName
        if needsLogin { return "\(n) needs you to sign in" }
        if !reachable { return "\(n) is offline" }
        if state.isResumable, state.status == "docked" || state.status == "idle" {
            return "\(n) has a job to finish"
        }
        switch state.status {
        case "docked": return state.charging ? "\(n) is docked and charging" : "\(n) is docked"
        case "cleaning":
            switch state.flag {
            case "segment": return "\(n) is cleaning \(plan?.cleaningWhere ?? "rooms")"
            case "zone": return "\(n) is cleaning a zone"
            case "spot": return "\(n) is cleaning a spot"
            default: return "\(n) is cleaning"
            }
        case "moving":
            switch state.flag {
            case "mapping": return "\(n) is mapping your home"
            case "target": return "\(n) is on its way"
            default: return "\(n) is moving"
            }
        case "returning": return "\(n) is heading to the dock"
        case "paused": return "\(n) is paused"
        case "idle": return "\(n) is ready"
        case "manual_control": return "\(n) is under manual control"
        case "error": return "\(n) needs help"
        default: return "Connecting to \(n)"
        }
    }

    struct Notice: Identifiable, Equatable {
        var id: String { text }
        let text: String
        var tone: Tone = .warning
        var opensControls = false
        var opensLogin = false
    }

    /// Things that need attention, most serious first.
    var notices: [Notice] {
        if needsLogin {
            return [Notice(text: Self.loginAdvice, tone: .critical, opensLogin: true)]
        }
        if !reachable {
            return [Notice(text: "Can't reach the robot. Check that it's on and on the same network as this phone, and that Local Network is on for this app in Settings.",
                           tone: .critical)]
        }
        if state.status == "error" {
            return [Notice(text: state.errorMessage ?? "Check the robot for details.", tone: .critical)]
        }
        return dockNotices
    }

    /// What the dock needs. Home shows an error first, but these still stand behind it.
    var dockNotices: [Notice] {
        var list: [Notice] = []
        let parts = state.dockParts
        if parts["water_tank_clean"] == "empty" { list.append(Notice(text: "Refill the clean water tank", opensControls: true)) }
        if parts["water_tank_clean"] == "missing" { list.append(Notice(text: "The clean water tank is missing", opensControls: true)) }
        if parts["water_tank_dirty"] == "full" { list.append(Notice(text: "Empty the dirty water tank", opensControls: true)) }
        if parts["water_tank_dirty"] == "missing" { list.append(Notice(text: "The dirty water tank is missing", opensControls: true)) }
        if parts["dustbag"] == "full" { list.append(Notice(text: "Replace the dust bag", opensControls: true)) }
        if parts["dustbag"] == "missing" { list.append(Notice(text: "The dust bag is missing", opensControls: true)) }
        if parts["detergent"] == "empty" { list.append(Notice(text: "Refill the detergent", opensControls: true)) }
        return list
    }

    // MARK: Loading

    /// The first load runs beside the polls, so the status stays live however long it takes.
    func run() async {
        stopped = false
        startLoad()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followState() }
            group.addTask { await self.followMap() }
            group.addTask { await self.followDetails() }
            group.addTask { await self.followRun() }
        }
        // Disconnecting or signing in again ends the polls, and a load left running would go on
        // asking the robot for things nobody will see, under a login that may be gone.
        stopped = true
        fullLoad?.cancel()
    }

    func loadEverything() async {
        await startLoad().value
    }

    /// For Try Again buttons. With nothing to show yet, going back to loading shows the tap worked.
    func retry() async {
        if capabilities.isEmpty || plan == nil { showLoading() }
        await loadEverything()
    }

    /// For coming back to the foreground, since anything can have changed on the robot meanwhile.
    func refreshOnReturn() async {
        guard fullLoad == nil else { return }
        await loadState()
        guard connected else {
            needsFullLoad = true
            return
        }
        // Hearing from the robot can have started a full load, which covers everything below.
        guard fullLoad == nil else { return await loadEverything() }
        await loadSpecs()
        await loadName()
        await loadSettings()
        await loadRooms()
        await loadSchedule()
        await loadDetails()
        await loadRunStatistics()
    }

    @discardableResult
    private func startLoad() -> Task<Void, Never> {
        if let fullLoad { return fullLoad }
        let load = Task {
            await readEverything()
            fullLoad = nil
        }
        fullLoad = load
        return load
    }

    private func readEverything() async {
        needsFullLoad = false
        answeredOnce = []
        defer {
            if Task.isCancelled {
                needsFullLoad = true
            } else {
                hasLoaded = true
                // A plan that was never fetched mustn't read as a robot with no plan.
                if plan == nil { mapLoadFailed = true }
            }
            loadStalled = false
        }
        do {
            capabilities = Set(try await client.get(Cap.root, as: [String].self))
            forgetWhatWasRemoved()
            heardFromRobot()
        } catch {
            needsFullLoad = true
            await learn(from: error)
            return
        }
        await loadName()
        await loadState()
        await loadMap()
        await loadSpecs()
        await loadSettings()
        await loadRooms()
        await loadSchedule()
        await loadDetails()
        await loadRunStatistics()
    }

    /// An update can take a capability away, and rows are drawn from what's held here.
    private func forgetWhatWasRemoved() {
        presets = presets.filter { has($0.key.capability) }
        switches = switches.filter { has($0.key.rawValue) }
        choices = choices.filter { has($0.key.rawValue) }
        if !has(Cap.volume) { volume = nil }
    }

    /// For what the app can manage without, so a failure leaves the last good value in place.
    /// If Valetudo itself has gone quiet, a full load ends here: every read left would wait out
    /// its own timeout, and the load runs again once the robot is back. One slow firmware call
    /// isn't that, and stopping for it would stop every load at the same place.
    private func read<Value>(_ request: () async throws -> Value) async -> Value? {
        guard !loadStalled, !Task.isCancelled else { return nil }
        do {
            return try await request()
        } catch let error as APIError where error.noAnswer && fullLoad != nil {
            // The load can end during this wait, and then nothing would clear the flag.
            if await !client.isAnswering(), fullLoad != nil {
                loadStalled = true
                needsFullLoad = true
            }
            return nil
        } catch {
            return nil
        }
    }

    /// For anything the app changes ahead of the robot's answer. A read that overlaps a change
    /// to the same thing can carry the old value, so it's dropped: the change's own answer
    /// settles what shows. Reads of anything else aren't affected.
    private func readSetting<Value>(_ field: Field, _ request: () async throws -> Value) async -> Value? {
        let started = changeClock
        let value = await read(request)
        return wasChanged(field, since: started) ? nil : value
    }

    private func wasChanged(_ field: Field, since clock: Int) -> Bool {
        changes.keys.contains(where: field.covers) || lastChange.contains { field.covers($0.key) && $0.value > clock }
    }

    /// For what only an update changes. One that fails is tried again the next time round.
    private func readOnce<Value>(_ path: String, _ request: (String) async throws -> Value) async -> Value? {
        guard !answeredOnce.contains(path), let value = await read({ try await request(path) }) else { return nil }
        answeredOnce.insert(path)
        return value
    }

    /// Any answer means the robot is there. It's also what recovery waits for.
    private func heardFromRobot() {
        if !reachable, needsFullLoad, capabilities.isEmpty { showLoading() }
        reachable = true
        needsLogin = false
        if needsFullLoad, !stopped { startLoad() }
    }

    /// Only silence means the robot has gone. A refusal still came from it, and got past the
    /// login. A read that timed out can be a stalled firmware, and an answer that can't be read
    /// can be something else at this address, so for those two `/robot` decides.
    private func learn(from error: Error) async {
        switch error {
        case is CancellationError:
            break
        case let error as APIError where error.kind == .needsLogin:
            reachable = true
            needsLogin = true
        case let error as APIError where error.kind == .other:
            heardFromRobot()
        case is APIError:
            if reachable, await !client.isAnswering() { reachable = false }
        default:
            if await client.isAnswering() { heardFromRobot() } else { reachable = false }
        }
    }

    /// With nothing to show, a fresh start should read as loading, not as what's missing.
    private func showLoading() {
        hasLoaded = false
        mapLoadFailed = false
        reachable = true
    }

    private func loadState() async {
        stateReads += 1
        let number = stateReads
        let started = changeClock
        do {
            var next = RobotState(try await client.get("/robot/state/attributes", as: [Attribute].self))
            guard isNewestState(number) else { return }
            for kind in PresetKind.allCases where wasChanged(.preset(kind), since: started) {
                next[kind] = state[kind]
            }
            // A new job's figures replace the last one's at once, not at the next 10 s read.
            let jobStarted = !state.isActive && next.isActive
            state = next
            if next.isActive { jobSeenSinceRunRead = true }
            heardFromRobot()
            if jobStarted { Task { await loadRunStatistics() } }
        } catch {
            if isNewestState(number) { await learn(from: error) }
        }
    }

    private func isNewestState(_ number: Int) -> Bool {
        guard number > shownStateRead else { return false }
        shownStateRead = number
        return true
    }

    /// Most polls bring the same map again, and skipping those saves the rebuild and the redraw.
    /// `redraw` is for a refresh someone asked for, which always counts as a new map, and takes
    /// a placeholder at once.
    private func loadMap(redraw: Bool = false) async {
        mapGeneration += 1
        let generation = mapGeneration
        do {
            let raw = try await client.get("/robot/state/map", as: RawMap.self)
            guard generation > shownGeneration else { return }
            mapLoadFailed = false
            if !redraw, isWaitingForMap(raw) { return }
            if redraw || raw != shownMap {
                var next = await Task.detached { FloorPlan(raw) }.value
                // A poll can finish behind the refresh that follows an edit.
                guard generation > shownGeneration else { return }
                next.note(spotter.recognized)
                plan = next
                shownMap = raw
                planRevision += 1
            }
            shownGeneration = generation
            spotObstacles()
        } catch is CancellationError {
        } catch {
            if generation > shownGeneration { mapLoadFailed = true }
        }
    }

    /// After a restart Valetudo serves its placeholder until the firmware sends the map, which
    /// can take over a minute. Polls wait that out rather than blank a good plan, but only for
    /// so long, because erasing the plan on Valetudo's web page looks just the same from here.
    private func isWaitingForMap(_ raw: RawMap) -> Bool {
        guard raw.isPlaceholder, plan?.isEmpty == false else {
            placeholderSince = nil
            return false
        }
        let clock = ContinuousClock()
        let since = placeholderSince ?? clock.now
        placeholderSince = since
        return since.duration(to: clock.now) < restartGrace
    }

    /// Only for an owner who keeps obstacle photos. The photos themselves are never stored.
    private func spotObstacles() {
        guard switches[.obstaclePhotos] == true, let obstacles = plan?.obstacles else { return }
        let client = client
        spotter.look(at: obstacles, fetch: {
            try await client.getData("\(Cap.root)/\(Cap.obstaclePhotos)/img/\($0)")
        }, found: { [weak self] in
            guard let self else { return }
            plan?.note(spotter.recognized)
        })
    }

    private func loadName() async {
        if let name = await readSetting(.name, { try await client.getJSON("/valetudo/config/customizations") })?["friendlyName"] as? String {
            friendlyName = name
        }
    }

    /// What this robot is and what it offers. Only an update changes these, so each is read until
    /// it has answered once, and one missed at launch still turns up without another full load.
    private func loadSpecs() async {
        if let robot = await readOnce("/robot", { try await client.get($0, as: RobotInfo.self) }) {
            info = robot
        }
        for kind in PresetKind.allCases where has(kind.capability) {
            if let list = await readOnce("\(Cap.root)/\(kind.capability)/presets", { try await client.get($0, as: [String].self) }) {
                presets[kind] = PresetKind.ordered(list)
            }
        }
        if has(Cap.rooms), let limits = await readOnce("\(Cap.root)/\(Cap.rooms)/properties", { try await client.get($0, as: IterationLimits.self) }) {
            maxRoomPasses = limits.iterationCount?.max ?? 1
            roomOrderSupported = limits.customOrderSupport ?? false
        }
        if has(Cap.zones), let limits = await readOnce("\(Cap.root)/\(Cap.zones)/properties", { try await client.get($0, as: IterationLimits.self) }) {
            maxZonePasses = limits.iterationCount?.max ?? 1
            maxZones = limits.zoneCount?.max ?? 1
        }
    }

    /// All of this can also change from Valetudo's web page, or over MQTT.
    func loadSettings() async {
        for item in RobotSwitch.allCases where has(item.rawValue) {
            await loadSwitch(item)
        }
        if has(Cap.volume) { await loadVolume() }
        for item in ChoiceSetting.allCases where has(item.rawValue) {
            await loadChoice(item)
        }
    }

    private func loadSwitch(_ item: RobotSwitch) async {
        struct Toggle: Decodable { let enabled: Bool }
        if let toggle = await readSetting(.toggle(item), { try await client.get("\(Cap.root)/\(item.rawValue)", as: Toggle.self) }) {
            switches[item] = toggle.enabled
        }
    }

    private func loadVolume() async {
        struct Level: Decodable { let volume: Double }
        if let level = await readSetting(.volume, { try await client.get("\(Cap.root)/\(Cap.volume)", as: Level.self) }) {
            volume = level.volume
        }
    }

    /// New options are kept even if the value's read fails, or is dropped because of a change.
    private func loadChoice(_ item: ChoiceSetting) async {
        let path = "\(Cap.root)/\(item.rawValue)"
        let properties = "\(path)/properties"
        var options = choices[item]?.options ?? []
        // Options are only kept along with a value, so without one they have to be read again.
        if options.isEmpty { answeredOnce.remove(properties) }
        if let latest = await readOnce(properties, { try await client.getJSON($0) })?[item.optionsKey] as? [String], !latest.isEmpty {
            options = latest
        }
        guard !options.isEmpty else { return }
        let latest = await readSetting(.choice(item), { try await client.getJSON(path) })?[item.valueKey] as? String
        if let value = latest ?? choices[item]?.value { choices[item] = (value, options) }
    }

    func loadCamera() async {
        guard has(Cap.camera) else { return }
        if let installed = await readSetting(.camera, { try await client.getJSON("\(Cap.root)/\(Cap.camera)/properties") })?["duststreamerInstalled"] as? Bool {
            cameraInstalled = installed
        }
        if let enabled = await readSetting(.camera, { try await client.getJSON("/valetudo/config/duststreaming") })?["enabled"] as? Bool {
            cameraEnabled = enabled
        }
        if cameraEnabled, !cameraInstalled, cameraInstallPath == nil,
           let executable = await read({ try await client.getJSON("/system/runtime/info") })?["execPath"] as? String {
            cameraInstallPath = (executable as NSString).deletingLastPathComponent + "/duststreamer"
        }
    }

    /// True once the owner has enabled streaming in Valetudo and installed the Duststreamer.
    var cameraReady: Bool { has(Cap.camera) && cameraEnabled && cameraInstalled }

    func refreshFloorPlan() async {
        await loadMap(redraw: true)
        await loadRooms()
        if has(Cap.pendingMap), let pending = await read({ try await client.getJSON("\(Cap.root)/\(Cap.pendingMap)") })?["pending"] as? Bool {
            pendingMap = pending
        }
    }

    func loadRooms() async {
        guard has(Cap.rooms) else { return }
        rooms = await read { try await client.get("\(Cap.root)/\(Cap.rooms)", as: [RoomRef].self) } ?? rooms
    }

    func loadSchedule() async {
        if let properties = await readOnce("/timers/properties", { try await client.get($0, as: ScheduleProperties.self) }) {
            scheduleProperties = properties
        }
        if let list = await readSetting(.routines, { try await client.get("/timers", as: [String: Routine].self) }) {
            routines = Self.inOrder(list.values)
        }
        if has(Cap.quietHours), let hours = await readSetting(.quietHours, { try await client.get("\(Cap.root)/\(Cap.quietHours)", as: QuietHours.self) }) {
            quietHours = hours
        }
    }

    private static func inOrder(_ routines: some Sequence<Routine>) -> [Routine] {
        routines.sorted { ($0.hour, $0.minute, $0.id) < ($1.hour, $1.minute, $1.id) }
    }

    func loadDetails() async {
        detailReads += 1
        let number = detailReads
        await noticeUpdate()
        await loadCamera()
        if has(Cap.consumables) {
            let available = await read({ try await client.get("\(Cap.root)/\(Cap.consumables)/properties", as: ConsumableProperties.self) })?.availableConsumables ?? []
            for entry in available { consumableMax[entry.id] = entry.maxValue }
            if let list = await read({ try await client.get("\(Cap.root)/\(Cap.consumables)", as: [Consumable].self) }), number == detailReads {
                // Dreame leaves out any part whose firmware read failed, and still answers 200.
                // A part the robot no longer lists at all is gone, which an update can do.
                let missing = consumables.filter { part in
                    !list.contains { $0.id == part.id } && (available.isEmpty || available.contains { $0.id == part.id })
                }
                consumables = list + missing
            }
        }
        if has(Cap.totalStats), let points = await read({ try await client.get("\(Cap.root)/\(Cap.totalStats)", as: [DataPoint].self) }) {
            total = Dictionary(points.map { ($0.type, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        if let list = await read({ try await client.get("/events", as: [RobotEvent].self) }), number == detailReads {
            events = list
        }
    }

    /// An update can change what the robot can do. Valetudo's own page reloads itself rather
    /// than keep driving a newer robot from what it knew before.
    private func noticeUpdate() async {
        guard let latest = await read({ try await client.get("/valetudo/version", as: VersionInfo.self) }) else { return }
        let known = build
        build = latest
        version = latest.release ?? version
        guard let known, known != latest else { return }
        needsFullLoad = true
        // A load already running leaves this to the next one, which the polls start.
        if fullLoad == nil { await loadEverything() }
    }

    private func loadRunStatistics() async {
        guard has(Cap.currentStats),
              let points = await read({ try await client.get("\(Cap.root)/\(Cap.currentStats)", as: [DataPoint].self) }) else { return }
        currentRun.merge(points)
    }

    private func followState() async {
        while !Task.isCancelled {
            // A refused login gets the same answer however often it's tried.
            try? await Task.sleep(for: .seconds(needsLogin ? 15 : 2))
            await loadState()
        }
    }

    /// A robot can accept a job a moment before it reports moving. `limit` is a little over one
    /// poll of `followState`, which is what notices when it does.
    func waitForWork(limit: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: limit)
        while !state.isActive, clock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The map only needs to be fresh while the robot is moving. The tick stays short even when
    /// it isn't, so a job started during a long wait shows after a state poll and one tick.
    private func followMap() async {
        let clock = ContinuousClock()
        var lastLoad = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if connected, state.isActive || lastLoad.duration(to: clock.now) >= .seconds(15) {
                await loadMap()
                lastLoad = clock.now
            }
        }
    }

    private func followDetails() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if connected {
                await loadSpecs()
                await loadDetails()
            }
        }
    }

    /// A job's figures only move during the job, so they're read through it and once after.
    /// Set by any state read that saw a job, so even one shorter than a tick gets its final figures.
    private var jobSeenSinceRunRead = false

    private func followRun() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if connected, state.isActive || jobSeenSinceRunRead {
                jobSeenSinceRunRead = state.isActive
                await loadRunStatistics()
            }
        }
    }

    // MARK: Commands

    /// Shows a short confirmation. Failures use the same place, for longer.
    func notify(_ message: String, symbol: String = "checkmark.circle.fill", seconds: Double = 2.2, isProblem: Bool = false) {
        toast = Toast(message: message, symbol: symbol, isProblem: isProblem)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }

    func report(_ error: Error) {
        // A firmware's message can be long, and its ending is often what to do about it.
        let message = error.localizedDescription
        notify(message, symbol: "exclamationmark.triangle.fill", seconds: max(4.5, Double(message.count) / 15), isProblem: true)
    }

    /// A gentle nudge for something the user can correct straight away.
    func warn(_ message: String) {
        notify(message, symbol: "hand.raised.fill", seconds: 2.6, isProblem: true)
    }

    /// Runs a command and says whether the robot accepted it. `done` only shows if it did.
    /// `answered` hears how it went, with the error if there was one, before the status is read.
    @discardableResult
    private func attempt(done: String? = nil, answered: (Error?) -> Void = { _ in }, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
        } catch {
            answered(error)
            if !(error is CancellationError) { report(error) }
            return false
        }
        answered(nil)
        if let done { notify(done) }
        await loadState()
        return true
    }

    private func perform(done: String? = nil, _ work: @escaping () async throws -> Void) {
        Task { await attempt(done: done, work) }
    }

    /// What a change can touch. Each routine is its own, so that one being refused can't disturb
    /// another. `routines` is only for reads, which get the whole list at once.
    private enum Field: Hashable {
        case name, volume, quietHours, camera, routines
        case preset(PresetKind), toggle(RobotSwitch), choice(ChoiceSetting), routine(String)

        func covers(_ other: Field) -> Bool {
            if self == .routines, case .routine = other { return true }
            return self == other
        }
    }

    /// The changes to one field that the robot hasn't finished answering.
    private struct Change {
        var waiting = 0
        var newest = 0
        var newestAccepted = 0
        /// One of the answers never came, so the robot may have acted on that change anyway.
        var unsure = false
        /// Shows what the robot is known to have: the newest change it accepted, or else what
        /// was there before the first of these.
        var fallback: () -> Void
    }

    /// Shows `value` ahead of the robot's answer, and goes back if the answer is no. Changes to
    /// one thing can overlap, as two quick taps do, and their answers can arrive in any order,
    /// so where to go back to is only known once they're all in.
    private func change<Value>(_ field: Field, _ path: ReferenceWritableKeyPath<RobotStore, Value>, to value: Value,
                               done: String? = nil, _ write: @escaping () async throws -> Void) {
        let before = self[keyPath: path]
        self[keyPath: path] = value
        changeClock += 1
        let order = changeClock
        var entry = changes[field] ?? Change(fallback: { [weak self] in self?[keyPath: path] = before })
        entry.waiting += 1
        entry.newest = order
        changes[field] = entry
        Task {
            var unsure = false
            await attempt(done: done, answered: { error in
                unsure = settle(field, order, error, show: { [weak self] in self?[keyPath: path] = value })
            }, write)
            if unsure { await reread(field) }
        }
    }

    /// Takes in one answer. Says whether the field needs reading, once every answer is in.
    private func settle(_ field: Field, _ order: Int, _ error: Error?, show: @escaping () -> Void) -> Bool {
        changeClock += 1
        lastChange[field] = changeClock
        guard var entry = changes[field] else { return false }
        entry.waiting -= 1
        if error == nil, order > entry.newestAccepted {
            entry.newestAccepted = order
            entry.fallback = show
        }
        if (error as? APIError)?.mayHaveArrived == true { entry.unsure = true }
        guard entry.waiting == 0 else {
            changes[field] = entry
            return false
        }
        changes[field] = nil
        if entry.newestAccepted != entry.newest { entry.fallback() }
        return entry.unsure
    }

    /// An answer that never came leaves only the robot knowing how a change went.
    private func reread(_ field: Field) async {
        switch field {
        case .name: await loadName()
        case .volume: await loadVolume()
        case .quietHours, .routines, .routine: await loadSchedule()
        case .camera: await loadCamera()
        case .preset: await loadState()
        case .toggle(let item): await loadSwitch(item)
        case .choice(let item): await loadChoice(item)
        }
    }

    // These three are here because `change` works through key paths.

    private subscript(choice item: ChoiceSetting) -> String? {
        get { choices[item]?.value }
        set {
            if let newValue, let options = choices[item]?.options { choices[item] = (newValue, options) }
        }
    }

    private subscript(routine id: String) -> Routine? {
        get { routines.first { $0.id == id } }
        set {
            let others = routines.filter { $0.id != id }
            routines = Self.inOrder(others + [newValue].compactMap { $0 })
        }
    }

    private var camera: (enabled: Bool, installed: Bool) {
        get { (cameraEnabled, cameraInstalled) }
        set { (cameraEnabled, cameraInstalled) = newValue }
    }

    private func action(_ capability: String, _ name: String, done: String? = nil) {
        let client = client
        perform(done: done) { try await client.put("\(Cap.root)/\(capability)", ["action": name]) }
    }

    /// Starting answers with whether the robot accepted, because picks only clear if it did.
    /// Pause, stop and dock don't wait for anything: stopping must never be held up.
    func start() async -> Bool {
        let client = client
        return await attempt { try await client.put("\(Cap.root)/\(Cap.basic)", ["action": "start"]) }
    }

    func pause() { action(Cap.basic, "pause", done: "Paused") }
    func stop() { action(Cap.basic, "stop", done: "Stopped") }
    func dock() { action(Cap.basic, "home", done: "Heading to the dock") }
    func locate() { action(Cap.locate, "locate", done: "Listen for your robot") }
    func emptyBin() { action(Cap.autoEmpty, "trigger", done: "Emptying the bin") }
    func washMop() { action(Cap.mopWash, "start", done: "Washing the mop") }
    func stopWashingMop() { action(Cap.mopWash, "stop", done: "Stopped washing") }
    func dryMop() { action(Cap.mopDry, "start", done: "Drying the mop") }
    func stopDryingMop() { action(Cap.mopDry, "stop", done: "Stopped drying") }

    func set(_ kind: PresetKind, to name: String) {
        let client = client
        change(.preset(kind), \.state[kind], to: name) {
            try await client.put("\(Cap.root)/\(kind.capability)/preset", ["name": name])
        }
    }

    func clean(rooms ids: [String], passes: Int) async -> Bool {
        await submit(.rooms(ids, passes: passes, customOrder: roomOrderSupported))
    }

    /// `zones` are in map pixels.
    func clean(zones: [CGRect], passes: Int) async -> Bool {
        guard let size = plan?.pixelSize else { return false }
        return await submit(.zones(zones, passes: passes, pixelSize: size))
    }

    /// `point` is in map pixels.
    func go(to point: CGPoint) async -> Bool {
        guard let size = plan?.pixelSize else { return false }
        return await submit(.go(to: point, pixelSize: size))
    }

    private func submit(_ request: JobRequest) async -> Bool {
        let client = client
        return await attempt { try await client.put("\(Cap.root)/\(request.capability)", request.body) }
    }

    func set(_ item: RobotSwitch, to on: Bool) {
        let client = client
        change(.toggle(item), \.switches[item], to: on) {
            try await client.put("\(Cap.root)/\(item.rawValue)", ["action": on ? "enable" : "disable"])
        }
    }

    func set(_ item: ChoiceSetting, to value: String) {
        let client = client
        change(.choice(item), \.[choice: item], to: value) {
            try await client.put("\(Cap.root)/\(item.rawValue)", [item.valueKey: value])
        }
    }

    func rename(to name: String) {
        let client = client
        change(.name, \.friendlyName, to: name, done: "Name saved") {
            try await client.put("/valetudo/config/customizations", ["friendlyName": name])
        }
    }

    /// Valetudo also deletes the Duststreamer when this runs, so the camera can't be
    /// re-enabled over HTTP. Turning it on is deliberately not offered here: that step,
    /// and its warning, stay in Valetudo's own web interface.
    func disableCamera() {
        let client = client
        change(.camera, \.camera, to: (enabled: false, installed: false), done: "Streaming is off") {
            try await client.put("/valetudo/config/duststreaming", ["enabled": false])
        }
    }

    func testSound() { action(Cap.speakerTest, "play_test_sound", done: "Playing a test sound") }
    func startMappingPass() { action(Cap.mappingPass, "start_mapping", done: "Mapping pass started") }

    /// Runs a floor plan change, then redraws the plan once the robot has applied it.
    /// The answer says whether it was accepted, so the editor can keep work that wasn't.
    @discardableResult
    func editPlan(_ capability: String, _ body: [String: Any], done: String) async -> Bool {
        let client = client
        return await changePlan(done: done) { try await client.put("\(Cap.root)/\(capability)", body) }
    }

    @discardableResult
    func saveAnnotations(_ body: [[String: Any]], done: String) async -> Bool {
        let client = client
        return await changePlan(done: done) { try await client.put("\(Cap.root)/\(Cap.annotations)", array: body) }
    }

    private func changePlan(done: String, _ write: () async throws -> Void) async -> Bool {
        await attempt(done: done) {
            do {
                try await write()
            } catch let error as APIError where error.mayHaveArrived {
                // It can have landed anyway, and then the plan should show it.
                await refreshFloorPlan()
                throw error
            }
            try? await Task.sleep(for: .seconds(1))
            await refreshFloorPlan()
        }
    }

    func setVolume(_ value: Double) {
        let client = client
        change(.volume, \.volume, to: value) {
            try await client.put("\(Cap.root)/\(Cap.volume)", ["action": "set_volume", "value": Int(value)])
        }
    }

    func markDone(_ consumable: Consumable) {
        var path = "\(Cap.root)/\(Cap.consumables)/\(consumable.type)"
        if let sub = consumable.subType, sub != "none" { path += "/\(sub)" }
        let client = client
        perform(done: "\(consumable.title) counter reset") {
            try await client.put(path, ["action": "reset"])
            await self.loadDetails()
        }
    }

    /// `reply` must be one the event's class accepts: see `RobotEvent.Style`.
    func respond(to event: RobotEvent, with reply: String) {
        Task { await answer(event, with: reply) }
    }

    /// Waits until the list is up to date, so a screen can hold the row's buttons until then:
    /// the robot refuses a second answer to the same event.
    func answer(_ event: RobotEvent, with reply: String) async {
        let client = client
        _ = await attempt {
            try await client.put("/events/\(event.id)/interact", ["interaction": reply])
            await self.loadDetails()
            if event.style == .pendingMap { await self.refreshFloorPlan() }
        }
    }

    func setEnabled(_ routine: Routine, _ on: Bool) {
        guard var edited = self[routine: routine.id] else { return }
        edited.enabled = on
        let client = client
        change(.routine(routine.id), \.[routine: routine.id], to: edited) {
            // The robot rebuilds a routine from this body, so it starts from the robot's copy.
            // The one here can be older, and would undo edits made on the web page.
            var latest = try await client.get("/timers/\(routine.id)", as: Routine.self)
            latest.enabled = on
            try await client.send("PUT", "/timers/\(routine.id)", encoding: latest)
            if self[routine: routine.id]?.enabled == on { self[routine: routine.id] = latest }
        }
    }

    func delete(_ routine: Routine) {
        let client = client
        change(.routine(routine.id), \.[routine: routine.id], to: nil, done: "Routine deleted") {
            try await client.delete("/timers/\(routine.id)")
        }
    }

    func runNow(_ routine: Routine) {
        let client = client
        perform(done: "Cleaning started") { try await client.put("/timers/\(routine.id)/action", ["action": "execute_now"]) }
    }

    func save(_ hours: QuietHours) {
        let client = client
        change(.quietHours, \.quietHours, to: hours) {
            try await client.send("PUT", "\(Cap.root)/\(Cap.quietHours)", encoding: hours)
        }
    }
}
