import SwiftUI

// MARK: - Updates

struct UpdaterView: View {
    private struct Status {
        let title: String
        var detail: String?
        let symbol: String
        let color: Color
        var tone: Tone = .neutral
    }

    @Environment(RobotStore.self) private var store
    @State private var state: [String: Any] = [:]
    @State private var channel = ""
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0
    @State private var sending = false
    @State private var confirmDownload = false
    @State private var confirmInstall = false
    /// Set from the moment Install is confirmed. The robot's state doesn't change while it
    /// installs, and a second install would write over the first.
    @State private var installing = false

    private var kind: String { state["__class"] as? String ?? "" }
    private var busy: Bool { state["busy"] as? Bool ?? false }
    private var newVersion: String { state["version"] as? String ?? "a new version" }
    private var installedVersion: String? { state["currentVersion"] as? String ?? store.version }
    private var isDownloading: Bool { kind.contains("Downloading") }
    private var isReadyToInstall: Bool { kind.contains("ApplyPending") }
    private var isBusy: Bool { busy || sending || installing }

    private var progress: Double? {
        ((state["metaData"] as? [String: Any])?["progress"] as? NSNumber)?.doubleValue
    }

    /// While it installs the robot restarts, so a failed refresh is expected rather than news.
    private var shownPhase: SettingsLoad { installing && phase == .stale ? .ready : phase }

    private var status: Status {
        if installing || (busy && isReadyToInstall) {
            return Status(title: "Installing Update", detail: "The robot may restart, and it can't be reached until it's back.",
                          symbol: "arrow.triangle.2.circlepath", color: .blue)
        }
        if isDownloading {
            return Status(title: "Downloading Update", detail: "Downloading \(newVersion).",
                          symbol: "arrow.down.circle.dotted", color: .blue)
        }
        if busy {
            return Status(title: "Checking for Updates", symbol: "arrow.triangle.2.circlepath", color: Theme.slate)
        }
        return settledStatus
    }

    private var settledStatus: Status {
        if kind.contains("Error") {
            return Status(title: "Update Failed", detail: state["message"] as? String ?? "The update check failed.",
                          symbol: "exclamationmark.triangle.fill", color: .red, tone: .critical)
        }
        if kind.contains("ApprovalPending") {
            return Status(title: "Update Available", detail: "Version \(newVersion) is available.",
                          symbol: "arrow.down.circle.fill", color: .blue)
        }
        if isReadyToInstall {
            return Status(title: "Ready to Install", detail: "Version \(newVersion) is ready. Install it within 10 minutes, or the robot discards the download.",
                          symbol: "arrow.clockwise.circle.fill", color: .blue)
        }
        if kind.contains("NoUpdateRequired") {
            return Status(title: "Up to Date", detail: "You're on the latest version.",
                          symbol: "checkmark.seal.fill", color: .green, tone: .good)
        }
        if kind.contains("Disabled") {
            return Status(title: "Updates Turned Off", detail: "Updates are turned off on this robot.",
                          symbol: "nosign", color: Theme.slate)
        }
        return Status(title: "Not Checked Yet", detail: "The robot only looks for updates when you ask it to.",
                      symbol: "arrow.triangle.2.circlepath", color: Theme.slate)
    }

    var body: some View {
        SettingsLoader(phase: shownPhase, retry: retry) {
            List {
                Section { hero }
                releaseNotes
                channelSection
            }
        }
        .settingsPage("Updates")
        .task(id: attempt) {
            await SettingsLoad.keepFresh(every: 2, phase: $phase) {
                state = try await store.client.settingsDocument("/updater/state")
                if channel.isEmpty {
                    channel = (try? await store.client.getJSON("/updater/config"))?["updateProvider"] as? String ?? ""
                }
                await finishInstallIfDone()
            }
        }
    }

    /// The robot answers with a new state once it's back, or an error if the install failed.
    private func finishInstallIfDone() async {
        guard installing, !isReadyToInstall else { return }
        installing = false
        await store.loadEverything()
    }

    @ViewBuilder private var releaseNotes: some View {
        if let notes = state["changelog"] as? String, !notes.isEmpty {
            if kind.contains("NoUpdateRequired") {
                Section {
                    DisclosureGroup("Release Notes for \(installedVersion ?? "This Version")") {
                        ReleaseNotes(text: notes)
                    }
                }
            } else {
                Section("What's New") { ReleaseNotes(text: notes) }
            }
        }
    }

    @ViewBuilder private var channelSection: some View {
        if ["github", "github_nightly"].contains(channel) {
            Section {
                Picker("Update Channel", selection: Binding(get: { channel }, set: setChannel)) {
                    Text("Stable").tag("github")
                    Text("Nightly").tag("github_nightly")
                }
                // Changing channel resets the updater, which would throw away a download.
                .disabled(isBusy || isDownloading || isReadyToInstall)
            } footer: {
                Text("Nightly builds get changes first, but they're less tested. Updates go one release at a time, so you may need to update more than once. This updates Valetudo, not the robot's firmware.")
            }
        }
    }

    private var hero: some View {
        let status = status
        return VStack(spacing: 14) {
            VStack(spacing: 10) {
                IconTile(symbol: status.symbol, color: status.color, size: 64)
                    .symbolEffect(.bounce, value: status.title)
                VStack(spacing: 2) {
                    Text("Valetudo \(installedVersion ?? "")".trimmingCharacters(in: .whitespaces))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    if installedVersion != nil {
                        Text("Installed Version")
                            .font(.footnote)
                            .foregroundStyle(Theme.slate)
                    }
                }
                VStack(spacing: 2) {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(status.tone == .critical ? status.tone.color : Theme.ink)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            if isDownloading { downloadProgress }
            if isReadyToInstall, !isBusy {
                Banner(text: "Any update can need some troubleshooting afterwards. Make sure you've read the release notes for changes that could affect you.")
            }
            primaryAction
        }
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.25), value: status.title)
    }

    @ViewBuilder private var downloadProgress: some View {
        if let progress {
            let percent = min(max(progress, 0), 100)
            VStack(spacing: 4) {
                ProgressView(value: percent, total: 100)
                    .accessibilityLabel("Download progress")
                Text("\(Int(percent))%")
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: percent)
                    .accessibilityHidden(true)
            }
        } else {
            ProgressView().accessibilityLabel("Downloading")
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if installing {
            EmptyView()
        } else if kind.contains("ApprovalPending") {
            SettingsActionButton("Download Update", busy: isBusy) { confirmDownload = true }
                .disabled(isBusy)
                .confirmationDialog("Download \(newVersion)?", isPresented: $confirmDownload, titleVisibility: .visible) {
                    Button("Download Update") { send("download", done: "Download started") }
                } message: {
                    Text("Read the release notes first. They can include changes that need work from you.")
                }
        } else if isReadyToInstall {
            SettingsActionButton("Install Update", busy: isBusy) { confirmInstall = true }
                .disabled(isBusy)
                .confirmationDialog("Install \(newVersion)?", isPresented: $confirmInstall, titleVisibility: .visible) {
                    Button("Install Update") { install() }
                } message: {
                    Text("The robot may restart while this runs, and you can't reach it until it's back. Any update can need some troubleshooting afterwards.")
                }
        } else if !isDownloading, !kind.contains("Disabled") {
            SettingsActionButton("Check for Updates", busy: isBusy) {
                send("check", done: "Checking for updates")
            }
            .disabled(isBusy)
        }
    }

    private func setChannel(_ value: String) {
        let previous = channel
        channel = value
        let client = store.client
        Task {
            do {
                try await client.put("/updater/config", ["updateProvider": value])
                store.notify("Update channel changed")
            } catch {
                channel = previous
                store.report(error)
            }
        }
    }

    private func send(_ action: String, done: String) {
        sending = true
        let client = store.client
        Task {
            defer { sending = false }
            do {
                try await client.put("/updater", ["action": action])
                store.notify(done)
                if let body = try? await client.settingsDocument("/updater/state") { state = body }
            } catch {
                store.report(error)
            }
        }
    }

    private func install() {
        installing = true
        let client = store.client
        Task {
            do {
                try await client.put("/updater", ["action": "apply"])
                store.notify("Installing the update")
            } catch {
                installing = false
                store.report(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

/// Release notes arrive as Markdown. `Text` only handles inline styles, so headings
/// and bullets are laid out here.
private struct ReleaseNotes: View {
    private static let collapsedLines = 12

    let text: String
    @State private var expanded = false

    /// Notes can contain HTML too, which Valetudo's web page renders and `Text` would print.
    private var lines: [String] {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        let all = lines
        let shown = expanded ? all : Array(all.prefix(Self.collapsedLines))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown.indices, id: \.self) { line(shown[$0]) }
            if all.count > Self.collapsedLines {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Show Less" : "Show More")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: Metric.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        if raw.hasPrefix("#") {
            Text(Self.inline(raw.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        } else if raw.hasPrefix("- ") || raw.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").accessibilityHidden(true)
                Text(Self.inline(String(raw.dropFirst(2))))
            }
            .font(.subheadline)
            .foregroundStyle(Theme.slate)
        } else {
            Text(Self.inline(raw))
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - System Information

/// A coloured dot and a name, for explaining a bar.
private struct LegendItem: View {
    let title: String
    let color: Color
    var value: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(Theme.slate)
            if let value { Text(value).foregroundStyle(Theme.ink).monospacedDigit() }
        }
        .font(.footnote)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Memory drawn like iPhone Storage: one bar, split by what's using it.
private struct MemoryRow: View {
    let total: Double
    let free: Double
    let valetudo: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var used: Double { min(max(total - free, 0), total) }
    private var ownShare: Double { min(valetudo ?? 0, used) }
    private var otherShare: Double { used - ownShare }

    static func megabytes(_ bytes: Double) -> String { "\(Int(bytes / 1_048_576)) MB" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Self.megabytes(used)) of \(Self.megabytes(total)) Used")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Theme.cobalt.frame(width: proxy.size.width * ownShare / total)
                    Color.orange.frame(width: proxy.size.width * otherShare / total)
                    Theme.track
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 4) { legend }
            }
        }
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue("\(Self.megabytes(used)) of \(Self.megabytes(total)) used, \(Self.megabytes(ownShare)) by Valetudo")
    }

    @ViewBuilder private var legend: some View {
        if valetudo != nil { LegendItem(title: "Valetudo", color: Theme.cobalt, value: Self.megabytes(ownShare)) }
        LegendItem(title: valetudo == nil ? "Used" : "Other", color: .orange, value: Self.megabytes(otherShare))
        LegendItem(title: "Free", color: Theme.track, value: Self.megabytes(free))
    }
}

/// One processor core, split by what's keeping it busy. Idle is the part left over.
private struct CoreRow: View {
    static let parts: [(key: String, title: String, color: Color)] = [
        ("user", "Programs", Theme.cobalt),
        ("nice", "Background", .teal),
        ("sys", "System", Theme.rose),
        ("irq", "Hardware", .purple)
    ]

    let number: Int
    let usage: [String: Any]

    private func share(_ key: String) -> Double { min(max((usage[key] as? NSNumber)?.doubleValue ?? 0, 0), 100) }
    private var percent: Int { Int(min(Self.parts.reduce(0) { $0 + share($1.key) }, 100).rounded()) }

    var body: some View {
        HStack(spacing: 10) {
            Text("Core \(number)")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Self.parts, id: \.key) { part in
                        part.color.frame(width: proxy.size.width * share(part.key) / 100)
                    }
                    Theme.track
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            Text("\(percent)%")
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(number)")
        .accessibilityValue("\(percent) percent in use")
    }
}

/// Details that don't change while Valetudo runs, so they're only read once.
private struct RobotFacts {
    var implementation: String?
    var firmware: String?
    var release: String?
    var commit: String?
    var embedded: Bool?
    var systemID: String?
}

struct SystemInfoView: View {
    @Environment(RobotStore.self) private var store
    @State private var host: [String: Any] = [:]
    @State private var facts = RobotFacts()
    @State private var runtime: [String: Any]?
    @State private var runtimeChecked = false
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0

    private static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "Unknown" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .full
        return formatter.string(from: seconds) ?? "Unknown"
    }

    private var memory: [String: Any]? { host["mem"] as? [String: Any] }
    private var cores: [[String: Any]] { host["cpus"] as? [[String: Any]] ?? [] }

    /// The 1, 5 and 15 minute averages the robot reports, as far as it reports them.
    private var loads: [Double] {
        let load = host["load"] as? [String: Any]
        return ["1", "5", "15"].compactMap { load?[$0] as? Double }
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            List {
                robotSection
                valetudoSection
                memorySection
                processorSection
                hostSection
                runtimeSection
            }
            .textSelection(.enabled)
            .refreshable { await loadFacts() }
        }
        .settingsPage("System Information")
        .task(id: attempt) {
            // Side by side, so a slow answer here can't hold up the page itself.
            async let details: Void = loadFacts()
            await SettingsLoad.keepFresh(every: 5, phase: $phase) {
                host = try await store.client.settingsDocument("/system/host/info")
            }
            await details
        }
    }

    private var robotSection: some View {
        Section("Robot") {
            if let model = store.info?.modelName {
                LabeledContent("Model", value: [store.info?.manufacturer, model].compactMap { $0 }.joined(separator: " "))
            }
            if let implementation = facts.implementation { LabeledContent("Implementation", value: implementation) }
            if let firmware = facts.firmware { LabeledContent("Firmware Version", value: firmware) }
        }
    }

    private var valetudoSection: some View {
        Section("Valetudo") {
            // The store's copy can be from before an update.
            if let version = facts.release ?? store.version { LabeledContent("Release", value: version) }
            if let commit = facts.commit {
                LabeledContent("Commit") {
                    Text(commit).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                }
            }
            if let embedded = facts.embedded { LabeledContent("Embedded", value: embedded ? "Yes" : "No") }
            if let systemID = facts.systemID { LabeledContent("System ID", value: systemID) }
            LabeledContent("Address", value: store.client.baseURL)
        }
    }

    @ViewBuilder private var memorySection: some View {
        if let total = memory?["total"] as? Double, let free = memory?["free"] as? Double, total > 0 {
            Section("Memory") {
                MemoryRow(total: total, free: free, valetudo: memory?["valetudo_current"] as? Double)
                if let peak = memory?["valetudo_max"] as? Double {
                    LabeledContent("Most Used by Valetudo", value: MemoryRow.megabytes(peak))
                }
            }
        }
    }

    @ViewBuilder private var processorSection: some View {
        if !cores.isEmpty {
            Section {
                ForEach(cores.indices, id: \.self) { index in
                    CoreRow(number: index + 1, usage: cores[index]["usage"] as? [String: Any] ?? [:])
                }
            } header: {
                Text("Processor")
            } footer: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { coreLegend }
                    VStack(alignment: .leading, spacing: 4) { coreLegend }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var coreLegend: some View {
        ForEach(CoreRow.parts, id: \.key) { LegendItem(title: $0.title, color: $0.color) }
    }

    private var hostSection: some View {
        Section {
            LabeledContent("Name", value: host["hostname"] as? String ?? "Unknown")
            LabeledContent("Architecture", value: host["arch"] as? String ?? "Unknown")
            LabeledContent("Running For", value: Self.duration(host["uptime"] as? Double))
            if !loads.isEmpty {
                LabeledContent("Processor Load", value: loads.map { String(format: "%.2f", $0) }.joined(separator: ", "))
            }
        } header: {
            Text("Host")
        } footer: {
            if loads.count > 1 { Text("Processor load is the average over the last 1, 5 and 15 minutes.") }
        }
    }

    @ViewBuilder private var runtimeSection: some View {
        if let runtime {
            Section("Runtime") {
                LabeledContent("Valetudo Running For", value: Self.duration(runtime["uptime"] as? Double))
                numberRow("User ID", runtime["uid"])
                numberRow("Group ID", runtime["gid"])
                numberRow("Process ID", runtime["pid"])
                phoenixRows(runtime["phoenix"] as? [String: Any] ?? [:])
                if let arguments = runtime["argv"] as? [String] {
                    LabeledContent("Started With", value: arguments.joined(separator: " "))
                }
                NavigationLink("Node") { NodeInfoView(runtime: runtime) }
                NavigationLink("Environment") { EnvironmentView(runtime: runtime) }
            }
        } else if runtimeChecked {
            Section("Runtime") {
                Text("The robot didn't send this. Pull down to try again.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
        }
    }

    @ViewBuilder private func phoenixRows(_ phoenix: [String: Any]) -> some View {
        if let canRestart = phoenix["canReincarnate"] as? Bool {
            LabeledContent("Can Restart Itself", value: canRestart ? "Yes" : "No")
        }
        numberRow("Restarts", phoenix["generation"])
    }

    @ViewBuilder private func numberRow(_ title: String, _ value: Any?) -> some View {
        if let number = value as? NSNumber { LabeledContent(title, value: number.stringValue) }
    }

    private func loadFacts() async {
        let client = store.client
        async let robot = try? client.getJSON("/robot")
        async let properties = try? client.getJSON("/robot/properties")
        async let version = try? client.getJSON("/valetudo/version")
        async let valetudo = try? client.getJSON("/valetudo")
        async let system = try? client.getJSON("/system/runtime/info")
        let answers = await (robot, properties, version, valetudo, system)
        guard !Task.isCancelled else { return }
        facts = RobotFacts(implementation: answers.0?["implementation"] as? String,
                           firmware: answers.1?["firmwareVersion"] as? String,
                           release: answers.2?["release"] as? String,
                           commit: answers.2?["commit"] as? String,
                           embedded: answers.3?["embedded"] as? Bool,
                           systemID: answers.3?["systemId"] as? String)
        runtime = answers.4
        runtimeChecked = true
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

private struct NodeInfoView: View {
    let runtime: [String: Any]

    private var versions: [String: String] { runtime["versions"] as? [String: String] ?? [:] }

    var body: some View {
        List {
            Section {
                LabeledContent("Path", value: runtime["execPath"] as? String ?? "Unknown")
                if let arguments = runtime["execArgv"] as? [String], !arguments.isEmpty {
                    LabeledContent("Started With", value: arguments.joined(separator: " "))
                }
            }
            Section("Versions") {
                ForEach(versions.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: versions[name] ?? "")
                }
            }
        }
        .textSelection(.enabled)
        .settingsPage("Node")
    }
}

private struct EnvironmentView: View {
    let runtime: [String: Any]

    private var values: [String: String] { runtime["env"] as? [String: String] ?? [:] }

    var body: some View {
        Group {
            if values.isEmpty {
                ContentUnavailableView("No Environment Values", systemImage: "list.bullet",
                                       description: Text("The robot didn't send any."))
            } else {
                List(values.keys.sorted(), id: \.self) { name in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Text(values[name] ?? "")
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.slate)
                    }
                    .accessibilityElement(children: .combine)
                }
                .textSelection(.enabled)
            }
        }
        .settingsPage("Environment")
    }
}

// MARK: - Log

private enum LogLevel: Sendable {
    case error, warning, info, quiet

    /// Valetudo writes `[2026-01-31T12:00:00.000Z] [INFO] message`. Only that exact start
    /// counts, so a stack trace that happens to contain a level stays with its entry.
    init?(line: String) {
        guard line.hasPrefix("["), line.dropFirst(25).hasPrefix("] ["),
              let end = line.dropFirst(28).firstIndex(of: "]") else { return nil }
        switch line.dropFirst(28)[..<end] {
        case "ERROR": self = .error
        case "WARN": self = .warning
        case "INFO": self = .info
        case "DEBUG", "TRACE": self = .quiet
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .error: return Tone.critical.color
        case .warning: return Tone.warning.color
        case .info: return Theme.ink
        case .quiet: return Theme.slate
        }
    }
}

private struct LogEntry: Identifiable, Sendable {
    let id: Int
    var text: String
    let level: LogLevel
}

/// The log as entries, kept apart from the view so a large one can be read off the main thread.
private struct LogBook: Sendable {
    private(set) var entries: [LogEntry] = []

    init(text: String = "") {
        for line in text.split(separator: "\n") { append(String(line)) }
    }

    /// A line with no level, such as a stack trace, belongs to the entry above it.
    mutating func append(_ line: String) {
        if let level = LogLevel(line: line) {
            entries.append(LogEntry(id: entries.count, text: line, level: level))
        } else if !entries.isEmpty {
            entries[entries.count - 1].text += "\n" + line
        }
    }
}

struct LogView: View {
    private static let bottom = "bottom"
    /// A full log runs to tens of thousands of entries. All of them can be filtered and
    /// shared, but only this many are laid out at a time.
    private static let pageSize = 1000

    @Environment(RobotStore.self) private var store
    @State private var text = ""
    @State private var book = LogBook()
    @State private var revision = 0
    @State private var following = true
    @State private var filter = ""
    @State private var shownLimit = pageSize
    @State private var level = ""
    @State private var levels: [String] = []
    @State private var phase = SettingsLoad.loading
    @State private var attempt = 0

    private var matches: [LogEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return book.entries }
        return book.entries.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }
    }

    var body: some View {
        SettingsLoader(phase: phase, retry: retry) {
            let matches = matches
            if book.entries.isEmpty {
                ContentUnavailableView("No Log Entries", systemImage: "doc.text",
                                       description: Text("What Valetudo records shows up here."))
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                logLines(matches)
            }
        }
        .background(Theme.mist)
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter")
        .toolbar {
            if !levels.isEmpty {
                ToolbarItem(placement: .primaryAction) { levelMenu }
            }
            if !text.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text, subject: Text("Valetudo Log")) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: attempt) {
            await SettingsLoad.keepFresh(every: 5, phase: $phase) {
                try await loadWholeLog()
                phase = .ready
                try? await followNewLines()
            }
        }
    }

    private func logLines(_ matches: [LogEntry]) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if matches.count > shownLimit {
                        Button("Show Earlier Entries") { shownLimit += Self.pageSize }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: Metric.hitTarget)
                    }
                    ForEach(matches.suffix(shownLimit)) { entry in
                        Text(entry.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.level.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Only keep up with new lines while the end is on screen, so reading
                    // further up isn't interrupted.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottom)
                        .onAppear { following = true }
                        .onDisappear { following = false }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: revision) {
                if following { reader.scrollTo(Self.bottom, anchor: .bottom) }
            }
        }
    }

    /// This changes what the robot writes down, which is why it isn't with the filter.
    private var levelMenu: some View {
        Menu {
            Picker("Log Level", selection: Binding(get: { level }, set: setLevel)) {
                ForEach(levels, id: \.self) { Text(PresetKind.label($0)).tag($0) }
            }
        } label: {
            Label("Log Level", systemImage: "slider.horizontal.3")
        }
        .accessibilityValue(PresetKind.label(level))
    }

    private func loadWholeLog() async throws {
        let latest = try await store.client.getText("/valetudo/log/content")
        if levels.isEmpty, let body = try? await store.client.getJSON("/valetudo/log/level") {
            level = body["current"] as? String ?? ""
            levels = body["presets"] as? [String] ?? []
        }
        guard latest != text else { return }
        let parsed = await Task.detached(priority: .userInitiated) { LogBook(text: latest) }.value
        text = latest
        book = parsed
        revision += 1
    }

    /// Valetudo pushes each new line, so the whole file only needs reading once. This ends
    /// when the stream does, which the robot also does to the oldest of its five listeners.
    private func followNewLines() async throws {
        var request = try store.client.streamRequest("/valetudo/log/content/sse")
        // Compression can hold a line back until there's more to send.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var isLogMessage = false
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                isLogMessage = line.hasSuffix("LogMessage")
            } else if isLogMessage, line.hasPrefix("data: ") {
                add(String(line.dropFirst(6)))
            }
        }
    }

    private func add(_ line: String) {
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        book.append(line)
        revision += 1
    }

    private func setLevel(_ value: String) {
        let previous = level
        level = value
        let client = store.client
        Task {
            do {
                try await client.put("/valetudo/log/level", ["level": value])
                store.notify("Log level changed")
            } catch {
                level = previous
                store.report(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        attempt += 1
    }
}

// MARK: - About

struct AboutView: View {
    private static let website = URL(string: "https://valetudo.cloud")!
    private static let sourceCode = URL(string: "https://github.com/Hypfer/Valetudo")!
    private static let license = URL(string: "https://github.com/Hypfer/Valetudo/blob/master/LICENSE")!
    private static let appIssues = URL(string: "https://github.com/bsidio/valetudo-ios/issues")!

    @Environment(RobotStore.self) private var store

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: appVersion)
                NavigationLink("Third-Party Notices") { NoticesView() }
                SettingsLinkRow("Report a Problem With This App", "exclamationmark.bubble.fill", .orange, url: Self.appIssues)
                SettingsLinkRow("Privacy Policy", "hand.raised.fill", .blue, url: AppLinks.privacyPolicy)
            } header: {
                Text("OpenVacuum")
            } footer: {
                Text("This is an unofficial app and isn't affiliated with the Valetudo project. It talks only to your robot, with no account, cloud service or tracking.")
            }
            Section {
                SettingsLinkRow("Documentation", "book.fill", .blue, url: Self.website)
                SettingsLinkRow("Source Code", "chevron.left.forwardslash.chevron.right", .indigo, url: Self.sourceCode)
                SettingsLinkRow("License", "doc.text.fill", .brown, url: Self.license)
                if let url = URL(string: "\(store.client.baseURL)/swagger/") {
                    SettingsLinkRow("API Reference", "curlybraces", .teal, url: url)
                }
            } header: {
                Text("Valetudo")
            } footer: {
                Text("Valetudo is made by Sören Beye with help from its contributors, and builds on the work of Dennis Giese. It's licensed under Apache-2.0.")
            }
        }
        .settingsPage("About")
    }
}

private struct NoticesView: View {
    private static let mitLicense = """
    Copyright (c) 2019 Dominic Szablewski

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    private static let valetudoLicense = Bundle.main.url(forResource: "Valetudo-License", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        List {
            Section {
                Text(Self.mitLicense)
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
            } header: {
                Text(verbatim: "pl_mpeg")
            }
            Section {
                Text("Achievement names and descriptions come from Valetudo, Copyright 2018 Sören Beye, under the Apache License 2.0.")
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
                NavigationLink("Apache License 2.0") {
                    ScrollView {
                        Text(Self.valetudoLicense)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.ink)
                            .padding(Metric.gutter)
                    }
                    .background(Theme.mist)
                    .navigationTitle("Apache License 2.0")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } header: {
                Text(verbatim: "Valetudo")
            }
        }
        .settingsPage("Third-Party Notices")
    }
}
