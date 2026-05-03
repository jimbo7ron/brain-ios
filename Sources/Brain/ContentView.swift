// ContentView.swift
// brain-ios
//
// Root view. Auth-state-driven routing: present `LoginView` when the
// session is signed out, otherwise show `SignedInPlaceholderView`
// (replaced by the real Today view in M34). The single source of
// truth is `AuthSession`, owned by `BrainApp` and injected via
// `\.environment(AuthSession.self)`. ContentView observes the
// session and re-renders when transitions fire — login flips the
// session via `didSignIn(...)`, sign-out via `signedOut()`, and a
// future M33 401-handler does the same. Keeping auth state out of
// this view's `@State` means non-view callers can flip the UI
// without owning a binding to it.

import SwiftUI

struct ContentView: View {

    @Environment(\.brainAPIClient) private var apiClient
    @Environment(AuthSession.self) private var authSession

    @State private var showingSettings: Bool = false

    var body: some View {
        Group {
            switch authSession.state {
            case .signedOut:
                NavigationStack {
                    LoginView()
                        .toolbar { settingsToolbarItem }
                        .sheet(isPresented: $showingSettings) {
                            SettingsView()
                        }
                }
            case .signedIn:
                SignedInPlaceholderView {
                    Task { @MainActor in await signOut() }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: BrainSymbols.settings)
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Auth state

    /// Sign-out flow: best-effort revoke the device key server-side,
    /// then wipe Keychain, clear the in-memory API key on the
    /// shared `BrainAPIClient`, and flip the session to
    /// `.signedOut`. The revoke is best-effort because we always
    /// want logout to succeed locally — if the device is offline or
    /// the key was already revoked, the user is still effectively
    /// signed out.
    ///
    /// Order matters: revoke (network) → wipe Keychain → clear API
    /// client → flip session. The session flip lands last so any
    /// view that re-renders on `.signedOut` (e.g. LoginView) reads a
    /// consistent post-wipe state.
    @MainActor
    private func signOut() async {
        // Capture the id before wiping Keychain, otherwise we'd revoke
        // nothing.
        let keyId = (try? KeychainStore.load(.apiKeyId)) ?? nil

        if let keyId, let apiClient {
            try? await apiClient.revokeApiKey(id: keyId)
        }

        // Local wipe always runs, even if the revoke threw.
        try? KeychainStore.wipe()
        await apiClient?.setApiKey(nil)
        authSession.signedOut()
    }
}

#Preview {
    ContentView()
        .environment(AuthSession(state: .signedOut))
}
