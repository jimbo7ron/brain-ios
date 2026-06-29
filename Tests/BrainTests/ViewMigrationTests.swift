// ViewMigrationTests.swift
// brain-ios — BrainTests
//
// M45 Wave 2: integration-shaped tests for the four create paths that
// migrated from open-coded `modelContext.insert + save +
// queue.enqueue` to `repo.create(payload)`. Per the brain testing
// philosophy the migrated views are tested at the *intent* layer — we
// build the same `CreateNotePayload` / `CreateProjectPayload` each
// view's `submit()` builds, hand it to the repository, and assert the
// post-conditions match the pre-migration behaviour:
//   * an optimistic stub appears on the repo's `ModelContext`
//   * the queue holds a matching `.createTodo` / `.createProject` row
//     keyed on the same client UUID
//   * the status store has a `.pending` entry for that id
//   * projectId / section / "inbox" sentinel mapping match the
//     spec (InboxDetailView in particular threads the sentinel
//     through to a local `nil` — see `NoteRepository.create`'s
//     `resolvedProjectID` resolution)
//
// SwiftUI views are not invoked directly: their `submit()` methods are
// `private` and the @Environment plumbing requires a host scene. The
// payload-construction logic in each view is small (5-10 lines after
// the migration) and is exercised end-to-end through the repo here.
// The shared fixture mirrors `NoteRepositoryTests.makeFixture()` /
// `ProjectRepositoryTests.makeFixture()`.

import Foundation
import SwiftData
import XCTest
@testable import brain

@MainActor
final class ViewMigrationTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            LocalNote.self,
            LocalProject.self,
            LocalSection.self,
            MutationQueueItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private struct NoteFixture {
        let container: ModelContainer
        let repo: NoteRepository
        let queue: MutationQueue
        let store: MutationStatusStore
        let repoContext: ModelContext
    }

    private func makeNoteFixture() throws -> NoteFixture {
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
        return NoteFixture(
            container: container,
            repo: repo,
            queue: queue,
            store: store,
            repoContext: repoContext
        )
    }

    private struct ProjectFixture {
        let container: ModelContainer
        let repo: ProjectRepository
        let queue: MutationQueue
        let store: MutationStatusStore
        let repoContext: ModelContext
    }

    private func makeProjectFixture() throws -> ProjectFixture {
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
        let repo = ProjectRepository(
            modelContext: repoContext,
            queue: queue,
            statusStore: store,
            client: client
        )
        return ProjectFixture(
            container: container,
            repo: repo,
            queue: queue,
            store: store,
            repoContext: repoContext
        )
    }

    // MARK: - QuickAddView migration

    /// Mirrors `QuickAddView.submit()` post-migration. The view runs
    /// the user-typed string through `QuickAddParser`, builds a
    /// `CreateNotePayload`, and hands it to `noteRepo.create`. We
    /// assert the optimistic stub + queue row + pending status all
    /// land — the same surface the old open-coded path produced.
    func testQuickAddView_submitMigrationProducesOptimisticStubAndQueueRow() throws {
        let f = try makeNoteFixture()

        // Match the smoke string from the in-view help footer so the
        // parser exercise is non-trivial: title + due date + priority
        // + tag should all survive into the wire payload.
        let parsed = QuickAddParser.parse("Ship migration tomorrow !high #work")
        let payload = CreateNotePayload(
            content: parsed.bodyForServer(),
            title: nil,
            type: "todo",
            dueDate: parsed.dueDateISO(),
            dueTime: parsed.dueTimeHHMM(),
            priority: parsed.priority?.rawValue,
            recurrence: parsed.recurrence?.rawValue,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        let stub = f.repo.create(payload)

        // Optimistic stub visible on the repo's context.
        let notes = try f.repoContext.fetch(FetchDescriptor<LocalNote>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.id, stub.id)
        XCTAssertEqual(notes.first?.priority, "high")
        XCTAssertEqual(stub.type, "todo")

        // Queue row matches.
        let queueRows = try f.queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createTodo.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, stub.id)

        // Status store marks pending.
        guard case .pending = f.store.status(for: stub.id) else {
            XCTFail("expected .pending in status store for \(stub.id)")
            return
        }
    }

    // MARK: - ProjectDetailView migration

    /// Mirrors `ProjectDetailView.createTodoInline(content:sectionSlug:)`
    /// post-migration. The view threads a real project UUID + the
    /// section slug onto the payload; the repository's optimistic
    /// resolver must persist both fields locally so the section's
    /// `@Query` (`projectId == projectID && section == slug`) picks
    /// the row up immediately.
    func testProjectDetailView_inlineAddProducesScopedOptimisticStub() throws {
        let f = try makeNoteFixture()

        let projectID = UUID().uuidString.lowercased()
        let payload = CreateNotePayload(
            content: "draft launch email",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: projectID,
            section: "now",
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        let stub = f.repo.create(payload)

        // Local stub keeps the project / section context so the
        // section's @Query renders the row in-place.
        XCTAssertEqual(stub.projectId, projectID)
        XCTAssertEqual(stub.section, "now")
        XCTAssertEqual(stub.content, "draft launch email")

        // Queue row keyed on the same client UUID.
        let queueRows = try f.queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.resourceId, stub.id)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createTodo.rawValue)
    }

    // MARK: - InboxDetailView migration

    /// Mirrors `InboxDetailView.createTodoInline(content:)` post-
    /// migration. The view threads `"inbox"` (the server-side
    /// clear sentinel) as the wire payload's `project`. The
    /// repository must surface this locally as `projectId == nil` so
    /// the inbox bucket's `@Query` (`projectId == nil`) picks
    /// the row up — if the literal sentinel string survived into
    /// SwiftData, the row would orphan into "neither bucket".
    func testInboxDetailView_inlineAddSurfacesAsNilProjectIDLocally() throws {
        let f = try makeNoteFixture()

        let payload = CreateNotePayload(
            content: "no-bucket todo",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: ProjectListView.inboxProjectID,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        let stub = f.repo.create(payload)

        // The "inbox" sentinel goes out on the wire (the queue
        // row's payload should still carry it so the server clears
        // `project_id` to NULL) but locally surfaces as nil so the
        // Inbox @Query picks the row up.
        XCTAssertNil(stub.projectId)

        let queueRows = try f.queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        // Decode the queued payload and verify the wire-side sentinel
        // is preserved — we don't want the optimistic local nil-ing
        // to leak into the bytes the queue replays.
        let body = try XCTUnwrap(queueRows.first?.payload)
        let decoded = try JSONDecoder().decode(WireCreateNote.self, from: body)
        XCTAssertEqual(decoded.project, "inbox")
    }

    // MARK: - NewProjectView migration

    /// Mirrors `NewProjectView.submit()` post-migration. The view
    /// builds a `CreateProjectPayload` from `name` + optional colour
    /// and hands it to `projectRepo.create`. Optimistic stub appears
    /// in the repo's context, queue holds a matching `.createProject`
    /// row, status store marks pending.
    func testNewProjectView_submitProducesOptimisticProjectAndQueueRow() throws {
        let f = try makeProjectFixture()

        let payload = CreateProjectPayload(
            name: "Spring Cleanup",
            color: "hsl(262 83% 58%)",
            sortOrder: nil
        )

        let stub = f.repo.create(payload)

        // Optimistic project visible on the repo's context.
        let projects = try f.repoContext.fetch(FetchDescriptor<LocalProject>())
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.id, stub.id)
        XCTAssertEqual(projects.first?.name, "Spring Cleanup")
        XCTAssertEqual(projects.first?.color, "hsl(262 83% 58%)")
        XCTAssertFalse(projects.first?.archived ?? true)

        // Queue holds a matching .createProject row.
        let queueRows = try f.queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createProject.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, stub.id)

        // Status store marks pending.
        guard case .pending = f.store.status(for: stub.id) else {
            XCTFail("expected .pending in status store for \(stub.id)")
            return
        }
    }
}

/// Small Decodable mirror of the wire shape used by
/// `testInboxDetailView_inlineAddSurfacesAsNilProjectIDLocally`
/// to assert the "inbox" sentinel survives into the queue
/// payload. `CreateNotePayload` itself is `Encodable`-only so we use
/// this private decoder shape for the round-trip.
private struct WireCreateNote: Decodable {
    let project: String?
}
