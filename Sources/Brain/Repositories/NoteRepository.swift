// NoteRepository.swift
// brain-ios
//
// M45 Wave 1: the single contract every iOS view-side note mutation
// will eventually go through. Each method takes the user's intent (a
// payload struct, a typed diff, a target row), performs the optimistic
// local mutation against the repository's own `ModelContext`, encodes
// the wire payload, and enqueues a `MutationOp` for the queue to
// replay. The view never sees the network.
//
// Wave 1 ships the skeleton + tests; **no view migrates yet**. Wave 2
// migrates create paths (`QuickAddView` etc.); Wave 3 migrates updates
// + archives + `TodoRow.toggleComplete`; Wave 4 ships per-row UI for
// the `MutationStatusStore`. See `docs/M45-write-coordinator.md` for
// the full migration plan.
//
// Threading: `@MainActor` because the repository owns a SwiftData
// `ModelContext` (which prefers main-actor access on iOS 17), publishes
// observable state, and feeds into the queue (also `@MainActor`). The
// HTTP work happens inside the `BrainAPIClient` actor, so awaits don't
// pin the main thread.
//
// ModelContext lifetime — three-context pattern (per spec §4.1):
//   1. SwiftUI environment context — owned by the view tree.
//   2. SyncEngine's context — owned by the engine, lifetime = app.
//   3. MutationQueue's context — owned by the queue, lifetime = app.
//   4. **NEW (this file): Repository's context** — owned here, lifetime
//      = app. Constructed in `BrainApp.init` against the same
//      `ModelContainer`. Cross-context propagation works because each
//      save persists to the shared SQLite store and the next fetch on
//      another context reads from disk; SwiftData's `@Query` on the
//      SwiftUI side picks up the change via change-coalescing. Same
//      pattern documented at `MutationQueue.swift:450-460`.

import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class NoteRepository {

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let queue: MutationQueue?
    private let statusStore: MutationStatusStore?

    // MARK: - Init

    /// Construct against the shared `ModelContainer`'s third
    /// `ModelContext` (the queue and SyncEngine own contexts #1 and #2).
    /// `queue` and `statusStore` are optional so preview / test hosts
    /// can drive the repository in isolation — production wiring in
    /// `BrainApp.init` always passes both.
    init(
        modelContext: ModelContext,
        queue: MutationQueue?,
        statusStore: MutationStatusStore?
    ) {
        self.modelContext = modelContext
        self.queue = queue
        self.statusStore = statusStore
    }

    // MARK: - Create

    /// Optimistically insert a new note locally and enqueue the
    /// matching `.createTodo` mutation. Returns the SwiftData row so
    /// callers can navigate to it / select it. The row's `id` is a
    /// client UUID until the queue's reconcile renames it to the
    /// server-issued id.
    ///
    /// Mirrors the field surface of `QuickAddView.submit()`'s open-
    /// coded path (Wave 2 will migrate that view to call this method
    /// instead). Field defaults match the M37 / M44 behaviour:
    ///   * `archived = false` (always)
    ///   * `completed = false` (creates start uncompleted)
    ///   * `priority = "medium"` (server default)
    ///   * `sortOrder = 0` (server-assigned on first sync)
    ///   * `shortId = ""` (filled by the create-echo's reconcile)
    ///
    /// The optimistic stub's `projectId` only resolves cleanly when the
    /// payload's `project` is a UUID — server names ("Inbox") need a
    /// server-side resolution step that the next sync delivers.
    /// "unassigned" is the server-side clear sentinel and surfaces
    /// locally as `nil`.
    @discardableResult
    func create(_ payload: CreateNotePayload) -> LocalNote {
        let clientID = UUID().uuidString.lowercased()
        let now = Date()
        // TODO(M45 Wave 3+): If the supplied `payload.project` is the
        // *client* UUID of a project whose own create echo hasn't
        // landed yet (rapid project create → immediate inline add),
        // shipping that UUID to the server will 404 — the server has
        // never heard of the client UUID. Either block inline-add
        // until the parent project's reconcile completes, or queue
        // the inline note against a sentinel that the queue rewrites
        // on parent-project reconcile (idempotent against the rename).
        // Pre-existing edge case; Wave 2 makes it more reachable but
        // doesn't introduce it.
        let resolvedProjectID: String? = {
            guard let project = payload.project else { return nil }
            if project == "unassigned" { return nil }
            return UUID(uuidString: project) != nil ? project : nil
        }()

        // Mirror QuickAddView's optimistic seeding (review fix from
        // M45 Wave 1): if the caller didn't provide a title, derive
        // one from the content via the same `QuickAddParser` the view
        // would have used. Same for tags — the server's NoteCreate
        // schema doesn't accept a `tags` field (the server derives
        // them from `content` via M26's NLP pipeline), so seeding
        // them locally just keeps the optimistic row's tag chips
        // rendered until the create echo lands. The server's
        // authoritative tag set arrives via the next sync.
        let parsed = QuickAddParser.parse(payload.content)
        let optimisticTitle: String? = {
            if let supplied = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !supplied.isEmpty {
                return supplied
            }
            let derived = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return derived.isEmpty ? nil : derived
        }()
        let optimisticTagsCSV = parsed.tags.joined(separator: ",")

        let stub = LocalNote(
            id: clientID,
            shortId: "",
            title: optimisticTitle,
            content: payload.content,
            type: payload.type,
            archived: false,
            createdAt: now,
            updatedAt: now,
            tagsCSV: optimisticTagsCSV,
            dueDate: payload.dueDate,
            dueTime: payload.dueTime,
            completed: false,
            priority: payload.priority ?? "medium",
            recurrence: payload.recurrence,
            projectId: resolvedProjectID,
            section: payload.section,
            url: payload.url,
            sortOrder: 0,
            appointmentStartTime: payload.startTime,
            appointmentEndTime: payload.endTime,
            appointmentLocation: payload.location,
            appointmentRecurrence: payload.recurrence
        )
        modelContext.insert(stub)
        do {
            try modelContext.save()
        } catch {
            // SwiftData fault — extremely rare. The stub is in memory
            // on the repository's context regardless; returning it to
            // the caller keeps the optimistic UX intact, and the next
            // save attempt (e.g. on the next mutation) may succeed.
            // Swallowing here matches the existing `QuickAddView`
            // behaviour where SwiftData faults surface as inline
            // errors in the view rather than throwing through the
            // repository.
            NSLog("NoteRepository.create: save failed for \(clientID): \(error)")
        }

        // Encode the wire payload for the queue. JSONEncoder on a
        // fixed Codable struct can't realistically fail; the throws
        // signature is satisfied by `try?` to keep the call shape
        // simple. If encoding ever does fail, the local stub stays
        // and the next sync will overwrite it with the server's truth
        // (or, if the server never received the create because we
        // never enqueued, the stub sits orphaned — same failure mode
        // as the open-coded path, which we'll address in Wave 4 with
        // a richer status surface).
        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("NoteRepository.create: failed to encode payload for \(clientID)")
            return stub
        }

        enqueue(
            op: .createTodo,
            resourceType: "todo",
            resourceId: clientID,
            payload: body,
            baseUpdatedAt: nil
        )

        return stub
    }

    // MARK: - Update

    /// Apply a typed diff to a local note and enqueue the matching
    /// `.updateTodo` mutation. Only non-nil fields on `fields` are
    /// applied locally and serialised onto the wire — that's how the
    /// caller signals "leave alone" vs "set to this value".
    ///
    /// `baseUpdatedAt` is captured from the live note so M38's LWW
    /// guard can detect a server-side write that landed while the
    /// queued update was in flight.
    func update(_ note: LocalNote, _ fields: NoteUpdateFields) {
        // Capture the base updatedAt before mutating — the LWW guard
        // wants the snapshot the user actually edited from. We bump
        // `note.updatedAt` to "now" locally so SwiftUI re-orders any
        // updated_at-based @Query immediately, matching the behaviour
        // a server-side write would have.
        let base = note.updatedAt

        if let content = fields.content { note.content = content }
        if let title = fields.title {
            // Empty title locally surfaces as nil (matches existing
            // EditTodoView optimistic semantics); wire payload still
            // ships the empty string so the server clears its title.
            note.title = title.isEmpty ? nil : title
        }
        if let url = fields.url {
            // Empty URL clears locally (matches EditTodoView).
            note.url = url.isEmpty ? nil : url
        }
        if let dueDate = fields.dueDate {
            // The wire convention is "none" to clear; on the local
            // model we mirror that as nil so the @Query / list filters
            // don't have to know about the sentinel. The wire payload
            // carries the literal "none" string (see below).
            note.dueDate = (dueDate == "none") ? nil : dueDate
        }
        if let priority = fields.priority { note.priority = priority }
        if let projectId = fields.projectId {
            // "unassigned" is the wire-side clear sentinel — surface
            // locally as nil so the row falls into the Unassigned
            // bucket immediately.
            if projectId == "unassigned" {
                note.projectId = nil
            } else if UUID(uuidString: projectId) != nil {
                note.projectId = projectId
            }
            // Name-only project values ("Inbox") can't safely populate
            // `projectId` locally — leave the field alone and let the
            // next sync delivery resolve it.
        }
        if let section = fields.section {
            note.section = section.isEmpty ? nil : section
        }
        if let startTime = fields.startTime {
            note.appointmentStartTime = startTime.isEmpty ? nil : startTime
        }
        if let endTime = fields.endTime {
            note.appointmentEndTime = endTime.isEmpty ? nil : endTime
        }
        if let location = fields.location {
            note.appointmentLocation = location.isEmpty ? nil : location
        }
        note.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("NoteRepository.update: save failed for \(note.id): \(error)")
        }

        // Build the wire payload from the same diff. Symmetric with the
        // local apply above so the queue ships exactly what the user
        // changed and nothing more.
        let payload = UpdateNotePayload(
            content: fields.content,
            title: fields.title,
            dueDate: fields.dueDate,
            priority: fields.priority,
            project: fields.projectId,
            section: fields.section,
            url: fields.url,
            startTime: fields.startTime,
            endTime: fields.endTime,
            location: fields.location
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("NoteRepository.update: failed to encode payload for \(note.id)")
            return
        }

        enqueue(
            op: .updateTodo,
            resourceType: "todo",
            resourceId: note.id,
            payload: body,
            baseUpdatedAt: base
        )
    }

    // MARK: - Toggle complete

    /// Optimistically flip `completed` and enqueue `.completeTodo` /
    /// `.uncompleteTodo`. Wave 1 wires the contract; `TodoRow.toggle`
    /// keeps its current direct-call path until Wave 3 migrates.
    ///
    /// Note: `.uncompleteTodo` is currently unimplemented on the wire
    /// (the server has no `/uncomplete` endpoint at the M44 cut). A
    /// queued `.uncompleteTodo` will be poisoned by the queue's
    /// permanent-failure handler — by Wave 3 the server endpoint or
    /// PUT-based shape will be in place.
    func toggleComplete(_ note: LocalNote) {
        let base = note.updatedAt
        let willComplete = !note.completed
        note.completed = willComplete
        note.completedAt = willComplete ? Date() : nil
        note.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("NoteRepository.toggleComplete: save failed for \(note.id): \(error)")
        }

        let op: MutationOp = willComplete ? .completeTodo : .uncompleteTodo
        // Both endpoints take an empty body — the resource id rides in
        // the path. Empty Data() matches the existing
        // `BrainAPIClient.executeMutation` dispatch.
        enqueue(
            op: op,
            resourceType: "todo",
            resourceId: note.id,
            payload: Data(),
            baseUpdatedAt: base
        )
    }

    // MARK: - Archive / unarchive

    /// Optimistically set `archived = true` and enqueue `.archiveNote`
    /// (the server's `DELETE /api/v1/notes/{id}` is a soft-delete; see
    /// `delete_note_endpoint`).
    func archive(_ note: LocalNote) {
        guard !note.archived else { return }
        let base = note.updatedAt
        note.archived = true
        note.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("NoteRepository.archive: save failed for \(note.id): \(error)")
        }

        enqueue(
            op: .archiveNote,
            resourceType: "todo",
            resourceId: note.id,
            payload: Data(),
            baseUpdatedAt: base
        )
    }

    /// Optimistically set `archived = false`. The server has no
    /// dedicated unarchive endpoint at the M45 Wave 1 cut — `NoteUpdate`
    /// carries no `archived` field, and there's no
    /// `POST .../{id}/unarchive` route (verified against
    /// `brain/src/brain/server.py`). Wave 1 ships the call site so
    /// Wave 2-3 can wire the server endpoint without any view churn.
    ///
    /// **Until the server endpoint lands**: this method only performs
    /// the local flip. It does NOT enqueue `.unarchiveNote` — doing so
    /// would immediately poison the row (the dispatch arm throws
    /// `.notImplemented`, which is poison-class), the rollback would
    /// flip `archived` back to true, and the user would see the row
    /// vanish. Logging an NSLog instead means the local flip stays put
    /// until the next sync delivers the server's authoritative state.
    /// When Wave 2-3 wires the wire path, replace the NSLog with an
    /// `enqueue(.unarchiveNote, ...)` call and remove this comment.
    func unarchive(_ note: LocalNote) {
        guard note.archived else { return }
        note.archived = false
        note.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("NoteRepository.unarchive: save failed for \(note.id): \(error)")
        }

        // TODO(M45 Wave 2-3): wire the server endpoint and replace
        // this with `enqueue(.unarchiveNote, ...)`. See
        // `MutationOp.unarchiveNote` doc-comment for the server
        // wiring constraint.
        NSLog(
            "NoteRepository.unarchive: server endpoint not implemented; " +
            "applied local flip only for \(note.id). Wave 2-3 will wire."
        )
    }

    // MARK: - Internal helpers

    /// Enqueue + status-store-pending in one place. The repository
    /// always pairs the two: every mutation that hits the queue should
    /// also get a per-row `.pending` indicator, and any failure /
    /// success is later reflected by the queue's reconcile + replay
    /// hooks (which clear or mark `.failed`).
    private func enqueue(
        op: MutationOp,
        resourceType: String,
        resourceId: String,
        payload: Data,
        baseUpdatedAt: Date?
    ) {
        guard let queue else {
            // Preview / test host without a queue. Local-only effect
            // is the entire intent — production never reaches here.
            return
        }
        do {
            _ = try queue.enqueue(
                op: op,
                resourceType: resourceType,
                resourceId: resourceId,
                payload: payload,
                baseUpdatedAt: baseUpdatedAt
            )
            statusStore?.mark(resourceId, .pending)
        } catch {
            // Enqueue failure (SwiftData fault on the queue row). The
            // optimistic local state is already applied; rather than
            // ripping it back out on a transient SwiftData hiccup,
            // leave it and let the next sync delivery reconcile.
            // Matches the existing archive-flow trade-off in
            // `TodoRow.archive` (M44.x).
            NSLog(
                "NoteRepository.enqueue: failed to enqueue \(op.rawValue) " +
                "for \(resourceId): \(error). Local mutation remains; " +
                "next sync will reconcile."
            )
        }
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `NoteRepository` via
/// `@Environment(\.noteRepository)`. Same pattern as
/// `\.mutationQueue` and `\.mutationStatusStore`. Default value is
/// `nil` so previews fall through gracefully — production wires the
/// repository in `BrainApp.init`.
private struct NoteRepositoryKey: EnvironmentKey {
    static let defaultValue: NoteRepository? = nil
}

extension EnvironmentValues {
    var noteRepository: NoteRepository? {
        get { self[NoteRepositoryKey.self] }
        set { self[NoteRepositoryKey.self] = newValue }
    }
}
