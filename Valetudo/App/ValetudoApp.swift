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
    private var following: Task<Void, Never>?

    init() {
        // The unit tests run inside this app, and must never reach a robot saved on that device.
        guard !Self.isUnitTest, let saved = Connection.load() else { return }
        open(saved, password: Keychain.password(for: saved.baseURL))
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
        if !stored {
            store?.notify("Couldn't save the password. You'll need to sign in again next time.",
                          symbol: Tone.warning.symbol, seconds: 6, isProblem: true)
        }
    }

    func disconnect() {
        if let saved = Connection.load() { Keychain.setPassword(nil, for: saved.baseURL) }
        Connection.clear()
        following?.cancel()
        following = nil
        store = nil
    }
}

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            if let store = session.store {
                MainTabs()
                    .environment(store)
                    .modifier(WifiSetupGate(client: store.client))
            } else {
                ConnectView()
            }
        }
        .animation(.snappy(duration: 0.35), value: session.store == nil)
    }
}

struct MainTabs: View {
    @Environment(RobotStore.self) private var store
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
