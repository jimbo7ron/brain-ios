// MutationQueueItem.swift
// brain-ios
//
// Pending API mutation captured while offline (M37). The replayer in
// `MutationQueue` walks these in `createdAt` order and dispatches them
// to the server with `Idempotency-Key: idempotencyKey` on every attempt.
//
// Why a SwiftData @Model and not, say, a plain JSON file: durable storage
// alongside the read-path rows means a kill-9 mid-replay leaves the same
// queue intact for next launch, and queries (next-ready, count, sort by
// createdAt) come for free. Registering it in the same `Schema` list as
// the read models is a pure additive change — no existing rows reference
// this type, so no migration step is needed.
//
// Identity: `id` is a UUID minted at enqueue time and is the SwiftData
// primary key. `idempotencyKey` is a *separate* UUID, also minted once at
// enqueue, that ships in the `Idempotency-Key` header on every retry. The
// brain server (`brain/src/brain/idempotency.py`) caches the response by
// `(key, user_id, method, path)` for 24h, so the same key on the same
// route always returns the same outcome — replays after a network blip
// are safe.
//
// Lifecycle: created via `MutationQueue.enqueue(...)`, deleted by the
// replayer on a successful 2xx response, or mutated in place (attempts /
// nextRetryAt / lastError) on a recoverable failure so the next replay
// pass can back off appropriately.
//
// Caller responsibility: the model is intentionally stringly-typed on
// `op` and `resourceType` so SwiftData persistence is trivial. Type
// safety lives in `MutationOp` (the enum) and the dispatch switch in
// `BrainAPIClient.executeMutation(_:)` — convert between the enum and
// its raw string at the queue boundary, never inside views.

import Foundation
import SwiftData

@Model
final class MutationQueueItem {
    /// Stable primary key, minted once at enqueue. Used by SwiftData to
    /// dedupe within the store and as the externally-visible item id.
    @Attribute(.unique) var id: UUID

    /// The operation slug. Always set from `MutationOp.rawValue` at
    /// enqueue — the column type is `String` so SwiftData can persist it
    /// without a custom transformer, and so we can introduce new
    /// operations later without a schema migration. Decode back via
    /// `MutationOp(rawValue: op)` at dispatch time; an unknown slug
    /// indicates a downgrade and surfaces as a `notImplemented` error.
    var op: String

    /// Coarse resource bucket — "todo" | "project" | "section". Useful
    /// for queue inspection and (later) for collapsing duplicate
    /// mutations on the same resource. Not used by the dispatch path,
    /// which routes off `op` alone.
    var resourceType: String

    /// Server UUID of the target resource for update/complete/archive
    /// ops, OR a locally-minted UUID for create-then-replace flows where
    /// the server hasn't returned an id yet (M38 territory). Stringly-
    /// typed because it has to round-trip through both shapes.
    var resourceId: String

    /// JSON-encoded request body. The replayer hands this straight to
    /// `URLRequest.httpBody`; the dispatch site is responsible for
    /// matching the encoded shape to the `op` (typed structs in
    /// `DTOs.swift`).
    var payload: Data

    /// Wall-clock at enqueue. Sort key for FIFO replay — preserving
    /// caller order is what makes "edit todo, then archive it" land in
    /// the right sequence on the server.
    var createdAt: Date

    /// Idempotency-Key UUID. Sent as the header value on every replay,
    /// never rotated. The 24h TTL on the server's cache is far longer
    /// than any realistic offline window, so retries even after several
    /// hours of airplane-mode are safe.
    var idempotencyKey: UUID

    /// Number of replay attempts so far. Drives the backoff schedule in
    /// `MutationQueue.backoff(attempts:)`. Capped only by user patience —
    /// we never give up automatically, since the queued action represents
    /// real user intent.
    var attempts: Int

    /// Earliest time the next replay attempt may run. `nil` means
    /// ready-now (newly enqueued or just woken from a successful
    /// neighbour replay). Set after a recoverable failure so the queue
    /// honours exponential backoff between attempts. Compared against
    /// `Date()` in `nextReadyItem()`.
    var nextRetryAt: Date?

    /// Last server-side error message captured for debug surfaces. Not
    /// shown to end users — `MutationQueue.lastError` carries the
    /// user-facing copy. Optional because the happy path never sets it.
    var lastError: String?

    /// The server's `updated_at` for the target resource at the moment
    /// this mutation was enqueued (M38). Captured so the LWW conflict
    /// detector in `SyncEngine.applyRow` can compare incoming server
    /// rows against the base the user actually edited from.
    ///
    /// Optional for two reasons:
    ///   * Existing queue rows from M37 builds have no base — they get
    ///     `nil` after auto-migration. A `nil` base is treated as
    ///     "unknown" and falls through to the client-wins branch (i.e.
    ///     replay normally), which preserves the user's pre-M38 intent.
    ///   * Some create-flows (e.g. `.createTodo`) have no pre-existing
    ///     resource row, so there's no `updated_at` to capture. Those
    ///     stay `nil`; the conflict check finds nothing pending under
    ///     a not-yet-server-side id anyway.
    ///
    /// Schema note: this is an additive nullable field, which SwiftData
    /// auto-migrates without ceremony. The destructive-fallback in
    /// `BrainApp.init` is the safety net if a dev / TestFlight device's
    /// store somehow can't migrate cleanly.
    var baseUpdatedAt: Date?

    init(
        op: String,
        resourceType: String,
        resourceId: String,
        payload: Data,
        baseUpdatedAt: Date? = nil
    ) {
        self.id = UUID()
        self.op = op
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.payload = payload
        self.createdAt = Date()
        self.idempotencyKey = UUID()
        self.attempts = 0
        self.nextRetryAt = nil
        self.lastError = nil
        self.baseUpdatedAt = baseUpdatedAt
    }
}
