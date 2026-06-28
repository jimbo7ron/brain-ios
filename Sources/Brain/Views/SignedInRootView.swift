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

    /// Drives the failed-changes sheet presented when the user taps the
    /// red "⚠ M" indicator on the status pill.
    @State private var showFailures = false

    /// Top offset added to `safeAreaInsets.top` when positioning the
    /// floating mutation-status pill. Clears both compact (`44pt`) and
    /// large-title (`96pt`) nav bars; see the rationale comment on the
    /// overlay below.
    private static let pillTopOffset: CGFloat = 52

    enum Tab: Hashable {
        case today
        case projects
        case search
        case settings
    }

    var body: some View {
        rootContent
            // M45 Wave 4: queue-level status pill (spec §4.4). Floats
            // top-right above the per-tab nav bars so it's visible from
            // every surface without having to inject into each
            // `NavigationStack`'s toolbar. Hides itself when the queue
            // is idle (no chrome unless there's something to surface).
            //
            // **Padding (M45 Wave 4 review fix).** Earlier the top
            // padding was a fixed `8pt` with a comment claiming "~52pt
            // accounts for the standard nav-bar." That's wrong on
            // iPhone with a large-title nav bar (~96pt total — the
            // pill collided with the title). The overlay sits ABOVE
            // the TabView's per-tab `NavigationStack`s, so its
            // `safeAreaInsets.top` is just the status bar, not the
            // nav bar. We use a `GeometryReader` scoped to the overlay
            // (NOT the whole root — that would force a layout pass on
            // the entire view tree on every rotation / size change)
            // to read the status-bar inset and add a generous offset
            // that clears both compact (`44pt`) and large (`96pt`)
            // nav bars without clipping. Picking the larger value
            // is fine: on a compact nav bar the pill sits below the
            // bar (slightly inside the content area), still readable;
            // on a large nav bar it sits in the air to the right of
            // the title where the rationale wanted it.
            .overlay(alignment: .topTrailing) {
                GeometryReader { proxy in
                    MutationStatusPill(
                        queue: mutationQueue,
                        onTapFailed: { showFailures = true }
                    )
                    .padding(.trailing, 12)
                    .padding(.top, proxy.safeAreaInsets.top + Self.pillTopOffset)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                // Only intercept touches when there's a failed indicator
                // to tap. With no failures the pill is purely
                // informational (the pending spinner), so the overlay
                // must let touches fall through to the content below.
                // Even when enabled, only the small failed Button
                // captures — the GeometryReader's empty area and the
                // pill's expanded frame draw nothing hit-testable, so
                // the rest of the screen (incl. per-tab nav bars) stays
                // reachable.
                .allowsHitTesting((mutationQueue?.failedCount ?? 0) > 0)
            }
            .sheet(isPresented: $showFailures) {
                if let mutationQueue {
                    MutationFailuresView(queue: mutationQueue)
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
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
