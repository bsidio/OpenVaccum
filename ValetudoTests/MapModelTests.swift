import SwiftUI
import XCTest
@testable import Valetudo

final class PlanMaskTests: XCTestCase {
    private func square(_ rect: CGRect) -> Path { Path(rect) }

    func testASquareTracesToOneClosedLoop() {
        let mask = PlanMask(square(CGRect(x: 10, y: 10, width: 20, height: 20)), in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let loops = mask.outlines(at: 0.5)
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(PlanMask.area(of: loops[0]), 400, accuracy: 30)
    }

    func testOutlinesStayInMapCoordinates() throws {
        let mask = PlanMask(square(CGRect(x: 110, y: 210, width: 20, height: 20)), in: CGRect(x: 100, y: 200, width: 40, height: 40))
        let loop = try XCTUnwrap(mask.outlines(at: 0.5).first)
        XCTAssertEqual(try XCTUnwrap(loop.map(\.x).min()), 110, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(loop.map(\.y).max()), 230, accuracy: 1)
    }

    func testAHoleTracesAsItsOwnLoop() {
        var ring = Path()
        ring.addRect(CGRect(x: 5, y: 5, width: 30, height: 10))
        ring.addRect(CGRect(x: 5, y: 25, width: 30, height: 10))
        ring.addRect(CGRect(x: 5, y: 15, width: 10, height: 10))
        ring.addRect(CGRect(x: 25, y: 15, width: 10, height: 10))
        let loops = PlanMask(ring, in: CGRect(x: 0, y: 0, width: 40, height: 40)).outlines(at: 0.5)
        XCTAssertEqual(loops.count, 2)
    }

    func testSofteningKeepsWallsOneMapPixelWide() {
        var mask = PlanMask(square(CGRect(x: 5, y: 10, width: 30, height: 1)), in: CGRect(x: 0, y: 0, width: 40, height: 20))
        mask.soften()
        XCTAssertEqual(mask.outlines(at: 0.34, minimumArea: 3).count, 1)
    }

    func testSpecksAreDropped() {
        let mask = PlanMask(square(CGRect(x: 5, y: 5, width: 1, height: 1)), in: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(mask.outlines(at: 0.5, minimumArea: 3).isEmpty)
    }

    func testStraightEdgesLoseTheirExtraPoints() throws {
        let mask = PlanMask(square(CGRect(x: 10, y: 10, width: 100, height: 100)), in: CGRect(x: 0, y: 0, width: 120, height: 120))
        let loop = try XCTUnwrap(mask.outlines(at: 0.5).first)
        XCTAssertLessThan(loop.count, 16)
    }

    func testEmptyPathsTraceToNothing() {
        XCTAssertTrue(PlanMask(Path(), in: CGRect(x: 0, y: 0, width: 10, height: 10)).outlines(at: 0.5).isEmpty)
    }
}

@MainActor
final class ObstacleIconTests: XCTestCase {
    private func obstacle(_ label: String, id: String = "a", hasPhoto: Bool = true) -> FloorPlan.Obstacle {
        FloorPlan.Obstacle(id: id, label: label, hasPhoto: hasPhoto, point: .zero)
    }

    func testEveryIconExists() {
        let labels = ["Dog", "Cat", "Pet Bowl", "Cord", "Sneaker", "Sock", "Sofa", "Chair", "Stuffed Animals", "Ball",
                      "Trash Can", "Weight Scale", "Liquid", "Backpack", "Suitcase", "Paper Bag", "Cardboard Box",
                      "Wine Bottle", "Mug", "Newspaper", "Decorative Plant", "Umbrella", "Dock Entrance"]
        for label in labels {
            let symbol = FloorPlan.Obstacle.symbol(forLabel: label)
            XCTAssertNotEqual(symbol, FloorPlan.Obstacle.genericSymbol, label)
            XCTAssertNotNil(UIImage(systemName: symbol), "\(label) uses \(symbol)")
        }
    }

    func testOnlyWholeWordsMatch() {
        for label in ["Location", "Scatter", "Binoculars", "Tablet", "Boxing"] {
            XCTAssertEqual(FloorPlan.Obstacle.symbol(forLabel: label), FloorPlan.Obstacle.genericSymbol, label)
        }
    }

    func testPetThingsStayPetThings() {
        XCTAssertEqual(FloorPlan.Obstacle.symbol(forLabel: "Pet Bowl"), "pawprint.fill")
    }

    func testARobotPercentageDoesNotGetInTheWay() {
        XCTAssertEqual(FloorPlan.Obstacle.symbol(forLabel: "Shoes (88%)"), "shoe.fill")
    }

    func testVisionNamesAGenericObstacle() async {
        let spotter = ObstacleSpotter(analyze: { _ in
            [.init(label: "Person", confidence: 1), .init(label: "Sneaker", confidence: 0.8)]
        })
        let found = expectation(description: "found")
        spotter.look(at: [obstacle("Obstacle")], fetch: { _ in Self.photo }) { found.fulfill() }
        await fulfillment(of: [found], timeout: 2)
        XCTAssertEqual(spotter.recognized["a"], "Sneaker", "a person isn't an obstacle icon, so the next finding is used")
    }

    func testTheRobotsOwnLabelIsLeftAlone() async {
        let spotter = ObstacleSpotter(analyze: { _ in [] })
        let fetched = Counter()
        spotter.look(at: [obstacle("Cable (92%)")], fetch: { _ in fetched.add(); return Self.photo }) {}
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fetched.value, 0)
    }

    func testObstaclesWithoutPhotosAreSkipped() async {
        let spotter = ObstacleSpotter(analyze: { _ in [] })
        let fetched = Counter()
        spotter.look(at: [obstacle("Obstacle", hasPhoto: false)], fetch: { _ in fetched.add(); return Self.photo }) {}
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fetched.value, 0)
    }

    func testVagueResultsKeepTheGenericIcon() {
        XCTAssertNil(ObstacleSpotter.name(in: [.init(label: "Person", confidence: 1), .init(label: "Wall", confidence: 0.9)]))
    }

    func testAPhotoIsOnlyCheckedOnce() async {
        let spotter = ObstacleSpotter(analyze: { _ in [] })
        let fetched = Counter()
        for _ in 0..<3 {
            spotter.look(at: [obstacle("Obstacle")], fetch: { _ in fetched.add(); return Self.photo }) {}
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(fetched.value, 1)
    }

    func testAPhotoThatWontLoadStopsBeingAskedFor() async {
        struct Failure: Error {}
        let spotter = ObstacleSpotter(analyze: { _ in [] })
        let fetched = Counter()
        for _ in 0..<6 {
            spotter.look(at: [obstacle("Obstacle")], fetch: { _ in fetched.add(); throw Failure() }) {}
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fetched.value, 3)
    }

    func testRecognizedNamesReachThePlan() throws {
        let json = #"{"pixelSize":5,"layers":[],"entities":[{"type":"obstacle","points":[50,50],"metaData":{"label":"Obstacle","id":"x","image":"y"}}]}"#
        var plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
        XCTAssertEqual(plan.obstacles.first?.symbol, FloorPlan.Obstacle.genericSymbol)
        plan.note(["x": "Sneaker"])
        XCTAssertEqual(plan.obstacles.first?.symbol, "shoe.fill")
        XCTAssertEqual(plan.obstacles.first?.title, "Sneaker")
    }

    private static let photo = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 1) { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func add() { value += 1 }
    }
}

final class CameraConeTests: XCTestCase {
    /// A 40 by 40 room of open floor, with the robot in the middle facing the top of the map.
    private func plan(heading: Int = 0, robot: Bool = true) throws -> FloorPlan {
        let rows = (0..<40).flatMap { [10, 10 + $0, 40] }
        let entity = robot ? #"{"type":"robot_position","points":[150,150],"metaData":{"angle":\#(heading)}}"# : ""
        let json = #"{"pixelSize":5,"layers":[{"type":"floor","compressedPixels":\#(rows)}],"entities":[\#(entity)]}"#
        return FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
    }

    func testSightStopsAtTheEdgeOfTheFloor() throws {
        let points = try XCTUnwrap(CameraCone.outline(in: plan()))
        for point in points {
            XCTAssertGreaterThanOrEqual(point.y, 9)
            XCTAssertLessThanOrEqual(point.x, 51)
            XCTAssertGreaterThanOrEqual(point.x, 9)
        }
    }

    func testTheConeFacesWhereTheRobotFaces() throws {
        let up = try XCTUnwrap(CameraCone.outline(in: plan(heading: 0)))
        let right = try XCTUnwrap(CameraCone.outline(in: plan(heading: 90)))
        XCTAssertLessThan(up[up.count / 2].y, 30, "heading 0 looks towards the top of the map")
        XCTAssertGreaterThan(right[right.count / 2].x, 30, "heading 90 looks to the right")
    }

    func testNoRobotMeansNoCone() throws {
        XCTAssertNil(CameraCone.outline(in: try plan(robot: false)))
    }
}

final class ModeTests: XCTestCase {
    func testModesReadFromVacuumToMop() {
        XCTAssertEqual(PresetKind.ordered(["vacuum_and_mop", "mop", "vacuum", "vacuum_then_mop"]),
                       ["vacuum", "vacuum_and_mop", "vacuum_then_mop", "mop"])
    }

    func testAnUnknownModeGoesLast() {
        XCTAssertEqual(PresetKind.ordered(["sweep_only", "mop", "vacuum"]), ["vacuum", "mop", "sweep_only"])
    }

    func testCustomIsNeverOffered() {
        XCTAssertEqual(PresetKind.ordered(["max", "custom", "off"]), ["off", "max"])
    }

    func testAddressesLoseAnyLoginTypedIntoThem() {
        XCTAssertEqual(Connection.normalize("http://user:pass@robot.lan/"), "http://robot.lan")
    }

    func testOnlyAnUnansweredRequestMightHaveArrived() {
        XCTAssertFalse(APIError(message: "", kind: .unreachable).mayHaveArrived)
        XCTAssertTrue(APIError(message: "", kind: .cutOff).noAnswer)
        XCTAssertTrue(APIError(message: "", kind: .tookTooLong).mayHaveArrived)
    }

    func testModeNames() {
        XCTAssertEqual(PresetKind.label("vacuum_and_mop"), "Vacuum + Mop")
        XCTAssertEqual(PresetKind.label("vacuum_then_mop"), "Vacuum Then Mop")
        XCTAssertEqual(PresetKind.label("wood_horizontal"), "Wood Horizontal")
    }
}

/// Valetudo's own rules for what each state of the robot offers.
final class ControlRuleTests: XCTestCase {
    private func state(_ status: String?, flag: String? = nil) -> RobotState {
        var state = RobotState()
        state.status = status
        state.flag = flag
        return state
    }

    func testStopFollowsTheWebRules() {
        XCTAssertFalse(state(nil).canStop, "not before the first state arrives")
        XCTAssertFalse(state("docked").canStop)
        XCTAssertFalse(state("idle").canStop)
        XCTAssertTrue(state("docked", flag: "resumable").canStop, "a job left at the dock can be ended")
        XCTAssertTrue(state("error").canStop)
        XCTAssertTrue(state("manual_control").canStop)
    }

    func testManualControlHasNoPause() {
        XCTAssertTrue(state("manual_control").isActive)
        XCTAssertFalse(state("manual_control").canPause)
        XCTAssertTrue(state("returning").canPause)
    }

    func testDockIsOnlyOfferedWhereItApplies() {
        for status in ["idle", "error", "paused"] { XCTAssertTrue(state(status).canDock, status) }
        for status in ["docked", "cleaning", "returning", "moving", "manual_control"] { XCTAssertFalse(state(status).canDock, status) }
    }

    @MainActor private func bar(_ rules: PickRules) -> BarModel {
        let picks = Picks()
        picks.rules = rules
        return picks.bar(name: { $0 })
    }

    @MainActor func testAJobLeftAtTheDockOffersResumeAndStop() {
        let model = bar(PickRules(rooms: true, basic: true, paused: true, stoppable: true))
        XCTAssertEqual(model.primary?.titles, ["Resume"])
        XCTAssertEqual(model.icons, [.stop, .dock, .controls])
    }

    @MainActor func testAnErrorStillOffersStop() {
        let model = bar(PickRules(rooms: true, basic: true, locate: true, stoppable: true))
        XCTAssertEqual(model.primary?.titles, ["Clean All"])
        XCTAssertEqual(model.icons, [.stop, .dock, .locate, .controls])
    }

    @MainActor func testDrivingKeepsStopButHasNoPause() {
        let model = bar(PickRules(basic: true, working: true, stoppable: true, manual: true))
        XCTAssertNil(model.primary)
        XCTAssertTrue(model.icons.contains(.stop), "Drive's last resort tells people to use Stop on Home")
    }

    @MainActor func testAReturningRobotCanStillBePaused() {
        let model = bar(PickRules(basic: true, working: true, paused: true, stoppable: true))
        XCTAssertEqual(model.primary?.titles, ["Pause"], "working comes first, because a returning job can also be resumable")
    }
}

/// Placing from 3D has to wait for the flat plan, which is the only thing that knows where it is on screen.
@MainActor
final class FlatPlanHandoffTests: XCTestCase {
    func testAPlacementWaitsForTheFlatPlan() async throws {
        let touches = PlanTouches()
        let plan = try PlanFixture.plan()
        let size = CGSize(width: 400, height: 400)
        var placed = 0
        touches.whenPlanIsShown { placed += 1 }
        await Task.yield()
        XCTAssertEqual(placed, 0, "nothing can be placed before the plan is laid out")

        let transform = PlanTransform(bounds: plan.bounds, size: size, insets: EdgeInsets(), zoom: 1, pan: .zero)
        touches.update(plan: plan, transform: transform, size: size, insets: EdgeInsets(), isZoomed: false)
        XCTAssertEqual(placed, 0, "not during the update itself, when picks can't change")

        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(placed, 1)

        touches.update(plan: plan, transform: transform, size: size, insets: EdgeInsets(), isZoomed: false)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(placed, 1, "it only happens once")
    }
}

/// These match what the web interface shows in its "Connect with other applications" dialog.
final class JobRequestTests: XCTestCase {
    private func decoded(_ request: JobRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.text.utf8)) as? [String: Any])
    }

    func testRooms() throws {
        let request = JobRequest.rooms(["4", "1"], passes: 2, customOrder: true)
        let body = try decoded(request)
        XCTAssertEqual(body["action"] as? String, "start_segment_action")
        XCTAssertEqual(body["segment_ids"] as? [String], ["4", "1"], "the order is the cleaning order")
        XCTAssertEqual(body["iterations"] as? Int, 2)
        XCTAssertEqual(body["customOrder"] as? Bool, true)
        XCTAssertEqual(request.path, "/api/v2/robot/capabilities/MapSegmentationCapability")
        XCTAssertFalse(request.usesCoordinates, "room ids survive small map changes, so the web gives no warning")
    }

    func testZonesAreSentInCentimetres() throws {
        let request = JobRequest.zones([CGRect(x: 10, y: 20, width: 30, height: 40)], passes: 3, pixelSize: 5)
        let body = try decoded(request)
        XCTAssertEqual(body["action"] as? String, "clean")
        XCTAssertEqual(body["iterations"] as? Int, 3)
        let zone = try XCTUnwrap((body["zones"] as? [[String: Any]])?.first)
        let points = try XCTUnwrap(zone["points"] as? [String: [String: Int]])
        XCTAssertEqual(points["pA"], ["x": 50, "y": 100])
        XCTAssertEqual(points["pB"], ["x": 200, "y": 100])
        XCTAssertEqual(points["pC"], ["x": 200, "y": 300])
        XCTAssertEqual(points["pD"], ["x": 50, "y": 300])
        XCTAssertEqual(request.path, "/api/v2/robot/capabilities/ZoneCleaningCapability")
        XCTAssertTrue(request.usesCoordinates)
    }

    func testGoTo() throws {
        let request = JobRequest.go(to: CGPoint(x: 10.4, y: 20), pixelSize: 5)
        let body = try decoded(request)
        XCTAssertEqual(body["action"] as? String, "goto")
        XCTAssertEqual(body["coordinates"] as? [String: Int], ["x": 52, "y": 100])
        XCTAssertEqual(request.path, "/api/v2/robot/capabilities/GoToLocationCapability")
        XCTAssertTrue(request.usesCoordinates)
    }

    func testTheWordingFollowsTheCount() {
        XCTAssertTrue(JobRequest.rooms(["1"], passes: 1, customOrder: false).purpose.contains("this room"))
        XCTAssertTrue(JobRequest.rooms(["1", "2"], passes: 1, customOrder: false).purpose.contains("these rooms"))
        let zone = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertTrue(JobRequest.zones([zone], passes: 1, pixelSize: 5).purpose.contains("this area"))
        XCTAssertTrue(JobRequest.zones([zone, zone], passes: 1, pixelSize: 5).purpose.contains("these areas"))
    }

    func testTwoLooksAtOneJobReadTheSame() {
        let first = JobRequest.rooms(["1", "2"], passes: 1, customOrder: false).text
        for _ in 0..<20 {
            XCTAssertEqual(JobRequest.rooms(["1", "2"], passes: 1, customOrder: false).text, first)
        }
    }

    @MainActor func testOnlyAPickHasARequestToShow() {
        let picks = Picks()
        picks.rules = PlanFixture.everything
        XCTAssertEqual(picks.bar(name: { $0 }).primary?.connects, false, "Clean All")

        picks.toggle("1")
        XCTAssertEqual(picks.bar(name: { $0 }).primary?.connects, true)

        picks.beginSending()
        XCTAssertEqual(picks.bar(name: { $0 }).primary?.connects, false, "Starting")
    }

    @MainActor func testCleaningEverythingHasNoRequest() {
        let store = RobotStore(client: Client(baseURL: "http://stub.invalid"))
        XCTAssertNil(store.request(for: .start))
        XCTAssertNotNil(store.request(for: .rooms(["1"], passes: 1)))
    }
}

/// Valetudo's achievement text is Apache-2.0, which requires its license to ship with the app.
final class NoticeTests: XCTestCase {
    func testValetudosLicenseShipsWithTheApp() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Valetudo-License", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("Sören Beye"))
    }
}
