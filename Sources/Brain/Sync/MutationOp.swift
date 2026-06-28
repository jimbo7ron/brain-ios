// MutationOp.swift
// brain-ios
//
// Typed enum of the mutation operations the queue knows how to replay
// (M37). Each case maps 1:1 to a brain server endpoint — see
// `brain/src/brain/server.py` for the route definitions.
//
// The `rawValue` strings are the persistent slugs stored in
// `MutationQueueItem.op`. Once a slug ships in a release, it must NEVER
// be renamed — users may have queue rows captured offline by an older
// build, and the replayer needs to recognise them after the app updates.
// To retire a slug, keep its case here and route it to a no-op or a
// migration shim, then drop it in a later major version when the queue
// has demonstrably drained.
//
// Adding a new operation:
//   1. Add the case + rawValue here.
//   2. Add a dispatch arm in `BrainAPIClient.executeMutation(_:)` that
//      reads the typed payload, builds the request (with idempotencyKey
//      threaded as `Idempotency-Key`), and performs it.
//   3. Add a typed payload struct to `DTOs.swift` if the body shape isn't
//      already covered.
//   4. Add a convenience `MutationQueue.enqueueXxx(...)` if call sites
//      benefit from one (otherwise enqueue raw via the generic `enqueue`).

import Foundation

enum MutationOp: String, Codable, CaseIterable {

    // MARK: - Todo lifecycle

    /// `POST /api/v1/notes/{id}/complete` — mark a todo complete. M36
    /// will re-plumb its toggle through the queue using this op.
    case completeTodo = "complete_todo"

    /// (M40) Reverse of `completeTodo`. The server doesn't expose a
    /// dedicated "uncomplete" endpoint today; the planned shape is
    /// `PUT /api/v1/notes/{id}` with `{"completed": false}` in the body.
    /// Keep the case here so persisted slugs from a forward-looking
    /// build still decode after a downgrade.
    case uncompleteTodo = "uncomplete_todo"

    /// `POST /api/v1/notes` — create a new note/todo/appointment. The
    /// `resourceId` on the queue row is a local UUID minted before the
    /// server has assigned one; M38's conflict resolution swaps it for
    /// the server id once the create round-trips.
    case createTodo = "create_todo"

    /// `PUT /api/v1/notes/{id}` — patch fields on an existing note.
    /// Despite the spec referring to PATCH, the server route is PUT —
    /// see `update_note_endpoint` in `brain/src/brain/server.py`. The
    /// server is forgiving on missing fields, so the payload only needs
    /// to carry the fields actually being changed (mirroring
    /// `UpdateNotePayload` in `DTOs.swift`).
    case updateTodo = "update_todo"

    /// `DELETE /api/v1/notes/{id}` — soft-delete a note. The brain
    /// server treats DELETE as archive (see `delete_note_endpoint`); the
    /// row resurfaces in the next sync's `tombstones.notes` list. The
    /// case name keeps the user-intent vocabulary even though the verb
    /// is DELETE.
    case archiveNote = "archive_note"

    /// (M45 Wave 1) Reverse of `archiveNote`. The server has no
    /// dedicated unarchive endpoint today — `NoteUpdate` doesn't carry
    /// an `archived` field, and there's no `POST .../{id}/unarchive`
    /// route (verified against `brain/src/brain/server.py` at the M45
    /// Wave 1 cut). Keep the case here so persisted slugs from a
    /// forward-looking build still decode after a downgrade, and so
    /// `NoteRepository.unarchive(...)` has a stable target slug to
    /// enqueue against once Wave 2-3 wires the server endpoint. The
    /// `executeMutation` arm currently throws `.notImplemented` — the
    /// queue's poison-class handler will park the row, surface a
    /// non-fatal lastError, and drain past it.
    case unarchiveNote = "unarchive_note"

    // MARK: - Project lifecycle

    /// `POST /api/v1/projects` — create a new project.
    case createProject = "create_project"

    /// `PUT /api/v1/projects/{id}` — rename / recolor / re-sort.
    case updateProject = "update_project"

    /// `POST /api/v1/projects/{id}/sections` — append a section. The
    /// server also exposes `PUT .../sections` (replace whole list) and
    /// `PATCH .../sections/{slug}` (rename); those land in their own
    /// cases when their UI flow ships.
    case addSection = "add_section"

    /// (M45 Wave 4) `POST /api/v1/projects/{projectId}/sections` via the
    /// Repository's optimistic create path. Differs from `.addSection`
    /// (which was the M40 placeholder slug) in that the queue row's
    /// `resourceId` is the composite `<projectID>:<tmp-slug>` so the
    /// reconcile path can find the optimistic `LocalSection` stub and
    /// rename it to the server's canonical slug. The wire payload is
    /// `CreateSectionPayload` (`{name}`).
    case createSection = "create_section"

    /// (M45 Wave 4) `PATCH /api/v1/projects/{projectId}/sections/{slug}`
    /// — rename a section. The server preserves `slug` server-side per
    /// the M40 contract, so the composite id stays stable across the
    /// rename; only the `name` column updates locally + on the wire.
    /// Resource id is the composite `<projectID>:<slug>`. Wire payload
    /// is `UpdateSectionPayload` (`{name}`).
    case updateSection = "update_section"

    /// Human-readable description of the action, phrased as the user's
    /// intent rather than the HTTP route. Surfaced by the failed-changes
    /// sheet (`MutationFailuresView`) so a parked row reads as "Edit
    /// to-do" rather than `update_todo`. Kept exhaustive (no `default`)
    /// so adding a new op forces a label decision here.
    var displayName: String {
        switch self {
        case .completeTodo: return "Complete to-do"
        case .uncompleteTodo: return "Reopen to-do"
        case .createTodo: return "Create to-do"
        case .updateTodo: return "Edit to-do"
        case .archiveNote: return "Delete note"
        case .unarchiveNote: return "Restore note"
        case .createProject: return "Create project"
        case .updateProject: return "Edit project"
        case .addSection, .createSection: return "Add section"
        case .updateSection: return "Rename section"
        }
    }
}
