import SwiftUI

/// First run: finds robots on the network, or connects to an address the owner types.
struct ConnectView: View {
    private enum Field: Hashable { case address, username, password }

    private struct Failure: Equatable {
        let message: String
        var tone: Tone = .critical
    }

    private static let website = URL(string: "https://valetudo.cloud")!
    private static let issues = URL(string: "https://github.com/bsidio/valetudo-ios/issues")!
    private static let addressForm = "addressForm"

    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var finder = RobotFinder()
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showLogin = false
    @State private var showHelp = false
    @State private var connecting = false
    @State private var lookingNearby = false
    /// The listed robot being tried. Nil when the attempt belongs to the address form.
    @State private var chosenRobot: String?
    @State private var failure: Failure?
    /// Set when the robot turns out not to be on a network yet.
    @State private var setup: WifiSetup?
    /// The network a robot was just sent to, which this phone has to join to see it again.
    @State private var joiningNetwork: String?
    @FocusState private var focus: Field?

    private var searching: Bool { finder.robots.isEmpty }
    private var busy: Bool { connecting || lookingNearby }
    private var canConnect: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty && !busy }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3) }

    /// iOS reports Local Network as refused while its permission alert is still up, which
    /// makes the app inactive, so this waits for the owner's answer.
    private var problem: RobotFinder.Problem? { scenePhase == .active ? finder.problem : nil }

    private var subtitle: String {
        guard searching else { return "Tap your robot to connect." }
        switch problem {
        case .localNetworkOff: return "Local Network access is off."
        case .searchStopped: return "The search stopped."
        case nil: break
        }
        if let joiningNetwork { return "Reconnect this phone to \(joiningNetwork), and your robot will appear here." }
        return showHelp ? "No robots found yet." : "Looking for robots on your network."
    }

    private var reveal: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// Failures show on the form unless their robot still has a row of its own to show them on.
    private var formFailure: Failure? {
        finder.robots.contains { $0.id == chosenRobot } ? nil : failure
    }

    var body: some View {
        GeometryReader { screen in
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 28) {
                        hero
                        // After moving one robot to another network, the others are still a tap away.
                        if session.store == nil, !session.robots.isEmpty {
                            Menu {
                                ForEach(session.robots) { robot in
                                    Button(robot.title) { session.switchTo(robot) }
                                }
                            } label: {
                                Label("Open a Saved Robot", systemImage: "list.bullet")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                        if !searching {
                            robotList.transition(reveal)
                        } else if showHelp || problem != nil {
                            HelpCard(problem: problem) { finder.restart() }.transition(reveal)
                            NewRobotCard(looking: lookingNearby, action: findOnItsOwnNetwork)
                                .disabled(busy)
                                .transition(reveal)
                        }
                        addressForm.id(Self.addressForm)
                        Spacer(minLength: 0)
                        footer
                    }
                    .padding(.horizontal, Metric.gutter)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    .frame(minHeight: screen.size.height)
                    .animation(motion, value: finder.robots)
                    .animation(motion, value: showHelp)
                    .animation(motion, value: problem)
                    .animation(motion, value: showLogin)
                    .animation(motion, value: failure)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .task(id: focus) {
                    guard focus != nil else { return }
                    // The keyboard is still rising, and scrolling now would leave Connect behind it.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(motion) { scroller.scrollTo(Self.addressForm, anchor: .bottom) }
                }
            }
        }
        .background(Theme.mist.ignoresSafeArea())
        // The unit tests run inside this app, and must not go looking for real robots.
        .onAppear { if !Session.isUnitTest { finder.start() } }
        .onDisappear { finder.stop() }
        .task(id: searching) {
            showHelp = false
            guard searching else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { showHelp = true }
        }
        .onChange(of: finder.robots.count) { old, new in
            if old == 0, new > 0 {
                AccessibilityNotification.Announcement(new == 1 ? "Found 1 robot" : "Found \(new) robots").post()
            }
        }
        .onChange(of: failure) { _, new in
            if let new { AccessibilityNotification.Announcement(new.message).post() }
        }
        .onChange(of: scenePhase) { _, phase in
            // The owner may have turned Local Network on in Settings, and a refused search stays refused.
            if phase == .active, finder.problem != nil { finder.restart() }
        }
        .fullScreenCover(item: $setup, onDismiss: { finder.restart() }) { setup in
            WifiSetupView(setup: setup) { joiningNetwork = $0 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: finder.robots.count) { old, new in new > old }
        .sensoryFeedback(.error, trigger: failure) { _, new in new != nil }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            RobotRadar(searching: searching && problem == nil, size: typeSize.isAccessibilitySize ? 120 : 176)
            VStack(spacing: 6) {
                Text("Connect Your Robot")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(Theme.slate)
                    .contentTransition(.opacity)
                    .animation(motion, value: subtitle)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Found robots

    private var robotList: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("On This Network")
            ForEach(finder.robots) { robot in
                let chosen = robot.id == chosenRobot
                RobotRow(robot: robot, busy: connecting && chosen, failure: chosen ? failure?.message : nil) {
                    connect(to: robot.addresses, robot: robot)
                }
                .disabled(busy)
                .opacity(busy && !chosen ? 0.5 : 1)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Address

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("Enter an Address")
            if let formFailure {
                Banner(text: formFailure.message, tone: formFailure.tone).transition(reveal)
            }
            VStack(spacing: 0) {
                IconField(symbol: "network") {
                    TextField("Address", text: $address, prompt: Text("192.168.1.20 or robot.local"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(showLogin ? .next : .go)
                        .onSubmit {
                            if showLogin { focus = .username } else { connectToAddress() }
                        }
                }
                FieldDivider()
                if showLogin {
                    IconField(symbol: "person") {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }
                    .onAppear { focus = loginField }
                    FieldDivider()
                    IconField(symbol: "key") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(connectToAddress)
                    }
                } else {
                    Button { showLogin = true } label: {
                        IconField(symbol: "person.badge.key") {
                            Text("Add Username and Password")
                                .foregroundStyle(Theme.cobalt)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius + 2, style: .continuous))
            .disabled(busy)

            if showLogin, Connection.normalize(address).lowercased().hasPrefix("http://") {
                Text("This connection isn't encrypted, so use a password you don't use anywhere else.")
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
                    .padding(.horizontal, 4)
            }

            WideButton(title: "Connect", busyTitle: "Connecting", busy: connecting && chosenRobot == nil, action: connectToAddress)
                .disabled(!canConnect)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Link("What Is Valetudo?", destination: Self.website)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: Metric.hitTarget)
            Text("Your phone talks directly to your robot. Nothing goes through the cloud. This is an unofficial app, not made by the Valetudo project.")
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link("Report a Problem With This App", destination: Self.issues)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: Metric.hitTarget)
            // Here as well as in About, because About can't be reached without a robot.
            Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: Metric.hitTarget)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Connecting

    private var loginField: Field { username.isEmpty ? .username : .password }

    private func connectToAddress() {
        guard canConnect else { return }
        // A login typed into the address belongs in the login fields, away from anything saved.
        if let login = Connection.login(in: address) {
            if username.isEmpty { username = login.username }
            if password.isEmpty { password = login.password }
            address = Connection.normalize(address)
        }
        connect(to: [address])
    }

    /// Tries each address until one answers.
    private func connect(to addresses: [String], robot: RobotFinder.Found? = nil) {
        focus = nil
        connecting = true
        chosenRobot = robot?.id
        failure = nil
        Task {
            for address in addresses {
                do {
                    try await open(address, robot: robot)
                    break
                } catch let error as APIError where error.noAnswer && address != addresses.last {
                    continue
                } catch {
                    handle(error, target: address)
                    break
                }
            }
            connecting = false
        }
    }

    /// A robot that hasn't joined a network yet goes to setup, and isn't saved: it won't be
    /// at this address once it has joined.
    private func open(_ address: String, robot: RobotFinder.Found?) async throws {
        let session = session
        // Ahead of any request, because a robot that asks for a login carries on through the
        // form, which no longer knows which robot this is.
        if let robot, let other = robot.addresses.first(where: { $0 != address }) {
            Connection.setFallback(other, for: Connection.normalize(address))
        }
        let client = Client(baseURL: Connection.normalize(address), username: username.isEmpty ? nil : username, password: password)
        if let needed = try await WifiSetup.needed(on: client) {
            setup = needed
            return
        }
        try await session.connect(address: address, username: username, password: password)
        // The app has already swapped to Home, which is where the owner sees this.
        // The wait lets Home appear first, so the toast slides in and plays its haptic.
        let store = session.store
        try? await Task.sleep(for: .milliseconds(400))
        store?.notify(robot.map { "Connected to \($0.title)" } ?? "Connected")
    }

    private func findOnItsOwnNetwork() {
        lookingNearby = true
        chosenRobot = nil
        failure = nil
        Task {
            let found = await RobotFinder.robotOnItsOwnNetwork()
            lookingNearby = false
            if let found {
                connect(to: [found])
            } else {
                failure = Failure(message: "No robot answered. Check that this phone has joined the robot's Wi-Fi network, then try again.",
                                  tone: .warning)
            }
        }
    }

    private func handle(_ error: Error, target: String) {
        guard (error as? APIError)?.kind == .needsLogin else {
            failure = Failure(message: error.localizedDescription)
            return
        }
        // The robot asked for a login, so carry on in the form, where it can be typed.
        let triedLogin = !username.isEmpty
        failure = Failure(message: triedLogin ? "That username or password didn't work." : error.localizedDescription,
                          tone: .warning)
        chosenRobot = nil
        address = target
        if showLogin { focus = loginField } else { showLogin = true }
    }
}

/// A robot seen from above, drawn so it reads the same at any size.
struct RobotGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.cobalt.gradient)
            // The bumper, along the front edge.
            Circle()
                .trim(from: 0.62, to: 0.88)
                .stroke(Theme.onCobalt.opacity(0.45), style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round))
                .padding(size * 0.08)
            // The laser tower.
            Circle()
                .fill(Theme.onCobalt)
                .overlay { Circle().fill(Theme.cobalt).padding(size * 0.1) }
                .frame(width: size * 0.32, height: size * 0.32)
                .offset(y: -size * 0.05)
            Capsule()
                .fill(Theme.onCobalt.opacity(0.6))
                .frame(width: size * 0.24, height: size * 0.05)
                .offset(y: size * 0.27)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The robot with rings spreading from it while the search runs.
private struct RobotRadar: View {
    let searching: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rings = 3
    private static let period = 3.6

    private var glyphSize: CGFloat { size * 0.46 }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !searching || reduceMotion)) { timeline in
                Canvas { context, canvas in
                    let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / Self.period
                    for ring in 0..<Self.rings {
                        // With Reduce Motion the rings simply sit still, evenly spaced.
                        let phase = (elapsed + (Double(ring) + 0.5) / Double(Self.rings)).truncatingRemainder(dividingBy: 1)
                        let radius = glyphSize / 2 + (canvas.width - glyphSize) / 2 * phase
                        let circle = CGRect(x: canvas.width / 2 - radius, y: canvas.height / 2 - radius,
                                            width: radius * 2, height: radius * 2)
                        context.stroke(Path(ellipseIn: circle),
                                       with: .color(Theme.cobalt.opacity(0.4 * (1 - phase))),
                                       lineWidth: 1.5)
                    }
                }
            }
            .opacity(searching ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: searching)

            RobotGlyph(size: glyphSize)
                .shadow(color: Theme.cobalt.opacity(0.3), radius: glyphSize * 0.16, y: glyphSize * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One robot found on the network. Shows the attempt to connect, and why it failed.
private struct RobotRow: View {
    let robot: RobotFinder.Found
    let busy: Bool
    let failure: String?
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: Metric.controlRadius + 2, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RobotGlyph(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(robot.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    if let detail = robot.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.slate)
                    }
                    if let failure {
                        Text(failure)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.rose)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                status.frame(width: 24)
            }
            .card(padding: 14, radius: Metric.controlRadius + 2)
            .overlay {
                if failure != nil { shape.strokeBorder(Theme.rose, lineWidth: 1.5) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityValue(busy ? "Connecting" : "")
        .accessibilityHint(failure == nil ? "Connects to this robot" : "Tries again")
    }

    @ViewBuilder private var status: some View {
        if busy {
            ProgressView()
        } else if failure != nil {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.rose)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.faint)
                .accessibilityHidden(true)
        }
    }
}

/// What to check when the search has come up empty for a while, or has hit a problem.
private struct HelpCard: View {
    private typealias Tip = (symbol: String, text: String)

    private static let robotTips: [Tip] = [
        ("checkmark.seal", "It needs to be running Valetudo."),
        ("wifi", "It needs to be on the same network as this phone.")
    ]
    private static let localNetworkTip: Tip = ("hand.raised", "Local Network needs to be on for this app in Settings.")

    let problem: RobotFinder.Problem?
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    private var tips: [Tip] {
        problem == .localNetworkOff ? [Self.localNetworkTip] + Self.robotTips : Self.robotTips + [Self.localNetworkTip]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                GroupTitle("Not Seeing Your Robot?")
                ForEach(tips, id: \.symbol) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: tip.symbol)
                            .foregroundStyle(Theme.cobalt)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(tip.text)
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Metric.controlRadius + 2)
    }

    @ViewBuilder private var action: some View {
        switch problem {
        case .localNetworkOff:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        case .searchStopped:
            Button("Search Again", action: retry)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        case nil:
            EmptyView()
        }
    }
}

/// A robot that isn't on a network yet makes its own, which the phone has to join first.
private struct NewRobotCard: View {
    private static let guide = URL(string: "https://valetudo.cloud/pages/general/getting-started/")!

    let looking: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("Setting Up a New Robot?")
            Text("Join the robot's own Wi-Fi network in the Settings app, then come back and tap Find Robot. You can also enter its address below, which is usually \(RobotFinder.hotspotAddresses.formatted(.list(type: .or))).")
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                HStack(spacing: 8) {
                    if looking { ProgressView() }
                    Text(looking ? "Looking" : "Find Robot")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            Link("Valetudo's Getting Started Guide", destination: Self.guide)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: Metric.hitTarget)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Metric.controlRadius + 2)
    }
}

/// A row of a form: a quiet symbol, then its control.
struct IconField<Content: View>: View {
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Theme.slate)
                .frame(width: 26)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: Metric.hitTarget + 6)
    }
}

/// Starts under the row's text, as list separators do.
struct FieldDivider: View {
    var body: some View {
        Divider().padding(.leading, 52)
    }
}

/// A form's one filled button. Keeps its colour while busy, so the spinner stays readable.
struct WideButton: View {
    let title: String
    var busyTitle: String?
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Theme.onCobalt) }
                Text(busy ? busyTitle ?? title : title)
                    .multilineTextAlignment(.center)
            }
            .font(.headline)
            .foregroundStyle(Theme.onCobalt)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.cobalt.gradient, in: Capsule())
            .opacity(isEnabled || busy ? 1 : 0.45)
        }
        .buttonStyle(.pressable)
    }
}
