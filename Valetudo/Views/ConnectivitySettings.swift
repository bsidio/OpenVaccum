import SwiftUI

// MARK: - Wi-Fi

/// A signal reading in words, since dBm means little to most people. The steps are the
/// ones Valetudo's web page draws its signal bars from.
private struct WifiSignal {
    let dBm: Double

    var word: String {
        if dBm >= 0 { return "Unknown" }
        if dBm >= -55 { return "Excellent" }
        if dBm >= -66 { return "Good" }
        return dBm >= -77 ? "Fair" : "Weak"
    }

    /// How much of the Wi-Fi symbol to fill.
    var level: Double {
        if dBm >= 0 { return 0 }
        if dBm >= -66 { return 1 }
        return dBm >= -77 ? 0.66 : 0.33
    }
}

private struct NearbyNetwork: Identifiable {
    let name: String
    let signal: WifiSignal?
    var id: String { name }

    /// Mesh systems list one name many times, so keep each name's strongest reading.
    /// Entries with no name are hidden networks, which can only be joined by typing the name.
    static func list(from scan: [[String: Any]]) -> [NearbyNetwork] {
        var strongest: [String: NearbyNetwork] = [:]
        for entry in scan {
            let details = entry["details"] as? [String: Any]
            guard let name = details?["ssid"] as? String, !name.isEmpty else { continue }
            let network = NearbyNetwork(name: name, signal: (details?["signal"] as? Double).map(WifiSignal.init))
            if let known = strongest[network.name], known.strength >= network.strength { continue }
            strongest[network.name] = network
        }
        return strongest.values.sorted { ($0.strength, $1.name) > ($1.strength, $0.name) }
    }

    private var strength: Double { signal?.dBm ?? -200 }
}

struct WifiView: View {
    private static let robotGuides = URL(string: "https://valetudo.cloud/pages/general/supported-robots/")!
    private static let wrongDetails = "If the details are wrong, the robot goes offline until you reset its Wi-Fi. Don't use a button labelled Reset, which usually erases the robot."

    @Environment(RobotStore.self) private var store
    @Environment(Session.self) private var session
    @State private var status: [String: Any] = [:]
    @State private var canChange = false
    @State private var networks: [NearbyNetwork] = []
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var ssid = ""
    @State private var password = ""
    @State private var confirm = false
    @State private var confirmSetup = false
    @State private var connecting = false
    /// The network the robot was told to join, which ends this connection.
    @State private var joining: String?
    @State private var picks = 0

    private var details: [String: Any] { status["details"] as? [String: Any] ?? [:] }
    private var isConnected: Bool { status["state"] as? String == "connected" }
    private var signal: WifiSignal? { (details["signal"] as? Double).map(WifiSignal.init) }
    private var addresses: [String] { details["ips"] as? [String] ?? [] }
    private var hasSavedLogin: Bool { Connection.load()?.username != nil }

    private var stateWord: String {
        switch status["state"] as? String {
        case "connected": return "Connected"
        case "not_connected": return "Not Connected"
        default: return "Unknown"
        }
    }

    private var isJoining: Binding<Bool> {
        Binding(get: { joining != nil }, set: { if !$0 { joining = nil } })
    }

    private var forgetsWhat: String {
        hasSavedLogin
            ? "This phone forgets the robot's address and login, so you'll need the username and password to connect again."
            : "This phone forgets the robot's address. You can connect to it again at any time."
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            List {
                connectionSection
                if canChange {
                    if store.has(Cap.wifiScan) { nearbySection }
                    changeSection
                    Section {
                        SettingsActionButton("Connect the Robot", busy: connecting) { confirm = true }
                            .disabled(ssid.isEmpty || password.isEmpty || connecting)
                            .confirmationDialog("Move the robot to \(ssid)?", isPresented: $confirm, titleVisibility: .visible) {
                                Button("Connect the Robot") { connect() }
                            } message: {
                                Text(Self.wrongDetails)
                            }
                            .settingsBareRow()
                    }
                } else {
                    resetSections
                }
            }
            .refreshable { await load() }
        }
        .settingsPage("Wi-Fi")
        .sensoryFeedback(.selection, trigger: picks)
        .alert("The Robot Is Changing Networks", isPresented: isJoining, presenting: joining) { _ in
            Button("Find the Robot") { session.disconnect(toFindAgain: true) }
        } message: { network in
            Text(afterJoining(network))
        }
        .task(id: attempt) {
            guard !phase.hasData else { return }
            await load()
        }
    }

    private func afterJoining(_ network: String) -> String {
        let steps = "If the details are right, the robot joins \(network) and this connection ends. Put this phone back on your home Wi-Fi, then find the robot again, because its address will change."
        return hasSavedLogin ? steps + " You'll need its username and password." : steps
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: isConnected ? "wifi" : "wifi.slash", variableValue: isConnected ? signal?.level ?? 1 : nil)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isConnected ? Theme.cobalt : Theme.slate)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(details["ssid"] as? String ?? stateWord)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let signal, isConnected {
                        Text("\(signal.word) Signal")
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                    } else if details["ssid"] != nil {
                        Text(stateWord)
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if let signal { LabeledContent("Signal Strength", value: "\(Int(signal.dBm)) dBm") }
            if let band = details["frequency"] as? String {
                LabeledContent("Band", value: band.replacingOccurrences(of: "ghz", with: " GHz"))
            }
            if !addresses.isEmpty {
                LabeledContent(addresses.count > 1 ? "Addresses" : "Address") {
                    Text(addresses.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Current Connection")
        } footer: {
            if !canChange {
                Text("To move the robot to another network, reset its Wi-Fi first. On most robots, press and hold the two outer buttons until the robot speaks. They're usually Home and Spot Clean, or Home and Power if there are only two. Some robots have their own Wi-Fi button.")
            }
        }
    }

    /// Without support for switching, the route goes through the network the robot makes
    /// itself, and this app's saved address doesn't work there.
    @ViewBuilder private var resetSections: some View {
        Section {
            Banner(text: "Check your robot's guide first. On some models Home and Spot Clean erase the robot, and a button labelled Reset near a Wi-Fi light usually does too. Either can remove Valetudo.",
                   tone: .critical)
                .settingsBareRow()
        }
        Section {
            SettingsLinkRow("Find Your Robot's Guide", "book.fill", .blue, url: Self.robotGuides)
            Button("Disconnect to Set Up Wi-Fi") { confirmSetup = true }
                .confirmationDialog("Disconnect to set up Wi-Fi?", isPresented: $confirmSetup, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { session.disconnect(toFindAgain: true) }
                } message: {
                    Text(forgetsWhat)
                }
        } footer: {
            Text("After the reset, join the robot's own Wi-Fi in this phone's Settings, then disconnect here and connect to it. Its address is usually http://192.168.5.1, http://192.168.8.1 or http://10.201.126.1. The app then lets you choose the new network.")
        }
    }

    private var nearbySection: some View {
        Section("Nearby Networks") {
            if networks.isEmpty, !scanning {
                Text(scanFailed ? "Couldn't search for networks." : "No networks found, or the robot is still searching.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
            ForEach(networks) { network in
                Button {
                    ssid = network.name
                    picks += 1
                } label: {
                    networkRow(network)
                }
                .foregroundStyle(Theme.ink)
                .accessibilityLabel(network.name)
                .accessibilityValue(network.signal.map { "\($0.word) signal" } ?? "")
                .accessibilityAddTraits(network.name == ssid ? .isSelected : [])
            }
            Button {
                Task { await scan() }
            } label: {
                HStack(spacing: 10) {
                    if scanning { ProgressView() }
                    Text(scanning ? "Searching" : "Search Again")
                }
            }
            .disabled(scanning)
        }
    }

    private func networkRow(_ network: NearbyNetwork) -> some View {
        HStack(spacing: 10) {
            Text(network.name)
            Spacer(minLength: 8)
            if network.name == ssid {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
            }
            if let signal = network.signal {
                Image(systemName: "wifi", variableValue: signal.level)
                    .foregroundStyle(Theme.slate)
            }
        }
        .contentShape(Rectangle())
    }

    private var changeSection: some View {
        Section {
            SettingsField("Network Name") {
                TextField("Network Name", text: $ssid, prompt: Text("Required"))
                    .settingsPlainInput()
            }
            SettingsField("Password") {
                // Not marked as a password: AutoFill would offer unrelated website logins.
                SettingsPasswordField(title: "Password", text: $password, focusRequest: picks)
            }
        } header: {
            Text("Change Network")
        } footer: {
            Text(store.client.isUnencrypted ? Self.wrongDetails + " This password reaches the robot unencrypted." : Self.wrongDetails)
        }
    }

    private func load() async {
        let client = store.client
        do {
            let body = try await client.settingsDocument("\(Cap.root)/\(Cap.wifi)")
            let properties = try await client.getJSON("\(Cap.root)/\(Cap.wifi)/properties")
            status = body
            canChange = properties["provisionedReconfigurationSupported"] as? Bool == true
                || body["state"] as? String == "not_connected"
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            if phase.hasData {
                store.report(error)
            } else {
                phase = .failed(error.localizedDescription)
            }
            return
        }
        if canChange, store.has(Cap.wifiScan) { await scan() }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            networks = NearbyNetwork.list(from: try await store.client.getList("\(Cap.root)/\(Cap.wifiScan)"))
            scanFailed = false
        } catch is CancellationError {
        } catch {
            scanFailed = true
        }
    }

    private func connect() {
        connecting = true
        let client = store.client
        let name = ssid
        let body: [String: Any] = ["ssid": ssid, "credentials": ["type": "wpa2_psk", "typeSpecificSettings": ["password": password]]]
        Task {
            defer { connecting = false }
            do {
                try await client.put("\(Cap.root)/\(Cap.wifi)", body)
                joining = name
            } catch let error as APIError where error.mayHaveArrived {
                // The robot leaves this network to join the new one, so its answer can get lost.
                joining = name
            } catch {
                store.report(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

// MARK: - Config pages

private extension Dictionary where Key == String, Value == Any {
    func value(_ keys: String...) -> Any? { value(path: keys) }

    func value(path keys: [String]) -> Any? {
        var node: Any? = self
        for key in keys { node = (node as? [String: Any])?[key] }
        return node
    }

    mutating func set(_ value: Any, path keys: ArraySlice<String>) {
        guard let key = keys.first else { return }
        if keys.count == 1 {
            self[key] = value
        } else {
            var child = self[key] as? [String: Any] ?? [:]
            child.set(value, path: keys.dropFirst())
            self[key] = child
        }
    }
}

private extension Optional where Wrapped == Any {
    var hasText: Bool {
        (self as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == false
    }
}

/// The robot swaps saved secrets for this when it sends them, and only keeps the real value
/// if exactly this comes back.
private let hiddenSecret = "<redacted>"

private extension Binding where Value == [String: Any] {
    /// A binding to a value inside nested dictionaries, such as `connection.tls.enabled`.
    func field<T>(_ keys: String..., default fallback: T) -> Binding<T> {
        field(path: keys, default: fallback)
    }

    func field<T>(path keys: [String], default fallback: T) -> Binding<T> {
        Binding<T>(
            get: { wrappedValue.value(path: keys) as? T ?? fallback },
            set: { wrappedValue.set($0, path: keys[...]) })
    }

    /// A secret the robot may be hiding: an empty field means "keep the saved one".
    func secret(path keys: [String], loaded: [String: Any]) -> Binding<String> {
        let stored = field(path: keys, default: "")
        let isSaved = loaded.value(path: keys) as? String == hiddenSecret
        return Binding<String>(
            get: { stored.wrappedValue == hiddenSecret ? "" : stored.wrappedValue },
            set: { stored.wrappedValue = $0.isEmpty && isSaved ? hiddenSecret : $0 })
    }
}

private extension Binding where Value == Int {
    /// A number as text, because a field bound to a number only updates once editing ends,
    /// and Save can be tapped before then. Blank reads as 0, which is never a valid value here.
    var digits: Binding<String> {
        Binding<String>(
            get: { wrappedValue == 0 ? "" : String(wrappedValue) },
            set: { wrappedValue = Int($0.filter { $0.isASCII && $0.isNumber }.prefix(5)) ?? 0 })
    }
}

private extension Binding where Value == String {
    func cleaned(_ clean: @escaping (String) -> String) -> Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = clean($0) })
    }
}

private enum ConfigText {
    /// Reduces a pasted link to its host, as Valetudo's web page does. The robot adds its own
    /// scheme and port, so anything left in would end up there twice.
    static func host(_ text: String) -> String {
        var host = text
        if let scheme = host.range(of: "^[a-zA-Z]+://", options: .regularExpression) { host.removeSubrange(scheme) }
        if let path = host.firstIndex(of: "/") { host = String(host[..<path]) }
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func portProblem(_ value: Any?) -> String? {
        (1...65535).contains(value as? Int ?? 0) ? nil : "Enter a port from 1 to 65535."
    }
}

/// Reads a config document, lets the page edit it, and writes the whole thing back.
/// Nothing editable appears until the real document has arrived, so a failed load can
/// never be saved over the robot's settings.
private struct ConfigEditor<Fields: View>: View {
    let title: String
    let path: String
    var isValid: ([String: Any]) -> Bool = { _ in true }
    /// Tidies what shouldn't be tidied while someone is still typing it.
    var prepare: (inout [String: Any]) -> Void = { _ in }
    var onSaved: () -> Void = {}
    /// Takes the editable document, and the one last read from the robot.
    @ViewBuilder let fields: (Binding<[String: Any]>, [String: Any]) -> Fields
    @Environment(RobotStore.self) private var store
    @State private var config: [String: Any] = [:]
    @State private var original: [String: Any] = [:]
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var saving = false

    private var hasChanges: Bool { NSDictionary(dictionary: config) != NSDictionary(dictionary: original) }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            List { fields($config, original) }
                .disabled(saving)
        }
        .settingsPage(title)
        .settingsDraftGuard(isDirty: hasChanges)
        .settingsKeyboardDone()
        .toolbar {
            if phase.hasData {
                ToolbarItem(placement: .confirmationAction) {
                    SettingsSaveButton(saving: saving, enabled: hasChanges && isValid(config), action: save)
                }
            }
        }
        .task(id: attempt) {
            // Coming back to this tab restarts the task, which mustn't wipe unsaved edits.
            guard !phase.hasData else { return }
            do {
                let body = try await store.client.settingsDocument(path)
                config = body
                original = body
                phase = .ready
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        saving = true
        let client = store.client
        var body = config
        prepare(&body)
        Task {
            defer { saving = false }
            do {
                try await client.put(path, body)
                // Reading it back shows what the robot kept, and hides secrets again.
                let saved = (try? await client.settingsDocument(path)) ?? body
                config = saved
                original = saved
                store.notify("Changes saved")
                onSaved()
            } catch {
                store.report(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

// MARK: - MQTT

/// The connection states the robot reports, in plain words.
enum MQTTLink {
    static func status(_ state: String) -> (text: String, tone: Tone) {
        switch state {
        case "ready": return ("Connected", .good)
        case "init": return ("Connecting", .neutral)
        case "disconnected": return ("Not Connected", .neutral)
        case "lost": return ("Connection Lost", .warning)
        case "alert": return ("Connection Error", .critical)
        default: return ("Unknown", .neutral)
        }
    }
}

/// What the robot says about its connection to the server.
private struct MQTTStatus {
    let state: String
    let statistics: [(title: String, value: String)]

    init(_ body: [String: Any]) {
        func count(_ keys: String...) -> Int { body.value(path: ["stats"] + keys) as? Int ?? 0 }
        func size(_ keys: String...) -> String { Int64(body.value(path: ["stats"] + keys) as? Int ?? 0).formatted(.byteCount(style: .file)) }
        state = body["state"] as? String ?? ""
        statistics = [
            ("Messages Sent", count("messages", "count", "sent").formatted()),
            ("Data Sent", size("messages", "bytes", "sent")),
            ("Messages Received", count("messages", "count", "received").formatted()),
            ("Data Received", size("messages", "bytes", "received")),
            ("Connects", count("connection", "connects").formatted()),
            ("Disconnects", count("connection", "disconnects").formatted()),
            ("Reconnects", count("connection", "reconnects").formatted()),
            ("Errors", count("connection", "errors").formatted())
        ]
    }
}

/// What each robot suggests and offers. Both differ from robot to robot.
private struct MQTTOffer {
    let identifier: String?
    let topicPrefix: String?
    let extras: [String]

    init(_ body: [String: Any]) {
        identifier = body.value("defaults", "identity", "identifier") as? String
        topicPrefix = body.value("defaults", "customizations", "topicPrefix") as? String
        extras = body["optionalExposableCapabilities"] as? [String] ?? []
    }

    /// Reuses the app's own names, so a setting reads the same here as on the Behavior page.
    static func title(of capability: String) -> String {
        if let item = RobotSwitch(rawValue: capability) { return item.title }
        if let item = ChoiceSetting(rawValue: capability) { return item.title }
        switch capability {
        case Cap.consumables: return "Parts and Reminders"
        case Cap.currentStats: return "Current Cleaning Statistics"
        case Cap.totalStats: return "Total Cleaning Statistics"
        case Cap.volume: return "Speaker Volume"
        default:
            return capability.replacingOccurrences(of: "Capability", with: "")
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
    }
}

private enum MQTTText {
    /// The characters Home Assistant accepts, which is why Valetudo's web page keeps to them.
    private static func isSafe(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    static func identifier(_ text: String) -> String { text.filter(isSafe) }

    static func topicPrefix(_ text: String) -> String {
        var clean = text.filter { isSafe($0) || $0 == "/" }
        while clean.contains("//") { clean = clean.replacingOccurrences(of: "//", with: "/") }
        return clean
    }

    /// Only for saving: trimming as you type would make a slash impossible to enter.
    static func trimmedPrefix(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Certificates are pasted in whole, so nothing here may change what arrives.
private struct CertificateField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                .font(.footnote.monospaced())
                .lineLimit(3...10)
                .settingsPlainInput()
        }
    }
}

struct MQTTView: View {
    private enum Path {
        static let host = ["connection", "host"]
        static let port = ["connection", "port"]
        static let username = ["connection", "authentication", "credentials", "username"]
        static let password = ["connection", "authentication", "credentials", "password"]
        static let certificate = ["connection", "authentication", "clientCertificate", "certificate"]
        static let key = ["connection", "authentication", "clientCertificate", "key"]
        static let topicPrefix = ["customizations", "topicPrefix"]
    }

    @Environment(RobotStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var status: MQTTStatus?
    @State private var statusPhase = SettingsLoad.loading
    @State private var offer: MQTTOffer?
    @State private var saves = 0

    var body: some View {
        ConfigEditor(title: "MQTT", path: "/valetudo/config/interfaces/mqtt", isValid: Self.isValid,
                     prepare: Self.prepare, onSaved: { saves += 1 }) { config, loaded in
            statusSection(config)
            if config.wrappedValue.value("enabled") as? Bool == true {
                serverSection(config)
                encryptionSection(config)
                signInSection(config, loaded)
                certificateSection(config, loaded)
                namingSection(config)
                extrasSection(config)
            }
        }
        // Saving restarts this, so the page shows at once how the new settings are doing.
        .task(id: saves) {
            await SettingsLoad.keepFresh(every: 5, phase: $statusPhase, persist: true) {
                status = MQTTStatus(try await store.client.settingsDocument("/mqtt/status"))
                if offer == nil, let body = try? await store.client.settingsDocument("/mqtt/properties") {
                    offer = MQTTOffer(body)
                }
            }
        }
    }

    // MARK: Rules

    private static func isValid(_ config: [String: Any]) -> Bool {
        guard config.value("enabled") as? Bool == true else { return true }
        return serverProblem(config) == nil && signInProblem(config) == nil && certificateProblem(config) == nil
    }

    private static func serverProblem(_ config: [String: Any]) -> String? {
        guard config.value(path: Path.host).hasText else { return "Enter the server's name or address." }
        return ConfigText.portProblem(config.value(path: Path.port))
    }

    private static func signInProblem(_ config: [String: Any]) -> String? {
        guard config.value("connection", "authentication", "credentials", "enabled") as? Bool == true else { return nil }
        return config.value(path: Path.username).hasText ? nil : "Enter a username."
    }

    private static func certificateProblem(_ config: [String: Any]) -> String? {
        guard config.value("connection", "authentication", "clientCertificate", "enabled") as? Bool == true else { return nil }
        let isComplete = config.value(path: Path.certificate).hasText && config.value(path: Path.key).hasText
        return isComplete ? nil : "Add both the certificate and its key."
    }

    private static func prepare(_ config: inout [String: Any]) {
        let prefix = config.value(path: Path.topicPrefix) as? String ?? ""
        config.set(MQTTText.trimmedPrefix(prefix), path: Path.topicPrefix[...])
        // A pasted address can carry its port, and the robot would add a second one.
        let host = config.value(path: Path.host) as? String ?? ""
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !host.contains("["), let port = Int(parts[1]), ConfigText.portProblem(port) == nil {
            config.set(String(parts[0]), path: Path.host[...])
            config.set(port, path: Path.port[...])
        }
        // The robot refuses a bad port even with MQTT off, where the field is hidden.
        if ConfigText.portProblem(config.value(path: Path.port)) != nil {
            config.set(1883, path: Path.port[...])
        }
    }

    // MARK: Sections

    private func statusSection(_ config: Binding<[String: Any]>) -> some View {
        Section {
            Toggle("Use MQTT", isOn: config.field("enabled", default: false)
                .animation(.settingsReveal(reduceMotion: reduceMotion)))
            if let status {
                let link = MQTTLink.status(status.state)
                LabeledContent("Status") {
                    SettingsStatusValue(text: link.text, tone: link.tone)
                }
                .accessibilityElement(children: .combine)
                DisclosureGroup("Statistics") {
                    ForEach(status.statistics, id: \.title) { row in
                        LabeledContent(row.title, value: row.value)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("MQTT connects the robot to home automation systems such as Home Assistant.")
                if statusPhase == .stale || status == nil, !isStatusLoading {
                    Text("Couldn't check the connection just now.")
                }
            }
        }
    }

    private var isStatusLoading: Bool { statusPhase == .loading }

    private func serverSection(_ config: Binding<[String: Any]>) -> some View {
        Section {
            SettingsField("Server") {
                TextField("Server", text: config.field(path: Path.host, default: "").cleaned(ConfigText.host), prompt: Text("Required"))
                    .settingsPlainInput()
                    .keyboardType(.URL)
            }
            SettingsField("Port") {
                TextField("Port", text: config.field(path: Path.port, default: 1883).digits, prompt: Text("Required"))
                    .keyboardType(.numberPad)
            }
        } header: {
            Text("Server")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = Self.serverProblem(config.wrappedValue) { SettingsProblem(problem) }
                Text("Valetudo is built and tested with the Mosquitto server, so try that if another one gives you trouble. Servers don't report blocked topics, so check their access rules if messages go missing.")
            }
        }
    }

    private func encryptionSection(_ config: Binding<[String: Any]>) -> some View {
        let usesTLS = config.wrappedValue.value("connection", "tls", "enabled") as? Bool == true
        return Section {
            Toggle("Use TLS", isOn: config.field("connection", "tls", "enabled", default: false)
                .animation(.settingsReveal(reduceMotion: reduceMotion)))
            if usesTLS {
                CertificateField(title: "Certificate Authority",
                                 text: config.field("connection", "tls", "ca", default: ""), prompt: "Optional")
                Toggle("Ignore Certificate Errors", isOn: config.field("connection", "tls", "ignoreCertificateErrors", default: false))
            }
        } header: {
            Text("Encryption")
        } footer: {
            if usesTLS {
                Text("A server with its own certificate needs that certificate here. Ignoring errors also works with one, but then anyone on your network could pretend to be the server.")
            }
        }
    }

    private func signInSection(_ config: Binding<[String: Any]>, _ loaded: [String: Any]) -> some View {
        let isOn = config.wrappedValue.value("connection", "authentication", "credentials", "enabled") as? Bool == true
        return Section {
            Toggle("Sign In to the Server", isOn: config.field("connection", "authentication", "credentials", "enabled", default: false)
                .animation(.settingsReveal(reduceMotion: reduceMotion)))
            if isOn {
                SettingsField("Username") {
                    TextField("Username", text: config.secret(path: Path.username, loaded: loaded),
                              prompt: Text(Self.prompt(for: Path.username, loaded, otherwise: "Required")))
                        .settingsPlainInput()
                        .textContentType(.username)
                }
                SettingsField("Password") {
                    SettingsPasswordField(title: "Password", text: config.secret(path: Path.password, loaded: loaded),
                                          prompt: Self.prompt(for: Path.password, loaded, otherwise: "Optional"), contentType: .password)
                }
            }
        } header: {
            Text("Sign In")
        } footer: {
            if isOn, let problem = Self.signInProblem(config.wrappedValue) { SettingsProblem(problem) }
        }
    }

    private func certificateSection(_ config: Binding<[String: Any]>, _ loaded: [String: Any]) -> some View {
        let isOn = config.wrappedValue.value("connection", "authentication", "clientCertificate", "enabled") as? Bool == true
        return Section {
            Toggle("Use a Client Certificate", isOn: config.field("connection", "authentication", "clientCertificate", "enabled", default: false)
                .animation(.settingsReveal(reduceMotion: reduceMotion)))
            if isOn {
                CertificateField(title: "Certificate", text: config.secret(path: Path.certificate, loaded: loaded),
                                 prompt: Self.prompt(for: Path.certificate, loaded, otherwise: "Required"))
                CertificateField(title: "Key", text: config.secret(path: Path.key, loaded: loaded),
                                 prompt: Self.prompt(for: Path.key, loaded, otherwise: "Required"))
            }
        } footer: {
            if isOn {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = Self.certificateProblem(config.wrappedValue) { SettingsProblem(problem) }
                    Text("Paste the whole certificate and key, including their first and last lines.")
                }
            }
        }
    }

    private static func prompt(for path: [String], _ loaded: [String: Any], otherwise fallback: String) -> String {
        loaded.value(path: path) as? String == hiddenSecret ? "Saved" : fallback
    }

    private func namingSection(_ config: Binding<[String: Any]>) -> some View {
        Section {
            SettingsField("Identifier") {
                TextField("Identifier", text: config.field("identity", "identifier", default: "").cleaned(MQTTText.identifier),
                          prompt: Text(offer?.identifier ?? "Optional"))
                    .settingsPlainInput()
            }
            SettingsField("Topic Prefix") {
                TextField("Topic Prefix", text: config.field(path: Path.topicPrefix, default: "").cleaned(MQTTText.topicPrefix),
                          prompt: Text(offer?.topicPrefix ?? "Optional"))
                    .settingsPlainInput()
            }
            if let topic = exampleTopic(config.wrappedValue) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example Topic")
                    Text(topic)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.slate)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Naming")
        } footer: {
            Text("The identifier names this robot on the server, and the topic prefix starts every topic it sends. Leave them blank to use the defaults.")
        }
    }

    /// Needs the robot's defaults, because the real topic uses them for anything left blank.
    private func exampleTopic(_ config: [String: Any]) -> String? {
        guard let offer, let defaultPrefix = offer.topicPrefix, let defaultName = offer.identifier else { return nil }
        let typedPrefix = MQTTText.trimmedPrefix(config.value(path: Path.topicPrefix) as? String ?? "")
        let typedName = config.value("identity", "identifier") as? String ?? ""
        let prefix = typedPrefix.isEmpty ? defaultPrefix : typedPrefix
        let name = typedName.isEmpty ? defaultName : typedName
        return "\(prefix)/\(name)/BatteryStateAttribute/level"
    }

    @ViewBuilder private func extrasSection(_ config: Binding<[String: Any]>) -> some View {
        if let offer, !offer.extras.isEmpty {
            Section {
                ForEach(offer.extras, id: \.self) { capability in
                    Toggle(MQTTOffer.title(of: capability), isOn: extra(capability, config))
                }
            } header: {
                Text("Also Share Over MQTT")
            } footer: {
                Text("Extra details the robot can send to your server. Each one stays off until you turn it on.")
            }
        }
    }

    private func extra(_ capability: String, _ config: Binding<[String: Any]>) -> Binding<Bool> {
        let chosen = config.field("optionalExposedCapabilities", default: [String]())
        return Binding(
            get: { chosen.wrappedValue.contains(capability) },
            set: { on in
                // Anything else in the list stays, even if this robot no longer offers it.
                let others = chosen.wrappedValue.filter { $0 != capability }
                chosen.wrappedValue = on ? others + [capability] : others
            })
    }
}

// MARK: - Time

/// What the robot says about its clock, in plain words.
private struct TimeStatus {
    let title: String
    let detail: String?
    let tone: Tone
    let correction: String?
    let robotTime: Date?

    init(_ body: [String: Any]) {
        let state = body["state"] as? [String: Any] ?? [:]
        let kind = state["__class"] as? String ?? ""
        robotTime = (body["robotTime"] as? String).flatMap {
            try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)
        }
        correction = (state["offset"] as? NSNumber).map { Self.words(forMilliseconds: abs($0.doubleValue)) }
        if kind.contains("Synced") {
            (title, detail, tone) = ("Synced", nil, .good)
        } else if kind.contains("Error") {
            (title, detail) = Self.failure(type: state["type"] as? String, message: state["message"] as? String)
            tone = .critical
        } else if kind.contains("Disabled") {
            (title, detail, tone) = ("Off", nil, .neutral)
        } else {
            (title, detail, tone) = ("Waiting for First Sync", nil, .neutral)
        }
    }

    private static func failure(type: String?, message: String?) -> (String, String?) {
        switch type {
        case "name_resolution": return ("Can't Find the Server", "Check the server's name.")
        case "connection": return ("Server Isn't Answering", "Check the server's name and port.")
        case "persisting": return ("Can't Set the Clock", "The robot got the time but couldn't save it.")
        case "transient": return ("Network Problem", "The robot will try again soon.")
        default: return ("Sync Failed", message)
        }
    }

    private static func words(forMilliseconds value: Double) -> String {
        value < 1000 ? "\(Int(value)) ms" : (value / 1000).formatted(.number.precision(.fractionLength(1))) + " seconds"
    }
}

struct TimeView: View {
    private static let hour = 3_600_000
    private static let second = 1000

    @Environment(RobotStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var status: TimeStatus?
    @State private var statusPhase = SettingsLoad.loading
    @State private var saves = 0

    var body: some View {
        ConfigEditor(title: "Time", path: "/ntpclient/config", isValid: Self.isValid, onSaved: { saves += 1 }) { config, _ in
            statusSection
            settingsSection(config)
        }
        // Saving restarts this, so the page shows at once how the new settings are doing.
        .task(id: saves) {
            await SettingsLoad.keepFresh(every: 5, phase: $statusPhase, persist: true) {
                status = TimeStatus(try await store.client.settingsDocument("/ntpclient/status"))
            }
        }
    }

    private static func isValid(_ config: [String: Any]) -> Bool {
        config.value("enabled") as? Bool == false || problem(config) == nil
    }

    private static func problem(_ config: [String: Any]) -> String? {
        guard config.value("server").hasText else { return "Enter the time server's name or address." }
        return ConfigText.portProblem(config.value("port"))
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            if let status {
                LabeledContent("Status") {
                    SettingsStatusValue(text: status.title, tone: status.tone)
                }
                .accessibilityElement(children: .combine)
                if let correction = status.correction { LabeledContent("Last Correction", value: correction) }
                if let robotTime = status.robotTime {
                    LabeledContent("Robot Time", value: robotTime.formatted(date: .abbreviated, time: .standard))
                }
            } else if statusPhase == .loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading").foregroundStyle(Theme.slate)
                }
            } else {
                Text("Couldn't check the robot's clock.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
        } header: {
            Text("Clock")
        } footer: {
            if statusPhase == .stale {
                Text("Couldn't check the robot's clock just now.")
            } else if let detail = status?.detail {
                Text(detail)
            }
        }
    }

    private func settingsSection(_ config: Binding<[String: Any]>) -> some View {
        let isOn = config.wrappedValue.value("enabled") as? Bool != false
        return Section {
            Toggle("Set Time Automatically", isOn: config.field("enabled", default: true)
                .animation(.settingsReveal(reduceMotion: reduceMotion)))
            if isOn {
                SettingsField("Time Server") {
                    TextField("Time Server", text: config.field("server", default: "").cleaned(ConfigText.host), prompt: Text("Required"))
                        .settingsPlainInput()
                        .keyboardType(.URL)
                }
                SettingsField("Port") {
                    TextField("Port", text: config.field("port", default: 123).digits, prompt: Text("Required"))
                        .keyboardType(.numberPad)
                }
                stepper("Check Every", config.field("interval", default: 8 * Self.hour), unit: Self.hour, in: 1...24, name: "Hour")
                stepper("Wait for a Reply", config.field("timeout", default: 10 * Self.second), unit: Self.second, in: 5...60, name: "Second")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if isOn, let problem = Self.problem(config.wrappedValue) { SettingsProblem(problem) }
                Text("The robot needs the right time for routines, for times in the log, and for secure connections such as updates.")
            }
        }
    }

    /// The robot keeps these in milliseconds, which nobody wants to work out.
    private func stepper(_ title: String, _ milliseconds: Binding<Int>, unit: Int, in range: ClosedRange<Int>, name: String) -> some View {
        let count = Binding<Int>(
            get: { min(max(Int((Double(milliseconds.wrappedValue) / Double(unit)).rounded()), range.lowerBound), range.upperBound) },
            set: { milliseconds.wrappedValue = $0 * unit })
        return Stepper(value: count, in: range) {
            LabeledContent(title, value: "\(count.wrappedValue) \(name)\(count.wrappedValue == 1 ? "" : "s")")
        }
    }
}

// MARK: - Finding This Robot

/// Only one setting, so it applies straight away instead of waiting for a Save.
struct AdvertisementView: View {
    private static let path = "/networkadvertisement/config"

    @Environment(RobotStore.self) private var store
    @State private var enabled = true
    @State private var hostname: String?
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var saving = false

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            List {
                Section {
                    Toggle("Announce on the Network", isOn: Binding(get: { enabled }, set: set))
                        .disabled(saving)
                } footer: {
                    Text("This is how apps like this one find the robot by themselves, so it's best left on. When it's off, you'll need to enter the robot's address.")
                }
                addressSection
            }
        }
        .settingsPage("Finding This Robot")
        .task(id: attempt) {
            guard !phase.hasData else { return }
            do {
                let body = try await store.client.settingsDocument(Self.path)
                enabled = body["enabled"] as? Bool ?? true
                hostname = (try? await store.client.getJSON("/networkadvertisement/properties"))?["zeroconfHostname"] as? String
                phase = .ready
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var addressSection: some View {
        Section {
            if let hostname {
                LabeledContent("Local Name") {
                    Text(hostname).textSelection(.enabled)
                }
            }
            LabeledContent("Address") {
                Text(store.client.baseURL).textSelection(.enabled)
            }
        } footer: {
            Text("Announcements don't cross from one network to another. If the robot can't be found, use its address, which your router can also show you.")
        }
    }

    private func set(_ on: Bool) {
        enabled = on
        saving = true
        let client = store.client
        Task {
            defer { saving = false }
            do {
                try await client.put(Self.path, ["enabled": on])
            } catch {
                enabled = !on
                store.report(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

// MARK: - Login

struct LoginView: View {
    private static let path = "/valetudo/config/interfaces/http/auth/basic"
    private static let reconnectAttempts = 5

    @Environment(RobotStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var enabled = false
    @State private var wasEnabled = false
    @State private var savedUsername = ""
    @State private var username = "valetudo"
    @State private var password = ""
    @State private var repeated = ""
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var confirm = false
    @State private var saving = false

    private var cleanUsername: String { username.trimmingCharacters(in: .whitespaces) }

    /// Basic auth splits on the first colon, so one in the name could never sign in.
    private var usernameIsUsable: Bool { !cleanUsername.isEmpty && !cleanUsername.contains(":") }
    private var passwordsDiffer: Bool { !repeated.isEmpty && repeated != password }

    /// The robot stores whatever password it's sent, so keeping the login on always needs one.
    private var canSave: Bool {
        guard enabled else { return wasEnabled }
        return usernameIsUsable && !password.isEmpty && password == repeated
    }

    private var isDirty: Bool {
        enabled != wasEnabled || !password.isEmpty || !repeated.isEmpty || (enabled && cleanUsername != savedUsername)
    }

    private var problem: String? {
        if cleanUsername.contains(":") { return "Usernames can't contain a colon." }
        if passwordsDiffer { return "The passwords don't match." }
        return nil
    }

    private var dialogTitle: String {
        if !enabled { return "Turn off the login?" }
        return wasEnabled ? "Change the login?" : "Turn on the login?"
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            List {
                if store.client.isUnencrypted, enabled {
                    Section {
                        Banner(text: "This connection isn't encrypted. Someone watching your network could read this password, so use one you don't use anywhere else.")
                            .settingsBareRow()
                    }
                }
                loginSection
            }
            .disabled(saving)
        }
        .settingsPage("Login")
        .settingsDraftGuard(isDirty: isDirty)
        .toolbar {
            if phase.hasData {
                ToolbarItem(placement: .confirmationAction) {
                    SettingsSaveButton(saving: saving, enabled: canSave) { confirm = true }
                    .confirmationDialog(dialogTitle, isPresented: $confirm, titleVisibility: .visible) {
                        if enabled {
                            Button("Save Login") { save() }
                        } else {
                            Button("Turn Off Login", role: .destructive) { save() }
                        }
                    } message: {
                        if enabled {
                            Text("Valetudo will ask for the username \(cleanUsername) and this password. If you lose them, you'd need to reach the robot over SSH to reset them.")
                        } else {
                            Text("Anyone on your network will be able to control the robot.")
                        }
                    }
                }
            }
        }
        .task(id: attempt) {
            guard !phase.hasData else { return }
            do {
                let body = try await store.client.settingsDocument(Self.path)
                enabled = body["enabled"] as? Bool ?? false
                wasEnabled = enabled
                username = body["username"] as? String ?? "valetudo"
                savedUsername = username
                phase = .ready
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var loginSection: some View {
        Section {
            Toggle("Require a Login", isOn: $enabled.animation(.settingsReveal(reduceMotion: reduceMotion)))
            if enabled {
                SettingsField("Username") {
                    TextField("Username", text: $username, prompt: Text("Required"))
                        .settingsPlainInput()
                        .textContentType(.username)
                }
                SettingsField("New Password") {
                    SettingsPasswordField(title: "New Password", text: $password, contentType: .newPassword)
                }
                SettingsField("Confirm Password") {
                    SettingsPasswordField(title: "Confirm Password", text: $repeated, contentType: .newPassword)
                }
            }
        } footer: {
            if enabled, let problem {
                SettingsProblem(problem)
            } else {
                Text("Keeps others on your network from controlling the robot without the login, and this phone remembers it. Valetudo tries to block the public internet by default, so use a VPN to reach it from outside your home.")
            }
        }
    }

    private func save() {
        saving = true
        let client = store.client
        let address = client.baseURL
        let on = enabled
        let name = cleanUsername
        let secret = on ? password : ""
        let body: [String: Any] = ["enabled": on, "username": name, "password": secret]
        Task {
            defer { saving = false }
            let login = on ? name : ""
            var unanswered: APIError?
            do {
                try await client.put(Self.path, body)
            } catch let error as APIError where error.mayHaveArrived {
                unanswered = error
            } catch {
                store.report(error)
                return
            }
            if let unanswered {
                // The robot may have changed login and only lost its reply, so ask it. The login
                // saved on this phone stays as it is unless the new one turns out to work.
                if await reconnect(address: address, username: login, password: secret), await robotConfirms(on, name) {
                    settle(on, name)
                    session.store?.notify(on ? "Login saved" : "Login turned off")
                } else {
                    store.report(unanswered)
                }
                return
            }
            // The robot only accepts the new login from here on, so this phone keeps it before
            // anything else can go wrong. Otherwise one missed reply would strand it on the old one.
            let connection = Connection(baseURL: address, username: on ? name : nil)
            connection.save()
            Keychain.setPassword(secret, for: address)
            settle(on, name)
            if await reconnect(address: address, username: login, password: secret) {
                session.store?.notify(on ? "Login saved" : "Login turned off")
            } else {
                session.adopt(connection, password: secret)
                session.store?.notify("Login saved. The robot isn't answering yet.",
                                      symbol: Tone.warning.symbol, seconds: 8, isProblem: true)
            }
        }
    }

    private func settle(_ on: Bool, _ name: String) {
        wasEnabled = on
        username = name
        savedUsername = name
        password = ""
        repeated = ""
    }

    private func reconnect(address: String, username: String, password: String) async -> Bool {
        for _ in 1...Self.reconnectAttempts {
            try? await Task.sleep(for: .seconds(1))
            if (try? await session.connect(address: address, username: username, password: password)) != nil {
                return true
            }
        }
        return false
    }

    /// With login off, any details connect, so a reconnect alone proves nothing.
    private func robotConfirms(_ on: Bool, _ name: String) async -> Bool {
        guard let config = try? await session.store?.client.getJSON(Self.path) else { return false }
        return config["enabled"] as? Bool == on && (!on || config["username"] as? String == name)
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}
