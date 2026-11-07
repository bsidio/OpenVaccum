import Foundation

// Decoding is deliberately forgiving. Robots differ, so a field one model
// doesn't send must never stop the rest of the app from working.

struct RobotInfo: Decodable {
    let manufacturer: String?
    let modelName: String?
    let modelDetails: ModelDetails?

    struct ModelDetails: Decodable {
        let supportedAttachments: [String]?
        let supportedDockComponents: [String]?
    }

    private enum Keys: String, CodingKey { case manufacturer, modelName, modelDetails }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        manufacturer = try? c.decode(String.self, forKey: .manufacturer)
        modelName = try? c.decode(String.self, forKey: .modelName)
        modelDetails = try? c.decode(ModelDetails.self, forKey: .modelDetails)
    }
}

struct VersionInfo: Decodable, Equatable {
    let release: String?
    /// Differs between builds of one release, which matters on a robot running nightlies.
    let commit: String?
}

// MARK: - State

/// Attributes are a mixed array, so every field is optional and `__class` says which apply.
struct Attribute: Decodable {
    let kind: String
    let type: String?
    let value: String?
    let flag: String?
    let level: Double?
    let attached: Bool?
    let errorMessage: String?

    private enum Keys: String, CodingKey {
        case kind = "__class", type, value, flag, level, attached, error
    }
    private struct ErrorBody: Decodable { let message: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        type = try? c.decode(String.self, forKey: .type)
        value = try? c.decode(String.self, forKey: .value)
        flag = try? c.decode(String.self, forKey: .flag)
        level = try? c.decode(Double.self, forKey: .level)
        attached = try? c.decode(Bool.self, forKey: .attached)
        errorMessage = (try? c.decode(ErrorBody.self, forKey: .error))?.message
    }
}

struct RobotState: Equatable {
    var status: String?
    var flag: String?
    var errorMessage: String?
    var battery: Int?
    var charging = false
    var fan: String?
    var water: String?
    var mode: String?
    var dockStatus: String?
    var dockParts: [String: String] = [:]
    /// By attachment type. Some robots report several at once.
    var attachments: [String: Bool] = [:]

    init() {}

    init(_ attributes: [Attribute]) {
        for a in attributes {
            switch a.kind {
            case "StatusStateAttribute":
                status = a.value
                flag = a.flag
                errorMessage = a.errorMessage
            case "BatteryStateAttribute":
                battery = a.level.map { Int($0.rounded()) }
                charging = a.flag == "charging"
            case "PresetSelectionStateAttribute":
                switch a.type {
                case "fan_speed": fan = a.value
                case "water_grade": water = a.value
                case "operation_mode": mode = a.value
                default: break
                }
            case "DockStatusStateAttribute":
                dockStatus = a.value
            case "DockComponentStateAttribute":
                if let type = a.type, let value = a.value { dockParts[type] = value }
            case "AttachmentStateAttribute":
                if let type = a.type, let attached = a.attached { attachments[type] = attached }
            default:
                break
            }
        }
    }

    subscript(kind: PresetKind) -> String? {
        get {
            switch kind {
            case .mode: return mode
            case .fan: return fan
            case .water: return water
            }
        }
        set {
            switch kind {
            case .mode: mode = newValue
            case .fan: fan = newValue
            case .water: water = newValue
            }
        }
    }

    var isActive: Bool { ["cleaning", "returning", "moving", "manual_control"].contains(status ?? "") }
    var isPaused: Bool { status == "paused" }
    var mopAttached: Bool { attachments["mop"] == true }

    // When each command applies, by Valetudo's own rules. `isActive` means something else:
    // manual control counts as active, but there's no pausing it.
    var isResumable: Bool { flag == "resumable" }
    /// Stopped partway, whether paused where it is or waiting on the dock.
    var isUnfinished: Bool { isPaused || isResumable }
    var canPause: Bool { ["cleaning", "returning", "moving"].contains(status ?? "") }
    var canStop: Bool { isResumable || !(status == nil || status == "idle" || status == "docked") }
    var canDock: Bool { ["idle", "error", "paused"].contains(status ?? "") }
}

// MARK: - Map

/// One bad item must never cost the whole map, so layers and entities are read one at a time.
struct RawMap: Decodable, Equatable, Sendable {
    let pixelSize: Double
    let layers: [Layer]
    let entities: [Entity]
    /// Until the firmware sends a map, Valetudo serves a made-up one, with a dock and a trail.
    /// None of that is real, so none of it is kept.
    let isPlaceholder: Bool

    private enum Keys: String, CodingKey { case pixelSize, layers, entities, metaData }
    private struct Details: Decodable { let defaultMap: Bool? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pixelSize = try c.decode(Double.self, forKey: .pixelSize)
        let listed = try c.decode([Forgiving<Layer>].self, forKey: .layers)
        let layers = listed.compactMap(\.value)
        // With nothing readable at all, this would pass for a robot that has no map.
        if layers.isEmpty, !listed.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .layers, in: c, debugDescription: "No layer could be read.")
        }
        let entities = try c.decode([Forgiving<Entity>].self, forKey: .entities).compactMap(\.value)
        isPlaceholder = (try? c.decode(Details.self, forKey: .metaData))?.defaultMap == true
        self.layers = isPlaceholder ? [] : layers
        self.entities = isPlaceholder ? [] : entities
    }

    struct Layer: Decodable, Equatable, Sendable {
        let type: String
        /// Runs of `[x, y, length, ...]`.
        let compressedPixels: [Int]?
        /// Older Valetudo versions send `[x, y, ...]` instead.
        let pixels: [Int]?
        let metaData: Meta?

        private enum Keys: String, CodingKey { case type, compressedPixels, pixels, metaData }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(String.self, forKey: .type)
            compressedPixels = try? c.decode([Int].self, forKey: .compressedPixels)
            pixels = try? c.decode([Int].self, forKey: .pixels)
            metaData = try? c.decode(Meta.self, forKey: .metaData)
        }

        struct Meta: Decodable, Equatable, Sendable {
            let segmentId: String?
            let name: String?
            let material: String?
            let active: Bool?

            private enum Keys: String, CodingKey { case segmentId, name, material, active }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                name = try? c.decode(String.self, forKey: .name)
                material = try? c.decode(String.self, forKey: .material)
                active = try? c.decode(Bool.self, forKey: .active)
                segmentId = RawMap.identifier(in: c, forKey: .segmentId)
            }
        }

        var runs: [Int] {
            if let compressedPixels, !compressedPixels.isEmpty { return compressedPixels }
            guard let pixels else { return [] }
            var out: [Int] = []
            out.reserveCapacity(pixels.count / 2 * 3)
            var i = 0
            while i + 1 < pixels.count {
                out += [pixels[i], pixels[i + 1], 1]
                i += 2
            }
            return out
        }
    }

    struct Entity: Decodable, Equatable, Sendable {
        let type: String
        let points: [Double]
        let metaData: Meta?

        private enum Keys: String, CodingKey { case type, points, metaData }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(String.self, forKey: .type)
            points = try c.decode([Double].self, forKey: .points)
            metaData = try? c.decode(Meta.self, forKey: .metaData)
        }

        struct Meta: Decodable, Equatable, Sendable {
            let angle: Double?
            let label: String?
            let id: String?
            let image: String?

            private enum Keys: String, CodingKey { case angle, label, id, image }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                angle = try? c.decode(Double.self, forKey: .angle)
                label = try? c.decode(String.self, forKey: .label)
                image = try? c.decode(String.self, forKey: .image)
                id = RawMap.identifier(in: c, forKey: .id)
            }
        }
    }

    /// Ids are text on most robots, but Midea numbers its carpets and some robots their rooms.
    private static func identifier<Key: CodingKey>(in c: KeyedDecodingContainer<Key>, forKey key: Key) -> String? {
        (try? c.decode(String.self, forKey: key)) ?? (try? c.decode(Int.self, forKey: key)).map(String.init)
    }
}

/// An item in a list, or nothing if it can't be read, so the items around it survive.
private struct Forgiving<Item: Decodable>: Decodable {
    let value: Item?

    init(from decoder: Decoder) throws {
        value = try? Item(from: decoder)
    }
}

struct RoomRef: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let material: String?
    var title: String { name ?? "Room \(id)" }
}

/// Per-robot limits, read from each capability's `/properties`.
struct IterationLimits: Decodable {
    let iterationCount: Range?
    let zoneCount: Range?
    /// Whether the robot cleans rooms in the order it's given.
    let customOrderSupport: Bool?
    struct Range: Decodable { let min: Int?; let max: Int? }
}

struct ScheduleProperties: Decodable {
    let supportedActions: [String]?
    let supportedPreActions: [String]?
}

// MARK: - Care

struct Consumable: Decodable, Identifiable {
    let type: String
    let subType: String?
    let remaining: Remaining

    struct Remaining: Decodable {
        let value: Double
        let unit: String
    }

    var id: String { "\(type)/\(subType ?? "none")" }

    /// Some entries are upkeep reminders rather than parts to buy.
    var isCleaningTask: Bool { type == "cleaning" }

    var title: String {
        switch (type, subType) {
        case ("brush", "main"): return "Main Brush"
        case ("brush", "side_right"): return "Right Side Brush"
        case ("brush", "side_left"): return "Left Side Brush"
        case ("filter", "main"), ("filter", nil): return "Filter"
        case ("cleaning", "sensor"): return "Sensors"
        case ("cleaning", "wheel"): return "Wheels"
        default:
            // Only the name drops these. `id` and resets still need them.
            let variant = subType == "none" || subType == "all" ? nil : subType
            let words = [variant, type].compactMap { $0 }.joined(separator: " ")
            let text = words.replacingOccurrences(of: "_", with: " ")
            return text.capitalized
        }
    }

    var remainingText: String {
        if remaining.unit == "percent" { return "\(Int(remaining.value))% left" }
        if remaining.value <= 0 { return "Due now" }
        if remaining.value >= 120 { return "\(Int(remaining.value / 60)) hours left" }
        return Int(remaining.value) == 1 ? "1 minute left" : "\(Int(remaining.value)) minutes left"
    }
}

struct ConsumableProperties: Decodable {
    let availableConsumables: [Entry]?
    struct Entry: Decodable {
        let type: String
        let subType: String?
        let maxValue: Double?

        /// Matches `Consumable.id`.
        var id: String { "\(type)/\(subType ?? "none")" }
    }
}

struct DataPoint: Decodable {
    let type: String
    let value: Double
}

/// The job under way, or else the last one. Robots choose what they report, so either can be missing.
struct RunStatistics: Equatable {
    var seconds: Double?
    var squareCentimetres: Double?

    var isEmpty: Bool { seconds == nil && squareCentimetres == nil }

    /// Dreame leaves out any figure whose firmware read failed, so a missing one keeps its value.
    mutating func merge(_ points: [DataPoint]) {
        seconds = points.first { $0.type == "time" }?.value ?? seconds
        squareCentimetres = points.first { $0.type == "area" }?.value ?? squareCentimetres
    }
}

// MARK: - Alerts

struct RobotEvent: Decodable, Identifiable {
    let id: String
    let kind: String
    let processed: Bool
    let type: String?
    let subType: String?
    let message: String?
    let date: Date?
    let previousVersion: String?
    let newVersion: String?
    let reason: String?
    let description: String?

    private enum Keys: String, CodingKey {
        case id, kind = "__class", processed, type, subType, message, timestamp, previousVersion, newVersion, reason, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        processed = (try? c.decode(Bool.self, forKey: .processed)) ?? false
        type = try? c.decode(String.self, forKey: .type)
        subType = try? c.decode(String.self, forKey: .subType)
        message = try? c.decode(String.self, forKey: .message)
        date = (try? c.decode(String.self, forKey: .timestamp)).flatMap {
            try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)
        }
        previousVersion = try? c.decode(String.self, forKey: .previousVersion)
        newVersion = try? c.decode(String.self, forKey: .newVersion)
        reason = try? c.decode(String.self, forKey: .reason)
        description = try? c.decode(String.self, forKey: .description)
    }

    /// Valetudo accepts different replies per event class, and `reset` on a
    /// consumable alert also zeroes that part's counter.
    enum Style { case dismiss, consumable, pendingMap }

    var style: Style {
        switch kind {
        case "ConsumableDepletedValetudoEvent": return .consumable
        case "PendingMapChangeValetudoEvent": return .pendingMap
        default: return .dismiss
        }
    }

    var title: String {
        switch kind {
        case "ConsumableDepletedValetudoEvent":
            switch (type, subType) {
            case ("cleaning", "sensor"): return "Clean the sensors"
            case ("cleaning", "wheel"): return "Clean the wheels"
            case ("cleaning", _): return "Cleaning is due"
            case ("brush", "main"): return "Replace the main brush"
            case ("brush", "side_right"), ("brush", "side_left"): return "Replace the side brush"
            case ("brush", "dock"): return "Replace the dock's brush"
            case ("brush", _): return "Replace the brush"
            case ("filter", "dock"): return "Replace the dock's filter"
            case ("filter", _): return "Replace the filter"
            case ("mop", _): return "Replace the mop"
            case ("detergent", _): return "Refill the detergent"
            case ("bin", _): return "Replace the dock's dust bag"
            default: return "A part needs attention"
            }
        case "DustBinFullValetudoEvent": return "Empty the dust bin"
        case "MopAttachmentReminderValetudoEvent": return "The mop is still attached"
        case "PendingMapChangeValetudoEvent": return "A new floor plan is ready"
        case "ErrorStateValetudoEvent": return message ?? "The robot reported an error"
        case "ValetudoUpdatedValetudoEvent":
            guard let previousVersion, let newVersion else { return "Valetudo was updated" }
            return "Valetudo updated from \(previousVersion) to \(newVersion)"
        case "ValetudoRuntimeErrorValetudoEvent": return "Valetudo restarted after a problem"
        default: return message ?? "The robot sent a notice"
        }
    }
}

// MARK: - Schedule

/// Stored in UTC on the robot. `RobotTime` converts for display.
struct Routine: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool
    var label: String?
    var dow: [Int]
    var hour: Int
    var minute: Int
    var action: Action
    var pre_actions: [PreAction]?

    struct Action: Codable, Equatable {
        var type: String
        var params: Params
    }
    struct Params: Codable, Equatable {
        var segment_ids: [String]?
        var iterations: Int?
        var custom_order: Bool?
    }
    struct PreAction: Codable, Equatable {
        var type: String
        var params: Value
        struct Value: Codable, Equatable { var value: String }
    }
}

struct QuietHours: Codable, Equatable {
    var enabled: Bool
    var start: Clock
    var end: Clock
    struct Clock: Codable, Equatable {
        var hour: Int
        var minute: Int
    }
}

/// The robot keeps schedule times in UTC, so days can shift when converting.
enum RobotTime {
    static var offsetMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }

    static func shift(days: [Int], hour: Int, minute: Int, byMinutes offset: Int) -> (days: [Int], hour: Int, minute: Int) {
        let total = hour * 60 + minute + offset
        let dayShift = Int((Double(total) / 1440).rounded(.down))
        let wrapped = total - dayShift * 1440
        let shifted = days.map { (($0 + dayShift) % 7 + 7) % 7 }.sorted()
        return (shifted, wrapped / 60, wrapped % 60)
    }

    static func toLocal(days: [Int], hour: Int, minute: Int) -> (days: [Int], hour: Int, minute: Int) {
        shift(days: days, hour: hour, minute: minute, byMinutes: offsetMinutes)
    }

    static func toRobot(days: [Int], hour: Int, minute: Int) -> (days: [Int], hour: Int, minute: Int) {
        shift(days: days, hour: hour, minute: minute, byMinutes: -offsetMinutes)
    }
}
