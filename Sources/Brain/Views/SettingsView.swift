// SettingsView.swift
// brain-ios
//
// Settings screen. Users can view / edit the server URL (default
// https://api.mindkeeper.io) and sign out. The server URL is
// persisted in Keychain alongside the API key so it survives app
// reinstalls and lives next to the credential it pairs with.
//
// In M34 this view also hosts the signed-in user's email and the
// "Sign out" button — the M32 placeholder view that previously owned
// sign-out has been replaced by the Today view, so the action moves
// here. Sign-out still drives the full revoke + Keychain wipe +
// `AuthSession.signedOut()` flow; we just relocated the surface.
// Settings is a sheet during sign-in (toolbar gear) and a tab once
// signed in (`SignedInRootView`), so this single screen serves both
// presentations without redesign — that's M43's job.

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.brainAPIClient) private var apiClient
    @Environment(AuthSession.self) private var authSession

    @State private var serverURL: String = ""
    @State private var savedServerURL: String = ""
    @State private var statusMessage: String?
    @State private var isSigningOut: Bool = false

    /// Hide the "Done" toolbar button when this view is presented as a
    /// tab (no sheet to dismiss). The presence of an injected
    /// `dismiss` action isn't enough on its own — SwiftUI always
    /// provides one — so callers presenting as a tab pass `false` to
    /// suppress the button.
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = true) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            Form {
                if let email = authSession.email {
                    Section {
                        LabeledContent("Signed in as", value: email)
                    }
                }

                Section {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Defaults to https://api.mindkeeper.io. Override to point at " +
                         "a local `brain serve` instance for development.")
                        .font(.caption)
                }

                Section {
                    Button {
                        saveServerURL()
                    } label: {
                        Text("Save server URL")
                    }
                    .disabled(serverURL == savedServerURL || serverURL.isEmpty)
                }

                if let status = statusMessage {
                    Section {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if authSession.isSignedIn {
                    Section {
                        Button(role: .destructive) {
                            isSigningOut = true
                            Task { @MainActor in
                                await signOut()
                                isSigningOut = false
                            }
                        } label: {
                            Label("Sign out", systemImage: BrainSymbols.signOut)
                        }
                        .disabled(isSigningOut)
                    }
                }

                Section {
                    LabeledContent("Bundle id", value: "io.mindkeeper.brain")
                    LabeledContent("Roadmap milestone", value: "M34")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                loadServerURL()
            }
        }
    }

    // MARK: - Actions

    private func loadServerURL() {
        let stored = (try? KeychainStore.load(.serverURL)) ?? nil
        let initial = stored ?? defaultBrainServerURL.absoluteString
        serverURL = initial
        savedServerURL = initial
    }

    private func saveServerURL() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else {
            statusMessage = "That doesn't look like a valid URL."
            return
        }
        do {
            try KeychainStore.save(trimmed, for: .serverURL)
            savedServerURL = trimmed
            statusMessage = "Server URL saved."
        } catch {
            statusMessage = "Couldn't save: \(error)"
        }
    }

    /// Sign-out flow lifted from the M32 ContentView. Order matters:
    /// best-effort revoke (network) → wipe Keychain → clear API
    /// client → flip session. The session flip lands last so any
    /// view that re-renders on `.signedOut` (e.g. LoginView) reads a
    /// consistent post-wipe state.
    @MainActor
    private func signOut() async {
        let keyId = (try? KeychainStore.load(.apiKeyId)) ?? nil
        if let keyId, let apiClient {
            try? await apiClient.revokeApiKey(id: keyId)
        }
        try? KeychainStore.wipe()
        await apiClient?.setApiKey(nil)
        authSession.signedOut()
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com")))
}
