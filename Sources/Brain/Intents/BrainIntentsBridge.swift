// BrainIntentsBridge.swift
// brain-ios
//
// M43 — singleton bridge between App Intents and the SwiftUI app's
// shared services. App Intents (`AppIntent.perform()`) run outside
// the SwiftUI environment — the system materialises the intent
// struct, calls `perform()`, and discards it. There is no
// `\.brainAPIClient` to read from and no SwiftData `\.modelContext`
// to write through.
//
// The bridge mirrors the pattern `BrainAppDelegate` already uses for
// APNs callbacks: `BrainApp.init` stashes static refs to the live
// `BrainAPIClient`, `AuthSession`, `ModelContainer`, and
// `MutationQueue` immediately after constructing them. Intents read
// from the bridge to reach the same singletons the rest of the app
// uses, so an offline-queued mutation from a Shortcut and an
// offline-queued mutation from QuickAddView both ride the same
// `MutationQueue` instance and FIFO drain together.
//
// Concurrency: `@MainActor` because every stashed singleton is
// main-actor-isolated. App Intents `perform()` is `async throws` and
// has no inherent actor isolation — intents that need bridge state
// must hop to the main actor explicitly (or call methods through the
// bridge that already do). Marking the bridge `@MainActor` lets us
// access the static stored properties without per-call hops on
// reads.
//
// Lifetime: refs are set exactly once in `BrainApp.init` and never
// reset. The singletons outlive any intent invocation by definition
// — the system can only run an intent while the app process is alive
// (foreground or background). On a cold launch driven by a Siri /
// Shortcut intent the SwiftUI scene tree builds first; SwiftUI's
// `@main` attribute runs `BrainApp.init` before the App Intents
// runtime calls `perform()`, so by the time an intent executes the
// statics are populated.

import Foundation
import SwiftData

/// Static bridge for App Intents. Read from
/// `WhatsDueIntent.perform()` / `AddTodoIntent.perform()` to reach
/// the same `BrainAPIClient` / `AuthSession` / `MutationQueue` /
/// `ModelContainer` instances the SwiftUI scene tree uses.
///
/// Why an enum rather than a class with a singleton property: enums
/// can't be instantiated, which means no caller can accidentally
/// build a second bridge with stale refs. The static properties on
/// the type itself are the bridge.
@MainActor
enum BrainIntentsBridge {

    /// Set by `BrainApp.init`. Same instance the SwiftUI environment
    /// holds via `\.brainAPIClient`. Nil until the first launch's
    /// init has populated it — intents that fire before that (cold
    /// launch racing the App Intents runtime, never observed in
    /// practice) bail out gracefully rather than crashing.
    static var apiClient: BrainAPIClient?

    /// Set by `BrainApp.init`. Used by intents to gate on signed-in
    /// state — a Siri command that fires while the user is signed
    /// out should respond with a friendly "you need to sign in"
    /// dialog rather than a 401 from the server.
    static var authSession: AuthSession?

    /// Set by `BrainApp.init`. Same instance SwiftUI views write to
    /// via `\.mutationQueue`. App Intents that create / update rows
    /// enqueue here so the existing replay machinery handles
    /// retries / idempotency / 401 handoff exactly the same way it
    /// handles in-app mutations.
    static var mutationQueue: MutationQueue?

    /// Set by `BrainApp.init`. Held so intents that need to read
    /// (rather than write) — e.g. `WhatsDueIntent` summarising
    /// overdue + due-today counts — can build a fresh `ModelContext`
    /// against the canonical store rather than racing the SwiftUI
    /// view tree's context.
    static var modelContainer: ModelContainer?
}
