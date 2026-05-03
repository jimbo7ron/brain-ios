// AuthSession.swift
// brain-ios
//
// App-wide source of truth for authentication state. Owned by
// `BrainApp` and injected into the SwiftUI environment so any view
// (or non-view, e.g. M33's sync engine) can read it and react to
// sign-in / sign-out transitions without reaching into a parent
// view's local `@State`.
//
// Why this exists: M32 originally split auth state across the
// `BrainAPIClient` actor's `apiKey` and `ContentView`'s `@State var
// apiKey`, both seeded independently from Keychain at launch. They
// stayed in sync because every transition touched both, but the
// pattern doesn't survive M33: when the sync engine catches a 401
// (e.g. the user revoked the device key from another device), it
// needs to flip the UI back to LoginView. The actor knows but
// ContentView's local @State doesn't, and there's no hook to bridge
// them without `NotificationCenter`.
//
// `AuthSession` collapses the two sources into one. Keychain remains
// the durable persistence layer; this object is the in-memory mirror
// the UI observes. Wiring is:
//
//   * App launch → `init` reads Keychain → state = .signedIn(...)
//     if all three of (.apiKey, .userId, .userEmail) are present,
//     else .signedOut.
//   * Login success → caller writes Keychain + sets the API client's
//     key, then calls `didSignIn(userId:email:)`. ContentView
//     re-renders.
//   * Sign-out → caller revokes server-side, wipes Keychain, clears
//     the API client's key, then calls `signedOut()`. ContentView
//     re-renders.
//   * 401 from sync (M33) → sync engine wipes Keychain + clears the
//     API client's key, then calls `signedOut()`. Same path as
//     manual sign-out.

import Foundation
import Observation

/// Observable wrapper around the app's authentication state. Read by
/// SwiftUI views via `@Environment(AuthSession.self)`; mutated by
/// the login flow (`didSignIn`) and by sign-out / 401 handlers
/// (`signedOut`).
///
/// Marked `@MainActor` because every transition originates from UI
/// code (login button, sign-out button) or from sync callbacks that
/// already hop to the main actor before flipping UI state. Keeping
/// it main-actor-isolated removes any "did SwiftUI observe this on
/// the right actor?" ambiguity at call sites.
@Observable
@MainActor
final class AuthSession {

    /// Discriminated state so views can pattern-match rather than
    /// juggling parallel `userId`/`email`/`isSignedIn` properties.
    enum State: Equatable {
        case signedOut
        case signedIn(userId: String, email: String)
    }

    /// Externally read-only — mutations go through `didSignIn` /
    /// `signedOut` so call sites can't accidentally bypass the
    /// transition contract.
    private(set) var state: State = .signedOut

    /// Default initialiser hydrates from Keychain so cold launches
    /// land on the correct branch without flickering through the
    /// login screen on warm starts. We require all three of
    /// `.apiKey`, `.userId`, `.userEmail` — partial state means a
    /// previous sign-in / sign-out only got halfway, and the safest
    /// recovery is to treat the session as signed out and let the
    /// user log in again.
    ///
    /// `try?` collapses both "key missing" and Keychain errors to
    /// nil. The latter happens on pre-first-unlock background
    /// launches (returns `errSecInteractionNotAllowed`); if M33's
    /// background fetch ever runs before first unlock, this will
    /// briefly read as signed out. That's a known limitation —
    /// noted on `BrainApp.init` too — and is fine until M33 actually
    /// does background work.
    init() {
        let apiKey = (try? KeychainStore.load(.apiKey)) ?? nil
        let userId = (try? KeychainStore.load(.userId)) ?? nil
        let email = (try? KeychainStore.load(.userEmail)) ?? nil
        if apiKey != nil, let userId, let email {
            self.state = .signedIn(userId: userId, email: email)
        } else {
            self.state = .signedOut
        }
    }

    /// Test-only / preview seam: build an `AuthSession` in a known
    /// state without touching Keychain. Production code uses the
    /// no-arg initialiser.
    init(state: State) {
        self.state = state
    }

    // MARK: - Transitions

    /// Flip to `.signedIn`. Callers are responsible for persisting
    /// credentials to Keychain and updating the API client's key
    /// *before* calling this — the order matters because views may
    /// re-render synchronously and immediately fire authenticated
    /// requests off the API client.
    func didSignIn(userId: String, email: String) {
        state = .signedIn(userId: userId, email: email)
    }

    /// Flip to `.signedOut`. Callers are responsible for revoking
    /// server-side, wiping Keychain, and clearing the API client's
    /// key *before* calling this. Used by both manual sign-out and
    /// the M33 sync-engine 401 handler — they share the same
    /// post-conditions, so they share the same transition.
    func signedOut() {
        state = .signedOut
    }

    // MARK: - Convenience accessors

    /// Quick boolean for views that don't need to inspect the
    /// associated values. `ContentView` uses the full pattern match;
    /// other views (e.g. a future Settings entry that reveals the
    /// signed-in email) can read these directly.
    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var email: String? {
        if case .signedIn(_, let email) = state { return email }
        return nil
    }

    var userId: String? {
        if case .signedIn(let userId, _) = state { return userId }
        return nil
    }
}
