// SignedInRootView.swift
// brain-ios
//
// Tabbed root for the signed-in user. Replaces the M32/M33
// `SignedInPlaceholderView` once we have a real Today surface to
// land on. Four tabs (M43 added Search):
//
//   * Today — the M34 surface, mirroring the web `/` page.
//   * Projects — the M35 surface. `ProjectListView` is a
//     `NavigationSplitView` (sidebar on iPad, push-stack on iPhone).
//   * Search — M43 in-app search across notes / todos via
//     `GET /api/v1/notes?q=`. Debounced 300 ms, with recent-search
//     history persisted in UserDefaults.
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
    @Environment(\.mutationQueue) private var mutationQueue
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .today

    enum Tab: Hashable {
        case today
        case projects
        case search
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: BrainSymbols.dueToday) }
                .tag(Tab.today)

            ProjectListView()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(Tab.projects)

            // M43: in-app search across notes / todos. Hits
            // `GET /api/v1/notes?q=` with a 300 ms debounce; recent
            // searches persist in UserDefaults.
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

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
            // de-dupes overlapping calls. After the read pass returns,
            // drain any mutations the user enqueued offline (M37). The
            // queue's own `isReplaying` guard de-dupes overlapping
            // replays, so it's safe even if a replay is already in
            // flight from a `enqueue`'s fire-and-forget Task.
            await syncEngine?.sync()
            await mutationQueue?.replay()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Resume sync on foreground re-entry. The same debounce
            // covers the rapid .task → scenePhase sequence on cold
            // launch. Mutation queue replay rides on the same trigger
            // — backgrounded mutations (alarms, push, etc.) become
            // possible in M41, but for now scenePhase is the right
            // moment to nudge the queue.
            if newPhase == .active {
                Task {
                    await syncEngine?.sync()
                    await mutationQueue?.replay()
                }
            }
        }
    }
}

#Preview {
    SignedInRootView()
        .environment(AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com")))
}
