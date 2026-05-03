// BrainApp.swift
// brain-ios
//
// App entry point. Wires up the SwiftData ModelContainer, the shared
// BrainAPIClient, and the shared AuthSession, then presents
// ContentView. Login (M32) and sync (M33) reach the API client
// through `\.brainAPIClient` in the environment so they share the
// same `apiKey` state; views read auth state via
// `@Environment(AuthSession.self)`.

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

    /// `@MainActor` because `AuthSession` is main-actor-isolated and
    /// we construct one below. SwiftUI already runs `App.init` on
    /// the main thread; this just makes the contract explicit so
    /// strict concurrency stops complaining about cross-actor
    /// initialisation.
    @MainActor
    init() {
        do {
            let schema = Schema([
                LocalUser.self,
                LocalProject.self,
                LocalSection.self,
                LocalNote.self,
                LocalAppointment.self,
                LocalSyncState.self,
                LocalMutationQueueItem.self,
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // If the store is corrupt at launch we have no graceful fallback —
            // the app is unusable without local storage. Surface a fatal error
            // so it shows up in crash logs rather than silently breaking.
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }

        // Pull the configured server URL out of Keychain (set in
        // SettingsView). `try?` collapses both "key missing" and
        // "Keychain error" to nil — in either case we fall back to the
        // built-in default. The API key is similarly optional: it's
        // absent on first launch and after sign-out.
        let storedServer = (try? KeychainStore.load(.serverURL)) ?? nil
        let serverURL = storedServer.flatMap(URL.init(string:)) ?? defaultBrainServerURL
        let storedApiKey = (try? KeychainStore.load(.apiKey)) ?? nil
        self.apiClient = BrainAPIClient(serverURL: serverURL, apiKey: storedApiKey)

        // AuthSession reads Keychain itself in its initialiser. We
        // build it here so the same instance is shared across the
        // entire scene tree via `.environment(authSession)` below.
        // Known limitation: pre-first-unlock background launches see
        // `errSecInteractionNotAllowed` from Keychain reads, which we
        // collapse to nil and treat as signed out. Becomes
        // load-bearing once M33 wires up Background App Refresh; fix
        // there is to defer the read until first unlock rather than
        // bouncing the user to LoginView.
        self.authSession = AuthSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.brainAPIClient, apiClient)
                .environment(authSession)
        }
        .modelContainer(modelContainer)
    }
}
