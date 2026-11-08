import SwiftUI

// The pieces every Settings page shares. They carry a "Settings" prefix because they're
// visible across the app, where other screens keep private helpers with plainer names.

// MARK: - Loading

/// Where a page is with its data.
enum SettingsLoad: Equatable {
    case loading
    case ready
    /// The page has real values, but the last refresh failed, so they may be out of date.
    case stale
    case failed(String)

    var hasData: Bool { self == .ready || self == .stale }

    /// Refreshes a live page until it goes away. A first load that fails stops and offers a
    /// retry, unless `persist` says the page stands without this data. After that a missed
    /// refresh keeps the last good values, which also covers the robot restarting.
    @MainActor
    static func keepFresh(every seconds: @autoclosure () -> Double, phase: Binding<SettingsLoad>,
                          persist: Bool = false, _ fetch: () async throws -> Void) async {
        while !Task.isCancelled {
            do {
                try await fetch()
                phase.wrappedValue = .ready
            } catch is CancellationError {
                return
            } catch {
                if phase.wrappedValue.hasData {
                    phase.wrappedValue = .stale
                } else {
                    phase.wrappedValue = .failed(error.localizedDescription)
                    if !persist { return }
                }
            }
            try? await Task.sleep(for: .seconds(seconds()))
        }
    }
}

extension Client {
    /// `getJSON` returns an empty document for anything that isn't one, which must not
    /// count as a successful load: the page would then offer defaults for saving.
    func settingsDocument(_ path: String) async throws -> [String: Any] {
        let body = try await getJSON(path)
        guard !body.isEmpty else { throw APIError(message: "The robot didn't send this information.") }
        return body
    }

    /// Valetudo has no HTTPS of its own, so this is true for nearly every robot.
    var isUnencrypted: Bool { baseURL.lowercased().hasPrefix("http://") }
}

/// Shows a spinner or a way to retry until the page has real values to show.
struct SettingsLoader<Content: View>: View {
    let phase: SettingsLoad
    let retry: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(RobotStore.self) private var store

    var body: some View {
        switch phase {
        case .loading:
            ProgressView("Loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load This Page", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button(action: retry) {
                    Text("Try Again").foregroundStyle(Theme.onCobalt)
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready, .stale:
            // One branch for both, so losing the robot doesn't rebuild the page under the reader.
            content()
                .safeAreaInset(edge: .top, spacing: 0) {
                    if phase == .stale { staleNotice }
                }
        }
    }

    private var staleNotice: some View {
        Banner(text: store.staleAdvice)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.mist)
    }
}

// MARK: - Page helpers

extension View {
    func settingsList() -> some View {
        textCase(nil)
            .scrollDismissesKeyboard(.interactively)
            .themedList()
    }

    func settingsPage(_ title: String) -> some View {
        settingsList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// For content that brings its own surface, such as a banner or the primary button.
    func settingsBareRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsPlainInput() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    /// A way to put the keyboard away, which number pads don't have.
    func settingsKeyboardDone() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    /// Asks before going back would drop edits that haven't been saved.
    func settingsDraftGuard(isDirty: Bool) -> some View {
        modifier(SettingsDraftGuard(isDirty: isDirty))
    }
}

/// The system back button can't be intercepted, so a dirty page swaps it for its own.
/// Hiding the system one also stops the swipe back.
private struct SettingsDraftGuard: ViewModifier {
    let isDirty: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirming = true } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .confirmationDialog("Discard your changes?", isPresented: $confirming, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                        }
                    }
                }
            }
    }
}

extension Animation {
    /// How rows appear and disappear when a switch reveals them.
    static func settingsReveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }
}

// MARK: - Rows

/// A row in the style of iOS Settings: a small coloured tile, the title, and sometimes a value.
struct SettingRow: View {
    private static let largestTile: CGFloat = 44

    let title: String
    let symbol: String
    let color: Color
    var value: String?
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 29
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, _ symbol: String, _ color: Color, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
    }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: min(tile, Self.largestTile))
            Text(title)
                .foregroundStyle(Theme.ink)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if let value, !typeSize.isAccessibilitySize {
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
            }
        }
    }
}

/// A row that leaves the app, marked so that it doesn't look like another page.
struct SettingsLinkRow: View {
    let title: String
    let symbol: String
    let color: Color
    let url: URL

    init(_ title: String, _ symbol: String, _ color: Color, url: URL) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            HStack {
                SettingRow(title, symbol, color)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.faint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint("Opens in your browser")
    }
}

/// A label and an input on one line, stacked at accessibility text sizes so neither clips.
struct SettingsField<Caption: View, Field: View>: View {
    @ViewBuilder let caption: () -> Caption
    @ViewBuilder let field: () -> Field
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                caption()
                field()
            }
        } else {
            HStack(spacing: 12) {
                caption()
                field().multilineTextAlignment(.trailing)
            }
        }
    }
}

extension SettingsField where Caption == Text {
    init(_ title: String, @ViewBuilder field: @escaping () -> Field) {
        self.init(caption: { Text(title) }, field: field)
    }
}

/// A password that can be shown, because a typo here is easy to miss and hard to recover from.
struct SettingsPasswordField: View {
    let title: String
    @Binding var text: String
    var prompt = "Required"
    var contentType: UITextContentType?
    /// Moves the cursor here each time this changes.
    var focusRequest = 0
    @State private var visible = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            input
                .textContentType(contentType)
                .focused($focused)
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.slate)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(visible ? "Hide \(title)" : "Show \(title)")
        }
        .onChange(of: focusRequest) { focused = true }
    }

    @ViewBuilder private var input: some View {
        if visible {
            TextField(title, text: $text, prompt: Text(prompt)).settingsPlainInput()
        } else {
            SecureField(title, text: $text, prompt: Text(prompt))
        }
    }
}

/// The one filled button on a page, matching the remote on the Home tab.
struct SettingsActionButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Theme.onCobalt) }
                Text(title)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.onCobalt)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.cobalt.gradient, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityValue(busy ? "Working" : "")
    }
}

/// Saves a page of edits. It lives in the toolbar so that it's in reach on long pages.
struct SettingsSaveButton: View {
    let saving: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if saving {
            ProgressView().accessibilityLabel("Saving")
        } else {
            Button("Save", action: action).disabled(!enabled)
        }
    }
}

/// A state word with a coloured dot, for values that are more than plain text.
struct SettingsStatusValue: View {
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.slate)
        }
    }
}

/// Why a page can't be saved yet, for the footer of the section it's about.
struct SettingsProblem: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: Tone.critical.symbol)
            .foregroundStyle(Tone.critical.color)
    }
}
