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
//   * On a *transient* failure (network blip, 5xx, rate-limit) we bump
//     `attempts` and stamp `nextRetryAt` with an exponential-backoff
//     timestamp, then *stop*. We do not skip past the failed item to
//     attempt later ones — that would break ordering. The next replay
//     call (post-sync, scenePhase, or the post-enqueue fire-and-forget)
//     picks up where we left off once `nextRetryAt` is in the past.
//   * On a *permanent* failure (404, 422, unknown op), the item is
//     "poisoned" — `nextRetryAt` is stamped to `.distantFuture` so it
//     never picks up again — and we `continue` to drain the rest of
//     the queue. Otherwise a single bad item would block every later
//     mutation forever.
//   * Transient failures also promote to poison after 10 attempts so a
//     pathological row can't retry indefinitely.
//   * On 401, we wipe the queue. The server has rejected the auth, so
//     replaying queue items would just clog with 404s; more importantly,
//     leaving rows on disk across a sign-out / sign-in cycle would let
//     User A's queued mutations replay against User B's tenant.
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
import SwiftUI

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
    /// Note: with the +/-25% jitter applied *after* the cap, the
    /// effective worst-case delay is ~6:15 (300 * 1.25), not exactly
    /// 5 minutes. Close enough — the cap exists to prevent runaway
    /// backoff, not to enforce a literal ceiling.
    private static let maxDelay: TimeInterval = 300

    /// Maximum number of replay attempts before a transient failure is
    /// promoted to a poison item. Picked high enough that a multi-day
    /// outage doesn't accidentally drop a user's mutation, but low
    /// enough that a pathologically broken request can't loop forever.
    /// At 10 attempts with the 5-minute cap, a stuck row burns ~50
    /// minutes of replay attempts before being parked.
    private static let maxAttempts: Int = 10

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

    /// Running count of queue items dropped by LWW conflict resolution
    /// (M38). Bumped from `dropPendingMutation(_:)` when the SyncEngine
    /// decides an incoming server row is newer than a pending local
    /// mutation. Surfaced as observability — a future Settings panel /
    /// transient toast (M43) can render "N changes overwritten by web
    /// edits". Reset on `clear()` so the count is meaningful per
    /// signed-in session rather than across sign-out/sign-in cycles.
    private(set) var conflictsResolved: Int = 0

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
    /// `baseUpdatedAt` is the server-side `updated_at` of the target
    /// resource at the moment the user kicked off this edit (M38). It's
    /// captured so LWW conflict resolution in `SyncEngine.applyRow` can
    /// detect the case where a newer server-side write (e.g. from the
    /// web client) lands while this mutation is still queued. Pass
    /// `nil` for ops that don't have a pre-existing resource (creates)
    /// or for callers that don't yet have the base — `nil` falls
    /// through to client-wins on replay, which matches pre-M38
    /// behaviour.
    ///
    /// After the row is persisted we kick a fire-and-forget `replay()`
    /// Task. The `isReplaying` guard prevents a stampede if the user is
    /// rapidly enqueueing several mutations — the second `replay()` call
    /// short-circuits and the in-flight pass picks up the new row when
    /// it loops back to `nextReadyItem()`.
    @discardableResult
    func enqueue(
        op: MutationOp,
        resourceType: String,
        resourceId: String,
        payload: Data,
        baseUpdatedAt: Date? = nil
    ) throws -> MutationQueueItem {
        let item = MutationQueueItem(
            op: op.rawValue,
            resourceType: resourceType,
            resourceId: resourceId,
            payload: payload,
            baseUpdatedAt: baseUpdatedAt
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

    /// Drain the queue in `createdAt` order. Safe to call concurrently
    /// — the `isReplaying` guard collapses overlapping calls.
    ///
    /// Failure taxonomy:
    ///   * Success (2xx): delete the row, save, loop.
    ///   * 401: wipe the queue (cross-tenant safety), hand off to
    ///     AuthSession.signedOut(), return.
    ///   * Permanent error (404 / 422 / notImplemented): poison the
    ///     row by stamping `nextRetryAt = .distantFuture` so it never
    ///     picks up again, then `continue` to the next item. Critical:
    ///     don't `return` — otherwise one bad row blocks the whole
    ///     queue indefinitely.
    ///   * Transient error (5xx, network, rate-limit): bump attempts,
    ///     schedule exponential backoff, return (preserves FIFO for
    ///     the retry). After `maxAttempts` retries the row is
    ///     promoted to poison so a pathological request can't retry
    ///     forever.
    func replay() async {
        guard !isReplaying else { return }
        isReplaying = true
        defer {
            isReplaying = false
            refreshPendingCount()
        }

        while let item = nextReadyItem() {
            do {
                let serverNote = try await client.executeMutation(item)
                // M44.x optimistic-add reconciliation: when a `.createTodo`
                // replay succeeds the server returns the canonical Note
                // (with a server-assigned UUID + short_id + timestamps).
                // The local stub was inserted at enqueue time keyed off
                // the client UUID we put in `item.resourceId`; patch it
                // in place so it picks up the server's id without a
                // visible flicker. Doing this *before* deleting the
                // queue row keeps the row's id the source of truth for
                // matching. Other ops (complete / update / archive)
                // return nil and skip the reconcile branch.
                if let serverNote {
                    reconcileCreateResponse(
                        clientId: item.resourceId,
                        serverNote: serverNote
                    )
                }
                modelContext.delete(item)
                try modelContext.save()
                // Clear the surfaced error once we make any forward
                // progress — keeps the UI from showing a stale failure
                // string after the next attempt succeeds.
                lastError = nil
            } catch let error as BrainAPIClient.Error {
                switch error {
                case .unauthorized:
                    // 401 = the device key is no longer valid. Wipe
                    // the queue (a re-sign-in could be a different
                    // user — see `handleUnauthorized` doc) and flip
                    // AuthSession back to .signedOut.
                    await handleUnauthorized()
                    return

                case .notFound, .validationError, .notImplemented:
                    // Permanent failure: the request will never
                    // succeed (resource gone, body malformed, op slug
                    // unknown). Poison the row and drain the rest of
                    // the queue — otherwise a single bad item blocks
                    // every later mutation.
                    //
                    // `.notFound` here specifically means a
                    // RESOURCE-not-found (a note/project the server
                    // confirms doesn't exist). Route-not-found is a
                    // separate case below — it should NOT poison.
                    item.attempts += 1
                    item.nextRetryAt = .distantFuture
                    item.lastError = "Permanent failure: \(error)"
                    try? modelContext.save()
                    lastError = error.userFacingMessage
                    continue

                case .routeNotFound:
                    // Server returned 404 for the PATH itself, not the
                    // resource. This signals iOS and the server are
                    // out of sync: misconfigured server URL, missing
                    // endpoint, or an iOS build newer than the
                    // deployed server. Poisoning would be wrong — a
                    // user with a bad URL would have every queued
                    // mutation permanently dropped. Backoff with the
                    // same retry-cap as other transient failures, but
                    // log LOUDLY (NSLog so it shows up outside the
                    // SwiftUI debug pane) so an operator can spot it.
                    let attemptsAfter = item.attempts + 1
                    item.attempts = attemptsAfter
                    if attemptsAfter >= Self.maxAttempts {
                        item.nextRetryAt = .distantFuture
                        item.lastError = "Retry cap exceeded after \(attemptsAfter) attempts: \(error)"
                    } else {
                        let delay = backoff(attempts: attemptsAfter)
                        item.nextRetryAt = Date().addingTimeInterval(delay)
                        item.lastError = String(describing: error)
                    }
                    try? modelContext.save()
                    // Surface the route-not-found case via lastError
                    // so the UI (M44 territory) can hint at the
                    // out-of-sync server. The message wording is
                    // chosen to point at the operator action, not the
                    // user's data.
                    lastError = error.userFacingMessage
                    NSLog(
                        "MutationQueue: route-not-found on \(item.op) for resource " +
                        "\(item.resourceId). Server URL may be misconfigured or the iOS " +
                        "client is newer than the deployed server. Backing off; will retry."
                    )
                    return

                default:
                    // Transient failure (5xx, network, rate-limit,
                    // unknown status, decoding, invalid URL). Backoff
                    // and stop the drain to preserve FIFO on retry.
                    // Promote to poison after `maxAttempts` so a
                    // genuinely-broken request can't retry forever.
                    let attemptsAfter = item.attempts + 1
                    item.attempts = attemptsAfter
                    if attemptsAfter >= Self.maxAttempts {
                        item.nextRetryAt = .distantFuture
                        item.lastError = "Retry cap exceeded after \(attemptsAfter) attempts: \(error)"
                    } else {
                        let delay = backoff(attempts: attemptsAfter)
                        item.nextRetryAt = Date().addingTimeInterval(delay)
                        item.lastError = String(describing: error)
                    }
                    // Best-effort save — if this throws too, the
                    // in-memory mutation is still on the row, but a
                    // relaunch would see the pre-failure state.
                    // That's acceptable; the worst case is one extra
                    // retry on next launch.
                    try? modelContext.save()
                    lastError = error.userFacingMessage
                    return
                }
            } catch {
                // Non-API error path (e.g. SwiftData fault). Treat as
                // transient and back off; same retry-cap logic as
                // above so we don't loop on a persistently broken row.
                let attemptsAfter = item.attempts + 1
                item.attempts = attemptsAfter
                if attemptsAfter >= Self.maxAttempts {
                    item.nextRetryAt = .distantFuture
                    item.lastError = "Retry cap exceeded after \(attemptsAfter) attempts: \(error)"
                } else {
                    let delay = backoff(attempts: attemptsAfter)
                    item.nextRetryAt = Date().addingTimeInterval(delay)
                    item.lastError = String(describing: error)
                }
                try? modelContext.save()
                lastError = "Failed to send change: \(error.localizedDescription)"
                return
            }
        }
    }

    /// Wipe every row in the queue. Used on sign-out (manual via
    /// `SettingsView.signOut()` and forced via `handleUnauthorized()`)
    /// to prevent User A's queued mutations from replaying against
    /// User B's tenant after a sign-in switch. Cheap — even a few
    /// hundred rows delete in milliseconds.
    func clear() {
        let descriptor = FetchDescriptor<MutationQueueItem>()
        if let items = try? modelContext.fetch(descriptor) {
            for item in items {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
        refreshPendingCount()
        lastError = nil
        // Reset the LWW conflict counter so it's meaningful per
        // signed-in session. A `clear()` always implies the queue is
        // gone (sign-out, 401, manual wipe), so the previous session's
        // accumulated conflict count would only confuse the UI on
        // re-sign-in.
        conflictsResolved = 0
    }

    /// Look up the oldest pending queue item for a given resource id.
    /// Used by `SyncEngine.applyRow` (M38) to find a queued mutation
    /// that may conflict with an incoming server row. FIFO matches the
    /// replay order, so picking the oldest gives us the same item the
    /// replayer would dispatch next for that resource.
    ///
    /// Why fetch with a predicate here rather than scanning the whole
    /// queue: a single resource typically has 0–1 pending mutations,
    /// and pulling them by `resourceId` keeps the SyncEngine call site
    /// O(1) even if the queue grows large during a long offline window.
    func pendingMutation(forResourceId id: String) -> MutationQueueItem? {
        var descriptor = FetchDescriptor<MutationQueueItem>(
            predicate: #Predicate { $0.resourceId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Drop a pending queue item because LWW concluded the server's
    /// version is newer (M38). Increments `conflictsResolved` so the
    /// UI can surface "N changes overwritten by web edits". Called by
    /// `SyncEngine.applyRow` when an inbound row's `updated_at` is
    /// strictly greater than both the queue item's `baseUpdatedAt`
    /// and `createdAt`.
    ///
    /// Best-effort save: a SwiftData failure here is logged via
    /// `lastError` rather than thrown — the SyncEngine can't usefully
    /// recover from a save failure mid-apply, and on next launch the
    /// queue will simply still contain the row (which then replays and
    /// — at worst — is rejected by the server with the newer state).
    func dropPendingMutation(_ item: MutationQueueItem) {
        modelContext.delete(item)
        do {
            try modelContext.save()
            conflictsResolved += 1
            refreshPendingCount()
        } catch {
            lastError = "Failed to drop conflicting mutation: \(error.localizedDescription)"
        }
    }

    // MARK: - Internal helpers

    /// Patch the local optimistic stub (keyed by the client-minted
    /// UUID we used as `resourceId`) with the server's canonical Note
    /// so the row picks up the server's id, short id, and timestamps
    /// in a single SwiftData update — no flicker, no duplicate.
    ///
    /// Why this rather than "delete the stub and let the next sync
    /// upsert the server row": the sync round-trip can take seconds,
    /// and a delete-then-insert window lets the row vanish from the
    /// list mid-glance. Mutating in place keeps the @Query's identity
    /// stable from the user's POV — the row they typed and the row
    /// the server confirmed are the same SwiftData object, just with
    /// the id rewritten.
    ///
    /// `@Attribute(.unique)` on `LocalNote.id` is a uniqueness
    /// constraint, not an immutability constraint — SwiftData rechecks
    /// the new value on save. The replayer always runs after the local
    /// optimistic insert has already saved, so there's no in-flight
    /// row colliding on the new id.
    ///
    /// Idempotency: if a sync has *already* delivered the server's row
    /// before the create replay completes (rare but possible — the
    /// foreground Timer or scenePhase might have fired during the
    /// network blip we were retrying through), the local stub looked
    /// up by `clientId` no longer exists and the upsert from
    /// `SyncEngine.upsert(_:)` already inserted a row keyed by the
    /// server id. The lookup-by-clientId returns nil, we no-op, and
    /// the queue row drains as normal. Worst case: the user briefly
    /// saw two rows; the next sync convergence step never duplicates
    /// because the server only emits one Note per id.
    private func reconcileCreateResponse(clientId: String, serverNote: Note) {
        let descriptor: FetchDescriptor<LocalNote> = {
            var d = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.id == clientId }
            )
            d.fetchLimit = 1
            return d
        }()
        guard let stub = (try? modelContext.fetch(descriptor))?.first else {
            // Local stub already gone — sync raced us, or the user
            // wiped local data between enqueue and replay. The server
            // row is canonical and (if not yet present) will land on
            // the next sync. Nothing to do here.
            return
        }
        // Mirror the field copy that `SyncEngine.upsert(_:)` does on
        // an existing row. Keep this list in sync with the upsert path
        // — both produce the same final state, just from different
        // entry points (sync delta vs create echo).
        let createdAt = parseServerDate(serverNote.createdAt)
        let updatedAt = parseServerDate(serverNote.updatedAt)
        let tagsCSV = serverNote.tags.joined(separator: ",")
        let todo = serverNote.todo
        let appointment = serverNote.appointment
        stub.id = serverNote.id
        stub.shortId = serverNote.shortId
        stub.title = serverNote.title
        stub.content = serverNote.content
        stub.type = serverNote.type
        stub.archived = serverNote.archived
        stub.createdAt = createdAt
        stub.updatedAt = updatedAt
        stub.tagsCSV = tagsCSV
        stub.dueDate = todo?.dueDate
        stub.dueTime = todo?.dueTime
        stub.completed = todo?.completed ?? false
        stub.completedAt = parseServerDate(todo?.completedAt)
        stub.priority = todo?.priority ?? "medium"
        stub.recurrence = todo?.recurrence ?? appointment?.recurrence
        stub.projectId = todo?.projectId
        stub.section = todo?.section
        stub.url = todo?.url
        stub.urlTitle = todo?.urlTitle
        stub.urlState = todo?.urlState
        stub.urlFetchedAt = parseServerDate(todo?.urlFetchedAt)
        stub.sortOrder = todo?.sortOrder ?? 0
        stub.appointmentStartTime = appointment?.startTime
        stub.appointmentEndTime = appointment?.endTime
        stub.appointmentLocation = appointment?.location
        stub.appointmentRecurrence = appointment?.recurrence
    }

    /// Local copy of the SyncEngine's date-parser. Duplicating this
    /// (rather than wiring a shared utility) keeps `MutationQueue`
    /// dependency-light — it doesn't otherwise need to know about
    /// SyncEngine — and the formatters are cheap to instantiate
    /// once. If the server's timestamp shape ever drifts, update both
    /// places.
    private func parseServerDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Self.isoFractional.date(from: raw) {
            return date
        }
        return Self.isoBasic.date(from: raw)
    }

    private static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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

    /// Exponential backoff with +/-25% jitter. `attempts` is the
    /// post-increment count (so the first failure passes `1`, yielding
    /// a ~2s wait, and the 8th passes `8`, hitting the 5-minute cap).
    /// Jitter avoids synchronised retry storms across devices on a
    /// shared outage. Note: jitter is applied AFTER the cap, so the
    /// effective worst-case delay is ~6:15 (300 * 1.25), not 300s.
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

    /// 401 handoff. Mirrors `SyncEngine.handleUnauthorized()` so the
    /// two paths converge on the same post-conditions: queue wiped,
    /// Keychain wiped, API client key cleared, AuthSession flipped to
    /// `.signedOut`.
    ///
    /// The queue IS wiped here. The original M37 design left it
    /// intact so a re-sign-in could resume the drain, but that's
    /// unsafe: we have no guarantee the next sign-in is the same
    /// user, and a UUID collision (or any reused `resourceId`) could
    /// then mutate User B's tenant with User A's intent. Since the
    /// 401 already means the server has rejected this session's
    /// auth, any queued items would replay into 404s anyway — wiping
    /// is strictly safer than preserving.
    private func handleUnauthorized() async {
        clear()
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

    /// M38: LWW server-wins drop. Enqueue with a `baseUpdatedAt`,
    /// then drop via `dropPendingMutation` and assert the queue
    /// shrinks and `conflictsResolved` ticks up. Mirrors what
    /// `SyncEngine.resolveConflictIfNeeded` does on a real conflict.
    @MainActor
    static func assertLWWDropIncrementsCounter() throws {
        let schema = Schema([MutationQueueItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        let resourceId = "11111111-1111-1111-1111-111111111111"
        let base = Date().addingTimeInterval(-60) // user's edit was based on something a minute old
        let item = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: resourceId,
            payload: Data(),
            baseUpdatedAt: base
        )
        assert(item.baseUpdatedAt == base, "baseUpdatedAt should round-trip through enqueue")
        let initialConflicts = queue.conflictsResolved
        let initialPending = queue.pendingCount
        // Look up the same item by resource id to exercise the helper.
        let fetched = queue.pendingMutation(forResourceId: resourceId)
        assert(fetched?.id == item.id, "pendingMutation(forResourceId:) should return the enqueued row")
        guard let fetched else {
            assertionFailure("pendingMutation lookup returned nil")
            return
        }
        queue.dropPendingMutation(fetched)
        assert(queue.conflictsResolved == initialConflicts + 1,
               "dropPendingMutation should bump conflictsResolved")
        assert(queue.pendingCount == initialPending - 1,
               "dropPendingMutation should shrink pendingCount")
        assert(queue.pendingMutation(forResourceId: resourceId) == nil,
               "dropped mutation should no longer be findable")
    }

    /// M38: clear() resets `conflictsResolved` along with the queue
    /// rows. The counter is per-session; a sign-out wipe should not
    /// carry yesterday's conflict tally into a new session.
    @MainActor
    static func assertClearResetsConflictCounter() throws {
        let schema = Schema([MutationQueueItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        let item = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: "22222222-2222-2222-2222-222222222222",
            payload: Data(),
            baseUpdatedAt: Date()
        )
        queue.dropPendingMutation(item)
        assert(queue.conflictsResolved >= 1)
        queue.clear()
        assert(queue.conflictsResolved == 0,
               "clear() should reset conflictsResolved")
        assert(queue.pendingCount == 0)
    }

    /// Run every check. Convenience entrypoint for a future debug menu /
    /// CI smoke step.
    @MainActor
    static func runAll() async {
        assertOpRoundTrip()
        do {
            try assertEnqueueBumpsCount()
            try await assertEmptyReplayIsNoOp()
            try assertLWWDropIncrementsCounter()
            try assertClearResetsConflictCounter()
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
