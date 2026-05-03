// ContentView.swift
// brain-ios
//
// Root view. Auth-state-driven routing: present `LoginView` when there's
// no API key in Keychain, otherwise show `SignedInPlaceholderView`
// (replaced by the real Today view in M34). The single source of truth
// is the `apiKey` @State here — `LoginView` flips it on success via
// `onSignedIn`, and sign-out from the placeholder flips it back after
// the server-side revoke + Keychain wipe.

import SwiftUI

struct ContentView: View {

    @Environment(\.brainAPIClient) private var apiClient

    /// Initial value comes from Keychain at view-construction time so
    /// the first render lands on the correct branch (no flicker through
    /// the login screen on warm launches).
    @State private var apiKey: String?
    @State private var showingSettings: Bool = false

    init() {
        let stored = (try? KeychainStore.load(.apiKey)) ?? nil
        _apiKey = State(initialValue: stored)
    }

    var body: some View {
        Group {
            if apiKey == nil {
                NavigationStack {
                    LoginView(onSignedIn: { refreshAuthState() })
                        .toolbar { settingsToolbarItem }
                        .sheet(isPresented: $showingSettings) {
                            SettingsView()
                        }
                }
            } else {
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

    /// Re-reads Keychain after `LoginView` finishes its writes. Pulling
    /// from Keychain (rather than threading the key through the
    /// callback) keeps a single source of truth: whatever's persisted
    /// is what we route on.
    private func refreshAuthState() {
        apiKey = (try? KeychainStore.load(.apiKey)) ?? nil
    }

    /// Sign-out flow: best-effort revoke the device key server-side,
    /// then wipe Keychain and clear the in-memory bearer token. The
    /// revoke is best-effort because we always want logout to succeed
    /// locally — if the device is offline or the key was already
    /// revoked, the user is still effectively signed out.
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
        apiKey = nil
    }
}

#Preview {
    ContentView()
}
