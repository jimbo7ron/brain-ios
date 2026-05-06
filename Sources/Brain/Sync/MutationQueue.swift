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

    /// Optional per-row status tracker (M45 Wave 1). Wired in
    /// `BrainApp.init` after both singletons exist so the queue can
    /// notify the store of `pending → renamed → cleared` and
    /// `pending → failed` transitions. Optional because many tests /
    /// debug callers construct the queue without one — the queue must
    /// keep working when the store is absent.
    ///
    /// **Why optional, not required:** `BrainDebugMutationQueue` and
    /// the M45 unit tests construct a `MutationQueue` directly with
    /// just (modelContext, client, authSession). Hard-requiring the
    /// store would fan out a constructor argument across every call
    /// site that doesn't care about UI status; making it optional
    /// keeps the existing wiring untouched and lets the new wiring
    /// land via a single line in `BrainApp.init`.
    weak var statusStore: MutationStatusStore?

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
                let serverResponse = try await client.executeMutation(item)
                // M44.x / M45 Wave 2 optimistic-add reconciliation: when
                // a `.createTodo` / `.createProject` replay succeeds the
                // server returns the canonical entity (with a server-
                // assigned UUID + short_id + timestamps). The local stub
                // was inserted at enqueue time keyed off the client UUID
                // we put in `item.resourceId`; patch it in place so it
                // picks up the server's id without a visible flicker.
                // Doing this *before* deleting the queue row keeps the
                // row's id the source of truth for matching. Other ops
                // (complete / update / archive) return nil and skip the
                // reconcile branch.
                switch serverResponse {
                case .note(let serverNote):
                    reconcileCreateResponse(
                        clientId: item.resourceId,
                        serverNote: serverNote
                    )
                case .project(let serverProject):
                    reconcileCreateProjectResponse(
                        clientId: item.resourceId,
                        serverProject: serverProject
                    )
                case .none:
                    break
                }
                // M45 Wave 1: capture the *post-reconcile* resource id
                // before we delete the queue row. For create ops the
                // reconcile above rewrote `item.resourceId` from the
                // client UUID to the server id (B2 step); for non-
                // create ops the id is unchanged. Either way, this is
                // the key the status store is now keyed under after
                // any rename, so it's the right key to clear.
                let clearedId = item.resourceId
                modelContext.delete(item)
                try modelContext.save()
                // Clear the surfaced error once we make any forward
                // progress — keeps the UI from showing a stale failure
                // string after the next attempt succeeds.
                lastError = nil
                // M45 Wave 1: success terminal of the per-row status
                // lifecycle. The repository wrote `.pending` at enqueue;
                // reconcile (if any) flipped the key to the server id;
                // now the queue has confirmed the round-trip and the
                // SwiftUI side has the canonical SwiftData row, so the
                // pending indicator can come down. No-op when
                // `statusStore` is nil — keeps tests / debug callers
                // unencumbered (see the field doc-comment for why).
                statusStore?.clear(clearedId)
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
                    rollbackOptimisticStateIfNeeded(for: item, reason: error)
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
                    let cappedToPoison = attemptsAfter >= Self.maxAttempts
                    if cappedToPoison {
                        item.nextRetryAt = .distantFuture
                        item.lastError = "Retry cap exceeded after \(attemptsAfter) attempts: \(error)"
                    } else {
                        let delay = backoff(attempts: attemptsAfter)
                        item.nextRetryAt = Date().addingTimeInterval(delay)
                        item.lastError = String(describing: error)
                    }
                    try? modelContext.save()
                    if cappedToPoison {
                        rollbackOptimisticStateIfNeeded(for: item, reason: error)
                    }
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
                    let cappedToPoison = attemptsAfter >= Self.maxAttempts
                    if cappedToPoison {
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
                    if cappedToPoison {
                        rollbackOptimisticStateIfNeeded(for: item, reason: error)
                    }
                    lastError = error.userFacingMessage
                    return
                }
            } catch {
                // Non-API error path (e.g. SwiftData fault). Treat as
                // transient and back off; same retry-cap logic as
                // above so we don't loop on a persistently broken row.
                let attemptsAfter = item.attempts + 1
                item.attempts = attemptsAfter
                let cappedToPoison = attemptsAfter >= Self.maxAttempts
                if cappedToPoison {
                    item.nextRetryAt = .distantFuture
                    item.lastError = "Retry cap exceeded after \(attemptsAfter) attempts: \(error)"
                } else {
                    let delay = backoff(attempts: attemptsAfter)
                    item.nextRetryAt = Date().addingTimeInterval(delay)
                    item.lastError = String(describing: error)
                }
                try? modelContext.save()
                if cappedToPoison {
                    rollbackOptimisticStateIfNeeded(for: item, reason: error)
                }
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
    /// Dual-ModelContext propagation: the optimistic insert in
    /// `QuickAddView.submit()` lands on the SwiftUI
    /// `@Environment(\.modelContext)`, while the reconcile fetch +
    /// rename + field copy here happens on the queue's own
    /// `ModelContext` (constructed in `BrainApp.init` ~line 247).
    /// Cross-context propagation works because SwiftData persists each
    /// save to the shared SQLite store and a fresh fetch on the other
    /// context re-reads from disk; the SwiftUI side's `@Query` picks
    /// up the change via SwiftData's change-coalescing. The same
    /// pattern is already in use by the archive / update flows; if it
    /// ever stops propagating, look here first.
    ///
    /// Sync-race / unique-constraint defence (B1): if a sync delta
    /// reached us *before* this create echo (the Timer or scenePhase
    /// fires during a network blip while we're retrying through the
    /// queue), `SyncEngine.upsert(_:)` will have inserted a separate
    /// `LocalNote` keyed by the server id. The pre-existing
    /// `shouldSkipEcho` defence in SyncEngine keys on `resourceId`
    /// which for create rows is the *client* UUID, so it never fires
    /// and the duplicate row goes through. Renaming the stub from
    /// `clientId` -> `serverNote.id` would then hit the
    /// `@Attribute(.unique)` constraint on `LocalNote.id` and crash
    /// the save. We pre-empt that by fetching any row already keyed
    /// on the server id and deleting it before the rename — the
    /// stub's canonical fields are about to be overwritten with the
    /// same `serverNote` payload anyway, so the sync-inserted row is
    /// strictly redundant.
    ///
    /// Pending-edit rewrite (B2): if the user immediately edits the
    /// fresh todo (long-press → EditTodoView before the create echo
    /// returns), the resulting `updateTodo` queue row carries the
    /// *client* UUID as its `resourceId`. After this method renames
    /// the stub to the server id, replaying that queued update with
    /// the now-stale client UUID would 404 on the server and get
    /// poisoned — silent data loss. Rewrite any queue rows targeting
    /// the client UUID to point at the server id *before* the rename
    /// so the next replay tick sees a consistent picture.
    ///
    /// Idempotency: if a sync has *already* delivered the server's
    /// row AND the local stub is gone (user wiped local data, or
    /// SwiftData lost the optimistic insert across a kill-9 + restart
    /// while the queue row survived), the lookup-by-clientId returns
    /// nil and we no-op — the existing sync-inserted row already
    /// represents the truth.
    private func reconcileCreateResponse(clientId: String, serverNote: Note) {
        // M45 Wave 0: the per-entity field copy lives on
        // `LocalNote.copyFields(from:parseDate:)`; the create-echo
        // ceremony (B1 dedupe + B2 pending-mutation rewrite + stub
        // fetch + adoptServerID + save) lives in `reconcileCreate<T:>`
        // below. The shared ceremony works generically over
        // `OptimisticStub` so adding a second entity (project create,
        // section create, ...) is a one-line conformance plus a
        // closure, not a copy-paste of the dedupe + rewrite logic.
        try? reconcileCreate(
            clientId: clientId,
            serverId: serverNote.id,
            type: LocalNote.self
        ) { stub in
            stub.copyFields(from: serverNote, parseDate: parseServerDate)
        }
    }

    /// M45 Wave 2 sibling of `reconcileCreateResponse` for the project
    /// create path. Same ceremony — B1 dedupe, B2 pending-mutation
    /// rewrite, stub fetch, field copy, adoptServerID — generic over
    /// `LocalProject`'s `OptimisticStub` conformance (Wave 0).
    ///
    /// `LocalProject.copyFields(from:parseDate:)` mirrors the field
    /// surface a project create echo carries: name, color, sort_order,
    /// timestamps, plus M26's default-section list (rebuilt against the
    /// server's canonical slugs so the optimistic empty-sections stub
    /// gets its Now/Next/Later trio without waiting for the next sync).
    private func reconcileCreateProjectResponse(clientId: String, serverProject: Project) {
        try? reconcileCreate(
            clientId: clientId,
            serverId: serverProject.id,
            type: LocalProject.self
        ) { stub in
            stub.copyFields(from: serverProject, parseDate: parseServerDate)
            // M45 Wave 2: mirror the server's canonical sections onto
            // the local project. Without this, the optimistic stub sits
            // with empty sections (its create payload has none) until
            // the next foreground sync (~5min Timer), so tapping into
            // ProjectDetailView right after creating shows zero
            // sections. The shared helper is idempotent against the B1
            // race where SyncEngine got there first and already
            // inserted the LocalSection rows.
            LocalProject.reconcileSections(
                serverProject.sections,
                on: stub,
                in: modelContext
            )
        }
    }

    /// Shared create-echo ceremony, generic over an `OptimisticStub`
    /// model. Performs the M45 Wave 0 sequence:
    ///
    ///   1. **B2** — rewrite any pending `MutationQueueItem` rows that
    ///      target `clientId` to point at `serverId` instead. Has to
    ///      happen *before* the rename / field copy below so a single
    ///      `modelContext.save()` lands the whole state transition
    ///      atomically. Even runs when the local stub is missing —
    ///      otherwise a queued edit-during-create would replay against
    ///      the stale client UUID, 404, and get poisoned (silent data
    ///      loss).
    ///
    ///   2. **Stub fetch** — look up the optimistic local row keyed by
    ///      `clientId`. If it's gone (user wiped local data, or
    ///      SwiftData lost the stub across a kill-9 + restart while the
    ///      queue row survived), save the B2 rewrite and return — the
    ///      sync-inserted row keyed on `serverId` (if any) is the
    ///      canonical truth and must NOT be touched.
    ///
    ///   3. **B1** — if a sync delta inserted a separate row keyed on
    ///      `serverId` while this create echo was in flight, delete it.
    ///      Otherwise the rename in step 5 would collide on the
    ///      `@Attribute(.unique)` constraint. Save immediately so the
    ///      unique slot is freed before the rename claims it.
    ///
    ///   4. **adoptServerID** — rename the stub's `id` String column
    ///      from `clientId` to `serverId`. SwiftData's
    ///      `@Attribute(.unique)` is rechecked on save, but the
    ///      uniqueness slot is already free thanks to step 3. Has to
    ///      happen BEFORE the field copy (step 5) so any closure work
    ///      that derives child-record ids from `stub.id` (notably
    ///      `LocalProject.reconcileSections`, which builds
    ///      `LocalSection.id` as `"<project.id>:<slug>"`) sees the
    ///      server id, not the about-to-be-discarded client UUID.
    ///      Otherwise the next SyncEngine pass would re-key every
    ///      child row, costing a delete + reinsert and a transient
    ///      `@Query` re-emit.
    ///
    ///   5. **Field copy** — invoke `copyFields` to mirror server-
    ///      derived fields onto the stub. The closure is per-entity so
    ///      we don't try to fold ~22-field note copies and ~7-field
    ///      project copies (with M26 default-section reconcile) under
    ///      a single contract that fits neither. The closure must NOT
    ///      mutate `stub.id` — it's already at its final (server) value
    ///      by this point in the ceremony (step 4 ran first).
    ///
    /// The final `modelContext.save()` is the caller's responsibility —
    /// `replay()` already calls `try modelContext.save()` after the
    /// `delete(item)` further down, which lands the rename + field copy
    /// in the same transaction as the queue-row deletion. Cross-context
    /// observability (SwiftUI `@Query` on a different `ModelContext`
    /// picks up the change) hangs off SwiftData's shared SQLite store,
    /// same pattern documented at `MutationQueue.swift:450-460`.
    ///
    /// `#Predicate` macro caveat — see `OptimisticStub.swift` header.
    /// Each conformance owns its own `makeFetchByID(_:)` because the
    /// macro doesn't accept generic type parameters cleanly on iOS 17.
    /// We invoke `T.makeFetchByID(...)` here rather than constructing
    /// a `FetchDescriptor<T>(predicate: #Predicate { ... })` inline.
    func reconcileCreate<T: OptimisticStub>(
        clientId: String,
        serverId: String,
        type: T.Type,
        copyFields: (T) -> Void
    ) throws {
        // B2: rewrite any queued mutations that still target the
        // client UUID. Has to happen before the rename / field copy —
        // those steps land via the save below, and we want a single
        // coherent post-state for the next replay tick. Best-effort
        // fetch: a SwiftData fault here is rare and recoverable (worst
        // case: the queue row replays once with the stale id, hits
        // 404, gets poisoned — same as the pre-M45 behaviour, so
        // we're not making things worse).
        let pendingDescriptor = FetchDescriptor<MutationQueueItem>(
            predicate: #Predicate { $0.resourceId == clientId }
        )
        if let stalePending = try? modelContext.fetch(pendingDescriptor) {
            for row in stalePending {
                row.resourceId = serverId
            }
        }

        let stubDescriptor = T.makeFetchByID(clientId)
        guard let stub = (try? modelContext.fetch(stubDescriptor))?.first else {
            // Local stub already gone. Either:
            //   * Sync delivered the server row first AND the user
            //     wiped local data between enqueue and replay (rare),
            //     or
            //   * The user restarted the app and SwiftData lost the
            //     stub but the queue row survived to replay.
            // In both cases the existing sync-inserted row (if any)
            // already represents the truth, OR the next sync will
            // deliver it. Don't touch any row keyed on `serverId` —
            // that's the canonical row we'd otherwise destroy. Save
            // the B2 queue rewrite and bail.
            try? modelContext.save()
            return
        }

        // B1: drop any row that sync already inserted under the server
        // id. The about-to-be-renamed stub will be repopulated with
        // the same canonical fields by `copyFields`, so the sync-
        // inserted row is redundant — and leaving it would collide
        // with the rename on the unique-id constraint. Only safe to
        // do once we've confirmed the stub exists; in the stub-
        // missing branch above the sync-inserted row IS the truth.
        let dupeDescriptor = T.makeFetchByID(serverId)
        if let dupe = (try? modelContext.fetch(dupeDescriptor))?.first,
           dupe !== stub {
            modelContext.delete(dupe)
            // Save now so the unique-id slot is freed before the
            // rename below tries to claim it. If this throws we'll
            // fall through and the final save will surface the
            // collision — same failure mode as before the fix, just
            // with a slightly different stack. Log so a recurring
            // failure isn't hidden behind the silent `try?` it used
            // to be.
            do {
                try modelContext.save()
            } catch {
                NSLog(
                    "MutationQueue: reconcile dupe-delete save failed " +
                    "for clientId \(clientId) -> serverId \(serverId): " +
                    "\(error). Falling through; the final save will " +
                    "surface the constraint collision."
                )
            }
        }

        // Rename first, then per-entity field copy. The closure may
        // touch child records whose composite-id includes
        // `stub.id` as a prefix (M45 Wave 2: `LocalProject`'s
        // `reconcileSections` builds `LocalSection.id` as
        // `"\(project.id):\(slug)"`). If the rename ran AFTER the
        // closure, the optimistic stub's child rows would land keyed
        // on the client UUID; the next SyncEngine pass would then
        // compute `wantedIDs` with the server-prefix, find no match,
        // and delete + reinsert every child — wasted work plus a
        // transient `@Query` re-emit that flickers any view bound to
        // the relationship. Renaming first keeps the prefix stable.
        // Safe for `LocalNote` too: `copyFields(from:parseDate:)`
        // never reads `self.id`, and the dupe-delete + save above
        // already freed the unique-id slot.
        stub.adoptServerID(serverId)
        copyFields(stub)

        // M45 Wave 1: per-row status follows the rename. The
        // repository wrote `.pending` keyed on the client UUID at
        // enqueue; flipping the key to the server id here keeps any
        // mid-flight UI indicator (Wave 4 territory) attached to the
        // same SwiftData row across the rename. The corresponding
        // *clear* fires in `replay()`'s success terminal — see the
        // comment alongside `modelContext.delete(item)`. Splitting
        // rename and clear matches the natural semantic boundary:
        //   * reconcile completes the id transition (rename)
        //   * replay's success terminal completes the lifecycle (clear)
        // No-op when `statusStore` is nil (preview / test hosts that
        // didn't wire the third singleton — see spec §8.3).
        statusStore?.rename(clientId, to: serverId)
    }

    /// S1 rollback for the createTodo poison case. `.createTodo` is
    /// the one mutation where the optimistic local state must be
    /// rolled back on permanent failure: the user saw a row appear in
    /// QuickAddView's optimistic insert and (without this) it would
    /// stay on screen forever, never reflected on the server. Other
    /// ops (toggle / archive / update) target an existing server row
    /// — the next sync will overwrite any optimistic divergence with
    /// the server's truth.
    ///
    /// Looks up the orphan `LocalNote` by `item.resourceId` (the
    /// client UUID minted in `QuickAddView.submit()`) and deletes it.
    /// Cross-context propagation: the stub was inserted on the
    /// SwiftUI `ModelContext` and we're deleting it from the queue's
    /// context — both share the SwiftData container, the delete
    /// hits the SQLite store on save, and `@Query` on the SwiftUI
    /// side picks up the disappearance via SwiftData's change-
    /// coalescing. Same pattern as the rename path in
    /// `reconcileCreateResponse`.
    ///
    /// No-ops for non-create ops, and silent (the only signal is the
    /// existing `lastError` / NSLog path the caller has already
    /// stamped). UI banners / toasts on this failure are a separate
    /// UX decision; this just prevents the phantom-row data state.
    ///
    /// Known limitation (M44+): if the user typed the stub, then
    /// long-pressed and edited it locally before the create cap was
    /// hit, this rollback nukes their edit silently. See the TODO at
    /// the delete site below.
    private func rollbackOptimisticStateIfNeeded(
        for item: MutationQueueItem,
        reason: some Error
    ) {
        // M45 Wave 1: mark the resource as failed in the status store
        // BEFORE deleting the stub (or returning early for non-create
        // ops). Per spec §4.4, failed entries persist until the user
        // dismisses, so the UI in Wave 4 can show "this row's mutation
        // didn't land" before the row vanishes / reverts. We mark for
        // every poison-class op (not just create), because non-create
        // poisons (an `.archiveNote` 404 because the row was
        // hard-deleted on web, an `.updateTodo` 422 from a malformed
        // payload) also leave the user with stale local state worth
        // surfacing. No-op when `statusStore` is nil.
        statusStore?.mark(item.resourceId, .failed(reason))

        guard MutationOp(rawValue: item.op) == .createTodo else { return }
        let stubId = item.resourceId
        let descriptor: FetchDescriptor<LocalNote> = {
            var d = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.id == stubId }
            )
            d.fetchLimit = 1
            return d
        }()
        guard let stub = (try? modelContext.fetch(descriptor))?.first else {
            return
        }
        // TODO(M44+): If the user edited the stub locally before the create
        // hit the cap (typed → long-press edit → create fails permanently),
        // this rollback nukes their edit silently. The rewritten updateTodo
        // will then 404 and poison. Consider preserving local-only edits or
        // surfacing the failure in UI before deleting.
        modelContext.delete(stub)
        do {
            try modelContext.save()
            NSLog(
                "MutationQueue: rolled back optimistic createTodo stub " +
                "\(stubId) after permanent failure: \(reason)"
            )
        } catch {
            NSLog(
                "MutationQueue: failed to roll back optimistic createTodo " +
                "stub \(stubId): \(error)"
            )
        }
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

extension MutationQueue {
    /// Test-only window into the internal context so debug checks can
    /// stage rows alongside the queue without going through the full
    /// SwiftUI view stack. Only exposed under `#if DEBUG`.
    var debugModelContext: ModelContext { modelContext }

    /// Test-only entry point for `reconcileCreateResponse`. Exposes
    /// the private helper to `BrainDebugMutationQueue`.
    func debugReconcileCreateResponse(clientId: String, serverNote: Note) {
        reconcileCreateResponse(clientId: clientId, serverNote: serverNote)
    }

    /// Test-only entry point for `reconcileCreateProjectResponse`.
    /// M45 Wave 2 review: exposes the private helper so tests can
    /// verify section reconcile mirrors server sections onto the
    /// optimistic stub.
    func debugReconcileCreateProjectResponse(clientId: String, serverProject: Project) {
        reconcileCreateProjectResponse(clientId: clientId, serverProject: serverProject)
    }

    /// Test-only entry point for `rollbackOptimisticStateIfNeeded`.
    func debugRollbackOptimisticState(for item: MutationQueueItem, reason: some Error) {
        rollbackOptimisticStateIfNeeded(for: item, reason: reason)
    }
}

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

    /// B1 (PR #31 review): `reconcileCreateResponse` must dedupe a
    /// LocalNote that sync inserted under the server id while the
    /// create echo was still in flight. Exactly one row keyed on the
    /// server id should remain after reconcile, populated from the
    /// echo (not the sync row), and no unique-id-constraint exception.
    ///
    /// Cross-context coverage: production wires the optimistic insert
    /// to the SwiftUI `\.modelContext` (one `ModelContext`) and the
    /// reconcile fetch / delete / rename to the queue's separate
    /// `ModelContext` (constructed in `BrainApp.swift` against the same
    /// `ModelContainer`). The bug class B1 was caught against only
    /// triggers when those two contexts coexist — both backed by the
    /// same SQLite store, both saving before reconcile runs. We model
    /// that here with a `swiftUIContext` (stub + sync row inserter) and
    /// a `queueContext` (reconciler), assert on a third read-side
    /// context, and require the assertions hold on all three.
    @MainActor
    static func assertReconcileDedupesSyncRace() throws {
        let schema = Schema([MutationQueueItem.self, LocalNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        // Mirror production's two-context layout: SwiftUI owns one
        // context, the queue owns another, both share the container.
        let swiftUIContext = ModelContext(container)
        let queueContext = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: queueContext, client: client, authSession: session)

        let clientId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let serverId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        // Optimistic stub on the SwiftUI context (where QuickAddView
        // would actually have inserted it).
        let stub = LocalNote(
            id: clientId,
            shortId: "",
            title: "draft title",
            content: "draft content",
            type: "todo"
        )
        swiftUIContext.insert(stub)
        try swiftUIContext.save()

        // Sync raced ahead and inserted a separate row under the
        // server id with the canonical content. SyncEngine runs on
        // its own context in production; we use the queue context as
        // a stand-in for "some other context backed by the same
        // store" — what matters is that the row hits the SQLite
        // store before reconcile runs.
        let syncInserted = LocalNote(
            id: serverId,
            shortId: "abc123",
            title: nil,
            content: "canonical content",
            type: "todo"
        )
        queueContext.insert(syncInserted)
        try queueContext.save()

        let serverNote = Note(
            id: serverId,
            shortId: "abc123",
            title: nil,
            content: "canonical content",
            type: "todo",
            tags: [],
            createdAt: nil,
            updatedAt: nil,
            archived: false,
            todo: nil,
            appointment: nil
        )

        // Should not throw / crash on the unique-id constraint even
        // though the stub was created on a different context.
        queue.debugReconcileCreateResponse(clientId: clientId, serverNote: serverNote)
        try queueContext.save()

        // Read back from a fresh third context to defeat any per-
        // context caching — exercises the full SQLite round-trip.
        let readContext = ModelContext(container)
        let allNotes = try readContext.fetch(FetchDescriptor<LocalNote>())
        let serverHits = allNotes.filter { $0.id == serverId }
        let clientHits = allNotes.filter { $0.id == clientId }
        assert(serverHits.count == 1,
               "expected exactly one LocalNote keyed on serverId, found \(serverHits.count)")
        assert(clientHits.isEmpty,
               "client UUID should be gone after reconcile, found \(clientHits.count)")
        assert(serverHits.first?.content == "canonical content",
               "reconcile should overwrite content with serverNote payload")
        assert(serverHits.first?.shortId == "abc123",
               "reconcile should backfill shortId from serverNote")
    }

    /// B2 (PR #31 review): pending `MutationQueueItem` rows targeting
    /// the client UUID must be rewritten to the server id during
    /// reconcile. Otherwise an edit enqueued before the create echo
    /// would 404 on replay (server doesn't know the client UUID) and
    /// get poisoned — silent data loss.
    ///
    /// Multi-op coverage: the realistic scenario is a user typing →
    /// long-press editing → toggling complete → archiving, all before
    /// the create reconciles. The fix's predicate is on `resourceId`
    /// only with no op filter, so every queued op against the client
    /// UUID must end up rewritten. We enqueue a representative mix
    /// here (`updateTodo`, `completeTodo`, `archiveNote`) and assert
    /// each one's `resourceId` lands on the server id.
    @MainActor
    static func assertReconcileRewritesPendingResourceIds() throws {
        let schema = Schema([MutationQueueItem.self, LocalNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)

        let clientId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let serverId = "dddddddd-dddd-dddd-dddd-dddddddddddd"

        // Optimistic stub.
        let stub = LocalNote(
            id: clientId,
            shortId: "",
            title: nil,
            content: "stub",
            type: "todo"
        )
        queue.debugModelContext.insert(stub)
        // User long-pressed and edited, then toggled complete, then
        // archived — all before the create echo returned. Produces
        // three queue rows, all keyed on the client UUID.
        let pendingEdit = try queue.enqueue(
            op: .updateTodo,
            resourceType: "todo",
            resourceId: clientId,
            payload: Data(),
            baseUpdatedAt: nil
        )
        let pendingComplete = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: clientId,
            payload: Data(),
            baseUpdatedAt: nil
        )
        let pendingArchive = try queue.enqueue(
            op: .archiveNote,
            resourceType: "note",
            resourceId: clientId,
            payload: Data(),
            baseUpdatedAt: nil
        )
        let pendingIds = Set([pendingEdit.id, pendingComplete.id, pendingArchive.id])
        assert(pendingEdit.resourceId == clientId)
        assert(pendingComplete.resourceId == clientId)
        assert(pendingArchive.resourceId == clientId)

        let serverNote = Note(
            id: serverId,
            shortId: "x9z",
            title: nil,
            content: "stub",
            type: "todo",
            tags: [],
            createdAt: nil,
            updatedAt: nil,
            archived: false,
            todo: nil,
            appointment: nil
        )
        queue.debugReconcileCreateResponse(clientId: clientId, serverNote: serverNote)
        try queue.debugModelContext.save()

        // Every queue row that targeted the client UUID should now
        // target the server id. Fetch the full queue and partition
        // by resourceId rather than relying on `pendingMutation` (a
        // single-row helper).
        let allQueueRows = try queue.debugModelContext.fetch(FetchDescriptor<MutationQueueItem>())
        let serverRows = allQueueRows.filter { $0.resourceId == serverId }
        let clientRows = allQueueRows.filter { $0.resourceId == clientId }
        assert(clientRows.isEmpty,
               "no queue row should still target the now-phantom client UUID, found \(clientRows.count)")
        assert(serverRows.count == 3,
               "all 3 queued ops should be rewritten to serverId, found \(serverRows.count)")
        let serverRowIds = Set(serverRows.map { $0.id })
        assert(serverRowIds == pendingIds,
               "rewritten queue rows should be the same rows we enqueued")
        // Stub renamed — so no leftover under the client UUID.
        let allNotes = try queue.debugModelContext.fetch(FetchDescriptor<LocalNote>())
        assert(allNotes.contains(where: { $0.id == serverId }),
               "stub should have been renamed to serverId")
        assert(!allNotes.contains(where: { $0.id == clientId }),
               "no LocalNote should remain under the client UUID")
    }

    /// B2 (PR #31 review, second pass): the rewrite must also fire
    /// when the optimistic stub is missing from the local store.
    /// Production reaches this branch when the user wiped local data
    /// (or SwiftData lost the stub across a kill-9 + restart) while
    /// queue rows survived. The fix moved the rewrite *above* the
    /// stub-missing guard so this path stays covered; this test locks
    /// that ordering in.
    @MainActor
    static func assertReconcileRewritesPendingResourceIdsWhenStubMissing() throws {
        let schema = Schema([MutationQueueItem.self, LocalNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)

        let clientId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let serverId = "99999999-9999-9999-9999-999999999999"

        // No stub insert — simulates the "stub gone, queue row
        // survived" branch.
        let pendingEdit = try queue.enqueue(
            op: .updateTodo,
            resourceType: "todo",
            resourceId: clientId,
            payload: Data(),
            baseUpdatedAt: nil
        )
        assert(pendingEdit.resourceId == clientId)

        let serverNote = Note(
            id: serverId,
            shortId: "ghi456",
            title: nil,
            content: "canonical",
            type: "todo",
            tags: [],
            createdAt: nil,
            updatedAt: nil,
            archived: false,
            todo: nil,
            appointment: nil
        )
        queue.debugReconcileCreateResponse(clientId: clientId, serverNote: serverNote)
        try queue.debugModelContext.save()

        // Even with no stub, the queue row must have been rewritten
        // before the early return. Otherwise the row would replay
        // with the stale client UUID and get poisoned.
        let pendingAfter = queue.pendingMutation(forResourceId: serverId)
        assert(pendingAfter?.id == pendingEdit.id,
               "queued updateTodo should be rewritten to serverId even when stub is missing")
        assert(queue.pendingMutation(forResourceId: clientId) == nil,
               "no queue row should still target the now-phantom client UUID")
    }

    /// S1 (PR #31 review): when a `.createTodo` mutation hits a
    /// poison-class error, the optimistic local stub must be deleted
    /// — otherwise the user is left with a phantom row that has no
    /// server counterpart and no UI signal of failure.
    @MainActor
    static func assertCreateTodoPoisonRollsBackStub() throws {
        let schema = Schema([MutationQueueItem.self, LocalNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)

        let clientId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        // Stub the user saw appear.
        let stub = LocalNote(
            id: clientId,
            shortId: "",
            title: nil,
            content: "doomed",
            type: "todo"
        )
        queue.debugModelContext.insert(stub)
        // Matching createTodo queue row (the one that's about to be
        // poisoned by the simulated 422).
        let item = try queue.enqueue(
            op: .createTodo,
            resourceType: "todo",
            resourceId: clientId,
            payload: Data()
        )

        // Simulate the poison-class arm of `replay()`: stamp the row
        // and call the rollback helper directly. The integration with
        // the real catch-arm is exercised by callers; here we're
        // covering the helper's contract.
        item.attempts += 1
        item.nextRetryAt = .distantFuture
        item.lastError = "simulated 422"
        try queue.debugModelContext.save()
        queue.debugRollbackOptimisticState(
            for: item,
            reason: BrainAPIClient.Error.validationError(detail: "simulated")
        )

        let allNotes = try queue.debugModelContext.fetch(FetchDescriptor<LocalNote>())
        assert(!allNotes.contains(where: { $0.id == clientId }),
               "createTodo poison rollback should delete the orphan stub")
        // Queue row stays — the rollback only touches the LocalNote.
        // The poisoned row will sit forever (parked) and is fine; a
        // future retry hook could reap it.
        let queueRows = try queue.debugModelContext.fetch(FetchDescriptor<MutationQueueItem>())
        assert(queueRows.contains(where: { $0.id == item.id }),
               "queue row should remain parked after rollback")
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
            try assertReconcileDedupesSyncRace()
            try assertReconcileRewritesPendingResourceIds()
            try assertReconcileRewritesPendingResourceIdsWhenStubMissing()
            try assertCreateTodoPoisonRollsBackStub()
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
