import SwiftUI

// MARK: - Root

/// What the rows say at a glance. Anything the robot didn't answer stays blank rather than guessed.
private struct RowValues {
    var wifi: String?
    var mqtt: String?
    var login: String?
    var update: String?
}

struct SettingsView: View {
    /// Valetudo's own rule for names, which it refuses anything else against.
    private static let longestName = 24

    @Environment(RobotStore.self) private var store
    @Environment(Session.self) private var session
    @State private var confirmDisconnect = false
    @State private var confirmRestore = false
    @State private var confirmCameraOff = false
    @State private var showLogin = false
    @State private var restoring = false
    @State private var canRestore = true
    @State private var rows = RowValues()
    @State private var name = ""
    @FocusState private var editingName: Bool

    private var hasBehavior: Bool {
        RobotSwitch.allCases.contains { store.has($0.rawValue) }
            || ChoiceSetting.allCases.contains { store.has($0.rawValue) }
    }

    private var hasSavedLogin: Bool { Connection.load()?.username != nil }

    /// Valetudo swaps its whole configuration for the defaults, keeping only how it talks to
    /// the robot. So routines go too, which nobody would guess from "settings".
    private var restoreWarning: String {
        let warning = "This deletes all routines and the robot's name, and resets MQTT, time and update settings. "
            + "The login turns off, so anyone on your network can control the robot. This can't be undone. "
            + "Your floor plan, Wi-Fi and the robot's own settings aren't changed."
        return store.cameraEnabled ? warning + " Camera streaming also turns off." : warning
    }

    private var disconnectWarning: String {
        let keeps = "The robot keeps its floor plan and schedule."
        if hasSavedLogin {
            return keeps + " This phone forgets the login, so you'll need the username and password to connect again."
        }
        return keeps + " You can connect again at any time."
    }

    var body: some View {
        NavigationStack {
            List {
                Section { RobotHeader() }
                if store.needsLogin {
                    Section {
                        Banner(text: RobotStore.loginAdvice, tone: .critical, action: { showLogin = true })
                            .settingsBareRow()
                    }
                }
                if !store.reachable {
                    Section {
                        Banner(text: "Can't reach the robot. If it moved to another network, disconnect it below and find it again.",
                               tone: .critical)
                            .settingsBareRow()
                    }
                }
                robotSection
                connectionsSection
                systemSection
                if store.has(Cap.camera), store.cameraEnabled {
                    Section {
                        Button(role: .destructive) { confirmCameraOff = true } label: {
                            Text("Turn Off Camera Streaming").frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("This also deletes the Duststreamer from the robot.")
                    }
                }
                if canRestore { restoreSection }
                Section {
                    Button(role: .destructive) { confirmDisconnect = true } label: {
                        Text("Disconnect This Robot").frame(maxWidth: .infinity)
                    }
                }
            }
            .settingsList()
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogin) { SignInSheet() }
            .onAppear {
                if !editingName { name = store.friendlyName }
            }
            .onDisappear(perform: commitName)
            .onChange(of: store.friendlyName) {
                if !editingName { name = store.friendlyName }
            }
            .onChange(of: name) {
                // Only while typing: tidying a name the robot sent would rename it on the way out.
                guard editingName else { return }
                let clean = Self.cleanName(name)
                if clean != name { name = clean }
            }
            .onChange(of: editingName) {
                if !editingName { commitName() }
            }
            .task(id: ObjectIdentifier(store)) { await loadRowValues() }
            .confirmationDialog("Turn off camera streaming?", isPresented: $confirmCameraOff, titleVisibility: .visible) {
                Button("Turn Off and Delete", role: .destructive) { store.disableCamera() }
            } message: {
                Text(CameraCopy.turnOffWarning)
            }
            .confirmationDialog("Restore default configuration?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button(store.routines.isEmpty ? "Restore Defaults" : "Delete Routines and Restore", role: .destructive) {
                    restoreDefaults()
                }
            } message: {
                Text(restoreWarning)
            }
            .confirmationDialog("Disconnect this robot?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { session.disconnect() }
            } message: {
                Text(disconnectWarning)
            }
        }
    }

    private var robotSection: some View {
        Section {
            SettingsField {
                SettingRow("Name", "tag.fill", .indigo)
            } field: {
                TextField("Robot Name", text: $name, prompt: Text("Your robot"))
                    .focused($editingName)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { editingName = false }
            }
            if hasBehavior {
                NavigationLink { BehaviorView() } label: { SettingRow("Behavior", "slider.horizontal.3", .blue) }
            }
            if store.has(Cap.volume) || store.has(Cap.voicePacks) || store.has(Cap.speakerTest) {
                NavigationLink { SoundView() } label: { SettingRow("Sound and Voice", "speaker.wave.2.fill", .pink) }
            }
            if store.has(Cap.quirks) {
                NavigationLink { QuirksView() } label: { SettingRow("Advanced Options", "wrench.adjustable.fill", Theme.slate) }
            }
        } header: {
            Text("Robot")
        } footer: {
            if editingName {
                Text("Names can use the letters A to Z, numbers, spaces and hyphens, up to \(Self.longestName) characters.")
            }
        }
    }

    private var connectionsSection: some View {
        Section("Connections") {
            if store.has(Cap.wifi) {
                NavigationLink { WifiView() } label: { SettingRow("Wi-Fi", "wifi", .blue, value: rows.wifi) }
            }
            NavigationLink { MQTTView() } label: {
                SettingRow("MQTT", "point.3.connected.trianglepath.dotted", .teal, value: rows.mqtt)
            }
            NavigationLink { TimeView() } label: { SettingRow("Time", "clock.fill", .orange) }
            NavigationLink { AdvertisementView() } label: { SettingRow("Finding This Robot", "dot.radiowaves.left.and.right", .cyan) }
            NavigationLink { LoginView() } label: { SettingRow("Login", "lock.fill", .indigo, value: rows.login) }
        }
    }

    private var systemSection: some View {
        Section("System") {
            NavigationLink { UpdaterView() } label: {
                SettingRow("Updates", "arrow.down.circle.fill", .green, value: rows.update)
            }
            NavigationLink { SystemInfoView() } label: { SettingRow("System Information", "cpu.fill", Theme.slate) }
            NavigationLink { LogView() } label: { SettingRow("Log", "doc.text.fill", .brown) }
            NavigationLink { AboutView() } label: { SettingRow("About", "info.circle.fill", .blue) }
            if let url = URL(string: store.client.baseURL) {
                SettingsLinkRow("Open Valetudo's Web Page", "safari.fill", .blue, url: url)
            }
        }
    }

    private var restoreSection: some View {
        Section {
            Button(role: .destructive) { confirmRestore = true } label: {
                HStack(spacing: 8) {
                    if restoring { ProgressView() }
                    Text("Restore Default Configuration")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(restoring)
        } footer: {
            Text("Deletes all routines and the robot's name, turns the login off, and resets MQTT, time and update settings. Your floor plan and Wi-Fi aren't changed.")
        }
    }

    private static func cleanName(_ text: String) -> String {
        let allowed = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-") }
        return String(allowed.prefix(longestName))
    }

    private func commitName() {
        guard name != store.friendlyName else { return }
        store.rename(to: name)
    }

    private func restoreDefaults() {
        restoring = true
        let client = store.client
        Task {
            defer { restoring = false }
            do {
                try await client.put("/valetudo/action", ["action": "restoreDefaultConfiguration"])
                await reloadAfterRestore(address: client.baseURL)
            } catch {
                store.report(error)
            }
        }
    }

    /// The robot has dropped its login, so a saved one is only misleading now. Connecting
    /// without it makes a new store, which loads everything again.
    private func reloadAfterRestore(address: String) async {
        let done = "Default configuration restored"
        if hasSavedLogin {
            do {
                try await session.connect(address: address, username: "", password: "")
                session.store?.notify(done)
                return
            } catch {
                // The old store still works: the robot ignores a login it no longer needs.
            }
        }
        await store.loadEverything()
        await loadRowValues()
        store.notify(done)
    }

    private func loadRowValues() async {
        let client = store.client
        let wifiPath = store.has(Cap.wifi) ? "\(Cap.root)/\(Cap.wifi)" : nil
        async let about = Self.document(client, "/valetudo")
        async let wifi = Self.document(client, wifiPath)
        async let mqtt = Self.document(client, "/valetudo/config/interfaces/mqtt")
        async let link = Self.document(client, "/mqtt/status")
        async let login = Self.document(client, "/valetudo/config/interfaces/http/auth/basic")
        async let updater = Self.document(client, "/updater/state")
        let answers = await (about, wifi, mqtt, link, login, updater)
        guard !Task.isCancelled else { return }
        canRestore = answers.0?["embedded"] as? Bool != false
        rows = RowValues(wifi: Self.wifiValue(answers.1),
                         mqtt: Self.mqttValue(config: answers.2, status: answers.3),
                         login: (answers.4?["enabled"] as? Bool).map { $0 ? "On" : "Off" },
                         update: Self.updateValue(answers.5))
    }

    private static func document(_ client: Client, _ path: String?) async -> [String: Any]? {
        guard let path else { return nil }
        return try? await client.getJSON(path)
    }

    private static func wifiValue(_ status: [String: Any]?) -> String? {
        if let ssid = (status?["details"] as? [String: Any])?["ssid"] as? String { return ssid }
        return status?["state"] as? String == "not_connected" ? "Not Connected" : nil
    }

    /// The status alone can't tell "off" from "failing", because both can read as disconnected.
    private static func mqttValue(config: [String: Any]?, status: [String: Any]?) -> String? {
        guard let enabled = config?["enabled"] as? Bool else { return nil }
        guard enabled else { return "Off" }
        return (status?["state"] as? String).map { MQTTLink.status($0).text }
    }

    /// Only for an update someone has already found: the robot never looks by itself.
    private static func updateValue(_ state: [String: Any]?) -> String? {
        let kind = state?["__class"] as? String ?? ""
        if kind.contains("ApprovalPending") { return "Available" }
        return kind.contains("ApplyPending") ? "Ready to Install" : nil
    }
}

/// The banner at the top of Settings, like the Apple Account row in iOS.
private struct RobotHeader: View {
    @Environment(RobotStore.self) private var store

    /// The robot vacuum symbol arrived in iOS 18, and a missing symbol would draw nothing.
    private var symbol: String {
        if #available(iOS 18.0, *) { return "robotic.vacuum.fill" }
        return "circle.circle.fill"
    }

    private var model: String {
        [store.info?.manufacturer, store.info?.modelName].compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: .indigo, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isEmpty {
                    Text(model)
                        .font(.subheadline)
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsStatusValue(text: store.needsLogin ? "Sign In Needed" : (store.reachable ? "Connected" : "Offline"),
                                    tone: store.connected ? .good : .critical)
                    .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Behavior

private extension RobotSwitch {
    /// What the switch does, with any cost Valetudo's web page warns about.
    var note: String {
        switch self {
        case .carpet: return "Raises the suction when the robot finds carpet."
        case .obstacles: return "Steers around obstacles it senses. It can sometimes avoid things that aren't there."
        case .pets: return "Also looks out for what pets leave behind. The robot will avoid more things that aren't there."
        case .obstaclePhotos: return "Takes a photo of each obstacle it finds. Tap an obstacle on the floor plan to see it."
        case .gentle: return "Drives a more careful route to avoid bumping into things, but it may miss some spots."
        case .floorDirection: return "Cleans along the direction of the floor, such as wooden boards."
        case .mopExtension: return "Reaches the mop out towards walls and furniture."
        case .mopFurniture: return "Uses the extending mop to get close to the legs of chairs and tables."
        case .mopTwist: return "Twists the robot to mop closer to walls and furniture. Cleaning takes longer."
        case .mopAutoDry: return "Dries the mop pads after each cleaning."
        case .cameraLight: return "Lights up dark areas so the robot can recognize obstacles."
        case .persistentMap: return "When this is off, the robot draws a new floor plan on every run. Turning it off deletes the current one."
        case .childLock: return "Turns off the buttons on the robot."
        }
    }
}

private extension ChoiceSetting {
    /// "Empty the Bin" reads like a button, and the control sheet has one by that name.
    var rowTitle: String { self == .autoEmptyInterval ? "Auto-Empty Frequency" : title }

    /// The order Valetudo's web page lists these in. The robot's own order is arbitrary.
    private var order: [String] {
        switch self {
        case .cleanRoute: return ["quick", "normal", "intensive", "deep"]
        case .carpetSensor: return ["lift", "avoid", "detach", "off"]
        case .autoEmptyInterval: return ["frequent", "normal", "infrequent", "off"]
        case .autoEmptyDuration: return ["auto", "short", "medium", "long"]
        case .mopWash: return ["cold", "warm", "hot", "scalding", "boiling"]
        case .mopDry: return ["2h", "3h", "4h", "5h", "quiet", "cold"]
        }
    }

    func sorted(_ options: [String]) -> [String] {
        func rank(_ option: String) -> Int { order.firstIndex(of: option) ?? order.count }
        return options.sorted { rank($0) < rank($1) }
    }

    func label(_ raw: String) -> String {
        switch (self, raw) {
        case (.carpetSensor, "off"): return "None"
        case (.carpetSensor, "avoid"): return "Avoid Carpet"
        case (.carpetSensor, "lift"): return "Lift Mop"
        case (.carpetSensor, "detach"): return "Detach Mop"
        case (.mopDry, _):
            if raw.hasSuffix("h"), let hours = Int(raw.dropLast()) { return "\(hours) Hours" }
            return PresetKind.label(raw)
        default:
            return PresetKind.label(raw)
        }
    }

    var note: String {
        switch self {
        case .cleanRoute: return "Trades speed for thoroughness."
        case .carpetSensor: return "What the robot does if it finds carpet while mopping."
        case .autoEmptyInterval: return "Whether the dock empties the robot, and how often."
        case .autoEmptyDuration: return "How long the dock takes to empty the robot."
        case .mopWash: return "How much the dock heats the water it rinses the mop with."
        case .mopDry: return "How long the dock dries the mop with hot air after cleaning."
        }
    }
}

private struct BehaviorView: View {
    private enum Item: Identifiable {
        case choice(ChoiceSetting)
        case toggle(RobotSwitch)

        var id: String {
            switch self {
            case .choice(let item): return item.id
            case .toggle(let item): return item.id
            }
        }
    }

    private static let groups: [(title: String, items: [Item])] = [
        ("Cleaning", [.choice(.cleanRoute), .toggle(.carpet), .toggle(.floorDirection)]),
        ("Mopping", [.choice(.carpetSensor), .toggle(.mopExtension), .toggle(.mopFurniture), .toggle(.mopTwist)]),
        ("Obstacles", [.toggle(.obstacles), .toggle(.pets), .toggle(.gentle), .toggle(.obstaclePhotos), .toggle(.cameraLight)]),
        ("Dock", [.choice(.autoEmptyInterval), .choice(.autoEmptyDuration), .choice(.mopWash), .choice(.mopDry), .toggle(.mopAutoDry)]),
        ("Robot", [.toggle(.persistentMap), .toggle(.childLock)])
    ]

    @Environment(RobotStore.self) private var store
    @State private var confirmForgetPlan = false
    @State private var routeProperties: [String: Any] = [:]
    @State private var retrying = false

    /// The robot lists it, but its value never arrived.
    private var isMissingValues: Bool {
        RobotSwitch.allCases.contains { store.has($0.rawValue) && store.switches[$0] == nil }
            || ChoiceSetting.allCases.contains { store.has($0.rawValue) && store.choices[$0] == nil }
    }

    private var phase: SettingsLoad {
        if !store.switches.isEmpty || !store.choices.isEmpty { return .ready }
        if retrying || !store.hasLoaded { return .loading }
        return .failed("The robot didn't send these settings.")
    }

    private func supports(_ item: Item) -> Bool {
        switch item {
        case .choice(let setting): return store.choices[setting] != nil
        case .toggle(let setting): return store.switches[setting] != nil
        }
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: reload) {
            List {
                if isMissingValues, store.hasLoaded { missingNotice }
                ForEach(Self.groups, id: \.title) { group in
                    let items = group.items.filter(supports)
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { row(for: $0) }
                        }
                    }
                }
            }
        }
        .settingsPage("Behavior")
        .confirmationDialog("Stop keeping the floor plan?", isPresented: $confirmForgetPlan, titleVisibility: .visible) {
            Button("Delete Floor Plan", role: .destructive) { store.set(.persistentMap, to: false) }
        } message: {
            Text("This deletes the current floor plan, including its rooms, names and no-go zones. It can't be undone. The robot then draws a new one on every run.")
        }
        .task {
            await store.loadSettings()
            guard store.has(ChoiceSetting.cleanRoute.rawValue) else { return }
            routeProperties = (try? await store.client.getJSON("\(Cap.root)/\(ChoiceSetting.cleanRoute.rawValue)/properties")) ?? [:]
        }
    }

    private var missingNotice: some View {
        Section {
            Banner(text: "Some settings didn't load, so they're not shown. Tap to try again.", action: reload)
                .settingsBareRow()
        }
    }

    /// The note sits under the control, so the control itself keeps a single tidy line.
    private func row(for item: Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item {
            case .choice(let setting): picker(setting)
            case .toggle(let setting): toggle(setting)
            }
            Text(note(for: item))
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inside a stack a picker can lose its row layout, so the label is spelled out.
    private func picker(_ setting: ChoiceSetting) -> some View {
        LabeledContent(setting.rowTitle) {
            Picker(setting.rowTitle, selection: Binding(
                get: { store.choices[setting]?.value ?? "" },
                set: { store.set(setting, to: $0) })) {
                ForEach(setting.sorted(store.choices[setting]?.options ?? []), id: \.self) {
                    Text(setting.label($0)).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// The switch stays on until the dialog is answered, because the store only changes when
    /// it's told to. Valetudo's web page guards this one the same way.
    private func toggle(_ setting: RobotSwitch) -> some View {
        Toggle(title(of: setting), isOn: Binding(
            get: { store.switches[setting] ?? false },
            set: { on in
                if setting == .persistentMap, !on {
                    confirmForgetPlan = true
                } else {
                    store.set(setting, to: on)
                }
            }))
    }

    private var twistsWithExtension: Bool { store.has(RobotSwitch.mopExtension.rawValue) }

    private func title(of setting: RobotSwitch) -> String {
        setting == .mopTwist && twistsWithExtension ? "Twist to Reach Under Furniture" : setting.title
    }

    private func note(for item: Item) -> String {
        switch item {
        case .toggle(.mopTwist) where twistsWithExtension:
            return "With the mop extended, twists the robot to reach further under furniture."
        case .toggle(let setting):
            return setting.note
        case .choice(.cleanRoute):
            return routeNote
        case .choice(.mopDry):
            let cold = store.choices[.mopDry]?.options.contains("cold") == true
            return ChoiceSetting.mopDry.note + (cold ? " Cold turns the heater off and runs for much longer." : "")
        case .choice(let setting):
            return setting.note
        }
    }

    /// Some routes only do anything in certain cases, and the robot says which.
    private var routeNote: String {
        func names(_ key: String) -> [String] {
            (routeProperties[key] as? [String] ?? []).map(ChoiceSetting.cleanRoute.label)
        }
        var note = ChoiceSetting.cleanRoute.note
        let mopOnly = names("mopOnly")
        if !mopOnly.isEmpty {
            note += " \(mopOnly.formatted(.list(type: .and))) only \(mopOnly.count > 1 ? "apply" : "applies") when mopping."
        }
        let oneTime = names("oneTime")
        if !oneTime.isEmpty {
            note += " \(oneTime.formatted(.list(type: .and))) \(oneTime.count > 1 ? "apply" : "applies") to one cleaning only."
        }
        return note
    }

    private func reload() {
        retrying = true
        Task {
            await store.loadEverything()
            retrying = false
        }
    }
}

// MARK: - Sound

private struct SoundView: View {
    private static var voicePath: String { "\(Cap.root)/\(Cap.voicePacks)" }

    @Environment(RobotStore.self) private var store
    @State private var volume: Double?
    @State private var dragging = false
    @State private var voice: [String: Any] = [:]
    @State private var voicePhase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var url = ""
    @State private var language = ""
    @State private var hash = ""
    @State private var sending = false

    private var status: [String: Any] { voice["operationStatus"] as? [String: Any] ?? [:] }
    private var statusType: String { status["type"] as? String ?? "idle" }
    private var isWorking: Bool { statusType == "downloading" || statusType == "installing" }

    /// Blanks stay out: a robot only falls back to its own defaults for what's missing, and
    /// Dreame would otherwise send an empty language.
    private var installRequest: [String: String] {
        var request = ["action": "download", "url": url]
        if !language.isEmpty { request["language"] = language }
        if !hash.isEmpty { request["hash"] = hash }
        return request
    }

    /// Robots often report no progress at all, and report it as 0 to 100 when they do.
    private var progress: Double? {
        guard let value = (status["progress"] as? NSNumber)?.doubleValue, value > 0 else { return nil }
        return min(value, 100)
    }

    /// Robots report codes, and custom packs can use any code they like.
    private var languageName: String {
        guard let code = voice["currentLanguage"] as? String else { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    var body: some View {
        List {
            if store.has(Cap.volume) || store.has(Cap.speakerTest) {
                Section("Volume") {
                    if let current = store.volume {
                        volumeRow(current)
                    } else if store.has(Cap.volume) {
                        Text(store.hasLoaded ? "The robot didn't send its volume." : "Loading")
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                    }
                    if store.has(Cap.speakerTest) {
                        Button {
                            store.testSound()
                        } label: {
                            Label("Play Test Sound", systemImage: "speaker.wave.2")
                        }
                    }
                }
            }
            if store.has(Cap.voicePacks) { voicePackSections }
        }
        .settingsPage("Sound and Voice")
        .task { await store.loadSettings() }
        .task(id: attempt) {
            guard store.has(Cap.voicePacks) else { return }
            await SettingsLoad.keepFresh(every: isWorking ? 1 : 3, phase: $voicePhase) {
                voice = try await store.client.settingsDocument(Self.voicePath)
            }
        }
        // VoiceOver adjusts a slider without the editing callbacks, so settle on a pause too.
        .task(id: volume) {
            guard volume != nil, !dragging else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, !dragging { commitVolume() }
        }
    }

    private func volumeRow(_ current: Double) -> some View {
        let shown = volume ?? current
        return VStack(spacing: 8) {
            HStack {
                Text("Voice Volume")
                Spacer()
                Text("\(Int(shown))%")
                    .foregroundStyle(Theme.slate)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: shown)
            }
            .accessibilityHidden(true)
            Slider(value: Binding(get: { shown }, set: { volume = $0 }), in: 0...100, step: 1) {
                Text("Voice Volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill").foregroundStyle(Theme.slate)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.slate)
            } onEditingChanged: { editing in
                dragging = editing
                if !editing { commitVolume() }
            }
            .accessibilityValue("\(Int(shown)) percent")
            .sensoryFeedback(.selection, trigger: Int(shown) / 10)
        }
        .padding(.vertical, 2)
    }

    private func commitVolume() {
        guard let volume else { return }
        store.setVolume(volume)
        self.volume = nil
    }

    @ViewBuilder private var voicePackSections: some View {
        Section {
            switch voicePhase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading").foregroundStyle(Theme.slate)
                }
            case .failed(let message):
                voicePackFailure(message)
            case .ready, .stale:
                voicePackStatus
            }
        } header: {
            Text("Voice Pack")
        } footer: {
            if voicePhase == .stale { Text(store.staleAdvice) }
        }
        if voicePhase.hasData { voicePackForm }
    }

    private func voicePackFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
            Button {
                voicePhase = .loading
                attempt += 1
            } label: {
                Text("Try Again")
                    .frame(minHeight: Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var voicePackStatus: some View {
        LabeledContent("Current Language", value: languageName)
        if isWorking {
            voicePackProgress
        } else if statusType == "error" {
            SettingsProblem("The voice pack didn't install. The log has the details.")
                .font(.subheadline)
        }
    }

    @ViewBuilder private var voicePackProgress: some View {
        let title = statusType == "downloading" ? "Downloading" : "Installing"
        if let progress {
            ProgressView(title, value: progress, total: 100)
                .foregroundStyle(Theme.slate)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(title).foregroundStyle(Theme.slate)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var voicePackForm: some View {
        Section {
            SettingsField("URL") {
                TextField("URL", text: $url, prompt: Text(verbatim: "https://"))
                    .settingsPlainInput()
                    .keyboardType(.URL)
            }
            SettingsField("Language Code") {
                TextField("Language Code", text: $language, prompt: Text(verbatim: "VA")).settingsPlainInput()
            }
            SettingsField("Hash") {
                TextField("Hash", text: $hash, prompt: Text("If Needed")).settingsPlainInput()
            }
        } header: {
            Text("Install a Voice Pack")
        } footer: {
            Text("A voice pack replaces what the robot says. It must be in your robot's format, on a web server the robot can reach. Some robots also need a hash of the file, and the kind of hash depends on the firmware. To go back to a built-in voice, install its code, such as EN. The URL field still needs something in it.")
        }
        .disabled(isWorking)
        Section {
            SettingsActionButton("Install Voice Pack", busy: sending || isWorking, action: install)
                .disabled(url.isEmpty || sending || isWorking)
                .settingsBareRow()
        }
    }

    private func install() {
        sending = true
        let client = store.client
        let body = installRequest
        Task {
            defer { sending = false }
            do {
                try await client.put(Self.voicePath, body)
                store.notify("Installing the voice pack")
                // Waiting for the next refresh would leave the button live in the meantime.
                if let latest = try? await client.settingsDocument(Self.voicePath) { voice = latest }
            } catch {
                store.report(error)
            }
        }
    }
}

// MARK: - Advanced Options

/// One of the options that differ from robot to robot.
private struct Quirk: Identifiable {
    enum Control { case action, toggle, menu }

    let id: String
    let title: String
    let description: String
    let value: String
    let options: [String]

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String else { return nil }
        self.id = id
        title = raw["title"] as? String ?? "Option"
        description = raw["description"] as? String ?? ""
        value = raw["value"] as? String ?? ""
        options = raw["options"] as? [String] ?? []
    }

    /// Robots only describe these as lists of choices. An exact match matters: a list with
    /// on, off and a third reported state has to stay a menu.
    var control: Control {
        let choices = Set(options)
        if choices == ["select_to_trigger", "trigger"] { return .action }
        return choices == ["on", "off"] ? .toggle : .menu
    }

    /// These are the robot's words, so only the raw parts are tidied.
    static func label(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "m2", with: "m²")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

private struct QuirksView: View {
    private static var path: String { "\(Cap.root)/\(Cap.quirks)" }

    @Environment(RobotStore.self) private var store
    @State private var quirks: [Quirk] = []
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var busy: Set<String> = []
    @State private var pendingAction: Quirk?

    private var confirmingAction: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            if quirks.isEmpty {
                emptyPage
            } else {
                List {
                    Section {
                        Banner(text: "These options are specific to your robot's model, so they differ from robot to robot. Changes apply right away.",
                               tone: .neutral)
                            .settingsBareRow()
                    }
                    ForEach(quirks) { row($0) }
                }
                .refreshable { await load() }
            }
        }
        .settingsPage("Advanced Options")
        .confirmationDialog(pendingAction.map { "Run \($0.title)?" } ?? "", isPresented: confirmingAction,
                            titleVisibility: .visible, presenting: pendingAction) { quirk in
            Button("Run") { set(quirk, to: "trigger") }
        } message: { quirk in
            if !quirk.description.isEmpty { Text(quirk.description) }
        }
        .task(id: attempt) {
            // Coming back to this tab restarts the task, which has nothing new to do.
            guard !phase.hasData else { return }
            await load()
        }
    }

    private var emptyPage: some View {
        ContentUnavailableView {
            Label("No Advanced Options", systemImage: "wrench.adjustable")
        } description: {
            Text("This robot doesn't have any model-specific options right now.")
        } actions: {
            Button("Check Again", action: retry)
        }
    }

    private func row(_ quirk: Quirk) -> some View {
        Section {
            control(for: quirk)
                .disabled(busy.contains(quirk.id))
        } footer: {
            if !quirk.description.isEmpty { Text(quirk.description) }
        }
    }

    @ViewBuilder private func control(for quirk: Quirk) -> some View {
        switch quirk.control {
        case .action:
            actionRow(quirk)
        case .toggle:
            Toggle(quirk.title, isOn: Binding(
                get: { quirk.value == "on" },
                set: { set(quirk, to: $0 ? "on" : "off") }))
        case .menu:
            Picker(quirk.title, selection: Binding(get: { quirk.value }, set: { set(quirk, to: $0) })) {
                ForEach(quirk.options, id: \.self) { Text(Quirk.label($0)).tag($0) }
            }
            .pickerStyle(.navigationLink)
        }
    }

    /// Stays ready after it runs, because some of these say to run them a few times.
    private func actionRow(_ quirk: Quirk) -> some View {
        Button { pendingAction = quirk } label: {
            HStack {
                Text(quirk.title)
                Spacer(minLength: 8)
                if busy.contains(quirk.id) { ProgressView() }
            }
            .contentShape(Rectangle())
        }
    }

    private func set(_ quirk: Quirk, to value: String) {
        busy.insert(quirk.id)
        let client = store.client
        Task {
            do {
                try await client.put(Self.path, ["id": quirk.id, "value": value])
                store.notify(quirk.control == .action ? "\(quirk.title) started" : "Option changed")
            } catch {
                store.report(error)
            }
            // The robot's answer is what shows, so a refused value doesn't stay on screen.
            await load()
            busy.remove(quirk.id)
        }
    }

    private func load() async {
        do {
            let list = try await store.client.getList(Self.path)
            quirks = list.compactMap(Quirk.init).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            phase = .ready
        } catch is CancellationError {
        } catch {
            phase = phase.hasData ? .stale : .failed(error.localizedDescription)
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}
