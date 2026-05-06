// NoteRepositoryTests.swift
// brain-ios — BrainTests
//
// M45 Wave 1: NoteRepository skeleton coverage. Verifies the optimistic
// local apply + queue enqueue + status-store mark contract that
// underwrites the entire write coordinator. Tests run against an
// in-memory `ModelContainer` so the production SQLite store is
// untouched.
//
// Per the brain testing philosophy ("test each behaviour ONCE at the
// lowest layer; don't re-test framework behaviour"), these tests cover:
//   * The repo's contract: local mutation + queue row + status entry
//     are produced by each entry point.
//   * The reconcile + clear hook into MutationStatusStore (queue rename
//     + clear path under direct invocation, since standing up a real
//     server replay would require mocking BrainAPIClient).
//
// Skipped here (covered elsewhere or framework-level):
//   * SwiftData @Attribute(.unique) constraint — framework.
//   * MutationOp Codable round-trip — `BrainDebugMutationQueue.assertOpRoundTrip`.
//   * Cross-context propagation — `BrainDebugMutationQueue.assertReconcileDedupesSyncRace`.

import Foundation
import SwiftData
import XCTest
@testable import brain

@MainActor
final class NoteRepositoryTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeContainer() throws -> ModelContainer {
        // Mirror BrainApp's schema list — we need every model the
        // queue + repo touch directly. Other models (LocalProject,
        // LocalUser, etc.) aren't required for note-only tests but
        // adding them keeps the schema parallel to production and
        // avoids surprise SwiftData faults if a future test reaches
        // for `LocalProject`.
        let schema = Schema([
            LocalNote.self,
            LocalProject.self,
            LocalSection.self,
            MutationQueueItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        repo: NoteRepository,
        queue: MutationQueue,
        store: MutationStatusStore,
        repoContext: ModelContext
    ) {
        let container = try makeContainer()
        let queueContext = ModelContext(container)
        let repoContext = ModelContext(container)
        let store = MutationStatusStore()
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(
            modelContext: queueContext,
            client: client,
            authSession: session
        )
        queue.statusStore = store
        let repo = NoteRepository(
            modelContext: repoContext,
            queue: queue,
            statusStore: store
        )
        return (container, repo, queue, store, repoContext)
    }

    // MARK: - Create

    /// Spec §6.1: `repo.create` performs an optimistic local insert and
    /// enqueues a `.createTodo` mutation against the same client UUID.
    /// The local stub must be findable on the repo's context, and the
    /// queue must hold a matching row.
    func testCreate_insertsLocalAndEnqueues() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let payload = CreateNotePayload(
            content: "buy milk",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        let stub = repo.create(payload)

        // Local stub visible on the repo's context, with the
        // optimistic content the user typed.
        let descriptor = FetchDescriptor<LocalNote>()
        let allNotes = try repoContext.fetch(descriptor)
        XCTAssertEqual(allNotes.count, 1)
        XCTAssertEqual(allNotes.first?.id, stub.id)
        XCTAssertEqual(allNotes.first?.content, "buy milk")
        XCTAssertEqual(allNotes.first?.type, "todo")
        XCTAssertFalse(allNotes.first?.completed ?? true)

        // Queue holds a matching .createTodo row keyed on the same
        // client UUID. We read from the queue's debug context to
        // exercise the cross-context propagation that production
        // relies on.
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createTodo.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, stub.id)
    }

    /// Spec §6.3 / §4.4: create marks the resource as `.pending` in the
    /// status store so per-row UI (Wave 4) can render a spinner.
    func testCreate_marksPendingInStatusStore() throws {
        let (_, repo, _, store, _) = try makeFixture()

        let payload = CreateNotePayload(
            content: "x",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )
        let stub = repo.create(payload)

        guard case .pending = store.status(for: stub.id) else {
            XCTFail(
                "expected .pending in status store after create, got " +
                "\(String(describing: store.status(for: stub.id)))"
            )
            return
        }
    }

    // MARK: - Update

    /// Spec §6.1: `repo.update` applies the diff locally and enqueues
    /// `.updateTodo`. Only non-nil fields are applied.
    func testUpdate_appliesLocalAndEnqueues() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        // Seed a server-side row directly so the test starts from a
        // post-create-reconcile world (the row already has its server
        // id and updated_at).
        let serverID = "11111111-1111-1111-1111-111111111111"
        let baseUpdated = Date(timeIntervalSinceReferenceDate: 0)
        let note = LocalNote(
            id: serverID,
            shortId: "abc",
            title: nil,
            content: "old content",
            type: "todo",
            createdAt: baseUpdated,
            updatedAt: baseUpdated,
            priority: "low"
        )
        repoContext.insert(note)
        try repoContext.save()

        let fields = NoteUpdateFields(
            content: "new content",
            dueDate: nil,
            priority: "high",
            projectId: nil,
            section: nil
        )
        repo.update(note, fields)

        // Local apply.
        XCTAssertEqual(note.content, "new content")
        XCTAssertEqual(note.priority, "high")
        // updatedAt bumped past the base.
        XCTAssertNotNil(note.updatedAt)
        XCTAssertGreaterThan(note.updatedAt!, baseUpdated)

        // Queue holds a matching .updateTodo row with the original
        // updatedAt as the LWW base (M38 contract).
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.updateTodo.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, serverID)
        XCTAssertEqual(queueRows.first?.baseUpdatedAt, baseUpdated)
    }

    /// M45 Wave 1 review fix: `NoteUpdateFields` covers every field
    /// `EditTodoView.save()` already mutates that the server's
    /// `NoteUpdate` actually accepts (`content`, `title`, `url`,
    /// `dueDate`, `priority`, `projectId`, `section`, plus the
    /// appointment trio). Verify all 10 fields land on the local stub
    /// AND on the encoded queue payload so Wave 2-3's view migration
    /// doesn't accidentally drop any.
    ///
    /// `dueTime` / `recurrence` are intentionally NOT exposed on
    /// `NoteUpdateFields` — the server's `NoteUpdate` schema has no
    /// matching keys, so they would be silently dropped on the wire.
    func testUpdate_appliesAllFields() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let serverID = "66666666-6666-6666-6666-666666666666"
        let baseUpdated = Date(timeIntervalSinceReferenceDate: 0)
        let note = LocalNote(
            id: serverID,
            shortId: "abc",
            title: "old title",
            content: "old content",
            type: "appointment",
            createdAt: baseUpdated,
            updatedAt: baseUpdated,
            priority: "low",
            url: "https://old.example.com",
            appointmentStartTime: "2026-01-01T09:00:00Z",
            appointmentEndTime: "2026-01-01T10:00:00Z",
            appointmentLocation: "old place"
        )
        repoContext.insert(note)
        try repoContext.save()

        let fields = NoteUpdateFields(
            content: "new content",
            title: "new title",
            url: "https://new.example.com",
            dueDate: "2026-12-31",
            priority: "high",
            projectId: "77777777-7777-7777-7777-777777777777",
            section: "later",
            startTime: "2026-02-02T11:00:00Z",
            endTime: "2026-02-02T12:00:00Z",
            location: "new place"
        )
        repo.update(note, fields)

        // Local apply — every field reflected on the stub.
        XCTAssertEqual(note.content, "new content")
        XCTAssertEqual(note.title, "new title")
        XCTAssertEqual(note.url, "https://new.example.com")
        XCTAssertEqual(note.dueDate, "2026-12-31")
        XCTAssertEqual(note.priority, "high")
        XCTAssertEqual(note.projectId, "77777777-7777-7777-7777-777777777777")
        XCTAssertEqual(note.section, "later")
        XCTAssertEqual(note.appointmentStartTime, "2026-02-02T11:00:00Z")
        XCTAssertEqual(note.appointmentEndTime, "2026-02-02T12:00:00Z")
        XCTAssertEqual(note.appointmentLocation, "new place")

        // Queue payload carries every non-nil field — decode it and
        // verify each made the wire trip. Catches a regression where a
        // future field is added to `NoteUpdateFields` but not threaded
        // through to `UpdateNotePayload`.
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        guard let body = queueRows.first?.payload else {
            XCTFail("queue row missing payload")
            return
        }
        // `UpdateNotePayload` is Encodable-only (wire DTOs are
        // one-direction by design). Read the encoded JSON via
        // `JSONSerialization` so we can assert each snake_case key
        // independently.
        guard
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("queue payload not a JSON object")
            return
        }
        XCTAssertEqual(json["content"] as? String, "new content")
        XCTAssertEqual(json["title"] as? String, "new title")
        XCTAssertEqual(json["url"] as? String, "https://new.example.com")
        XCTAssertEqual(json["due_date"] as? String, "2026-12-31")
        XCTAssertEqual(json["priority"] as? String, "high")
        XCTAssertEqual(json["project"] as? String, "77777777-7777-7777-7777-777777777777")
        XCTAssertEqual(json["section"] as? String, "later")
        XCTAssertEqual(json["start_time"] as? String, "2026-02-02T11:00:00Z")
        XCTAssertEqual(json["end_time"] as? String, "2026-02-02T12:00:00Z")
        XCTAssertEqual(json["location"] as? String, "new place")
    }

    /// M45 Wave 1 review fix: the optimistic stub seeds `tagsCSV` and
    /// a derived `title` so the row's chips/title don't flicker between
    /// create and the server's reconcile. Verify both happen at the
    /// repo layer (not just in QuickAddView).
    func testCreate_seedsTagsAndTitle() throws {
        let (_, repo, _, _, _) = try makeFixture()

        // Content with an inline hashtag and a bare title; the
        // QuickAddParser strips the hashtag and the cleaned title is
        // what the optimistic row should display.
        let payload = CreateNotePayload(
            content: "buy milk #grocery",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )
        let stub = repo.create(payload)

        // Tag chip ready to render before any server reconcile.
        XCTAssertEqual(stub.tagsCSV, "grocery")
        // Derived title — parser strips the hashtag, leaving "buy milk".
        XCTAssertEqual(stub.title, "buy milk")
    }

    /// Caller-supplied title should win over the derived one — we
    /// don't want to silently overwrite an explicit title.
    func testCreate_explicitTitleWinsOverDerived() throws {
        let (_, repo, _, _, _) = try makeFixture()

        let payload = CreateNotePayload(
            content: "free-form content #tagged",
            title: "Explicit Title",
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )
        let stub = repo.create(payload)
        XCTAssertEqual(stub.title, "Explicit Title")
        // Tags are still derived even when title is supplied.
        XCTAssertEqual(stub.tagsCSV, "tagged")
    }

    // MARK: - Archive

    /// Spec §6.1: `repo.archive` flips `archived = true` locally and
    /// enqueues `.archiveNote`.
    func testArchive_flipsLocalAndEnqueues() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let serverID = "22222222-2222-2222-2222-222222222222"
        let note = LocalNote(
            id: serverID,
            shortId: "xyz",
            title: nil,
            content: "to archive",
            type: "todo"
        )
        repoContext.insert(note)
        try repoContext.save()

        repo.archive(note)

        // Local row hidden by `archived` filter.
        XCTAssertTrue(note.archived)

        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.archiveNote.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, serverID)
    }

    // MARK: - Reconcile + status lifecycle round-trip

    /// Spec §4.4: when the queue reconciles a successful create, the
    /// status store key flips from clientId to serverId — and a
    /// subsequent clear under the serverId removes the entry. Mocking a
    /// real server replay would require a stub `BrainAPIClient`; we
    /// instead exercise the same path by calling `reconcileCreate<T:>`
    /// directly + the clear step, which is the contract the queue
    /// honours after a successful round-trip.
    func testRoundTrip_renameThenClear() throws {
        let (_, repo, queue, store, _) = try makeFixture()

        let payload = CreateNotePayload(
            content: "round-trip",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )
        let stub = repo.create(payload)
        let clientID = stub.id
        let serverID = "33333333-3333-3333-3333-333333333333"

        // Pending entry under the client UUID after create.
        guard case .pending = store.status(for: clientID) else {
            XCTFail("repo.create should mark .pending under clientId")
            return
        }

        // Simulate a successful server replay: the queue's reconcile
        // step renames the stub + the queue row + the status store
        // entry from clientId → serverId.
        let serverNote = Note(
            id: serverID,
            shortId: "rt-1",
            title: nil,
            content: "round-trip",
            type: "todo",
            tags: [],
            createdAt: nil,
            updatedAt: nil,
            archived: false,
            todo: nil,
            appointment: nil
        )
        queue.debugReconcileCreateResponse(clientId: clientID, serverNote: serverNote)
        try queue.debugModelContext.save()

        // Status now keyed under server UUID.
        XCTAssertNil(
            store.status(for: clientID),
            "status under clientId should be gone after reconcile rename"
        )
        guard case .pending = store.status(for: serverID) else {
            XCTFail("status should have been renamed to serverId by reconcile")
            return
        }

        // Final lifecycle step: queue's success terminal clears under
        // the serverId. We exercise the contract directly since
        // `replay()` would otherwise need a real server response.
        store.clear(serverID)
        XCTAssertNil(store.status(for: serverID))
    }
}
