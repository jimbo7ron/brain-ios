// BrainAppDelegate.swift
// brain-ios
//
// M41 — UIKit AppDelegate adapter for SwiftUI. Exists because three
// of the APNs callbacks live on `UIApplicationDelegate` and SwiftUI
// has no native way to surface them:
//
//   * `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
//     — APNs handed us a device token. Forward to NotificationManager
//     so it can POST to `/api/v1/devices`.
//   * `application(_:didFailToRegisterForRemoteNotificationsWithError:)`
//     — APNs registration failed (typical during M41 development:
//     bundle id not yet reserved + Push capability not enabled).
//     Log via NotificationManager; the app keeps working.
//   * `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
//     — silent push wake (`content-available: 1`). The system gives us
//     ~30s in the background to do work; we drain `SyncEngine.sync()`
//     and the mutation queue, then call the completion handler. Returns
//     `.newData` on success so the system tracks the wake as productive
//     (the OS uses this signal to throttle future wakes; reporting
//     `.failed` accurately when sync fails is what gates M29's 15-minute
//     cadence on healthy networks).
//
// Bridge pattern: SwiftUI owns the lifecycle (`@UIApplicationDelegateAdaptor`
// in BrainApp), but the AppDelegate has no access to the SwiftUI
// environment. So `BrainApp.init` stashes the NotificationManager and
// SyncEngine on static storage immediately after constructing them.
// The static refs are weak-equivalent — they're never reset because
// the singletons live for the app's full lifetime — but we use
// `static var` rather than capturing them in closures because
// AppDelegate methods are called by UIKit, not by user code, and have
// no place to inject dependencies.
//
// Concurrency model: the class is marked `@MainActor` so the static
// stored properties (which hold main-actor-isolated singletons)
// inherit isolation, and the synchronous AppDelegate methods can
// read them without explicit hops. UIKit invokes
// `UIApplicationDelegate` methods on the main thread in practice, so
// the runtime contract matches. The `Task { @MainActor in ... }`
// wrappers inside each method exist not for actor-hopping but to
// bridge the synchronous AppDelegate signatures to async work
// (`handleAPNsToken` awaits a network call; `sync()` is async).

#if canImport(UIKit)
import Foundation
import UIKit

/// UIKit app delegate adapter. Registered in `BrainApp` via
/// `@UIApplicationDelegateAdaptor(BrainAppDelegate.self)`.
///
/// Marked `@MainActor` so the static refs (which hold main-actor
/// isolated `NotificationManager` / `SyncEngine` / `MutationQueue`
/// values) inherit isolation — Swift 5.10 strict concurrency
/// otherwise warns on static stored properties of main-actor types.
/// The `UIApplicationDelegate` methods are already main-actor in the
/// SDK so this annotation just makes the inheritance explicit.
@MainActor
final class BrainAppDelegate: NSObject, UIApplicationDelegate {

    /// Set by `BrainApp.init` immediately after constructing the
    /// NotificationManager. The AppDelegate has no other way to reach
    /// the SwiftUI-environment-hosted instance, so we use a static
    /// reference. Initialised exactly once per process and never reset
    /// — the manager outlives the AppDelegate.
    static var notificationManager: NotificationManager?

    /// Set by `BrainApp.init` immediately after constructing the
    /// SyncEngine. Same rationale as `notificationManager` — silent-push
    /// wake needs to drive `sync()` from a non-SwiftUI context.
    static var syncEngine: SyncEngine?

    /// Set by `BrainApp.init` immediately after constructing the
    /// MutationQueue. We drain it during silent-push wake too — a
    /// background wake is a perfect moment to push any queued offline
    /// mutations, since the user explicitly is not in the app to
    /// notice the round-trip latency.
    static var mutationQueue: MutationQueue?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // SwiftUI's `@main` body owns the rest of launch — scene
        // setup, environment injection, root view. We just need the
        // protocol method to exist so the adapter binds.
        true
    }

    // MARK: - APNs registration callbacks

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Bridge to async work: `handleAPNsToken` awaits a network
        // round-trip. The Task inherits the class's main-actor
        // isolation, so no explicit `@MainActor` annotation needed.
        Task {
            await Self.notificationManager?.handleAPNsToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Synchronous handler — the manager just records the reason
        // and returns. Common failure during M41 development: the
        // `aps-environment` entitlement isn't trusted because the
        // App ID hasn't been Push-enabled yet on the dev portal.
        // The rest of the app keeps working without push.
        Self.notificationManager?.handleAPNsRegistrationFailure(error)
    }

    // MARK: - Silent push wake

    /// Background fetch driven by an APNs `content-available: 1` payload.
    /// The system gives us a budget (~30s) to do work and expects us
    /// to call `completionHandler` exactly once. Failing to call it is
    /// punished by the OS throttling future wakes, which would defeat
    /// the 15-minute cadence M29 is designed for.
    ///
    /// We drain `SyncEngine.sync()` (read path) and then `mutationQueue.replay()`
    /// (write path). On failure we still call the handler — the system
    /// uses the result to throttle, but never calling it is worse than
    /// reporting `.failed`.
    ///
    /// Note: `SyncEngine.sync()` is non-throwing — it traps errors
    /// internally and surfaces them via `lastError`. We can't tell
    /// from the call site whether a sync actually succeeded, so we
    /// inspect `lastSyncedAt` before/after to decide between
    /// `.newData` and `.noData`. A bumped timestamp means a successful
    /// pull (even if the response carried no notes); an unchanged
    /// timestamp + `lastError` set means it failed.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Bridge to async work via Task. The Task inherits the
        // class's main-actor isolation, so all subsequent reads/writes
        // are safe. We MUST call `completionHandler` exactly once
        // before returning — the OS punishes apps that don't.
        Task {
            guard let syncEngine = Self.syncEngine else {
                // No engine wired up — happens only in pathological
                // launch states (the static is set in BrainApp.init,
                // before any APNs callback could fire). Report
                // `.noData` rather than `.failed` so the OS doesn't
                // back off future wakes for a transient init issue.
                completionHandler(.noData)
                return
            }

            let beforeSyncedAt = syncEngine.lastSyncedAt
            await syncEngine.sync()
            // Drain the mutation queue too — a background wake is
            // a perfect moment to flush queued offline writes the
            // user enqueued while disconnected.
            await Self.mutationQueue?.replay()
            let afterSyncedAt = syncEngine.lastSyncedAt

            // `lastSyncedAt` only advances on a successful pull. If
            // it changed, the sync went through (regardless of
            // payload size). If it didn't change AND there's a
            // `lastError`, the sync failed.
            if afterSyncedAt != beforeSyncedAt {
                completionHandler(.newData)
            } else if syncEngine.lastError != nil {
                completionHandler(.failed)
            } else {
                // Debounce skipped the call — the engine recently
                // synced from another trigger. Report `.noData`:
                // we did our job, there just wasn't fresh data to
                // pull this round.
                completionHandler(.noData)
            }
        }
    }
}

#endif
