// MutationStatusStore.swift
// brain-ios
//
// M45 Wave 1: per-row mutation status keyed by the resource's *current*
// id. Powers the "spinner / red dot on individual notes that are mid-
// flight or have failed" affordance — the queue-level "N pending /
// M failed" banner is already covered by `MutationQueue.pendingCount` /
// `lastError` (and the not-yet-added `failedCount`).
//
// Why a separate observable, not a column on `LocalNote`:
//   * Status is transient — it doesn't survive an app restart. Persisting
//     it on the model would create ghost-pending rows after a force-quit
//     (Bear shipped this and got bitten).
//   * Status isn't the model's concern — `LocalNote` mirrors the server's
//     wire shape; "we have a queued mutation in flight" is sync state,
//     not data.
//   * SwiftData `@Query` re-renders fight with transient mutation —
//     flipping a column to drive a spinner ripples through the row's
//     full SwiftData diff path on every state change.
//
// Lifecycle (per spec §4.4):
//   1. Repository populates `.pending` on enqueue.
//   2. The MutationQueue calls `rename(clientId, to: serverId)` from
//      inside `reconcileCreate<T:>` once the server-issued id is known.
//   3. The MutationQueue calls `clear(serverId)` once the queue row is
//      deleted (success terminal).
//   4. The rollback path (`rollbackOptimisticStateIfNeeded`) calls
//      `mark(id, .failed(error))`. Failed entries persist until the
//      user dismisses (so the user has time to notice before the row
//      vanishes).
//
// Storage: a single `[String: Status]` dictionary. `@Observable`'s
// macro-driven change tracking on the dictionary is the source of truth
// — views reading `status(for:)` rebuild when the dictionary mutates.
// iOS 17 `@Observable` tracks dictionary writes correctly; if the
// rebuild surface ever turns out too coarse (every status change rebuilds
// every row that observes the store), the fix is to switch the API to
// per-key bindings via SwiftUI `@Bindable` — not to add a layer of
// publishers here.

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MutationStatusStore {

    enum Status {
        /// Mutation is enqueued and the queue is either replaying it
        /// now or waiting on a backoff window.
        case pending
        /// Mutation was poisoned by the queue (404 / 422 / unknown op)
        /// and the optimistic local state — if any — has been rolled
        /// back. The error is captured for the per-row UI to surface
        /// once Wave 4 lands.
        case failed(Error)
    }

    /// Backing dictionary. `private(set)` so tests can read the map
    /// without going through `status(for:)` (avoiding O(N) when verifying
    /// "no entry exists for this key" patterns), but no external writer
    /// can bypass the named mutators.
    private(set) var statuses: [String: Status] = [:]

    init() {}

    /// Look up the current status for a resource id, or `nil` if no
    /// mutation is in flight / failed for that id.
    ///
    /// Reads from the dictionary directly so the `@Observable` macro
    /// records a dependency on the keypath; views that observe this
    /// rebuild when any entry changes. See file header for the
    /// rebuild-coarseness caveat.
    func status(for id: String) -> Status? {
        statuses[id]
    }

    /// Mark a resource id as `pending` or `.failed`. Repository calls
    /// this on enqueue (pending) and the queue's rollback path calls
    /// it on poison (failed).
    func mark(_ id: String, _ status: Status) {
        statuses[id] = status
    }

    /// Drop a resource id from the map. Called by the queue's success
    /// terminal once the queue row is deleted, OR by Wave 4's "dismiss
    /// failure" UI gesture.
    func clear(_ id: String) {
        statuses.removeValue(forKey: id)
    }

    /// Rewrite a resource id from `oldId` to `newId` in place. Called
    /// from inside `MutationQueue.reconcileCreate<T:>` once the server
    /// has issued the canonical UUID (the create-echo's id rename
    /// step). Preserves the status under the new key so per-row UI
    /// indicators tied to the eventual server id stay attached across
    /// the rename.
    ///
    /// No-op when `oldId == newId` or when the store has no entry under
    /// `oldId` (the latter is the common case — most rename calls fire
    /// from reconcile paths where the repository didn't record a
    /// pending status, e.g. preview / debug builds).
    func rename(_ oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let status = statuses.removeValue(forKey: oldId) else { return }
        statuses[newId] = status
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `MutationStatusStore` via
/// `@Environment(\.mutationStatusStore)`. Wired the same way as
/// `\.brainAPIClient`, `\.syncEngine`, and `\.mutationQueue` — the
/// per-singleton symmetry keeps call sites consistent.
///
/// Per spec §8.3 (preview trap): default value is `nil`, and
/// Repository / view callers MUST handle the nil case gracefully.
/// Xcode previews are the canonical "no environment" host; production
/// always has the store wired in `BrainApp.init`.
private struct MutationStatusStoreKey: EnvironmentKey {
    static let defaultValue: MutationStatusStore? = nil
}

extension EnvironmentValues {
    var mutationStatusStore: MutationStatusStore? {
        get { self[MutationStatusStoreKey.self] }
        set { self[MutationStatusStoreKey.self] = newValue }
    }
}
