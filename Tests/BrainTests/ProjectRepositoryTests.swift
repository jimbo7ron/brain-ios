// ProjectRepositoryTests.swift
// brain-ios — BrainTests
//
// M45 Wave 1: ProjectRepository skeleton coverage. Mirrors
// `NoteRepositoryTests` for the create / update / archive contract.
// Section ops have lighter coverage because they're explicitly the
// "Wave 4 will refactor" path (per spec §8.6); we just verify they
// don't crash and that `reorderSections` throws the expected
// `unimplemented` per spec §3.

import Foundation
import SwiftData
import XCTest
@testable import brain

@MainActor
final class ProjectRepositoryTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeFixture() throws -> (
        container: ModelContainer,
        repo: ProjectRepository,
        queue: MutationQueue,
        store: MutationStatusStore,
        repoContext: ModelContext
    ) {
        let schema = Schema([
            LocalNote.self,
            LocalProject.self,
            LocalSection.self,
            MutationQueueItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
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
        return (container, repo, queue, store, repoContext)
    }

    // MARK: - Create

    /// Spec §6.2: `repo.create` performs an optimistic local insert and
    /// enqueues a `.createProject` mutation against the same client
    /// UUID. Status store entry under the client UUID.
    func testCreate_insertsLocalAndEnqueues() throws {
        let (_, repo, queue, store, repoContext) = try makeFixture()

        let payload = CreateProjectPayload(
            name: "Garden",
            color: "hsl(120 50% 40%)",
            sortOrder: nil
        )
        let stub = repo.create(payload)

        // Local stub with the optimistic name + colour.
        let allProjects = try repoContext.fetch(FetchDescriptor<LocalProject>())
        XCTAssertEqual(allProjects.count, 1)
        XCTAssertEqual(allProjects.first?.id, stub.id)
        XCTAssertEqual(allProjects.first?.name, "Garden")
        XCTAssertEqual(allProjects.first?.color, "hsl(120 50% 40%)")

        // Queue holds a matching .createProject row keyed on the same
        // client UUID. (`.createProject` is currently `notImplemented`
        // in `executeMutation` — Wave 2-3 will wire the wire-side; the
        // queue still accepts the row at enqueue time, which is what
        // matters for Wave 1.)
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createProject.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, stub.id)

        // Status store .pending under the client UUID.
        guard case .pending = store.status(for: stub.id) else {
            XCTFail("repo.create should mark .pending under clientId")
            return
        }
    }

    // MARK: - Section direct-call path (Wave 4 will refactor)

    /// Spec §8.6: `addSection` is direct-call in Wave 1. Verify the
    /// optimistic local section insert succeeds without crashing — the
    /// async server call fires in a Task and is allowed to fail
    /// (no real server in tests). The test asserts on the local
    /// SwiftData state, not the network.
    func testAddSection_insertsLocally() throws {
        let (_, repo, _, _, repoContext) = try makeFixture()

        let project = LocalProject(
            id: "44444444-4444-4444-4444-444444444444",
            shortId: "p1",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        let section = repo.addSection(to: project, name: "Pruning")

        // Local row inserted with a placeholder slug. The slug shape
        // is intentionally tmp-prefixed so a regression that stops
        // overwriting it via sync delivery is visible.
        XCTAssertEqual(section.name, "Pruning")
        XCTAssertTrue(
            section.slug.hasPrefix("tmp-"),
            "expected tmp-prefixed placeholder slug, got \(section.slug)"
        )
        XCTAssertEqual(section.project?.id, project.id)
    }

    // MARK: - Reorder is explicit-stub

    /// Spec §3: `reorderSections` throws `unimplemented` because
    /// sortOrder / drag-reorder is its own follow-up milestone. Locks
    /// the contract so a future caller doesn't silently get a no-op.
    func testReorderSections_throwsUnimplemented() throws {
        let (_, repo, _, _, repoContext) = try makeFixture()
        let project = LocalProject(
            id: "55555555-5555-5555-5555-555555555555",
            shortId: "p2",
            name: "x",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        XCTAssertThrowsError(try repo.reorderSections(of: project, to: ["a", "b"])) { error in
            guard let repoError = error as? ProjectRepository.RepositoryError else {
                XCTFail("expected ProjectRepository.RepositoryError, got \(error)")
                return
            }
            switch repoError {
            case .unimplemented(let detail):
                XCTAssertEqual(detail, "reorderSections")
            }
        }
    }
}
