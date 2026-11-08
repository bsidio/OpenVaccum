import SwiftUI
import XCTest
@testable import OpenVacuum

/// A map as the robot sends one: rooms as runs of pixels, entities in centimetres, at 5 cm a pixel.
private enum Sketch {
    struct Room {
        var id: String
        var rect: CGRect
        var material: String?
        var active = false
        /// A second rectangle, for a room that isn't one.
        var arm: CGRect?
    }

    static func runs(_ rect: CGRect) -> [Int] {
        (Int(rect.minY)..<Int(rect.maxY)).flatMap { [Int(rect.minX), $0, Int(rect.width)] }
    }

    static func raw(_ rooms: [Room], wall: CGRect? = nil, entities: [[String: Any]] = []) throws -> RawMap {
        var layers: [[String: Any]] = rooms.map { room in
            var meta: [String: Any] = ["segmentId": room.id, "active": room.active]
            if let material = room.material { meta["material"] = material }
            return ["type": "segment", "compressedPixels": runs(room.rect) + (room.arm.map(runs) ?? []), "metaData": meta]
        }
        if let wall { layers.append(["type": "wall", "compressedPixels": runs(wall)]) }
        let json: [String: Any] = ["pixelSize": 5, "layers": layers, "entities": entities]
        return try JSONDecoder().decode(RawMap.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func plan(_ rooms: [Room], wall: CGRect? = nil, entities: [[String: Any]] = []) throws -> FloorPlan {
        FloorPlan(try raw(rooms, wall: wall, entities: entities))
    }

    static func entity(_ type: String, _ points: [Double]) -> [String: Any] {
        ["type": type, "points": points, "metaData": [String: Any]()]
    }

    /// `rows` by `columns` touching rooms, numbered from 1 along each row.
    static func grid(rows: Int, columns: Int) -> [Room] {
        (0..<rows * columns).map { index in
            let x = index % columns, y = index / columns
            return Room(id: "\(index + 1)", rect: CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
        }
    }

    static let room = Room(id: "1", rect: CGRect(x: 0, y: 0, width: 100, height: 100))
}

final class PlanParsingTests: XCTestCase {
    func testRestrictionsKeepTheirKinds() throws {
        let plan = try Sketch.plan([Sketch.room], entities: [
            Sketch.entity("virtual_wall", [50, 50, 250, 50]),
            Sketch.entity("no_go_area", [50, 100, 150, 100, 150, 200, 50, 200]),
            Sketch.entity("no_mop_area", [200, 100, 300, 100, 300, 200, 200, 200])
        ])
        XCTAssertEqual(plan.restrictions.map(\.kind), [.wall, .noGo, .noMop])
        XCTAssertEqual(plan.restrictions[0].points, [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)])
    }

    /// Picks and the 3D view read these, so they must go on being filled.
    func testRestrictionPathsStayFilled() throws {
        let plan = try Sketch.plan([Sketch.room], entities: [
            Sketch.entity("virtual_wall", [50, 50, 250, 50]),
            Sketch.entity("no_go_area", [50, 100, 150, 100, 150, 200, 50, 200]),
            Sketch.entity("no_mop_area", [200, 100, 300, 100, 300, 200, 200, 200])
        ])
        XCTAssertFalse(plan.virtualWalls.isEmpty)
        XCTAssertTrue(plan.noGo.contains(CGPoint(x: 20, y: 30)))
        XCTAssertTrue(plan.noMop.contains(CGPoint(x: 50, y: 30)))
    }

    func testTheJobUnderWayIsRead() throws {
        let plan = try Sketch.plan([Sketch.room], entities: [
            Sketch.entity("active_zone", [50, 50, 250, 50, 250, 150, 50, 150]),
            Sketch.entity("active_zone", [300, 50, 400, 50, 400, 150, 300, 150]),
            Sketch.entity("go_to_target", [100, 200])
        ])
        XCTAssertTrue(plan.activeZones.contains(CGPoint(x: 30, y: 20)))
        XCTAssertTrue(plan.activeZones.contains(CGPoint(x: 70, y: 20)))
        XCTAssertFalse(plan.activeZones.contains(CGPoint(x: 55, y: 20)))
        XCTAssertEqual(plan.goToTarget, CGPoint(x: 20, y: 40))
    }

    func testNoJobLeavesNothingToDraw() throws {
        let plan = try Sketch.plan([Sketch.room])
        XCTAssertTrue(plan.activeZones.isEmpty)
        XCTAssertNil(plan.goToTarget)
    }

    func testFootprintDoesNotNeedAFloorLayer() throws {
        let plan = try Sketch.plan([Sketch.room], wall: CGRect(x: 100, y: 0, width: 2, height: 100))
        XCTAssertTrue(plan.floor.isEmpty)
        XCTAssertTrue(plan.footprint.contains(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(plan.footprint.contains(CGPoint(x: 101, y: 50)))
    }

    func testAreaCountsTheRoomsPixels() throws {
        let plan = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 40, height: 10))])
        XCTAssertEqual(try XCTUnwrap(plan.rooms.first).area, 1, accuracy: 0.0001)
    }

    func testARoomsSpanIsItsShortSide() throws {
        let plan = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 100, height: 40))])
        XCTAssertEqual(try XCTUnwrap(plan.rooms.first).span, 40, accuracy: 0.001)
    }

    func testAHallThatTurnsACornerStillCountsAsNarrow() throws {
        let plan = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 200, height: 16),
                                                arm: CGRect(x: 0, y: 16, width: 16, height: 100))])
        XCTAssertLessThan(try XCTUnwrap(plan.rooms.first).span, 32)
    }

    func testRoomCountReadsNaturally() throws {
        XCTAssertEqual(try Sketch.plan([Sketch.room]).roomCount, "1 room")
        XCTAssertEqual(try Sketch.plan(Sketch.grid(rows: 1, columns: 2)).roomCount, "2 rooms")
    }
}

final class RoomColourTests: XCTestCase {
    private func palette(_ plan: FloorPlan) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: plan.rooms.map { ($0.id, $0.palette) })
    }

    func testRoomsUpToThePaletteSizeAllDiffer() throws {
        let plan = try Sketch.plan(Sketch.grid(rows: 2, columns: 4))
        XCTAssertEqual(Set(plan.rooms.map(\.palette)).count, plan.rooms.count)
    }

    func testTouchingRoomsNeverMatchInALargeHome() throws {
        let columns = 5
        let plan = try Sketch.plan(Sketch.grid(rows: 5, columns: columns))
        let colors = palette(plan)
        for index in 0..<25 {
            let id = "\(index + 1)"
            if index % columns < columns - 1 { XCTAssertNotEqual(colors[id], colors["\(index + 2)"], "Room \(id) and its right neighbour") }
            if index / columns < 4 { XCTAssertNotEqual(colors[id], colors["\(index + 1 + columns)"], "Room \(id) and the room below") }
        }
    }

    func testAWallBetweenRoomsDoesNotHideThem() throws {
        // Ids 1 and 9 both start from the same colour, and only a wall stands between them.
        let plan = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                    Sketch.Room(id: "9", rect: CGRect(x: 22, y: 0, width: 20, height: 20))],
                                   wall: CGRect(x: 20, y: 0, width: 2, height: 20))
        let colors = palette(plan)
        XCTAssertNotEqual(colors["1"], colors["9"])
    }

    func testRoomsOneAboveTheOtherAreNeighbours() throws {
        let plan = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                    Sketch.Room(id: "9", rect: CGRect(x: 0, y: 22, width: 20, height: 20))])
        let colors = palette(plan)
        XCTAssertNotEqual(colors["1"], colors["9"])
    }

    func testColoursHoldAcrossRefreshes() throws {
        let rooms = Sketch.grid(rows: 4, columns: 4)
        let first = palette(try Sketch.plan(rooms))
        XCTAssertEqual(palette(try Sketch.plan(rooms.shuffled())), first)
        XCTAssertEqual(palette(try Sketch.plan(rooms.reversed())), first)
    }

    func testAddingARoomLeavesTheOthersAlone() throws {
        let rooms = Sketch.grid(rows: 2, columns: 3)
        let before = palette(try Sketch.plan(rooms))
        var after = palette(try Sketch.plan(rooms + [Sketch.Room(id: "7", rect: CGRect(x: 60, y: 0, width: 20, height: 40))]))
        after["7"] = nil
        XCTAssertEqual(after, before)
    }

    func testAHallwayWithMoreDoorsThanColoursStillStandsOut() {
        let doors = (1...12).map(String.init)
        let ids = doors + ["13"]
        var neighbours = Dictionary(uniqueKeysWithValues: doors.map { ($0, Set(["13"])) })
        neighbours["13"] = Set(doors)
        let colors = FloorPlan.palette(for: ids, neighbours: neighbours, colors: 8)
        for door in doors { XCTAssertNotEqual(colors[door], colors["13"]) }
    }

    func testRoomIdsNeedNotBeNumbers() {
        let ids = ["kitchen", "hall", "a-very-long-room-identifier-that-goes-on-for-a-while-and-then-some-more"]
        let colors = FloorPlan.palette(for: ids, neighbours: [:], colors: 8)
        XCTAssertEqual(Set(colors.values).count, 3)
        XCTAssertTrue(colors.values.allSatisfy { (0..<8).contains($0) })
    }

    func testEveryColourExists() throws {
        let plan = try Sketch.plan(Sketch.grid(rows: 5, columns: 5))
        XCTAssertTrue(plan.rooms.allSatisfy { Theme.rooms.indices.contains($0.palette) })
    }
}

final class FloorTextureTests: XCTestCase {
    private let box = CGRect(x: 0, y: 0, width: 60, height: 40)

    private func slopes(of path: Path) -> Set<Int> {
        var result = Set<Int>()
        var start = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to): start = to
            case .line(let to):
                result.insert((to.x - start.x) * (to.y - start.y) > 0 ? 1 : -1)
                start = to
            default: break
            }
        }
        return result
    }

    func testEachFloorTypeHasItsOwnLook() {
        let materials = ["tile", "wood", "wood_horizontal", "wood_vertical", "carpet", "carpet_low", "carpet_high"]
        let textures = materials.map { FloorPlan.texture(for: $0, in: box) }
        XCTAssertFalse(textures.contains(where: \.isEmpty))
        for (index, texture) in textures.enumerated() {
            for other in textures[(index + 1)...] { XCTAssertNotEqual(texture, other) }
        }
    }

    func testCarpetsAreHatchedBothWays() {
        for material in ["carpet", "carpet_low", "carpet_high"] {
            XCTAssertEqual(slopes(of: FloorPlan.texture(for: material, in: box)), [1, -1], material)
        }
    }

    func testCarpetEntitiesGetAHatchThatCoversThem() throws {
        let plan = try Sketch.plan([Sketch.room], entities: [Sketch.entity("carpet", [50, 50, 250, 50, 250, 150, 50, 150])])
        XCTAssertEqual(slopes(of: plan.carpetHatch), [1, -1])
        XCTAssertTrue(plan.carpetHatch.boundingRect.contains(plan.carpets.boundingRect))
    }

    func testNoCarpetMeansNoHatch() throws {
        XCTAssertTrue(try Sketch.plan([Sketch.room]).carpetHatch.isEmpty)
    }
}

final class RobotHeadingTests: XCTestCase {
    func testTurnsTakeTheShortWayRound() {
        XCTAssertEqual(RobotMarker.turn(from: 355, to: 5), 10, accuracy: 0.0001)
        XCTAssertEqual(RobotMarker.turn(from: 5, to: 355), -10, accuracy: 0.0001)
        XCTAssertEqual(RobotMarker.turn(from: 90, to: 120), 30, accuracy: 0.0001)
        XCTAssertEqual(RobotMarker.turn(from: 40, to: 40), 0, accuracy: 0.0001)
    }

    func testRepeatedTurnsEndOnTheReportedHeading() {
        var shown = 350.0
        var reported = 350.0
        for next in [10.0, 200.0, 359.0, 1.0, 180.0, 0.0] {
            shown += RobotMarker.turn(from: reported, to: next)
            reported = next
            let remainder = shown.truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(remainder < 0 ? remainder + 360 : remainder, next, accuracy: 0.0001)
        }
    }
}

final class RoomLabelTests: XCTestCase {
    private func room(area: Double) throws -> FloorPlan.Room {
        // 400 pixels at 25 cm² each is one square metre.
        let side = (area * 400).squareRoot()
        return try XCTUnwrap(try Sketch.plan([Sketch.Room(id: "7", rect: CGRect(x: 0, y: 0, width: side, height: side))]).rooms.first)
    }

    func testDetailShowsTheAreaAndId() throws {
        XCTAssertEqual(PlanCanvas.detail(of: try room(area: 4), locale: Locale(identifier: "en_GB")), "4.0 m² · ID 7")
        XCTAssertEqual(PlanCanvas.detail(of: try room(area: 25), locale: Locale(identifier: "en_GB")), "25 m² · ID 7")
    }

    func testDetailFollowsTheLocale() throws {
        XCTAssertEqual(PlanCanvas.detail(of: try room(area: 4), locale: Locale(identifier: "en_US")), "43 sq ft · ID 7")
        XCTAssertEqual(PlanCanvas.detail(of: try room(area: 4), locale: Locale(identifier: "de_DE")), "4,0 m² · ID 7")
    }
}

final class ToastTests: XCTestCase {
    func testOnlyTheFirstHostToSeeAToastPlaysIt() {
        let toast = Toast(message: "Saved")
        XCTAssertTrue(toast.claim())
        XCTAssertFalse(toast.claim())
    }

    func testEachNewToastIsPlayed() {
        XCTAssertTrue(Toast(message: "Saved").claim())
        XCTAssertTrue(Toast(message: "Saved").claim())
    }
}

/// Renders a view offscreen, reading its pixels rather than the code that draws it.
@MainActor
private func paint<V: View>(_ view: V, size: CGSize, scheme: ColorScheme = .light, strong: Bool = false) throws -> Bitmap {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .environment(\._colorSchemeContrast, strong ? .increased : .standard))
    renderer.scale = 1
    return try Bitmap(try XCTUnwrap(renderer.cgImage))
}

/// What actually reaches the screen, so these read pixels rather than the code that draws them.
@MainActor
final class PlanPaintingTests: XCTestCase {
    private static let size = CGSize(width: 200, height: 200)

    /// A room filling the view, with a no-go zone top left and everything else well clear of it.
    private func plan(active: Bool = false, entities: [[String: Any]] = []) throws -> FloorPlan {
        try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 100, height: 100), active: active)], entities: entities)
    }

    private var noGo: [String: Any] { Sketch.entity("no_go_area", [50, 50, 150, 50, 150, 150, 50, 150]) }

    private func bitmap<V: View>(_ view: V, scheme: ColorScheme = .light, strong: Bool = false) throws -> Bitmap {
        try paint(view, size: Self.size, scheme: scheme, strong: strong)
    }

    /// `drawStructures` alone, onto a clear surface, where alpha shows how strongly a thing is drawn.
    private func structures(of plan: FloorPlan, strong: Bool = false) throws -> Bitmap {
        try bitmap(Canvas { context, size in
            PlanCanvas.drawStructures(of: plan, in: context, PlanTransform(bounds: plan.bounds, size: size))
        }, strong: strong)
    }

    private func point(_ map: CGPoint, on plan: FloorPlan) -> CGPoint {
        PlanTransform(bounds: plan.bounds, size: Self.size).toView(map)
    }

    private func rect(_ map: CGRect, on plan: FloorPlan) -> CGRect {
        PlanTransform(bounds: plan.bounds, size: Self.size).toView(map)
    }

    /// A spot on a label's backing, clear of its text.
    private func labelBacking(on plan: FloorPlan) throws -> CGPoint {
        let room = try XCTUnwrap(plan.rooms.first)
        let middle = point(room.label, on: plan)
        return CGPoint(x: middle.x - PlanLabel.size(of: room.name, mark: nil).width / 2 + 3, y: middle.y)
    }

    /// The editor's split line, to see whether it survives what's under it.
    private func splitLine(_ context: GraphicsContext, _ t: PlanTransform) {
        var path = Path()
        path.addLines([t.toView(CGPoint(x: 50, y: 0)), t.toView(CGPoint(x: 50, y: 100))])
        context.stroke(path, with: .color(Theme.cobalt), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
    }

    func testStructuresPaintRestrictionsAnnotationsAndTheJob() throws {
        let entities: [(String, [Double], CGPoint)] = [
            ("no_go_area", [50, 50, 150, 50, 150, 150, 50, 150], CGPoint(x: 20, y: 20)),
            ("no_mop_area", [200, 50, 300, 50, 300, 150, 200, 150], CGPoint(x: 50, y: 20)),
            ("ramp", [350, 50, 450, 50, 450, 150, 350, 150], CGPoint(x: 80, y: 20)),
            ("active_zone", [50, 300, 150, 300, 150, 400, 50, 400], CGPoint(x: 20, y: 70))
        ]
        let drawn = try plan(entities: entities.map { Sketch.entity($0.0, $0.1) })
        let image = try structures(of: drawn)
        for entity in entities {
            XCTAssertGreaterThan(image.alpha(at: point(entity.2, on: drawn)), 0, entity.0)
        }
        XCTAssertEqual(image.alpha(at: point(CGPoint(x: 50, y: 50), on: drawn)), 0, "Nothing belongs in the gap")
    }

    func testStructuresPaintLines() throws {
        let entities: [(String, [Double], CGPoint)] = [
            ("virtual_wall", [50, 100, 450, 100], CGPoint(x: 50, y: 20)),
            ("threshold", [50, 200, 450, 200], CGPoint(x: 50, y: 40))
        ]
        let drawn = try plan(entities: entities.map { Sketch.entity($0.0, $0.1) })
        let image = try structures(of: drawn)
        for entity in entities {
            XCTAssertGreaterThan(image.alpha(at: point(entity.2, on: drawn)), 0, entity.0)
        }
    }

    func testTheGoToPinStandsOnItsTarget() throws {
        let drawn = try plan(entities: [Sketch.entity("go_to_target", [250, 400])])
        let image = try structures(of: drawn)
        let tip = point(CGPoint(x: 50, y: 80), on: drawn)
        XCTAssertGreaterThan(image.alpha(at: tip), 0)
        XCTAssertGreaterThan(image.alpha(at: CGPoint(x: tip.x, y: tip.y - PlanPin.headRise)), 0)
        XCTAssertEqual(image.alpha(at: CGPoint(x: tip.x + 40, y: tip.y - PlanPin.headRise)), 0)
    }

    /// A pin picked on the plan hands over to the robot's own, so they have to line up.
    func testTheRobotsPinLandsWhereAPickedPinWas() throws {
        let tip = CGPoint(x: 100, y: 150)
        let picked = try bitmap(ZStack(alignment: .topLeading) {
            Color.clear
            PlanPin().position(x: tip.x, y: tip.y - PlanPin.tipDrop)
        })
        let drawn = try bitmap(Canvas { context, _ in PlanPin.draw(at: tip, in: context) })
        XCTAssertLessThan(picked.differingPixels(from: drawn), 40 * 40 / 10)
    }

    func testAPlanWithoutStructuresPaintsNothing() throws {
        let image = try structures(of: try plan())
        XCTAssertEqual(image.alpha(at: CGPoint(x: 100, y: 100)), 0)
    }

    func testTheEditorCanTurnStructuresOff() throws {
        let drawn = try plan(entities: [noGo, Sketch.entity("go_to_target", [250, 250])])
        let bare = try plan()
        XCTAssertNotEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false)),
                          try bitmap(PlanCanvas(plan: bare, showsRobot: false)))
        XCTAssertEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false, showsRestrictions: false)),
                       try bitmap(PlanCanvas(plan: bare, showsRobot: false)))
    }

    func testLabelsCanBeTurnedOff() throws {
        let drawn = try plan()
        XCTAssertNotEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false, showsLabels: false)),
                          try bitmap(PlanCanvas(plan: drawn, showsRobot: false)))
    }

    func testAJobMarksItsRooms() throws {
        let idle = try bitmap(PlanCanvas(plan: try plan(), showsRobot: false))
        XCTAssertNotEqual(try bitmap(PlanCanvas(plan: try plan(active: true), active: true, showsRobot: false)), idle)
    }

    func testAPausedJobStaysMarked() throws {
        let running = try bitmap(PlanCanvas(plan: try plan(active: true), active: true, showsRobot: false))
        XCTAssertEqual(try bitmap(PlanCanvas(plan: try plan(active: true), paused: true, showsRobot: false)), running)
    }

    func testAFlagLeftOnAnIdleRobotMarksNothing() throws {
        XCTAssertEqual(try bitmap(PlanCanvas(plan: try plan(active: true), showsRobot: false)),
                       try bitmap(PlanCanvas(plan: try plan(), showsRobot: false)))
    }

    func testHomeGetsAShadowWithoutAFloorLayer() throws {
        let small = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 40, y: 40, width: 20, height: 20)),
                                     Sketch.Room(id: "2", rect: CGRect(x: 0, y: 0, width: 4, height: 4)),
                                     Sketch.Room(id: "3", rect: CGRect(x: 96, y: 96, width: 4, height: 4))])
        let image = try bitmap(PlanCanvas(plan: small, showsRobot: false, showsLabels: false))
        let edge = point(CGPoint(x: 50, y: 62), on: small)
        XCTAssertGreaterThan(image.alpha(at: edge), 0)
    }

    func testSelectionShowsInTheEditorLabelToo() throws {
        let drawn = try plan()
        let picked = try bitmap(PlanCanvas(plan: drawn, selected: ["1"], showsRobot: false))
        let label = point(try XCTUnwrap(drawn.rooms.first).label, on: drawn)
        // The cobalt pill replaces the pale one, whichever way the room itself is coloured.
        XCTAssertNotEqual(picked.pixel(at: label), try bitmap(PlanCanvas(plan: drawn, showsRobot: false)).pixel(at: label))
    }

    // MARK: Order

    func testTheJobPaintsOverLabels() throws {
        let bare = try plan()
        let zoned = try plan(entities: [Sketch.entity("active_zone", [100, 100, 400, 100, 400, 400, 100, 400])])
        let spot = try labelBacking(on: bare)
        // The backing is solid with Increase Contrast, so a zone beneath it couldn't tint it.
        XCTAssertNotEqual(try bitmap(PlanCanvas(plan: zoned, showsRobot: false), strong: true).pixel(at: spot),
                          try bitmap(PlanCanvas(plan: bare, showsRobot: false), strong: true).pixel(at: spot))
    }

    func testTheDockPaintsOverTheJob() throws {
        let dock = Sketch.entity("charger_location", [100, 100])
        let zone = Sketch.entity("active_zone", [50, 50, 450, 50, 450, 450, 50, 450])
        let drawn = try plan(entities: [dock, zone])
        let corner = point(CGPoint(x: 20, y: 20), on: drawn)
        let spot = CGPoint(x: corner.x + 6, y: corner.y - 6)
        XCTAssertEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false)).pixel(at: spot),
                       try bitmap(PlanCanvas(plan: try plan(entities: [dock]), showsRobot: false)).pixel(at: spot))
    }

    // MARK: Floors

    func testCarpetsPaintTheirHatchInsideTheirOutlineOnly() throws {
        let drawn = try plan(entities: [Sketch.entity("carpet", [100, 100, 300, 100, 300, 300, 100, 300])])
        let painted = try bitmap(PlanCanvas(plan: drawn, showsRobot: false, showsLabels: false))
        let bare = try bitmap(PlanCanvas(plan: try plan(), showsRobot: false, showsLabels: false))
        let carpet = rect(CGRect(x: 22, y: 22, width: 36, height: 36), on: drawn)
        let changed = painted.pixels(differingFrom: bare, in: carpet)
        XCTAssertGreaterThan(changed, Int(carpet.width * carpet.height) / 5)
        XCTAssertLessThan(changed, Int(carpet.width * carpet.height) * 9 / 10, "A hatch, not a flat tint")
        XCTAssertEqual(painted.pixels(differingFrom: bare, in: rect(CGRect(x: 65, y: 65, width: 30, height: 30), on: drawn)), 0)
    }

    func testDarkModeSkipsTheShadow() throws {
        let small = try Sketch.plan([Sketch.Room(id: "1", rect: CGRect(x: 40, y: 40, width: 20, height: 20)),
                                     Sketch.Room(id: "2", rect: CGRect(x: 0, y: 0, width: 4, height: 4)),
                                     Sketch.Room(id: "3", rect: CGRect(x: 96, y: 96, width: 4, height: 4))])
        let image = try bitmap(PlanCanvas(plan: small, showsRobot: false, showsLabels: false), scheme: .dark)
        XCTAssertEqual(image.alpha(at: point(CGPoint(x: 50, y: 62), on: small)), 0)
    }

    // MARK: The job

    func testAJobDrawsALineInsideTheRoomsWalls() throws {
        let job = try bitmap(PlanCanvas(plan: try plan(active: true), active: true, showsRobot: false, showsLabels: false))
        let idle = try bitmap(PlanCanvas(plan: try plan(), showsRobot: false, showsLabels: false))
        let room = rect(CGRect(x: 0, y: 0, width: 100, height: 100), on: try plan())
        let edge = job.pixel(at: CGPoint(x: room.midX, y: room.minY + 1.5))
        XCTAssertGreaterThan(Int(edge[2]), Int(edge[0]) + 60, "Cobalt, at the room's edge")
        let middle = CGPoint(x: room.midX, y: room.midY)
        XCTAssertEqual(job.pixel(at: middle), idle.pixel(at: middle), "The room keeps its colour")
    }

    func testALineInANarrowRoomLeavesItsColourShowing() throws {
        let hall = CGRect(x: 0, y: 48, width: 100, height: 4)
        let idle = try Sketch.plan([Sketch.Room(id: "1", rect: hall)])
        let job = try Sketch.plan([Sketch.Room(id: "1", rect: hall, active: true)])
        let middle = point(CGPoint(x: 50, y: 50), on: job)
        for strong in [false, true] {
            let marked = try bitmap(PlanCanvas(plan: job, active: true, showsRobot: false, showsLabels: false), strong: strong)
            let plain = try bitmap(PlanCanvas(plan: idle, showsRobot: false, showsLabels: false), strong: strong)
            XCTAssertEqual(marked.pixel(at: middle), plain.pixel(at: middle), "strong: \(strong)")
        }
    }

    func testARunningZoneIsNotTheColourOfAPickedOne() throws {
        let drawn = try plan(entities: [Sketch.entity("active_zone", [50, 50, 250, 50, 250, 250, 50, 250])])
        let inside = try structures(of: drawn).pixel(at: point(CGPoint(x: 30, y: 30), on: drawn))
        XCTAssertGreaterThan(inside[1], inside[2], "Green rather than blue")
    }

    // MARK: Zoom

    func testZoomingInAddsASecondLineToTheLabel() throws {
        let drawn = try plan()
        func darkestBelowTheName(zoom: CGFloat) throws -> Int {
            let middle = PlanTransform(bounds: drawn.bounds, size: Self.size, zoom: zoom).toView(try XCTUnwrap(drawn.rooms.first).label)
            return try bitmap(PlanCanvas(plan: drawn, showsRobot: false, zoom: zoom))
                .darkest(in: CGRect(x: middle.x - 30, y: middle.y + 10, width: 60, height: 12))
        }
        XCTAssertLessThan(try darkestBelowTheName(zoom: 3), 170)
        XCTAssertGreaterThan(try darkestBelowTheName(zoom: 2.4), 170)
    }

    // MARK: Increase Contrast

    /// Cobalt is the colour of the split line, the trail, the predicted path and the pin, so a
    /// picked room can't be filled with it, whatever the setting.
    func testASplitLineShowsOnAPickedRoomWithIncreaseContrast() throws {
        let drawn = try plan()
        func linePixels(scheme: ColorScheme, strong: Bool) throws -> Int {
            let bare = PlanCanvas(plan: drawn, selected: ["1"], showsRobot: false, showsLabels: false)
            let lined = PlanCanvas(plan: drawn, selected: ["1"], showsRobot: false, showsLabels: false, overlay: splitLine)
            return try bitmap(lined, scheme: scheme, strong: strong).differingPixels(from: try bitmap(bare, scheme: scheme, strong: strong))
        }
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThan(try linePixels(scheme: scheme, strong: true), try linePixels(scheme: scheme, strong: false) * 8 / 10, "\(scheme)")
        }
    }

    func testTheTrailShowsOnAPickedRoomWithIncreaseContrast() throws {
        let drawn = try plan(entities: [Sketch.entity("path", [100, 100, 400, 100])])
        let image = try bitmap(PlanCanvas(plan: drawn, selected: ["1"], showsRobot: false, showsLabels: false), strong: true)
        XCTAssertNotEqual(image.pixel(at: point(CGPoint(x: 50, y: 20), on: drawn)), image.pixel(at: point(CGPoint(x: 50, y: 70), on: drawn)))
    }

    func testIncreaseContrastEdgesAPickedRoom() throws {
        let drawn = try plan()
        let room = rect(CGRect(x: 0, y: 0, width: 100, height: 100), on: drawn)
        let edge = CGPoint(x: room.midX, y: room.minY + 2)
        let view = PlanCanvas(plan: drawn, selected: ["1"], showsRobot: false, showsLabels: false)
        let strong = try bitmap(view, strong: true), standard = try bitmap(view)
        XCTAssertLessThan(Int(strong.pixel(at: edge)[0]), Int(standard.pixel(at: edge)[0]) - 50)
        let middle = CGPoint(x: room.midX, y: room.midY)
        XCTAssertEqual(strong.pixel(at: middle), standard.pixel(at: middle), "Only the edge changes")
    }

    func testIncreaseContrastStrengthensZonesAndTheJob() throws {
        let drawn = try plan(entities: [noGo, Sketch.entity("active_zone", [300, 50, 400, 50, 400, 150, 300, 150])])
        let standard = try structures(of: drawn), strong = try structures(of: drawn, strong: true)
        for spot in [CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 20)] {
            let p = point(spot, on: drawn)
            XCTAssertGreaterThan(Int(strong.alpha(at: p)), Int(standard.alpha(at: p)) + 20, "\(spot)")
        }
    }

    func testIncreaseContrastStrengthensTheTrailAndPredictedPath() throws {
        let drawn = try Sketch.plan([], wall: CGRect(x: 0, y: 0, width: 100, height: 1), entities: [
            Sketch.entity("path", [50, 100, 450, 100]),
            Sketch.entity("predicted_path", [50, 200, 450, 200])
        ])
        // Dark mode has no shadow, so what's left on a clear surface is the two lines.
        func alphas(strong: Bool) throws -> (trail: Int, predicted: Int) {
            let image = try bitmap(PlanCanvas(plan: drawn, showsRobot: false, showsLabels: false), scheme: .dark, strong: strong)
            let line = point(CGPoint(x: 10, y: 40), on: drawn)
            return (Int(image.alpha(at: point(CGPoint(x: 50, y: 20), on: drawn))),
                    image.strongestAlpha(in: CGRect(x: line.x, y: line.y - 2, width: 120, height: 4)))
        }
        let standard = try alphas(strong: false), strong = try alphas(strong: true)
        XCTAssertGreaterThan(strong.trail, standard.trail + 20)
        XCTAssertGreaterThan(strong.predicted, standard.predicted + 20)
    }

    func testIncreaseContrastMakesLabelsSolid() throws {
        let drawn = try plan()
        let spot = try labelBacking(on: drawn)
        let white: [UInt8] = [255, 255, 255, 255]
        XCTAssertEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false), strong: true).pixel(at: spot), white)
        XCTAssertNotEqual(try bitmap(PlanCanvas(plan: drawn, showsRobot: false)).pixel(at: spot), white)
    }

    func testAPickedShapeStandsOutFromTheRestInEitherContrast() throws {
        let shape = PlanShape(kind: .noGo, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10), CGPoint(x: 90, y: 90), CGPoint(x: 10, y: 90)])
        func alpha(highlighted: Bool, strong: Bool) throws -> Int {
            Int(try bitmap(Canvas { context, size in
                PlanCanvas.draw(shape, highlighted: highlighted, in: context,
                                PlanTransform(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), size: size))
            }, strong: strong).alpha(at: CGPoint(x: 100, y: 100)))
        }
        for strong in [false, true] {
            XCTAssertGreaterThan(try alpha(highlighted: true, strong: strong), try alpha(highlighted: false, strong: strong) + 30, "strong: \(strong)")
        }
    }
}

@MainActor
final class DesignSystemPaintingTests: XCTestCase {
    private static let picker = CGSize(width: 200, height: 42)

    private var segments: some View {
        SlidingPicker(options: ["One", "Two"], selection: "One", title: { $0 }, onSelect: { _ in }).background(Theme.mist)
    }

    func testTheSelectedSegmentShowsOnItsTrackInDarkMode() throws {
        let image = try paint(segments, size: Self.picker, scheme: .dark)
        // Beside the labels, which sit in the middle of each segment.
        let selected = image.pixel(at: CGPoint(x: 14, y: 21)), plain = image.pixel(at: CGPoint(x: 186, y: 21))
        XCTAssertGreaterThan(Int(selected[0]), Int(plain[0]) + 25)
    }

    func testIncreaseContrastOutlinesTheSelectedSegment() throws {
        let edge = CGRect(x: 0, y: 12, width: 12, height: 18)
        let standard = try paint(segments, size: Self.picker).darkest(in: edge)
        let strong = try paint(segments, size: Self.picker, strong: true).darkest(in: edge)
        XCTAssertLessThan(strong, standard - 40)
    }

    func testNoticeTextIsInkRatherThanItsTone() throws {
        for tone in [Tone.warning, .critical] {
            let size = CGSize(width: 300, height: 44)
            let image = try paint(Banner(text: "Check the dustbin", tone: tone).background(Theme.mist), size: size)
            // Amber and rose both keep plenty of red, so tinted text never gets this dark.
            XCTAssertLessThan(image.darkest(in: CGRect(origin: .zero, size: size)), 60, "\(tone)")
        }
    }

    func testStatusTileTextIsInkRatherThanItsTone() throws {
        for tone in [Tone.warning, .critical] {
            let image = try paint(StatusTile(title: "Main Brush", value: "Replace soon", symbol: "gearshape", tone: tone).background(Theme.mist),
                                  size: CGSize(width: 240, height: 58))
            XCTAssertLessThan(image.darkest(in: CGRect(x: 40, y: 30, width: 200, height: 22)), 60, "Value \(tone)")
            XCTAssertLessThan(image.darkest(in: CGRect(x: 40, y: 8, width: 200, height: 20)), 120, "Title \(tone)")
        }
    }

    func testABannerIsATapTargetEvenOnOneLine() {
        let banner = UIHostingController(rootView: Banner(text: "Hi", action: {}))
        XCTAssertGreaterThanOrEqual(banner.sizeThatFits(in: CGSize(width: 300, height: 400)).height, Metric.hitTarget)
    }
}

/// A view in a real window, for what an offscreen render can't show: `onChange`, animation and glass.
@MainActor
private final class Stage {
    private let window: UIWindow

    init<V: View>(_ view: V, size: CGSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    /// What's on screen this moment, partway through any animation.
    func frame() throws -> Bitmap {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return try Bitmap(try XCTUnwrap(image.cgImage))
    }

    /// Frames from now until a little after an animation of `duration` has ended.
    func frames(for duration: Duration) async throws -> [Bitmap] {
        var frames: [Bitmap] = []
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: duration)
        while clock.now < end {
            try await Task.sleep(for: .milliseconds(25))
            frames.append(try frame())
        }
        return frames
    }

    func close() { window.isHidden = true }
}

@Observable @MainActor
private final class Screen {
    var heading = 355.0
    var toast: Toast?
    var spoken: [String] = []
    var haptics: [PlanHaptic] = []
}

@MainActor
final class RobotMarkerTests: XCTestCase {
    private struct Marker: View {
        let screen: Screen

        var body: some View {
            ZStack {
                Color.white
                RobotMarker(active: false, heading: screen.heading)
            }
        }
    }

    func testTheBeamTurnsTheShortWayThroughNorth() async throws {
        let screen = Screen()
        let stage = try Stage(Marker(screen: screen), size: CGSize(width: 100, height: 100))
        defer { stage.close() }
        try await Task.sleep(for: .milliseconds(400))
        screen.heading = 5
        let frames = try await stage.frames(for: .seconds(0.9))
        func tinted(_ pixel: [UInt8]) -> Bool { pixel[0] < 240 }
        // The beam points up the whole way. The long way round, it would sweep through here.
        let below = CGRect(x: 25, y: 76, width: 50, height: 10)
        XCTAssertEqual(frames.map { $0.pixels(in: below, where: tinted) }.max(), 0)
        XCTAssertGreaterThan(try XCTUnwrap(frames.last).pixels(in: CGRect(x: 25, y: 18, width: 50, height: 10), where: tinted), 0, "The beam is on screen")
    }
}

@MainActor
final class PlanCameraTests: XCTestCase {
    private final class Press {
        var action: (() -> Void)?
    }

    /// Keeps hold of a button's action, because a test can't tap one. The opacity matters:
    /// SwiftUI never calls a style whose body is the bare label.
    private struct KeepsAction: PrimitiveButtonStyle {
        let press: Press

        func makeBody(configuration: Configuration) -> some View {
            press.action = configuration.trigger
            return configuration.label.opacity(1)
        }
    }

    func testFitSnapsTheRobotRatherThanSlidingIt() async throws {
        let size = CGSize(width: 200, height: 200)
        let plan = try Sketch.plan([Sketch.room], entities: [Sketch.entity("robot_position", [200, 200])])
        let press = Press()
        let stage = try Stage(PlanCanvas(plan: plan, zoom: 3).buttonStyle(KeepsAction(press: press)), size: size)
        defer { stage.close() }
        try await Task.sleep(for: .milliseconds(400))

        func robot(_ frame: Bitmap) -> CGFloat? { frame.middle { Int($0[2]) > Int($0[0]) + 100 }?.x }
        let zoomed = try XCTUnwrap(robot(try stage.frame()))
        let fit = PlanTransform(bounds: plan.bounds, size: size).toView(CGPoint(x: 40, y: 40)).x
        XCTAssertGreaterThan(abs(fit - zoomed), 20, "Far enough apart to see anything between them")

        try XCTUnwrap(press.action)()
        let seen = try await stage.frames(for: .seconds(0.6)).compactMap(robot)
        for x in seen { XCTAssertLessThan(min(abs(x - zoomed), abs(x - fit)), 3, "Partway there") }
        XCTAssertEqual(try XCTUnwrap(seen.last), fit, accuracy: 3)
    }
}

@MainActor
final class ToastHostTests: XCTestCase {
    /// A sheet over a screen: two hosts, both showing the store's toast.
    private struct Nested: View {
        let screen: Screen

        private var host: ToastHost {
            ToastHost(toast: screen.toast, haptic: { screen.haptics.append($0) }, announce: { screen.spoken.append($0) })
        }

        var body: some View {
            Color.yellow.modifier(host).modifier(host)
        }
    }

    private struct Plain: View {
        let screen: Screen

        var body: some View {
            Color.yellow.modifier(ToastHost(toast: screen.toast))
        }
    }

    private static let window = CGSize(width: 402, height: 300)

    /// Long enough for `onChange` to have run, including a second time if something's wrong.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    func testAToastIsPlayedOnceHoweverManyHostsSeeIt() async throws {
        let screen = Screen()
        let stage = try Stage(Nested(screen: screen), size: Self.window)
        defer { stage.close() }
        try await settle()
        screen.toast = Toast(message: "Saved")
        try await settle()
        XCTAssertEqual(screen.spoken, ["Saved"])
        XCTAssertEqual(screen.haptics, [.success])
    }

    func testAProblemPlaysTheWarningAndStillSpeaks() async throws {
        let screen = Screen()
        let stage = try Stage(Nested(screen: screen), size: Self.window)
        defer { stage.close() }
        try await settle()
        screen.toast = Toast(message: "Couldn't reach the robot", isProblem: true)
        try await settle()
        XCTAssertEqual(screen.spoken, ["Couldn't reach the robot"])
        XCTAssertEqual(screen.haptics, [.warning])
    }

    /// As when saving the password fails while connecting: the toast is set before the screen exists.
    func testAToastAlreadyUpWhenTheHostAppearsIsStillPlayed() async throws {
        let screen = Screen()
        screen.toast = Toast(message: "Couldn't save the password", isProblem: true)
        let stage = try Stage(Nested(screen: screen), size: Self.window)
        defer { stage.close() }
        try await settle()
        XCTAssertEqual(screen.spoken, ["Couldn't save the password"])
        XCTAssertEqual(screen.haptics, [.warning])
    }

    /// Text is the only thing on the yellow with no red in it.
    private func isText(_ pixel: [UInt8]) -> Bool { pixel[0] < 200 }

    /// How many points of text a message takes up on screen, against how many it needs.
    private func height(of message: String, at type: DynamicTypeSize) async throws -> (shown: Int, needed: CGFloat) {
        let screen = Screen()
        screen.toast = Toast(message: message)
        let stage = try Stage(Plain(screen: screen).environment(\.dynamicTypeSize, type), size: CGSize(width: 402, height: 500))
        defer { stage.close() }
        try await settle()
        let rows = try XCTUnwrap(try stage.frame().rows(where: isText))
        let label = Label(message, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).environment(\.dynamicTypeSize, type)
        // The window less the toast's margins and padding.
        let needed = UIHostingController(rootView: label).sizeThatFits(in: CGSize(width: 402 - 48 - 32, height: 2000)).height
        return (rows.count, needed)
    }

    func testALongErrorKeepsItsEnding() async throws {
        let split = "Failed to split segment. Both ends of the cutting line need to be connected with a wall surrounding the chosen segment."
        let longest = String(repeating: "Cannot do that right now because of something. ", count: 5).prefix(199)
        for (message, type) in [(split, DynamicTypeSize.xxLarge), (String(longest), .large)] {
            let height = try await height(of: message, at: type)
            // Rows of text run from the top of the first line to the bottom of the last.
            XCTAssertGreaterThan(CGFloat(height.shown), height.needed - 12, "\(type)")
        }
    }

    func testAPanelOfSeveralLinesKeepsItsCorners() async throws {
        let screen = Screen()
        screen.toast = Toast(message: String(repeating: "Several lines of text. ", count: 6))
        let stage = try Stage(Plain(screen: screen), size: Self.window)
        defer { stage.close() }
        try await settle()
        let frame = try stage.frame()
        let yellow = frame.pixel(at: CGPoint(x: 10, y: 290))
        func isGlass(_ pixel: [UInt8]) -> Bool { abs(Int(pixel[2]) - Int(yellow[2])) > 24 }
        let panel = try XCTUnwrap(frame.rows(where: isGlass))
        // Margin of 24 at the side. A capsule this tall would have curved away from this spot.
        let corner = CGPoint(x: 24 + 11, y: CGFloat(panel.lowerBound) + 11)
        XCTAssertTrue(isGlass(frame.pixel(at: corner)))
    }

    func testReduceMotionFadesTheToastInPlace() async throws {
        let screen = Screen()
        let stage = try Stage(Plain(screen: screen).environment(\._accessibilityReduceMotion, true), size: Self.window)
        defer { stage.close() }
        try await settle()
        screen.toast = Toast(message: "Saved")
        let tops = try await stage.frames(for: .seconds(0.5)).compactMap { $0.rows(where: isText)?.lowerBound }
        XCTAssertLessThanOrEqual(try XCTUnwrap(tops.max()) - (try XCTUnwrap(tops.min())), 2)
    }
}

/// Contrast worked out from the colours the system really resolves, the WCAG way.
final class ContrastTests: XCTestCase {
    private typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

    private func traits(_ style: UIUserInterfaceStyle, elevated: Bool = false, strong: Bool = false) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.userInterfaceLevel = elevated ? .elevated : .base
            traits.accessibilityContrast = strong ? .high : .normal
        }
    }

    private func rgb(_ color: Color, _ traits: UITraitCollection) -> RGB {
        var c: RGB = (0, 0, 0, 0)
        UIColor(color).resolvedColor(with: traits).getRed(&c.r, green: &c.g, blue: &c.b, alpha: &c.a)
        return c
    }

    private func over(_ top: RGB, _ bottom: RGB) -> RGB {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * top.a + b * (1 - top.a) }
        return (mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b), 1)
    }

    private func luminance(_ c: RGB) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func ratio(_ a: RGB, _ b: RGB) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testTheSelectedPillShowsOnItsTrackInDarkMode() {
        for elevated in [false, true] {
            let dark = traits(.dark, elevated: elevated)
            let track = over(rgb(Theme.track, dark), rgb(Theme.mist, dark))
            XCTAssertGreaterThan(ratio(rgb(Theme.pill, dark), track), 2, "elevated: \(elevated)")
        }
    }

    func testPickerTextStaysReadableOnThePill() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let t = traits(style)
            XCTAssertGreaterThanOrEqual(ratio(rgb(Theme.ink, t), rgb(Theme.pill, t)), 4.5)
        }
    }

    func testNoticeTextReachesAAOnItsOwnWash() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for elevated in [false, true] {
                let t = traits(style, elevated: elevated)
                for tone in [Tone.neutral, .good, .warning, .critical] {
                    let fill = over(rgb(tone.wash, t), rgb(Theme.mist, t))
                    XCTAssertGreaterThanOrEqual(ratio(rgb(Theme.ink, t), fill), 4.5, "\(tone) \(style.rawValue)")
                }
            }
        }
    }

    func testStatusTileTitlesReachAA() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for elevated in [false, true] {
                let t = traits(style, elevated: elevated)
                let backgrounds = [rgb(Theme.paper, t)]
                    + [Tone.warning, .critical].map { over(rgb($0.wash, t), rgb(Theme.mist, t)) }
                for background in backgrounds {
                    let title = over(rgb(Theme.quietInk, t), background)
                    XCTAssertGreaterThanOrEqual(ratio(title, background), 4.5, "\(style.rawValue)")
                }
            }
        }
    }

    func testARunningZoneShowsOnEveryRoom() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for strong in [false, true] {
                let t = traits(style, strong: strong)
                for room in Theme.rooms {
                    XCTAssertGreaterThanOrEqual(ratio(rgb(Theme.working, t), rgb(room, t)), 3, "\(style.rawValue) strong: \(strong)")
                }
            }
        }
    }

    func testThePickedEdgeShowsOnAPickedRoom() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let t = traits(style, strong: true)
            XCTAssertGreaterThan(ratio(rgb(Theme.cobalt, t), rgb(Theme.selected, t)), 2.5, "\(style.rawValue)")
        }
    }

    func testNoticeSymbolsStayVisibleOnTheirWash() {
        let light = traits(.light)
        for tone in [Tone.warning, .critical] {
            let fill = over(rgb(tone.wash, light), rgb(Theme.mist, light))
            XCTAssertGreaterThanOrEqual(ratio(rgb(tone.color, light), fill), 3)
        }
    }
}

/// A rendered image as bytes, so two renders can be compared and single pixels read.
private struct Bitmap: Equatable, CustomStringConvertible {
    private let width: Int
    private let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space, bitmapInfo: info))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    func pixel(at point: CGPoint) -> [UInt8] {
        let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
        let start = (y * width + x) * 4
        return Array(bytes[start..<start + 4])
    }

    func alpha(at point: CGPoint) -> UInt8 { pixel(at: point)[3] }

    private func points(in rect: CGRect) -> [CGPoint] {
        let box = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !box.isNull else { return [] }
        return (Int(box.minY)..<Int(box.maxY)).flatMap { y in
            (Int(box.minX)..<Int(box.maxX)).map { CGPoint(x: $0, y: y) }
        }
    }

    func pixels(in rect: CGRect, where test: ([UInt8]) -> Bool) -> Int {
        points(in: rect).filter { test(pixel(at: $0)) }.count
    }

    /// How many pixels show any real difference from the same pixel in `other`.
    func pixels(differingFrom other: Bitmap, in rect: CGRect) -> Int {
        points(in: rect).filter { point in
            zip(pixel(at: point), other.pixel(at: point)).contains { abs(Int($0) - Int($1)) > 6 }
        }.count
    }

    /// The lowest "brightest channel" in an area, so black text scores near 0 and amber text 154.
    func darkest(in rect: CGRect) -> Int {
        points(in: rect).map { Int(pixel(at: $0)[0..<3].max() ?? 0) }.min() ?? 255
    }

    func strongestAlpha(in rect: CGRect) -> Int {
        points(in: rect).map { Int(alpha(at: $0)) }.max() ?? 0
    }

    /// The middle of all the matching pixels.
    func middle(where test: ([UInt8]) -> Bool) -> CGPoint? {
        let matching = points(in: CGRect(x: 0, y: 0, width: width, height: height)).filter { test(pixel(at: $0)) }
        guard !matching.isEmpty else { return nil }
        let count = CGFloat(matching.count)
        return CGPoint(x: matching.map(\.x).reduce(0, +) / count, y: matching.map(\.y).reduce(0, +) / count)
    }

    /// The rows that hold a matching pixel, from the first to the last.
    func rows(where test: ([UInt8]) -> Bool) -> ClosedRange<Int>? {
        let matching = (0..<height).filter { y in
            (0..<width).contains { test(pixel(at: CGPoint(x: $0, y: y))) }
        }
        guard let first = matching.first, let last = matching.last else { return nil }
        return first...last
    }

    /// How many pixels are clearly different, ignoring the small changes antialiasing makes.
    func differingPixels(from other: Bitmap) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { start in
            (0..<4).contains { abs(Int(bytes[start + $0]) - Int(other.bytes[start + $0])) > 40 }
        }.count
    }

    /// A failed comparison would otherwise print every byte.
    var description: String { "\(width) by \(height) image" }
}

final class CleaningWhereTests: XCTestCase {
    private let rooms = [Sketch.Room(id: "1", rect: CGRect(x: 0, y: 0, width: 20, height: 20), active: true),
                         Sketch.Room(id: "2", rect: CGRect(x: 20, y: 0, width: 20, height: 20), active: true),
                         Sketch.Room(id: "3", rect: CGRect(x: 40, y: 0, width: 20, height: 20))]

    func testTheRoomTheRobotIsInIsNamed() throws {
        // Entities are in centimetres: 150 cm is pixel 30, inside room 2.
        let plan = try Sketch.plan(rooms, entities: [Sketch.entity("robot_position", [150, 50])])
        XCTAssertEqual(plan.cleaningWhere, "Room 2")
    }

    func testWithTheRobotOutsideTheJobTheJobsRoomsAreNamed() throws {
        let plan = try Sketch.plan(rooms, entities: [Sketch.entity("robot_position", [250, 50])])
        XCTAssertEqual(plan.cleaningWhere, "Room 1 and Room 2")
    }

    func testManyRoomsAreCounted() throws {
        let all = rooms.map { var room = $0; room.active = true; return room }
        XCTAssertEqual(try Sketch.plan(all).cleaningWhere, "3 rooms")
    }

    func testNoMarkedRoomsLeavesItToTheCaller() throws {
        XCTAssertNil(try Sketch.plan([Sketch.room]).cleaningWhere)
    }
}
