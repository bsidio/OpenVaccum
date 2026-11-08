import SwiftUI

@main
struct ValetudoApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Theme.cobalt)
        }
    }
}

/// Holds the connected robot. No store means the app shows the connect screen.
@MainActor @Observable
final class Session {
    private(set) var store: RobotStore?
    /// Every robot saved on this phone, favourites first.
    private(set) var robots: [SavedRobot] = []
    /// Shows the connect screen over the current robot, to add another.
    var addingRobot = false
    private var following: Task<Void, Never>?

    init() {
        // The unit tests run inside this app, and must never reach a robot saved on that device.
        guard !Self.isUnitTest else { return }
        robots = RobotList.all()
        guard let saved = Connection.load() else { return }
        open(saved, password: Keychain.password(for: saved.baseURL))
    }

    /// The address of the open robot, which is how saved robots are told apart.
    var currentRobot: String? { store?.client.baseURL }

    func switchTo(_ robot: SavedRobot) {
        guard robot.id != currentRobot else { return }
        robot.connection.save()
        open(robot.connection, password: Keychain.password(for: robot.id))
        refreshRobots()
    }

    func setFavorite(_ favorite: Bool, for robot: SavedRobot) {
        RobotList.setFavorite(favorite, for: robot.id)
        refreshRobots()
    }

    /// Removes a robot from this phone. Removing the open one moves on to the next.
    func forget(_ robot: SavedRobot) {
        if robot.id == currentRobot {
            disconnect()
        } else {
            RobotList.forget(robot.id)
            refreshRobots()
        }
    }

    /// Kept so the list can name robots that aren't open.
    func nameSeen(_ name: String) {
        guard let currentRobot, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        RobotList.setName(name, for: currentRobot)
        refreshRobots()
    }

    private func refreshRobots() {
        let latest = RobotList.all()
        if latest != robots { robots = latest }
    }

    private func open(_ connection: Connection, password: String?) {
        let client = Client(baseURL: connection.baseURL, username: connection.username, password: password)
        let store = RobotStore(client: client)
        self.store = store
        following?.cancel()
        // Owned here rather than by a view: a full-screen cover takes Home out of the window,
        // which would end a view's task just when Drive, Camera or the editor needs live state.
        following = Task { await store.run() }
    }

    /// Opens a robot whose details are already saved, without waiting for it to answer.
    func adopt(_ connection: Connection, password: String?) {
        open(connection, password: password)
    }

    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// A new client starts on the robot's name, which can be quiet while its address works.
    /// That failure moves the client on, so a second try reaches the other address.
    static func verify(_ client: Client) async throws {
        do {
            do {
                _ = try await client.get("/robot", as: RobotInfo.self)
            } catch let error as APIError where error.noAnswer && Connection.fallback(for: client.baseURL) != nil {
                _ = try await client.get("/robot", as: RobotInfo.self)
            }
        } catch is DecodingError {
            throw APIError(message: "Something answered at that address, but it isn't Valetudo.")
        }
    }

    /// Checks the address and login work before saving them.
    func connect(address: String, username: String, password: String) async throws {
        let baseURL = Connection.normalize(address)
        let user = username.isEmpty ? nil : username
        try await Self.verify(Client(baseURL: baseURL, username: user, password: password))
        let stored = Keychain.setPassword(password, for: baseURL)
        let connection = Connection(baseURL: baseURL, username: user)
        // A new robot with no saved password couldn't reconnect next launch, so it isn't kept.
        if stored || Connection.load() != nil { connection.save() }
        open(connection, password: password)
        refreshRobots()
        addingRobot = false
        if !stored {
            store?.notify("Couldn't save the password. You'll need to sign in again next time.",
                          symbol: Tone.warning.symbol, seconds: 6, isProblem: true)
        }
    }

    /// Forgets the open robot. If others are saved, the next one opens, unless the owner is
    /// about to look for this one again, as after moving it to another network.
    func disconnect(toFindAgain: Bool = false) {
        if let saved = Connection.load() { RobotList.forget(saved.baseURL) }
        Connection.clear()
        refreshRobots()
        if !toFindAgain, let next = robots.first {
            next.connection.save()
            open(next.connection, password: Keychain.password(for: next.id))
            return
        }
        following?.cancel()
        following = nil
        store = nil
    }
}

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        Group {
            if let store = session.store {
                MainTabs()
                    .environment(store)
                    .modifier(WifiSetupGate(client: store.client))
                    // A fresh screen for each robot, so nothing picked on one can be sent to another.
                    .id(store.client.baseURL)
            } else {
                ConnectView()
            }
        }
        .animation(.snappy(duration: 0.35), value: session.store == nil)
        .sheet(isPresented: $session.addingRobot) {
            NavigationStack {
                ConnectView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.addingRobot = false } }
                    }
            }
        }
    }
}

struct MainTabs: View {
    @Environment(RobotStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")
            ScheduleView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag("schedule")
            CareView()
                .tabItem { Label("Care", systemImage: "heart.text.square") }
                .tag("care")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .modifier(ToastHost(toast: store.toast))
        .modifier(TroubleAnnouncer())
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshOnReturn() } }
        }
        .onChange(of: store.friendlyName, initial: true) { _, name in session.nameSeen(name) }
    }
}

/// VoiceOver hears about trouble on any tab, not only with the focus on Home's headline.
private struct TroubleAnnouncer: ViewModifier {
    @Environment(RobotStore.self) private var store

    private var trouble: String? {
        store.connected && store.state.status != "error" ? nil : store.sentence
    }

    func body(content: Content) -> some View {
        content.onChange(of: trouble) { _, new in
            AccessibilityNotification.Announcement(new ?? store.sentence).post()
        }
    }
}
