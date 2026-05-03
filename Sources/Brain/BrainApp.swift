// BrainApp.swift
// brain-ios
//
// App entry point. Wires up the SwiftData ModelContainer and presents
// ContentView. Login and sync land in M32/M33; this file just sets up
// the container so subsequent milestones have somewhere to write.

import SwiftData
import SwiftUI

@main
struct BrainApp: App {

    /// Single shared ModelContainer for the app. SwiftData expects one
    /// container per app process; views grab a `ModelContext` from the
    /// environment.
    let modelContainer: ModelContainer

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
