import ObjectiveC
import SwiftUI
import XCTest
@testable import Valetudo

final class ValetudoTests: XCTestCase {
    func testAddressesAreNormalized() {
        XCTAssertEqual(Connection.normalize(" 192.168.1.20/ "), "http://192.168.1.20")
        XCTAssertEqual(Connection.normalize("robot.lan:8080"), "http://robot.lan:8080")
        XCTAssertEqual(Connection.normalize("https://robot.example/"), "https://robot.example")
    }

    func testRobotTimeCrossesMidnightBothWays() {
        // 23:30 Sunday, seven hours ahead, becomes 06:30 Monday.
        let forward = RobotTime.shift(days: [0], hour: 23, minute: 30, byMinutes: 420)
        XCTAssertEqual(forward.days, [1])
        XCTAssertEqual(forward.hour, 6)
        XCTAssertEqual(forward.minute, 30)

        // 01:00 Sunday, eight hours behind, becomes 17:00 Saturday.
        let back = RobotTime.shift(days: [0], hour: 1, minute: 0, byMinutes: -480)
        XCTAssertEqual(back.days, [6])
        XCTAssertEqual(back.hour, 17)
    }

    func testRobotTimeRoundTrips() {
        for offset in [-720, -480, 0, 330, 840] {
            let there = RobotTime.shift(days: [0, 3, 6], hour: 7, minute: 15, byMinutes: offset)
            let back = RobotTime.shift(days: there.days, hour: there.hour, minute: there.minute, byMinutes: -offset)
            XCTAssertEqual(back.days, [0, 3, 6])
            XCTAssertEqual(back.hour, 7)
            XCTAssertEqual(back.minute, 15)
        }
    }

    func testStateIgnoresUnknownAttributes() throws {
        let json = """
        [{"__class":"StatusStateAttribute","value":"docked","flag":"none"},
         {"__class":"BatteryStateAttribute","level":96.6,"flag":"charging"},
         {"__class":"DockComponentStateAttribute","type":"water_tank_clean","value":"empty"},
         {"__class":"SomethingNewStateAttribute","value":42}]
        """
        let state = RobotState(try JSONDecoder().decode([Attribute].self, from: Data(json.utf8)))
        XCTAssertEqual(state.status, "docked")
        XCTAssertEqual(state.battery, 97)
        XCTAssertTrue(state.charging)
        XCTAssertEqual(state.dockParts["water_tank_clean"], "empty")
    }

    func testMapDecodesBothPixelFormats() throws {
        let json = """
        {"pixelSize":5,"layers":[
          {"type":"segment","compressedPixels":[10,10,4,10,11,4],"metaData":{"segmentId":"7","name":"Kitchen"}},
          {"type":"wall","pixels":[9,9,9,10]}],
         "entities":[{"type":"robot_position","points":[60,55],"metaData":{"angle":90}}]}
        """
        let plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
        XCTAssertEqual(plan.rooms.first?.name, "Kitchen")
        XCTAssertEqual(plan.roomID(at: CGPoint(x: 11.5, y: 10.5)), "7")
        XCTAssertNil(plan.roomID(at: CGPoint(x: 40, y: 40)))
        XCTAssertEqual(plan.robot, CGPoint(x: 12, y: 11))
        XCTAssertFalse(plan.walls.isEmpty)
    }

    func testNumericSegmentIdsAreAccepted() throws {
        let json = #"{"pixelSize":5,"layers":[{"type":"segment","compressedPixels":[1,1,1],"metaData":{"segmentId":3}}],"entities":[]}"#
        let plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
        XCTAssertEqual(plan.rooms.first?.id, "3")
        XCTAssertEqual(plan.rooms.first?.name, "Room 3")
    }

    func testLabelStaysInsideAnLShapedRoom() {
        var cells: [(Int, Int)] = []
        for x in 0..<40 { for y in 0..<6 { cells.append((x, y)) } }
        for x in 0..<6 { for y in 6..<40 { cells.append((x, y)) } }
        let p = FloorPlan.labelPoint(cells)
        XCTAssertTrue(cells.contains { $0.0 == Int(p.x) && $0.1 == Int(p.y) })
    }

    func testEventsGetTheRepliesValetudoAccepts() throws {
        func event(_ kind: String) throws -> RobotEvent {
            try JSONDecoder().decode(RobotEvent.self, from: Data(#"{"__class":"\#(kind)","id":"a"}"#.utf8))
        }
        XCTAssertEqual(try event("ConsumableDepletedValetudoEvent").style, .consumable)
        XCTAssertEqual(try event("PendingMapChangeValetudoEvent").style, .pendingMap)
        XCTAssertEqual(try event("DustBinFullValetudoEvent").style, .dismiss)
    }

    func testRoutineEncodesTheFieldNamesTheRobotExpects() throws {
        var draft = RoutineDraft()
        draft.wholeHome = false
        draft.rooms = ["2"]
        draft.presets = [.fan: "high"]
        let data = try JSONEncoder().encode(draft.routine())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""custom_order":false"#))
        XCTAssertTrue(text.contains(#""segment_ids":["2"]"#))
        XCTAssertTrue(text.contains(#""type":"fan_speed_control""#))
    }

    func testDemuxerExtractsVideoAcrossChunks() {
        // One TS packet: PES header on PID 0x100, then eight bytes of video.
        var packet: [UInt8] = [0x47, 0x41, 0x00, 0x30, 166]
        packet += [UInt8](repeating: 0xFF, count: 166)
        packet += [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00]
        packet += [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(packet.count, 188)

        var demuxer = TransportDemuxer()
        var video = demuxer.feed(Data(packet[..<100]))
        XCTAssertTrue(video.isEmpty)
        video = demuxer.feed(Data(packet[100...]))
        XCTAssertEqual(Array(video), [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testShapesCanBePicked() {
        let wall = PlanShape(kind: .wall, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        XCTAssertTrue(wall.contains(CGPoint(x: 5, y: 1), tolerance: 2))
        XCTAssertFalse(wall.contains(CGPoint(x: 5, y: 5), tolerance: 2))
        let zone = PlanShape(kind: .noGo, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
        XCTAssertTrue(zone.contains(CGPoint(x: 5, y: 5), tolerance: 1))
    }

    func testVisionReturnsLabelsForAPhoto() async throws {
        let size = CGSize(width: 320, height: 240)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        // A plain image may have no confident labels, so this proves Vision runs without crashing.
        _ = await ImageLabeler.analyze(try XCTUnwrap(image.cgImage))
    }

    func testObstacleLabelsFromEveryBrandGetARealSymbol() {
        let labels = ["Cable (92%)", "Shoes (80%)", "Sock", "Fabric", "Furniture Leg", "Pet Bowl", "Pet house",
                      "Trash Can", "Trash can", "Toy", "Weighing scale", "Liquid Stain", "Dock", "Obstacle (90%)"]
        for label in labels {
            let symbol = FloorPlan.Obstacle.symbol(forLabel: label)
            XCTAssertNotNil(UIImage(systemName: symbol), "\(label) uses \(symbol), which doesn't exist")
        }
        XCTAssertEqual(FloorPlan.Obstacle.symbol(forLabel: "Cable (92%)"), "cable.connector")
        XCTAssertEqual(FloorPlan.Obstacle.symbol(forLabel: "Something New"), "exclamationmark")
    }

    func testRoomFactsAreDecoded() throws {
        let json = #"{"pixelSize":5,"layers":[{"type":"segment","compressedPixels":[0,0,40,0,1,40],"metaData":{"segmentId":"1","material":"tile","active":true}}],"entities":[]}"#
        let plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
        XCTAssertEqual(plan.rooms.first?.active, true)
        XCTAssertEqual(plan.rooms.first?.texture.isEmpty, false)
    }

    func testUnknownFloorTypesDrawNothing() {
        XCTAssertTrue(FloorPlan.texture(for: "generic", in: CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
        XCTAssertTrue(FloorPlan.texture(for: nil, in: CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
    }

    func testTargetsMustBeOnTheFloor() throws {
        let json = #"{"pixelSize":5,"layers":[{"type":"floor","compressedPixels":[10,10,5,10,11,5,10,12,5]},{"type":"wall","compressedPixels":[9,9,7]}],"entities":[]}"#
        let plan = FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))

        // On the floor: unchanged.
        XCTAssertEqual(plan.nearestFloor(to: CGPoint(x: 12.5, y: 11.5), within: 8), CGPoint(x: 12.5, y: 11.5))
        // Just outside: snaps to the closest floor cell.
        let snapped = try XCTUnwrap(plan.nearestFloor(to: CGPoint(x: 16.5, y: 11.5), within: 8))
        XCTAssertEqual(snapped, CGPoint(x: 14.5, y: 11.5))
        // Far outside: refused.
        XCTAssertNil(plan.nearestFloor(to: CGPoint(x: 60, y: 60), within: 8))

        XCTAssertTrue(plan.hasFloor(in: CGRect(x: 8, y: 8, width: 4, height: 4)))
        XCTAssertFalse(plan.hasFloor(in: CGRect(x: 30, y: 30, width: 10, height: 10)))
    }
}

// MARK: - Home: picks

/// Two 2 m rooms with a gap between them, 5 cm to the pixel, and a no-go area in the Hall.
enum PlanFixture {
    static func plan(rooms: Bool = true, floorOnly: Bool = false) throws -> FloorPlan {
        func rows(_ x: Int, _ width: Int) -> [Int] { (10..<50).flatMap { [x, $0, width] } }
        let kitchen = #"{"type":"segment","compressedPixels":\#(rows(10, 40)),"metaData":{"segmentId":"1","name":"Kitchen"}}"#
        let hall = #"{"type":"segment","compressedPixels":\#(rows(60, 40)),"metaData":{"segmentId":"2","name":"Hall"}}"#
        let floor = #"{"type":"floor","compressedPixels":\#(rows(10, 90))}"#
        let layers = rooms ? "\(kitchen),\(hall)" : floor
        let noGo = #"{"type":"no_go_area","points":[450,150,480,150,480,180,450,180]}"#
        let obstacle = #"{"type":"obstacle","points":[150,150],"metaData":{"label":"Shoe","id":"s"}}"#
        let json = #"{"pixelSize":5,"layers":[\#(layers)],"entities":[\#(noGo),\#(obstacle)]}"#
        return FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
    }

    /// The same home after a refresh that lost the Hall.
    static func kitchenOnly() throws -> FloorPlan {
        let rows = (10..<50).flatMap { [10, $0, 40] }
        let kitchen = #"{"type":"segment","compressedPixels":\#(rows),"metaData":{"segmentId":"1","name":"Kitchen"}}"#
        let json = #"{"pixelSize":5,"layers":[\#(kitchen)],"entities":[]}"#
        return FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8)))
    }

    static func emptyMap() throws -> FloorPlan {
        FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(#"{"pixelSize":5,"layers":[],"entities":[]}"#.utf8)))
    }

    static let everything = PickRules(rooms: true, zones: true, goTo: true, roomOrder: true, maxZones: 3,
                                      maxRoomPasses: 3, maxZonePasses: 2, basic: true, locate: true)
}

/// Every row of the design's transition table, in its order.
@MainActor
final class PicksTransitionTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!
    private let zone = CGRect(x: 20, y: 20, width: 20, height: 20)
    private let spot = CGPoint(x: 30, y: 30)

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
    }

    private func assertOneKind(file: StaticString = #filePath, line: UInt = #line) {
        let filled = [!picks.rooms.isEmpty, !picks.zones.isEmpty, picks.pin != nil].filter { $0 }.count
        XCTAssertLessThanOrEqual(filled, 1, "only one kind of pick can exist", file: file, line: line)
    }

    func testNothingThenTapRoomGivesRooms() {
        picks.toggle("1")
        XCTAssertEqual(picks.kind, .rooms)
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testNothingThenHoldGivesPin() {
        XCTAssertTrue(picks.beginHold(at: spot, on: plan))
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .pin)
        XCTAssertEqual(picks.pin, spot)
    }

    func testNothingThenDropPinGivesPin() {
        picks.dropPin(at: spot)
        XCTAssertEqual(picks.kind, .pin)
    }

    func testNothingThenStretchGivesZones() {
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertEqual(picks.zones, [CGRect(x: 30, y: 30, width: 15, height: 15)])
        XCTAssertEqual(picks.activeZone, 0)
    }

    func testNothingThenAddZoneGivesZones() {
        XCTAssertTrue(picks.addZone(zone))
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertEqual(picks.activeZone, 0)
    }

    func testNothingThenPrimaryStartsTheRobot() {
        XCTAssertEqual(picks.job(on: plan), .start)
    }

    func testTapOrderIsCleaningOrderAndRemovingRenumbers() {
        picks.toggle("2")
        picks.toggle("1")
        picks.toggle("3")
        XCTAssertEqual(picks.rooms, ["2", "1", "3"])
        picks.toggle("1")
        XCTAssertEqual(picks.rooms, ["2", "3"])
        XCTAssertEqual(picks.job(on: plan), .rooms(["2", "3"], passes: 1), "the order must reach the robot unchanged")
    }

    func testLastRoomOffGivesNothing() {
        picks.toggle("1")
        picks.toggle("1")
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testRoomsThenHoldGivesPinWithRoomsHeld() {
        picks.toggle("2")
        picks.toggle("1")
        _ = picks.beginHold(at: spot, on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .pin)
        XCTAssertEqual(picks.heldRooms, ["2", "1"])
        assertOneKind()
    }

    func testRoomsThenDropPinHoldsThem() {
        picks.toggle("1")
        picks.dropPin(at: spot)
        XCTAssertEqual(picks.heldRooms, ["1"])
        assertOneKind()
    }

    func testRoomsThenStretchGivesZonesWithRoomsHeld() {
        picks.toggle("1")
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertEqual(picks.heldRooms, ["1"])
        assertOneKind()
    }

    func testRoomsThenAddZoneHoldsThem() {
        picks.toggle("1")
        picks.addZone(zone)
        XCTAssertEqual(picks.heldRooms, ["1"])
        assertOneKind()
    }

    func testRoomsThenClearGivesNothing() {
        picks.toggle("1")
        picks.clear()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(picks.heldRooms.isEmpty)
    }

    func testZonesThenHoldAddsAnotherDefaultZoneAtTheSpot() {
        picks.addZone(zone)
        XCTAssertTrue(picks.beginHold(at: CGPoint(x: 80, y: 30), on: plan))
        XCTAssertEqual(picks.kind, .zones)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.zones.count, 2)
        XCTAssertEqual(picks.zones[1].width, 30, "1.5 m at 5 cm a pixel")
        XCTAssertEqual(picks.zones[1].midX, 80)
        XCTAssertEqual(picks.activeZone, 1)
    }

    func testZonesThenStretchAddsAnotherZone() {
        picks.addZone(zone)
        _ = picks.beginHold(at: CGPoint(x: 70, y: 20), on: plan)
        picks.stretch(to: CGPoint(x: 90, y: 40), on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.zones.last, CGRect(x: 70, y: 20, width: 20, height: 20))
    }

    func testZonesStopAtTheMaximum() {
        picks.rules.maxZones = 1
        picks.addZone(zone)
        XCTAssertFalse(picks.addZone(zone))
        XCTAssertFalse(picks.beginHold(at: spot, on: plan), "a hold at the maximum must add nothing")
        XCTAssertEqual(picks.zones.count, 1)
    }

    func testCapsuleDeleteKeepsTheOthers() {
        picks.addZone(zone)
        picks.addZone(zone.offsetBy(dx: 5, dy: 5))
        picks.deleteZone(at: 1)
        XCTAssertEqual(picks.zones, [zone])
        XCTAssertNil(picks.activeZone)
    }

    func testDeletingTheLastZoneRestoresHeldRooms() {
        picks.toggle("2")
        picks.toggle("1")
        picks.addZone(zone)
        picks.deleteZone(at: 0)
        XCTAssertEqual(picks.rooms, ["2", "1"])
        XCTAssertTrue(picks.heldRooms.isEmpty)
    }

    func testZonesThenClearRestoresHeldRooms() {
        picks.toggle("1")
        picks.addZone(zone)
        picks.clear()
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testZonesThenClearWithNothingHeldGivesNothing() {
        picks.addZone(zone)
        picks.clear()
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testPinThenClearRestoresHeldRooms() {
        picks.toggle("1")
        picks.dropPin(at: spot)
        picks.clear()
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertNil(picks.pin)
    }

    func testPinThenClearWithNothingHeldGivesNothing() {
        picks.dropPin(at: spot)
        picks.clear()
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testPinThenStretchGivesZonesAndRoomsStayHeld() {
        picks.toggle("1")
        picks.dropPin(at: spot)
        _ = picks.beginHold(at: CGPoint(x: 20, y: 20), on: plan)
        XCTAssertEqual(picks.pin, CGPoint(x: 20, y: 20), "the pin jumps to the hold")
        picks.stretch(to: CGPoint(x: 40, y: 40), on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertNil(picks.pin)
        XCTAssertEqual(picks.heldRooms, ["1"])
    }

    func testAcceptedJobClearsEverythingAndDiscardsHeldRooms() {
        picks.toggle("1")
        picks.passes = 3
        picks.addZone(zone)
        picks.beginSending()
        XCTAssertEqual(picks.kind, .zones, "picks stay until the robot accepts")
        picks.finishSending(accepted: true)
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(picks.heldRooms.isEmpty)
        picks.toggle("1")
        XCTAssertEqual(picks.passes, 1, "passes reset with the picks")
    }

    func testRefusedJobKeepsPicks() {
        picks.toggle("1")
        picks.beginSending()
        XCTAssertTrue(picks.sending)
        picks.finishSending(accepted: false)
        XCTAssertFalse(picks.sending)
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testRobotStartingAloneClearsPicksWithANote() {
        picks.toggle("1")
        picks.dropPin(at: spot)
        picks.robotStartedAlone()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(picks.heldRooms.isEmpty)
        XCTAssertEqual(picks.note?.text, "Cleaning started, so your picks were cleared.")
    }

    func testARobotThatStartsMovingAloneDoesntClaimToBeCleaning() {
        picks.toggle("1")
        picks.robotStartedAlone(cleaning: false)
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertEqual(picks.note?.text, "The robot started moving, so your picks were cleared.")
    }

    func testRobotStartingAloneWithNothingPickedSaysNothing() {
        picks.robotStartedAlone()
        XCTAssertNil(picks.note)
    }

    func testFiveMinutesInTheBackgroundClearsPicks() {
        let start = Date()
        picks.toggle("1")
        picks.dropPin(at: spot)
        picks.enteredBackground(at: start)
        picks.becameActive(at: start.addingTimeInterval(300))
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(picks.heldRooms.isEmpty)
    }

    func testAShortTripToTheBackgroundKeepsPicks() {
        let start = Date()
        picks.toggle("1")
        picks.enteredBackground(at: start)
        picks.becameActive(at: start.addingTimeInterval(299))
        XCTAssertEqual(picks.rooms, ["1"])
    }
}

/// How a hold turns into a pin or a zone, and how it's undone.
@MainActor
final class PicksHoldTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!
    private let spot = CGPoint(x: 30, y: 30)

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
    }

    func testComingBackInsideMakesItAPinAgain() {
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        XCTAssertNil(picks.pin)
        XCTAssertEqual(picks.kind, .zones, "the bar already shows a zone while stretching")
        picks.unstretch(on: plan)
        XCTAssertEqual(picks.pin, spot)
        XCTAssertNil(picks.draft)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .pin)
    }

    func testComingBackInsideWithZonesKeepsTheDefaultZone() {
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.unstretch(on: plan)
        XCTAssertEqual(picks.draft?.width, 30)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.zones.count, 2)
    }

    func testCancellingAHoldBringsBackTheRooms() {
        picks.toggle("1")
        _ = picks.beginHold(at: spot, on: plan)
        picks.cancelGesture()
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertNil(picks.pin)
    }

    func testCancellingAStretchReturnsToWhereItStarted() {
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.cancelGesture()
        XCTAssertEqual(picks.zones.count, 1)
        XCTAssertNil(picks.draft)
        XCTAssertFalse(picks.adding)
    }

    func testCancellingAHoldThatMovedAPinPutsItBack() {
        picks.dropPin(at: spot)
        _ = picks.beginHold(at: CGPoint(x: 20, y: 20), on: plan)
        picks.cancelGesture()
        XCTAssertEqual(picks.pin, spot)
    }

    func testAThinStretchKeepsTheMinimumSide() {
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 30), on: plan)
        picks.endHold(on: plan)
        let zone = try? XCTUnwrap(picks.zones.first)
        XCTAssertEqual(zone?.height, 4, "20 cm at 5 cm a pixel")
        XCTAssertEqual(zone?.width, 15)
    }

    func testAStretchThatEndsWithNoFloorIsDroppedWithANote() throws {
        let holed = try PlanFixture.plan(rooms: true)
        picks.toggle("1")
        // A start in the gap between the rooms, stretched only across the gap.
        _ = picks.beginHold(at: CGPoint(x: 51, y: 5), on: holed)
        picks.stretch(to: CGPoint(x: 58, y: 8), on: holed)
        picks.endHold(on: holed)
        XCTAssertTrue(picks.zones.isEmpty)
        XCTAssertEqual(picks.rooms, ["1"], "the rooms come back because no zone was made")
        XCTAssertEqual(picks.note?.text, "Draw the zone on the floor plan")
    }

    func testARoomThatVanishesDuringAHoldDoesntComeBackOnCancel() {
        picks.toggle("1")
        picks.toggle("2")
        _ = picks.beginHold(at: spot, on: plan)
        XCTAssertEqual(picks.keepRooms(in: ["1"]), ["2"])
        picks.cancelGesture()
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertTrue(picks.heldRooms.isEmpty)
    }

    func testAHeldRoomThatVanishesDuringAHoldDoesntComeBackOnCancel() {
        picks.toggle("1")
        picks.toggle("2")
        picks.dropPin(at: spot)
        _ = picks.beginHold(at: CGPoint(x: 20, y: 20), on: plan)
        _ = picks.keepRooms(in: ["1"])
        picks.cancelGesture()
        XCTAssertEqual(picks.heldRooms, ["1"])
    }

    func testAStretchCountsTowardTheZoneLimit() {
        picks.rules.maxZones = 2
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        XCTAssertFalse(picks.zonesAtLimit)
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        XCTAssertTrue(picks.zonesAtLimit)
        XCTAssertFalse(picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20)))
        picks.endHold(on: plan)
        XCTAssertEqual(picks.zones.count, 2)
    }

    func testAJobWaitsForAFirstStretchInsteadOfSendingNoZones() {
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertNil(picks.job(on: plan))
        XCTAssertNil(picks.note, "a tap mid-stretch isn't a mistake worth a note")
        picks.endHold(on: plan)
        XCTAssertEqual(picks.job(on: plan), .zones([CGRect(x: 30, y: 30, width: 15, height: 15)], passes: 1))
    }

    func testAJobWaitsForAStretchThatAddsToOtherZones() {
        let first = CGRect(x: 70, y: 20, width: 20, height: 20)
        picks.addZone(first)
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        XCTAssertNil(picks.job(on: plan), "the bar says two zones here, so sending one would be wrong")
        picks.cancelGesture()
        XCTAssertEqual(picks.job(on: plan), .zones([first], passes: 1))
    }

    func testAJobWaitsForAHeldPinToLand() {
        _ = picks.beginHold(at: spot, on: plan)
        XCTAssertNil(picks.job(on: plan))
        picks.endHold(on: plan)
        XCTAssertNotNil(picks.job(on: plan))
    }

    func testResetDuringAHoldLeavesNothingBehind() {
        _ = picks.beginHold(at: spot, on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.reset()
        picks.stretch(to: CGPoint(x: 46, y: 46), on: plan)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertNil(picks.draft)
    }
}

/// Moving, resizing and everything that keeps picks on the map.
@MainActor
final class PicksFloorTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!
    private let zone = CGRect(x: 20, y: 20, width: 20, height: 20)

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
    }

    func testADragDoesntTouchTheZoneUntilLift() {
        picks.addZone(zone)
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: CGPoint(x: 25, y: 25), on: plan)
        XCTAssertEqual(picks.zones, [zone], "what's sent stays valid during a drag")
        XCTAssertEqual(picks.draft?.origin, CGPoint(x: 25, y: 25))
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.zones[0].origin, CGPoint(x: 25, y: 25))
        XCTAssertNil(picks.draft)
    }

    func testAZoneLeftWithNoFloorSpringsBack() {
        picks.addZone(zone)
        picks.beginEdit(zone: 0)
        picks.resizeEdit(from: CGPoint(x: 52, y: 12), to: CGPoint(x: 57, y: 20), on: plan)
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.zones, [zone])
        XCTAssertEqual(picks.note?.text, "Draw the zone on the floor plan")
    }

    func testAMovedZoneStopsAtThePlansEdge() {
        picks.addZone(zone)
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: CGPoint(x: -500, y: -500), on: plan)
        XCTAssertEqual(picks.draft?.minX, plan.bounds.minX)
        XCTAssertEqual(picks.draft?.minY, plan.bounds.minY)
    }

    func testResizingKeepsTheMinimumSide() {
        picks.addZone(zone)
        picks.beginEdit(zone: 0)
        picks.resizeEdit(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20.5, y: 20.5), on: plan)
        XCTAssertEqual(picks.draft?.width, 4)
        XCTAssertEqual(picks.draft?.height, 4)
    }

    func testCancellingAnEditPutsTheZoneBack() {
        picks.addZone(zone)
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: CGPoint(x: 30, y: 30), on: plan)
        picks.cancelGesture()
        XCTAssertEqual(picks.zones, [zone])
        XCTAssertNil(picks.draft)
        XCTAssertNil(picks.editing)
    }

    func testAPinDraggedOffTheFloorGoesBackToItsLastFloorPoint() {
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        picks.dragPin(to: CGPoint(x: 45, y: 30), on: plan)
        XCTAssertFalse(picks.pinOffFloor)
        picks.dragPin(to: CGPoint(x: 55, y: 30), on: plan)
        XCTAssertTrue(picks.pinOffFloor)
        XCTAssertEqual(picks.pin, CGPoint(x: 30, y: 30), "a job sent mid-drag can't use the spot off the floor")
        picks.endPinDrag()
        XCTAssertEqual(picks.pin, CGPoint(x: 45, y: 30))
        XCTAssertFalse(picks.pinOffFloor)
        XCTAssertNil(picks.pinDrag)
    }

    func testCancellingAPinDragLeavesThePinWhereItStarted() {
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        picks.dragPin(to: CGPoint(x: 45, y: 30), on: plan)
        picks.cancelGesture()
        XCTAssertEqual(picks.pin, CGPoint(x: 30, y: 30))
    }

    func testAPinCantBeDraggedPastThePlan() {
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        picks.dragPin(to: CGPoint(x: 9000, y: 30), on: plan)
        XCTAssertEqual(picks.pinDrag?.x, plan.bounds.maxX)
    }

    func testDeletingTheZoneBeingDraggedEndsTheDrag() {
        let other = CGRect(x: 70, y: 20, width: 20, height: 20)
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        picks.addZone(other)
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: CGPoint(x: 25, y: 25), on: plan)
        picks.deleteZone(at: 0)
        XCTAssertNil(picks.editing)
        XCTAssertNil(picks.draft)
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.zones, [other], "the other zone mustn't pick up the deleted one's rect")
    }

    func testDeletingAnEarlierZoneKeepsTheDragOnItsZone() {
        let moved = CGRect(x: 75, y: 25, width: 20, height: 20)
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        picks.beginEdit(zone: 1)
        picks.moveEdit(to: moved.origin, on: plan)
        picks.deleteZone(at: 0)
        XCTAssertEqual(picks.editing, 0)
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.zones, [moved])
    }

    func testDeletingALaterZoneLeavesTheDragAlone() {
        let moved = CGRect(x: 25, y: 25, width: 20, height: 20)
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: moved.origin, on: plan)
        picks.deleteZone(at: 1)
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.zones, [moved])
    }

    func testAZoneCantBeDeletedFromUnderAStretch() {
        picks.toggle("1")
        picks.addZone(CGRect(x: 70, y: 20, width: 20, height: 20))
        _ = picks.beginHold(at: CGPoint(x: 30, y: 30), on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.deleteZone(at: 0)
        picks.endHold(on: plan)
        XCTAssertEqual(picks.zones.count, 2)
        XCTAssertTrue(picks.rooms.isEmpty, "rooms and zones must never exist together")
    }

    func testAJobWaitsForADraggedZoneToLand() {
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        picks.beginEdit(zone: 0)
        picks.moveEdit(to: CGPoint(x: 25, y: 25), on: plan)
        XCTAssertNil(picks.job(on: plan), "what's drawn must be what's sent")
        picks.endEdit(on: plan)
        XCTAssertEqual(picks.job(on: plan), .zones([CGRect(x: 25, y: 25, width: 20, height: 20)], passes: 1))
    }

    func testAJobWaitsForADraggedPinToLand() {
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        picks.dragPin(to: CGPoint(x: 20, y: 20), on: plan)
        XCTAssertNil(picks.job(on: plan))
        picks.endPinDrag()
        XCTAssertNotNil(picks.job(on: plan))
    }

    func testNoZonesIsNeverAZoneJob() {
        XCTAssertEqual(picks.job(on: plan), .start, "nothing picked is the idle job, not an empty zone list")
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        XCTAssertNotEqual(picks.job(on: plan), .zones([], passes: 1))
    }

    func testAJobIsRefusedIfThePinIsOffTheFloor() {
        picks.dropPin(at: CGPoint(x: 55, y: 30))
        XCTAssertNil(picks.job(on: plan))
        XCTAssertEqual(picks.note?.text, "Pick a spot on the floor plan")
    }

    func testAJobIsRefusedIfAZoneHasNoFloor() {
        picks.addZone(CGRect(x: 51, y: 20, width: 8, height: 8))
        XCTAssertNil(picks.job(on: plan))
        XCTAssertEqual(picks.note?.text, "Draw the zone on the floor plan")
    }

    func testAJobIsRefusedWithoutAPlan() {
        picks.addZone(zone)
        XCTAssertNil(picks.job(on: nil))
    }

    func testAJobIsRefusedInANoGoArea() {
        let inside = CGPoint(x: 93, y: 33)
        picks.dropPin(at: inside)
        XCTAssertTrue(picks.pinIsBlocked(on: plan))
        XCTAssertNil(picks.job(on: plan))
    }

    func testCleanHereSendsADefaultSquareAndGoHereThePoint() {
        let spot = CGPoint(x: 30, y: 30)
        picks.passes = 2
        picks.dropPin(at: spot)
        XCTAssertEqual(picks.job(on: plan), .zones([CGRect(x: 15, y: 15, width: 30, height: 30)], passes: 2))
        picks.setVerb(.go)
        XCTAssertEqual(picks.job(on: plan), .go(spot))
    }

    func testADefaultSquareStaysInsideThePlan() {
        let rect = Picks.square(around: CGPoint(x: 12, y: 12), on: plan)
        XCTAssertEqual(rect.minX, plan.bounds.minX)
        XCTAssertEqual(rect.width, 30)
    }

    func testPlacementPrefersTheLastPickedRoom() {
        let spot = Picks.placement(on: plan, after: "2", near: .zero)
        XCTAssertEqual(plan.roomID(at: spot ?? .zero), "2")
    }

    func testPlacementFallsBackToTheNearestLabel() {
        let spot = Picks.placement(on: plan, after: nil, near: CGPoint(x: 95, y: 30))
        XCTAssertEqual(plan.roomID(at: spot ?? .zero), "2")
    }

    func testPlacementWithoutRoomsFindsFloorFromFarAway() throws {
        let bare = try PlanFixture.plan(rooms: false)
        let spot = try XCTUnwrap(Picks.placement(on: bare, after: nil, near: CGPoint(x: -300, y: -300)))
        XCTAssertNotNil(bare.nearestFloor(to: spot, within: 0))
    }

    func testVoiceNudgeMovesBy25Centimetres() {
        picks.addZone(zone)
        XCTAssertTrue(picks.nudgeZone(0, dx: PickSize.voiceStep, dy: 0, on: plan))
        XCTAssertEqual(picks.zones[0].minX, 25)
    }

    func testVoiceNudgeStopsAtThePlansEdge() {
        picks.addZone(zone)
        for _ in 0..<50 { picks.nudgeZone(0, dx: 0, dy: -PickSize.voiceStep, on: plan) }
        XCTAssertGreaterThanOrEqual(picks.zones[0].minY, plan.bounds.minY)
    }

    func testVoiceNudgeRefusesToLeaveTheFloor() {
        picks.addZone(CGRect(x: 51, y: 20, width: 8, height: 8))
        XCTAssertFalse(picks.nudgeZone(0, dx: 0, dy: PickSize.voiceStep, on: plan))
        XCTAssertEqual(picks.zones[0].minX, 51)
    }

    func testVoiceNudgeMovesThePinBy25Centimetres() {
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertTrue(picks.nudgePin(dx: 25, dy: 0, on: plan))
        XCTAssertEqual(picks.pin, CGPoint(x: 35, y: 30))
    }

    func testVoiceNudgeRefusesToTakeThePinOffTheFloor() {
        picks.dropPin(at: CGPoint(x: 49, y: 30))
        XCTAssertFalse(picks.nudgePin(dx: 25, dy: 0, on: plan))
        XCTAssertEqual(picks.pin, CGPoint(x: 49, y: 30))
        XCTAssertEqual(picks.note?.text, "Pick a spot on the floor plan")
    }

    func testVoiceResizeKeepsTheCentreAndTheMinimum() {
        picks.addZone(zone)
        XCTAssertTrue(picks.growZone(0, by: PickSize.voiceStep, on: plan))
        XCTAssertEqual(picks.zones[0].width, 25)
        XCTAssertEqual(picks.zones[0].midX, zone.midX)
        for _ in 0..<20 { picks.growZone(0, by: -PickSize.voiceStep, on: plan) }
        XCTAssertEqual(picks.zones[0].width, 4)
    }
}

/// Passes, map refreshes and the words on the bar.
@MainActor
final class PicksWordingTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
    }

    func testCountsAreWords() {
        XCTAssertEqual((1...4).map(PickWording.times), ["Once", "Twice", "3 Times", "4 Times"])
    }

    func testTitlesFallBackInTheOwnersOrder() {
        XCTAssertEqual(PickWording.roomTitles(names: ["Kitchen"], passes: 2), ["Clean Kitchen Twice", "Clean Room Twice", "Clean Twice"])
        XCTAssertEqual(PickWording.roomTitles(names: ["Kitchen"], passes: 1), ["Clean Kitchen", "Clean Room", "Clean"])
        XCTAssertEqual(PickWording.roomTitles(names: ["A", "B"], passes: 3).first, "Clean 2 Rooms 3 Times")
        XCTAssertEqual(PickWording.zoneTitles(count: 1, passes: 2).first, "Clean Zone Twice")
        XCTAssertEqual(PickWording.zoneTitles(count: 2, passes: 1).first, "Clean 2 Zones")
        XCTAssertEqual(PickWording.pinTitles(passes: 2).first, "Clean Here Twice")
    }

    func testTheSpokenJobIsSpelledOut() {
        XCTAssertEqual(PickWording.spokenRooms(names: ["Kitchen", "Hall"], ordered: true, passes: 2), "Clean Kitchen, then Hall, twice")
        XCTAssertEqual(PickWording.spokenRooms(names: ["Kitchen", "Hall"], ordered: false, passes: 1), "Clean Kitchen and Hall")
    }

    func testSizesUseTheLocalUnit() {
        let rect = CGRect(x: 0, y: 0, width: 32, height: 42)
        let metric = Locale(identifier: "en_GB"), american = Locale(identifier: "en_US")
        XCTAssertEqual(PickWording.size(rect, pixelSize: 5, locale: metric), "1.6 by 2.1 m")
        XCTAssertEqual(PickWording.size(rect, pixelSize: 5, locale: metric, spoken: true), "1.6 by 2.1 metres")
        XCTAssertEqual(PickWording.size(rect, pixelSize: 5, locale: american), "5.2 by 6.9 ft")
    }

    func testPassesClampWhenTheKindOfPickChanges() {
        picks.toggle("1")
        picks.passes = 3
        XCTAssertEqual(picks.maxPasses, 3)
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        XCTAssertEqual(picks.passes, 2, "zones only go up to 2 here")
        picks.clear()
        XCTAssertEqual(picks.passes, 3, "the rooms come back with their own count")
    }

    func testGoHereHasNoPasses() {
        picks.passes = 2
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(picks.maxPasses, 2)
        picks.setVerb(.go)
        XCTAssertEqual(picks.maxPasses, 1)
        XCTAssertEqual(picks.passes, 1)
    }

    func testClearingToNothingResetsPasses() {
        picks.toggle("1")
        picks.passes = 3
        picks.clear()
        picks.toggle("1")
        XCTAssertEqual(picks.passes, 1)
    }

    func testPinDefaultsFollowWhatTheRobotCanDo() {
        picks.rules.zones = false
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(picks.verb, .go)
        picks.clear()
        picks.rules.zones = true
        picks.rules.goTo = false
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(picks.verb, .clean)
    }

    func testMovingARoomChangesTheOrderSent() {
        picks.selectAll(["1", "2", "3"])
        picks.moveRooms(from: [2], to: 0)
        XCTAssertEqual(picks.job(on: plan), .rooms(["3", "1", "2"], passes: 1))
    }

    func testSelectAllKeepsTheOrderSoFar() {
        picks.toggle("3")
        picks.selectAll(["1", "2", "3"])
        XCTAssertEqual(picks.rooms, ["3", "1", "2"])
    }

    func testVanishedRoomsDropOutAndTheNumbersShift() {
        picks.toggle("1")
        picks.toggle("2")
        picks.toggle("3")
        XCTAssertEqual(picks.keepRooms(in: ["2", "3"]), ["1"])
        XCTAssertEqual(picks.rooms, ["2", "3"])
    }

    func testVanishedHeldRoomsDropOutToo() {
        picks.toggle("1")
        picks.toggle("2")
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(picks.keepRooms(in: ["2"]), ["1"])
        picks.clear()
        XCTAssertEqual(picks.rooms, ["2"])
    }

    func testGoneNotesNameTheRooms() {
        XCTAssertEqual(PickNote.gone(["Kitchen"]), "Kitchen is no longer on the plan.")
        XCTAssertEqual(PickNote.gone(["Kitchen", "Hall"]), "Kitchen and Hall are no longer on the plan.")
    }

    func testZoneLimitNotes() {
        XCTAssertEqual(PickNote.zoneLimit(1), "This robot cleans one zone at a time.")
        XCTAssertEqual(PickNote.zoneLimit(4), "This robot cleans up to 4 zones at once.")
    }

    func testClearNamesWhatItBringsBack() {
        XCTAssertEqual(picks.clearSymbol, "xmark")
        picks.toggle("1")
        XCTAssertEqual(picks.clearLabel, "Clear")
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(picks.clearSymbol, "arrow.uturn.backward")
        XCTAssertEqual(picks.clearLabel, "Clear Pin and Return to Rooms")
        picks.clear()
        picks.addZone(CGRect(x: 20, y: 20, width: 20, height: 20))
        XCTAssertEqual(picks.clearLabel, "Clear Zones and Return to Rooms")
    }

    func testANoteOnlyDismissesItself() throws {
        picks.say("One")
        let first = try XCTUnwrap(picks.note)
        picks.say("Two")
        picks.dismiss(first)
        XCTAssertEqual(picks.note?.text, "Two")
    }
}

/// A job in flight. The lock is checked in one place, so these go straight at the model.
@MainActor
final class PicksLockTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!
    private let zone = CGRect(x: 20, y: 20, width: 20, height: 20)
    private let other = CGRect(x: 70, y: 20, width: 20, height: 20)
    private let spot = CGPoint(x: 30, y: 30)

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
    }

    func testRoomsDontChangeWhileSending() {
        picks.toggle("1")
        picks.toggle("2")
        picks.passes = 2
        picks.beginSending()
        picks.toggle("1")
        picks.selectAll(["1", "2", "3"])
        picks.moveRooms(from: [1], to: 0)
        picks.clear()
        picks.passes = 3
        XCTAssertFalse(picks.dropPin(at: spot))
        XCTAssertFalse(picks.addZone(zone))
        XCTAssertEqual(picks.rooms, ["1", "2"])
        XCTAssertEqual(picks.kind, .rooms)
        XCTAssertEqual(picks.passes, 2)
    }

    func testZonesDontChangeWhileSending() {
        picks.addZone(zone)
        picks.addZone(other)
        picks.beginSending()
        picks.deleteZone(at: 0)
        picks.activate(zone: 0)
        XCTAssertFalse(picks.nudgeZone(1, dx: 25, dy: 0, on: plan))
        XCTAssertFalse(picks.growZone(1, by: 25, on: plan))
        XCTAssertFalse(picks.addZone(zone))
        picks.clear()
        XCTAssertEqual(picks.zones, [zone, other])
        XCTAssertEqual(picks.activeZone, 1)
    }

    func testAPinDoesntChangeWhileSending() {
        picks.dropPin(at: spot)
        picks.beginSending()
        picks.setVerb(.go)
        XCTAssertFalse(picks.nudgePin(dx: 25, dy: 0, on: plan))
        XCTAssertFalse(picks.dropPin(at: CGPoint(x: 20, y: 20)))
        picks.clear()
        XCTAssertEqual(picks.pin, spot)
        XCTAssertEqual(picks.verb, .clean)
    }

    func testARefusedJobLeavesExactlyWhatWasSentAndUnlocks() {
        picks.toggle("1")
        picks.addZone(zone)
        picks.addZone(other)
        let sent = picks.job(on: plan)
        picks.beginSending()
        picks.deleteZone(at: 1)
        picks.clear()
        picks.finishSending(accepted: false)
        XCTAssertEqual(picks.job(on: plan), sent)
        picks.deleteZone(at: 1)
        XCTAssertEqual(picks.zones, [zone], "the lock lifts with the answer")
    }

    func testAnAcceptedJobClearsEvenThoughTheLockIsOn() {
        picks.toggle("1")
        picks.beginSending()
        picks.finishSending(accepted: true)
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testAMapRefreshStillDropsAVanishedRoomWhileSending() {
        picks.toggle("1")
        picks.toggle("2")
        picks.beginSending()
        XCTAssertEqual(picks.keepRooms(in: ["1"]), ["2"])
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testSelectAllIsRefusedWhileWorking() {
        picks.rules.working = true
        picks.selectAll(["1", "2"])
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testSelectAllWorksWhilePaused() {
        picks.rules.paused = true
        picks.selectAll(["1", "2"])
        XCTAssertEqual(picks.rooms, ["1", "2"])
    }
}

/// A new map arriving under what's already picked.
@MainActor
final class PicksRefreshTests: XCTestCase {
    private var picks: Picks!
    private var plan: FloorPlan!
    private var smaller: FloorPlan!
    private let kitchenZone = CGRect(x: 20, y: 20, width: 20, height: 20)
    private let hallZone = CGRect(x: 70, y: 20, width: 20, height: 20)

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
        plan = try PlanFixture.plan()
        smaller = try PlanFixture.kitchenOnly()
    }

    func testAPinStillOnTheFloorStaysPut() {
        let spot = CGPoint(x: 30.25, y: 30.25)
        picks.dropPin(at: spot)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertEqual(picks.pin, spot)
        XCTAssertNil(picks.note)
    }

    func testAPinJustOffTheNewFloorMovesOntoIt() throws {
        picks.dropPin(at: CGPoint(x: 55, y: 30))
        picks.keepOnFloor(of: smaller, reach: 8)
        let moved = try XCTUnwrap(picks.pin)
        XCTAssertNotNil(smaller.nearestFloor(to: moved, within: 0))
        XCTAssertLessThan(moved.x, 50)
        XCTAssertNil(picks.note, "it's still where it was, near enough")
    }

    func testAPinFarFromTheNewFloorGoesWithANoteAndRoomsComeBack() {
        picks.toggle("1")
        picks.dropPin(at: CGPoint(x: 80, y: 30))
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertNil(picks.pin)
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertTrue(picks.heldRooms.isEmpty)
        XCTAssertEqual(picks.note?.text, "Pick a spot on the floor plan")
    }

    func testAZoneLeftWithNoFloorGoesAndTheOthersStay() {
        picks.addZone(hallZone)
        picks.addZone(kitchenZone)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertEqual(picks.zones, [kitchenZone])
        XCTAssertEqual(picks.activeZone, 0, "the active zone keeps its place as the list closes up")
        XCTAssertEqual(picks.note?.text, "Draw the zone on the floor plan")
    }

    func testTheLastZoneGoingBringsBackHeldRooms() {
        picks.toggle("1")
        picks.addZone(hallZone)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertTrue(picks.zones.isEmpty)
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertEqual(picks.kind, .rooms)
    }

    func testAZoneWithSomeFloorLeftStaysExactlyWhereItIs() {
        let straddling = CGRect(x: 40, y: 20, width: 30, height: 20)
        picks.addZone(straddling)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertEqual(picks.zones, [straddling], "zones are kept by map pixel")
        XCTAssertNil(picks.note)
    }

    func testAnEmptyMapClearsAPinAndGivesBackRooms() throws {
        picks.toggle("1")
        picks.dropPin(at: CGPoint(x: 30, y: 30))
        picks.keepOnFloor(of: try PlanFixture.emptyMap(), reach: 8)
        XCTAssertNil(picks.pin)
        XCTAssertEqual(picks.rooms, ["1"], "rooms can still be cleaned from the robot's own list")
    }

    func testAnEmptyMapClearsZones() throws {
        picks.addZone(kitchenZone)
        picks.keepOnFloor(of: try PlanFixture.emptyMap(), reach: 8)
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testAnEmptyMapEndsAStretch() throws {
        _ = picks.beginHold(at: CGPoint(x: 30, y: 30), on: plan)
        picks.stretch(to: CGPoint(x: 45, y: 45), on: plan)
        picks.keepOnFloor(of: nil, reach: 8)
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertFalse(picks.adding)
        XCTAssertEqual(picks.job(on: plan), .start, "and the primary isn't left waiting for a lift")
    }

    func testAnEmptyMapLeavesRoomsAlone() throws {
        picks.toggle("1")
        picks.keepOnFloor(of: try PlanFixture.emptyMap(), reach: 8)
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertNil(picks.note)
    }

    func testAGestureIsLeftToItsOwnCheckAtLift() {
        picks.addZone(hallZone)
        picks.beginEdit(zone: 0)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertEqual(picks.zones, [hallZone])
        picks.endEdit(on: smaller)
        picks.keepOnFloor(of: smaller, reach: 8)
        XCTAssertTrue(picks.zones.isEmpty)
    }

    func testAPinLeftOffTheFloorDisablesThePrimary() {
        picks.dropPin(at: CGPoint(x: 80, y: 30))
        XCTAssertFalse(picks.pinIsBlocked(on: plan))
        XCTAssertTrue(picks.pinIsBlocked(on: smaller))
    }
}

// MARK: - Home: touches on the plan

/// Shared set-up: the fixture plan filling a 400 by 300 view, with nothing around it.
@MainActor
class PlanTouchCase: XCTestCase {
    var touches: PlanTouches!
    var plan: FloorPlan!
    var haptics: [PlanHaptic] = []
    var opened: [FloorPlan.Obstacle] = []
    var spoken: [String] = []
    var teachingDrags = 0
    var holdsUsed = 0
    var roomsPicked = 0

    var picks: Picks { touches.picks }

    override func setUp() async throws {
        haptics = []
        opened = []
        spoken = []
        teachingDrags = 0
        holdsUsed = 0
        roomsPicked = 0
        touches = PlanTouches()
        touches.picks.rules = PlanFixture.everything
        touches.haptic = { [unowned self] in haptics.append($0) }
        touches.onObstacle = { [unowned self] in opened.append($0) }
        touches.announce = { [unowned self] in spoken.append($0) }
        touches.onFailedDrag = { [unowned self] in teachingDrags += 1 }
        touches.onHeld = { [unowned self] in holdsUsed += 1 }
        touches.onRoomPicked = { [unowned self] in roomsPicked += 1 }
        touches.roomName = { $0 == "1" ? "Kitchen" : "Hall" }
        try load(PlanFixture.plan())
    }

    func load(_ plan: FloorPlan, zoomed: Bool = false, zoom: CGFloat = 1) {
        self.plan = plan
        let size = CGSize(width: 400, height: 300)
        let transform = PlanTransform(bounds: plan.bounds, size: size, zoom: zoom)
        touches.update(plan: plan, transform: transform, size: size, insets: EdgeInsets(), isZoomed: zoomed)
    }

    /// A map pixel, as a point on screen.
    func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { touches.transform!.toView(CGPoint(x: x, y: y)) }

    func zone(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGRect { CGRect(x: x, y: y, width: side, height: side) }
}

final class PlanTapTests: PlanTouchCase {
    func testATapPicksTheRoomAndNothingStarts() {
        touches.tap(at: v(15, 15))
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertEqual(haptics, [.selection])
        XCTAssertEqual(roomsPicked, 1)
    }

    func testTappingAgainTakesItOut() {
        touches.tap(at: v(15, 15))
        touches.tap(at: v(15, 15))
        XCTAssertTrue(picks.rooms.isEmpty)
    }

    func testTapOrderIsKept() {
        touches.tap(at: v(90, 15))
        touches.tap(at: v(15, 15))
        XCTAssertEqual(picks.rooms, ["2", "1"])
    }

    func testATapJustOffARoomFindsIt() {
        touches.tap(at: v(52, 15))
        XCTAssertEqual(picks.rooms, ["1"], "this catches taps on walls and doorways")
    }

    func testATapFarFromAnyRoomDoesNothingAndNeverClears() {
        touches.tap(at: v(15, 15))
        touches.tap(at: v(55, -30))
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testALabelCatchesTapsOutsideASmallRoom() throws {
        // At this zoom the closet is about 21pt tall, so its label counts as 44pt tall.
        let closet = #"{"type":"segment","compressedPixels":[10,50,40,10,51,40,10,52,40,10,53,40,10,54,40],"metaData":{"segmentId":"9","name":"Closet"}}"#
        let big = #"{"type":"segment","compressedPixels":\#((0..<40).flatMap { [10, 100 + $0, 90] }),"metaData":{"segmentId":"8","name":"Big"}}"#
        let json = #"{"pixelSize":5,"layers":[\#(closet),\#(big)],"entities":[]}"#
        load(FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8))))
        let label = try XCTUnwrap(plan.rooms.first { $0.id == "9" }?.label)
        let above = v(label.x, label.y)
        XCTAssertNil(plan.roomID(at: touches.transform!.toMap(CGPoint(x: above.x, y: above.y - 18))), "the tap misses the room itself")
        XCTAssertEqual(touches.room(at: CGPoint(x: above.x, y: above.y - 18)), "9")
    }

    func testTheNearerOfTwoOverlappingLabelsWins() throws {
        let left = #"{"type":"segment","compressedPixels":[10,10,3,10,11,3],"metaData":{"segmentId":"1","name":"Left room"}}"#
        let right = #"{"type":"segment","compressedPixels":[14,10,3,14,11,3],"metaData":{"segmentId":"2","name":"Right room"}}"#
        let far = #"{"type":"segment","compressedPixels":[100,100,3],"metaData":{"segmentId":"3","name":"Far"}}"#
        let json = #"{"pixelSize":5,"layers":[\#(left),\#(right),\#(far)],"entities":[]}"#
        load(FloorPlan(try JSONDecoder().decode(RawMap.self, from: Data(json.utf8))))
        let labels = plan.rooms.map { v($0.label.x, $0.label.y) }
        XCTAssertEqual(touches.room(at: CGPoint(x: labels[0].x - 1, y: labels[0].y)), "1")
        XCTAssertEqual(touches.room(at: CGPoint(x: labels[1].x + 1, y: labels[1].y)), "2")
    }

    func testATapOnThePinDoesNothing() {
        picks.toggle("1")
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        let tip = v(80, 40)
        touches.tap(at: tip)
        touches.tap(at: CGPoint(x: tip.x, y: tip.y - PlanPin.headRise))
        XCTAssertEqual(picks.kind, .pin)
    }

    func testATapAwayRemovesThePinBringsRoomsBackAndStops() {
        picks.toggle("1")
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        touches.tap(at: v(15, 15))
        XCTAssertNil(picks.pin)
        XCTAssertEqual(picks.rooms, ["1"], "the tap must not also toggle the room it landed on")
    }

    func testATapOnAZoneMakesItActive() {
        picks.addZone(zone(15, 15, 20))
        picks.addZone(zone(70, 15, 20))
        touches.tap(at: v(20, 20))
        XCTAssertEqual(picks.activeZone, 0)
    }

    func testATapOffTheZonesOnlyDeactivatesThenTheNextGivesTheNote() {
        picks.addZone(zone(15, 15, 10))
        touches.tap(at: v(90, 40))
        XCTAssertNil(picks.activeZone)
        XCTAssertNil(picks.note)
        XCTAssertEqual(picks.zones.count, 1)
        touches.tap(at: v(90, 40))
        XCTAssertEqual(picks.note?.text, "Clear zones to pick rooms.")
        XCTAssertTrue(picks.rooms.isEmpty)
    }

    func testAnObstacleOpensItsPhoto() {
        touches.tap(at: v(30, 30))
        XCTAssertEqual(opened.map(\.id), ["s"])
        XCTAssertTrue(picks.rooms.isEmpty, "obstacles sit on top of rooms")
    }

    func testAnObstacleIsReachedWithin14Points() {
        touches.tap(at: CGPoint(x: v(30, 30).x + 13, y: v(30, 30).y))
        XCTAssertEqual(opened.count, 1)
    }

    func testAnObstacleOpensWhileWorking() {
        picks.rules.working = true
        touches.tap(at: v(30, 30))
        XCTAssertEqual(opened.count, 1)
    }

    func testAnObstacleOpensWhileSending() {
        picks.toggle("2")
        picks.beginSending()
        touches.tap(at: v(30, 30))
        XCTAssertEqual(opened.count, 1)
    }

    func testWhileWorkingARoomTapOnlyGivesTheNote() {
        picks.rules.working = true
        touches.tap(at: v(15, 15))
        XCTAssertEqual(picks.note?.text, "Pause first to choose something else.")
        XCTAssertTrue(picks.rooms.isEmpty)
        XCTAssertTrue(haptics.isEmpty, "the note isn't worth a buzz")
    }

    func testWhilePausedARoomTapPicks() {
        picks.rules.paused = true
        touches.tap(at: v(15, 15))
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testARobotWithoutRoomsIgnoresRoomTaps() {
        picks.rules.rooms = false
        touches.tap(at: v(15, 15))
        XCTAssertTrue(picks.rooms.isEmpty)
        XCTAssertNil(picks.note)
    }

    func testPicksDontChangeWhileAJobIsBeingSent() {
        picks.toggle("1")
        picks.beginSending()
        touches.tap(at: v(90, 15))
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testASheetRowWhileSendingLeavesThePinAlone() {
        picks.toggle("1")
        picks.dropPin(at: CGPoint(x: 15, y: 15))
        picks.beginSending()
        touches.pick(room: "1")
        XCTAssertNotNil(picks.pin)
        XCTAssertEqual(picks.heldRooms, ["1"])
        XCTAssertTrue(spoken.isEmpty)
    }

    func testPickingAnnouncesWhatsNowAvailable() {
        touches.tap(at: v(15, 15))
        XCTAssertEqual(spoken.last, "Kitchen picked. Clean Kitchen available.")
        touches.tap(at: v(90, 15))
        XCTAssertEqual(spoken.last, "Hall picked. Clean 2 Rooms available.")
        touches.tap(at: v(90, 15))
        touches.tap(at: v(15, 15))
        XCTAssertEqual(spoken.last, "Kitchen not picked.")
    }
}

final class PlanHoldTests: PlanTouchCase {
    func testAHoldDropsAPinWithAMediumBuzz() {
        touches.holdBegan(at: v(15, 15))
        touches.holdEnded()
        XCTAssertEqual(picks.pin, CGPoint(x: 15, y: 15).floorSnapped(on: plan))
        XCTAssertEqual(haptics, [.hold])
        XCTAssertEqual(holdsUsed, 1)
    }

    func testAHoldJustOffTheFloorLandsOnTheFloor() throws {
        touches.holdBegan(at: v(52, 15))
        touches.holdEnded()
        let pin = try XCTUnwrap(picks.pin)
        XCTAssertNotNil(plan.nearestFloor(to: pin, within: 0), "no pin may sit off the floor")
    }

    func testAHoldFarOffTheFloorDoesNothingAtAll() {
        touches.holdBegan(at: v(55, -30))
        touches.holdEnded()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertNil(picks.note)
    }

    func testAHoldWhileWorkingGivesTheNoteWithNoBuzz() {
        picks.rules.working = true
        touches.holdBegan(at: v(15, 15))
        touches.holdEnded()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertEqual(picks.note?.text, "Pause first to choose something else.")
        XCTAssertTrue(haptics.isEmpty)
    }

    func testAHoldOffTheFloorWhileWorkingSaysNothing() {
        picks.rules.working = true
        touches.holdBegan(at: v(55, -30))
        XCTAssertNil(picks.note)
    }

    func testARobotWithNeitherZonesNorGoToIgnoresHolds() {
        picks.rules.zones = false
        picks.rules.goTo = false
        touches.holdBegan(at: v(15, 15))
        touches.holdEnded()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertTrue(haptics.isEmpty)
    }

    func testMovingPast16PointsStretchesAndComingBackUndoesIt() {
        let start = v(15, 15)
        touches.holdBegan(at: start)
        touches.holdMoved(to: CGPoint(x: start.x + 15, y: start.y))
        XCTAssertEqual(picks.kind, .pin)
        touches.holdMoved(to: CGPoint(x: start.x + 17, y: start.y))
        XCTAssertEqual(picks.kind, .zones)
        XCTAssertNotNil(picks.draft)
        touches.holdMoved(to: CGPoint(x: start.x + 10, y: start.y))
        XCTAssertEqual(picks.kind, .pin)
        XCTAssertNil(picks.draft)
    }

    func testAStretchUsesTheStartAsOneCornerAndTheFingerAsTheOther() {
        touches.holdBegan(at: v(15, 15))
        touches.holdMoved(to: v(35, 40))
        touches.holdEnded()
        XCTAssertEqual(picks.zones.first?.minX ?? 0, 15, accuracy: 0.01)
        XCTAssertEqual(picks.zones.first?.maxY ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(picks.activeZone, 0)
    }

    func testAStretchStopsAtWhatsOnScreen() {
        touches.holdBegan(at: v(15, 15))
        touches.holdMoved(to: CGPoint(x: 9000, y: 9000))
        touches.holdEnded()
        let map = touches.transform!.toMap(CGPoint(x: 400, y: 300))
        XCTAssertLessThanOrEqual(picks.zones[0].maxX, map.x + 0.01)
        XCTAssertLessThanOrEqual(picks.zones[0].maxY, plan.bounds.maxY + 0.01)
    }

    func testWithoutZonesMovingAfterAHoldDragsThePin() {
        picks.rules.zones = false
        touches.holdBegan(at: v(15, 15))
        touches.holdMoved(to: v(40, 40))
        touches.holdEnded()
        XCTAssertEqual(picks.kind, .pin)
        XCTAssertEqual(picks.pin?.x ?? 0, 40, accuracy: 0.01)
        XCTAssertNil(picks.draft)
    }

    func testAHoldAtTheZoneLimitWarnsAndAddsNothing() {
        picks.rules.maxZones = 2
        picks.addZone(zone(15, 15, 10))
        picks.addZone(zone(30, 15, 10))
        touches.holdBegan(at: v(80, 30))
        touches.holdEnded()
        XCTAssertEqual(picks.zones.count, 2)
        XCTAssertEqual(haptics, [.warning])
        XCTAssertEqual(picks.note?.text, "This robot cleans up to 2 zones at once.")
    }

    func testAHoldOnAHandleResizesRatherThanAddsAZone() {
        picks.addZone(zone(15, 15, 30))
        let corner = v(45, 45)
        touches.holdBegan(at: corner)
        touches.holdMoved(to: v(40, 40))
        touches.holdEnded()
        XCTAssertEqual(picks.zones.count, 1)
        XCTAssertEqual(picks.zones[0].maxX, 40, accuracy: 0.01)
        XCTAssertEqual(haptics, [.hold])
    }

    func testAHoldOnThePinHeadDragsItWithoutAJump() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        let head = CGPoint(x: v(80, 40).x, y: v(80, 40).y - PlanPin.headRise)
        touches.holdBegan(at: head)
        touches.holdMoved(to: CGPoint(x: head.x - 40, y: head.y))
        touches.holdEnded()
        XCTAssertEqual(picks.pin?.y ?? 0, 40, accuracy: 0.01)
        XCTAssertLessThan(picks.pin?.x ?? 99, 80)
    }

    func testAHoldWaitsWhileTheRoomsSheetIsOpen() {
        touches.sheetIsOpen = true
        touches.holdBegan(at: v(15, 15))
        touches.holdEnded()
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testAHoldDoesNothingWhileSending() {
        picks.toggle("1")
        picks.beginSending()
        touches.holdBegan(at: v(90, 15))
        touches.holdEnded()
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testARefusedHoldLeavesTheFingerFreeToPan() {
        picks.rules.working = true
        touches.holdBegan(at: v(15, 15))
        XCTAssertFalse(touches.ownsTheTouch, "resting before a pan mustn't freeze the map")
        XCTAssertEqual(picks.note?.text, "Pause first to choose something else.")
    }

    func testAHoldOffTheFloorLeavesTheFingerFreeToPan() {
        touches.holdBegan(at: CGPoint(x: 0, y: 0))
        XCTAssertFalse(touches.ownsTheTouch)
    }

    func testAHoldAtTheZoneLimitLeavesTheFingerFreeToPan() {
        picks.rules.maxZones = 1
        picks.addZone(zone(15, 15, 20))
        picks.deactivateZone()
        touches.holdBegan(at: v(80, 30))
        XCTAssertFalse(touches.ownsTheTouch)
    }

    func testAHoldThatPlacedSomethingOwnsTheFinger() {
        touches.holdBegan(at: v(15, 15))
        XCTAssertTrue(touches.ownsTheTouch)
        touches.holdEnded()
        XCTAssertFalse(touches.ownsTheTouch)
    }

    func testAHoldThatGrabbedSomethingOwnsTheFinger() {
        picks.addZone(zone(15, 15, 30))
        touches.holdBegan(at: v(30, 30))
        XCTAssertTrue(touches.ownsTheTouch)
    }

    func testASecondFingerBringsEverythingBack() {
        picks.toggle("1")
        touches.holdBegan(at: v(90, 15))
        touches.holdMoved(to: v(95, 40))
        touches.cancel()
        XCTAssertEqual(picks.rooms, ["1"])
        XCTAssertEqual(picks.kind, .rooms)
        XCTAssertNil(picks.draft)
    }

    func testCancelWithNothingGoingOnChangesNothing() {
        picks.toggle("1")
        touches.cancel()
        XCTAssertEqual(picks.rooms, ["1"])
    }
}

final class PlanDragTests: PlanTouchCase {
    func testHitTestingFindsWhatsOnTop() {
        picks.addZone(zone(15, 15, 30))
        XCTAssertEqual(touches.hit(v(45, 45)), .handle(.bottomRight))
        XCTAssertEqual(touches.hit(v(15, 15)), .handle(.topLeft))
        XCTAssertEqual(touches.hit(v(30, 30)), .zone)
        XCTAssertEqual(touches.hit(v(80, 30)), .plan)
    }

    func testAnInactiveZoneCantBeDragged() {
        picks.addZone(zone(15, 15, 30))
        picks.deactivateZone()
        XCTAssertEqual(touches.hit(v(30, 30)), .plan)
    }

    func testASmallZoneKeepsOneHandleSoItsBodyStaysDraggable() {
        picks.addZone(zone(15, 15, 10))
        XCTAssertEqual(touches.hit(v(25, 25)), .handle(.bottomRight))
        XCTAssertEqual(touches.hit(v(20, 20)), .zone, "the middle of a small zone is still its body")
        XCTAssertNotEqual(touches.hit(v(15, 15)), .handle(.topLeft))
        XCTAssertEqual(ZoneCorner.shown(on: CGRect(x: 0, y: 0, width: 65, height: 200)), [.bottomRight])
        XCTAssertEqual(ZoneCorner.shown(on: CGRect(x: 0, y: 0, width: 66, height: 66)).count, 4)
    }

    func testDraggingAHandleResizesAgainstTheOppositeCorner() {
        picks.addZone(zone(15, 15, 30))
        XCTAssertTrue(touches.dragBegan(from: v(45, 45), at: v(45, 45)))
        touches.dragMoved(to: v(40, 35))
        touches.dragEnded()
        XCTAssertEqual(picks.zones[0].minX, 15, accuracy: 0.01)
        XCTAssertEqual(picks.zones[0].minY, 15, accuracy: 0.01)
        XCTAssertEqual(picks.zones[0].maxX, 40, accuracy: 0.01)
        XCTAssertEqual(picks.zones[0].maxY, 35, accuracy: 0.01)
    }

    func testDraggingTheBodyMovesItRelativeToTheTouch() {
        picks.addZone(zone(15, 15, 20))
        let down = v(25, 25), start = v(27, 25)
        XCTAssertTrue(touches.dragBegan(from: down, at: start))
        touches.dragMoved(to: start)
        XCTAssertEqual(picks.draft?.minX ?? 0, 15, accuracy: 0.01, "the zone must not jump when the drag begins")
        touches.dragMoved(to: v(30, 30))
        touches.dragEnded()
        XCTAssertEqual(picks.zones[0].minX, 18, accuracy: 0.01)
        XCTAssertEqual(picks.zones[0].minY, 20, accuracy: 0.01)
    }

    func testDraggingAZoneOffTheFloorSpringsItBack() {
        picks.addZone(zone(15, 15, 6))
        let start = v(18, 18)
        touches.dragBegan(from: start, at: start)
        touches.dragMoved(to: v(54, 3))
        touches.dragEnded()
        XCTAssertEqual(picks.zones, [zone(15, 15, 6)])
        XCTAssertEqual(picks.note?.text, "Draw the zone on the floor plan")
    }

    func testDraggingThePinMovesItRelativeToTheTouch() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        let head = CGPoint(x: v(80, 40).x, y: v(80, 40).y - PlanPin.headRise)
        XCTAssertTrue(touches.dragBegan(from: head, at: head))
        touches.dragMoved(to: CGPoint(x: head.x - 20, y: head.y))
        touches.dragEnded()
        XCTAssertEqual(picks.pin?.y ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(picks.pin?.x ?? 0, 80 - 20 / touches.transform!.scale, accuracy: 0.01)
    }

    func testAPinDraggedOffTheFloorTurnsGreyAndGoesBack() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        touches.dragBegan(from: v(80, 40), at: v(80, 40))
        touches.dragMoved(to: v(55, 40))
        XCTAssertTrue(picks.pinOffFloor)
        touches.dragEnded()
        XCTAssertFalse(picks.pinOffFloor)
        XCTAssertNotNil(plan.nearestFloor(to: picks.pin ?? .zero, within: 0))
    }

    func testAnyDragElsewhereIsLeftToTheCamera() {
        XCTAssertFalse(touches.dragBegan(from: v(15, 15), at: v(15, 20)))
    }

    func testALongDragAtFitZoomTeachesTheHoldOnce() {
        touches.dragBegan(from: v(15, 15), at: v(15, 15))
        touches.dragMoved(to: CGPoint(x: v(15, 15).x + 39, y: v(15, 15).y))
        XCTAssertEqual(teachingDrags, 0)
        touches.dragMoved(to: CGPoint(x: v(15, 15).x + 40, y: v(15, 15).y))
        touches.dragMoved(to: CGPoint(x: v(15, 15).x + 80, y: v(15, 15).y))
        XCTAssertEqual(teachingDrags, 1)
    }

    func testADragStartedOffTheFloorTeachesNothing() {
        touches.dragBegan(from: v(55, 30), at: v(55, 30))
        touches.dragMoved(to: CGPoint(x: 300, y: 200))
        XCTAssertEqual(teachingDrags, 0)
    }

    func testADragWhileZoomedTeachesNothing() {
        load(plan, zoomed: true, zoom: 2)
        touches.dragBegan(from: v(15, 15), at: v(15, 15))
        touches.dragMoved(to: CGPoint(x: 300, y: 200))
        XCTAssertEqual(teachingDrags, 0)
    }

    func testASecondFingerPutsADraggedZoneBack() {
        picks.addZone(zone(15, 15, 20))
        touches.dragBegan(from: v(25, 25), at: v(25, 25))
        touches.dragMoved(to: v(30, 30))
        touches.cancel()
        XCTAssertEqual(picks.zones, [zone(15, 15, 20)])
        XCTAssertNil(picks.draft)
    }

    func testASecondFingerPutsADraggedPinBack() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        touches.dragBegan(from: v(80, 40), at: v(80, 40))
        touches.dragMoved(to: v(70, 30))
        touches.cancel()
        XCTAssertEqual(picks.pin, CGPoint(x: 80, y: 40))
    }

    func testAJobWaitsForAFingerThatHasGrabbedThePinButNotMovedIt() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        touches.dragBegan(from: v(80, 40), at: v(80, 40))
        XCTAssertNil(picks.job(on: plan))
        touches.dragEnded()
        XCTAssertEqual(picks.pin, CGPoint(x: 80, y: 40))
        XCTAssertNotNil(picks.job(on: plan))
    }

    func testAJobWaitsForAFingerRestingOnThePin() {
        picks.dropPin(at: CGPoint(x: 80, y: 40))
        touches.holdBegan(at: v(80, 40))
        XCTAssertNil(picks.job(on: plan))
        touches.cancel()
        XCTAssertEqual(picks.pin, CGPoint(x: 80, y: 40))
        XCTAssertNotNil(picks.job(on: plan))
    }

    func testAJobMidDragLeavesNothingBehind() {
        picks.addZone(zone(15, 15, 20))
        touches.dragBegan(from: v(25, 25), at: v(25, 25))
        picks.reset()
        touches.dragMoved(to: v(30, 30))
        touches.dragEnded()
        XCTAssertEqual(picks.kind, .nothing)
        XCTAssertNil(picks.draft)
    }
}

final class PlanPlacementTests: PlanTouchCase {
    func testDropPinHoldsPickedRoomsAndUsesTheLastLabel() {
        picks.toggle("1")
        picks.toggle("2")
        touches.dropPin()
        XCTAssertEqual(picks.heldRooms, ["1", "2"])
        XCTAssertEqual(plan.roomID(at: picks.pin ?? .zero), "2")
    }

    func testAddZonePlacesAnActiveDefaultZone() {
        touches.addZone()
        XCTAssertEqual(picks.zones.first?.width, 30)
        XCTAssertEqual(picks.activeZone, 0)
    }

    func testAddZoneHoldsPickedRooms() {
        picks.toggle("1")
        touches.addZone()
        XCTAssertEqual(picks.heldRooms, ["1"])
    }

    func testThePlusAddsTheNextZone24PointsAway() {
        picks.addZone(zone(20, 20, 30))
        touches.addZone()
        XCTAssertEqual(picks.zones.count, 2)
        XCTAssertEqual(picks.zones[1].minX - 20, 24 / touches.transform!.scale, accuracy: 0.01)
    }

    func testTheNextZoneStaysOnThePlanAtItsEdge() throws {
        picks.addZone(zone(70, 20, 30))
        touches.addZone()
        let rect = try XCTUnwrap(picks.zones.last)
        XCTAssertTrue(plan.bounds.contains(rect))
        XCTAssertTrue(plan.hasFloor(in: rect))
        XCTAssertNotEqual(rect, picks.zones.first)
    }

    func testThePlusAtTheLimitWarnsAndShowsTheNote() {
        picks.rules.maxZones = 1
        picks.addZone(zone(20, 20, 30))
        touches.addZone()
        XCTAssertEqual(picks.zones.count, 1)
        XCTAssertEqual(haptics, [.warning])
        XCTAssertEqual(picks.note?.text, "This robot cleans one zone at a time.")
    }

    func testThePlusCantPassTheLimitDuringAStretch() {
        picks.rules.maxZones = 2
        picks.addZone(zone(70, 15, 20))
        touches.holdBegan(at: v(15, 15))
        touches.holdMoved(to: v(40, 40))
        touches.addZone()
        touches.holdEnded()
        XCTAssertEqual(picks.zones.count, 2)
        XCTAssertEqual(haptics.last, .warning)
    }

    func testThePlusTellsVoiceOverWhereThePinWent() {
        picks.toggle("1")
        touches.dropPin()
        XCTAssertEqual(spoken.last, "Pin in Kitchen.")
    }

    func testThePlusTellsVoiceOverAboutEachZone() {
        touches.addZone()
        XCTAssertTrue(spoken.last?.hasPrefix("Zone") == true)
        spoken = []
        touches.addZone()
        XCTAssertEqual(spoken.count, 1)
        XCTAssertTrue(spoken.last?.hasPrefix("Zone") == true)
    }

    func testVoiceOverIsToldNothingWhenNothingWasPlaced() throws {
        picks.toggle("1")
        picks.beginSending()
        touches.dropPin()
        touches.addZone()
        touches.dropPin(in: try XCTUnwrap(plan.rooms.first))
        touches.addZone(in: try XCTUnwrap(plan.rooms.first))
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testAPinIsNamedAfterItsRoomWhereThereIsOne() {
        XCTAssertEqual(touches.pinSpeech(at: CGPoint(x: 15, y: 15)), "Pin in Kitchen")
        XCTAssertEqual(touches.pinSpeech(at: CGPoint(x: 400, y: 400)), "Pin")
    }

    func testANewMapChecksPicksWithinTheFingersReach() throws {
        let smaller = try PlanFixture.kitchenOnly()
        let reach = 22 / touches.transform!.scale
        picks.dropPin(at: CGPoint(x: 50 + reach * 0.5, y: 30))
        touches.planChanged(to: smaller)
        XCTAssertNotNil(picks.pin, "a pin within 22pt of the floor moves onto it")
        XCTAssertNotNil(smaller.nearestFloor(to: picks.pin ?? .zero, within: 0))
        picks.clear()
        picks.dropPin(at: CGPoint(x: 50 + reach * 2, y: 30))
        touches.planChanged(to: smaller)
        XCTAssertNil(picks.pin)
    }

    func testPlacementIsAlwaysOnTheFloor() throws {
        touches.dropPin()
        XCTAssertNotNil(plan.nearestFloor(to: try XCTUnwrap(picks.pin), within: 0))
        picks.clear()
        touches.addZone()
        XCTAssertTrue(plan.hasFloor(in: try XCTUnwrap(picks.zones.first)))
    }

    func testVoiceOverPlacesAPinInARoom() throws {
        let room = try XCTUnwrap(plan.rooms.first)
        touches.dropPin(in: room)
        XCTAssertEqual(plan.roomID(at: picks.pin ?? .zero), room.id)
        XCTAssertEqual(spoken.last, "Pin in Kitchen.")
    }

    func testVoiceOverMovesAnExistingPinToAnotherRoom() throws {
        picks.dropPin(at: CGPoint(x: 15, y: 15))
        touches.dropPin(in: try XCTUnwrap(plan.rooms.last))
        XCTAssertEqual(plan.roomID(at: picks.pin ?? .zero), "2")
    }

    func testVoiceOverAddsAZoneInARoom() throws {
        touches.addZone(in: try XCTUnwrap(plan.rooms.first))
        XCTAssertEqual(picks.zones.count, 1)
        XCTAssertTrue(spoken.last?.hasPrefix("Zone in Kitchen, ") == true)
    }

    func testVoiceOverIsToldAboutTheZoneLimit() throws {
        picks.rules.maxZones = 1
        picks.addZone(zone(20, 20, 30))
        touches.addZone(in: try XCTUnwrap(plan.rooms.last))
        XCTAssertEqual(picks.zones.count, 1)
        XCTAssertEqual(picks.note?.text, "This robot cleans one zone at a time.")
    }

    func testActivatingARoomWithVoiceOverRemovesAPinLikeATap() {
        picks.dropPin(at: CGPoint(x: 15, y: 15))
        touches.pick(room: "1")
        XCTAssertNil(picks.pin)
        XCTAssertEqual(spoken.last, "Pin removed.")
    }

    func testZoneSpeechNamesTheRoom() {
        XCTAssertTrue(touches.speech(for: zone(15, 15, 20)).hasPrefix("Zone in Kitchen, "))
        XCTAssertTrue(touches.speech(for: zone(400, 400, 20)).hasPrefix("Zone, "))
    }
}

/// Where a capsule goes, how pinching keeps its anchor, and the plus button's choices.
final class PlanGeometryTests: XCTestCase {
    private let insets = EdgeInsets(top: 12, leading: 14, bottom: 78, trailing: 14)
    private let area = CGSize(width: 393, height: 600)
    private let size = CGSize(width: 150, height: 44)

    func testACapsuleSitsAboveItsTarget() {
        let spot = PlanFloat.origin(for: size, beside: CGRect(x: 100, y: 200, width: 60, height: 60), in: area, insets: insets)
        XCTAssertEqual(spot.y, 200 - 8 - 44)
        XCTAssertEqual(spot.x, 130 - 75)
    }

    func testACapsuleFlipsBelowNearTheTop() {
        let spot = PlanFloat.origin(for: size, beside: CGRect(x: 100, y: 30, width: 60, height: 60), in: area, insets: insets)
        XCTAssertEqual(spot.y, 98)
    }

    func testACapsuleStaysInsideThePlansWidth() {
        let left = PlanFloat.origin(for: size, beside: CGRect(x: -40, y: 200, width: 60, height: 60), in: area, insets: insets)
        XCTAssertEqual(left.x, 8)
        let right = PlanFloat.origin(for: size, beside: CGRect(x: 380, y: 200, width: 60, height: 60), in: area, insets: insets)
        XCTAssertEqual(right.x, 393 - 8 - 150)
    }

    func testACapsuleStaysAboveTheBarWhenItsTargetIsHuge() {
        let spot = PlanFloat.origin(for: size, beside: CGRect(x: 0, y: 0, width: 393, height: 900), in: area, insets: insets)
        XCTAssertLessThanOrEqual(spot.y + size.height, area.height - insets.bottom)
    }

    func testAPinchKeepsTheMapPointUnderTheFingers() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let view = CGSize(width: 400, height: 300)
        let centre = CGPoint(x: 200, y: 150)
        let start = PlanTransform(bounds: bounds, size: view, zoom: 2, pan: CGSize(width: 30, height: -10))
        let fingers = CGPoint(x: 120, y: 90)
        let under = start.toMap(fingers)
        let pan = PlanZoom.pan(start: fingers, now: fingers, centre: centre, pan: CGSize(width: 30, height: -10), ratio: 1.5)
        let end = PlanTransform(bounds: bounds, size: view, zoom: 3, pan: pan)
        XCTAssertEqual(end.toView(under).x, fingers.x, accuracy: 0.001)
        XCTAssertEqual(end.toView(under).y, fingers.y, accuracy: 0.001)
    }

    func testMovingFingersCarryThePlanWithThem() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let view = CGSize(width: 400, height: 300)
        let start = PlanTransform(bounds: bounds, size: view, zoom: 2)
        let down = CGPoint(x: 120, y: 90), now = CGPoint(x: 160, y: 130)
        let under = start.toMap(down)
        let pan = PlanZoom.pan(start: down, now: now, centre: CGPoint(x: 200, y: 150), pan: .zero, ratio: 1)
        XCTAssertEqual(PlanTransform(bounds: bounds, size: view, zoom: 2, pan: pan).toView(under).x, now.x, accuracy: 0.001)
    }

    /// With one id in both sections, `List` moves the row across and it never gets a drag handle.
    func testARoomIsADifferentRowInEachSectionOfTheSheet() {
        let room = RoomChoice(id: "1", name: "Kitchen")
        XCTAssertNotEqual(room.id, room.otherRowID)
    }

    func testZoomStaysBetweenOneAndSix() {
        XCTAssertEqual(PlanZoom.clamp(0.4), 1)
        XCTAssertEqual(PlanZoom.clamp(9), 6)
        XCTAssertEqual(PlanZoom.clamp(3), 3)
    }

    func testThePlusOffersOnlyWhatTheRobotCanDo() {
        var rules = PickRules(rooms: true, zones: true, goTo: true)
        XCTAssertEqual(PlusOption.available(rules, hasPlan: true), [.rooms, .zone, .pin])
        rules.zones = false
        XCTAssertEqual(PlusOption.available(rules, hasPlan: true), [.rooms, .pin], "a pin still works for go-to")
        rules.goTo = false
        XCTAssertEqual(PlusOption.available(rules, hasPlan: true), [.rooms])
        rules.rooms = false
        XCTAssertTrue(PlusOption.available(rules, hasPlan: true).isEmpty)
    }

    func testWithoutAPlanThePlusOnlyOpensTheList() {
        let rules = PickRules(rooms: true, zones: true, goTo: true)
        XCTAssertEqual(PlusOption.available(rules, hasPlan: false), [.rooms])
    }

    @MainActor func testThePlusHidesWhileWorkingAndForAPin() {
        let picks = Picks()
        picks.rules = PlanFixture.everything
        XCTAssertTrue(picks.showsPlus(hasPlan: true))
        picks.rules.working = true
        XCTAssertFalse(picks.showsPlus(hasPlan: true))
        picks.rules.working = false
        picks.dropPin(at: CGPoint(x: 15, y: 15))
        XCTAssertFalse(picks.showsPlus(hasPlan: true))
    }

    func testEverySymbolExists() {
        let symbols = ["bolt.fill", "speaker.wave.2.fill", "slider.horizontal.3", "stop.fill", "play.fill", "pause.fill",
                       "location.fill", "xmark", "arrow.uturn.backward", "chevron.up.chevron.down", "plus", "checkmark",
                       "list.bullet", "rectangle.dashed", "mappin"]
        for symbol in symbols { XCTAssertNotNil(UIImage(systemName: symbol), symbol) }
    }
}

private extension CGPoint {
    func floorSnapped(on plan: FloorPlan) -> CGPoint? { plan.nearestFloor(to: self, within: 5) }
}

// MARK: - Home: the bar, and what reaches the robot

/// The design's table of what the bar shows, one test per row.
@MainActor
final class HomeBarTests: XCTestCase {
    private var picks: Picks!
    private let names = ["1": "Kitchen", "2": "Hall", "3": "A very long living room"]

    override func setUp() async throws {
        picks = Picks()
        picks.rules = PlanFixture.everything
    }

    private var bar: BarModel { picks.bar(name: { self.names[$0] ?? "Room" }) }
    private var title: String? { bar.primary?.titles.first }

    func testIdle() {
        XCTAssertEqual(bar.icons, [.dock, .locate, .controls])
        XCTAssertEqual(title, "Clean All")
    }

    func testIdleWithoutRoomsJustSaysClean() {
        picks.rules.rooms = false
        XCTAssertEqual(title, "Clean")
    }

    func testWorking() {
        picks.rules.working = true
        XCTAssertEqual(bar.icons, [.stop, .dock, .controls])
        XCTAssertEqual(title, "Pause")
        XCTAssertEqual(bar.primary?.pauses, true)
    }

    func testPaused() {
        picks.rules.paused = true
        XCTAssertEqual(bar.icons, [.stop, .dock, .controls])
        XCTAssertEqual(title, "Resume")
        XCTAssertEqual(bar.primary?.pauses, false)
    }

    func testRooms() {
        picks.toggle("1")
        XCTAssertEqual(bar.icons, [.clear, .passes, .controls])
        XCTAssertEqual(title, "Clean Kitchen")
        picks.toggle("2")
        XCTAssertEqual(title, "Clean 2 Rooms")
    }

    func testZones() {
        picks.addZone(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(bar.icons, [.clear, .passes, .controls])
        XCTAssertEqual(title, "Clean Zone")
        picks.addZone(CGRect(x: 20, y: 0, width: 10, height: 10))
        XCTAssertEqual(title, "Clean 2 Zones")
    }

    func testPinClean() {
        picks.dropPin(at: .zero)
        XCTAssertEqual(bar.icons, [.clear, .passes, .controls])
        XCTAssertEqual(title, "Clean Here")
    }

    func testPinGo() {
        picks.dropPin(at: .zero)
        picks.setVerb(.go)
        XCTAssertEqual(bar.icons, [.clear, .controls])
        XCTAssertEqual(title, "Go Here")
        XCTAssertEqual(bar.primary?.symbol, "location.fill")
    }

    func testSending() {
        picks.toggle("1")
        let icons = bar.icons
        picks.beginSending()
        XCTAssertEqual(bar.icons, icons)
        XCTAssertEqual(title, "Starting")
        XCTAssertEqual(bar.primary?.busy, true)
        XCTAssertEqual(bar.primary?.enabled, false)
    }

    func testPauseIsntHeldUpOnceTheRobotReportsWork() {
        picks.toggle("1")
        picks.beginSending()
        picks.rules.working = true
        XCTAssertEqual(bar.icons, [.stop, .dock, .controls])
        XCTAssertEqual(title, "Pause")
        XCTAssertEqual(bar.primary?.pauses, true)
        XCTAssertEqual(bar.primary?.enabled, true, "our own answer can take a minute, and the robot is already moving")
        XCTAssertEqual(bar.primary?.busy, false)
    }

    func testThePrimaryStaysPauseWhileWorkingWhateverIsPicked() {
        picks.toggle("1")
        picks.rules.working = true
        XCTAssertEqual(title, "Pause")
    }

    func testPausedPlusPicksRedirectsTheJob() {
        picks.rules.paused = true
        picks.toggle("1")
        XCTAssertEqual(title, "Clean Kitchen")
        picks.clear()
        XCTAssertEqual(title, "Resume")
    }

    func testTheCountAppearsOnThePrimary() {
        picks.toggle("1")
        picks.passes = 2
        XCTAssertEqual(title, "Clean Kitchen Twice")
        picks.toggle("2")
        picks.passes = 3
        XCTAssertEqual(title, "Clean 2 Rooms 3 Times")
    }

    func testTheCountFollowsThePickKindsLimit() {
        picks.toggle("1")
        picks.passes = 3
        picks.addZone(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(title, "Clean Zone Twice")
    }

    func testLongNamesHaveShorterFallbacks() {
        picks.toggle("3")
        XCTAssertEqual(bar.primary?.titles, ["Clean A very long living room", "Clean Room", "Clean"])
    }

    func testSpokenLabelsCarryTheWholeJob() {
        picks.toggle("1")
        picks.toggle("2")
        picks.passes = 2
        XCTAssertEqual(bar.primary?.spoken, "Clean Kitchen, then Hall, twice")
    }

    func testPassesHideWhenTheMaximumIsOne() {
        picks.rules.maxRoomPasses = 1
        picks.toggle("1")
        XCTAssertEqual(bar.icons, [.clear, .controls])
    }

    func testAMissingCapabilityClosesUp() {
        picks.rules.locate = false
        XCTAssertEqual(bar.icons, [.dock, .controls])
        picks.rules.basic = false
        XCTAssertEqual(bar.icons, [.controls])
    }

    func testWithoutBasicControlOnlyPicksGetAPrimary() {
        picks.rules.basic = false
        XCTAssertNil(bar.primary)
        picks.toggle("1")
        XCTAssertEqual(title, "Clean Kitchen")
    }

    func testControlsIsAlwaysTheLastIcon() {
        for setUp in [{ self.picks.rules.working = true }, { self.picks.rules.paused = true }, { self.picks.toggle("1") }] {
            setUp()
            XCTAssertEqual(bar.icons.last, .controls)
        }
    }

    func testOfflineDisablesThePrimaryInEveryStateAndKeepsPicks() {
        picks.rules.reachable = false
        XCTAssertEqual(bar.primary?.enabled, false)
        picks.rules.working = true
        XCTAssertEqual(bar.primary?.enabled, false)
        picks.rules.working = false
        picks.rules.paused = true
        XCTAssertEqual(bar.primary?.enabled, false)
        picks.toggle("1")
        XCTAssertEqual(bar.primary?.enabled, false)
        picks.rules.reachable = true
        XCTAssertEqual(bar.primary?.enabled, true)
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testAPinOnANoGoAreaDisablesThePrimary() {
        picks.dropPin(at: .zero)
        XCTAssertEqual(picks.bar(name: { $0 }, pinBlocked: true).primary?.enabled, false)
    }

    func testNoWordOnTheBarUsesAMultiplicationSign() {
        var words: [String] = []
        for passes in 1...4 {
            words.append(PickWording.times(passes))
            words += PickWording.roomTitles(names: ["Kitchen"], passes: passes)
            words += PickWording.zoneTitles(count: 2, passes: passes)
            words += PickWording.pinTitles(passes: passes)
        }
        words.append(PickWording.size(CGRect(x: 0, y: 0, width: 30, height: 30), pixelSize: 5))
        XCTAssertFalse(words.contains { $0.contains("\u{00D7}") })
    }
}

final class StartGuardTests: XCTestCase {
    func testTheBarsCommandIconsWaitLonger() {
        let now = Date()
        var guardrail = StartGuard(delay: 1)
        guardrail.labelChanged(at: now)
        XCTAssertFalse(guardrail.allowsStart(at: now.addingTimeInterval(0.9)), "a tap meant for Clear, 0.9 s later")
        XCTAssertTrue(guardrail.allowsStart(at: now.addingTimeInterval(1.0)))
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    func testNothingIsHeldBackBeforeTheLabelChanges() {
        XCTAssertTrue(StartGuard().allowsStart(at: now))
    }

    func testStartingIgnoresTapsForHalfASecondAfterTheLabelChanges() {
        var guardrail = StartGuard()
        guardrail.labelChanged(at: now)
        XCTAssertFalse(guardrail.allowsStart(at: now))
        XCTAssertFalse(guardrail.allowsStart(at: now.addingTimeInterval(0.49)))
        XCTAssertTrue(guardrail.allowsStart(at: now.addingTimeInterval(0.5)))
    }

    func testEachChangeRestartsTheWait() {
        var guardrail = StartGuard()
        guardrail.labelChanged(at: now)
        guardrail.labelChanged(at: now.addingTimeInterval(0.4))
        XCTAssertFalse(guardrail.allowsStart(at: now.addingTimeInterval(0.6)))
    }
}

/// What reaches the robot, checked at the wire against a stub that opens no sockets.
@MainActor
final class RobotCommandTests: XCTestCase {
    private func store() async -> RobotStore {
        let store = RobotStore(client: Client(baseURL: "http://stub.invalid"))
        await store.loadEverything()
        return store
    }

    func testLimitsAreReadPerRobot() async {
        StubRobot.install(rooms: 3, zones: 4, zonePasses: 2, order: true)
        let store = await store()
        XCTAssertEqual(store.maxRoomPasses, 3)
        XCTAssertEqual(store.maxZonePasses, 2)
        XCTAssertEqual(store.maxZones, 4)
        XCTAssertTrue(store.roomOrderSupported)
    }

    func testTapOrderReachesARobotThatCanFollowIt() async throws {
        StubRobot.install(order: true)
        let store = await store()
        let accepted = await store.clean(rooms: ["2", "1"], passes: 2)
        XCTAssertTrue(accepted)
        let sent = try XCTUnwrap(StubRobot.commands.last)
        XCTAssertEqual(sent.path, "/robot/capabilities/MapSegmentationCapability")
        XCTAssertEqual(sent.body["segment_ids"] as? [String], ["2", "1"])
        XCTAssertEqual(sent.body["customOrder"] as? Bool, true)
        XCTAssertEqual(sent.body["iterations"] as? Int, 2)
    }

    func testARobotWithoutOrderSupportIsNotAskedForOne() async throws {
        StubRobot.install(order: false)
        let store = await store()
        XCTAssertFalse(store.roomOrderSupported)
        _ = await store.clean(rooms: ["1"], passes: 1)
        XCTAssertEqual(try XCTUnwrap(StubRobot.commands.last).body["customOrder"] as? Bool, false)
    }

    func testAPropertiesAnswerWithoutTheFieldMeansNoOrder() async {
        StubRobot.install()
        StubRobot.routes["/robot/capabilities/MapSegmentationCapability/properties"] = #"{"iterationCount":{"min":1,"max":3}}"#
        let store = await store()
        XCTAssertFalse(store.roomOrderSupported)
        XCTAssertEqual(store.maxRoomPasses, 3)
    }

    func testZonesAreSentInCentimetres() async throws {
        StubRobot.install()
        let store = await store()
        let accepted = await store.clean(zones: [CGRect(x: 10, y: 20, width: 30, height: 40)], passes: 2)
        XCTAssertTrue(accepted)
        let sent = try XCTUnwrap(StubRobot.commands.last)
        let zones = try XCTUnwrap(sent.body["zones"] as? [[String: Any]])
        let points = try XCTUnwrap(zones.first?["points"] as? [String: [String: Int]])
        XCTAssertEqual(points["pA"], ["x": 50, "y": 100])
        XCTAssertEqual(points["pC"], ["x": 200, "y": 300])
        XCTAssertEqual(sent.body["iterations"] as? Int, 2)
    }

    func testGoToIsSentInCentimetres() async throws {
        StubRobot.install()
        let store = await store()
        let accepted = await store.go(to: CGPoint(x: 30, y: 40))
        XCTAssertTrue(accepted)
        let sent = try XCTUnwrap(StubRobot.commands.last)
        XCTAssertEqual(sent.body["coordinates"] as? [String: Int], ["x": 150, "y": 200])
    }

    func testStartAnswersAndSendsTheAction() async throws {
        StubRobot.install()
        let store = await store()
        let accepted = await store.start()
        XCTAssertTrue(accepted)
        XCTAssertEqual(try XCTUnwrap(StubRobot.commands.last).body["action"] as? String, "start")
    }

    func testSuccessIsSilentBecauseTheTitleSaysIt() async {
        StubRobot.install()
        let store = await store()
        _ = await store.clean(rooms: ["1"], passes: 1)
        _ = await store.start()
        _ = await store.go(to: CGPoint(x: 30, y: 40))
        _ = await store.clean(zones: [CGRect(x: 10, y: 20, width: 30, height: 40)], passes: 1)
        XCTAssertNil(store.toast)
    }

    func testARefusalAnswersFalseAndShowsTheError() async {
        StubRobot.install()
        let store = await store()
        StubRobot.refusing = "/robot/capabilities/MapSegmentationCapability"
        let accepted = await store.clean(rooms: ["1"], passes: 1)
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.toast?.message, "Nope")
        XCTAssertEqual(store.toast?.isProblem, true)
    }

    func testEveryMapCountsAsANewRevision() async {
        StubRobot.install()
        let store = await store()
        let before = store.planRevision
        XCTAssertGreaterThan(before, 0)
        await store.refreshFloorPlan()
        XCTAssertEqual(store.planRevision, before + 1)
    }

    func testAFailedMapReadIsNotANewRevision() async {
        StubRobot.install()
        let store = await store()
        let before = store.planRevision
        StubRobot.routes["/robot/state/map"] = nil
        await store.refreshFloorPlan()
        XCTAssertEqual(store.planRevision, before)
    }

    func testAWorkingRobotIsntWaitedFor() async {
        StubRobot.install(state: "cleaning")
        let store = await store()
        let clock = ContinuousClock()
        let waited = await clock.measure { await store.waitForWork(limit: .seconds(5)) }
        XCTAssertLessThan(waited, .seconds(1))
    }

    func testTheWaitForWorkGivesUp() async {
        StubRobot.install()
        let store = await store()
        let clock = ContinuousClock()
        let waited = await clock.measure { await store.waitForWork(limit: .milliseconds(250)) }
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(250))
        XCTAssertLessThan(waited, .seconds(2))
    }

    func testAnAcceptedJobStaysLockedUntilTheRobotReportsWork() async {
        StubRobot.install()
        let store = await store()
        let picks = Picks()
        picks.rules = PlanFixture.everything
        picks.toggle("1")
        picks.beginSending()
        let delivered = Task { await picks.deliver(.rooms(["1"], passes: 1), to: store, within: .seconds(20)) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(StubRobot.commands.count, 1, "the robot has said yes")
        XCTAssertTrue(picks.sending, "but it's still reporting docked, so the idle bar can't come back yet")
        XCTAssertEqual(picks.bar(name: { $0 }).primary?.titles, ["Starting"])

        StubRobot.set(state: "cleaning")
        await store.loadEverything()
        let accepted = await delivered.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(picks.sending)
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testAnAcceptedJobUnlocksIfTheRobotNeverReportsWork() async {
        StubRobot.install()
        let store = await store()
        let picks = Picks()
        picks.rules = PlanFixture.everything
        picks.toggle("1")
        picks.beginSending()
        let accepted = await picks.deliver(.rooms(["1"], passes: 1), to: store, within: .milliseconds(150))
        XCTAssertTrue(accepted)
        XCTAssertFalse(picks.sending)
        XCTAssertEqual(picks.kind, .nothing)
    }

    func testARefusedJobUnlocksAtOnceAndKeepsItsPicks() async {
        StubRobot.install()
        let store = await store()
        StubRobot.refusing = "/robot/capabilities/MapSegmentationCapability"
        let picks = Picks()
        picks.rules = PlanFixture.everything
        picks.toggle("1")
        picks.beginSending()
        let clock = ContinuousClock()
        var accepted = true
        let waited = await clock.measure { accepted = await picks.deliver(.rooms(["1"], passes: 1), to: store, within: .seconds(20)) }
        XCTAssertFalse(accepted)
        XCTAssertLessThan(waited, .seconds(2))
        XCTAssertFalse(picks.sending)
        XCTAssertEqual(picks.rooms, ["1"])
    }

    func testEveryJobGoesToItsOwnCommand() async throws {
        StubRobot.install()
        let store = await store()
        for job: Picks.Job in [.start, .rooms(["1"], passes: 1), .go(CGPoint(x: 30, y: 40)),
                               .zones([CGRect(x: 10, y: 20, width: 30, height: 40)], passes: 1)] {
            let accepted = await store.send(job)
            XCTAssertTrue(accepted)
        }
        XCTAssertEqual(StubRobot.commands.map(\.path), ["/robot/capabilities/BasicControlCapability",
                                                        "/robot/capabilities/MapSegmentationCapability",
                                                        "/robot/capabilities/GoToLocationCapability",
                                                        "/robot/capabilities/ZoneCleaningCapability"])
    }

    func testTheHoldTipNeedsAPlanToPointAt() {
        let rules = PlanFixture.everything
        HomeTips.update(rules, hasPlan: false)
        XCTAssertFalse(HoldTip.canShow, "don't teach a gesture on a screen with no plan to do it on")
        HomeTips.update(rules, hasPlan: true)
        XCTAssertTrue(HoldTip.canShow)
    }

    func testNoPlanMeansNoZoneOrGoToJob() async {
        StubRobot.install()
        let store = RobotStore(client: Client(baseURL: "http://stub.invalid"))
        let zones = await store.clean(zones: [CGRect(x: 0, y: 0, width: 10, height: 10)], passes: 1)
        let go = await store.go(to: .zero)
        XCTAssertFalse(zones)
        XCTAssertFalse(go)
        XCTAssertTrue(StubRobot.commands.isEmpty)
    }

    func testRulesReadWhatTheRobotReports() async {
        StubRobot.install(state: "paused", rooms: 3, zones: 4, zonePasses: 2)
        let store = await store()
        let rules = PickRules(store)
        XCTAssertTrue(rules.rooms && rules.zones && rules.goTo && rules.basic && rules.locate && rules.paused)
        XCTAssertFalse(rules.working)
        XCTAssertEqual(rules.maxZones, 4)
        XCTAssertEqual(store.roomName("2"), "Living room")
        XCTAssertEqual(store.roomName("999"), "Room")
    }

    func testAFailedPlanStillOffersRoomsFromTheRobotsList() async {
        StubRobot.install()
        StubRobot.routes["/robot/state/map"] = nil
        let store = await store()
        XCTAssertNil(store.plan)
        XCTAssertTrue(PickRules(store).rooms)
        XCTAssertEqual(store.roomName("1"), "Kitchen")
    }

    func testAMapWithNoRoomsOffersNone() async {
        StubRobot.install()
        StubRobot.routes["/robot/state/map"] = #"{"pixelSize":5,"layers":[{"type":"floor","compressedPixels":[1,1,5]}],"entities":[]}"#
        let store = await store()
        XCTAssertFalse(PickRules(store).rooms, "a map with no rooms beats the robot's own list")
    }
}

/// A pretend robot. It answers `Client` from memory through a URL protocol, so these tests
/// never open a socket, and it records every command sent to it.
final class StubRobot: URLProtocol {
    struct Command {
        let path: String
        let body: [String: Any]
    }

    nonisolated(unsafe) static var routes: [String: String] = [:]
    nonisolated(unsafe) static var commands: [Command] = []
    /// Commands to this path are refused with an error.
    nonisolated(unsafe) static var refusing: String?

    private static let installed: Void = {
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral))
        let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.stubbed))
        if let original, let replacement { method_exchangeImplementations(original, replacement) }
    }()

    /// Starts from a robot that can do everything, with the given limits.
    static func install(state: String = "docked", rooms: Int = 3, zones: Int = 4, zonePasses: Int = 2, order: Bool = true) {
        _ = installed
        commands = []
        refusing = nil
        routes = [
            "/robot/capabilities": #"["BasicControlCapability","LocateCapability","MapSegmentationCapability","ZoneCleaningCapability","GoToLocationCapability"]"#,
            "/robot": #"{"manufacturer":"Stub","modelName":"One"}"#,
            "/valetudo/config/customizations": #"{"friendlyName":"Robbie"}"#,
            "/robot/state/map": map,
            "/robot/capabilities/MapSegmentationCapability": #"[{"id":"1","name":"Kitchen"},{"id":"2","name":"Living room"}]"#,
            "/robot/capabilities/MapSegmentationCapability/properties": #"{"iterationCount":{"min":1,"max":\#(rooms)},"customOrderSupport":\#(order)}"#,
            "/robot/capabilities/ZoneCleaningCapability/properties": #"{"zoneCount":{"min":1,"max":\#(zones)},"iterationCount":{"min":1,"max":\#(zonePasses)}}"#
        ]
        set(state: state)
    }

    static func set(state: String) {
        routes["/robot/state/attributes"] = #"[{"__class":"StatusStateAttribute","value":"\#(state)","flag":"none"},{"__class":"BatteryStateAttribute","level":98,"flag":"charging"}]"#
    }

    /// Five rooms around a void, because the design has to cope with an empty middle.
    static var map: String {
        func box(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [Int] {
            (y..<(y + height)).flatMap { [x, $0, width] }
        }
        func outline(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [Int] {
            box(x - 1, y - 1, width + 2, 1) + box(x - 1, y + height, width + 2, 1)
                + box(x - 1, y, 1, height) + box(x + width, y, 1, height)
        }
        let rooms: [(id: String, name: String, frame: (Int, Int, Int, Int))] = [
            ("1", "Kitchen", (20, 20, 70, 60)), ("2", "Living room", (100, 20, 100, 80)), ("3", "Hall", (60, 110, 70, 30)),
            ("4", "Bedroom", (20, 150, 70, 70)), ("5", "Bathroom", (100, 150, 60, 50))
        ]
        let segments = rooms.map { room in
            #"{"type":"segment","compressedPixels":\#(box(room.frame.0, room.frame.1, room.frame.2, room.frame.3)),"metaData":{"segmentId":"\#(room.id)","name":"\#(room.name)"}}"#
        }
        let walls = rooms.flatMap { outline($0.frame.0, $0.frame.1, $0.frame.2, $0.frame.3) }
        let wall = #"{"type":"wall","compressedPixels":\#(walls)}"#
        let entities = [
            #"{"type":"robot_position","points":[800,400],"metaData":{"angle":90}}"#,
            #"{"type":"charger_location","points":[900,700]}"#,
            #"{"type":"no_go_area","points":[700,700,800,700,800,800,700,800]}"#,
            #"{"type":"obstacle","points":[250,850],"metaData":{"label":"Shoe","id":"s"}}"#
        ]
        return #"{"pixelSize":5,"layers":[\#((segments + [wall]).joined(separator: ","))],"entities":[\#(entities.joined(separator: ","))]}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let path = url.path.replacingOccurrences(of: "/api/v2", with: "")
        var status = 200
        var body = Data(Self.routes[path]?.utf8 ?? "".utf8)
        if request.httpMethod == "PUT" {
            Self.commands.append(Command(path: path, body: requestBody()))
            if path == Self.refusing { (status, body) = (400, Data("Nope".utf8)) }
        } else if Self.routes[path] == nil {
            status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        if let response { client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    /// Bodies reach a URL protocol as a stream.
    private func requestBody() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

extension URLSessionConfiguration {
    /// Swapped with `ephemeral`, so this calls the real one.
    @objc class func stubbed() -> URLSessionConfiguration {
        let configuration = stubbed()
        configuration.protocolClasses = [StubRobot.self]
        return configuration
    }
}
