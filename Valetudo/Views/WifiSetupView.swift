import SwiftUI

/// A robot that hasn't joined a Wi-Fi network, and what its setup screen shows about it.
struct WifiSetup: Identifiable {
    let id = UUID()
    let client: Client
    let model: String?
    let version: String?
    let canScan: Bool

    /// Asks what Valetudo's web page asks before it shows its setup page instead of the app:
    /// can this robot join Wi-Fi, is this the robot itself, and is it still off the network?
    static func needed(on client: Client) async throws -> WifiSetup? {
        let capabilities: [String]
        do {
            capabilities = try await client.get(Cap.root)
        } catch is DecodingError {
            // Something else is at this address, which connecting goes on to report.
            return nil
        }
        guard capabilities.contains(Cap.wifi),
              (try? await client.getJSON("/valetudo"))?["embedded"] as? Bool == true,
              (try? await client.getJSON("\(Cap.root)/\(Cap.wifi)"))?["state"] as? String == "not_connected" else {
            return nil
        }
        let info = try? await client.get("/robot", as: RobotInfo.self)
        let model = [info?.manufacturer, info?.modelName].compactMap { $0 }.joined(separator: " ")
        return WifiSetup(client: client, model: model.isEmpty ? nil : model,
                         version: (try? await client.get("/valetudo/version", as: VersionInfo.self))?.release,
                         canScan: capabilities.contains(Cap.wifiScan))
    }
}

/// Covers the app with the setup flow when a saved robot has lost its network, which is how
/// most robots change networks: their Wi-Fi is reset with their buttons.
struct WifiSetupGate: ViewModifier {
    let client: Client
    @State private var setup: WifiSetup?

    func body(content: Content) -> some View {
        content
            .task { setup = try? await WifiSetup.needed(on: client) }
            .fullScreenCover(item: $setup) { WifiSetupView(setup: $0) }
    }
}

/// A network from the robot's scan.
private struct NearbyWifi: Identifiable {
    let name: String
    let dBm: Double?
    var id: String { name }

    private var strength: Double { dBm ?? -200 }

    /// A signal in words, since dBm means little to most people.
    var word: String? {
        guard let dBm, dBm < 0 else { return nil }
        if dBm >= -55 { return "Excellent" }
        if dBm >= -67 { return "Good" }
        return dBm >= -75 ? "Fair" : "Weak"
    }

    /// How much of the Wi-Fi symbol to fill.
    var level: Double {
        guard let dBm, dBm < 0 else { return 0 }
        if dBm >= -67 { return 1 }
        return dBm >= -75 ? 0.66 : 0.33
    }

    /// Mesh systems list one name many times, so keep each name's strongest reading.
    /// Hidden networks have no name to show, so they're left for the owner to type.
    static func list(from scan: [[String: Any]]) -> [NearbyWifi] {
        var strongest: [String: NearbyWifi] = [:]
        for entry in scan {
            let details = entry["details"] as? [String: Any]
            guard let name = details?["ssid"] as? String, !name.isEmpty else { continue }
            let network = NearbyWifi(name: name, dBm: details?["signal"] as? Double)
            if let known = strongest[name], known.strength >= network.strength { continue }
            strongest[name] = network
        }
        return strongest.values.sorted { ($1.strength, $0.name) < ($0.strength, $1.name) }
    }
}

/// Joins a robot to a Wi-Fi network, as Valetudo's own setup page does.
struct WifiSetupView: View {
    private enum Field { case name, password }

    private struct Joining: Equatable {
        let network: String
        /// False when the robot went quiet instead of answering, which leaving its own network causes.
        let confirmed: Bool
    }

    /// How many networks show at first, as on Valetudo's page.
    private static let batch = 5
    private static let fieldShape = RoundedRectangle(cornerRadius: Metric.controlRadius + 2, style: .continuous)
    private static let form = "form"

    let setup: WifiSetup
    /// Runs when the owner leaves the finished screen, with the network the robot is joining.
    var onFinish: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var networks: [NearbyWifi] = []
    @State private var shown = WifiSetupView.batch
    @State private var scans = 0
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var sending = false
    @State private var failure: String?
    @State private var joining: Joining?
    @FocusState private var focus: Field?

    private var canJoin: Bool { !ssid.isEmpty && !password.isEmpty && !sending }

    private var robotLine: String {
        [setup.model, setup.version.map { "Valetudo \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 24) {
                        if let joining {
                            finished(joining)
                        } else {
                            hero
                            if setup.canScan { nearby }
                            form
                        }
                    }
                    .padding(.horizontal, Metric.gutter)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .task(id: focus) {
                    guard focus != nil else { return }
                    // The keyboard is still rising, and scrolling now would leave the button behind it.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3)) {
                        scroller.scrollTo(Self.form, anchor: .bottom)
                    }
                }
            }
            .background(Theme.mist.ignoresSafeArea())
            .navigationTitle("Wi-Fi Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if joining == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(sending)
                    }
                }
            }
        }
        .task(id: scans) { await scan() }
        .onChange(of: failure) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .onChange(of: joining) { _, new in
            if let new { AccessibilityNotification.Announcement("Joining \(new.network)").post() }
        }
        .sensoryFeedback(.success, trigger: joining) { _, new in new != nil }
        .sensoryFeedback(.error, trigger: failure) { _, new in new != nil }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            RobotGlyph(size: 72)
            Text("Join Your Wi-Fi")
                .font(.title.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("This robot isn't on your network yet. Choose your Wi-Fi so this app can reach it.")
                .foregroundStyle(Theme.slate)
            if !robotLine.isEmpty {
                Text(robotLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    // MARK: Nearby networks

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                GroupTitle("Nearby Networks")
                Spacer(minLength: 8)
                Button("Scan Again") { scans += 1 }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: Metric.hitTarget)
                    .disabled(scanning)
            }
            VStack(spacing: 0) {
                if networks.isEmpty {
                    scanStatus
                }
                ForEach(networks.prefix(shown)) { network in
                    if network.id != networks.first?.id { FieldDivider() }
                    row(network)
                }
                if networks.count > shown {
                    FieldDivider()
                    Button { shown += Self.batch } label: {
                        Text("Show More")
                            .foregroundStyle(Theme.cobalt)
                            .frame(maxWidth: .infinity, minHeight: Metric.hitTarget + 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .background(Theme.paper, in: Self.fieldShape)
        }
    }

    private var scanStatus: some View {
        HStack(spacing: 10) {
            if scanning { ProgressView() }
            Text(scanMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: Metric.hitTarget + 6)
    }

    private var scanMessage: String {
        if scanning { return "Searching. This can take up to a minute." }
        return scanFailed ? "Couldn't search for networks. You can still type yours below."
                          : "No networks found yet. Scan again, or type yours below."
    }

    private func row(_ network: NearbyWifi) -> some View {
        Button {
            ssid = network.name
            focus = .password
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wifi", variableValue: network.level)
                    .foregroundStyle(Theme.slate)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(network.name)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if network.name == ssid {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: Metric.hitTarget + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityValue(network.word.map { "\($0) signal" } ?? "")
        .accessibilityAddTraits(network.name == ssid ? .isSelected : [])
    }

    // MARK: Details

    private var form: some View {
        VStack(spacing: 24) {
            details
            WideButton(title: "Connect the Robot", busyTitle: "Sending to the Robot", busy: sending, action: join)
                .disabled(!canJoin)
        }
        .id(Self.form)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("Your Wi-Fi")
            if let failure {
                Banner(text: failure, tone: .critical)
            }
            VStack(spacing: 0) {
                IconField(symbol: "wifi") {
                    TextField("Network Name", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
                FieldDivider()
                IconField(symbol: "key") {
                    passwordField
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .password)
                        .submitLabel(.join)
                        .onSubmit(join)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(Theme.slate)
                            .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(showPassword ? "Hide Password" : "Show Password")
                }
            }
            .background(Theme.paper, in: Self.fieldShape)
            .disabled(sending)
            Text("If the name or password is wrong, the robot can't join. You'd then need to reset its Wi-Fi with its buttons and start again.")
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var passwordField: some View {
        if showPassword {
            TextField("Password", text: $password)
        } else {
            SecureField("Password", text: $password)
        }
    }

    // MARK: Finished

    private func finished(_ joining: Joining) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
                .accessibilityHidden(true)
            Text("Joining \(joining.network)")
                .font(.title.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(joining.confirmed ? "The robot has your details and is joining now."
                                   : "The robot stopped answering, which usually means it's already on its way.")
                .foregroundStyle(Theme.ink)
            Text("Its own network goes away now, so reconnect this phone to \(joining.network) if that doesn't happen by itself.")
                .foregroundStyle(Theme.slate)
            Text("If the robot doesn't appear within a few minutes, the name or password may be wrong. Reset its Wi-Fi with its buttons and start again.")
                .foregroundStyle(Theme.slate)
            WideButton(title: "Find My Robot") {
                onFinish(joining.network)
                dismiss()
            }
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Talking to the robot

    /// The robot answers from what it already knows after about two seconds while its radio
    /// keeps looking for up to a minute, so an empty first answer doesn't mean nothing's there.
    private func scan() async {
        guard setup.canScan else { return }
        scanning = true
        defer { scanning = false }
        for _ in 0..<8 {
            do {
                networks = NearbyWifi.list(from: try await setup.client.getList("\(Cap.root)/\(Cap.wifiScan)"))
                scanFailed = false
            } catch {
                scanFailed = !(error is CancellationError)
                return
            }
            guard networks.isEmpty else { return }
            try? await Task.sleep(for: .seconds(5))
            // Once the robot has its orders it's leaving this network, so there's no one to ask.
            if Task.isCancelled || sending || joining != nil { return }
        }
    }

    private func join() {
        guard canJoin else { return }
        sending = true
        failure = nil
        focus = nil
        let network = ssid
        let body: [String: Any] = ["ssid": ssid,
                                   "credentials": ["type": "wpa2_psk", "typeSpecificSettings": ["password": password]]]
        Task {
            defer { sending = false }
            do {
                try await setup.client.put("\(Cap.root)/\(Cap.wifi)", body)
                joining = Joining(network: network, confirmed: true)
            } catch let error as APIError where error.mayHaveArrived {
                joining = Joining(network: network, confirmed: false)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
