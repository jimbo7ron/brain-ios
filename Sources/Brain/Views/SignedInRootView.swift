// SignedInRootView.swift
// brain-ios
//
// Tabbed root for the signed-in user. Replaces the M32/M33
// `SignedInPlaceholderView` once we have a real Today surface to
// land on. Three tabs:
//
//   * Today — the M34 surface, mirroring the web `/` page.
//   * Projects — placeholder until M35 wires up the real project
//     picker. Shipping the tab now keeps the chrome stable so M35 is
//     a content-only swap.
//   * Settings — hosts the server URL editor and the sign-out
//     button. In M32 those lived in a sheet behind a toolbar gear;
//     promoting Settings to a tab here means the user always has a
//     way to reach sign-out without depending on view-specific
//     toolbars (the Today / Projects views may not surface one).
//
// Lifecycle: this view owns the initial sync trigger and the
// foreground-resume re-sync. The 5-minute Timer + 401 handoff still
// live inside `SyncEngine` so they survive view churn. We
// deliberately don't hop the trigger out to `BrainApp` because
// `.task` already gives us "fire-once-per-mount" semantics tied to
// the auth-gated branch — `ContentView` only renders this view when
// the session is signed in, so the sync naturally pauses on
// sign-out.

import SwiftUI

@MainActor
struct SignedInRootView: View {

    @Environment(\.syncEngine) private var syncEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .today

    enum Tab: Hashable {
        case today
        case projects
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: BrainSymbols.dueToday) }
                .tag(Tab.today)

            ProjectsPlaceholderView()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(Tab.projects)

            // Settings hosted as a tab — pass `showsDismissButton:
            // false` so it doesn't render a "Done" button (there's no
            // sheet to dismiss when it's a tab).
            SettingsView(showsDismissButton: false)
                .tabItem { Label("Settings", systemImage: BrainSymbols.settings) }
                .tag(Tab.settings)
        }
        .task {
            // First sync of the signed-in session. Safe to call
            // unconditionally — `SyncEngine.sync()` debounces against
            // the .task + scenePhase + Timer triple-trigger and
            // de-dupes overlapping calls.
            await syncEngine?.sync()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Resume sync on foreground re-entry. The same debounce
            // covers the rapid .task → scenePhase sequence on cold
            // launch.
            if newPhase == .active {
                Task { await syncEngine?.sync() }
            }
        }
    }
}

/// M35 placeholder. Kept here (rather than as a free-standing file)
/// so M35 can replace the contents in one focused diff without
/// having to also rewire `SignedInRootView`.
@MainActor
struct ProjectsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Projects", systemImage: "folder")
            } description: {
                Text("Project navigation lands in M35.")
            }
            .navigationTitle("Projects")
        }
    }
}

#Preview {
    SignedInRootView()
        .environment(AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com")))
}
