import CoreGraphics
import Foundation
import GameController
import UIKit

/// The ways of steering. Valetudo's own page offers the same three.
enum DriveInput: Hashable {
    case joystick, dpad, keyboard

    var title: String {
        switch self {
        case .joystick: return "Joystick"
        case .dpad: return "D-Pad"
        case .keyboard: return "Keyboard"
        }
    }

    var hint: String {
        switch self {
        case .joystick: return "Drag to drive. Let go to stop."
        case .dpad: return "Hold a direction to drive. Let go to stop."
        case .keyboard: return "Hold W, A, S or D, or an arrow key, to drive."
        }
    }
}

/// What Valetudo's simple manual control can do, in the user's terms.
enum DriveCommand: String, CaseIterable {
    case forward
    case turnLeft = "rotate_counterclockwise"
    case turnRight = "rotate_clockwise"
    case backward

    var title: String {
        switch self {
        case .forward: return "Forward"
        case .turnLeft: return "Turn Left"
        case .turnRight: return "Turn Right"
        case .backward: return "Backward"
        }
    }

    var symbol: String {
        switch self {
        case .forward: return "arrow.up"
        case .turnLeft: return "arrow.counterclockwise"
        case .turnRight: return "arrow.clockwise"
        case .backward: return "arrow.down"
        }
    }

    /// Where this move puts the stick, which is how Valetudo's D-pad works too. Up is forward.
    var stick: CGPoint {
        switch self {
        case .forward: return CGPoint(x: 0, y: -1)
        case .backward: return CGPoint(x: 0, y: 1)
        case .turnLeft: return CGPoint(x: -1, y: 0)
        case .turnRight: return CGPoint(x: 1, y: 0)
        }
    }

    /// The move a stick position asks for, in the same order of preference as Valetudo's page.
    /// Nil near the centre, because these commands have no slow speeds and no stop.
    static func matching(_ stick: CGPoint, among commands: [DriveCommand]) -> DriveCommand? {
        let velocity = -stick.y
        let angle = stick.x * 120
        if velocity > 0.3, commands.contains(.forward) { return .forward }
        if velocity < -0.3, commands.contains(.backward) { return .backward }
        if angle > 30, commands.contains(.turnRight) { return .turnRight }
        if angle < -30, commands.contains(.turnLeft) { return .turnLeft }
        return nil
    }
}

extension RobotState {
    /// What driving by hand would cut short, in the owner's words. Nil if there's nothing to lose.
    /// `resumable` matters as much as the status, because a job waiting at the dock reports "docked".
    var interruption: String? {
        if flag == "resumable" || status == "cleaning" || status == "paused" {
            return "Driving by hand ends this job, and you may need to start it again."
        }
        switch status {
        case "returning":
            return "Driving by hand stops it on its way to the dock."
        case "moving":
            return flag == "mapping" ? "Driving by hand ends the mapping pass." : "Driving by hand stops it on its way."
        default:
            break
        }
        switch dockStatus {
        case "cleaning", "pause": return "Driving by hand stops the dock washing the mop."
        case "drying": return "Driving by hand stops the dock drying the mop."
        case "emptying": return "Driving by hand stops the dock emptying the bin."
        default: return nil
        }
    }
}

/// One visit to the Drive screen, and everything it sends to the robot.
///
/// This isn't in the view because a view's long-running task holds a copy of the view, whose
/// environment values stop updating. Every way a hand can leave the control ends in `stick`
/// being zero, and `control` then sends the stop:
/// - Finger lifted, or the touch cancelled by the system: the control's `@GestureState` resets.
/// - The control leaves the screen mid-press: `onDisappear`, and `input`'s `didSet`.
/// - The app stops being active: `sceneChanged`, and `steering` holds at zero until it's back.
/// - Done: `letGo` straight away, then `handBack` once the screen has gone.
/// - The robot leaves manual control: `controlEnded`, which sends nothing because nothing's listening.
@MainActor @Observable
final class DriveSession {
    enum Phase: Equatable {
        case checking
        /// Waiting for the owner to decide. The text is what they'd lose, or nil if that has since gone away.
        case confirming(String?)
        case taking
        case driving
        /// The robot left manual control by itself.
        case ended
        case failed(String)
    }

    /// Only one robot is connected at a time, so only one of these can matter.
    private static var handingBack: Task<Void, Never>?

    let highResolution: Bool
    private(set) var phase = Phase.checking {
        didSet { wake() }
    }
    private(set) var commands: [DriveCommand]
    private(set) var linkLost = false
    private(set) var keyboardAttached = false

    var input: DriveInput {
        didSet { letGo() }
    }

    /// The one virtual stick every input writes to, as on Valetudo's page.
    var stick = CGPoint.zero {
        didSet {
            if (stick == .zero) != (oldValue == .zero) { wake() }
        }
    }

    private let store: RobotStore
    private let client: Client
    private let route: String
    private let stopTime = BackgroundTime()
    private var foreground = true
    private var mayHoldControl = false
    private var controlAcknowledged = false
    private var stopOwed = false
    private var sawManualStatus = false
    private var misses = 0
    private var nudging: Task<Void, Never>?
    private var pause: Task<Void, Never>?
    private var woken = false

    init(store: RobotStore) {
        let highResolution = store.has(Cap.drive)
        self.store = store
        self.highResolution = highResolution
        client = store.client
        route = "\(Cap.root)/\(highResolution ? Cap.drive : Cap.driveSimple)"
        input = highResolution ? .joystick : .dpad
        commands = highResolution ? DriveCommand.allCases : []
    }

    /// Zero whenever nobody can be holding the control, whatever `stick` says.
    private var steering: CGPoint { foreground ? stick : .zero }

    /// What a robot without the joystick is being asked to do right now.
    var move: DriveCommand? { DriveCommand.matching(steering, among: commands) }

    // MARK: From the screen

    /// Runs for as long as the screen is open. Everything sent to the robot starts here, so
    /// leaving cancels all of it, and only the hand-back carries on afterwards.
    func run() async {
        phase = .checking
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.control() }
            group.addTask { await self.watch() }
        }
        handBack()
    }

    func letGo() {
        nudging?.cancel()
        stick = .zero
    }

    /// VoiceOver can't press and hold, so one activation moves the robot for a moment.
    func nudge(_ command: DriveCommand) {
        guard phase == .driving else { return }
        nudging?.cancel()
        stick = command.stick
        nudging = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { stick = .zero }
        }
    }

    /// iOS can suspend the app at any moment after this, so the stop goes out now, with a
    /// little background time to finish in. Waiting for the next tick could mean it never goes.
    func sceneChanged(active: Bool) {
        foreground = active
        letGo()
        if !active, highResolution, phase == .driving { stopTime.begin("Stop the Robot") }
        wake()
    }

    func confirmTakeover() {
        phase = .taking
    }

    func retry() {
        phase = .checking
    }

    // MARK: Control

    /// Four times a second while a control is held, as Valetudo's own page does. Waiting for
    /// each answer keeps requests in order, so a slow robot can't build up a queue.
    private func control() async {
        while !Task.isCancelled {
            let next = ContinuousClock.now.advanced(by: .milliseconds(250))
            switch phase {
            case .checking: await check()
            case .taking: await take()
            case .driving: await sendMove()
            case .confirming, .ended, .failed: break
            }
            await rest(until: next)
        }
    }

    /// Reads the robot fresh, because the store's copy can be a couple of seconds old.
    private func check() async {
        // A quick reopen mustn't have its new session ended by the last one's hand-back.
        await Self.handingBack?.value
        do {
            let robot = try await readRobot()
            let enabled = try await Self.enabled(client, route)
            if !highResolution { try await loadCommands() }
            if robot.status == "manual_control", enabled {
                // Still held from an earlier visit, so there's nothing to take.
                startDriving()
            } else if let warning = robot.interruption {
                phase = .confirming(warning)
            } else {
                phase = .taking
            }
        } catch is CancellationError {
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func take() async {
        // Before the request, because one that times out can still have reached the robot.
        mayHoldControl = true
        do {
            try await client.put(route, ["action": "enable"])
            startDriving()
        } catch is CancellationError {
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func startDriving() {
        mayHoldControl = true
        controlAcknowledged = true
        sawManualStatus = false
        misses = 0
        linkLost = false
        phase = .driving
    }

    private func sendMove() async {
        do {
            if highResolution {
                try await sendVector()
            } else if let move {
                try await client.put(route, ["action": "move", "movementCommand": move.rawValue])
                linkLost = false
            }
        } catch is CancellationError {
        } catch {
            linkLost = true
        }
    }

    /// `stopOwed` is set ahead of the request, because a move can arrive even if its answer doesn't.
    /// It only clears once the robot has acknowledged a stop, so a dropped stop is sent again.
    private func sendVector() async throws {
        let vector = steering
        guard vector != .zero || stopOwed else {
            stopTime.end()
            return
        }
        if vector != .zero { stopOwed = true }
        try await client.put(route, Self.moveBody(vector))
        linkLost = false
        if vector == .zero {
            stopOwed = false
            stopTime.end()
        }
    }

    private static func moveBody(_ stick: CGPoint) -> [String: Any] {
        ["action": "move", "vector": ["velocity": Double(-stick.y), "angle": Double(stick.x) * 120]]
    }

    private func loadCommands() async throws {
        let properties = try await client.getJSON("\(route)/properties")
        let supported = properties["supportedMovementCommands"] as? [String] ?? []
        commands = DriveCommand.allCases.filter { supported.contains($0.rawValue) }
        if commands.isEmpty { throw APIError(message: "The robot didn't say which moves it supports.") }
    }

    // MARK: Watching the robot

    /// Separate from `control`, so a slow read can never hold up a stop.
    private func watch() async {
        while !Task.isCancelled {
            keyboardAttached = GCKeyboard.coalesced != nil
            if !keyboardAttached, input == .keyboard { input = highResolution ? .joystick : .dpad }
            switch phase {
            case .confirming: await recheckJob()
            case .driving: await checkStillInControl()
            default: break
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Nothing is taken over here, even if the job finishes. That still waits for the owner.
    private func recheckJob() async {
        guard let robot = try? await readRobot(), case .confirming = phase else { return }
        let next = Phase.confirming(robot.interruption)
        if phase != next { phase = next }
    }

    /// A schedule, the robot's own buttons or a low battery can all end manual control, and the
    /// controls mustn't look live after that. `enabled` alone isn't enough: Roborock's only ever
    /// clears when asked to. One reading isn't either: some robots report the change a moment late.
    private func checkStillInControl() async {
        let status = store.state.status
        do {
            let enabled = try await Self.enabled(client, route)
            guard phase == .driving else { return }
            if stick == .zero { linkLost = false }
            let manual = status == "manual_control"
            sawManualStatus = sawManualStatus || manual
            misses = !enabled || (sawManualStatus && !manual) ? misses + 1 : 0
            if misses >= 2 { controlEnded() }
        } catch is CancellationError {
        } catch {
            linkLost = true
        }
    }

    private func controlEnded() {
        // Nothing to stop or hand back. A job may be running now, and a `disable` could end it.
        mayHoldControl = false
        stopOwed = false
        letGo()
        stopTime.end()
        phase = .ended
    }

    private func readRobot() async throws -> RobotState {
        RobotState(try await client.get("/robot/state/attributes", as: [Attribute].self))
    }

    /// An answer that can't be read counts as on, because that's the side that gets it turned off.
    private static func enabled(_ client: Client, _ route: String) async throws -> Bool {
        try await client.getJSON(route)["enabled"] as? Bool ?? true
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.message ?? "The robot sent an answer this app can't read."
    }

    // MARK: Handing back

    /// Runs on its own task, because the screen's has been cancelled by now, and it has to
    /// finish even if Done is the last thing anyone does before locking the phone.
    private func handBack() {
        let time = BackgroundTime()
        if mayHoldControl { time.begin("Hand Back Control") }
        stopTime.end()
        guard mayHoldControl else { return }
        mayHoldControl = false
        let store = store, client = client, route = route, stop = stopOwed, acknowledged = controlAcknowledged
        Self.handingBack = Task {
            let released = await Self.release(client, route, stop: stop)
            if !released, acknowledged {
                store.notify("Couldn't end manual control. Use Stop on Home.",
                             symbol: Tone.warning.symbol, seconds: 4.5, isProblem: true)
            }
            time.end()
        }
    }

    /// A few tries, because it's the last chance the app gets. That's about 30 seconds at
    /// worst with the client's timeouts, which is roughly what iOS allows in the background.
    private static func release(_ client: Client, _ route: String, stop: Bool) async -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            do {
                // Only if it's still on. A job may have started since, and on Dreame a stop is the
                // same write that takes control, and `disable` ends the job.
                if try await enabled(client, route) {
                    if stop { try await client.put(route, moveBody(.zero)) }
                    try await client.put(route, ["action": "disable"])
                }
                return true
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: Timing

    /// Sleeps until the next tick, unless something needs sending sooner.
    private func rest(until deadline: ContinuousClock.Instant) async {
        if !woken {
            let pause = Task<Void, Never> { try? await Task.sleep(until: deadline, clock: .continuous) }
            self.pause = pause
            await pause.value
        }
        woken = false
    }

    /// `woken` covers a press that lands while a request is in flight, when nothing is sleeping yet.
    private func wake() {
        woken = true
        pause?.cancel()
    }
}

/// A little time to finish in, if iOS is about to suspend the app.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(_ name: String) {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
