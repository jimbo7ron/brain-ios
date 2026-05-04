// BrainApp.swift
// brain-ios
//
// App entry point. Wires up the SwiftData ModelContainer, the shared
// BrainAPIClient, the shared AuthSession, the SyncEngine (M33), the
// MutationQueue (M37), and the NotificationManager (M41), then
// presents ContentView. Login (M32) and sync (M33) reach the
// API client through `\.brainAPIClient` in the environment so they
// share the same `apiKey` state; views read auth state via
// `@Environment(AuthSession.self)`, the sync engine via
// `\.syncEngine`, the mutation queue via `\.mutationQueue`, and the
// notification manager via `\.notificationManager`.
//
// M41 also registers a `BrainAppDelegate` via `@UIApplicationDelegateAdaptor`
// so the UIKit-only APNs callbacks (token registration + silent-push
// wake) have a place to land. `init` stashes static refs to the
// NotificationManager / SyncEngine / MutationQueue on the AppDelegate
// because UIKit invokes its methods outside the SwiftUI environment.

import SwiftData
import SwiftUI

@main
struct BrainApp: App {

    /// SwiftUI's bridge to the legacy UIKit AppDelegate world. We need
    /// it for M41: the three APNs callbacks
    /// (`didRegisterForRemoteNotificationsWithDeviceToken`,
    /// `didFailToRegisterForRemoteNotificationsWithError`, and
    /// `didReceiveRemoteNotification:fetchCompletionHandler:`) live on
    /// `UIApplicationDelegate` and SwiftUI has no native equivalent.
    /// `BrainAppDelegate` forwards the token / failure / silent-push
    /// payloads to the NotificationManager and the SyncEngine via
    /// static refs set in `init` below.
    @UIApplicationDelegateAdaptor(BrainAppDelegate.self) private var appDelegate

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

    /// Single shared notification manager (M41). Owns the APNs
    /// permission + registration flow and the `POST /api/v1/devices`
    /// round-trip. Held as `@State` (matches `mutationQueue`) because
    /// `NotificationManager` is `@Observable`. Lifetime tied to the
    /// app: built once in `init`, shared via `\.notificationManager`,
    /// and stashed on `BrainAppDelegate.notificationManager` so the
    /// AppDelegate APNs callbacks can reach it without the SwiftUI
    /// environment.
    @State private var notificationManager: NotificationManager

    /// `@MainActor` because `AuthSession` and `SyncEngine` are both
    /// main-actor-isolated and we construct them here. SwiftUI
    /// already runs `App.init` on the main thread; this just makes
    /// the contract explicit so strict concurrency stops complaining
    /// about cross-actor initialisation.
    @MainActor
    init() {
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

        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // M37 introduced a schema rename (`LocalMutationQueueItem`
            // -> `MutationQueueItem`). The old type was a never-used
            // scaffold — `git grep` across every commit on origin/main
            // confirms zero `LocalMutationQueueItem(...)` constructor
            // calls ever existed — so on a typical install there are
            // no rows under the old type and the container opens
            // cleanly. But dev / TestFlight builds may have written
            // unrelated rows under the old schema version, so a
            // SwiftData migration check could still fail at launch.
            //
            // Destructive fallback: wipe the on-disk store and retry
            // once. We never had user data on the old schema (M33
            // sync only landed the read-path models), so the reset
            // costs at most a re-sync from the server. Acceptable
            // trade for not crashing the app on first launch after
            // upgrade.
            //
            // This is a one-time concession for the M37 migration
            // boundary. Once the schema has been stable across one
            // shipped release, tighten back to a hard `fatalError`.
            NSLog("BrainApp: ModelContainer init failed (\(error)). Attempting destructive fallback.")
            Self.removeOnDiskStore()
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                // Second failure means something fundamentally wrong
                // (disk full, sandbox permissions). Crash so it shows
                // up in the crash log rather than silently breaking.
                fatalError("Failed to create SwiftData ModelContainer after destructive fallback: \(error)")
            }
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

        // Wire the engine -> queue back-reference now that both
        // exist. `attach(mutationQueue:)` lets the foreground sync
        // Timer drain queued mutations and lets a 401 from sync
        // wipe the queue (cross-tenant safety). Held weakly inside
        // SyncEngine so the two engines don't retain each other.
        engine.attach(mutationQueue: queue)

        // M41: build the notification manager and stash refs on the
        // AppDelegate adapter so its APNs callbacks (which run
        // outside the SwiftUI environment) can reach the singletons.
        // `BrainAppDelegate` is constructed by SwiftUI before `init`
        // runs, but the static refs are nil until we set them here —
        // any APNs callback fired before this point would no-op
        // gracefully, and in practice the system can't deliver a
        // callback before the app has even finished launching.
        let manager = NotificationManager(
            client: apiClient,
            authSession: authSession
        )
        _notificationManager = State(initialValue: manager)
        BrainAppDelegate.notificationManager = manager
        BrainAppDelegate.syncEngine = engine
        BrainAppDelegate.mutationQueue = queue

        // M43: stash the same singletons on `BrainIntentsBridge` so
        // App Intents (`WhatsDueIntent`, `AddTodoIntent`) can reach
        // them. App Intents run outside the SwiftUI environment and
        // would otherwise have no path to `\.brainAPIClient` /
        // `\.mutationQueue` / the SwiftData container. Same pattern
        // as `BrainAppDelegate.notificationManager` above — set once
        // here, never reset, never cleared on sign-out (the bridge's
        // intents check `authSession.isSignedIn` themselves).
        BrainIntentsBridge.apiClient = apiClient
        BrainIntentsBridge.authSession = authSession
        BrainIntentsBridge.mutationQueue = queue
        BrainIntentsBridge.modelContainer = modelContainer
    }

    /// Best-effort wipe of the on-disk SwiftData store. Used by the
    /// destructive-fallback branch in `init` when `ModelContainer`
    /// fails to open — typically because of an M37 migration mismatch
    /// on a dev / TestFlight device. Removes the default
    /// `default.store` (and its `-shm` / `-wal` siblings) under
    /// `Application Support`. We don't fail the app if the removal
    /// itself fails — the retry will just re-fail and we'll
    /// `fatalError` from that path instead.
    private static func removeOnDiskStore() {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let candidates = [
            "default.store",
            "default.store-shm",
            "default.store-wal",
        ]
        for name in candidates {
            let url = appSupport.appendingPathComponent(name)
            try? fileManager.removeItem(at: url)
        }
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
                // M41: expose the notification manager so LoginView /
                // SettingsView can trigger registration and surface
                // current authorization status.
                .environment(\.notificationManager, notificationManager)
        }
        .modelContainer(modelContainer)
    }
}
