import SwiftUI

/// For a login changed somewhere else, such as on the robot's web page. This phone's saved
/// one has stopped working, and retyping it here beats disconnecting and starting again.
struct SignInSheet: View {
    private enum Field { case username, password }

    @Environment(Session.self) private var session
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var username = Connection.load()?.username ?? ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .listRowBackground(Theme.paper)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                        .listRowBackground(Theme.paper)
                } footer: {
                    Text(problem ?? "The login saved on this phone no longer works.")
                        .foregroundStyle(problem == nil ? Theme.slate : Theme.rose)
                }
            }
            .themedList()
            .disabled(signingIn)
            .navigationTitle("Robot Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if signingIn {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn).disabled(username.isEmpty || password.isEmpty)
                    }
                }
            }
            .onAppear { focus = username.isEmpty ? .username : .password }
        }
        .presentationDetents([.medium])
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty, !signingIn else { return }
        signingIn = true
        problem = nil
        Task {
            defer { signingIn = false }
            do {
                try await session.connect(address: store.client.baseURL, username: username, password: password)
                dismiss()
            } catch let error as APIError where error.kind == .needsLogin {
                problem = "That username or password isn't right."
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
