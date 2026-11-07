import GameController
import SwiftUI

// MARK: - Drive

/// Drive the robot by hand. Stops and hands control back when you leave.
struct DriveView: View {
    @Environment(RobotStore.self) private var store

    var body: some View { DriveScreen(store: store) }
}

private struct DriveScreen: View {
    let store: RobotStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session: DriveSession
    @State private var camera: CameraStream?

    init(store: RobotStore) {
        self.store = store
        _session = State(initialValue: DriveSession(store: store))
    }

    private var shouldStream: Bool { store.cameraReady && scenePhase == .active }
    private var canSteer: Bool { session.phase == .driving && scenePhase == .active }

    private var inputs: [DriveInput] {
        session.keyboardAttached ? [.joystick, .dpad, .keyboard] : [.joystick, .dpad]
    }

    var body: some View {
        NavigationStack {
            screen
                .modifier(ToastHost(toast: store.toast))
                .modifier(DriveAlerts(session: session))
                .task { await session.run() }
                .onChange(of: scenePhase) { _, phase in session.sceneChanged(active: phase == .active) }
                .onChange(of: shouldStream, initial: true) { _, on in
                    if on {
                        let stream = camera ?? CameraStream(client: store.client)
                        camera = stream
                        stream.start()
                    } else {
                        camera?.stop()
                    }
                }
                .onDisappear { camera?.stop() }
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                deck(in: geo.size)
            }
        }
        .background(Theme.mist.ignoresSafeArea())
        .navigationTitle("Drive Manually")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    // The screen takes a moment to go, and the robot shouldn't wait for that.
                    session.letGo()
                    dismiss()
                }
            }
        }
    }

    // MARK: Layout

    @ViewBuilder private var stage: some View {
        if store.cameraReady {
            Group {
                if let camera {
                    CameraFeed(stream: camera)
                } else {
                    Color.black.aspectRatio(4 / 3, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
            .padding(.horizontal, Metric.gutter)
            .padding(.vertical, 8)
        } else {
            PlanStage(active: store.connected && store.state.isActive)
        }
    }

    private func deck(in size: CGSize) -> some View {
        Group {
            switch session.phase {
            case .checking, .taking, .driving:
                controls(side: min(232, size.height * 0.34))
            case .confirming(let warning):
                takeoverPrompt(warning).frame(maxHeight: size.height * 0.62)
            case .ended:
                endedNotice.frame(maxHeight: size.height * 0.62)
            case .failed(let message):
                failureNotice(message).frame(maxHeight: size.height * 0.62)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: session.phase)
    }

    private func controls(side: CGFloat) -> some View {
        VStack(spacing: 14) {
            instruction
            SlidingPicker(options: inputs, selection: session.input, title: \.title) { session.input = $0 }
                .frame(maxWidth: 300)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            Group {
                switch session.input {
                case .joystick:
                    Joystick(value: $session.stick)
                case .dpad:
                    DirectionPad(commands: session.commands, value: $session.stick, nudge: session.nudge)
                case .keyboard:
                    KeyboardPad(value: $session.stick, active: canSteer)
                }
            }
            .frame(width: side, height: side)
            .disabled(!canSteer)
            .opacity(session.phase == .driving ? 1 : 0.5)
        }
    }

    /// One line that always says what's happening right now.
    private var instruction: some View {
        Group {
            switch session.phase {
            case .checking:
                working("Checking on the robot")
            case .taking:
                working("Taking control")
            default:
                if session.linkLost {
                    Label(store.needsLogin ? "The robot's login has changed. Sign in again on Home." : "Can't reach the robot. Still trying.",
                          systemImage: store.needsLogin ? store.readSymbol : "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tone.critical.color)
                } else if session.stick != .zero {
                    readout
                } else {
                    Text(session.input.hint)
                        .foregroundStyle(Theme.slate)
                }
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
        }
        .foregroundStyle(Theme.slate)
    }

    /// Robots without the joystick have one speed, so a percentage would mean nothing there.
    @ViewBuilder private var readout: some View {
        if session.highResolution {
            HStack(spacing: 6) {
                Text(session.stick.driveState)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                Text("\(session.stick.drivePercent)%")
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: session.stick.drivePercent)
            }
        } else if let move = session.move {
            Text(move.title)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
        } else {
            Text(hypot(session.stick.x, session.stick.y) > 0.5 ? "This robot can't move that way." : "Drag further to move.")
                .foregroundStyle(Theme.slate)
        }
    }

    // MARK: Before and after driving

    private func takeoverPrompt(_ warning: String?) -> some View {
        DriveNotice(symbol: warning == nil ? "gamecontroller" : Tone.warning.symbol,
                    tone: warning == nil ? .neutral : .warning,
                    title: store.sentence,
                    detail: warning ?? "Nothing will be interrupted now.") {
            VStack(spacing: 10) {
                Button { session.confirmTakeover() } label: {
                    Text(warning == nil ? "Take Control" : "Stop and Drive")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.onCobalt)
                        .padding(.horizontal, 24)
                        .frame(minHeight: Metric.hitTarget + 2)
                        .background((warning == nil ? Theme.cobalt : Tone.critical.color).gradient, in: Capsule())
                }
                .buttonStyle(.pressable)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var endedNotice: some View {
        DriveNotice(symbol: "hand.raised.fill", tone: .neutral, title: "Manual Control Ended",
                    detail: "\(store.sentence). The controls are off until you take control again.") {
            Button("Take Control Again") { session.retry() }
                .buttonStyle(.bordered)
        }
    }

    private func failureNotice(_ message: String) -> some View {
        DriveNotice(symbol: Tone.critical.symbol, tone: .critical, title: "Can't Take Control", detail: message) {
            Button("Try Again") { session.retry() }
                .buttonStyle(.bordered)
        }
    }
}

/// The two things that can change while the owner is looking at the robot, not the phone.
private struct DriveAlerts: ViewModifier {
    let session: DriveSession
    @Environment(RobotStore.self) private var store

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.warning, trigger: session.linkLost) { _, lost in lost }
            .sensoryFeedback(.warning, trigger: session.phase) { _, phase in phase == .ended }
            .onChange(of: session.linkLost) { _, lost in
                if lost {
                    AccessibilityNotification.Announcement(store.needsLogin ? "The robot's login has changed" : "Can't reach the robot").post()
                }
            }
            .onChange(of: session.phase) { _, phase in
                if phase == .ended { AccessibilityNotification.Announcement("Manual control ended").post() }
            }
    }
}

/// Takes the place of the controls while there's something to read or decide first.
private struct DriveNotice<Actions: View>: View {
    let symbol: String
    let tone: Tone
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollsIfNeeded {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
                actions
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The stick in words. Up on the stick is forward.
private extension CGPoint {
    var driveState: String {
        if abs(y) < 0.2 { return x < 0 ? "Turning left" : "Turning right" }
        let way = y < 0 ? "Forward" : "Backward"
        guard abs(x) > 0.35 else { return way }
        return way + (x < 0 ? " left" : " right")
    }

    /// In steps of five, so the number stays readable while the thumb moves.
    var drivePercent: Int { Int((min(1, hypot(x, y)) * 20).rounded()) * 5 }
}

/// The disc shared by the joystick and the direction pad.
private struct DriveBase: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.paper.opacity(0.7))
                .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
            Color.clear.glass(in: Circle())
            Circle()
                .fill(Theme.track)
                .padding(radius * 0.3)
        }
        .accessibilityHidden(true)
    }
}

private struct Joystick: View {
    @Binding var value: CGPoint
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let directions: [(symbol: String, x: CGFloat, y: CGFloat)] = [
        ("chevron.up", 0, -1), ("chevron.down", 0, 1), ("chevron.left", -1, 0), ("chevron.right", 1, 0)
    ]

    private var moving: Bool { value != .zero }
    private var atLimit: Bool { hypot(value.x, value.y) >= 0.99 }

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let knob = radius * 0.38
            let travel = radius - knob - 6
            ZStack {
                DriveBase(radius: radius)
                ForEach(Self.directions, id: \.symbol) { direction in
                    chevron(direction, radius: radius)
                }
                tether(radius: radius, knob: knob, travel: travel)
                knobView(size: knob * 2)
                    .offset(x: value.x * travel, y: value.y * travel)
            }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .gesture(steering(radius: radius, travel: travel))
        }
        // A drag the system cancels never reaches onEnded, but this state always resets,
        // so a phone call or a system gesture can't leave the robot driving.
        .onChange(of: touching) { _, held in
            guard !held else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { value = .zero }
        }
        // That state can't report back from a view that's gone, such as after switching inputs.
        .onDisappear { value = .zero }
        .sensoryFeedback(trigger: moving) { _, now in .impact(weight: now ? .medium : .light) }
        .sensoryFeedback(.selection, trigger: atLimit) { _, now in now }
        .accessibilityElement()
        .accessibilityLabel("Drive Joystick")
        .accessibilityValue(moving ? "\(value.driveState), \(value.drivePercent) percent" : "Stopped")
        .accessibilityHint("Drag to drive. Let go to stop.")
        .accessibilityDirectTouch()
    }

    private func steering(radius: CGFloat, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { drag in
                let x = (drag.location.x - radius) / travel
                let y = (drag.location.y - radius) / travel
                let length = hypot(x, y)
                // A small dead zone, so a resting thumb can't creep the robot along.
                guard length > 0.08 else {
                    value = .zero
                    return
                }
                let scale = max(1, length)
                value = CGPoint(x: x / scale, y: y / scale)
            }
    }

    /// Lights up as the stick leans towards it.
    private func chevron(_ direction: (symbol: String, x: CGFloat, y: CGFloat), radius: CGFloat) -> some View {
        let lean = max(0, value.x * direction.x + value.y * direction.y)
        return ZStack {
            Image(systemName: direction.symbol).foregroundStyle(Theme.faint)
            Image(systemName: direction.symbol).foregroundStyle(Theme.cobalt).opacity(lean)
        }
        .font(.system(size: max(12, radius * 0.13), weight: .bold))
        .offset(x: direction.x * radius * 0.82, y: direction.y * radius * 0.82)
    }

    /// Ties the knob to the centre, so direction and speed read at a glance.
    private func tether(radius: CGFloat, knob: CGFloat, travel: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: radius, y: radius))
            path.addLine(to: CGPoint(x: radius + value.x * travel, y: radius + value.y * travel))
        }
        .stroke(Theme.cobalt.opacity(0.22), style: StrokeStyle(lineWidth: knob * 0.6, lineCap: .round))
    }

    private func knobView(size: CGFloat) -> some View {
        Circle()
            .fill(Theme.cobalt.gradient)
            .overlay(Circle().strokeBorder(Theme.onCobalt.opacity(0.25), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: Theme.cobalt.opacity(touching ? 0.45 : 0.25), radius: touching ? 14 : 8, y: 4)
            .scaleEffect(touching && !reduceMotion ? 1.06 : 1)
            .animation(.snappy(duration: 0.18), value: touching)
    }
}

/// Only the moves this robot supports, laid out like a remote. One gesture covers the whole pad,
/// so the thumb can slide between directions and only one press can ever be in progress.
private struct DirectionPad: View {
    let commands: [DriveCommand]
    @Binding var value: CGPoint
    let nudge: (DriveCommand) -> Void
    @GestureState private var touching = false

    private var held: DriveCommand? { commands.first { $0.stick == value } }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / 3
            ZStack {
                DriveBase(radius: side / 2)
                VStack(spacing: 0) {
                    button(.forward, cell: cell)
                    HStack(spacing: cell) {
                        button(.turnLeft, cell: cell)
                        button(.turnRight, cell: cell)
                    }
                    button(.backward, cell: cell)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(pressing(side: side))
        }
        // As on the joystick, this state resets however the touch ends.
        .onChange(of: touching) { _, down in
            if !down { value = .zero }
        }
        .onDisappear { value = .zero }
        .sensoryFeedback(.impact(weight: .medium), trigger: held) { _, now in now != nil }
    }

    private func pressing(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { drag in
                value = direction(at: drag.location, side: side)?.stick ?? .zero
            }
    }

    /// The middle of the pad is somewhere to rest a thumb, not a direction.
    private func direction(at point: CGPoint, side: CGFloat) -> DriveCommand? {
        let x = point.x - side / 2
        let y = point.y - side / 2
        guard hypot(x, y) > side / 6 else { return nil }
        let nearest: DriveCommand = abs(y) >= abs(x) ? (y < 0 ? .forward : .backward) : (x < 0 ? .turnLeft : .turnRight)
        return commands.contains(nearest) ? nearest : nil
    }

    @ViewBuilder private func button(_ command: DriveCommand, cell: CGFloat) -> some View {
        if commands.contains(command) {
            Image(systemName: command.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(held == command ? Theme.onCobalt : Theme.ink)
                .frame(width: cell, height: cell)
                .background {
                    if held == command {
                        Circle()
                            .fill(Theme.cobalt.gradient)
                            .padding(cell * 0.08)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityElement()
                .accessibilityLabel(command.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Moves the robot a short way.")
                .accessibilityAction { nudge(command) }
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }
}

/// A hardware keyboard, as on Valetudo's page. Only offered while one is attached.
private struct KeyboardPad: View {
    @Binding var value: CGPoint
    let active: Bool
    @State private var keys = DriveKeys()

    var body: some View {
        VStack(spacing: 8) {
            KeyCap(label: "W", down: keys.forward)
            HStack(spacing: 8) {
                KeyCap(label: "A", down: keys.left)
                KeyCap(label: "S", down: keys.backward)
                KeyCap(label: "D", down: keys.right)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task(id: active) { await follow() }
        .onDisappear { value = .zero }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard Controls")
        .accessibilityValue(value == .zero ? "Stopped" : "\(value.driveState), \(value.drivePercent) percent")
    }

    /// Reads the keys instead of waiting for key events, as GameController advises, so a key-up
    /// that never arrives or a keyboard that goes away mid-press can't leave the robot driving.
    /// A key already down when this starts doesn't count until it has been let go, because
    /// coming back to the app mustn't set the robot off.
    private func follow() async {
        var armed = false
        while active, !Task.isCancelled {
            let held = DriveKeys.current
            armed = armed || held == DriveKeys()
            keys = armed ? held : DriveKeys()
            if value != keys.stick { value = keys.stick }
            try? await Task.sleep(for: .milliseconds(30))
        }
        keys = DriveKeys()
        value = .zero
    }
}

private struct DriveKeys: Equatable {
    var forward = false
    var backward = false
    var left = false
    var right = false

    static var current: DriveKeys {
        let keyboard = GCKeyboard.coalesced?.keyboardInput
        func down(_ codes: GCKeyCode...) -> Bool {
            codes.contains { keyboard?.button(forKeyCode: $0)?.isPressed == true }
        }
        return DriveKeys(forward: down(.keyW, .upArrow), backward: down(.keyS, .downArrow),
                         left: down(.keyA, .leftArrow), right: down(.keyD, .rightArrow))
    }

    /// Two keys at once still make full speed in total, as on Valetudo's page.
    var stick: CGPoint {
        let x: CGFloat = (right ? 1 : 0) - (left ? 1 : 0)
        let y: CGFloat = (backward ? 1 : 0) - (forward ? 1 : 0)
        let length = hypot(x, y)
        return length == 0 ? .zero : CGPoint(x: x / length, y: y / length)
    }
}

private struct KeyCap: View {
    let label: String
    let down: Bool

    var body: some View {
        Text(label)
            .font(.headline)
            .foregroundStyle(down ? Theme.onCobalt : Theme.slate)
            .frame(width: 48, height: 48)
            .background(down ? Theme.cobalt : Theme.track,
                        in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
    }
}

// MARK: - Shared

/// The live floor plan, or why there isn't one.
private struct PlanStage: View {
    let active: Bool
    /// Only the camera screen shows this, because the camera isn't mentioned anywhere else.
    var showsCameraView = false
    @Environment(RobotStore.self) private var store

    var body: some View {
        if let plan = store.plan, !plan.isEmpty {
            PlanCanvas(plan: plan, active: active,
                       paused: store.connected && store.state.isUnfinished,
                       insets: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
                       overlay: { context, t in
                           if showsCameraView { CameraCone.draw(for: plan, in: context, t) }
                       })
        } else if !store.connected || store.mapLoadFailed {
            ContentUnavailableView {
                Label("Can't Load the Floor Plan", systemImage: "map")
            } description: {
                Text(store.readAdvice)
            }
            .frame(maxHeight: .infinity)
        } else if store.hasLoaded {
            ContentUnavailableView {
                Label("No Floor Plan Yet", systemImage: "map")
            } description: {
                Text(store.planAdvice)
            }
            .frame(maxHeight: .infinity)
        } else {
            ProgressView("Loading floor plan")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Keeps a message readable in a small space at large text sizes.
private struct ScrollsIfNeeded<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}

// MARK: - Camera

/// Wording shared by every place that can turn streaming off.
enum CameraCopy {
    static let turnOffWarning = "This also deletes the Duststreamer from the robot. To use the camera again, you'd need to turn it on in Valetudo and install the Duststreamer again."
}

/// Live video, or a plain explanation of why there isn't any.
struct CameraFeed: View {
    let stream: CameraStream
    var findings: [ImageLabeler.Finding] = []
    /// True while the owner has asked to identify what's in view, even if nothing has been found.
    var identifying = false
    @Environment(RobotStore.self) private var store
    @State private var stalled = false

    /// "Live" has to be true, so it goes away when frames stop even if the connection hasn't dropped.
    private var live: Bool { stream.phase == .live && !stalled }

    private var failure: String? {
        if case .failed(let message) = stream.phase { return message }
        return nil
    }

    private var aspect: CGFloat {
        guard let frame = stream.frame, frame.height > 0 else { return 4 / 3 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }

    private var seen: String? {
        if !findings.isEmpty { return findings.map(\.label).joined(separator: ", ") }
        return identifying ? "Nothing identified yet" : nil
    }

    var body: some View {
        ZStack {
            Color.black
            if failure == nil, let frame = stream.frame {
                Image(frame, scale: 1, label: Text("Live video from the robot"))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(live ? 1 : 0.4)
            }
            if let failure {
                FeedFailure(message: failure) { stream.start() }
                    .transition(.opacity)
            } else if !live {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Connecting to the camera")
            }
        }
        .overlay(alignment: .topLeading) {
            if live {
                LiveBadge()
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if live, let seen {
                SeenInView(text: seen)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        // Video is always dark, whatever the rest of the app is doing.
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.25), value: live)
        .animation(.snappy(duration: 0.25), value: failure)
        .modifier(KeepsAwake(live: live))
        .task(id: stream.frame.map(ObjectIdentifier.init)) {
            stalled = false
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { stalled = true }
        }
        // A refused stream can mean streaming was turned off elsewhere. Asking now means the
        // camera can leave the screen straight away, instead of on the next routine check.
        .onChange(of: failure) { _, failed in
            if failed != nil { Task { await store.loadCamera() } }
        }
    }
}

/// Keeps the screen on while video is playing, but only for a while. Auto-lock is the only thing
/// that stops the stream on a phone left on a table, so it always has to come back.
private struct KeepsAwake: ViewModifier {
    let live: Bool
    @State private var expired = false

    func body(content: Content) -> some View {
        content
            .onChange(of: live && !expired, initial: true) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            .task {
                try? await Task.sleep(for: .seconds(15 * 60))
                expired = true
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Shown only while frames are arriving. The dot is state, so it holds still.
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

private struct SeenInView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "eye")
            .font(.footnote.weight(.medium))
            .imageScale(.small)
            .foregroundStyle(Theme.ink)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glass(in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In view: \(text)")
    }
}

private struct FeedFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollsIfNeeded {
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.slate)
                    .accessibilityHidden(true)
                Text("No Video")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(Metric.gutter)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Spectator view: the camera above the live floor plan.
struct CameraView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stream: CameraStream?
    @State private var labelsOn = false
    @State private var findings: [ImageLabeler.Finding] = []
    @State private var confirmOff = false
    @State private var turningOff = false
    @State private var fullScreen = false

    /// Video should only run while someone is looking at it.
    private var shouldStream: Bool { store.cameraReady && scenePhase == .active && !turningOff }
    private var identifying: Bool { labelsOn && shouldStream }
    private var showsLightHint: Bool { store.switches[.cameraLight] == true && !store.state.isActive }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("Camera")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(fullScreen ? .hidden : .automatic, for: .navigationBar)
                .statusBarHidden(fullScreen)
                .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    if store.cameraEnabled {
                        ToolbarItem(placement: .primaryAction) { actions }
                    }
                }
                .modifier(ToastHost(toast: store.toast))
                .sensoryFeedback(.selection, trigger: labelsOn)
                .task { await store.loadCamera() }
                .onChange(of: shouldStream, initial: true) { _, on in
                    if on {
                        let camera = stream ?? CameraStream(client: store.client)
                        stream = camera
                        camera.start()
                    } else {
                        stream?.stop()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // The setup notice asks people to come back here once they've finished.
                    if phase == .active, !store.cameraReady { Task { await store.loadCamera() } }
                }
                // Streaming was turned off elsewhere. Valetudo's page leaves the camera too,
                // because nothing may mention it from then on.
                .onChange(of: store.cameraEnabled, initial: true) { _, on in
                    if !on, !turningOff { dismiss() }
                }
                .onDisappear { stream?.stop() }
                .confirmationDialog("Turn off camera streaming?", isPresented: $confirmOff, titleVisibility: .visible) {
                    Button("Turn Off and Delete", role: .destructive) {
                        stream?.stop()
                        turningOff = true
                        store.disableCamera()
                        dismiss()
                    }
                } message: {
                    Text(CameraCopy.turnOffWarning)
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        if store.cameraReady || turningOff {
            player
        } else if store.cameraEnabled {
            setupNotice
        }
    }

    private var actions: some View {
        Menu {
            if store.cameraReady {
                Section {
                    Toggle("Identify What's in View", systemImage: "eye", isOn: $labelsOn)
                    if store.switches[.cameraLight] != nil {
                        Toggle("Camera Light", systemImage: "flashlight.on.fill", isOn: Binding(
                            get: { store.switches[.cameraLight] ?? false },
                            set: { store.set(.cameraLight, to: $0) }))
                    }
                }
            }
            Button("Turn Off Camera Streaming", systemImage: "video.slash", role: .destructive) { confirmOff = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Camera Options")
    }

    // MARK: Player

    private var player: some View {
        Group {
            if fullScreen {
                turnedVideo
            } else if typeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        video
                        PlanStage(active: store.connected && store.state.isActive, showsCameraView: true).frame(height: 280)
                        notes
                    }
                }
            } else {
                VStack(spacing: 0) {
                    video.layoutPriority(1)
                    PlanStage(active: store.connected && store.state.isActive, showsCameraView: true)
                    notes
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: showsLightHint)
        .task(id: identifying) {
            guard identifying else {
                findings = []
                return
            }
            while !Task.isCancelled {
                if let frame = stream?.frame, stream?.phase == .live {
                    let latest = await ImageLabeler.analyze(frame)
                    withAnimation(.easeInOut(duration: 0.2)) { findings = latest }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The app stays upright, so the picture turns to use the phone's long edge.
    private var turnedVideo: some View {
        GeometryReader { geo in
            video
                .frame(width: geo.size.height, height: geo.size.width)
                .rotationEffect(.degrees(90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }

    private var fullScreenButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { fullScreen.toggle() }
        } label: {
            Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(6)
        .accessibilityLabel(fullScreen ? "Exit Full Screen" : "Full Screen")
    }

    @ViewBuilder private var video: some View {
        if let stream, !turningOff {
            CameraFeed(stream: stream, findings: findings, identifying: identifying)
                .overlay(alignment: .bottomTrailing) { fullScreenButton }
        } else {
            Color.black.aspectRatio(4 / 3, contentMode: .fit)
        }
    }

    private var notes: some View {
        VStack(spacing: 6) {
            if showsLightHint {
                Text("The camera light only comes on while the robot is moving.")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ink)
                    .transition(.opacity)
            }
            Text("People near the robot can't tell when it's streaming. Make sure everyone in your home knows.")
                .foregroundStyle(Theme.slate)
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Other states

    /// Valetudo keeps this step manual on purpose, so the app explains it and stops there.
    private var setupNotice: some View {
        ScrollsIfNeeded {
            VStack(spacing: 14) {
                Image(systemName: "video.badge.ellipsis")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.slate)
                    .accessibilityHidden(true)
                Text("Finish Setting Up the Camera")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Camera streaming is on, but the Duststreamer isn't on the robot yet. Place an executable copy at this path, then come back here.")
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                if let path = store.cameraInstallPath {
                    Text(path)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .card(padding: 14, radius: Metric.controlRadius)
                }
                if let link = URL(string: "https://github.com/Hypfer/Duststreamer") {
                    Link("Get the Duststreamer", destination: link)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
                Text("Valetudo keeps this step manual on purpose, so a robot can't become a hidden camera with one tap.")
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Metric.gutter + 8)
        }
    }
}
