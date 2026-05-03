// ContentView.swift
// brain-ios
//
// Root view. Auth-state-driven routing: present `LoginView` when the
// session is signed out, otherwise hand off to `SignedInRootView`
// (M34) which owns the TabView shell. The single source of truth is
// `AuthSession`, owned by `BrainApp` and injected via
// `\.environment(AuthSession.self)`. ContentView observes the
// session and re-renders when transitions fire — login flips the
// session via `didSignIn(...)`, sign-out via `signedOut()`, and the
// M33 401 handler does the same. Keeping auth state out of this
// view's `@State` means non-view callers can flip the UI without
// owning a binding to it.
//
// The sign-out flow used to live here in M32. It moved to
// `SettingsView` in M34 because SettingsView is the new home of the
// "Sign out" button (the placeholder view that previously hosted it
// has been replaced by the tabbed Today shell). Settings already
// owns the server URL roundtrip and sits next to the email row, so
// co-locating revoke + wipe + flip there keeps related affordances
// in one place.

import SwiftUI

struct ContentView: View {

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
                SignedInRootView()
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
}

#Preview {
    ContentView()
        .environment(AuthSession(state: .signedOut))
}
