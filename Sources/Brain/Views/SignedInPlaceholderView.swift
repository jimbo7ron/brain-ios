// SignedInPlaceholderView.swift
// brain-ios
//
// M32 placeholder for the signed-in experience. Shows the signed-in
// user's email plus a "Sign out" button so we can exercise the full
// login → revoke → wipe loop end-to-end. The real Today view lands in
// M34 once the M33 sync engine is feeding SwiftData.

import SwiftUI

struct SignedInPlaceholderView: View {

    @Environment(AuthSession.self) private var authSession

    /// Parent (ContentView) injects the sign-out flow because it owns
    /// the API client + Keychain wipe sequence; this view just calls
    /// it. The post-condition (auth session flipped to `.signedOut`)
    /// happens inside that closure so this view re-renders /
    /// unmounts naturally.
    let onSignOut: () -> Void

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

                if let email = authSession.email {
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
        }
    }
}

#Preview {
    SignedInPlaceholderView(onSignOut: {})
        .environment(AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com")))
}
