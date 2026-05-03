// BrainApp.swift
// brain-ios
//
// App entry point. Wires up the SwiftData ModelContainer, the shared
// BrainAPIClient, the shared AuthSession, and (M33) the SyncEngine,
// then presents ContentView. Login (M32) and sync (M33) reach the
// API client through `\.brainAPIClient` in the environment so they
// share the same `apiKey` state; views read auth state via
// `@Environment(AuthSession.self)` and the sync engine via
// `\.syncEngine`.

import SwiftData
import SwiftUI

@main
struct BrainApp: App {

    /// Single shared ModelContainer for the app. SwiftData expects one
    /// container per app process; views grab a `ModelContext` from the
    /// environment.
    let modelContainer: ModelContainer

    /// Single shared API client for the app. Built once with whatever
    /// server URL and API key are in Keychain at launch; mutated in
    /// place by `setApiKey(...)` after login (M32). Views access the
    /// same instance via `@Environment(\.brainAPIClient)`.
    let apiClient: BrainAPIClient

    /// Single shared auth-state observable. Hydrated from Keychain in
    /// its initialiser, mutated by login (`didSignIn`) and sign-out /
    /// 401 (`signedOut`). Views observe via
    /// `@Environment(AuthSession.self)`. Owning it here (instead of
    /// in ContentView's `@State`) means non-view callers — notably
    /// M33's sync engine — can flip the UI back to LoginView on a
    /// 401 without reaching into a parent view's local state.
    let authSession: AuthSession

    /// Single shared sync engine. Holds the cursor and orchestrates
    /// `GET /api/v1/sync` (M33). `@StateObject` keeps it alive across
    /// SwiftUI re-renders and lets views observe `isSyncing` etc. via
    /// `@EnvironmentObject` or `\.syncEngine`. We build it in `init`
    /// rather than lazily so the M34 `SignedInRootView`'s `.task` can
    /// trigger the first sync without an extra plumbing hop. The
    /// engine owns the foreground 5-minute Timer internally so the
    /// view layer doesn't have to manage that lifetime.
    @StateObject private var syncEngine: SyncEngine

    /// Single shared mutation queue (M37). Drains queued offline writes
    /// and threads `Idempotency-Key` on every replay so the server
    /// dedupes retries. Held as `@State` (not `@StateObject`) because
    /// `MutationQueue` is `@Observable` rather than `ObservableObject`
    /// — that's the modern Swift 5.9+ flavour and matches `AuthSession`.
    /// Same lifetime as `syncEngine`: built once in `init`, shared
    /// across the scene tree via `\.mutationQueue`.
    @State private var mutationQueue: MutationQueue

    /// `@MainActor` because `AuthSession` and `SyncEngine` are both
    /// main-actor-isolated and we construct them here. SwiftUI
    /// already runs `App.init` on the main thread; this just makes
    /// the contract explicit so strict concurrency stops complaining
    /// about cross-actor initialisation.
    @MainActor
    init() {
        let modelContainer: ModelContainer
        do {
            let schema = Schema([
                LocalUser.self,
                LocalProject.self,
                LocalSection.self,
                LocalNote.self,
                LocalAppointment.self,
                LocalSyncState.self,
                MutationQueueItem.self,
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // If the store is corrupt at launch we have no graceful fallback —
            // the app is unusable without local storage. Surface a fatal error
            // so it shows up in crash logs rather than silently breaking.
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
        self.modelContainer = modelContainer

        // Pull the configured server URL out of Keychain (set in
        // SettingsView). `try?` collapses both "key missing" and
        // "Keychain error" to nil — in either case we fall back to the
        // built-in default. The API key is similarly optional: it's
        // absent on first launch and after sign-out.
        let storedServer = (try? KeychainStore.load(.serverURL)) ?? nil
        let serverURL = storedServer.flatMap(URL.init(string:)) ?? defaultBrainServerURL
        let storedApiKey = (try? KeychainStore.load(.apiKey)) ?? nil
        let apiClient = BrainAPIClient(serverURL: serverURL, apiKey: storedApiKey)
        self.apiClient = apiClient

        // AuthSession reads Keychain itself in its initialiser. We
        // build it here so the same instance is shared across the
        // entire scene tree via `.environment(authSession)` below.
        // Known limitation: pre-first-unlock background launches see
        // `errSecInteractionNotAllowed` from Keychain reads, which we
        // collapse to nil and treat as signed out. Becomes
        // load-bearing once M41 wires up Background App Refresh; fix
        // there is to defer the read until first unlock rather than
        // bouncing the user to LoginView.
        let authSession = AuthSession()
        self.authSession = authSession

        // SyncEngine writes via its own `ModelContext`. We deliberately
        // do NOT reuse the SwiftUI-injected context — that one is owned
        // by the view hierarchy and can be torn down on scene churn. A
        // dedicated context tied to the same container shares the
        // SwiftData store while keeping the engine's lifetime aligned
        // with the app, not the view tree.
        //
        // The engine takes the AuthSession so that on a 401 it can
        // call `authSession.signedOut()` directly — flipping the UI
        // back to LoginView without reaching through ContentView state.
        let context = ModelContext(modelContainer)
        let engine = SyncEngine(
            client: apiClient,
            modelContext: context,
            authSession: authSession
        )
        _syncEngine = StateObject(wrappedValue: engine)

        // Mutation queue (M37) gets its own `ModelContext` for the same
        // reason as the sync engine: lifetime tied to the app, not the
        // view tree. Sharing the SwiftData container is what makes the
        // `MutationQueueItem` rows visible to a future debug surface
        // running from a different context (e.g. a Settings inspector).
        let queueContext = ModelContext(modelContainer)
        let queue = MutationQueue(
            modelContext: queueContext,
            client: apiClient,
            authSession: authSession
        )
        _mutationQueue = State(initialValue: queue)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.brainAPIClient, apiClient)
                .environment(authSession)
                .environment(\.syncEngine, syncEngine)
                .environmentObject(syncEngine)
                // M37: expose the mutation queue so views can `enqueue`
                // and so `SignedInRootView` can call `replay()` after a
                // successful sync / on scenePhase resume.
                .environment(\.mutationQueue, mutationQueue)
        }
        .modelContainer(modelContainer)
    }
}
