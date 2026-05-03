// BrainApp.swift
// brain-ios
//
// App entry point. Wires up the SwiftData ModelContainer and the shared
// BrainAPIClient, then presents ContentView. Login (M32) and sync (M33)
// reach the API client through `\.brainAPIClient` in the environment so
// they share the same `apiKey` state.

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.brainAPIClient, apiClient)
        }
        .modelContainer(modelContainer)
    }
}
