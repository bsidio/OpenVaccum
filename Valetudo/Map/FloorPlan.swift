import SwiftUI

/// A Valetudo map turned into drawable paths, in map pixels.
/// Entities arrive in centimetres and are divided by `pixelSize` here.
struct FloorPlan {
    struct Room: Identifiable {
        let id: String
        let name: String
        let path: Path
        let label: CGPoint
        /// Part of the job under way. Some robots flag every room in the job, not just the one
        /// they're in, so this can't be read as where the robot is.
        let active: Bool
        /// Lines suggesting the floor type, in map pixels.
        let texture: Path
        /// In square metres.
        let area: Double
        /// How wide it mostly is, in map pixels: its pixels over its longest side, so a hall that
        /// turns a corner still counts as narrow, which its bounding box wouldn't show.
        let span: CGFloat
        /// Its colour in `Theme.rooms`, which no room facing it shares.
        fileprivate(set) var palette = 0
    }

    struct Obstacle: Identifiable {
        static let genericSymbol = "exclamationmark"

        let id: String
        let label: String
        let hasPhoto: Bool
        let point: CGPoint
        /// What Vision recognized in the photo, when the robot's own label says nothing useful.
        var recognized: String?

        var title: String { recognized ?? label }
        var symbol: String { Self.symbol(forLabel: title) }
        var isUnnamed: Bool { Self.symbol(forLabel: label) == Self.genericSymbol }

        /// Whole words, in priority order. Labels vary by robot brand, and Vision has its own
        /// vocabulary, so this covers the words both use. "Pet Bowl" should stay a pet thing.
        private static let symbols: [(symbol: String, words: Set<String>)] = [
            ("dog.fill", ["dog", "puppy", "canine"]),
            ("cat.fill", ["cat", "kitten"]),
            ("pawprint.fill", ["pet", "animal", "poop", "feces", "excrement"]),
            ("cable.connector", ["cable", "cord", "wire", "thread", "rope"]),
            ("shoe.fill", ["shoe", "shoes", "sneaker", "sandal", "boot", "slipper", "slippers"]),
            ("tshirt.fill", ["sock", "socks", "fabric", "cloth", "clothing", "towel", "textile"]),
            ("sofa.fill", ["sofa", "couch", "armchair"]),
            ("chair.fill", ["furniture", "chair", "stool", "table"]),
            ("teddybear.fill", ["toy", "stuffed", "doll", "blocks"]),
            ("soccerball", ["ball"]),
            ("trash.fill", ["trash", "bin", "garbage"]),
            ("scalemass.fill", ["scale", "weighing"]),
            ("drop.fill", ["stain", "liquid", "spill", "water"]),
            ("backpack.fill", ["backpack"]),
            ("suitcase.fill", ["luggage", "suitcase"]),
            ("bag.fill", ["bag", "purse"]),
            ("shippingbox.fill", ["box", "carton"]),
            ("waterbottle.fill", ["bottle"]),
            ("cup.and.saucer.fill", ["cup", "mug"]),
            ("book.fill", ["book", "magazine", "newspaper"]),
            ("leaf.fill", ["plant"]),
            ("umbrella.fill", ["umbrella"]),
            ("bolt.fill", ["dock"])
        ]

        static func symbol(forLabel label: String) -> String {
            let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
            return symbols.first { !$0.words.isDisjoint(with: words) }?.symbol ?? genericSymbol
        }
    }

    let pixelSize: CGFloat
    let floor: Path
    let walls: Path
    /// Everything mapped, as one shape. Some robots send no floor layer at all.
    let footprint: Path
    let rooms: [Room]
    let trail: Path
    let predicted: Path
    let noGo: Path
    let noMop: Path
    let virtualWalls: Path
    /// Virtual walls, no-go zones and no-mop zones, as the editor draws them.
    let restrictions: [PlanShape]
    /// Where the robot is cleaning a zone right now.
    let activeZones: Path
    /// Where the robot is on its way to.
    let goToTarget: CGPoint?
    let robot: CGPoint?
    let heading: Double
    let dock: CGPoint?
    private(set) var obstacles: [Obstacle]
    let annotations: [PlanShape]
    let carpets: Path
    /// Lines to clip to `carpets`.
    let carpetHatch: Path
    let bounds: CGRect
    private let cells: [Int: String]
    private let walkable: Set<Int>

    var isEmpty: Bool { floor.isEmpty && walls.isEmpty && rooms.isEmpty }

    /// For spoken labels.
    var roomCount: String { rooms.count == 1 ? "1 room" : "\(rooms.count) rooms" }

    /// Adds what Vision recognized, by obstacle id.
    mutating func note(_ recognized: [String: String]) {
        for index in obstacles.indices {
            obstacles[index].recognized = recognized[obstacles[index].id]
        }
    }

    private static func key(_ x: Int, _ y: Int) -> Int { x << 20 | y }

    /// One row of a room, in map pixels. `room` is its place in the unsorted list.
    private struct RoomRun {
        let x, y, length, room: Int
    }

    init(_ map: RawMap) {
        let size = map.pixelSize > 0 ? CGFloat(map.pixelSize) : 5
        pixelSize = size

        var floor = Path(), walls = Path()
        var rooms: [Room] = []
        var cells: [Int: String] = [:]
        var walkable = Set<Int>()
        var roomRuns: [RoomRun] = []

        for layer in map.layers {
            let runs = layer.runs
            var path = Path()
            var own: [(Int, Int)] = []
            var i = 0
            while i + 2 < runs.count {
                path.addRect(CGRect(x: runs[i], y: runs[i + 1], width: runs[i + 2], height: 1))
                if layer.type == "segment" {
                    for k in 0..<runs[i + 2] { own.append((runs[i] + k, runs[i + 1])) }
                    roomRuns.append(RoomRun(x: runs[i], y: runs[i + 1], length: runs[i + 2], room: rooms.count))
                }
                if layer.type == "segment" || layer.type == "floor" {
                    for k in 0..<runs[i + 2] { walkable.insert(Self.key(runs[i] + k, runs[i + 1])) }
                }
                i += 3
            }
            switch layer.type {
            case "floor": floor.addPath(path)
            case "wall": walls.addPath(path)
            case "segment":
                let id = layer.metaData?.segmentId ?? "\(rooms.count)"
                for cell in own { cells[Self.key(cell.0, cell.1)] = id }
                rooms.append(Room(id: id, name: layer.metaData?.name ?? "Room \(id)",
                                  path: path, label: Self.labelPoint(own),
                                  active: layer.metaData?.active ?? false,
                                  texture: Self.texture(for: layer.metaData?.material, in: path.boundingRect),
                                  area: Double(own.count) * Double(size * size) / 10_000,
                                  span: CGFloat(own.count) / max(path.boundingRect.width, path.boundingRect.height, 1)))
            default: break
            }
        }

        var trail = Path(), predicted = Path(), noGo = Path(), noMop = Path(), virtualWalls = Path()
        var robot: CGPoint?, dock: CGPoint?, goToTarget: CGPoint?
        var heading = 0.0
        var obstacles: [Obstacle] = []
        var restrictions: [PlanShape] = []
        var annotations: [PlanShape] = []
        var carpets = Path(), activeZones = Path()

        for entity in map.entities {
            var points: [CGPoint] = []
            var i = 0
            while i + 1 < entity.points.count {
                points.append(CGPoint(x: entity.points[i] / size, y: entity.points[i + 1] / size))
                i += 2
            }
            switch entity.type {
            case "robot_position":
                robot = points.first
                heading = entity.metaData?.angle ?? 0
            case "charger_location": dock = points.first
            case "obstacle":
                if let p = points.first {
                    let meta = entity.metaData
                    obstacles.append(Obstacle(id: meta?.id ?? "\(obstacles.count)", label: meta?.label ?? "Obstacle",
                                              hasPhoto: meta?.image != nil, point: p))
                }
            case "threshold": annotations.append(PlanShape(kind: .threshold, points: points))
            case "curtain": annotations.append(PlanShape(kind: .curtain, points: points))
            case "ramp": annotations.append(PlanShape(kind: .ramp, points: points))
            case "carpet":
                carpets.addLines(points)
                carpets.closeSubpath()
            case "path": trail.addLines(points)
            case "predicted_path": predicted.addLines(points)
            case "virtual_wall":
                virtualWalls.addLines(points)
                restrictions.append(PlanShape(kind: .wall, points: points))
            case "no_go_area":
                noGo.addLines(points)
                noGo.closeSubpath()
                restrictions.append(PlanShape(kind: .noGo, points: points))
            case "no_mop_area":
                noMop.addLines(points)
                noMop.closeSubpath()
                restrictions.append(PlanShape(kind: .noMop, points: points))
            case "active_zone":
                activeZones.addLines(points)
                activeZones.closeSubpath()
            case "go_to_target": goToTarget = points.first
            default: break
            }
        }

        var footprint = floor
        footprint.addPath(walls)
        for room in rooms { footprint.addPath(room.path) }

        let sorted = rooms.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let colors = Self.palette(for: sorted.map(\.id), neighbours: Self.neighbours(roomRuns, ids: rooms.map(\.id)),
                                  colors: Theme.rooms.count)

        self.floor = floor
        self.walls = walls
        self.footprint = footprint
        self.rooms = sorted.map { room in
            var room = room
            room.palette = colors[room.id] ?? 0
            return room
        }
        self.cells = cells
        self.walkable = walkable
        self.trail = trail
        self.predicted = predicted
        self.noGo = noGo
        self.noMop = noMop
        self.virtualWalls = virtualWalls
        self.restrictions = restrictions
        self.activeZones = activeZones
        self.goToTarget = goToTarget
        self.robot = robot
        self.heading = heading
        self.dock = dock
        self.obstacles = obstacles
        self.annotations = annotations
        self.carpets = carpets
        carpetHatch = Self.crosshatch(in: carpets.boundingRect, gap: 3)

        let boxes = ([floor, walls] + rooms.map(\.path)).map(\.boundingRect).filter { !$0.isEmpty && !$0.isNull }
        let union = boxes.dropFirst().reduce(boxes.first ?? CGRect(x: 0, y: 0, width: 100, height: 100)) { $0.union($1) }
        bounds = union.insetBy(dx: -2, dy: -2)
    }

    /// Which rooms face each other along a row or column, as the web interface works it out.
    /// Only another room counts as being in the way, so neighbours can be a wall or a gap apart.
    private static func neighbours(_ runs: [RoomRun], ids: [String]) -> [String: Set<String>] {
        guard let left = runs.map(\.x).min(), let right = runs.map({ $0.x + $0.length }).max() else { return [:] }
        var found: [String: Set<String>] = [:]
        func meet(_ a: Int, _ b: Int) {
            found[ids[a], default: []].insert(ids[b])
            found[ids[b], default: []].insert(ids[a])
        }
        var lastInColumn = [Int?](repeating: nil, count: right - left)
        var previous: RoomRun?
        for run in runs.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if let previous, previous.y == run.y, previous.room != run.room { meet(previous.room, run.room) }
            previous = run
            for column in (run.x - left)..<(run.x - left + run.length) {
                if let above = lastInColumn[column], above != run.room { meet(above, run.room) }
                lastInColumn[column] = run.room
            }
        }
        return found
    }

    /// Colours rooms so that no two facing each other match. The rooms with the most neighbours
    /// choose first, because they have the least choice, and that keeps a hallway from running
    /// out. Each room starts from a colour of its own rather than the lowest free one, so most
    /// rooms keep theirs when others are split or joined. Rooms only share a colour once there
    /// are more rooms than colours.
    static func palette(for ids: [String], neighbours: [String: Set<String>], colors: Int) -> [String: Int] {
        func count(_ index: Int) -> Int { neighbours[ids[index]]?.count ?? 0 }
        let order = ids.indices.sorted { count($0) == count($1) ? $0 < $1 : count($0) > count($1) }
        var chosen: [String: Int] = [:]
        for id in order.map({ ids[$0] }) {
            // Not `hashValue`, which changes on every launch.
            let own = Int(id.utf8.reduce(UInt(0)) { $0 &* 10 &+ UInt($1) } % UInt(colors))
            let tries = (0..<colors).map { (own + $0) % colors }
            let facing = Set(neighbours[id, default: []].compactMap { chosen[$0] })
            let used = Set(chosen.values)
            chosen[id] = tries.first { !facing.contains($0) && !used.contains($0) }
                ?? tries.first { !facing.contains($0) } ?? own
        }
        return chosen
    }

    /// Lines both ways, the look of a carpet on the web interface.
    private static func crosshatch(in box: CGRect, gap: CGFloat) -> Path {
        var path = Path()
        guard !box.isEmpty else { return path }
        var c = box.minX - box.height
        while c <= box.maxX {
            path.move(to: CGPoint(x: c, y: box.minY))
            path.addLine(to: CGPoint(x: c + box.height, y: box.maxY))
            path.move(to: CGPoint(x: c + box.height, y: box.minY))
            path.addLine(to: CGPoint(x: c, y: box.maxY))
            c += gap
        }
        return path
    }

    /// Faint lines suggesting wood, tile or carpet, one look for each material the web interface
    /// draws. Sizes are in map pixels, usually 5 cm each.
    static func texture(for material: String?, in box: CGRect) -> Path {
        var path = Path()
        guard !box.isEmpty, let material else { return path }

        func planks(alongX: Bool) {
            let plank: CGFloat = 3, length: CGFloat = 26
            let across = alongX ? (box.minY, box.maxY) : (box.minX, box.maxX)
            let along = alongX ? (box.minX, box.maxX) : (box.minY, box.maxY)
            func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint { alongX ? CGPoint(x: a, y: b) : CGPoint(x: b, y: a) }
            var row = 0
            var b = across.0
            while b <= across.1 {
                path.move(to: point(along.0, b))
                path.addLine(to: point(along.1, b))
                // Stagger the joints, as real boards are laid.
                var a = along.0 + (row % 3 == 0 ? 0 : row % 3 == 1 ? length / 3 : length * 2 / 3)
                while a <= along.1 {
                    path.move(to: point(a, b))
                    path.addLine(to: point(a, b + plank))
                    a += length
                }
                b += plank
                row += 1
            }
        }

        func chevrons() {
            let plank: CGFloat = 4, section: CGFloat = 8
            var y = box.minY - section
            while y <= box.maxY {
                path.move(to: CGPoint(x: box.minX, y: y))
                var x = box.minX, turns = 0
                while x <= box.maxX {
                    x += section
                    turns += 1
                    path.addLine(to: CGPoint(x: x, y: y + (turns % 2 == 0 ? 0 : section)))
                }
                y += plank
            }
        }

        switch material {
        case "wood":
            chevrons()
        case "wood_horizontal":
            planks(alongX: true)
        case "wood_vertical":
            planks(alongX: false)
        case "tile":
            let size: CGFloat = 12
            var x = box.minX
            while x <= box.maxX {
                path.move(to: CGPoint(x: x, y: box.minY))
                path.addLine(to: CGPoint(x: x, y: box.maxY))
                x += size
            }
            var y = box.minY
            while y <= box.maxY {
                path.move(to: CGPoint(x: box.minX, y: y))
                path.addLine(to: CGPoint(x: box.maxX, y: y))
                y += size
            }
        case "carpet":
            return crosshatch(in: box, gap: 3)
        case "carpet_low":
            return crosshatch(in: box, gap: 5)
        case "carpet_high":
            return crosshatch(in: box, gap: 2)
        default:
            break
        }
        return path
    }

    /// The closest open floor to a point, looking no further than `radius` map pixels.
    func nearestFloor(to point: CGPoint, within radius: Int) -> CGPoint? {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        if walkable.contains(Self.key(x, y)) { return point }
        var best: (x: Int, y: Int, distance: Int)?
        for dy in -radius...radius {
            for dx in -radius...radius where walkable.contains(Self.key(x + dx, y + dy)) {
                let distance = dx * dx + dy * dy
                if distance <= radius * radius, distance < (best?.distance ?? .max) {
                    best = (x + dx, y + dy, distance)
                }
            }
        }
        return best.map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) }
    }

    /// Where a line of sight ends: at `reach`, or at the first thing that isn't open floor.
    func sightEnd(from start: CGPoint, angle: Double, reach: CGFloat) -> CGPoint {
        let step = CGVector(dx: cos(angle) * 0.5, dy: sin(angle) * 0.5)
        var point = start
        var travelled: CGFloat = 0
        while travelled < reach {
            let next = CGPoint(x: point.x + step.dx, y: point.y + step.dy)
            guard walkable.contains(Self.key(Int(next.x.rounded(.down)), Int(next.y.rounded(.down)))) else { break }
            point = next
            travelled += 0.5
        }
        return point
    }

    /// Whether any open floor lies inside a rectangle.
    func hasFloor(in rect: CGRect) -> Bool {
        let box = rect.intersection(bounds)
        guard !box.isNull else { return false }
        for y in Int(box.minY.rounded(.down))...Int(box.maxY.rounded(.up)) {
            for x in Int(box.minX.rounded(.down))...Int(box.maxX.rounded(.up)) where walkable.contains(Self.key(x, y)) {
                return true
            }
        }
        return false
    }

    func roomID(at point: CGPoint) -> String? {
        cells[Self.key(Int(point.x.rounded(.down)), Int(point.y.rounded(.down)))]
    }

    /// The middle of an L-shaped room can fall outside it, so choose a cell
    /// with open space around it that sits close to the room's centre.
    static func labelPoint(_ cells: [(Int, Int)]) -> CGPoint {
        guard !cells.isEmpty else { return .zero }
        let set = Set(cells.map { key($0.0, $0.1) })
        let mx = Double(cells.reduce(0) { $0 + $1.0 }) / Double(cells.count)
        let my = Double(cells.reduce(0) { $0 + $1.1 }) / Double(cells.count)

        func clearance(_ x: Int, _ y: Int) -> Int {
            for r in 1..<12 {
                for (a, b) in [(r, 0), (-r, 0), (0, r), (0, -r), (r, r), (-r, r), (r, -r), (-r, -r)]
                where !set.contains(key(x + a, y + b)) {
                    return r
                }
            }
            return 12
        }

        var best = cells[0]
        var score = -Double.infinity
        for i in stride(from: 0, to: cells.count, by: 3) {
            let (x, y) = cells[i]
            let value = Double(clearance(x, y)) * 12 - hypot(Double(x) - mx, Double(y) - my)
            if value > score {
                score = value
                best = cells[i]
            }
        }
        return CGPoint(x: CGFloat(best.0) + 0.5, y: CGFloat(best.1) + 0.5)
    }
}

/// A wall, zone or annotation being shown or edited, in map pixels.
struct PlanShape: Identifiable {
    enum Kind: String, CaseIterable {
        case wall, noGo, noMop, threshold, curtain, ramp

        var title: String {
            switch self {
            case .wall: return "Wall"
            case .noGo: return "No-go zone"
            case .noMop: return "No-mop zone"
            case .threshold: return "Threshold"
            case .curtain: return "Curtain"
            case .ramp: return "Ramp"
            }
        }

        /// Lines take two points. Everything else is a four-corner area.
        var isLine: Bool { self == .wall || self == .threshold || self == .curtain }
    }

    let id = UUID()
    var kind: Kind
    var points: [CGPoint]

    var path: Path {
        var p = Path()
        p.addLines(points)
        if !kind.isLine { p.closeSubpath() }
        return p
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if !kind.isLine, path.contains(point) { return true }
        guard points.count >= 2 else { return false }
        for i in 0..<(points.count - (kind.isLine ? 1 : 0)) {
            let a = points[i], b = points[(i + 1) % points.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            if hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= tolerance { return true }
        }
        return false
    }
}

/// Converts between map pixels and view points, keeping the plan's proportions.
struct PlanTransform {
    let scale: CGFloat
    let offset: CGPoint

    init(bounds: CGRect, size: CGSize, insets: EdgeInsets = EdgeInsets(), zoom: CGFloat = 1, pan: CGSize = .zero) {
        let width = max(1, size.width - insets.leading - insets.trailing)
        let height = max(1, size.height - insets.top - insets.bottom)
        let fit = max(0.0001, min(width / max(bounds.width, 1), height / max(bounds.height, 1)))
        let s = fit * zoom
        scale = s
        offset = CGPoint(x: insets.leading + (width - bounds.width * s) / 2 - bounds.minX * s + pan.width,
                         y: insets.top + (height - bounds.height * s) / 2 - bounds.minY * s + pan.height)
    }

    var affine: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    func toMap(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
}

extension FloorPlan {
    /// Where a room clean is happening, for the headline: the room the robot is in when that's
    /// one of the job's rooms, otherwise the job's rooms themselves. Nil when the map can't say.
    var cleaningWhere: String? {
        let job = rooms.filter(\.active)
        let named = { (room: Room) -> String? in
            let name = room.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        // Some robots flag every room in the job, so the robot's position says which it's in.
        if let robot, let here = job.first(where: { $0.path.contains(robot) }), let name = named(here) {
            return name
        }
        let names = job.compactMap(named)
        guard !names.isEmpty, names.count == job.count else { return job.count > 1 ? "\(job.count) rooms" : nil }
        return names.count <= 2 ? names.formatted(.list(type: .and)) : "\(names.count) rooms"
    }
}
