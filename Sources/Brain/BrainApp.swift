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

    /// (M45 Wave 1) Per-row mutation status — keyed by the resource's
    /// current id, populated by repositories on enqueue and cleared by
    /// the queue on success / marked failed on poison. Held as
    /// `@State` because `MutationStatusStore` is `@Observable`.
    /// Constructed first in `init` (before the queue or repos) since
    /// both depend on it.
    @State private var mutationStatusStore: MutationStatusStore

    /// (M45 Wave 1) Note write contract. Owns its own `ModelContext`
    /// (the third one) so its lifetime stays app-bound rather than
    /// view-tree-bound. All view-side note mutations (Wave 2-3 will
    /// migrate them) flow through this; the queue handles the network
    /// round-trip.
    @State private var noteRepository: NoteRepository

    /// (M45 Wave 1) Project write contract. Same shape as
    /// `noteRepository`. Section ops (`addSection` / `renameSection`)
    /// are direct-call until Wave 4 introduces an
    /// `OptimisticCompositeStub` for composite-id models.
    @State private var projectRepository: ProjectRepository

    /// "Compact density" toggle (Settings → Display). When `true`, the
    /// root content view is wrapped in `.dynamicTypeSize(.xSmall)` to
    /// shrink fonts, paddings, and list row heights by ~14-16%. SwiftUI
    /// keeps tap targets at the platform-minimum 44pt regardless, so
    /// the cap is safe from an accessibility-affordance standpoint.
    /// Defaults to `true` per the user's explicit request to start
    /// denser; flip in Settings to revert to system default sizing.
    @AppStorage("compactDensity") private var compactDensity: Bool = true

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
        // Tier 2 e2e harness: under `-uiTesting` use an in-memory store
        // so SwiftData state does not leak between test methods. The
        // `BrainTestMode.isUITesting` flag is `false` in production
        // launches, so the on-disk store path is unchanged for users.
        // Production-binary cleanup: the test-mode flag is gated behind
        // `#if DEBUG` so Release builds never reference `BrainTestMode`
        // at all — the configuration is unconditionally on-disk.
        #if DEBUG
        let storedInMemoryOnly = BrainTestMode.isUITesting
        #else
        let storedInMemoryOnly = false
        #endif
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: storedInMemoryOnly
        )

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
            // Destructive fallback (NARROWED in the polish round): we
            // only wipe the on-disk store when the failure is plausibly
            // a schema mismatch. Other failure modes (disk full,
            // sandbox permissions, file-system corruption) wiping the
            // store would be a hard data-loss event for a TestFlight
            // user with a populated database — and wouldn't even
            // recover, since the next init would fail for the same
            // reason. So those crash with `fatalError` instead, which
            // surfaces in the TestFlight crash log.
            //
            // Even on the schema-mismatch branch we BACK UP the store
            // to `<original>.backup-<timestamp>.store` (and -shm/-wal
            // siblings) by RENAMING. The user's data is quarantined,
            // not destroyed; a developer can recover it manually if
            // anyone reports loss. The next sync from the server
            // re-populates the read models; queued mutations on the
            // old schema do not survive (acceptable — see queue clear
            // semantics in `MutationQueue.handleUnauthorized`).
            //
            // If the backup move itself fails (permissions, disk
            // full, etc.) the helper LEAVES THE ORIGINAL STORE IN
            // PLACE and re-throws. We then crash with `fatalError`
            // rather than silently deleting user data. No data is
            // deleted in any failure path.
            //
            // The proper fix is a real `SchemaMigrationPlan`, tracked
            // separately. This is the conservative pre-TestFlight
            // narrowing that prevents a non-migration init failure
            // from wiping user data.
            if Self.isSchemaIncompatibilityError(error) {
                NSLog(
                    "BrainApp: ModelContainer init failed with schema-incompatibility error " +
                    "(\(error)). Backing up store and retrying with a fresh store."
                )
                let backedUpTo: URL?
                do {
                    backedUpTo = try Self.backUpOnDiskStore()
                } catch {
                    // Backup move failed — original store is preserved
                    // (the helper does NOT delete on failure). Crash
                    // with a clear message so the TestFlight crash
                    // report surfaces the underlying I/O error; the
                    // user's data is intact on disk and recoverable.
                    fatalError(
                        "ModelContainer schema-fallback backup failed; original store " +
                        "preserved on disk: \(error)"
                    )
                }
                if let backedUpTo {
                    NSLog("BrainApp: existing store quarantined to \(backedUpTo.path).")
                } else {
                    NSLog("BrainApp: no existing store to back up.")
                }
                do {
                    modelContainer = try ModelContainer(for: schema, configurations: [configuration])
                } catch {
                    // Second failure post-backup means something
                    // fundamentally wrong (disk full, sandbox
                    // permissions). Crash so it shows up in the crash
                    // log rather than silently breaking. Backed-up
                    // copy on disk preserves any user data we
                    // quarantined during the wipe.
                    fatalError("Failed to create SwiftData ModelContainer after backup + retry: \(error)")
                }
            } else {
                // Non-recoverable: not a schema-mismatch error, so
                // wiping the store wouldn't help and would destroy
                // user data. Crash and let the TestFlight crash report
                // surface the actual underlying cause.
                fatalError("ModelContainer init failed (non-recoverable, not a schema mismatch): \(error)")
            }
        }
        self.modelContainer = modelContainer

        // Pull the configured server URL out of Keychain (set in
        // SettingsView). `try?` collapses both "key missing" and
        // "Keychain error" to nil — in either case we fall back to the
        // built-in default. The API key is similarly optional: it's
        // absent on first launch and after sign-out.
        // Tier 2 e2e harness: under `-uiTesting` swap in a URLSession
        // backed by `FakeBrainURLProtocol` and a fake server URL. The
        // production `BrainAPIClient` actor is kept as-is (no protocol
        // extraction); the fake intercepts at the URLSession layer so
        // every consumer (sync engine, mutation queue, repositories,
        // intents bridge) sees the same actor type as in production.
        let serverURL: URL
        let storedApiKey: String?
        let session: URLSession
        #if DEBUG
        if BrainTestMode.isUITesting {
            // Reset the in-memory fake state at process launch so each
            // test method starts from a clean slate. XCUITest can
            // additionally seed via `-uiTestingSeed*` flags handled
            // below, mirroring the test fixtures pattern from
            // `Tests/BrainTests`.
            FakeBrainState.shared.reset()
            Self.applyUITestingSeeds()
            serverURL = BrainTestMode.testServerURL
            storedApiKey = BrainTestMode.testApiKey
            session = URLSession.brainTestModeSession()
        } else {
            let storedServer = (try? KeychainStore.load(.serverURL)) ?? nil
            serverURL = storedServer.flatMap(URL.init(string:)) ?? defaultBrainServerURL
            storedApiKey = (try? KeychainStore.load(.apiKey)) ?? nil
            session = .shared
        }
        #else
        // Production: no test-mode branch in the binary. `BrainTestMode`
        // and `FakeBrainURLProtocol` are themselves `#if DEBUG`-gated
        // so they're not even compiled into Release.
        let storedServer = (try? KeychainStore.load(.serverURL)) ?? nil
        serverURL = storedServer.flatMap(URL.init(string:)) ?? defaultBrainServerURL
        storedApiKey = (try? KeychainStore.load(.apiKey)) ?? nil
        session = .shared
        #endif
        let apiClient = BrainAPIClient(serverURL: serverURL, apiKey: storedApiKey, session: session)
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
        // Tier 2 e2e harness: under `-uiTesting` skip the LoginView
        // entirely by bootstrapping the session as `.signedIn`. The
        // synthetic credentials are placeholders — they're never sent
        // to a real server because `FakeBrainURLProtocol` intercepts.
        let authSession: AuthSession
        #if DEBUG
        if BrainTestMode.isUITesting {
            authSession = AuthSession(
                state: .signedIn(
                    userId: BrainTestMode.testUserID,
                    email: BrainTestMode.testUserEmail
                )
            )
        } else {
            authSession = AuthSession()
        }
        #else
        authSession = AuthSession()
        #endif
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

        // M45 Wave 1: per-row mutation status store + Note/Project
        // repositories. The store has no SwiftData backing — purely
        // in-memory `[String: Status]`. The repositories own the
        // *third* `ModelContext` against the same container; their
        // lifetime is the app, not the view tree (per spec §4.1).
        // Wiring order matters:
        //   1. Construct the status store (no deps).
        //   2. Hand the queue a weak reference to the store so its
        //      reconcile + replay paths can rename / clear / mark
        //      failed (per spec §4.4).
        //   3. Construct the repositories with both queue + store.
        let statusStore = MutationStatusStore()
        _mutationStatusStore = State(initialValue: statusStore)
        queue.statusStore = statusStore

        let repositoryContext = ModelContext(modelContainer)
        let noteRepo = NoteRepository(
            modelContext: repositoryContext,
            queue: queue,
            statusStore: statusStore
        )
        _noteRepository = State(initialValue: noteRepo)
        let projectRepo = ProjectRepository(
            modelContext: repositoryContext,
            queue: queue,
            statusStore: statusStore,
            client: apiClient
        )
        _projectRepository = State(initialValue: projectRepo)

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

    /// Tier 2 e2e harness: parse XCUITest seed flags from
    /// `ProcessInfo.arguments` and apply them to `FakeBrainState`.
    ///
    /// Two flag families are supported. Each consumes either one or
    /// two arguments:
    ///   * `-uiTestingSeedTodo "<title>"`                    — seed an
    ///       inbox todo due today (lands in TodayView's "Due
    ///       today" section), with a server-assigned UUID.
    ///   * `-uiTestingSeedTodoWithID "<title>" "<uuid>"`     — seed
    ///       with a deterministic id so the UI test can locate the
    ///       resulting `todo-row-<uuid>` element directly.
    ///   * `-uiTestingSeedProject "<name>"`                  — seed a
    ///       project (uses M26 default sections).
    ///   * `-uiTestingSeedProjectWithID "<name>" "<uuid>"`   — seed
    ///       with a deterministic id; UI test addresses
    ///       `project-row-<uuid>` directly.
    ///
    /// Multiple occurrences are honoured so a test can seed several
    /// records in one launch. Tests that need richer fixtures should
    /// extend `FakeBrainState` with their own seed methods rather than
    /// growing this flag set unbounded.
    ///
    /// `#if DEBUG`-gated: callers (the test-mode branch in `init`) are
    /// gated on the same flag, and `FakeBrainState` itself is too.
    #if DEBUG
    private static func applyUITestingSeeds() {
        let args = ProcessInfo.processInfo.arguments
        var index = 0
        let todayISO: String = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return f.string(from: Date())
        }()
        while index < args.count {
            let arg = args[index]
            if arg == "-uiTestingSeedTodo", index + 1 < args.count {
                let title = args[index + 1]
                _ = FakeBrainState.shared.seedTodo(content: title, dueDate: todayISO)
                index += 2
                continue
            }
            if arg == "-uiTestingSeedTodoWithID", index + 2 < args.count {
                let title = args[index + 1]
                let id = args[index + 2]
                _ = FakeBrainState.shared.seedTodo(content: title, dueDate: todayISO, forcedID: id)
                index += 3
                continue
            }
            if arg == "-uiTestingSeedProject", index + 1 < args.count {
                _ = FakeBrainState.shared.seedProject(name: args[index + 1])
                index += 2
                continue
            }
            if arg == "-uiTestingSeedProjectWithID", index + 2 < args.count {
                _ = FakeBrainState.shared.seedProject(name: args[index + 1], forcedID: args[index + 2])
                index += 3
                continue
            }
            index += 1
        }
    }
    #endif // DEBUG

    /// Heuristic: is `error` plausibly a SwiftData / Core Data schema
    /// mismatch (where wiping + retrying might recover) rather than a
    /// non-recoverable failure (disk full, sandbox permissions)?
    ///
    /// SwiftData is built on Core Data and surfaces its underlying
    /// errors through `NSCocoaErrorDomain`. The persistent-store error
    /// codes are the 134xxx range in `CoreDataErrors.h`:
    ///
    ///   * 134100 `NSPersistentStoreIncompatibleVersionHashError`
    ///     — store on disk has a different schema hash than the model.
    ///   * 134110 `NSMigrationMissingSourceModelError`
    ///     — a migration is required but no source model is registered.
    ///   * 134111 `NSMigrationMissingMappingModelError`
    ///   * 134130 `NSPersistentStoreIncompatibleSchemaError`
    ///   * 134140 `NSPersistentStoreIncompatibleVersionHashError`
    ///
    /// Apple does NOT publish a stable list of which exact codes
    /// SwiftData re-raises (the SwiftData layer can also throw its own
    /// `SwiftDataError` types that bridge to `NSError`), so we treat
    /// the entire `134000...134999` range as "schema-related, safe to
    /// wipe + retry". Non-Cocoa errors (e.g. POSIX `ENOSPC` for disk
    /// full) and non-134xxx Cocoa errors fall through to a hard crash.
    /// This is conservative on the recovery side — it won't silently
    /// wipe data on a permissions / disk error — but accepts that a
    /// genuine schema mismatch we don't recognise will also crash.
    private static func isSchemaIncompatibilityError(_ error: Swift.Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        // Cocoa persistent-store error codes are 134000-134999. Apple's
        // CoreDataErrors.h defines the named constants, but the range
        // is reserved for this family.
        return (134000...134999).contains(nsError.code)
    }

    /// Backup-then-quarantine of the on-disk SwiftData store. Used by
    /// the schema-incompatibility branch in `init` when the
    /// `ModelContainer` fails to open in a way we recognise as
    /// recoverable.
    ///
    /// Renames the default `default.store` (and its `-shm` / `-wal`
    /// siblings) to `default.backup-<unix-ts>.store{,-shm,-wal}`
    /// under `Application Support`, so the user's data is quarantined
    /// rather than destroyed. The next `ModelContainer(...)` call sees
    /// no store and creates a fresh one.
    ///
    /// Returns the URL of the primary backed-up store file (the
    /// `.store` itself, not the `-shm`/`-wal`) for logging, or `nil`
    /// if there was no store to back up.
    ///
    /// **Failure semantics:** if a `moveItem` call fails (permissions,
    /// disk full, etc.) we leave the original store untouched and
    /// re-throw. The previous version silently `removeItem`'d the
    /// original on move failure as a "best-effort cleanup", which
    /// contradicted the quarantine guarantee — a transient permissions
    /// error would have wiped a TestFlight user's data with no
    /// recovery path. The retry in `init` will likely also fail
    /// against the still-incompatible store, which surfaces as a
    /// `fatalError` and a TestFlight crash report — strictly better
    /// than silent data destruction. **No data is deleted in any
    /// failure path.**
    private static func backUpOnDiskStore() throws -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        // Use a single timestamp across all three sidecar files so the
        // backup set is recognisable as one snapshot.
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffixes = ["", "-shm", "-wal"]
        var primaryBackup: URL?
        for suffix in suffixes {
            let original = appSupport.appendingPathComponent("default.store\(suffix)")
            // Skip files that don't exist — `-shm` / `-wal` are only
            // present when SQLite has an open WAL.
            guard fileManager.fileExists(atPath: original.path) else { continue }
            let backup = appSupport.appendingPathComponent("default.backup-\(timestamp).store\(suffix)")
            do {
                try fileManager.moveItem(at: original, to: backup)
                if suffix.isEmpty {
                    primaryBackup = backup
                }
            } catch {
                // Move failed. Leave the original in place and
                // propagate — we'd rather surface a launch failure
                // than silently delete user data. The retry in `init`
                // will likely also fail against the still-incompatible
                // store, which crashes with `fatalError` and shows up
                // in the TestFlight crash log so the user can recover.
                NSLog(
                    "[BrainApp] schema-fallback backup failed; leaving original store at " +
                    "\(original.path): \(error)"
                )
                throw error
            }
        }
        return primaryBackup
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
                // M45 Wave 1: expose the new write-coordinator
                // singletons. No views consume these yet — Wave 2-4
                // will migrate `QuickAddView`, `EditTodoView`, etc.
                // off their open-coded `modelContext.insert + queue.
                // enqueue` blocks. Wiring the env keys here keeps the
                // migration's surface change to a one-line
                // `@Environment(\.noteRepository)` per view.
                .environment(\.mutationStatusStore, mutationStatusStore)
                .environment(\.noteRepository, noteRepository)
                .environment(\.projectRepository, projectRepository)
                // Apply the global "Compact density" cap. `.xSmall` is
                // ~86% of the default `.large`, hitting the user-
                // requested ~15% shrink while letting SwiftUI scale
                // associated paddings / list row heights proportionally
                // and keeping tap targets ≥44pt. Toggle in
                // Settings → Display.
                .dynamicTypeSize(compactDensity ? .xSmall : .large)
        }
        .modelContainer(modelContainer)
    }
}

#if DEBUG
/// Debug-only test surface for the destructive-fallback narrowing
/// (polish-round). Exposes the schema-incompatibility classifier so
/// `BrainDebugSchemaFallbackChecks` (in the matching checks file) can
/// exercise it without making the production helper internal. The
/// production binary strips this whole extension.
extension BrainApp {
    static func _debug_isSchemaIncompatibilityError(_ error: Swift.Error) -> Bool {
        isSchemaIncompatibilityError(error)
    }
}
#endif
