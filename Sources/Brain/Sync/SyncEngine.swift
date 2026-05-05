// SyncEngine.swift
// brain-ios
//
// Read-only sync orchestrator (M33). Owns the `GET /api/v1/sync` cursor
// loop: pulls the delta feed from the server, applies it to SwiftData,
// and persists the new `server_time` cursor so the next call resumes
// where this one left off.
//
// Threading model: `@MainActor` so we can mutate the SwiftData
// `ModelContext` (which prefers main-actor access) and publish state to
// SwiftUI without hopping. The HTTP work happens inside an `actor`
// (`BrainAPIClient`) so awaiting it doesn't block the main thread —
// SwiftUI keeps rendering while the request is in flight.
//
// Source of truth: SwiftData. Views observe `LocalProject` /
// `LocalNote` via `@Query`; this engine is the only thing that writes
// into them on the read path. M37 will add a separate replayer for
// outgoing mutations.
//
// Tombstones: server returns `tombstones.notes` and `tombstones.projects`
// as id arrays. We delete the matching local rows; section rows cascade
// out via the `LocalProject -> LocalSection` relationship rule.
//
// Cursor persistence: the cursor lives in a single `LocalSyncState` row
// keyed by `"default"`. It survives app relaunches because SwiftData
// fsyncs to disk; on first launch the row is absent, which surfaces as
// `nil` and triggers a full pull. The cursor advance and the upserts /
// deletes commit in the *same* `modelContext.save()` so we can never
// advance the cursor past data that didn't actually persist.
//
// Auth integration: on a 401 (revoked device key, expired creds, etc.)
// we wipe Keychain, clear the API client's key, stop the foreground
// Timer, and flip `AuthSession` back to `.signedOut`. ContentView
// re-renders into LoginView in the same render pass. We deliberately
// do NOT surface the API client's user-facing error string for 401 —
// that one is tuned for the login form ("That email and password didn't
// match…") and would be confusing on a background sync.
//
// Foreground Timer: lives here, not in the view, so its lifetime is
// tied to the engine (and ultimately the auth session) rather than to
// any view SwiftUI happens to instantiate. Kicks every 5 minutes;
// torn down on signedOut() so revocation doesn't leave an in-flight
// retry loop running.

import Foundation
import SwiftData
import SwiftUI

/// Drives `GET /api/v1/sync` and applies the response to SwiftData.
@MainActor
final class SyncEngine: ObservableObject {

    /// Sentinel key for the singleton `LocalSyncState` row. We keep it
    /// stringly-typed (rather than an enum) so a future multi-account
    /// world can mint per-account cursors without a schema migration.
    private static let cursorKey: String = "default"

    /// Foreground sync cadence. Matches the M33 spec; the 15-minute
    /// backgrounded cadence is a separate beast (M41).
    private static let foregroundInterval: TimeInterval = 300

    /// Debounce window for `sync()`. Collapses the .task + scenePhase +
    /// foreground Timer triple-trigger that fires on every foreground
    /// re-entry — a sync that completed less than this ago is skipped.
    /// Smaller than `foregroundInterval` so the periodic Timer still
    /// makes progress, but big enough to absorb the burst.
    private static let debounceInterval: TimeInterval = 30

    private let client: BrainAPIClient
    private let modelContext: ModelContext
    private let authSession: AuthSession

    /// Optional back-reference to the mutation queue. Set once via
    /// `attach(mutationQueue:)` after both engines are constructed —
    /// we can't pass it via init because `MutationQueue` itself doesn't
    /// exist yet at the moment `BrainApp` builds the SyncEngine. Two
    /// uses: (a) the foreground Timer fires `replay()` alongside
    /// `sync()` so queue draining isn't gated solely on `.task` /
    /// scenePhase; (b) on a 401 we wipe the queue so a re-sign-in by
    /// a different user can't replay the prior session's mutations.
    /// `weak` to avoid the engines retaining each other.
    private weak var mutationQueue: MutationQueue?

    /// Wall-clock timestamp of the last successful sync. Surfaces as a
    /// "Synced 2m ago" hint in the placeholder view; nil before the
    /// first successful pull this launch.
    @Published private(set) var lastSyncedAt: Date?

    /// True between the start and end of a `sync()` call. Exposed so
    /// views can render a spinner without having to track their own
    /// state.
    @Published private(set) var isSyncing: Bool = false

    /// User-facing copy for the most recent failure, or nil if the last
    /// attempt succeeded (or hasn't run yet). We deliberately overwrite
    /// rather than accumulating — surfacing only the latest error keeps
    /// the UI simple. 401 is *not* surfaced here because the engine
    /// flips the user back to LoginView; lingering an error on the
    /// already-replaced view would be misleading.
    @Published private(set) var lastError: String?

    /// Running count of inbound sync rows skipped because they were
    /// the echo of a pending mutation (M40 polish — when a queue item
    /// is in flight and a sync arrives before the queue replays, the
    /// server's row carries the *pre-edit* `updated_at` and applying
    /// it would briefly clobber the optimistic local state). Surfaced
    /// for observability — a future Settings panel / debug toast can
    /// render this. Reset on `handleUnauthorized()` so the count is
    /// meaningful per signed-in session, mirroring
    /// `MutationQueue.conflictsResolved`.
    @Published private(set) var echoSkips: Int = 0

    /// Foreground Timer. Started lazily on the first `sync()` call (so
    /// signed-out launches don't tick) and torn down in `signedOut()`.
    /// Held as `Timer` rather than the Combine publisher so we can
    /// invalidate it deterministically.
    private var foregroundTimer: Timer?

    init(client: BrainAPIClient, modelContext: ModelContext, authSession: AuthSession) {
        self.client = client
        self.modelContext = modelContext
        self.authSession = authSession
    }

    /// Wire the mutation queue back-reference. Called once from
    /// `BrainApp.init` after both engines are constructed. See
    /// `mutationQueue` for the rationale.
    func attach(mutationQueue: MutationQueue) {
        self.mutationQueue = mutationQueue
    }

    // Note: we deliberately do NOT invalidate the Timer in `deinit`.
    // `deinit` is nonisolated and Timer's `invalidate()` should be
    // called on the run loop the Timer is scheduled on (the main run
    // loop here) — calling it from a background-deinit would be wrong.
    // In practice the engine outlives the app process anyway because
    // `BrainApp` holds it as a `@StateObject`; on sign-out we tear the
    // Timer down explicitly in `handleUnauthorized()` /
    // `stopForegroundTimer()` rather than relying on dealloc.

    // MARK: - Public API

    /// Run a single sync pass: read the cursor, fetch the delta, apply
    /// it, persist the new cursor — all in one SwiftData transaction.
    /// Safe to call concurrently — the `isSyncing` guard de-dupes
    /// overlapping calls (e.g. the Timer firing while the foreground
    /// sync is still in flight) and a debounce guard collapses the
    /// .task + scenePhase + Timer triple-trigger after a foreground
    /// resume.
    func sync() async {
        guard !isSyncing else { return }

        // Debounce: if we synced very recently, skip. The Timer's
        // 5-minute cadence still runs, so we don't fall behind.
        if let lastSyncedAt = lastSyncedAt,
           Date().timeIntervalSince(lastSyncedAt) < Self.debounceInterval {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        // Start the foreground Timer on the first sync attempt of a
        // signed-in session. Idempotent — if it's already running
        // we leave it alone.
        startForegroundTimerIfNeeded()

        let cursor = currentCursor()
        do {
            let response = try await client.sync(since: cursor)
            // Apply + cursor advance happen in a single save() inside
            // applyAndAdvanceCursor. If save() throws, neither the data
            // nor the cursor moves — the next sync re-pulls the same
            // delta cleanly.
            try applyAndAdvanceCursor(response)
            lastSyncedAt = Date()
            lastError = nil
        } catch BrainAPIClient.Error.unauthorized {
            // 401 = the device's API key is no longer valid. Hand off
            // to the auth flow: wipe local creds, stop the loop, flip
            // the UI to LoginView. We don't show a "sync failed"
            // banner — the user's about to see the login screen, which
            // is the actionable surface.
            await handleUnauthorized()
        } catch let error as BrainAPIClient.Error {
            lastError = error.userFacingMessage
        } catch {
            // Catch-all for SwiftData save failures and the like. The
            // detail isn't actionable for end users — log-style copy is
            // fine here; a future milestone can wire this into a real
            // log sink.
            lastError = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Lifecycle

    /// Start the 5-minute foreground Timer, if it isn't already
    /// running. Tied to the engine's lifetime so signing out
    /// guarantees teardown.
    private func startForegroundTimerIfNeeded() {
        guard foregroundTimer == nil else { return }
        // Tolerance lets the system coalesce ticks with other timers,
        // saving battery. A 30-second tolerance on a 5-minute interval
        // is well within the spec's "approx 5 min" cadence.
        //
        // The Timer is scheduled on the current (main) run loop —
        // `startForegroundTimerIfNeeded` is `@MainActor`, so the
        // resulting Timer fires on the main thread. We still hop
        // through a Task so `sync()` (an async method) can await
        // properly, and `[weak self]` keeps a torn-down engine from
        // resurrecting itself.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.foregroundInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sync()
                // Drain any queued offline mutations on the same
                // cadence. The `.task` and scenePhase triggers in
                // `SignedInRootView` cover startup and foreground
                // re-entry; this Timer is the third path that fires
                // while the app stays in the foreground for >5
                // minutes (e.g. user is reading a long note).
                await self?.mutationQueue?.replay()
            }
        }
        timer.tolerance = 30
        foregroundTimer = timer
    }

    /// Tear down the foreground Timer. Called on 401-handoff so the
    /// post-sign-out app doesn't keep firing sync attempts with a
    /// nil API key.
    private func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    /// 401 handoff. Order: stop the Timer (no more retries), wipe
    /// the mutation queue (cross-tenant safety — a re-sign-in might
    /// be a different user), wipe Keychain (revokes the local copy
    /// of the dead key), clear the API client's in-memory key (so
    /// any in-flight tail callers don't immediately re-401), then
    /// flip AuthSession to `.signedOut` (which causes ContentView to
    /// render LoginView). Cursor stays put — when the user signs
    /// back in, sync resumes from the same point. Clean
    /// `lastError = nil` because the user is about to see LoginView,
    /// not the sync status pill.
    private func handleUnauthorized() async {
        stopForegroundTimer()
        mutationQueue?.clear()
        try? KeychainStore.wipe()
        await client.setApiKey(nil)
        authSession.signedOut()
        lastError = nil
        lastSyncedAt = nil
        // Reset the echo-skip counter so it's meaningful per signed-in
        // session, mirroring `MutationQueue.conflictsResolved`.
        echoSkips = 0
    }

    // MARK: - Cursor

    /// Read the persisted `server_time` cursor, if any. Returns nil on
    /// first launch (and after a deliberate reset) which the server
    /// interprets as "send everything".
    private func currentCursor() -> String? {
        let descriptor = cursorFetchDescriptor()
        let existing = (try? modelContext.fetch(descriptor))?.first
        return existing?.lastServerTime
    }

    /// Stage the new cursor row (insert or mutate) without saving.
    /// The save happens in `applyAndAdvanceCursor` so the cursor
    /// advance and the upsert/delete batch commit atomically.
    private func stageCursor(_ serverTime: String) {
        let descriptor = cursorFetchDescriptor()
        let existing = (try? modelContext.fetch(descriptor))?.first
        let now = Date()
        if let existing = existing {
            existing.lastServerTime = serverTime
            existing.lastSyncAt = now
        } else {
            let row = LocalSyncState(
                key: Self.cursorKey,
                lastServerTime: serverTime,
                lastSyncAt: now
            )
            modelContext.insert(row)
        }
    }

    private func cursorFetchDescriptor() -> FetchDescriptor<LocalSyncState> {
        let key = Self.cursorKey
        var descriptor = FetchDescriptor<LocalSyncState>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    // MARK: - Apply

    /// Drop the server response into SwiftData and advance the cursor
    /// in the same transaction. Order matters: we apply upserts first
    /// (so any rows referenced by tombstones in the same payload would
    /// already exist) and then deletes. The server should never return
    /// a row in both `projects` and `tombstones.projects` for the same
    /// id, but the upsert-then-delete order makes the behaviour
    /// predictable if it ever does.
    ///
    /// Per-row order: (1) conflict-drop check (server strictly newer
    /// than the queue item's base — drop the queued mutation), then
    /// (2) echo-skip check (server's `updated_at` equals the queue
    /// item's `baseUpdatedAt` — server hasn't yet seen our pending
    /// edit; the row would clobber the optimistic local state), then
    /// (3) upsert. Steps 1 and 2 are mutually exclusive — they're
    /// gated on different inequalities on the same pair of timestamps
    /// — but we run them in this fixed order so a misbehaving server
    /// (e.g. one that didn't bump `updated_at` on a remote write)
    /// can't sneak past both gates.
    ///
    /// The single `save()` at the end commits the data deltas AND the
    /// cursor row together. If it throws, neither is persisted — the
    /// next sync will re-pull the same payload starting from the
    /// previous cursor, which is safe because all the operations are
    /// idempotent (upsert by id, delete-if-exists).
    private func applyAndAdvanceCursor(_ response: SyncResponse) throws {
        for project in response.projects {
            let serverUpdatedAt = parseDate(project.updatedAt)
            resolveConflictIfNeeded(
                resourceId: project.id,
                serverUpdatedAt: serverUpdatedAt
            )
            if shouldSkipEcho(resourceId: project.id, serverUpdatedAt: serverUpdatedAt) {
                continue
            }
            upsert(project)
        }
        for note in response.notes {
            let serverUpdatedAt = parseDate(note.updatedAt)
            resolveConflictIfNeeded(
                resourceId: note.id,
                serverUpdatedAt: serverUpdatedAt
            )
            if shouldSkipEcho(resourceId: note.id, serverUpdatedAt: serverUpdatedAt) {
                continue
            }
            upsert(note)
        }
        for projectID in response.tombstones.projects {
            deleteProject(id: projectID)
        }
        for noteID in response.tombstones.notes {
            deleteNote(id: noteID)
        }
        // Stage the cursor advance into the same pending change set.
        // SwiftData's save() commits everything together.
        stageCursor(response.serverTime)
        try modelContext.save()
    }

    // MARK: - Echo skip (M40 polish)

    /// Detect the optimistic-edit echo case and tell the apply step to
    /// skip overwriting the local row. Triggered when the user just
    /// queued an edit (so a `MutationQueueItem` exists for the same
    /// resource with a `baseUpdatedAt`) and an inbound sync fires
    /// before the queue replay completes — the server's row still
    /// reflects the pre-edit state (`server.updated_at ==
    /// pending.baseUpdatedAt`), and applying it would briefly
    /// overwrite the user's optimistic UI until the replay finishes.
    ///
    /// Compared to `resolveConflictIfNeeded`, which fires on
    /// `server.updated_at > pending.baseUpdatedAt` (server strictly
    /// newer — drop the queued mutation), this fires on equality
    /// (server hasn't moved — keep the queued mutation AND skip the
    /// apply). The two are mutually exclusive, so the fixed
    /// conflict-then-echo ordering in `applyAndAdvanceCursor` is
    /// safe.
    ///
    /// False-positive analysis: the only way `server.updated_at`
    /// could equal `pending.baseUpdatedAt` while genuinely carrying
    /// the user's edit is if the server failed to bump `updated_at`
    /// on a write — that would be a server bug, and the next sync
    /// after the queue replay completes would correct any drift
    /// anyway (the row will then carry a strictly-greater
    /// `updated_at` from the replayed mutation).
    ///
    /// `echoSkips` is incremented for observability — surfacing how
    /// often this fires in practice helps catch a misbehaving server
    /// early. It mirrors the `conflictsResolved` counter on the
    /// queue.
    private func shouldSkipEcho(resourceId: String, serverUpdatedAt: Date?) -> Bool {
        guard let queue = mutationQueue else { return false }
        guard let serverUpdatedAt else { return false }
        guard let pending = queue.pendingMutation(forResourceId: resourceId) else { return false }
        guard let baseUpdatedAt = pending.baseUpdatedAt else { return false }
        guard baseUpdatedAt == serverUpdatedAt else { return false }
        echoSkips += 1
        return true
    }

    // MARK: - 401 handoff (public surface)

    /// Public entry point for the 401-handoff flow. Used by view-layer
    /// code (e.g. `TodoRow.toggle()`) that hits an `unauthorized`
    /// response on a direct-to-API call and wants to surface the
    /// sign-out immediately rather than waiting up to 5 minutes for
    /// the next sync tick to detect the revoked key. Mirrors the
    /// internal `handleUnauthorized()` post-conditions: stop the
    /// Timer, wipe the queue, wipe Keychain, clear the API client's
    /// in-memory key, flip AuthSession to `.signedOut`.
    func signOutDueToUnauthorized() async {
        await handleUnauthorized()
    }

    // MARK: - Conflict resolution (M38)

    /// LWW (last-write-wins) conflict check. Called for every inbound
    /// resource row before its local state is overwritten. If the
    /// queue holds a pending mutation against the same resource AND
    /// the server's row is strictly newer than the base the user
    /// edited from AND newer than when the user made the edit, the
    /// queue item is dropped — replaying it would clobber the newer
    /// server state.
    ///
    /// Conditions in detail:
    ///   * `serverUpdatedAt` must be present. Without it we can't
    ///     compare timestamps; fall through to client-wins.
    ///   * `baseUpdatedAt` must be present on the queue item. A nil
    ///     base is "unknown" (M37 row, or a create op) — we can't
    ///     prove the server moved past it, so fall through to
    ///     client-wins.
    ///   * `serverUpdatedAt > baseUpdatedAt`: the server has changed
    ///     since the user started their edit. Without this, the
    ///     incoming row could just be the echo of the user's own
    ///     queued mutation having already been applied (race between
    ///     sync and replay). Echoes carry `updated_at == baseUpdatedAt`
    ///     in the absence of a server-side modification.
    ///   * `serverUpdatedAt > createdAt`: belt-and-braces. If the
    ///     server's row is older than the queue entry, the user's
    ///     edit happened *after* whatever produced this server row —
    ///     client wins.
    ///
    /// All four must hold to drop. Any one failing leaves the queue
    /// item in place and lets the replayer run normally — at worst
    /// the server rejects or no-ops the request, which is the M37
    /// failure path we already handle.
    ///
    /// Always-after-apply: the server row is applied to local state
    /// regardless. The user's optimistic UI update gets overwritten
    /// by the server's truth in the same transaction. That's the
    /// "lose one side of a simultaneous edit" trade-off documented in
    /// the M38 spec — single-user app, acceptable.
    private func resolveConflictIfNeeded(resourceId: String, serverUpdatedAt: Date?) {
        guard let queue = mutationQueue else { return }
        guard let serverUpdatedAt else { return }
        guard let pending = queue.pendingMutation(forResourceId: resourceId) else { return }
        guard let baseUpdatedAt = pending.baseUpdatedAt else { return }
        guard serverUpdatedAt > baseUpdatedAt,
              serverUpdatedAt > pending.createdAt else { return }
        queue.dropPendingMutation(pending)
    }

    // MARK: - Project upsert

    /// Insert or update a `LocalProject` from the wire DTO. Section
    /// reconciliation happens in `reconcileSections(...)` so we don't
    /// muddle two unrelated diffs in one method.
    private func upsert(_ project: Project) {
        let id = project.id
        var descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(descriptor))?.first

        let createdAt = parseDate(project.createdAt)
        let updatedAt = parseDate(project.updatedAt)

        let local: LocalProject
        if let existing = existing {
            existing.shortId = project.shortId
            existing.name = project.name
            existing.color = project.color
            existing.sortOrder = project.sortOrder
            existing.archived = project.archived
            existing.createdAt = createdAt
            existing.updatedAt = updatedAt
            local = existing
        } else {
            local = LocalProject(
                id: project.id,
                shortId: project.shortId,
                name: project.name,
                color: project.color,
                sortOrder: project.sortOrder,
                archived: project.archived,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            modelContext.insert(local)
        }

        reconcileSections(project.sections, on: local)
    }

    /// Bring the project's local section list into agreement with the
    /// wire payload. Any local section whose id is not in the wire set
    /// is deleted (the server only emits the canonical set per project,
    /// so anything missing locally got removed server-side). Existing
    /// sections are mutated in place; new ones are inserted.
    private func reconcileSections(_ wireSections: [SectionDTO], on project: LocalProject) {
        let projectID = project.id
        let wantedIDs = Set(wireSections.map { LocalSection.makeID(projectID: projectID, slug: $0.slug) })

        // Delete sections that no longer exist server-side. The server
        // only returns the canonical section list per project, so the
        // absence of a slug means it was removed upstream.
        for existing in project.sections where !wantedIDs.contains(existing.id) {
            modelContext.delete(existing)
        }

        // Upsert each wire section. Build a slug -> local lookup once
        // (keyed off the post-delete state) so the inner loop stays
        // O(1) per wire entry — a per-section fetch would be O(n*m).
        // Note that `project.sections` may still include rows we just
        // marked for deletion; SwiftData removes them on save. The
        // slug-set check above guarantees those rows aren't picked up
        // here because their slug isn't in `wantedIDs`.
        let currentBySlug = Dictionary(
            project.sections
                .filter { wantedIDs.contains($0.id) }
                .map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for wire in wireSections {
            if let local = currentBySlug[wire.slug] {
                local.name = wire.name
                local.position = wire.position
            } else {
                let composite = LocalSection.makeID(projectID: projectID, slug: wire.slug)
                let local = LocalSection(
                    id: composite,
                    slug: wire.slug,
                    name: wire.name,
                    position: wire.position,
                    project: project
                )
                modelContext.insert(local)
            }
        }
    }

    // MARK: - Note upsert

    /// Insert or update a `LocalNote` from the wire DTO. The single
    /// `LocalNote` shape carries todo/appointment fields inline, mirroring
    /// the server's flattened `NoteResponse`.
    private func upsert(_ note: Note) {
        let id = note.id
        var descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(descriptor))?.first

        let createdAt = parseDate(note.createdAt)
        let updatedAt = parseDate(note.updatedAt)
        // Tags ride as a comma-separated string in SwiftData — matches the
        // schema field name. Encoding here keeps the choice of separator
        // in one place.
        let tagsCSV = note.tags.joined(separator: ",")

        let todo = note.todo
        let appointment = note.appointment

        if let existing = existing {
            existing.shortId = note.shortId
            existing.title = note.title
            existing.content = note.content
            existing.type = note.type
            existing.archived = note.archived
            existing.createdAt = createdAt
            existing.updatedAt = updatedAt
            existing.tagsCSV = tagsCSV
            existing.dueDate = todo?.dueDate
            existing.dueTime = todo?.dueTime
            existing.completed = todo?.completed ?? false
            existing.completedAt = parseDate(todo?.completedAt)
            existing.priority = todo?.priority ?? "medium"
            existing.recurrence = todo?.recurrence ?? appointment?.recurrence
            existing.projectId = todo?.projectId
            existing.section = todo?.section
            existing.url = todo?.url
            existing.urlTitle = todo?.urlTitle
            existing.urlState = todo?.urlState
            existing.urlFetchedAt = parseDate(todo?.urlFetchedAt)
            existing.sortOrder = todo?.sortOrder ?? 0
            existing.appointmentStartTime = appointment?.startTime
            existing.appointmentEndTime = appointment?.endTime
            existing.appointmentLocation = appointment?.location
            existing.appointmentRecurrence = appointment?.recurrence
        } else {
            let local = LocalNote(
                id: note.id,
                shortId: note.shortId,
                title: note.title,
                content: note.content,
                type: note.type,
                archived: note.archived,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tagsCSV: tagsCSV,
                dueDate: todo?.dueDate,
                dueTime: todo?.dueTime,
                completed: todo?.completed ?? false,
                completedAt: parseDate(todo?.completedAt),
                priority: todo?.priority ?? "medium",
                recurrence: todo?.recurrence ?? appointment?.recurrence,
                projectId: todo?.projectId,
                section: todo?.section,
                url: todo?.url,
                urlTitle: todo?.urlTitle,
                urlState: todo?.urlState,
                urlFetchedAt: parseDate(todo?.urlFetchedAt),
                sortOrder: todo?.sortOrder ?? 0,
                appointmentStartTime: appointment?.startTime,
                appointmentEndTime: appointment?.endTime,
                appointmentLocation: appointment?.location,
                appointmentRecurrence: appointment?.recurrence
            )
            modelContext.insert(local)
        }
    }

    // MARK: - Tombstones

    private func deleteNote(id: String) {
        var descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        if let target = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(target)
        }
    }

    private func deleteProject(id: String) {
        var descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        if let target = (try? modelContext.fetch(descriptor))?.first {
            // Sections cascade-delete via the relationship rule on
            // LocalProject.sections, so we don't have to chase them
            // ourselves.
            modelContext.delete(target)
        }
    }

    // MARK: - Date parsing

    /// Parse a server ISO-8601 string into a `Date`. The server emits
    /// fractional-seconds variants (e.g. `2026-04-29T12:00:00.123456Z`)
    /// for some timestamps and integer-second variants for others, so
    /// we try both formatters in order. Returns nil for missing or
    /// unparseable input — the SwiftData column is optional, so
    /// downstream code already tolerates that.
    private func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if let date = Self.isoFractional.date(from: raw) {
            return date
        }
        return Self.isoBasic.date(from: raw)
    }

    /// Cached because ISO8601DateFormatter is relatively expensive to
    /// build and we hit it for every timestamp on every sync.
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
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `SyncEngine` instance via
/// `@Environment(\.syncEngine)`. Wired the same way as
/// `\.brainAPIClient` (M31/M32) so the two singletons stay symmetrical.
private struct SyncEngineKey: EnvironmentKey {
    static let defaultValue: SyncEngine? = nil
}

extension EnvironmentValues {
    var syncEngine: SyncEngine? {
        get { self[SyncEngineKey.self] }
        set { self[SyncEngineKey.self] = newValue }
    }
}

// MARK: - Debug-only sanity checks

#if DEBUG

/// Documentation-grade smoke checks for the sync apply path. No XCTest
/// target exists yet — these mirror the `BrainDebugMutationQueue`
/// shape so a future CI hook running `BrainDebugSyncEngine.runAll()`
/// would catch the obvious regressions.
enum BrainDebugSyncEngine {

    /// Build an in-memory SwiftData container wired with the schema
    /// the engines expect. Shared across the checks below.
    @MainActor
    private static func makeContext() throws -> ModelContext {
        let schema = Schema([
            LocalProject.self,
            LocalSection.self,
            LocalNote.self,
            LocalSyncState.self,
            MutationQueueItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// Build a `Date` truncated to whole seconds, offset from now by
    /// `seconds`. Whole-second precision matters for these checks
    /// because `ServerDateChecks.formatForWire` parses on
    /// `.withInternetDateTime` (no fractional component), so a
    /// fractional input would round-trip to a different `Date` than
    /// the one passed in and the equality assertion in
    /// `shouldSkipEcho` would miss.
    private static func wholeSecondDate(secondsFromNow seconds: TimeInterval) -> Date {
        let raw = Date().addingTimeInterval(seconds).timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(raw))
    }

    /// M40 polish: the echo-skip path fires when a queue item's
    /// `baseUpdatedAt` exactly equals the inbound server row's
    /// `updated_at`. Builds a `LocalNote` (so we can detect a
    /// *would-be* upsert by reading its fields back), seeds the
    /// queue with a matching base, and runs the apply. Asserts the
    /// echoSkips counter ticks up and the local row is untouched.
    @MainActor
    static func assertEchoSkipFires() throws {
        let context = try makeContext()
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        let engine = SyncEngine(client: client, modelContext: context, authSession: session)
        engine.attach(mutationQueue: queue)

        // Seed a local note with the user's optimistic edit already
        // applied. The "echo" arrives from the server still showing
        // the *pre-edit* title. Truncate to whole seconds so the
        // baseUpdatedAt round-trips through `formatForWire` →
        // `parseDate` byte-identically; any fractional component
        // would drop on wire-format and the equality check would
        // miss.
        let resourceId = "33333333-3333-3333-3333-333333333333"
        let optimisticTitle = "User just typed this"
        let preEditUpdatedAt = wholeSecondDate(secondsFromNow: -30)
        let local = LocalNote(
            id: resourceId,
            shortId: "abc",
            title: optimisticTitle,
            content: "",
            type: "todo",
            archived: false,
            createdAt: preEditUpdatedAt,
            updatedAt: preEditUpdatedAt
        )
        context.insert(local)
        try context.save()

        // Enqueue a pending mutation with `baseUpdatedAt` matching the
        // server's pre-edit timestamp.
        _ = try queue.enqueue(
            op: .updateTodo,
            resourceType: "todo",
            resourceId: resourceId,
            payload: Data(),
            baseUpdatedAt: preEditUpdatedAt
        )

        // Build a fake inbound sync response with the server's
        // pre-edit row (its `updated_at` exactly equals the queue
        // item's base — the echo signature).
        let serverRow = Note.echoTestFixture(
            id: resourceId,
            title: "Pre-edit title",
            updatedAt: ServerDateChecks.formatForWire(preEditUpdatedAt)
        )
        let response = SyncResponse(
            projects: [],
            notes: [serverRow],
            tombstones: SyncTombstones(notes: [], projects: []),
            serverTime: ServerDateChecks.formatForWire(Date())
        )

        let initialEchoSkips = engine.echoSkips
        try engine.applyForTesting(response)

        // Echo-skip should have fired exactly once for the note.
        assert(engine.echoSkips == initialEchoSkips + 1,
               "echoSkips should bump when server.updatedAt == pending.baseUpdatedAt")
        // The local row's title should still reflect the user's
        // optimistic edit — the upsert was skipped.
        assert(local.title == optimisticTitle,
               "echo-skip path must not overwrite the optimistic local row")
    }

    /// Counterpart: when the server row's `updated_at` is strictly
    /// newer than the queue item's base, the conflict-drop path
    /// fires (handled by `MutationQueue.dropPendingMutation`) and
    /// the echo-skip path does NOT fire — i.e. the upsert proceeds.
    @MainActor
    static func assertEchoSkipDoesNotFireForNewerServer() throws {
        let context = try makeContext()
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        let engine = SyncEngine(client: client, modelContext: context, authSession: session)
        engine.attach(mutationQueue: queue)

        let resourceId = "44444444-4444-4444-4444-444444444444"
        let optimisticTitle = "User just typed this"
        // Whole-second precision — see `wholeSecondDate` for why.
        let baseUpdatedAt = wholeSecondDate(secondsFromNow: -60)
        let serverNewerUpdatedAt = wholeSecondDate(secondsFromNow: -10)
        let local = LocalNote(
            id: resourceId,
            shortId: "def",
            title: optimisticTitle,
            content: "",
            type: "todo",
            archived: false,
            createdAt: baseUpdatedAt,
            updatedAt: baseUpdatedAt
        )
        context.insert(local)
        try context.save()

        _ = try queue.enqueue(
            op: .updateTodo,
            resourceType: "todo",
            resourceId: resourceId,
            payload: Data(),
            baseUpdatedAt: baseUpdatedAt
        )

        let serverTitle = "Web client wrote this"
        let serverRow = Note.echoTestFixture(
            id: resourceId,
            title: serverTitle,
            updatedAt: ServerDateChecks.formatForWire(serverNewerUpdatedAt)
        )
        let response = SyncResponse(
            projects: [],
            notes: [serverRow],
            tombstones: SyncTombstones(notes: [], projects: []),
            serverTime: ServerDateChecks.formatForWire(Date())
        )

        let initialEchoSkips = engine.echoSkips
        try engine.applyForTesting(response)

        assert(engine.echoSkips == initialEchoSkips,
               "echoSkips must not bump when server is strictly newer than base")
        // Server-newer wins: the local row should now reflect the
        // server's title. (And the conflict-drop path should have
        // removed the queue item, but we don't assert that here —
        // it's covered by `BrainDebugMutationQueue` already.)
        assert(local.title == serverTitle,
               "server-newer apply must overwrite the local row")
    }

    /// Run every check. Convenience entrypoint for a future CI hook.
    @MainActor
    static func runAll() {
        do {
            try assertEchoSkipFires()
            try assertEchoSkipDoesNotFireForNewerServer()
        } catch {
            assertionFailure("BrainDebugSyncEngine: setup failed: \(error)")
        }
    }
}

extension SyncEngine {
    /// Test-only entry point that runs the same apply path as a real
    /// sync. We deliberately do not expose `applyAndAdvanceCursor`
    /// itself because it's also responsible for staging the cursor
    /// row, which we don't need to exercise here.
    @MainActor
    fileprivate func applyForTesting(_ response: SyncResponse) throws {
        try applyAndAdvanceCursor(response)
    }
}

extension Note {
    /// Build a minimal `Note` DTO suitable for the echo-skip checks.
    /// All other fields default to empty/false because the echo path
    /// only inspects `id` and `updatedAt`.
    static func echoTestFixture(id: String, title: String, updatedAt: String) -> Note {
        Note(
            id: id,
            shortId: "test",
            title: title,
            content: "",
            type: "todo",
            tags: [],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            archived: false,
            todo: TodoFields(
                dueDate: nil,
                dueTime: nil,
                completed: false,
                completedAt: nil,
                priority: "medium",
                recurrence: nil,
                projectId: nil,
                section: "default",
                url: nil,
                urlTitle: nil,
                urlState: nil,
                urlFetchedAt: nil,
                sortOrder: 0
            ),
            appointment: nil
        )
    }
}

extension ServerDateChecks {
    /// Wire-format a `Date` so it round-trips through
    /// `SyncEngine.parseDate`. The engine uses
    /// `ISO8601DateFormatter` with `.withInternetDateTime`, which
    /// REQUIRES a `Z` (or explicit offset) designator — naive
    /// `yyyy-MM-dd'T'HH:mm:ss` does not parse. Truncate to whole
    /// seconds so the engine's non-fractional formatter handles the
    /// string cleanly, and equality comparisons against
    /// `baseUpdatedAt` (which is *also* parsed back through the same
    /// formatter on the next round-trip) line up exactly.
    static func formatForWire(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Truncate to whole seconds — the same formatter parses with
        // second precision, so a fractional input would round-trip to
        // a different `Date` than the one we passed in.
        let truncated = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        return formatter.string(from: truncated)
    }
}

#endif
