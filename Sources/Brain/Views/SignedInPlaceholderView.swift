// SignedInPlaceholderView.swift
// brain-ios
//
// Signed-in placeholder for the M32/M33 era. Shows the signed-in user's
// email, the live sync status (M33), and a "Sign out" button so we can
// exercise the full login → sync → revoke → wipe loop end-to-end. The
// real Today view replaces this in M34 once we're rendering SwiftData
// rows.
//
// M33 wiring:
// - Drives `SyncEngine` on first appear (`.task`) and on foreground
//   re-entry (scenePhase). The 5-minute foreground cadence Timer
//   lives inside `SyncEngine` itself so its lifetime is tied to the
//   engine (and ultimately the auth session) rather than to this
//   view, which SwiftUI is free to re-instantiate. The 15-minute
//   backgrounded cadence and APNs silent-push wake are deferred to
//   M41 when we register `BGAppRefreshTask`.
// - Surfaces `isSyncing` / `lastSyncedAt` / `lastError` so we can
//   verify the loop end-to-end from the simulator without devtools.

import SwiftData
import SwiftUI

struct SignedInPlaceholderView: View {

    @Environment(AuthSession.self) private var authSession

    /// Parent (ContentView) injects the sign-out flow because it owns
    /// the API client + Keychain wipe sequence; this view just calls
    /// it. The post-condition (auth session flipped to `.signedOut`)
    /// happens inside that closure so this view re-renders /
    /// unmounts naturally.
    let onSignOut: () -> Void

    /// Sync engine (M33). Read as an EnvironmentObject so the view
    /// re-renders when `isSyncing` / `lastSyncedAt` change.
    @EnvironmentObject private var syncEngine: SyncEngine

    /// SwiftUI feeds this with the current scene phase; we use it to
    /// trigger a foreground sync when the app comes back from inactive.
    @Environment(\.scenePhase) private var scenePhase

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

                syncStatusView

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
                // Initial sync on first appear. `.task` is awaited and
                // cancelled when the view disappears, so a slow sync
                // won't outlive a sign-out. The engine's own debounce
                // guard collapses the .task + scenePhase + foreground
                // Timer triple-trigger — calling sync() repeatedly in
                // rapid succession is safe.
                await syncEngine.sync()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Re-sync whenever the app returns to the foreground.
                // The de-dupe / debounce inside SyncEngine.sync() makes
                // this safe even if `.task` is still running on cold
                // launch.
                if newPhase == .active {
                    Task { await syncEngine.sync() }
                }
            }
            // 5-minute foreground Timer + 15-minute background fetch
            // both live inside SyncEngine.
            // TODO(M41): register BGAppRefreshTask + APNs silent push
            // for background sync (15min cadence per spec).
        }
    }

    // MARK: - Sync status

    /// One-line status pill showing current sync state. Kept compact so
    /// the placeholder doesn't grow into a real surface — that's M34's
    /// job. Renders three states: actively syncing, last error, last
    /// success time.
    @ViewBuilder
    private var syncStatusView: some View {
        if syncEngine.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let error = syncEngine.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        } else if let lastSyncedAt = syncEngine.lastSyncedAt {
            Text("Synced \(Self.relativeFormatter.localizedString(for: lastSyncedAt, relativeTo: Date()))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // Pre-first-sync placeholder. Replaced in <1s on a working
            // network; left visible if the first sync fails so the view
            // never looks "stuck" with no signal at all.
            Text("Waiting to sync…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Cached so we don't rebuild a `RelativeDateTimeFormatter` per
    /// render — they're surprisingly expensive to construct.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

// Preview helper: builds an in-memory SyncEngine so the canvas can
// render. `@MainActor` because SyncEngine.init is main-actor-isolated
// — without this the preview macro expansion sits in a non-isolated
// context and Swift 5.10 strict concurrency complains.
@MainActor
private func makeSyncEnginePreviewHost() -> some View {
    let schema = Schema([
        LocalUser.self,
        LocalProject.self,
        LocalSection.self,
        LocalNote.self,
        LocalAppointment.self,
        LocalSyncState.self,
        LocalMutationQueueItem.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    // Force-try is OK in a #Preview — preview crashes are caught by the
    // canvas, not the app.
    // swiftlint:disable:next force_try
    let container = try! ModelContainer(for: schema, configurations: [configuration])
    let client = BrainAPIClient()
    let authSession = AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com"))
    let engine = SyncEngine(
        client: client,
        modelContext: ModelContext(container),
        authSession: authSession
    )
    return SignedInPlaceholderView(onSignOut: {})
        .environmentObject(engine)
        .environment(\.brainAPIClient, client)
        .environment(\.syncEngine, engine)
        .environment(authSession)
}

#Preview {
    makeSyncEnginePreviewHost()
}
