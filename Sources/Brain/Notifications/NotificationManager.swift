// NotificationManager.swift
// brain-ios
//
// M41 — APNs device registration. Wraps the three-step dance
// (request permission -> register for remote notifications -> POST the
// device token to the brain server) behind a single `@Observable` that
// SwiftUI views can read for status and call to (re)kick the flow.
//
// Threading: `@MainActor` because every entry point either hops onto
// UIKit (`UIApplication.registerForRemoteNotifications` is main-actor
// isolated under strict concurrency) or publishes state SwiftUI
// observes. The HTTP call to the API client awaits an `actor`, so the
// main thread isn't pinned for the round-trip.
//
// Failure stance: APNs registration is intentionally non-load-bearing
// for v1. Sync still works without it — push only powers the morning
// briefing / due-reminder paths (M29). So when permission is denied,
// when APNs fails (typical on a not-yet-reserved bundle id without
// the Push entitlement), or when `POST /api/v1/devices` returns an
// error, we record the reason in `lastError` and move on. No alerts,
// no retries blocking the user, no crashes. Settings can surface the
// state for the user to act on if they want notifications back.
//
// Idempotency: `requestAuthorizationAndRegister()` is safe to call on
// every sign-in. The system caches the auth status (`requestAuthorization`
// just resolves to the cached value if the user already responded), and
// `POST /api/v1/devices` is upsert-on-token server-side (M29) — duplicate
// registrations are a no-op.
//
// SwiftUI <-> AppDelegate bridge: SwiftUI doesn't expose
// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
// `BrainAppDelegate` (registered via `@UIApplicationDelegateAdaptor`)
// holds a static reference to the manager and forwards the token /
// failure / silent-push callbacks. See `BrainAppDelegate` for the
// other half of the bridge.

#if canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// App-wide notification permission + APNs registration coordinator.
/// Owned by `BrainApp` and exposed to SwiftUI via
/// `@Environment(\.notificationManager)`. The same instance is also
/// stashed on `BrainAppDelegate` so the AppDelegate APNs callbacks can
/// reach it without the SwiftUI environment.
@Observable
@MainActor
final class NotificationManager {

    // MARK: - Observable state

    /// Latest authorization status as reported by the system. Defaults
    /// to `.notDetermined`; refreshed by `refreshAuthorizationStatus()`
    /// (called on launch and after `requestAuthorization`).
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Hex-encoded APNs device token from the most recent successful
    /// registration. Surfaced for the SettingsView debug row and so a
    /// future "re-register" flow can short-circuit if nothing changed.
    /// Not persisted across launches — APNs hands us a fresh token at
    /// app start anyway, so caching it would just risk staleness.
    private(set) var lastDeviceToken: String?

    /// User-facing reason the most recent attempt failed, or nil if
    /// the last attempt succeeded (or hasn't run yet). Includes both
    /// permission denial and server-side `POST /api/v1/devices`
    /// failures — they all go in the same bucket because the user
    /// action ("flip the toggle in Settings.app") is the same.
    private(set) var lastError: String?

    // MARK: - Dependencies

    private let client: BrainAPIClient
    private let authSession: AuthSession

    /// Indirection over `UNUserNotificationCenter.current()` /
    /// `UIApplication.shared` so future #if-DEBUG harnesses can stand
    /// the manager up without poking the real system. Production code
    /// uses the default initialiser.
    private let notificationCenter: UNUserNotificationCenter

    // MARK: - Init

    init(client: BrainAPIClient, authSession: AuthSession) {
        self.client = client
        self.authSession = authSession
        self.notificationCenter = UNUserNotificationCenter.current()
    }

    // MARK: - Public API

    /// Refresh `authorizationStatus` from the system. Call on launch
    /// so the Settings row reflects whatever the user did in
    /// Settings.app while the app was backgrounded. Cheap — just
    /// reads cached state inside the system.
    func refreshAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Request notification permission and, if granted, kick APNs
    /// registration. Idempotent — the system caches the user's choice
    /// after the first prompt, so subsequent calls resolve without
    /// re-prompting. Safe to call on every sign-in.
    ///
    /// On grant, calls `UIApplication.shared.registerForRemoteNotifications()`.
    /// The token (or failure) arrives asynchronously via the AppDelegate
    /// callbacks; see `handleAPNsToken(_:)` / `handleAPNsRegistrationFailure(_:)`.
    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            await refreshAuthorizationStatus()
            guard granted else {
                // User explicitly denied. Don't try to register for
                // remote notifications — APNs would just hand us back
                // a token we couldn't use to deliver a visible push
                // anyway, and silent-push wake doesn't require alert
                // permission but the M29 server-side delivery path
                // assumes alert-style notifications too.
                lastError = "Notification permission denied. Enable it in Settings to receive reminders."
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            // No `lastError = nil` here — the success ack lives in
            // `handleAPNsToken(_:)` once the system actually returns a
            // token. Leaving the previous error visible until then is
            // intentional: a stale "registration failed" message
            // accurately reflects state during the brief window
            // between requestAuthorization succeeding and the token
            // callback firing.
        } catch {
            lastError = "Authorization request failed: \(error.localizedDescription)"
        }
    }

    /// Forward to the system Settings.app entry for this app. Used by
    /// the SettingsView "Open System Settings" button when permission
    /// is denied — the only path back to a granted state is the OS
    /// settings, since `requestAuthorization` is one-shot.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - AppDelegate hooks

    /// Called by `BrainAppDelegate` when APNs returns a device token.
    /// Encodes the token bytes as lowercase hex and POSTs them to
    /// `/api/v1/devices`. The endpoint is upsert-on-token so duplicate
    /// calls (re-sign-in, app reinstall with the same token) are
    /// no-ops server-side.
    ///
    /// Skips the network call if the user is signed out — the token
    /// can arrive after a sign-out if APNs was slow. The next
    /// successful sign-in will trigger registration again from
    /// `requestAuthorizationAndRegister()`, so deferring is safe.
    func handleAPNsToken(_ deviceToken: Data) async {
        let tokenHex = Self.hex(from: deviceToken)
        lastDeviceToken = tokenHex

        guard authSession.isSignedIn else {
            // User signed out before the token arrived. Don't POST —
            // the request would 401 anyway (no API key). Next sign-in
            // re-runs the flow.
            return
        }

        do {
            try await client.registerDevice(
                apnsToken: tokenHex,
                platform: "ios",
                deviceName: Self.deviceName()
            )
            lastError = nil
        } catch let error as BrainAPIClient.Error {
            // Don't surface as a hard error — push isn't load-bearing
            // for v1 (sync still works). Log via `lastError` so a
            // SettingsView debug row can show what happened.
            lastError = "Device registration failed: \(error.userFacingMessage)"
        } catch {
            lastError = "Device registration failed: \(error.localizedDescription)"
        }
    }

    /// Called by `BrainAppDelegate` when APNs registration fails. The
    /// typical cause during M41 development is a missing Push
    /// capability on the App ID (Apple Developer setup is happening
    /// out-of-band). Record the reason and continue — the rest of the
    /// app keeps working without push.
    func handleAPNsRegistrationFailure(_ error: Error) {
        lastError = "APNs registration failed: \(error.localizedDescription)"
    }

    // MARK: - Helpers

    /// APNs token bytes -> lowercase hex string. Matches the wire
    /// format the server expects (the M29 schema stores `apns_token`
    /// as TEXT, and the brain `push.py` module hands it straight to
    /// `aioapns` which also wants lowercase hex).
    ///
    /// `nonisolated` because the encoding is pure data manipulation —
    /// no UIKit / system access — and the DEBUG `NotificationChecks`
    /// harness runs from a non-main-actor context. Keeping it off
    /// the main actor lets the checks call it without an `await`.
    nonisolated static func hex(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the `device_name` sent on `POST /api/v1/devices`. Mirrors
    /// the format used by the M30 login flow (`LoginView.deviceName()`)
    /// so a user inspecting their device list sees consistent labels
    /// across the API key and the APNs registration. Reading
    /// `UIDevice.current.name` is `@MainActor` under strict concurrency,
    /// which is why this whole class is main-actor isolated.
    static func deviceName() -> String {
        "iPhone — \(UIDevice.current.name)"
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `NotificationManager` instance via
/// `@Environment(\.notificationManager)`. Wired the same way as
/// `\.brainAPIClient` (M31/M32) and `\.syncEngine` (M33) so the four
/// app-scope singletons share the same plumbing.
private struct NotificationManagerKey: EnvironmentKey {
    static let defaultValue: NotificationManager? = nil
}

extension EnvironmentValues {
    var notificationManager: NotificationManager? {
        get { self[NotificationManagerKey.self] }
        set { self[NotificationManagerKey.self] = newValue }
    }
}

#endif
