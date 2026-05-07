// BrainTestMode.swift
// brain-ios
//
// Tier 2 e2e harness flag. When the app is launched with `-uiTesting`
// in its `ProcessInfo.arguments` (XCUITest sets this via
// `XCUIApplication.launchArguments`), the production wiring is replaced
// with hermetic test-mode wiring:
//
//   * `URLSession` swaps in `FakeBrainURLProtocol` so every HTTP call
//     against `BrainAPIClient` is answered by an in-memory fake server
//     that mirrors the brain server's data model. No real network.
//   * `ModelContainer` is in-memory (`isStoredInMemoryOnly: true`) so
//     SwiftData state does not leak between test runs.
//   * `AuthSession` is bootstrapped to `.signedIn` with a synthetic
//     test user, bypassing the LoginView entirely.
//   * The SyncEngine's 5-minute foreground Timer is suppressed so
//     test-driven `sync()` calls are the only ones that fire — all
//     timing is deterministic.
//   * APNs registration is skipped (NotificationManager is wired but
//     never asks for push permission).
//
// The flag is read once at process launch and cached in a static.
// Production builds default to `isUITesting == false`; the wiring in
// `BrainApp.init` short-circuits cleanly when the flag is unset, so
// shipping this file in the production target has no runtime cost.

import Foundation

/// Entry-point checks that switch the app into hermetic test mode.
/// Routed through a single namespace so the call sites in `BrainApp`
/// stay greppable.
enum BrainTestMode {

    /// `true` when the host process was launched with `-uiTesting`.
    /// Cached on first read — `ProcessInfo.arguments` is stable for
    /// the life of the process so the cache is safe.
    static let isUITesting: Bool = {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }()

    /// Synthetic user id assigned to the in-memory `AuthSession` when
    /// `isUITesting` is true. Stable across launches so XCUITest can
    /// rely on it if it ever needs to reconcile against a fixture.
    static let testUserID: String = "00000000-0000-0000-0000-00000000beef"

    /// Synthetic email for the in-memory test session.
    static let testUserEmail: String = "uitest@brain.local"

    /// Synthetic API key — placeholder. Never sent to a real server
    /// because `FakeBrainURLProtocol` intercepts every request.
    static let testApiKey: String = "uitest-api-key"

    /// Fake server base URL. The host is fictitious; `FakeBrainURLProtocol`
    /// intercepts on the scheme so it doesn't matter what the host is, but
    /// using `*.brain.test` keeps the intent obvious in any logs.
    static let testServerURL: URL = URL(string: "https://uitest.brain.test")!  // swiftlint:disable:this force_unwrapping
}
