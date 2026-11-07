import Foundation

struct APIError: LocalizedError {
    enum Kind { case other, unreachable, cutOff, tookTooLong, needsLogin }

    let message: String
    var kind = Kind.other

    var errorDescription: String? { message }

    /// Nothing came back, so another address might still work.
    var noAnswer: Bool { kind == .unreachable || mayHaveArrived }

    /// The request went out with no answer, so the robot may still have acted on it.
    var mayHaveArrived: Bool { kind == .cutOff || kind == .tookTooLong }
}

/// A robot's `.local` name and plain address, and which one requests are going to.
/// Multicast is patchier than ordinary traffic, and the owner can turn announcements off, so
/// the name can go quiet while the robot's fine. The address alone would break on a new lease.
private final class Route: @unchecked Sendable {
    private let lock = NSLock()
    private let addresses: [String]
    private var index = 0

    init(_ first: String, _ second: String) {
        addresses = [first, second]
    }

    var current: String { lock.withLock { addresses[index] } }

    /// The polls that follow try the other address, so the app settles on whichever answers.
    func moveOn(from request: URLRequest) {
        lock.withLock {
            // Requests in flight fail together, and only the first of them should move.
            if request.url?.absoluteString.hasPrefix("\(addresses[index])/") == true { index = 1 - index }
        }
    }
}

/// Talks to Valetudo's REST API on the robot. Nothing here leaves your network.
struct Client {
    /// Polling needs to notice a lost robot quickly, and so does driving.
    private static let quick = session(timeout: 8)
    /// Valetudo answers at once if it's there, so asking whether it is needs no long wait.
    private static let brief = session(timeout: 3)
    /// A write gets no answer until the robot has finished, which takes over ten seconds
    /// for some jobs, such as renaming a room on a Midea E20. Valetudo's web page has no limit.
    private static let patient = session(timeout: 60)

    let baseURL: String
    private let authorization: String?
    private let route: Route?

    private static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }

    init(baseURL: String, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        route = Connection.fallback(for: baseURL).map { Route(baseURL, $0) }
        if let username, !username.isEmpty {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            authorization = "Basic \(token)"
        } else {
            authorization = nil
        }
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: "\(route?.current ?? baseURL)/api/v2\(path)") else {
            throw APIError(message: "That address doesn't look right.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func perform(_ request: URLRequest, on session: URLSession = Client.quick) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut && request.httpMethod != "GET" {
            throw APIError(message: "The robot is taking longer than expected. The change may still go through.",
                           kind: .tookTooLong)
        } catch {
            route?.moveOn(from: request)
            throw APIError(message: "Can't reach the robot. Check that your phone is on the same network.",
                           kind: Self.neverSent(error) ? .unreachable : .cutOff)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 {
            throw APIError(message: "This robot needs a username and password.", kind: .needsLogin)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: Self.refusal(data, status: http.statusCode))
        }
        return data
    }

    /// These come before any connection exists, so the robot can't have received anything.
    private static func neverSent(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(code)
    }

    /// Failures arrive as a JSON string, a JSON object with a `message`, or plain text.
    private static func refusal(_ body: Data, status: Int) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        let raw = parsed == nil
            ? String(decoding: body, as: UTF8.self)
            : parsed as? String ?? (parsed as? [String: Any])?["message"] as? String ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `sendStatus` puts the bare status name in the body, which says nothing useful.
        let isStatusName = text.caseInsensitiveCompare(HTTPURLResponse.localizedString(forStatusCode: status)) == .orderedSame
        let readable = !text.isEmpty && !text.hasPrefix("<") && text.count < 200 && !isStatusName
        return readable ? text : "The robot refused that request (error \(status))."
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await perform(try request(path))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For settings whose shape varies between robots.
    func getJSON(_ path: String) async throws -> [String: Any] {
        let data = try await perform(try request(path))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Nothing polls these, and some are slow: a robot can spend 9 seconds on its quirks.
    func getList(_ path: String) async throws -> [[String: Any]] {
        let data = try await perform(try request(path), on: Client.patient)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Whether Valetudo itself is there. `/robot` doesn't wait on the firmware, so this tells a
    /// stalled firmware from a lost robot, which a state read can't. Its answer also has to read
    /// as a robot's, because a Wi-Fi sign-in page answers every address with a 200.
    func isAnswering() async -> Bool {
        // The read that failed has moved the route on, so the first try goes to the other
        // address. If that one's dead, the address the robot is really on still has to be asked.
        for _ in 0..<(route == nil ? 1 : 2) {
            guard let probe = try? request("/robot") else { return false }
            do {
                let data = try await perform(probe, on: Client.brief)
                _ = try JSONDecoder().decode(RobotInfo.self, from: data)
                return true
            } catch is DecodingError {
                route?.moveOn(from: probe)
            } catch let error as APIError where error.noAnswer {
                continue
            } catch {
                // A refusal still came from Valetudo, and being cancelled says nothing about it.
                return true
            }
        }
        return false
    }

    func getData(_ path: String) async throws -> Data {
        try await perform(try request(path))
    }

    func getText(_ path: String) async throws -> String {
        String(decoding: try await getData(path), as: UTF8.self)
    }

    func streamRequest(_ path: String) throws -> URLRequest {
        var r = try request(path)
        r.timeoutInterval = 30
        return r
    }

    func put(_ path: String, array: [[String: Any]]) async throws {
        try await send("PUT", path, try JSONSerialization.data(withJSONObject: array))
    }

    func put(_ path: String, _ json: [String: Any]) async throws {
        try await send("PUT", path, try JSONSerialization.data(withJSONObject: json))
    }

    func send<B: Encodable>(_ method: String, _ path: String, encoding body: B) async throws {
        try await send(method, path, try JSONEncoder().encode(body))
    }

    func delete(_ path: String) async throws {
        _ = try await perform(try request(path, method: "DELETE"), on: Client.patient)
    }

    private func send(_ method: String, _ path: String, _ body: Data) async throws {
        var r = try request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        // Driving sends one command at a time, so a stuck one would hold up the stop behind it.
        let isDriving = [Cap.drive, Cap.driveSimple].contains { path.hasSuffix($0) }
        _ = try await perform(r, on: isDriving ? Client.quick : Client.patient)
    }
}

/// Capability routes. A control only appears if the robot lists its capability.
enum Cap {
    static let root = "/robot/capabilities"
    static let basic = "BasicControlCapability"
    static let locate = "LocateCapability"
    static let rooms = "MapSegmentationCapability"
    static let zones = "ZoneCleaningCapability"
    static let goTo = "GoToLocationCapability"
    static let autoEmpty = "AutoEmptyDockManualTriggerCapability"
    static let mopWash = "MopDockCleanManualTriggerCapability"
    static let mopDry = "MopDockDryManualTriggerCapability"
    static let consumables = "ConsumableMonitoringCapability"
    static let quietHours = "DoNotDisturbCapability"
    static let volume = "SpeakerVolumeControlCapability"
    static let currentStats = "CurrentStatisticsCapability"
    static let totalStats = "TotalStatisticsCapability"
    static let drive = "HighResolutionManualControlCapability"
    static let driveSimple = "ManualControlCapability"
    static let camera = "DuststreamingCapability"
    static let obstaclePhotos = "ObstacleImagesCapability"
    static let mappingPass = "MappingPassCapability"
    static let mapReset = "MapResetCapability"
    static let mapSnapshot = "MapSnapshotCapability"
    static let pendingMap = "PendingMapChangeHandlingCapability"
    static let segmentEdit = "MapSegmentEditCapability"
    static let segmentRename = "MapSegmentRenameCapability"
    static let segmentMaterial = "MapSegmentMaterialControlCapability"
    static let restrictions = "CombinedVirtualRestrictionsCapability"
    static let annotations = "MapAnnotationsCapability"
    static let speakerTest = "SpeakerTestCapability"
    static let voicePacks = "VoicePackManagementCapability"
    static let quirks = "QuirksCapability"
    static let wifi = "WifiConfigurationCapability"
    static let wifiScan = "WifiScanCapability"
}

enum PresetKind: CaseIterable, Identifiable {
    case mode, fan, water
    var id: Self { self }

    var capability: String {
        switch self {
        case .mode: return "OperationModeControlCapability"
        case .fan: return "FanSpeedControlCapability"
        case .water: return "WaterUsageControlCapability"
        }
    }

    var title: String {
        switch self {
        case .mode: return "Mode"
        case .fan: return "Suction"
        case .water: return "Water"
        }
    }

    /// The name a routine uses to apply this setting before it starts.
    var preAction: String {
        switch self {
        case .mode: return "operation_mode_control"
        case .fan: return "fan_speed_control"
        case .water: return "water_usage_control"
        }
    }

    /// Weakest to strongest, and plain vacuuming through to plain mopping, whatever order the
    /// robot lists them in. "custom" is something a robot can report, not something to pick.
    /// Anything newer goes last, in the order it arrived.
    static func ordered(_ presets: [String]) -> [String] {
        let order = ["off", "min", "low", "medium", "high", "max", "turbo",
                     "vacuum", "vacuum_and_mop", "vacuum_then_mop", "mop"]
        func rank(_ preset: String) -> Int { order.firstIndex(of: preset) ?? order.count }
        return presets.filter { $0 != "custom" }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static func label(_ raw: String) -> String {
        switch raw {
        case "vacuum_and_mop": return "Vacuum + Mop"
        case "vacuum_then_mop": return "Vacuum Then Mop"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Settings that are a plain on/off switch on the robot.
enum RobotSwitch: String, CaseIterable, Identifiable {
    case carpet = "CarpetModeControlCapability"
    case obstacles = "ObstacleAvoidanceControlCapability"
    case pets = "PetObstacleAvoidanceControlCapability"
    case obstaclePhotos = "ObstacleImagesCapability"
    case gentle = "CollisionAvoidantNavigationControlCapability"
    case floorDirection = "FloorMaterialDirectionAwareNavigationControlCapability"
    case mopExtension = "MopExtensionControlCapability"
    case mopFurniture = "MopExtensionFurnitureLegHandlingControlCapability"
    case mopTwist = "MopTwistControlCapability"
    case mopAutoDry = "MopDockMopAutoDryingControlCapability"
    case cameraLight = "CameraLightControlCapability"
    case persistentMap = "PersistentMapControlCapability"
    case childLock = "KeyLockCapability"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carpet: return "Boost Suction on Carpet"
        case .obstacles: return "Avoid Obstacles"
        case .pets: return "Avoid Pet Waste"
        case .obstaclePhotos: return "Save Obstacle Photos"
        case .gentle: return "Gentle Navigation"
        case .floorDirection: return "Follow Floor Direction"
        case .mopExtension: return "Extend Mop at Edges"
        case .mopFurniture: return "Extend Mop Around Furniture Legs"
        case .mopTwist: return "Twist Mop Into Corners"
        case .mopAutoDry: return "Dry Mop Automatically"
        // Not "camera": the word only appears once the owner has turned streaming on.
        case .cameraLight: return "Obstacle Light"
        case .persistentMap: return "Keep the Floor Plan Between Runs"
        case .childLock: return "Child Lock"
        }
    }
}

/// Settings with a fixed list of choices the robot reports in `/properties`.
enum ChoiceSetting: String, CaseIterable, Identifiable {
    case cleanRoute = "CleanRouteControlCapability"
    case carpetSensor = "CarpetSensorModeControlCapability"
    case autoEmptyInterval = "AutoEmptyDockAutoEmptyIntervalControlCapability"
    case autoEmptyDuration = "AutoEmptyDockAutoEmptyDurationControlCapability"
    case mopWash = "MopDockMopWashTemperatureControlCapability"
    case mopDry = "MopDockMopDryingTimeControlCapability"

    var id: String { rawValue }

    var valueKey: String {
        switch self {
        case .cleanRoute: return "route"
        case .carpetSensor: return "mode"
        case .autoEmptyInterval: return "interval"
        case .autoEmptyDuration, .mopDry: return "duration"
        case .mopWash: return "temperature"
        }
    }

    var optionsKey: String {
        switch self {
        case .cleanRoute: return "supportedRoutes"
        case .carpetSensor: return "supportedModes"
        case .autoEmptyInterval: return "supportedIntervals"
        case .autoEmptyDuration, .mopDry: return "supportedDurations"
        case .mopWash: return "supportedTemperatures"
        }
    }

    var title: String {
        switch self {
        case .cleanRoute: return "Cleaning Route"
        case .carpetSensor: return "When Mopping Near Carpet"
        case .autoEmptyInterval: return "Empty the Bin"
        case .autoEmptyDuration: return "Emptying Time"
        case .mopWash: return "Mop Wash Temperature"
        case .mopDry: return "Mop Drying Time"
        }
    }
}
