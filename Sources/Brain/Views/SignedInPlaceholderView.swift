// SignedInPlaceholderView.swift
// brain-ios
//
// M32 placeholder for the signed-in experience. Shows the signed-in
// user's email plus a "Sign out" button so we can exercise the full
// login → revoke → wipe loop end-to-end. The real Today view lands in
// M34 once the M33 sync engine is feeding SwiftData.

import SwiftUI

struct SignedInPlaceholderView: View {

    /// Parent (ContentView) injects the sign-out flow because it owns
    /// the auth-state binding and needs to flip its `apiKey` back to
    /// `nil` once we're done.
    let onSignOut: () -> Void

    /// Cached at first appear so the view doesn't re-touch the Keychain
    /// every render.
    @State private var email: String?
    @State private var isSigningOut: Bool = false
    @State private var showingSettings: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: BrainSymbols.appGlyph)
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(BrainColors.violet.color)
                    .accessibilityHidden(true)

                Text("Signed in")
                    .font(.title2.bold())

                if let email {
                    Text(email)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Today view lands in M34. M33 wires up the sync engine that feeds it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                Button(role: .destructive) {
                    isSigningOut = true
                    onSignOut()
                } label: {
                    Label("Sign out", systemImage: BrainSymbols.signOut)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(isSigningOut)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle("brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: BrainSymbols.settings)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                // Prefer the live Keychain value over a captured one so
                // we pick up post-login writes without an extra plumbing
                // hop. `try?` collapses Keychain misses to nil — the
                // user just won't see their email if the read fails,
                // which is preferable to crashing.
                email = (try? KeychainStore.load(.userEmail)) ?? nil
            }
        }
    }
}

#Preview {
    SignedInPlaceholderView(onSignOut: {})
}
