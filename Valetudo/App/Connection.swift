import dnssd
import Foundation
import Network
import Observation
import Security

/// The saved robot. The password lives in the Keychain, never in UserDefaults.
struct Connection: Codable, Equatable {
    var baseURL: String
    var username: String?

    private static let key = "connection"
    private static let fallbackKey = "fallbackAddress"

    static func load() -> Connection? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var saved = try? JSONDecoder().decode(Connection.self, from: data) else { return nil }
        saved.moveLoginOutOfAddress()
        return saved
    }

    /// Makes this the robot the app opens, and keeps it in the list of saved robots.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        RobotList.keep(self)
    }

    /// Forgets which robot is open. The list of saved robots is left alone.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The robot's other address, for when the saved one stops answering.
    /// It's stored apart from the connection, which gets rebuilt whenever the login changes.
    static func fallback(for baseURL: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: fallbackKey) as? [String: String])?[baseURL]
    }

    /// Each saved robot keeps its own, so adding a robot doesn't lose another's.
    static func setFallback(_ fallback: String?, for baseURL: String) {
        var all = UserDefaults.standard.dictionary(forKey: fallbackKey) as? [String: String] ?? [:]
        all[baseURL] = fallback
        UserDefaults.standard.set(all, forKey: fallbackKey)
    }

    /// Accepts "192.168.1.20", "robot.lan:8080", or a full http(s) URL.
    /// A login typed into the address is dropped, because the result gets saved and displayed.
    static func normalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        text = withScheme(text)
        guard var parts = URLComponents(string: text), parts.user != nil || parts.password != nil else { return text }
        parts.user = nil
        parts.password = nil
        return parts.string ?? text
    }

    /// The login in an address such as `http://user:pass@robot.lan`, if there is one.
    static func login(in address: String) -> (username: String, password: String)? {
        let text = withScheme(address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let parts = URLComponents(string: text), let username = parts.user else { return nil }
        return (username, parts.password ?? "")
    }

    private static func withScheme(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? text : "http://\(text)"
    }

    /// Earlier builds could save such a login. Its password is filed under the old address.
    private mutating func moveLoginOutOfAddress() {
        let clean = Self.normalize(baseURL)
        guard clean != baseURL else { return }
        let typed = Self.login(in: baseURL)
        let password = Keychain.password(for: baseURL) ?? typed?.password
        if Keychain.setPassword(password, for: clean) { Keychain.setPassword(nil, for: baseURL) }
        RobotList.forget(baseURL)
        username = username ?? typed?.username
        baseURL = clean
        save()
    }
}

/// A robot this phone has connected to, so the owner can switch between several.
struct SavedRobot: Codable, Equatable, Identifiable {
    var connection: Connection
    /// The robot's own name, from the last time it was open.
    var name: String?
    var favorite = false

    var id: String { connection.baseURL }

    /// The address without the scheme, which is what people recognise.
    var address: String {
        connection.baseURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
    }

    var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? address : trimmed
    }
}

/// The robots saved on this phone. Passwords stay in the keychain, filed by address.
enum RobotList {
    private static let key = "robots"

    /// Favourites first, then by name.
    static func all() -> [SavedRobot] {
        var robots = stored()
        // Builds before this list kept only one robot.
        if robots.isEmpty, let current = Connection.load() {
            robots = [SavedRobot(connection: current)]
            store(robots)
        }
        return robots.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func keep(_ connection: Connection) {
        var robots = stored()
        if let i = robots.firstIndex(where: { $0.id == connection.baseURL }) {
            robots[i].connection = connection
        } else {
            robots.append(SavedRobot(connection: connection))
        }
        store(robots)
    }

    /// Forgets the robot, its password and its other address.
    static func forget(_ baseURL: String) {
        store(stored().filter { $0.id != baseURL })
        Keychain.setPassword(nil, for: baseURL)
        Connection.setFallback(nil, for: baseURL)
    }

    static func setName(_ name: String, for baseURL: String) {
        update(baseURL) { $0.name = name }
    }

    static func setFavorite(_ favorite: Bool, for baseURL: String) {
        update(baseURL) { $0.favorite = favorite }
    }

    private static func update(_ baseURL: String, _ change: (inout SavedRobot) -> Void) {
        var robots = stored()
        guard let i = robots.firstIndex(where: { $0.id == baseURL }) else { return }
        let before = robots[i]
        change(&robots[i])
        if robots[i] != before { store(robots) }
    }

    private static func stored() -> [SavedRobot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedRobot].self, from: data)) ?? []
    }

    private static func store(_ robots: [SavedRobot]) {
        if let data = try? JSONEncoder().encode(robots) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Pages about the app itself, in its public repository.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/bsidio/valetudo-ios/blob/main/PRIVACY.md")!
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Valetudo",
         kSecAttrAccount as String: account]
    }

    static func password(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the password, or removes it when there's none. Says whether that worked.
    /// Updates in place, so a failed write can't lose the password that's already there.
    @discardableResult
    static func setPassword(_ password: String?, for account: String) -> Bool {
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return update == errSecSuccess }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Finds robots through the `_valetudo._tcp` service they advertise.
@MainActor @Observable
final class RobotFinder {
    struct Found: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String?
        let baseURL: String
        /// The `.local` name the robot publishes, which keeps working when its address changes.
        let hostURL: String?

        /// Best first. Not every network passes `.local` names along, so the address stays too.
        var addresses: [String] { [hostURL, baseURL].compactMap { $0 } }
    }

    enum Problem: Equatable { case localNetworkOff, searchStopped }

    /// Where a robot answers on its own Wi-Fi network, from Valetudo's getting-started guide.
    static let hotspotAddresses = ["192.168.5.1", "192.168.8.1", "10.201.126.1"]

    private(set) var robots: [Found] = []
    private(set) var problem: Problem?
    private var browser: NWBrowser?
    private var lookups: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_valetudo._tcp", domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        lookups.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        lookups = [:]
    }

    func restart() {
        stop()
        // A listed robot isn't looked up again, so it would keep an address it may have left.
        robots = []
        start()
    }

    /// The address that answers as a robot, for a phone that has joined a robot's own Wi-Fi.
    static func robotOnItsOwnNetwork() async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for address in hotspotAddresses {
                group.addTask { await answersAsRobot(address) ? address : nil }
            }
            for await found in group {
                if let found {
                    group.cancelAll()
                    return found
                }
            }
            return nil
        }
    }

    private static func answersAsRobot(_ address: String) async -> Bool {
        do {
            _ = try await Client(baseURL: Connection.normalize(address)).get("/robot", as: RobotInfo.self)
            return true
        } catch let error as APIError {
            return error.kind == .needsLogin
        } catch {
            return false
        }
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            problem = nil
        case .waiting(let error):
            if Self.isLocalNetworkOff(error) { problem = .localNetworkOff }
        case .failed(let error):
            problem = Self.isLocalNetworkOff(error) ? .localNetworkOff : .searchStopped
            // Cleared so that `start` can run again.
            stop()
        default:
            break
        }
    }

    private static func isLocalNetworkOff(_ error: NWError) -> Bool {
        error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let names = Set(results.compactMap(Self.name))
        robots.removeAll { !names.contains($0.id) }
        for result in results {
            guard let name = Self.name(result), !robots.contains(where: { $0.id == name }), lookups[name] == nil else { continue }
            resolve(result, name: name)
        }
    }

    private static func name(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    /// Bonjour gives a service name, so connect briefly to learn its address.
    private func resolve(_ result: NWBrowser.Result, name: String, isRetry: Bool = false) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: result.endpoint, using: parameters)
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        lookups[name] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.add(name, at: connection.currentPath?.remoteEndpoint, txt: txt)
                    self.finish(connection, name: name)
                case .failed:
                    self.finish(connection, name: name)
                    if !isRetry { self.retry(result, name: name) }
                case .cancelled:
                    self.finish(connection, name: name)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func add(_ name: String, at endpoint: NWEndpoint?, txt: [String: String]) {
        guard case let .hostPort(host, port) = endpoint, !robots.contains(where: { $0.id == name }) else { return }
        let address = "\(host)".components(separatedBy: "%")[0]
        let suffix = port.rawValue == 80 ? "" : ":\(port.rawValue)"
        let friendly = txt["name"].flatMap { $0.isEmpty ? nil : $0 }
        let title = friendly ?? txt["model"] ?? name
        let detail = [friendly == nil ? txt["manufacturer"] : txt["model"], address].compactMap { $0 }.joined(separator: ", ")
        robots.append(Found(id: name, title: title, detail: detail, baseURL: "http://\(address)\(suffix)",
                            hostURL: Self.hostURL(systemID: txt["id"], suffix: suffix)))
    }

    /// Valetudo names itself `valetudo-<id>.local`. The id can be overridden, so check it fits in a hostname.
    private static func hostURL(systemID: String?, suffix: String) -> String? {
        guard let systemID, !systemID.isEmpty,
              systemID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return "http://valetudo-\(systemID.lowercased()).local\(suffix)"
    }

    /// Dropping the handler frees the connection it holds, and stops a late callback from
    /// clearing a newer lookup of the same name.
    private func finish(_ connection: NWConnection, name: String) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        if lookups[name] === connection { lookups[name] = nil }
    }

    /// Without this, a robot that failed once stays hidden until the browse results change.
    private func retry(_ result: NWBrowser.Result, name: String) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard browser?.browseResults.contains(result) == true, lookups[name] == nil,
                  !robots.contains(where: { $0.id == name }) else { return }
            resolve(result, name: name, isRetry: true)
        }
    }
}
