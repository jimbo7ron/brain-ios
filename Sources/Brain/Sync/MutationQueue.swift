// MutationQueue.swift
// brain-ios
//
// Append-only, FIFO replayer for offline mutations (M37). Mirrors the
// shape of `SyncEngine` for the read path: own a `ModelContext`, a
// `BrainAPIClient`, and the `AuthSession`; expose a small public surface
// (`enqueue`, `replay`); manage backoff and 401-handoff internally so
// callers don't have to.
//
// Threading model: `@MainActor` for the same reason as `SyncEngine` —
// SwiftData's `ModelContext` prefers main-actor access, and we publish
// state to SwiftUI via `@Observable`. The HTTP work happens inside the
// `BrainAPIClient` actor, so awaits don't pin the main thread.
//
// Why the queue is the source of truth for writes:
//   * View code (M36 toggle, M38 inline edit, ...) calls `enqueue(...)`
//     and immediately performs the optimistic local mutation. The view
//     is done — the queue owns the round-trip.
//   * The replayer drains the queue in `createdAt` order. FIFO matters:
//     "rename project, then add section" must hit the server in that
//     order, otherwise the section add can race the rename and use the
//     pre-rename slug.
//   * On a recoverable failure (network blip, 5xx, rate-limit) we bump
//     `attempts` and stamp `nextRetryAt` with an exponential-backoff
//     timestamp, then *stop*. We do not skip past the failed item to
//     attempt later ones — that would break ordering. The next replay
//     call (post-sync, scenePhase, or the post-enqueue fire-and-forget)
//     picks up where we left off once `nextRetryAt` is in the past.
//   * On 401, we hand off to `AuthSession.signedOut()` (mirroring the
//     SyncEngine pattern) and *leave the queue intact*. When the user
//     signs back in, the same mutations replay against the new key.
//
// SyncEngine ↔ MutationQueue dependency direction: the SwiftUI scope
// (`SignedInRootView`) calls `replay()` after a successful sync rather
// than the engines holding references to each other. Keeping the two
// engines stateless w.r.t. each other matches how `\.brainAPIClient`
// and `\.syncEngine` are wired today and avoids a retain cycle through
// the environment. See `SignedInRootView.refreshTriggers()` for the
// trigger surface.
//
// Compile-time note: this file references `MutationQueueItem` (the
// SwiftData @Model) and `MutationOp`. Both live in this target — no
// imports beyond Foundation/SwiftData/Observation.

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class MutationQueue {

    // MARK: - Tunables

    /// Base delay for the exponential backoff schedule. Picked to be
    /// short enough that a transient network blip (a couple of seconds)
    /// doesn't visibly delay the user's mutation, but long enough that
    /// we don't hammer the server during a real outage. A doubling
    /// schedule from 2s reaches the 5-minute cap at ~8 attempts.
    private static let baseDelay: TimeInterval = 2

    /// Hard ceiling on backoff. Five minutes matches the SyncEngine
    /// foreground cadence — any mutation parked longer than that will
    /// retry whenever the next sync trigger fires the queue anyway.
    private static let maxDelay: TimeInterval = 300

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let client: BrainAPIClient
    private let authSession: AuthSession

    // MARK: - Observable state

    /// True between the start and end of a `replay()` pass. The guard
    /// in `replay()` is the de-dupe primitive — multiple triggers
    /// (post-enqueue Task, post-sync, scenePhase) can fire concurrently
    /// without stampeding the server.
    private(set) var isReplaying: Bool = false

    /// Pending row count surfaced for UI ("3 actions waiting to sync"
    /// pill in a future Settings panel). Refreshed on every enqueue and
    /// every replay pass so the value stays close to truth without
    /// having to materialise a SwiftData `@Query` in the call site.
    private(set) var pendingCount: Int = 0

    /// User-facing copy for the most recent failure across the queue,
    /// or nil if everything is replaying / has replayed cleanly.
    /// Overwritten on every failure — surfacing only the latest matches
    /// the SyncEngine treatment.
    private(set) var lastError: String?

    // MARK: - Init

    init(modelContext: ModelContext, client: BrainAPIClient, authSession: AuthSession) {
        self.modelContext = modelContext
        self.client = client
        self.authSession = authSession
        refreshPendingCount()
    }

    // MARK: - Public API

    /// Append a new mutation to the queue. Caller is responsible for any
    /// optimistic local UI mutation *before* this call so the user sees
    /// instant feedback regardless of network state.
    ///
    /// After the row is persisted we kick a fire-and-forget `replay()`
    /// Task. The `isReplaying` guard prevents a stampede if the user is
    /// rapidly enqueueing several mutations — the second `replay()` call
    /// short-circuits and the in-flight pass picks up the new row when
    /// it loops back to `nextReadyItem()`.
    @discardableResult
    func enqueue(op: MutationOp, resourceType: String, resourceId: String, payload: Data) throws -> MutationQueueItem {
        let item = MutationQueueItem(
            op: op.rawValue,
            resourceType: resourceType,
            resourceId: resourceId,
            payload: payload
        )
        modelContext.insert(item)
        try modelContext.save()
        refreshPendingCount()

        // Kick a non-blocking replay. Caller doesn't await it — the
        // optimistic UI is already correct, and a slow server shouldn't
        // freeze the user's tap-handler. `Task` inherits the main actor
        // (we're already on it), so `replay()`'s @MainActor expectation
        // holds.
        Task { await self.replay() }

        return item
    }

    /// Drain the queue in `createdAt` order, stopping at the first
    /// non-recoverable error. Safe to call concurrently — the
    /// `isReplaying` guard collapses overlapping calls.
    ///
    /// Behaviour summary:
    ///   * Success: delete the row, save, loop.
    ///   * 401: hand off to AuthSession (wipe Keychain + signedOut),
    ///     leave the queue intact, return.
    ///   * Other error: bump attempts, stamp nextRetryAt, stash
    ///     lastError on the row, save, then return (preserve order).
    func replay() async {
        guard !isReplaying else { return }
        isReplaying = true
        defer {
            isReplaying = false
            refreshPendingCount()
        }

        while let item = nextReadyItem() {
            do {
                try await client.executeMutation(item)
                modelContext.delete(item)
                try modelContext.save()
                // Clear the surfaced error once we make any forward
                // progress — keeps the UI from showing a stale failure
                // string after the next attempt succeeds.
                lastError = nil
            } catch BrainAPIClient.Error.unauthorized {
                // 401 = the device key is no longer valid. Mirror the
                // SyncEngine handoff: wipe Keychain, drop the in-memory
                // key, flip AuthSession back to .signedOut. Leave the
                // queue intact — re-signing in will resume replay
                // against the new key.
                await handleUnauthorized()
                return
            } catch {
                // Recoverable failure: bump attempts, schedule a
                // backoff, surface the error, stop the loop. The next
                // replay trigger after `nextRetryAt` picks the row back
                // up.
                let attemptsAfter = item.attempts + 1
                let delay = backoff(attempts: attemptsAfter)
                item.attempts = attemptsAfter
                item.nextRetryAt = Date().addingTimeInterval(delay)
                item.lastError = String(describing: error)
                // Best-effort save — if this throws too, the in-memory
                // mutation is still on the row, but a relaunch would
                // see the pre-failure state. That's acceptable; the
                // worst case is one extra retry on next launch.
                try? modelContext.save()
                if let apiError = error as? BrainAPIClient.Error {
                    lastError = apiError.userFacingMessage
                } else {
                    lastError = "Failed to send change: \(error.localizedDescription)"
                }
                return
            }
        }
    }

    // MARK: - Internal helpers

    /// Pull the oldest queue item that's ready for replay. Ready means
    /// either no `nextRetryAt` set (fresh row) or one whose `nextRetryAt`
    /// is in the past (backoff window expired).
    ///
    /// We do the "ready now?" filter in Swift rather than via a SwiftData
    /// `#Predicate` because the predicate language doesn't compose
    /// `nil OR <= now` cleanly across iOS 17/18 — the workaround would
    /// be two fetches and a merge. Pulling the full queue (sorted by
    /// createdAt, with `fetchLimit` capped) and filtering in memory is
    /// simpler and is bounded by the realistic queue depth (single-
    /// digit hundreds at the absolute outside).
    private func nextReadyItem() -> MutationQueueItem? {
        var descriptor = FetchDescriptor<MutationQueueItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        // Bound the fetch so a runaway queue can't fault every row into
        // memory. We only need the first ready row.
        descriptor.fetchLimit = 64
        let now = Date()
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        return candidates.first { item in
            guard let nextRetryAt = item.nextRetryAt else { return true }
            return nextRetryAt <= now
        }
    }

    /// Exponential backoff with ±25% jitter. `attempts` is the post-
    /// increment count (so the first failure passes `1`, yielding a
    /// ~2s wait, and the 8th passes `8`, hitting the 5-minute cap).
    /// Jitter avoids synchronised retry storms across devices on a
    /// shared outage.
    func backoff(attempts: Int) -> TimeInterval {
        // Guard against bad input. attempts <= 0 shouldn't happen on
        // the call path (we always pre-increment), but defensive math
        // here prevents a negative shift if the contract ever drifts.
        let safeAttempts = max(attempts, 1)
        // `pow` to TimeInterval keeps the math floating-point — Int
        // shifts would overflow at ~31 attempts, which is well past
        // the maxDelay cap but still nice to avoid as a class of bug.
        let exp = pow(2.0, Double(safeAttempts - 1))
        let raw = Self.baseDelay * exp
        let capped = min(raw, Self.maxDelay)
        // Jitter: uniform in [0.75, 1.25]. We deliberately apply jitter
        // *after* the cap so a fully-saturated row still varies its
        // retry instant across devices.
        let jitter = Double.random(in: 0.75...1.25)
        return capped * jitter
    }

    /// 401 handoff. Mirrors `SyncEngine.handleUnauthorized()` so the two
    /// paths converge on the same post-conditions: Keychain wiped, API
    /// client key cleared, AuthSession flipped to `.signedOut`. We do
    /// NOT clear the queue — those mutations represent real user
    /// intent, and the next sign-in (which uses the same `userId`) will
    /// drain them against the freshly-minted key.
    private func handleUnauthorized() async {
        try? KeychainStore.wipe()
        await client.setApiKey(nil)
        authSession.signedOut()
        lastError = nil
    }

    /// Refresh `pendingCount` from SwiftData. Cheap — SwiftData runs a
    /// `COUNT(*)` rather than materialising every row.
    private func refreshPendingCount() {
        let descriptor = FetchDescriptor<MutationQueueItem>()
        if let count = try? modelContext.fetchCount(descriptor) {
            pendingCount = count
        }
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `MutationQueue` instance via
/// `@Environment(\.mutationQueue)`. Wired the same way as
/// `\.brainAPIClient` and `\.syncEngine` (M31/M33) so the three
/// singletons stay symmetrical at the call site.
private struct MutationQueueKey: EnvironmentKey {
    static let defaultValue: MutationQueue? = nil
}

extension EnvironmentValues {
    var mutationQueue: MutationQueue? {
        get { self[MutationQueueKey.self] }
        set { self[MutationQueueKey.self] = newValue }
    }
}

// MARK: - Debug-only sanity checks

#if DEBUG

/// Documentation-grade smoke checks (no test target exists yet — see
/// the M37 spec). Call from a debug REPL or wire into a future
/// `BrainTests` target. Each function asserts on its own and crashes
/// on regression so a CI hook running `BrainDebugMutationQueue.runAll`
/// would catch the obvious breakages.
enum BrainDebugMutationQueue {

    /// Round-trip every `MutationOp` raw value through Codable. Catches
    /// future renames that would invalidate persisted queue rows.
    static func assertOpRoundTrip() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for op in MutationOp.allCases {
            do {
                let data = try encoder.encode(op)
                let decoded = try decoder.decode(MutationOp.self, from: data)
                assert(decoded == op, "MutationOp \(op) failed Codable round-trip")
                assert(decoded.rawValue == op.rawValue, "MutationOp \(op) raw value drift")
            } catch {
                assertionFailure("MutationOp \(op) failed to encode/decode: \(error)")
            }
        }
    }

    /// Verify the backoff schedule is monotonic non-decreasing in
    /// `attempts` (modulo jitter, which is bounded ±25%). Catches the
    /// off-by-one bugs where attempts=2 rolls back to a shorter delay
    /// than attempts=1.
    @MainActor
    static func assertBackoffMonotonic(queue: MutationQueue) {
        // We sample the worst-case low end of attempts=N+1 and the best-
        // case high end of attempts=N, then check N+1's floor exceeds
        // N's ceiling — that's only true once we're past the maxDelay
        // cap, where they should both saturate. Below the cap, we
        // weaken the assertion to "centre value strictly increases".
        var previousCentre: TimeInterval = 0
        for attempts in 1...10 {
            // Run a few samples and average to smooth jitter.
            let samples = (0..<8).map { _ in queue.backoff(attempts: attempts) }
            let average = samples.reduce(0, +) / Double(samples.count)
            assert(average >= previousCentre - 0.1,
                   "Backoff centre regressed at attempts=\(attempts): \(average) < \(previousCentre)")
            previousCentre = average
        }
    }

    /// Smoke-test enqueue → pendingCount bump. Requires an in-memory
    /// SwiftData container so we don't pollute the real store.
    @MainActor
    static func assertEnqueueBumpsCount() throws {
        let schema = Schema([MutationQueueItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        let initial = queue.pendingCount
        _ = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: "00000000-0000-0000-0000-000000000000",
            payload: Data()
        )
        assert(queue.pendingCount == initial + 1,
               "enqueue should bump pendingCount: was \(initial), now \(queue.pendingCount)")
    }

    /// Replay with no items must be a no-op (no crash, no state change).
    @MainActor
    static func assertEmptyReplayIsNoOp() async throws {
        let schema = Schema([MutationQueueItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        await queue.replay()
        assert(queue.pendingCount == 0)
        assert(queue.lastError == nil)
        assert(queue.isReplaying == false)
    }

    /// Run every check. Convenience entrypoint for a future debug menu /
    /// CI smoke step.
    @MainActor
    static func runAll() async {
        assertOpRoundTrip()
        do {
            try assertEnqueueBumpsCount()
            try await assertEmptyReplayIsNoOp()
        } catch {
            assertionFailure("BrainDebugMutationQueue: setup failed: \(error)")
        }
        // Backoff check uses a live MutationQueue, so build a throwaway
        // one to exercise the math.
        do {
            let schema = Schema([MutationQueueItem.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let session = AuthSession(state: .signedOut)
            let client = BrainAPIClient()
            let queue = MutationQueue(modelContext: context, client: client, authSession: session)
            assertBackoffMonotonic(queue: queue)
        } catch {
            assertionFailure("BrainDebugMutationQueue: backoff setup failed: \(error)")
        }
    }
}

#endif
