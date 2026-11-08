import Observation
import ObjectiveC
import UIKit
import XCTest
@testable import OpenVacuum

/// Answers `StubRobot` can't give: any status, silence, or an answer held back until a test lets
/// it go. It sits in front of `StubRobot`, so nothing here opens a socket either, and it logs
/// every request. Routes are "METHOD /path". An answer can also cover everything at one host.
enum Wire {
    enum Answer {
        case status(Int, Data)
        case silence(URLError.Code)
        case hold(status: Int)
        case holdThenFail(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var hostAnswers: [String: Answer] = [:]
    nonisolated(unsafe) private static var log: [(host: String, route: String)] = []
    nonisolated(unsafe) private static var parked: [String: [() -> Void]] = [:]

    private static let installed: Void = {
        let original = class_getInstanceMethod(StubRobot.self, #selector(URLProtocol.startLoading))
        let replacement = class_getInstanceMethod(StubRobot.self, #selector(StubRobot.wiredStartLoading))
        if let original, let replacement { method_exchangeImplementations(original, replacement) }
    }()

    static func reset() {
        _ = installed
        lock.withLock {
            answers = [:]
            hostAnswers = [:]
            log = []
            parked = [:]
        }
    }

    static func on(_ route: String, _ answer: Answer) {
        lock.withLock { answers[route] = answer }
    }

    static func on(host: String, _ answer: Answer) {
        lock.withLock { hostAnswers[host] = answer }
    }

    static func on(_ route: String, status: Int, _ body: String = "") {
        on(route, .status(status, Data(body.utf8)))
    }

    static func hold(_ route: String, status: Int = 200) {
        on(route, .hold(status: status))
    }

    static func clear(_ route: String) {
        lock.withLock { answers[route] = nil }
    }

    static func clearAll() {
        lock.withLock {
            answers = [:]
            hostAnswers = [:]
        }
    }

    static func count(_ route: String, host: String? = nil) -> Int {
        lock.withLock { log.filter { $0.route == route && (host == nil || $0.host == host) }.count }
    }

    static var heldCount: Int { lock.withLock { parked.values.map(\.count).reduce(0, +) } }

    static func release() {
        let waiting = lock.withLock {
            defer { parked = [:] }
            return parked.values.flatMap { $0 }
        }
        waiting.forEach { $0() }
    }

    static func release(_ route: String) {
        let waiting = lock.withLock {
            defer { parked[route] = nil }
            return parked[route] ?? []
        }
        waiting.forEach { $0() }
    }

    /// Lets one held request on a route go, the oldest unless told otherwise.
    static func releaseOne(_ route: String, newest: Bool = false) {
        let next: (() -> Void)? = lock.withLock {
            guard parked[route]?.isEmpty == false else { return nil }
            return newest ? parked[route]?.removeLast() : parked[route]?.removeFirst()
        }
        next?()
    }

    fileprivate static func answer(for route: String, host: String) -> Answer? {
        lock.withLock {
            log.append((host, route))
            return hostAnswers[host] ?? answers[route]
        }
    }

    fileprivate static func park(_ route: String, _ answer: @escaping () -> Void) {
        lock.withLock { parked[route, default: []].append(answer) }
    }
}

extension StubRobot {
    /// Swapped with `startLoading`, so calling this runs `StubRobot`'s own answer. `dynamic`
    /// because a final class would otherwise call straight back into this.
    @objc dynamic func wiredStartLoading() {
        guard let url = request.url else { return }
        let path = url.path.replacingOccurrences(of: "/api/v2", with: "")
        let route = "\(request.httpMethod ?? "GET") \(path)"
        switch Wire.answer(for: route, host: url.host ?? "") {
        case nil:
            wiredStartLoading()
        case .status(let status, let body):
            finish(url, status, body)
        case .silence(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold(let status):
            // What the robot would have said when asked, whatever it says by the time this lands.
            let body = Data((Self.routes[path] ?? "").utf8)
            parkOnThisThread(route) { self.finish(url, status, body) }
        case .holdThenFail(let code):
            parkOnThisThread(route) { self.client?.urlProtocol(self, didFailWithError: URLError(code)) }
        }
    }

    /// A URL protocol has to answer on the thread it started on.
    private func parkOnThisThread(_ route: String, _ answer: @escaping () -> Void) {
        let loop = CFRunLoopGetCurrent()
        let mode = RunLoop.current.currentMode ?? .default
        Wire.park(route) {
            CFRunLoopPerformBlock(loop, mode.rawValue as CFString, answer)
            CFRunLoopWakeUp(loop)
        }
    }

    private func finish(_ url: URL, _ status: Int, _ body: Data) {
        guard let client else { return }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
}

/// A robot that reports everything the store reads, and the routes they live on.
private enum Fixture {
    static let root = Cap.root
    static let carpet = "\(root)/\(RobotSwitch.carpet.rawValue)"
    static let photos = "\(root)/\(Cap.obstaclePhotos)"
    static let cleanRoute = "\(root)/\(ChoiceSetting.cleanRoute.rawValue)"
    static let volume = "\(root)/\(Cap.volume)"
    static let fanPresets = "\(root)/FanSpeedControlCapability/presets"
    static let quietHours = "\(root)/\(Cap.quietHours)"
    static let parts = "\(root)/\(Cap.consumables)"
    static let runStats = "\(root)/\(Cap.currentStats)"
    static let pendingMap = "\(root)/\(Cap.pendingMap)"
    static let attributes = "/robot/state/attributes"
    static let map = "/robot/state/map"
    /// What Valetudo serves until the firmware sends a map.
    static let placeholder = #"{"pixelSize":5,"metaData":{"defaultMap":true},"layers":[{"type":"floor","compressedPixels":[1,1,5]}],"entities":[]}"#

    static func install() {
        StubRobot.install()
        Wire.reset()
        let capabilities = [Cap.basic, Cap.locate, Cap.rooms, Cap.zones, Cap.goTo, RobotSwitch.carpet.rawValue,
                            ChoiceSetting.cleanRoute.rawValue, Cap.volume, "FanSpeedControlCapability",
                            Cap.quietHours, Cap.consumables, Cap.currentStats, Cap.camera, Cap.pendingMap]
        StubRobot.routes[root] = list(capabilities)
        StubRobot.routes[carpet] = #"{"enabled":true}"#
        StubRobot.routes[cleanRoute] = #"{"route":"normal"}"#
        StubRobot.routes["\(cleanRoute)/properties"] = #"{"supportedRoutes":["quick","normal"]}"#
        StubRobot.routes[volume] = #"{"volume":70}"#
        StubRobot.routes[fanPresets] = #"["max","custom","low","turbo"]"#
        StubRobot.routes[quietHours] = #"{"enabled":true,"start":{"hour":22,"minute":0},"end":{"hour":7,"minute":0}}"#
        StubRobot.routes["/timers"] = #"{"a":\#(routine("a", hour: 8)),"b":\#(routine("b", hour: 9))}"#
        StubRobot.routes["/timers/a"] = routine("a", hour: 8)
        StubRobot.routes["/timers/properties"] = #"{"supportedActions":["full_cleanup"]}"#
        StubRobot.routes[parts] = #"[\#(part("brush", "main")),\#(part("mop", "all"))]"#
        StubRobot.routes["\(parts)/properties"] = #"{"availableConsumables":[]}"#
        StubRobot.routes[runStats] = stats(seconds: 300, area: 60000)
        StubRobot.routes["\(root)/\(Cap.camera)/properties"] = #"{"duststreamerInstalled":true}"#
        StubRobot.routes["/valetudo/config/duststreaming"] = #"{"enabled":true}"#
        StubRobot.routes[pendingMap] = #"{"pending":false}"#
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.10.0","commit":"aaa"}"#
        StubRobot.routes["/events"] = "[]"
    }

    static func list(_ names: [String]) -> String {
        "[" + names.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    static func routine(_ id: String, hour: Int, enabled: Bool = true, label: String = "Morning") -> String {
        #"{"id":"\#(id)","enabled":\#(enabled),"label":"\#(label)","dow":[1,3],"hour":\#(hour),"minute":30,"action":{"type":"full_cleanup","params":{}}}"#
    }

    static func part(_ type: String, _ subType: String) -> String {
        #"{"__class":"ConsumableStateAttribute","type":"\#(type)","subType":"\#(subType)","remaining":{"value":120,"unit":"minutes"}}"#
    }

    static func stats(seconds: Int, area: Int) -> String {
        #"[{"type":"time","value":\#(seconds)},{"type":"area","value":\#(area)}]"#
    }

    static func attributes(_ status: String, flag: String = "none", fan: String = "low") -> String {
        #"[{"__class":"StatusStateAttribute","value":"\#(status)","flag":"\#(flag)"},{"__class":"PresetSelectionStateAttribute","type":"fan_speed","value":"\#(fan)"}]"#
    }

    /// A one-room map, so that each name makes a different one.
    static func plan(_ room: String, entities: String = "") -> String {
        #"{"pixelSize":5,"layers":[{"type":"segment","compressedPixels":[10,10,5,10,11,5],"metaData":{"segmentId":"1","name":"\#(room)"}}],"entities":[\#(entities)]}"#
    }

    /// Blank, and made up on the spot. No robot's camera or obstacle photo comes near these tests.
    static let blankImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }

    @MainActor static func store(at host: String = "stub.invalid", spotter: ObstacleSpotter? = nil,
                                 restartGrace: Duration = .seconds(120)) -> RobotStore {
        RobotStore(client: Client(baseURL: "http://\(host)"), spotter: spotter, restartGrace: restartGrace)
    }

    @MainActor static func loaded(at host: String = "stub.invalid", spotter: ObstacleSpotter? = nil,
                                  restartGrace: Duration = .seconds(120)) async -> RobotStore {
        let store = store(at: host, spotter: spotter, restartGrace: restartGrace)
        await store.loadEverything()
        return store
    }
}

@MainActor
private func eventually(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: .seconds(seconds))
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Runs a command the robot accepts, and waits for it to finish. Every accepted command ends
/// with a state read, so a state only the robot knows about shows that it has.
@MainActor
private func accepted(by store: RobotStore, _ command: () -> Void) async -> Bool {
    StubRobot.routes[Fixture.attributes] = Fixture.attributes("idle", flag: "landed", fan: store.selected(.fan) ?? "low")
    command()
    return await eventually { store.state.flag == "landed" }
}

/// `Wire` stays in place for the whole run, so nothing a test scripted may outlive it.
@MainActor
class StoreTestCase: XCTestCase {
    override func setUp() async throws {
        Fixture.install()
    }

    override func tearDown() async throws {
        Wire.clearAll()
        Wire.release()
    }
}

final class StoreReadTests: StoreTestCase {
    func testAFailedReloadKeepsEverythingThatWasGood() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.friendlyName, "Robbie")
        for route in ["/robot", "/valetudo/config/customizations", Fixture.carpet, Fixture.volume, Fixture.fanPresets,
                      Fixture.quietHours, Fixture.cleanRoute, "/timers", "\(Cap.root)/\(Cap.rooms)",
                      "\(Cap.root)/\(Cap.rooms)/properties", "\(Cap.root)/\(Cap.zones)/properties", Fixture.parts,
                      "/valetudo/config/duststreaming", "/events"] {
            Wire.on("GET \(route)", status: 500, "Firmware said no")
        }
        await store.loadEverything()
        XCTAssertEqual(store.friendlyName, "Robbie")
        XCTAssertEqual(store.info?.modelName, "One")
        XCTAssertEqual(store.switches[.carpet], true)
        XCTAssertEqual(store.volume, 70)
        XCTAssertEqual(store.presets[.fan], ["low", "max", "turbo"])
        XCTAssertNotNil(store.quietHours)
        XCTAssertEqual(store.choices[.cleanRoute]?.value, "normal")
        XCTAssertEqual(store.routines.count, 2)
        XCTAssertEqual(store.rooms.count, 2)
        XCTAssertEqual(store.maxRoomPasses, 3)
        XCTAssertEqual(store.maxZones, 4)
        XCTAssertEqual(store.consumables.count, 2)
        XCTAssertTrue(store.cameraEnabled)
    }

    func testPresetsComeInTheWebsOrderWithoutCustom() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.presets[.fan], ["low", "max", "turbo"])
    }

    func testPartsLeftOutOfAnAnswerKeepTheirLastReading() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.parts] = #"[\#(Fixture.part("brush", "main"))]"#
        await store.loadDetails()
        XCTAssertEqual(store.consumables.map(\.id), ["brush/main", "mop/all"])
        StubRobot.routes[Fixture.parts] = "[]"
        await store.loadDetails()
        XCTAssertEqual(store.consumables.count, 2, "Dreame answers with an empty list when its firmware read fails")
    }

    func testAReadOverlappingAChangeCantPutTheOldValueBack() async {
        let store = await Fixture.loaded()
        Wire.hold("GET \(Fixture.carpet)")
        let read = Task { await store.loadSettings() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        Wire.clearAll()
        let landed = await accepted(by: store) { store.set(.carpet, to: false) }
        XCTAssertTrue(landed)
        Wire.release()
        await read.value
        XCTAssertEqual(store.switches[.carpet], false, "the robot's old answer arrived after the change")
    }

    func testAReadDuringAChangeCantPutTheOldValueBack() async {
        let store = await Fixture.loaded()
        Wire.hold("PUT \(Fixture.carpet)")
        let landed = await accepted(by: store) {
            store.set(.carpet, to: false)
            Task {
                await store.loadSettings()
                XCTAssertEqual(store.switches[.carpet], false, "the robot hasn't applied it yet, so it still says on")
                Wire.clearAll()
                Wire.release()
            }
        }
        XCTAssertTrue(landed)
    }

    func testAChangeDuringTheFirstLoadLeavesNoGaps() async {
        let store = Fixture.store()
        Wire.hold("PUT \(Cap.root)/FanSpeedControlCapability/preset")
        store.set(.fan, to: "max")
        await store.loadEverything()
        XCTAssertEqual(store.switches[.carpet], true, "nothing else would read these until the app next returns")
        XCTAssertEqual(store.volume, 70)
        XCTAssertEqual(store.routines.count, 2)
        let landed = await accepted(by: store) {
            Wire.clearAll()
            Wire.release()
        }
        XCTAssertTrue(landed)
    }

    func testAReadAfterAChangeIsBelieved() async {
        let store = await Fixture.loaded()
        let landed = await accepted(by: store) { store.set(.carpet, to: false) }
        XCTAssertTrue(landed)
        await store.loadSettings()
        XCTAssertEqual(store.switches[.carpet], true, "the stub never changed, so the robot still says on")
    }

    func testSettingsAreReadAgainButTheirOptionsArent() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.carpet] = #"{"enabled":false}"#
        StubRobot.routes[Fixture.volume] = #"{"volume":30}"#
        StubRobot.routes[Fixture.cleanRoute] = #"{"route":"quick"}"#
        await store.loadSettings()
        XCTAssertEqual(store.switches[.carpet], false)
        XCTAssertEqual(store.volume, 30)
        XCTAssertEqual(store.choices[.cleanRoute]?.value, "quick")
        XCTAssertEqual(Wire.count("GET \(Fixture.cleanRoute)/properties"), 1)
    }

    func testOptionsThatFailedOnceAreTriedAgain() async {
        Wire.on("GET \(Fixture.cleanRoute)/properties", status: 500)
        let store = await Fixture.loaded()
        XCTAssertNil(store.choices[.cleanRoute])
        Wire.clearAll()
        await store.loadSettings()
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["quick", "normal"])
    }

    func testAChoiceWhoseValueFailedIsReadAgain() async {
        Wire.on("GET \(Fixture.cleanRoute)", status: 500)
        let store = await Fixture.loaded()
        XCTAssertNil(store.choices[.cleanRoute])
        Wire.clearAll()
        await store.loadSettings()
        XCTAssertEqual(store.choices[.cleanRoute]?.value, "normal")
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["quick", "normal"])
    }

    func testAReadDuringARoutineChangeCantPutItBack() async {
        let store = await Fixture.loaded()
        Wire.hold("PUT /timers/a")
        store.setEnabled(store.routines[0], false)
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        await store.loadSchedule()
        XCTAssertEqual(store.routines.first { $0.id == "a" }?.enabled, false, "the robot's list still has it on")
        let landed = await accepted(by: store) {
            Wire.clearAll()
            Wire.release()
        }
        XCTAssertTrue(landed)
    }

    func testComingBackRereadsWhatCanChangeElsewhere() async {
        let store = await Fixture.loaded()
        StubRobot.routes["/valetudo/config/customizations"] = #"{"friendlyName":"Rosie"}"#
        StubRobot.routes[Fixture.carpet] = #"{"enabled":false}"#
        StubRobot.routes["\(Cap.root)/\(Cap.rooms)"] = #"[{"id":"9","name":"Attic"}]"#
        StubRobot.routes["/timers"] = #"{"z":\#(Fixture.routine("z", hour: 3))}"#
        StubRobot.routes["/events"] = #"[{"__class":"DustBinFullValetudoEvent","id":"e","processed":false}]"#
        StubRobot.routes[Fixture.runStats] = Fixture.stats(seconds: 900, area: 120000)
        await store.refreshOnReturn()
        XCTAssertEqual(store.friendlyName, "Rosie")
        XCTAssertEqual(store.switches[.carpet], false)
        XCTAssertEqual(store.rooms.map(\.id), ["9"])
        XCTAssertEqual(store.routines.map(\.id), ["z"])
        XCTAssertEqual(store.openEvents.count, 1)
        XCTAssertEqual(store.currentRun.seconds, 900)
    }

    func testComingBackDoesNothingDuringALoad() async {
        let store = Fixture.store()
        Wire.hold("GET \(Fixture.attributes)")
        let load = Task { await store.loadEverything() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Fixture.attributes)"), 1)
        Wire.clearAll()
        Wire.release()
        await load.value
    }

    func testComingBackAwayFromTheRobotWaitsForItToAnswer() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.cannotConnectToHost))
        Wire.on("GET /robot", .silence(.cannotConnectToHost))
        await store.refreshOnReturn()
        XCTAssertFalse(store.reachable)
        XCTAssertEqual(Wire.count("GET \(Fixture.carpet)"), 1, "with no robot, each read would only wait out its timeout")

        Wire.clearAll()
        StubRobot.routes[Fixture.carpet] = #"{"enabled":false}"#
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable)
        XCTAssertEqual(store.switches[.carpet], false)
    }

    func testRunFiguresAreTypedAsTheRobotGivesThem() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.currentRun.seconds, 300)
        XCTAssertEqual(store.currentRun.squareCentimetres, 60000)
        XCTAssertFalse(store.currentRun.isEmpty)
    }

    func testARobotWithoutRunFiguresHasAnEmptyRun() async {
        StubRobot.routes[Cap.root] = Fixture.list([Cap.basic])
        let store = await Fixture.loaded()
        XCTAssertTrue(store.currentRun.isEmpty)
        XCTAssertEqual(Wire.count("GET \(Fixture.runStats)"), 0)
    }

    func testTheThirtySecondReadLeavesRunFiguresAlone() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(Wire.count("GET \(Fixture.runStats)"), 1)
        await store.loadDetails()
        XCTAssertEqual(Wire.count("GET \(Fixture.runStats)"), 1)
    }

    func testAnEmptyRunAnswerKeepsTheLastFigures() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.runStats] = "[]"
        await store.loadEverything()
        XCTAssertEqual(store.currentRun.seconds, 300)
    }

    func testAPartialRunAnswerKeepsTheOtherFigure() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.runStats] = #"[{"type":"area","value":90000}]"#
        await store.refreshOnReturn()
        XCTAssertEqual(store.currentRun.squareCentimetres, 90000)
        XCTAssertEqual(store.currentRun.seconds, 300, "Dreame drops any figure whose firmware read failed")
    }

    func testWhatAFirstLoadMissedComesBackOnReturn() async {
        Wire.on("GET \(Fixture.fanPresets)", .silence(.timedOut))
        Wire.on("GET \(Cap.root)/\(Cap.zones)/properties", status: 500)
        Wire.on("GET \(Cap.root)/\(Cap.rooms)/properties", status: 500)
        Wire.on("GET /robot", status: 500)
        let store = await Fixture.loaded()
        XCTAssertNil(store.presets[.fan])
        XCTAssertNil(store.info)
        XCTAssertEqual(store.maxZones, 1)
        XCTAssertEqual(store.maxRoomPasses, 1)
        XCTAssertFalse(store.roomOrderSupported)

        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertEqual(store.presets[.fan], ["low", "max", "turbo"])
        XCTAssertEqual(store.info?.modelName, "One")
        XCTAssertEqual(store.maxZones, 4)
        XCTAssertEqual(store.maxZonePasses, 2)
        XCTAssertEqual(store.maxRoomPasses, 3)
        XCTAssertTrue(store.roomOrderSupported)
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1, "only what's missing, without another full load")
    }

    func testWhatsBeenReadOnceIsntReadAgainOnReturn() async {
        let store = await Fixture.loaded()
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Fixture.fanPresets)"), 1)
        XCTAssertEqual(Wire.count("GET /timers/properties"), 1)
    }

    func testAFullLoadReadsEverythingAgain() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.fanPresets] = #"["max"]"#
        await store.loadEverything()
        XCTAssertEqual(store.presets[.fan], ["max"])
    }

    func testAnUpdatedRobotIsReadAgain() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.version, "2026.10.0")
        XCTAssertFalse(store.has(Cap.speakerTest))

        StubRobot.routes[Cap.root] = Fixture.list([Cap.basic, ChoiceSetting.cleanRoute.rawValue, Cap.speakerTest])
        StubRobot.routes["\(Fixture.cleanRoute)/properties"] = #"{"supportedRoutes":["deep"]}"#
        StubRobot.routes["/timers/properties"] = #"{"supportedActions":["segment_cleanup"]}"#
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.11.0","commit":"bbb"}"#
        await store.loadDetails()

        XCTAssertTrue(store.has(Cap.speakerTest))
        XCTAssertEqual(store.version, "2026.11.0")
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["deep"])
        XCTAssertEqual(store.scheduleProperties?.supportedActions, ["segment_cleanup"])
    }

    func testANewBuildOfTheSameReleaseCountsAsAnUpdate() async {
        let store = await Fixture.loaded()
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.10.0","commit":"ccc"}"#
        await store.loadDetails()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 2)
    }

    func testTheSameVersionReadsNothingExtra() async {
        let store = await Fixture.loaded()
        await store.loadDetails()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1)
    }

    func testAnUpdateSeenDuringALoadLeavesItToTheNextOne() async {
        let store = await Fixture.loaded()
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.11.0","commit":"bbb"}"#
        var finished = false
        Task {
            await store.loadEverything()
            finished = true
        }
        let done = await eventually { finished }
        XCTAssertTrue(done, "waiting for a new load here would be waiting for itself")
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 2)
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 3, "the next answer from the robot runs it again")
    }

    func testAnUpdateWhoseLoadStalledReadsTheNewOptionsLater() async {
        let store = await Fixture.loaded()
        StubRobot.routes["\(Fixture.cleanRoute)/properties"] = #"{"supportedRoutes":["deep"]}"#
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.11.0","commit":"bbb"}"#
        Wire.on("GET /robot", .silence(.timedOut))
        await store.loadDetails()
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["quick", "normal"], "Valetudo went quiet before reaching these")
        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["deep"])
    }

    func testNewOptionsArentLostToAChangeInFlight() async {
        let store = await Fixture.loaded()
        Wire.hold("PUT \(Fixture.cleanRoute)")
        store.set(.cleanRoute, to: "quick")
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        StubRobot.routes["\(Fixture.cleanRoute)/properties"] = #"{"supportedRoutes":["quick","deep"]}"#
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.11.0","commit":"bbb"}"#
        await store.loadDetails()
        XCTAssertEqual(store.choices[.cleanRoute]?.options, ["quick", "deep"])
        XCTAssertEqual(store.choices[.cleanRoute]?.value, "quick", "the robot hasn't answered, so this stays")
        Wire.clearAll()
        Wire.release()
    }

    func testAChangeDoesntCostTheReadsOfAnythingElse() async {
        Wire.on("GET \(Cap.root)", status: 503)
        let store = await Fixture.loaded()
        XCTAssertTrue(store.hasLoaded, "this load got nowhere, but it did finish")
        Wire.clearAll()
        Wire.hold("PUT \(Cap.root)/FanSpeedControlCapability/preset")
        store.set(.fan, to: "max")
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        await store.refreshOnReturn()
        XCTAssertEqual(store.switches[.carpet], true, "nothing else would read these until the app next returns")
        XCTAssertEqual(store.routines.count, 2)
        XCTAssertEqual(store.volume, 70)
        Wire.clearAll()
        Wire.release()
    }

    func testAnUpdateTakesAwayWhatItRemoved() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.switches[.carpet], true)
        StubRobot.routes[Cap.root] = Fixture.list([Cap.basic])
        StubRobot.routes["/valetudo/version"] = #"{"release":"2026.11.0","commit":"bbb"}"#
        await store.loadDetails()
        XCTAssertFalse(store.has(RobotSwitch.carpet.rawValue))
        XCTAssertNil(store.switches[.carpet], "Behavior draws a row for anything held here")
        XCTAssertNil(store.choices[.cleanRoute])
        XCTAssertNil(store.volume)
        XCTAssertNil(store.presets[.fan])
    }

    func testAPartTheRobotStillListsKeepsItsLastReading() async {
        let store = await Fixture.loaded()
        StubRobot.routes["\(Fixture.parts)/properties"] = Self.available(["brush", "main"], ["mop", "all"])
        StubRobot.routes[Fixture.parts] = #"[\#(Fixture.part("brush", "main"))]"#
        await store.loadDetails()
        XCTAssertEqual(store.consumables.map(\.id), ["brush/main", "mop/all"])
    }

    func testAPartTheRobotNoLongerListsIsDropped() async {
        let store = await Fixture.loaded()
        StubRobot.routes["\(Fixture.parts)/properties"] = Self.available(["brush", "main"])
        StubRobot.routes[Fixture.parts] = #"[\#(Fixture.part("brush", "main"))]"#
        await store.loadDetails()
        XCTAssertEqual(store.consumables.map(\.id), ["brush/main"])
    }

    func testAPartMissingFromTheListIsKeptIfTheRobotStillReportsIt() async {
        let store = await Fixture.loaded()
        StubRobot.routes["\(Fixture.parts)/properties"] = Self.available(["brush", "main"])
        await store.loadDetails()
        XCTAssertEqual(store.consumables.map(\.id), ["brush/main", "mop/all"], "it's the robot's answer that counts")
    }

    private static func available(_ parts: [String]...) -> String {
        let entries = parts.map { #"{"type":"\#($0[0])","subType":"\#($0[1])","maxValue":100}"# }
        return #"{"availableConsumables":[\#(entries.joined(separator: ","))]}"#
    }

    func testAnOlderPollCantBringBackADismissedAlert() async throws {
        let alert = #"{"__class":"DustBinFullValetudoEvent","id":"e","processed":false}"#
        StubRobot.routes["/events"] = "[\(alert)]"
        let store = await Fixture.loaded()
        let event = try XCTUnwrap(store.openEvents.first)
        Wire.hold("GET /events")
        let poll = Task { await store.loadDetails() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        Wire.clearAll()
        StubRobot.routes["/events"] = "[]"
        store.respond(to: event, with: "ok")
        let dismissed = await eventually { store.openEvents.isEmpty }
        XCTAssertTrue(dismissed)
        Wire.release()
        await poll.value
        XCTAssertTrue(store.openEvents.isEmpty, "that read began before the robot dismissed it")
    }

    func testAnOlderPollCantBringBackAResetCounter() async throws {
        let store = await Fixture.loaded()
        let brush = try XCTUnwrap(store.consumables.first)
        XCTAssertEqual(brush.remaining.value, 120)
        Wire.hold("GET \(Fixture.parts)")
        let poll = Task { await store.loadDetails() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        Wire.clearAll()
        StubRobot.routes[Fixture.parts] = #"[{"type":"brush","subType":"main","remaining":{"value":999,"unit":"minutes"}}]"#
        store.markDone(brush)
        let reset = await eventually { store.consumables.first?.remaining.value == 999 }
        XCTAssertTrue(reset)
        Wire.release()
        await poll.value
        XCTAssertEqual(store.consumables.first?.remaining.value, 999)
    }

    func testAnOlderPollCantPutAPresetBack() async {
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "low")
        let store = await Fixture.loaded()
        Wire.hold("GET \(Fixture.attributes)")
        let poll = Task { await store.refreshOnReturn() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        Wire.clearAll()
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "max")
        store.set(.fan, to: "max")
        let read = await eventually { Wire.count("GET \(Fixture.attributes)") >= 3 }
        XCTAssertTrue(read, "every command ends with a status read")
        Wire.release()
        await poll.value
        XCTAssertEqual(store.selected(.fan), "max", "the robot has applied it, and that read began before it did")
    }

    func testAnOlderPollCantPutAStatusBack() async {
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("cleaning")
        let store = await Fixture.loaded()
        Wire.hold("GET \(Fixture.attributes)")
        let poll = Task { await store.refreshOnReturn() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        Wire.clearAll()
        let paused = await accepted(by: store) { store.pause() }
        XCTAssertTrue(paused)
        Wire.release()
        await poll.value
        XCTAssertEqual(store.state.flag, "landed", "that read began before the robot stopped")
    }

    func testAnOlderFailureCantOutrankANewerAnswer() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .holdThenFail(.cannotConnectToHost))
        let poll = Task { await store.refreshOnReturn() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        Wire.clear("GET \(Fixture.attributes)")
        Wire.on("GET /robot", .silence(.cannotConnectToHost))
        let started = await store.start()
        XCTAssertTrue(started, "that command's status read has answered since the poll set out")
        Wire.release()
        await poll.value
        XCTAssertTrue(store.reachable)
    }

    func testAPollDuringAChangeLeavesThePresetOnScreen() async {
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "low")
        let store = await Fixture.loaded()
        Wire.hold("PUT \(Cap.root)/FanSpeedControlCapability/preset")
        store.set(.fan, to: "max")
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("cleaning", fan: "low")
        await store.refreshOnReturn()
        XCTAssertEqual(store.state.status, "cleaning", "everything else about the read still counts")
        XCTAssertEqual(store.selected(.fan), "max", "the robot hasn't answered yet")
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("cleaning", fan: "max")
        Wire.clearAll()
        Wire.release()
        let read = await eventually { Wire.count("GET \(Fixture.attributes)") >= 3 }
        XCTAssertTrue(read)
    }

    func testTheStatusReadAfterAChangeIsBelieved() async {
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "low")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "high")
        store.set(.fan, to: "max")
        let shown = await eventually { store.selected(.fan) == "high" }
        XCTAssertTrue(shown, "a robot can take a preset and report a different one")
    }

    func testObstaclePhotosStayOnTheRobotUnlessTheOwnerKeepsThem() async {
        StubRobot.routes[Cap.root] = Fixture.list([Cap.basic, Cap.obstaclePhotos])
        StubRobot.routes[Fixture.photos] = #"{"enabled":false}"#
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen", entities: Self.unnamedObstacle)
        let store = await Fixture.loaded()
        await store.loadEverything()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Wire.count("GET \(Fixture.photos)/img/x"), 0)
    }

    func testANameFromAPhotoAppearsWithoutCountingAsANewMap() async {
        StubRobot.routes[Cap.root] = Fixture.list([Cap.basic, Cap.obstaclePhotos])
        StubRobot.routes[Fixture.photos] = #"{"enabled":true}"#
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen", entities: Self.unnamedObstacle)
        Wire.on("GET \(Fixture.photos)/img/x", .status(200, Fixture.blankImage))
        let spotter = ObstacleSpotter(analyze: { _ in [.init(label: "Sneaker", confidence: 1)] })
        let store = await Fixture.loaded(spotter: spotter)
        let revision = store.planRevision

        await store.loadEverything()
        let named = await eventually { store.plan?.obstacles.first?.title == "Sneaker" }
        XCTAssertTrue(named)
        XCTAssertEqual(store.planRevision, revision)

        StubRobot.routes[Fixture.map] = Fixture.plan("Pantry", entities: Self.unnamedObstacle)
        await store.loadEverything()
        XCTAssertEqual(store.planRevision, revision + 1)
        XCTAssertEqual(store.plan?.obstacles.first?.title, "Sneaker", "a new map keeps the name")
        XCTAssertEqual(Wire.count("GET \(Fixture.photos)/img/x"), 1, "each photo is only looked at once")
    }

    private static let unnamedObstacle = #"{"type":"obstacle","points":[60,60],"metaData":{"id":"x","label":"Obstacle","image":"/photo"}}"#
}

final class StoreMapTests: StoreTestCase {
    func testAnUnchangedMapChangesNothing() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        let revision = store.planRevision
        let redrawn = expectation(description: "the plan's filters are expensive to redraw")
        redrawn.isInverted = true
        withObservationTracking { _ = store.plan } onChange: { redrawn.fulfill() }
        await store.loadEverything()
        await fulfillment(of: [redrawn], timeout: 0.1)
        XCTAssertEqual(store.planRevision, revision)
    }

    func testAChangedMapIsANewRevision() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        let revision = store.planRevision
        StubRobot.routes[Fixture.map] = Fixture.plan("Pantry")
        await store.loadEverything()
        XCTAssertEqual(store.planRevision, revision + 1)
        XCTAssertEqual(store.plan?.rooms.first?.name, "Pantry")
    }

    func testAnOlderReadCantReplaceANewerOne() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("First")
        let store = await Fixture.loaded()

        StubRobot.routes[Fixture.map] = Fixture.plan("Older")
        Wire.hold("GET \(Fixture.map)")
        let poll = Task { await store.loadEverything() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)

        StubRobot.routes[Fixture.map] = Fixture.plan("Newer")
        Wire.clearAll()
        await store.refreshFloorPlan()
        XCTAssertEqual(store.plan?.rooms.first?.name, "Newer")

        Wire.release()
        await poll.value
        XCTAssertEqual(store.plan?.rooms.first?.name, "Newer")
    }

    func testAnOlderFailureCantFlagANewerRead() async {
        let store = await Fixture.loaded()
        Wire.hold("GET \(Fixture.map)", status: 500)
        let poll = Task { await store.loadEverything() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        Wire.clearAll()
        await store.refreshFloorPlan()
        Wire.release()
        await poll.value
        XCTAssertFalse(store.mapLoadFailed)
    }

    func testASlowBuildCantReplaceANewerPlan() async {
        let store = await Fixture.loaded()
        let route = "GET \(Fixture.map)"
        // Few numbers, so it decodes at once, but many cells, so it takes a while to build.
        let rows = (0..<500).flatMap { [0, $0, 500] }
        StubRobot.routes[Fixture.map] = #"{"pixelSize":5,"layers":[{"type":"segment","compressedPixels":\#(rows),"metaData":{"segmentId":"1","name":"Older"}}],"entities":[]}"#
        Wire.hold(route)
        let older = Task { await store.refreshFloorPlan() }
        let first = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(first)
        StubRobot.routes[Fixture.map] = Fixture.plan("Newer")
        let newer = Task { await store.refreshFloorPlan() }
        let second = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(second)

        Wire.releaseOne(route)
        try? await Task.sleep(for: .milliseconds(50))
        Wire.clearAll()
        Wire.releaseOne(route)
        await newer.value
        await older.value
        XCTAssertEqual(store.plan?.rooms.first?.name, "Newer")
    }

    func testARestartDoesntBlankAGoodPlan() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        await store.loadEverything()
        XCTAssertEqual(store.plan?.rooms.first?.name, "Kitchen", "the robot hasn't lost its map, it just hasn't sent it yet")
        XCTAssertFalse(store.mapLoadFailed)
    }

    func testAPlaceholderThatStaysIsBelieved() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded(restartGrace: .milliseconds(100))
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        await store.loadEverything()
        XCTAssertEqual(store.plan?.isEmpty, false)
        try? await Task.sleep(for: .milliseconds(150))
        await store.loadEverything()
        XCTAssertEqual(store.plan?.isEmpty, true, "the plan may have been erased on Valetudo's web page")
    }

    func testTheRealMapReturningEndsTheWait() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded(restartGrace: .milliseconds(100))
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        await store.loadEverything()
        try? await Task.sleep(for: .milliseconds(150))
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        await store.loadEverything()
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        await store.loadEverything()
        XCTAssertEqual(store.plan?.isEmpty, false, "this is a new wait, not the end of the last one")
    }

    func testAskingForThePlanTakesThePlaceholderAtOnce() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        await store.refreshFloorPlan()
        XCTAssertEqual(store.plan?.isEmpty, true, "this is how the plan looks straight after erasing it")
    }

    func testARobotWithNoPlanYetShowsThePlaceholderAtOnce() async {
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        let store = await Fixture.loaded()
        XCTAssertEqual(store.plan?.isEmpty, true)
        XCTAssertFalse(store.mapLoadFailed)
    }

    func testAFailedPendingReadKeepsWhatWasKnown() async {
        StubRobot.routes[Fixture.pendingMap] = #"{"pending":true}"#
        let store = await Fixture.loaded()
        await store.refreshFloorPlan()
        XCTAssertTrue(store.pendingMap)
        Wire.on("GET \(Fixture.pendingMap)", status: 500)
        await store.refreshFloorPlan()
        XCTAssertTrue(store.pendingMap)
    }

    func testAMapWithNothingReadableFailsAndKeepsThePlan() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.map] = #"{"pixelSize":5,"layers":[{"kind":"floor"},{"kind":"segment"}],"entities":[]}"#
        await store.loadEverything()
        XCTAssertTrue(store.mapLoadFailed, "a format this app can't read isn't a robot with no map")
        XCTAssertEqual(store.plan?.rooms.first?.name, "Kitchen")
    }

    func testAMapReadThatFailsIsFlaggedAndKeepsThePlan() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Kitchen")
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.map)", status: 500)
        await store.loadEverything()
        XCTAssertTrue(store.mapLoadFailed)
        XCTAssertEqual(store.plan?.rooms.first?.name, "Kitchen")
        Wire.clearAll()
        await store.loadEverything()
        XCTAssertFalse(store.mapLoadFailed)
    }

    func testMapsDifferOnlyByWhatTheyDraw() throws {
        func decode(_ json: String) throws -> RawMap { try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)) }
        let layer = #"{"type":"segment","compressedPixels":[1,1,2],"metaData":{"segmentId":"1","active":false,"area":100}}"#
        let robot = #"{"type":"robot_position","points":[10,10],"metaData":{"angle":90}}"#
        let map = try decode(#"{"pixelSize":5,"layers":[\#(layer)],"entities":[\#(robot)],"metaData":{"nonce":"one"}}"#)
        XCTAssertEqual(map, try decode(#"{"pixelSize":5,"layers":[\#(layer)],"entities":[\#(robot)],"metaData":{"nonce":"two"}}"#),
                       "Valetudo stamps every map with a new nonce")
        let cleaning = layer.replacingOccurrences(of: #""active":false"#, with: #""active":true"#)
        XCTAssertNotEqual(map, try decode(#"{"pixelSize":5,"layers":[\#(cleaning)],"entities":[\#(robot)]}"#))
        let moved = robot.replacingOccurrences(of: "[10,10]", with: "[11,10]")
        XCTAssertNotEqual(map, try decode(#"{"pixelSize":5,"layers":[\#(layer)],"entities":[\#(moved)]}"#))
    }

    func testAMideaCarpetDoesntCostTheMap() throws {
        let json = #"{"pixelSize":5,"layers":[],"entities":[{"type":"carpet","points":[0,0,10,0,10,10,0,10],"metaData":{"id":3}}]}"#
        let map = try JSONDecoder().decode(RawMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.entities.first?.metaData?.id, "3")
        XCTAssertFalse(FloorPlan(map).carpets.isEmpty)
    }

    func testAnOddEntityIsSkippedAndTheRestKept() throws {
        let json = """
        {"pixelSize":5,"layers":[],"entities":[
            {"type":"carpet","points":"none"},
            {"points":[1,2]},
            17,
            {"type":"robot_position","points":[10,10],"metaData":"odd"},
            {"type":"charger_location","points":[20,20],"metaData":{"angle":"north","label":5}}
        ]}
        """
        let map = try JSONDecoder().decode(RawMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.entities.map(\.type), ["robot_position", "charger_location"])
        XCTAssertNil(map.entities[0].metaData, "odd details don't cost the entity itself")
        XCTAssertNil(map.entities[1].metaData?.angle)
    }

    func testAnOddLayerIsSkippedAndTheRestKept() throws {
        let json = """
        {"pixelSize":5,"entities":[],"layers":[
            {"compressedPixels":[1,1,1]},
            "floor",
            {"type":"wall","compressedPixels":"none"},
            {"type":"floor","compressedPixels":[1,1,1],"metaData":[]}
        ]}
        """
        let map = try JSONDecoder().decode(RawMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.layers.map(\.type), ["wall", "floor"])
        XCTAssertEqual(map.layers[0].runs, [])
        XCTAssertEqual(map.layers[1].runs, [1, 1, 1])
    }

    func testSomethingThatIsntAMapStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(RawMap.self, from: Data(#"{"message":"Nope"}"#.utf8)))
    }

    func testValetudosPlaceholderReadsAsNoPlan() throws {
        let json = """
        {"pixelSize":5,"metaData":{"defaultMap":true},
         "layers":[{"type":"floor","compressedPixels":[1,1,5]}],
         "entities":[{"type":"charger_location","points":[20,20]},{"type":"robot_position","points":[10,10]}]}
        """
        let plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertNil(plan.dock, "the placeholder's dock isn't real")
    }

    func testUsingANewPlanRedrawsIt() async throws {
        StubRobot.routes[Fixture.map] = Fixture.plan("Old")
        let store = await Fixture.loaded()
        let event = try JSONDecoder().decode(RobotEvent.self, from: Data(#"{"__class":"PendingMapChangeValetudoEvent","id":"e"}"#.utf8))
        StubRobot.routes[Fixture.map] = Fixture.plan("New")
        store.respond(to: event, with: "yes")
        let redrawn = await eventually { store.plan?.rooms.first?.name == "New" }
        XCTAssertTrue(redrawn)
        XCTAssertEqual(StubRobot.commands.last?.path, "/events/e/interact")
    }

    func testATimedOutEditStillShowsAChangeThatLanded() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Old")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.map] = Fixture.plan("New")
        Wire.on("PUT \(Cap.root)/\(Cap.segmentEdit)", .silence(.timedOut))
        let accepted = await store.editPlan(Cap.segmentEdit, ["action": "split"], done: "Split")
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.plan?.rooms.first?.name, "New")
        XCTAssertEqual(store.toast?.message, "The robot is taking longer than expected. The change may still go through.")
    }

    func testADroppedAnnotationSaveStillShowsAChangeThatLanded() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Old")
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.map] = Fixture.plan("New")
        Wire.on("PUT \(Cap.root)/\(Cap.annotations)", .silence(.networkConnectionLost))
        let accepted = await store.saveAnnotations([["type": "ramp"]], done: "Saved")
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.plan?.rooms.first?.name, "New")
    }

    func testARefusedEditLeavesThePlanAlone() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Old")
        let store = await Fixture.loaded()
        let reads = Wire.count("GET \(Fixture.map)")
        StubRobot.refusing = "\(Cap.root)/\(Cap.segmentEdit)"
        let accepted = await store.editPlan(Cap.segmentEdit, ["action": "split"], done: "Split")
        XCTAssertFalse(accepted)
        XCTAssertEqual(Wire.count("GET \(Fixture.map)"), reads, "the robot said no, so nothing can have landed")
        XCTAssertEqual(store.toast?.message, "Nope")
    }
}

final class StoreConnectionTests: StoreTestCase {
    private func silenceTheRobot() {
        for route in [Cap.root, Fixture.attributes, "/robot"] {
            Wire.on("GET \(route)", .silence(.cannotConnectToHost))
        }
    }

    /// Runs the polls for the length of a test, because recovery happens in them.
    private func following(_ store: RobotStore, _ body: () async -> Void) async {
        let polls = Task { await store.run() }
        await body()
        polls.cancel()
        await polls.value
    }

    func testTheStatusStaysLiveDuringALoad() async {
        Wire.hold("GET \(Fixture.fanPresets)")
        let store = Fixture.store()
        await following(store) {
            let held = await eventually { Wire.heldCount == 1 }
            XCTAssertTrue(held)
            StubRobot.routes[Fixture.attributes] = Fixture.attributes("cleaning")
            let live = await eventually(within: 4) { store.state.status == "cleaning" }
            XCTAssertTrue(live, "the load is still waiting on the robot, and the polls shouldn't be")
            Wire.clearAll()
            Wire.release()
        }
    }

    func testEndingThePollsStopsTheLoad() async {
        Wire.hold("GET /robot")
        let store = Fixture.store()
        let polls = Task { await store.run() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        polls.cancel()
        await polls.value
        Wire.clearAll()
        Wire.release()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Wire.count("GET /timers"), 0, "the app has left this robot, and this login may be gone")
        XCTAssertEqual(Wire.count("GET /valetudo/version"), 0)
    }

    func testEndingThePollsStartsNoOtherLoad() async {
        Wire.hold("GET \(Cap.root)")
        let store = Fixture.store()
        let polls = Task { await store.run() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        polls.cancel()
        await polls.value
        Wire.clearAll()
        Wire.release()
        _ = await store.start()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1, "a late answer isn't a reason to start reading again")
        XCTAssertFalse(store.hasLoaded, "a load that was cut off hasn't finished")
    }

    func testPollsStartedAgainPickUpWhereTheLoadWasCutOff() async {
        Wire.hold("GET \(Fixture.fanPresets)")
        let store = Fixture.store()
        let polls = Task { await store.run() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        polls.cancel()
        await polls.value
        Wire.clearAll()
        Wire.release()
        await following(store) {
            let loaded = await eventually(within: 5) { store.presets[.fan] != nil && store.routines.count == 2 }
            XCTAssertTrue(loaded)
        }
    }

    func testBeingCancelledDuringTheCheckSaysNothingAboutTheRobot() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
        Wire.on("GET /robot", .holdThenFail(.timedOut))
        let poll = Task { await store.refreshOnReturn() }
        let checking = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(checking)
        poll.cancel()
        await poll.value
        XCTAssertTrue(store.reachable, "the check was called off, so nothing was learned")
    }

    func testACancelledReadSaysNothingAboutTheRobot() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", status: 401)
        await store.refreshOnReturn()
        XCTAssertTrue(store.needsLogin)
        Wire.hold("GET \(Fixture.attributes)")
        let poll = Task { await store.refreshOnReturn() }
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        poll.cancel()
        await poll.value
        XCTAssertTrue(store.needsLogin, "a read that was called off isn't an answer")
    }

    /// All of this happens over time, so it shares one wait, on three robots at once.
    func testThePollsOnlyAskWhatARobotCanAnswer() async {
        let (good, refusing, silent) = ("good.invalid", "refusing.invalid", "silent.invalid")
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("cleaning")
        Wire.on("GET \(Fixture.fanPresets)", status: 500)
        let stores = [await Fixture.loaded(at: good), await Fixture.loaded(at: refusing), await Fixture.loaded(at: silent)]
        Wire.on(host: refusing, .status(401, Data()))
        Wire.on(host: silent, .silence(.timedOut))
        let polls = stores.map { store in Task { await store.run() } }

        let settled = await eventually(within: 8) {
            stores[1].needsLogin && !stores[2].reachable && Wire.count("GET /events", host: good) == 2
        }
        XCTAssertTrue(settled)
        Wire.clear("GET \(Fixture.fanPresets)")
        XCTAssertNil(stores[0].presets[.fan])
        let routes = ["GET \(Fixture.map)", "GET /events", "GET \(Fixture.runStats)", "GET \(Cap.root)"]
        let before = routes.map { (Wire.count($0, host: refusing), Wire.count($0, host: silent)) }
        let statusReads = Wire.count("GET \(Fixture.attributes)", host: refusing)
        let mapReads = Wire.count("GET \(Fixture.map)", host: good)

        try? await Task.sleep(for: .seconds(31))

        for (route, counts) in zip(routes, before) {
            XCTAssertEqual(Wire.count(route, host: refusing), counts.0, "\(route) would only be refused")
            XCTAssertEqual(Wire.count(route, host: silent), counts.1, "\(route) would only wait out its timeout")
        }
        XCTAssertLessThanOrEqual(Wire.count("GET \(Fixture.attributes)", host: refusing) - statusReads, 3,
                                 "a refused login gets the same answer however often it's tried")
        XCTAssertGreaterThan(Wire.count("GET \(Fixture.map)", host: good) - mapReads, 5, "a robot at work is followed closely")
        XCTAssertEqual(stores[0].presets[.fan], ["low", "max", "turbo"], "what a load missed turns up with the details")
        polls.forEach { $0.cancel() }
        for poll in polls { await poll.value }
    }

    func testAFailedFirstLoadRecoversByItself() async {
        silenceTheRobot()
        let store = Fixture.store()
        await following(store) {
            let failed = await eventually { store.hasLoaded && !store.reachable }
            XCTAssertTrue(failed)
            XCTAssertTrue(store.capabilities.isEmpty)
            Wire.clearAll()
            let recovered = await eventually(within: 6) { store.has(Cap.basic) && store.hasLoaded && store.plan != nil }
            XCTAssertTrue(recovered)
            XCTAssertEqual(store.friendlyName, "Robbie")
            XCTAssertTrue(store.reachable)
            XCTAssertFalse(store.mapLoadFailed)
        }
    }

    func testTryAgainAfterAFailedMapReadGoesBackToLoading() async {
        Wire.on("GET \(Fixture.map)", status: 500)
        let store = await Fixture.loaded()
        XCTAssertTrue(store.mapLoadFailed)
        Wire.clearAll()
        Wire.hold("GET \(Fixture.map)")
        let retry = Task { await store.retry() }
        let loading = await eventually { !store.hasLoaded && !store.mapLoadFailed }
        XCTAssertTrue(loading)
        Wire.clearAll()
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        Wire.release()
        await retry.value
        XCTAssertNotNil(store.plan)
        XCTAssertFalse(store.mapLoadFailed)
    }

    func testAFailedFirstLoadLetsEachScreenSaySo() async {
        silenceTheRobot()
        let store = await Fixture.loaded()
        XCTAssertTrue(store.hasLoaded, "Care and Schedule show their failure once this is true")
        XCTAssertFalse(store.reachable)
        XCTAssertTrue(store.mapLoadFailed, "not having fetched a plan isn't the same as there being none")
    }

    func testTheRobotReturningReadsAsLoadingNotAsNoPlan() async {
        silenceTheRobot()
        let store = await Fixture.loaded()
        Wire.clearAll()
        Wire.hold("GET \(Cap.root)")
        let refresh = Task { await store.refreshOnReturn() }
        let returned = await eventually { store.reachable }
        XCTAssertTrue(returned)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.mapLoadFailed)
        Wire.clearAll()
        Wire.release()
        await refresh.value
        XCTAssertTrue(store.hasLoaded)
        XCTAssertTrue(store.has(Cap.basic))
    }

    func testOnlyOneLoadRunsAtATime() async {
        let store = Fixture.store()
        Wire.hold("GET \(Cap.root)")
        let loads = (0..<3).map { _ in Task { await store.loadEverything() } }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1)
        Wire.clearAll()
        Wire.release()
        for load in loads { await load.value }
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1)
        XCTAssertTrue(store.has(Cap.basic), "everyone who asked waited for that one load")
    }

    func testTryAgainGoesBackToLoadingAndReloads() async {
        silenceTheRobot()
        let store = await Fixture.loaded()
        Wire.clearAll()
        Wire.hold("GET \(Cap.root)")
        let retry = Task { await store.retry() }
        let loading = await eventually { !store.hasLoaded }
        XCTAssertTrue(loading)
        XCTAssertFalse(store.mapLoadFailed)
        XCTAssertTrue(store.reachable, "the offline notice would otherwise cover the spinner")
        Wire.clearAll()
        Wire.release()
        await retry.value
        XCTAssertTrue(store.hasLoaded)
        XCTAssertTrue(store.has(Cap.basic))
    }

    func testTryAgainWithEverythingLoadedKeepsTheScreenAsItIs() async {
        let store = await Fixture.loaded()
        Wire.hold("GET \(Cap.root)")
        let retry = Task { await store.retry() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        XCTAssertTrue(store.hasLoaded)
        Wire.clearAll()
        Wire.release()
        await retry.value
    }

    func testTryAgainThatFailsSaysSoAgain() async {
        silenceTheRobot()
        let store = await Fixture.loaded()
        await store.retry()
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.reachable)
        XCTAssertTrue(store.mapLoadFailed)
    }

    func testLosingTheRobotPartWayStopsTheLoadAndItRunsAgain() async {
        Wire.on("GET /robot", .silence(.timedOut))
        let store = await Fixture.loaded()
        XCTAssertEqual(Wire.count("GET /timers"), 0, "each read left would only wait out its timeout")
        XCTAssertEqual(Wire.count("GET \(Fixture.carpet)"), 0)

        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertEqual(store.info?.modelName, "One")
        XCTAssertEqual(store.presets[.fan], ["low", "max", "turbo"])
        XCTAssertEqual(store.routines.count, 2)
        XCTAssertEqual(store.switches[.carpet], true)
    }

    func testACheckThatOutlivesTheLoadLeavesNothingBehind() async {
        let store = await Fixture.loaded()
        Wire.hold("GET \(Fixture.runStats)")
        let load = Task { await store.loadEverything() }
        let last = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(last)
        Wire.on("GET /timers", .silence(.timedOut))
        Wire.on("GET /robot", .holdThenFail(.timedOut))
        let screen = Task { await store.loadSchedule() }
        let checking = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(checking)
        Wire.clear("GET \(Fixture.runStats)")
        Wire.release("GET \(Fixture.runStats)")
        await load.value
        Wire.release("GET /robot")
        await screen.value
        Wire.clearAll()

        let events = Wire.count("GET /events")
        await store.loadDetails()
        XCTAssertEqual(Wire.count("GET /events"), events + 1, "nothing is stopping reads any more")
    }

    func testAMissedReadOutsideALoadAsksNothingElse() async {
        let store = await Fixture.loaded()
        let checks = Wire.count("GET /robot")
        Wire.on("GET /timers", .silence(.timedOut))
        await store.loadSchedule()
        XCTAssertEqual(Wire.count("GET /robot"), checks, "there's no load here to stop")
    }

    func testARefusalFromTheCheckStillCountsAsAnswering() async {
        for status in [401, 500] {
            let store = await Fixture.loaded()
            Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
            Wire.on("GET /robot", status: status)
            await store.refreshOnReturn()
            XCTAssertTrue(store.reachable, "\(status) still came from Valetudo")
            Wire.clearAll()
        }
    }

    func testAnAnswerThatIsntValetudoIsntTheRobot() async {
        let store = await Fixture.loaded()
        for route in [Fixture.attributes, "/robot", Cap.root] {
            StubRobot.routes[route] = "<html>Sign in to the hotel Wi-Fi</html>"
        }
        await store.refreshOnReturn()
        XCTAssertFalse(store.reachable, "nothing that answered was Valetudo")
        XCTAssertEqual(store.sentence, "Robbie is offline")
    }

    func testOneSlowReadDoesntStopTheLoad() async {
        Wire.on("GET \(Fixture.fanPresets)", .silence(.timedOut))
        let store = await Fixture.loaded()
        XCTAssertEqual(store.routines.count, 2, "a firmware call can be slow with Valetudo itself fine")
        XCTAssertEqual(store.switches[.carpet], true)
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1, "running it again would only stop at the same place")
    }

    func testARefusedReadDoesntRepeatTheLoad() async {
        Wire.on("GET \(Fixture.fanPresets)", status: 500)
        let store = await Fixture.loaded()
        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1, "a refusal says nothing about the robot being gone")
    }

    func testAChangedLoginOnFirstLoadAsksToSignIn() async {
        Wire.on("GET \(Cap.root)", status: 401)
        let store = await Fixture.loaded()
        XCTAssertTrue(store.needsLogin)
        XCTAssertTrue(store.reachable, "it answered, so the headline shouldn't blame the network")
        XCTAssertTrue(store.hasLoaded)
        XCTAssertTrue(store.mapLoadFailed)
        XCTAssertFalse(store.sentence.contains("offline"))
        XCTAssertEqual(store.notices, [RobotStore.Notice(text: "The robot's login has changed. Sign in again to keep using it.",
                                                         tone: .critical, opensLogin: true)])
    }

    func testAChangedLoginDuringAPollAsksToSignInUntilTheNextGoodAnswer() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", status: 401)
        await store.refreshOnReturn()
        XCTAssertTrue(store.needsLogin)
        XCTAssertEqual(store.sentence, "Robbie needs you to sign in")
        XCTAssertEqual(store.notices.count, 1)
        XCTAssertTrue(store.notices[0].opensLogin)
        XCTAssertEqual(Wire.count("GET \(Fixture.carpet)"), 1, "every read would get the same answer")

        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertFalse(store.needsLogin)
        XCTAssertEqual(store.sentence, "Robbie is docked and charging")
        XCTAssertTrue(store.notices.isEmpty)
    }

    func testAFailedFirstLoadBehindALoginRecoversOnceItsAccepted() async {
        Wire.on("GET \(Cap.root)", status: 401)
        Wire.on("GET \(Fixture.attributes)", status: 401)
        let store = await Fixture.loaded()
        Wire.clearAll()
        await store.refreshOnReturn()
        XCTAssertFalse(store.needsLogin)
        XCTAssertTrue(store.has(Cap.basic))
    }

    func testARefusedPollIsntOffline() async {
        let store = await Fixture.loaded()
        let state = store.state
        Wire.on("GET \(Fixture.attributes)", status: 500, "Error: user ack timeout")
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable)
        XCTAssertEqual(store.state, state)
        XCTAssertFalse(store.sentence.contains("offline"))
    }

    func testAnUnreadablePollIsntOffline() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.attributes] = "not json"
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable)
    }

    func testAStalledFirmwareIsntOffline() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable, "Valetudo itself still answers")
        XCTAssertEqual(Wire.count("GET /robot"), 2)
    }

    /// Saving a list replaces the robot's, so an empty one read during a restart would wipe it.
    func testTheEditorWontTrustAMapThatIsntReal() async throws {
        let client = Client(baseURL: "http://stub.invalid")
        StubRobot.routes[Fixture.map] = Fixture.placeholder
        do {
            _ = try await MapEditorView.realMap(from: client)
            XCTFail("a placeholder must not pass")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The robot hasn't sent its map yet.")
        }
        StubRobot.routes[Fixture.map] = #"{"pixelSize":5,"layers":[{"type":"floor","compressedPixels":[1,1,5]}],"entities":[]}"#
        let map = try await MapEditorView.realMap(from: client)
        XCTAssertFalse(map.isPlaceholder)
    }

    func testTheDockStillNeedsSayingBehindAnError() async {
        StubRobot.routes[Fixture.attributes] = """
        [{"__class":"StatusStateAttribute","value":"error","flag":"none"},
         {"__class":"DockComponentStateAttribute","type":"water_tank_clean","value":"empty"}]
        """
        let store = await Fixture.loaded()
        XCTAssertEqual(store.notices.count, 1, "Home shows the error first")
        XCTAssertEqual(store.dockNotices.map(\.text), ["Refill the clean water tank"], "Care must not say all is well")
    }

    func testAnEmptyScreenNamesTheRealProblem() async {
        let store = await Fixture.loaded()
        XCTAssertEqual(store.readAdvice, "The robot is answering, but this didn't arrive.")

        Wire.on("GET \(Fixture.attributes)", status: 401)
        await store.refreshOnReturn()
        XCTAssertEqual(store.readAdvice, RobotStore.loginAdvice)
        XCTAssertTrue(store.staleAdvice.contains("login"))
    }

    func testAnEventThatGetsAnAnswerHasGoneByTheTimeTheAnswerReturns() async throws {
        StubRobot.routes["/events"] = #"[{"__class":"DustBinFullValetudoEvent","id":"e1","processed":false}]"#
        let store = await Fixture.loaded()
        let event = try XCTUnwrap(store.openEvents.first)
        StubRobot.routes["/events"] = #"[{"__class":"DustBinFullValetudoEvent","id":"e1","processed":true}]"#
        await store.answer(event, with: "ok")
        XCTAssertTrue(store.openEvents.isEmpty, "the row's buttons wait for this, because a second answer is refused")
    }

    func testNoAnswerAtAllIsOffline() async {
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
        Wire.on("GET /robot", .silence(.timedOut))
        await store.refreshOnReturn()
        XCTAssertFalse(store.reachable)
        XCTAssertEqual(store.sentence, "Robbie is offline")
    }

    func testAlreadyOfflineDoesntProbeAgain() async {
        let store = await Fixture.loaded()
        silenceTheRobot()
        await store.refreshOnReturn()
        let probes = Wire.count("GET /robot")
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET /robot"), probes)
    }

    func testTheOfflineNoticePointsAtLocalNetwork() async {
        silenceTheRobot()
        let store = await Fixture.loaded()
        XCTAssertEqual(store.notices.first?.text,
                       "Can't reach the robot. Check that it's on and on the same network as this phone, and that Local Network is on for this app in Settings.")
        XCTAssertEqual(store.notices.first?.tone, .critical)
    }

    func testAJobLeftWaitingIsSaidPlainly() async {
        for status in ["docked", "idle"] {
            StubRobot.routes[Fixture.attributes] = Fixture.attributes(status, flag: "resumable")
            let store = await Fixture.loaded()
            XCTAssertEqual(store.sentence, "Robbie has a job to finish")
        }
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("paused", flag: "resumable")
        let store = await Fixture.loaded()
        XCTAssertEqual(store.sentence, "Robbie is paused")
    }

    func testExpressDefaultBodiesGetThePlainMessage() async {
        let store = await Fixture.loaded()
        let route = "PUT \(Cap.root)/\(Cap.basic)"
        for (status, body) in [(400, "Bad Request"), (403, "Forbidden"), (404, "Not Found"),
                               (500, "Internal Server Error"), (503, "Service Unavailable")] {
            Wire.on(route, status: status, body)
            _ = await store.start()
            XCTAssertEqual(store.toast?.message, "The robot refused that request (error \(status)).")
        }
    }

    func testErrorBodiesAreReadWhateverShapeTheyCameIn() async {
        let store = await Fixture.loaded()
        let route = "PUT \(Cap.root)/\(Cap.basic)"
        for (body, shown) in [(#""Can't do that while docked""#, "Can't do that while docked"),
                              (#"{"message":"Request payload is invalid.","error":[]}"#, "Request payload is invalid."),
                              ("Error: user ack timeout", "Error: user ack timeout"),
                              ("<html>Oops</html>", "The robot refused that request (error 500).")] {
            Wire.on(route, status: 500, body)
            _ = await store.start()
            XCTAssertEqual(store.toast?.message, shown)
        }
    }

    /// One job from start to finish, in real time, because these all depend on the polls.
    func testAJobShowsUpQuicklyAndItsFiguresFollowIt() async {
        StubRobot.routes[Fixture.map] = Fixture.plan("Before")
        let store = await Fixture.loaded()
        await following(store) {
            // Starting the polls loads everything once, which isn't what's being tested here.
            await store.loadEverything()
            StubRobot.set(state: "cleaning")
            StubRobot.routes[Fixture.map] = Fixture.plan("During")
            StubRobot.routes[Fixture.runStats] = Fixture.stats(seconds: 600, area: 90000)

            let mapped = await eventually(within: 5) { store.plan?.rooms.first?.name == "During" }
            XCTAssertTrue(mapped, "a state poll and a map tick is about 4 seconds, not the 15 of an idle wait")
            let during = await eventually(within: 11) { store.currentRun.seconds == 600 }
            XCTAssertTrue(during)

            StubRobot.set(state: "docked")
            StubRobot.routes[Fixture.runStats] = Fixture.stats(seconds: 1200, area: 180000)
            let after = await eventually(within: 13) { store.currentRun.seconds == 1200 }
            XCTAssertTrue(after, "the last figures are read once after the job ends")
        }
    }
}

/// A robot found through discovery, which has a second address to fall back on.
final class StoreFallbackTests: StoreTestCase {
    private let dead = "other.invalid"
    private let fallbackKey = "fallbackAddress"
    private var savedFallback: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedFallback = UserDefaults.standard.object(forKey: fallbackKey)
        Connection.setFallback("http://\(dead)", for: "http://stub.invalid")
    }

    /// Puts back what was there, because these run inside the app and share its saved robot.
    override func tearDown() async throws {
        UserDefaults.standard.set(savedFallback, forKey: fallbackKey)
        try await super.tearDown()
    }

    func testSigningInReachesARobotOnlyAtItsOtherAddress() async throws {
        Wire.on(host: "stub.invalid", .silence(.cannotConnectToHost))
        try await Session.verify(Client(baseURL: "http://stub.invalid"))
        XCTAssertEqual(Wire.count("GET /robot", host: dead), 1, "the name was quiet, so it tried the address")
    }

    func testARobotThatRefusesTheLoginIsNotTriedAgain() async {
        Wire.on("GET /robot", status: 401)
        do {
            try await Session.verify(Client(baseURL: "http://stub.invalid"))
            XCTFail("a refused login must not pass")
        } catch {
            XCTAssertEqual((error as? APIError)?.kind, .needsLogin)
        }
        XCTAssertEqual(Wire.count("GET /robot"), 1, "only silence means the other address might work")
    }

    func testAStalledFirmwareIsntOfflineWhenTheOtherAddressIsDead() async {
        Wire.on(host: dead, .silence(.timedOut))
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable, "Valetudo answers at the address in use")
    }

    func testOneSlowReadDoesntStopTheLoadWhenTheOtherAddressIsDead() async {
        Wire.on(host: dead, .silence(.timedOut))
        Wire.on("GET \(Fixture.fanPresets)", .silence(.timedOut))
        let store = await Fixture.loaded()
        XCTAssertEqual(store.routines.count, 2, "one slow firmware read shouldn't cost everything after it")
        await store.refreshOnReturn()
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Cap.root)"), 1, "running it again would only stop at the same place")
    }

    func testRequestsSettleBackOnTheAddressThatWorks() async {
        Wire.on(host: dead, .silence(.timedOut))
        let store = await Fixture.loaded()
        Wire.on("GET \(Fixture.attributes)", .silence(.timedOut))
        await store.refreshOnReturn()
        Wire.clear("GET \(Fixture.attributes)")
        await store.refreshOnReturn()
        XCTAssertEqual(Wire.count("GET \(Fixture.attributes)", host: dead), 0)
    }

    func testBothAddressesSilentIsOffline() async {
        let store = await Fixture.loaded()
        Wire.on(host: dead, .silence(.timedOut))
        Wire.on(host: "stub.invalid", .silence(.timedOut))
        await store.refreshOnReturn()
        XCTAssertFalse(store.reachable)
    }

    func testSomethingElseAtTheAddressMovesOnToTheOther() async {
        let store = await Fixture.loaded()
        Wire.on(host: "stub.invalid", .status(200, Data("<html>A printer</html>".utf8)))
        await store.refreshOnReturn()
        XCTAssertTrue(store.reachable, "the robot is at its other address")
        let before = Wire.count("GET \(Fixture.attributes)", host: dead)
        await store.refreshOnReturn()
        XCTAssertGreaterThan(Wire.count("GET \(Fixture.attributes)", host: dead), before)
    }
}

final class StoreCommandTests: StoreTestCase {
    /// Two changes to one thing, both refused, with the answers in the order given.
    private func refuseTwo(_ route: String, newestFirst: Bool, in store: RobotStore,
                           _ first: () -> Void, _ second: () -> Void) async {
        Wire.hold(route, status: 500)
        first()
        let one = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(one)
        second()
        let two = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(two)
        Wire.releaseOne(route, newest: newestFirst)
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        Wire.releaseOne(route, newest: newestFirst)
    }

    func testTwoRefusedTogglesBothGoBack() async {
        StubRobot.routes["/timers/b"] = Fixture.routine("b", hour: 9)
        let store = await Fixture.loaded()
        let before = store.routines
        Wire.hold("PUT /timers/a", status: 500)
        Wire.hold("PUT /timers/b", status: 500)
        store.setEnabled(before[0], false)
        store.setEnabled(before[1], false)
        let held = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(held)
        Wire.release("PUT /timers/a")
        let first = await eventually { store.routines.first { $0.id == "a" }?.enabled == true }
        XCTAssertTrue(first)
        XCTAssertEqual(store.routines.first { $0.id == "b" }?.enabled, false, "the robot hasn't answered this one yet")
        Wire.release("PUT /timers/b")
        let both = await eventually { store.routines == before }
        XCTAssertTrue(both)
    }

    func testARefusedToggleGoesBackThoughAnotherRoutineChanged() async {
        StubRobot.routes["/timers/b"] = Fixture.routine("b", hour: 9)
        let store = await Fixture.loaded()
        let before = store.routines
        Wire.hold("PUT /timers/a", status: 500)
        store.setEnabled(before[0], false)
        let held = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(held)
        let landed = await accepted(by: store) { store.setEnabled(before[1], false) }
        XCTAssertTrue(landed)
        Wire.release("PUT /timers/a")
        let restored = await eventually { store.routines.first { $0.id == "a" }?.enabled == true }
        XCTAssertTrue(restored, "the robot refused this one")
        XCTAssertEqual(store.routines.first { $0.id == "b" }?.enabled, false, "and took that one")
    }

    func testTwoRefusedDeletesBothComeBackInOrder() async {
        let store = await Fixture.loaded()
        let before = store.routines
        Wire.hold("DELETE /timers/a", status: 500)
        Wire.hold("DELETE /timers/b", status: 500)
        store.delete(before[0])
        store.delete(before[1])
        XCTAssertTrue(store.routines.isEmpty)
        let held = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(held)
        Wire.release("DELETE /timers/b")
        let first = await eventually { store.routines.map(\.id) == ["b"] }
        XCTAssertTrue(first)
        Wire.release("DELETE /timers/a")
        let both = await eventually { store.routines == before }
        XCTAssertTrue(both, "the robot still has both, and the first one goes back ahead of the other")
    }

    func testRefusedVolumesEndOnTheRobotsValue() async {
        for newestFirst in [false, true] {
            let store = await Fixture.loaded()
            await refuseTwo("PUT \(Fixture.volume)", newestFirst: newestFirst, in: store,
                            { store.setVolume(50) }, { store.setVolume(40) })
            let restored = await eventually { store.volume == 70 }
            XCTAssertTrue(restored, "the robot never took 50 or 40")
            Wire.clearAll()
        }
    }

    func testRefusedSwitchFlipsEndOnTheRobotsValue() async {
        for newestFirst in [false, true] {
            let store = await Fixture.loaded()
            await refuseTwo("PUT \(Fixture.carpet)", newestFirst: newestFirst, in: store,
                            { store.set(.carpet, to: false) }, { store.set(.carpet, to: true) })
            let restored = await eventually { store.switches[.carpet] == true }
            XCTAssertTrue(restored, "the robot still has it on, as it did all along")
            Wire.clearAll()
        }
    }

    func testARefusedChangeFallsBackToAnAcceptedOne() async {
        for newestFirst in [false, true] {
            let store = await Fixture.loaded()
            let route = "PUT \(Fixture.volume)"
            Wire.hold(route)
            store.setVolume(50)
            let one = await eventually { Wire.heldCount == 1 }
            XCTAssertTrue(one)
            Wire.hold(route, status: 500)
            store.setVolume(40)
            let two = await eventually { Wire.heldCount == 2 }
            XCTAssertTrue(two)
            Wire.clearAll()
            Wire.releaseOne(route, newest: newestFirst)
            Wire.releaseOne(route, newest: newestFirst)
            let settled = await eventually { store.volume == 50 }
            XCTAssertTrue(settled, "the robot took 50, whichever answer came first")
        }
    }

    func testARefusalLeavesANewerChangeThatsStillWaitingOnScreen() async {
        let store = await Fixture.loaded()
        let route = "PUT \(Fixture.volume)"
        Wire.hold(route, status: 500)
        store.setVolume(50)
        let one = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(one)
        Wire.hold(route)
        store.setVolume(40)
        let two = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(two)
        Wire.clearAll()
        Wire.releaseOne(route)
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        XCTAssertEqual(store.volume, 40, "the robot hasn't answered this one yet")
        let landed = await accepted(by: store) { Wire.releaseOne(route) }
        XCTAssertTrue(landed)
        XCTAssertEqual(store.volume, 40, "and it took it")
    }

    func testTheNewestAcceptedChangeCountsHoweverTheAnswersArrive() async {
        let store = await Fixture.loaded()
        let route = "PUT \(Fixture.volume)"
        Wire.hold(route)
        store.setVolume(50)
        let one = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(one)
        store.setVolume(40)
        let two = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(two)
        Wire.hold(route, status: 500)
        store.setVolume(30)
        let three = await eventually { Wire.heldCount == 3 }
        XCTAssertTrue(three)
        Wire.clearAll()
        Wire.releaseOne(route, newest: true)
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        Wire.releaseOne(route, newest: true)
        Wire.releaseOne(route, newest: true)
        let settled = await eventually { store.volume == 40 }
        XCTAssertTrue(settled)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.volume, 40, "the answer for 50 came last, but 40 was sent after it")
    }

    func testALateFailureLeavesANewerPresetOrChoiceAlone() async {
        let store = await Fixture.loaded()
        let preset = "PUT \(Cap.root)/FanSpeedControlCapability/preset"
        Wire.hold(preset, status: 500)
        Wire.hold("PUT \(Fixture.cleanRoute)", status: 500)
        store.set(.fan, to: "max")
        store.set(.cleanRoute, to: "quick")
        let held = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(held)
        Wire.clearAll()
        let landed = await accepted(by: store) {
            store.set(.fan, to: "turbo")
            store.set(.cleanRoute, to: "normal")
        }
        XCTAssertTrue(landed)
        Wire.release()
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.selected(.fan), "turbo")
        XCTAssertEqual(store.choices[.cleanRoute]?.value, "normal")
    }

    func testARefusedPresetGoesBack() async {
        StubRobot.routes[Fixture.attributes] = Fixture.attributes("docked", fan: "low")
        let store = await Fixture.loaded()
        Wire.on("PUT \(Cap.root)/FanSpeedControlCapability/preset", status: 500)
        store.set(.fan, to: "max")
        XCTAssertEqual(store.selected(.fan), "max", "it moves at once")
        let restored = await eventually { store.selected(.fan) == "low" }
        XCTAssertTrue(restored)
    }

    func testATimedOutDeleteThatLandedDoesntComeBack() async {
        let store = await Fixture.loaded()
        StubRobot.routes["/timers"] = #"{"b":\#(Fixture.routine("b", hour: 9))}"#
        Wire.on("DELETE /timers/a", .silence(.timedOut))
        store.delete(store.routines[0])
        let told = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(told)
        let read = await eventually { Wire.count("GET /timers") == 2 }
        XCTAssertTrue(read)
        let gone = await eventually { store.routines.map(\.id) == ["b"] }
        XCTAssertTrue(gone, "the toast says it may still go through, and it did")
    }

    func testATimedOutChangeShowsWhatTheRobotEndedUpWith() async {
        let store = await Fixture.loaded()
        StubRobot.routes[Fixture.carpet] = #"{"enabled":false}"#
        Wire.on("PUT \(Fixture.carpet)", .silence(.networkConnectionLost))
        store.set(.carpet, to: false)
        let read = await eventually { Wire.count("GET \(Fixture.carpet)") == 2 }
        XCTAssertTrue(read)
        let shown = await eventually { store.switches[.carpet] == false }
        XCTAssertTrue(shown)
    }

    func testEveryChangeWithNoAnswerIsReadAgain() async {
        let store = await Fixture.loaded()
        let settings = [Fixture.cleanRoute, Fixture.volume, Fixture.quietHours, "/valetudo/config/customizations",
                        "/valetudo/config/duststreaming"]
        for route in settings + ["\(Cap.root)/FanSpeedControlCapability/preset"] {
            Wire.on("PUT \(route)", .silence(.timedOut))
        }
        let routes = settings + [Fixture.attributes]
        let reads = routes.map { Wire.count("GET \($0)") }
        store.set(.cleanRoute, to: "quick")
        store.setVolume(5)
        store.save(QuietHours(enabled: false, start: .init(hour: 1, minute: 0), end: .init(hour: 2, minute: 0)))
        store.rename(to: "Maybe")
        store.disableCamera()
        store.set(.fan, to: "max")
        for (route, before) in zip(routes, reads) {
            let read = await eventually { Wire.count("GET \(route)") > before }
            XCTAssertTrue(read, route)
        }
    }

    func testARefusedChangeIsntReadAgain() async {
        let store = await Fixture.loaded()
        Wire.on("PUT \(Fixture.carpet)", status: 500)
        store.set(.carpet, to: false)
        let restored = await eventually { store.switches[.carpet] == true }
        XCTAssertTrue(restored)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Wire.count("GET \(Fixture.carpet)"), 1, "a refusal leaves no doubt about what the robot has")
    }

    func testTheAnswerForAnOlderTapDoesntCoverANewerOne() async {
        let store = await Fixture.loaded()
        let routine = store.routines[0]
        Wire.hold("PUT /timers/a")
        store.setEnabled(routine, false)
        store.setEnabled(routine, true)
        let held = await eventually { Wire.heldCount == 2 }
        XCTAssertTrue(held)
        Wire.releaseOne("PUT /timers/a")
        let answered = await eventually { Wire.count("GET \(Fixture.attributes)") == 2 }
        XCTAssertTrue(answered, "an accepted command ends with a status read")
        XCTAssertEqual(store.routines.first { $0.id == "a" }?.enabled, true, "the second tap is the one on screen")
        Wire.clearAll()
        Wire.release()
    }

    func testTogglingARoutineBeingDeletedSendsNothing() async {
        let store = await Fixture.loaded()
        let routine = store.routines[0]
        Wire.hold("DELETE /timers/a")
        store.delete(routine)
        store.setEnabled(routine, false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Wire.count("GET /timers/a"), 0)
        XCTAssertEqual(store.routines.map(\.id), ["b"], "and doesn't bring it back")
        Wire.clearAll()
        Wire.release()
    }

    func testAReadOverlappingTheTurnOffCantShowStreamingAsOn() async {
        let store = await Fixture.loaded()
        Wire.hold("GET /valetudo/config/duststreaming")
        let read = Task { await store.loadCamera() }
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        Wire.clearAll()
        let landed = await accepted(by: store) { store.disableCamera() }
        XCTAssertTrue(landed)
        Wire.release()
        await read.value
        XCTAssertFalse(store.cameraEnabled, "that read began before the robot turned it off")
    }

    func testARefusedToggleGoesBack() async {
        let store = await Fixture.loaded()
        let before = store.routines
        StubRobot.refusing = "/timers/a"
        store.setEnabled(before[0], false)
        XCTAssertEqual(store.routines[0].enabled, false, "the switch moves at once")
        let restored = await eventually { store.routines == before }
        XCTAssertTrue(restored)
    }

    func testAnUnreachableToggleGoesBack() async {
        let store = await Fixture.loaded()
        let before = store.routines
        Wire.on("GET /timers/a", .silence(.cannotConnectToHost))
        store.setEnabled(before[0], false)
        let restored = await eventually { store.routines == before }
        XCTAssertTrue(restored)
        XCTAssertEqual(store.toast?.isProblem, true)
    }

    func testARefusedDeleteBringsTheRoutineBack() async {
        let store = await Fixture.loaded()
        let before = store.routines
        Wire.on("DELETE /timers/a", status: 500)
        store.delete(before[0])
        XCTAssertEqual(store.routines.count, 1)
        let restored = await eventually { store.routines == before }
        XCTAssertTrue(restored)
    }

    func testADeleteThatLandsStays() async {
        let store = await Fixture.loaded()
        let landed = await accepted(by: store) { store.delete(store.routines[0]) }
        XCTAssertTrue(landed)
        XCTAssertEqual(store.routines.map(\.id), ["b"])
        XCTAssertEqual(store.toast?.message, "Routine deleted")
    }

    func testTogglingSendsTheRobotsCopyNotTheOneHere() async throws {
        let store = await Fixture.loaded()
        let stale = store.routines[0]
        StubRobot.routes["/timers/a"] = Fixture.routine("a", hour: 17, label: "Edited on the web")
        let landed = await accepted(by: store) { store.setEnabled(stale, false) }
        XCTAssertTrue(landed)
        let sent = try XCTUnwrap(StubRobot.commands.last)
        XCTAssertEqual(sent.path, "/timers/a")
        XCTAssertEqual(sent.body["hour"] as? Int, 17)
        XCTAssertEqual(sent.body["label"] as? String, "Edited on the web")
        XCTAssertEqual(sent.body["enabled"] as? Bool, false)
        XCTAssertEqual(store.routines.first { $0.id == "a" }?.hour, 17)
    }

    func testTogglingARoutineDeletedElsewhereSendsNothing() async {
        let store = await Fixture.loaded()
        StubRobot.routes["/timers/a"] = nil
        store.setEnabled(store.routines[0], false)
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        XCTAssertTrue(StubRobot.commands.isEmpty, "a PUT here would bring it back")
    }

    func testALateFailureLeavesANewerChangeAlone() async {
        let store = await Fixture.loaded()
        Wire.hold("PUT \(Fixture.volume)", status: 500)
        store.setVolume(10)
        let waiting = await eventually { Wire.heldCount == 1 }
        XCTAssertTrue(waiting)
        Wire.clearAll()
        let landed = await accepted(by: store) { store.setVolume(20) }
        XCTAssertTrue(landed)
        Wire.release()
        let refused = await eventually { store.toast?.isProblem == true }
        XCTAssertTrue(refused)
        XCTAssertEqual(store.volume, 20)
    }

    func testEverySettingGoesBackWhenRefused() async {
        let store = await Fixture.loaded()
        for route in [Fixture.carpet, Fixture.cleanRoute, Fixture.volume, Fixture.quietHours, "/valetudo/config/customizations"] {
            Wire.on("PUT \(route)", status: 500)
        }
        let hours = store.quietHours
        store.set(.carpet, to: false)
        store.set(.cleanRoute, to: "quick")
        store.setVolume(5)
        store.rename(to: "Nope")
        store.save(QuietHours(enabled: false, start: .init(hour: 1, minute: 0), end: .init(hour: 2, minute: 0)))
        let restored = await eventually {
            store.switches[.carpet] == true && store.choices[.cleanRoute]?.value == "normal" && store.volume == 70
                && store.friendlyName == "Robbie" && store.quietHours == hours
        }
        XCTAssertTrue(restored)
    }

    func testTurningStreamingOffDoesntNameTheCamera() async {
        let store = await Fixture.loaded()
        let landed = await accepted(by: store) {
            store.disableCamera()
            XCTAssertFalse(store.cameraEnabled)
        }
        XCTAssertTrue(landed)
        XCTAssertEqual(store.toast?.message, "Streaming is off")
        XCTAssertFalse(store.cameraEnabled)
        XCTAssertFalse(store.cameraInstalled)
    }

    func testAFailedTurnOffShowsTheCameraAsItIs() async {
        let store = await Fixture.loaded()
        Wire.on("PUT /valetudo/config/duststreaming", status: 500)
        store.disableCamera()
        let restored = await eventually { store.cameraEnabled && store.cameraInstalled }
        XCTAssertTrue(restored)
    }

    func testResettingTheMopKeepsItsSubType() async throws {
        let store = await Fixture.loaded()
        let mop = try XCTUnwrap(store.consumables.first { $0.type == "mop" })
        let landed = await accepted(by: store) { store.markDone(mop) }
        XCTAssertTrue(landed)
        XCTAssertEqual(StubRobot.commands.last?.path, "\(Fixture.parts)/mop/all")
        XCTAssertEqual(store.toast?.message, "Mop counter reset")
    }
}

final class StoreModelTests: XCTestCase {
    private func part(_ type: String, _ subType: String?, value: Double = 60, unit: String = "minutes") throws -> Consumable {
        let sub = subType.map { #""subType":"\#($0)","# } ?? ""
        let json = #"{"type":"\#(type)",\#(sub)"remaining":{"value":\#(value),"unit":"\#(unit)"}}"#
        return try JSONDecoder().decode(Consumable.self, from: Data(json.utf8))
    }

    private func event(_ json: String) throws -> RobotEvent {
        try JSONDecoder().decode(RobotEvent.self, from: Data(json.utf8))
    }

    private func depleted(_ type: String, _ subType: String) throws -> RobotEvent {
        try event(#"{"__class":"ConsumableDepletedValetudoEvent","id":"a","type":"\#(type)","subType":"\#(subType)"}"#)
    }

    func testAllAndNoneAreLeftOutOfAPartsName() throws {
        XCTAssertEqual(try part("mop", "all").title, "Mop")
        XCTAssertEqual(try part("detergent", "none").title, "Detergent")
        XCTAssertEqual(try part("mop", "main").title, "Main Mop", "as Valetudo's web page has it")
        XCTAssertEqual(try part("brush", "secondary").title, "Secondary Brush")
        XCTAssertEqual(try part("bin", "dock").title, "Dock Bin")
    }

    func testAPartsIdKeepsItsSubType() throws {
        XCTAssertEqual(try part("mop", "all").id, "mop/all", "the robot's maximum is looked up by this")
    }

    func testTimeLeftReadsNaturally() throws {
        XCTAssertEqual(try part("brush", "main", value: 1).remainingText, "1 minute left")
        XCTAssertEqual(try part("brush", "main", value: 45).remainingText, "45 minutes left")
        XCTAssertEqual(try part("brush", "main", value: 180).remainingText, "3 hours left")
        XCTAssertEqual(try part("brush", "main", value: 0).remainingText, "Due now")
        XCTAssertEqual(try part("brush", "main", value: 42, unit: "percent").remainingText, "42% left")
    }

    func testAlertsNameThePartTheyMean() throws {
        XCTAssertEqual(try depleted("brush", "main").title, "Replace the main brush")
        XCTAssertEqual(try depleted("brush", "side_right").title, "Replace the side brush")
        XCTAssertEqual(try depleted("brush", "side_left").title, "Replace the side brush")
        XCTAssertEqual(try depleted("brush", "dock").title, "Replace the dock's brush")
        XCTAssertEqual(try depleted("brush", "secondary").title, "Replace the brush")
        XCTAssertEqual(try depleted("filter", "main").title, "Replace the filter")
        XCTAssertEqual(try depleted("filter", "dock").title, "Replace the dock's filter")
        XCTAssertEqual(try depleted("mop", "all").title, "Replace the mop")
        XCTAssertEqual(try depleted("detergent", "dock").title, "Refill the detergent")
        XCTAssertEqual(try depleted("bin", "dock").title, "Replace the dock's dust bag")
        XCTAssertEqual(try depleted("cleaning", "sensor").title, "Clean the sensors")
    }

    func testValetudosOwnEventsSayWhatHappened() throws {
        let updated = try event(#"{"__class":"ValetudoUpdatedValetudoEvent","id":"a","previousVersion":"2026.09.0","newVersion":"2026.10.0"}"#)
        XCTAssertEqual(updated.title, "Valetudo updated from 2026.09.0 to 2026.10.0")
        XCTAssertEqual(try event(#"{"__class":"ValetudoUpdatedValetudoEvent","id":"a"}"#).title, "Valetudo was updated")
        let restarted = try event(#"{"__class":"ValetudoRuntimeErrorValetudoEvent","id":"a","reason":"memory_usage","description":"Too much"}"#)
        XCTAssertEqual(restarted.title, "Valetudo restarted after a problem")
        XCTAssertEqual(restarted.reason, "memory_usage")
        XCTAssertEqual(restarted.description, "Too much")
    }

    func testAnEventsTimeIsRead() throws {
        let dated = try event(#"{"__class":"DustBinFullValetudoEvent","id":"a","timestamp":"2026-11-07T08:43:06.123Z"}"#)
        XCTAssertEqual(try XCTUnwrap(dated.date).timeIntervalSince1970, 1_794_040_986.123, accuracy: 0.001)
        XCTAssertNil(try event(#"{"__class":"DustBinFullValetudoEvent","id":"a","timestamp":"soon"}"#).date)
    }

    func testAttachmentsAreKeptPerType() throws {
        let json = """
        [{"__class":"AttachmentStateAttribute","type":"mop","attached":true},
         {"__class":"AttachmentStateAttribute","type":"dustbin","attached":false},
         {"__class":"AttachmentStateAttribute","type":"watertank"}]
        """
        let state = RobotState(try JSONDecoder().decode([Attribute].self, from: Data(json.utf8)))
        XCTAssertEqual(state.attachments, ["mop": true, "dustbin": false])
        XCTAssertTrue(state.mopAttached)
    }

    func testAMopNotReportedCountsAsNotAttached() {
        XCTAssertFalse(RobotState().mopAttached, "as strict as Valetudo's web page")
    }

    func testModelDetailsAreRead() throws {
        let json = #"{"manufacturer":"Dreame","modelName":"X40 Ultra","modelDetails":{"supportedAttachments":["mop"],"supportedDockComponents":["dustbag"]}}"#
        let info = try JSONDecoder().decode(RobotInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.modelDetails?.supportedAttachments, ["mop"])
        XCTAssertEqual(info.modelDetails?.supportedDockComponents, ["dustbag"])
    }

    func testOddModelDetailsDontCostTheRest() throws {
        let info = try JSONDecoder().decode(RobotInfo.self, from: Data(#"{"modelName":"X40 Ultra","modelDetails":"odd"}"#.utf8))
        XCTAssertEqual(info.modelName, "X40 Ultra")
        XCTAssertNil(info.modelDetails)
    }

    func testSomethingThatIsntARobotStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(RobotInfo.self, from: Data("[1,2]".utf8)),
                             "connecting relies on this to spot an address that isn't Valetudo")
    }

    func testVersionsDifferByBuildToo() throws {
        func version(_ json: String) throws -> VersionInfo { try JSONDecoder().decode(VersionInfo.self, from: Data(json.utf8)) }
        XCTAssertNotEqual(try version(#"{"release":"1","commit":"a"}"#), try version(#"{"release":"1","commit":"b"}"#))
    }

    func testRunFiguresIgnoreWhatTheyDontKnow() {
        var run = RunStatistics()
        run.merge([DataPoint(type: "count", value: 3)])
        XCTAssertTrue(run.isEmpty)
    }
}
