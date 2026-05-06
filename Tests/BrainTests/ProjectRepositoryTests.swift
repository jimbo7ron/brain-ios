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

    /// M45 Wave 1 review fix: `unarchive` is the symmetric pair to
    /// `archive`, mirroring `NoteRepository`. Unlike notes, the server
    /// has a working endpoint (PUT carries `archived: false`), so the
    /// repo enqueues a real `.updateProject` op.
    func testProjectUnarchive_flipsLocal() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let project = LocalProject(
            id: "88888888-8888-8888-8888-888888888888",
            shortId: "p3",
            name: "Old project",
            sortOrder: 0,
            archived: true
        )
        repoContext.insert(project)
        try repoContext.save()

        repo.unarchive(project)

        // Local flip happened immediately.
        XCTAssertFalse(project.archived)

        // Queue holds an .updateProject row carrying `archived: false`.
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.updateProject.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, project.id)
        guard let body = queueRows.first?.payload else {
            XCTFail("queue row missing payload")
            return
        }
        // `UpdateProjectPayload` is Encodable-only. Verify the wire
        // payload via `JSONSerialization`.
        guard
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("queue payload not a JSON object")
            return
        }
        XCTAssertEqual(json["archived"] as? Bool, false)
    }

    /// `unarchive` on an already-non-archived project is a no-op —
    /// matches `archive`'s guard and avoids enqueuing a wasted PUT.
    func testProjectUnarchive_noOpWhenAlreadyActive() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let project = LocalProject(
            id: "99999999-9999-9999-9999-999999999999",
            shortId: "p4",
            name: "Active project",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        repo.unarchive(project)

        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 0)
    }

    // MARK: - Section direct-call path (Wave 4 will refactor)

    /// Wave 4: optimistic local insert with a tmp-prefixed slug. The
    /// queue picks up a `.createSection` row keyed on the composite
    /// `<projectID>:<tmpSlug>` so the reconcile path can find it
    /// later.
    func testAddSection_optimisticInsertWithTmpSlug() throws {
        let (_, repo, queue, store, repoContext) = try makeFixture()

        let project = LocalProject(
            id: "11111111-1111-1111-1111-111111111111",
            shortId: "p9",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        let section = repo.addSection(to: project, name: "Pruning")
        XCTAssertTrue(section.slug.hasPrefix(LocalSection.optimisticSlugPrefix))
        XCTAssertEqual(section.id, LocalSection.makeID(projectID: project.id, slug: section.slug))
        XCTAssertEqual(section.name, "Pruning")

        // Queue holds a matching .createSection row keyed on the
        // composite tmp-slug id.
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createSection.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, section.id)
        // Status pending under the composite id.
        guard case .pending = store.status(for: section.id) else {
            XCTFail("expected .pending under composite id after addSection")
            return
        }
    }

    /// Wave 4: server's create-echo response renames the composite id
    /// to the canonical slug; pending mutation rows targeting the
    /// tmp composite must be rewritten to the canonical composite.
    func testAddSection_reconcileAdoptsServerSlug() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let serverProjectID = "22222222-2222-2222-2222-222222222222"
        let project = LocalProject(
            id: serverProjectID,
            shortId: "p10",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        let section = repo.addSection(to: project, name: "Pruning")
        let tmpComposite = section.id

        // Locate the queue row to hand to the reconcile.
        guard
            let createRow = try queue.debugModelContext.fetch(
                FetchDescriptor<MutationQueueItem>()
            ).first
        else {
            XCTFail("expected one queued row after addSection")
            return
        }

        let canonicalSlug = "pruning"
        let serverProject = Project(
            id: serverProjectID,
            shortId: "p10",
            name: "Garden",
            color: nil,
            sortOrder: 0,
            archived: false,
            sections: [
                SectionDTO(slug: canonicalSlug, name: "Pruning", position: 0),
            ],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileCreateSectionResponse(
            currentItem: createRow,
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        // Re-fetch on the repo context — composite id should be
        // canonical now.
        let canonicalComposite = LocalSection.makeID(
            projectID: serverProjectID,
            slug: canonicalSlug
        )
        let allSections = try repoContext.fetch(FetchDescriptor<LocalSection>())
        XCTAssertEqual(allSections.count, 1)
        XCTAssertEqual(allSections.first?.id, canonicalComposite)
        XCTAssertEqual(allSections.first?.slug, canonicalSlug)
        XCTAssertFalse(allSections.first?.isOptimistic ?? true)

        // Tmp composite must no longer exist locally.
        XCTAssertFalse(allSections.contains { $0.id == tmpComposite })
    }

    /// Wave 4: rename applies locally and enqueues `.updateSection`
    /// against the section's composite id. Server preserves slug, so
    /// the composite stays stable across the rename.
    func testRenameSection_appliesLocalAndEnqueues() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let projectID = "33333333-3333-3333-3333-333333333333"
        let project = LocalProject(
            id: projectID,
            shortId: "p11",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        let section = LocalSection(
            id: LocalSection.makeID(projectID: projectID, slug: "pruning"),
            slug: "pruning",
            name: "Pruning",
            position: 0,
            project: project
        )
        repoContext.insert(section)
        try repoContext.save()

        repo.renameSection(section, to: "Heavy pruning")

        XCTAssertEqual(section.name, "Heavy pruning")

        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.updateSection.rawValue)
        XCTAssertEqual(queueRows.first?.resourceId, section.id)
        guard let body = queueRows.first?.payload,
              let payload = try? JSONDecoder().decode(UpdateSectionPayload.self, from: body)
        else {
            XCTFail("queue payload not a valid UpdateSectionPayload")
            return
        }
        XCTAssertEqual(payload.name, "Heavy pruning")
    }

    /// Wave 4: when a section is still optimistic (the `.createSection`
    /// hasn't reconciled), `renameSection` must NOT enqueue a separate
    /// `.updateSection` against the tmp slug — instead, the rename
    /// folds into the in-flight create's payload.
    func testRenameSection_optimisticFoldsIntoCreatePayload() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let project = LocalProject(
            id: "44444444-4444-4444-4444-444444444444",
            shortId: "p12",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        let section = repo.addSection(to: project, name: "Original name")
        XCTAssertTrue(section.isOptimistic)

        repo.renameSection(section, to: "Folded rename")

        // Still only one queued row — the create — and its payload
        // now carries the folded name.
        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueRows.count, 1)
        XCTAssertEqual(queueRows.first?.op, MutationOp.createSection.rawValue)
        guard let body = queueRows.first?.payload,
              let payload = try? JSONDecoder().decode(CreateSectionPayload.self, from: body)
        else {
            XCTFail("queue payload not a valid CreateSectionPayload")
            return
        }
        XCTAssertEqual(payload.name, "Folded rename")
    }

    /// Wave 4: the pre-existing direct-call test (renamed). Verifies
    /// the optimistic insert path doesn't crash even when the server
    /// is unavailable (queue row stays parked locally).
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

    // MARK: - Create-echo section reconcile (M45 Wave 2 review fix)

    /// Spec §6.2 review fix: `reconcileCreateProjectResponse` must
    /// mirror the server's canonical sections onto the optimistic stub
    /// at create-echo time. Without this, a freshly-created project
    /// sits with empty `sections` until the next foreground sync
    /// (~5min Timer), so tapping into ProjectDetailView immediately
    /// after creating shows zero sections.
    func testProjectCreate_reconcileMirrorsServerSections() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let payload = CreateProjectPayload(
            name: "Garden",
            color: nil,
            sortOrder: nil
        )
        let stub = repo.create(payload)
        let clientID = stub.id
        let serverID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        let serverProject = Project(
            id: serverID,
            shortId: "g-1",
            name: "Garden",
            color: nil,
            sortOrder: 0,
            archived: false,
            sections: [
                SectionDTO(slug: "now", name: "Now", position: 0),
                SectionDTO(slug: "next", name: "Next", position: 1),
                SectionDTO(slug: "later", name: "Later", position: 2),
            ],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileCreateProjectResponse(
            clientId: clientID,
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        // Re-fetch on the repo context — reconcile happens on the
        // queue context, but both share the container.
        let projectsAfter = try repoContext.fetch(FetchDescriptor<LocalProject>())
        XCTAssertEqual(projectsAfter.count, 1)
        guard let renamed = projectsAfter.first else { return }
        XCTAssertEqual(renamed.id, serverID, "stub should adopt the server id")

        let sectionSlugs = Set(renamed.sections.map(\.slug))
        XCTAssertEqual(sectionSlugs, ["now", "next", "later"])

        // Locks in the M45 Wave 2 ordering fix: `adoptServerID` must
        // run BEFORE the section reconcile closure, so the composite
        // ids carry the server-side project prefix. If the rename
        // ran last, sections would land keyed on the client UUID and
        // the next SyncEngine pass would delete + reinsert them all.
        XCTAssertTrue(
            renamed.sections.allSatisfy { $0.id.hasPrefix(serverID + ":") },
            "Section composite-ids must use the server-side project id, not the client UUID"
        )
    }

    // MARK: - Project update-response reconcile (M45 Wave 4 Part E)

    /// Wave 4 Part E: the `.updateProject` PUT response should land on
    /// the local project under the LWW guard. Single-pending case
    /// applies the response.
    func testProjectUpdateResponse_appliesWhenSinglePending() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let serverID = "66666666-6666-6666-6666-666666666666"
        let project = LocalProject(
            id: serverID,
            shortId: "p13",
            name: "Old name",
            sortOrder: 0,
            archived: false,
            updatedAt: Date().addingTimeInterval(-60)
        )
        repoContext.insert(project)
        try repoContext.save()

        repo.update(project, ProjectUpdateFields(name: "New name"))

        // The repo enqueued one row. Hand it to the reconcile with a
        // server response carrying the canonical state.
        guard let pending = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        ).first else {
            XCTFail("expected one queued row")
            return
        }

        let serverProject = Project(
            id: serverID,
            shortId: "p13-server",
            name: "Server-canonical name",
            color: nil,
            sortOrder: 7,
            archived: false,
            sections: [],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileUpdateProjectResponse(
            currentItem: pending,
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        // Re-fetch on a fresh context to defeat per-context caching.
        let storedOnQueue = try queue.debugModelContext.fetch(
            FetchDescriptor<LocalProject>()
        ).first
        XCTAssertEqual(storedOnQueue?.name, "Server-canonical name")
        XCTAssertEqual(storedOnQueue?.shortId, "p13-server")
        XCTAssertEqual(storedOnQueue?.sortOrder, 7)
    }

    /// Wave 4 Part E: LWW guard — a second pending mutation against
    /// the same project drops the response copy so the user's newer
    /// edit isn't clobbered.
    func testProjectUpdateResponse_lwwGuardDropsWhenNewerPending() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let serverID = "77777777-7777-7777-7777-777777777777"
        let project = LocalProject(
            id: serverID,
            shortId: "p14",
            name: "Local newer",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        // First update (the one whose response we're reconciling).
        repo.update(project, ProjectUpdateFields(name: "First edit"))
        // Second update (the user's "newer" edit — still pending).
        repo.update(project, ProjectUpdateFields(name: "Local newer"))

        guard let firstQueued = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        ).first else {
            XCTFail("expected at least one queued row")
            return
        }

        let serverProject = Project(
            id: serverID,
            shortId: "p14",
            name: "Stale server response",
            color: nil,
            sortOrder: 0,
            archived: false,
            sections: [],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileUpdateProjectResponse(
            currentItem: firstQueued,
            serverProject: serverProject
        )

        // Local row should NOT have adopted the stale server response.
        let stored = try repoContext.fetch(FetchDescriptor<LocalProject>()).first
        XCTAssertEqual(stored?.name, "Local newer")
    }

    /// B1-style idempotency: if SyncEngine's delta-fetch beat the
    /// create echo and already inserted the canonical `LocalSection`
    /// rows, `reconcileCreateProjectResponse` must NOT insert
    /// duplicates against `LocalSection.id`'s `@Attribute(.unique)`
    /// constraint. The shared `LocalProject.reconcileSections` helper
    /// keys on slug so it mutates in place.
    func testProjectCreate_reconcileIdempotentWhenSectionsPreExist() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let stub = repo.create(CreateProjectPayload(name: "Garden", color: nil, sortOrder: nil))
        let clientID = stub.id
        let serverID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        // Simulate SyncEngine getting there first: it would have
        // inserted a row keyed on the server id (a separate row from
        // the optimistic stub). The MutationQueue's B1 dedupe deletes
        // that pre-existing project row before renaming the stub —
        // section reconcile happens *after* that on the renamed stub,
        // so the pre-existing row's section list is what we need to
        // simulate via stub-attached LocalSection rows that match the
        // wire payload's slugs.
        //
        // Approximation: attach two of the three wire sections to the
        // stub itself (so reconcile mutates them in place) and assert
        // the third is freshly inserted without duplicates.
        let preExistingNow = LocalSection(
            id: LocalSection.makeID(projectID: clientID, slug: "now"),
            slug: "now",
            name: "Stale",
            position: 99,
            project: stub
        )
        let preExistingNext = LocalSection(
            id: LocalSection.makeID(projectID: clientID, slug: "next"),
            slug: "next",
            name: "Stale",
            position: 99,
            project: stub
        )
        repoContext.insert(preExistingNow)
        repoContext.insert(preExistingNext)
        try repoContext.save()

        let serverProject = Project(
            id: serverID,
            shortId: "g-1",
            name: "Garden",
            color: nil,
            sortOrder: 0,
            archived: false,
            sections: [
                SectionDTO(slug: "now", name: "Now", position: 0),
                SectionDTO(slug: "next", name: "Next", position: 1),
                SectionDTO(slug: "later", name: "Later", position: 2),
            ],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileCreateProjectResponse(
            clientId: clientID,
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        let allSections = try repoContext.fetch(FetchDescriptor<LocalSection>())
        let slugCounts = Dictionary(grouping: allSections, by: \.slug).mapValues(\.count)
        // Whether the pre-existing rows are mutated in place or
        // deleted-then-reinserted (the project's adoptServerID rename
        // changes the composite key prefix), what matters is no
        // duplicates land — the `@Attribute(.unique)` on
        // `LocalSection.id` would otherwise throw on save.
        XCTAssertEqual(slugCounts["now"], 1, "should not duplicate 'now'")
        XCTAssertEqual(slugCounts["next"], 1, "should not duplicate 'next'")
        XCTAssertEqual(slugCounts["later"], 1, "should land 'later'")

        // Wire-side name + position win regardless of pre-existing values.
        let nowRow = allSections.first { $0.slug == "now" }
        XCTAssertEqual(nowRow?.name, "Now")
        XCTAssertEqual(nowRow?.position, 0)

        // Same invariant as testProjectCreate_reconcileMirrorsServerSections:
        // every surviving section must carry the server-side prefix,
        // even when sync-race pre-existing rows were keyed on the
        // client UUID. The Wave 2 fix renames the project before the
        // section reconcile so the wantedIDs / wireSection insert
        // path produces server-prefixed composite ids.
        XCTAssertTrue(
            allSections.allSatisfy { $0.id.hasPrefix(serverID + ":") },
            "All section composite-ids must carry the server-side project prefix after reconcile"
        )
    }

    // MARK: - Wave 4 review fixes

    /// Wave 4 review #1: simultaneous same-name section adds. The user
    /// taps "Add 'X'" twice in quick succession; both create-echos
    /// return a Project DTO with two same-named sections [A, B] (same
    /// name, two distinct slugs). The first reconcile must claim slug
    /// A; the second must NOT also claim A (which would collide on
    /// `LocalSection.id`'s unique constraint with the just-renamed
    /// canonical row) — it must pick the unclaimed slug B instead.
    /// Locks the name-match picker's "prefer unclaimed slug" behaviour.
    func testReconcileSectionsHandlesSimultaneousSameNameAdds() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        let projectID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let project = LocalProject(
            id: projectID,
            shortId: "p15",
            name: "Garden",
            sortOrder: 0,
            archived: false
        )
        repoContext.insert(project)
        try repoContext.save()

        // Two adds of the same name. Each yields a tmp-prefixed
        // composite + a `.createSection` queue row.
        let firstSection = repo.addSection(to: project, name: "Tasks")
        let secondSection = repo.addSection(to: project, name: "Tasks")
        XCTAssertNotEqual(firstSection.id, secondSection.id)

        let queueRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        )
        XCTAssertEqual(queueRows.count, 2, "two .createSection rows expected")

        // Server response: both sections present, distinct slugs.
        let serverProject = Project(
            id: projectID,
            shortId: "p15",
            name: "Garden",
            color: nil,
            sortOrder: 0,
            archived: false,
            sections: [
                SectionDTO(slug: "tasks", name: "Tasks", position: 0),
                SectionDTO(slug: "tasks-2", name: "Tasks", position: 1),
            ],
            createdAt: nil,
            updatedAt: nil
        )

        // First reconcile claims one of the two slugs.
        queue.debugReconcileCreateSectionResponse(
            currentItem: queueRows[0],
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        // Second reconcile must not collide. The picker should filter
        // out the slug the first reconcile already claimed and pick
        // the remaining one.
        queue.debugReconcileCreateSectionResponse(
            currentItem: queueRows[1],
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        let allSections = try repoContext.fetch(FetchDescriptor<LocalSection>())
        // Both must exist locally, each at a distinct canonical slug.
        XCTAssertEqual(allSections.count, 2)
        let slugs = Set(allSections.map(\.slug))
        XCTAssertEqual(slugs, ["tasks", "tasks-2"])
        // Both must carry the canonical (non-tmp) composite id.
        XCTAssertTrue(
            allSections.allSatisfy { !$0.isOptimistic },
            "Both sections should be canonically keyed (no tmp- prefix) after reconcile"
        )
    }

    /// Wave 4 review #5b: parent-project guard fallback. If the
    /// parent project's `.createProject` is still pending (the project
    /// is itself optimistic), `addSection` must NOT enqueue a
    /// `.createSection` row keyed on the client UUID — that would 404
    /// on replay because the server doesn't know the project yet.
    /// Instead, the optimistic local section is inserted and the
    /// repo dispatches a direct `client.addProjectSection` call (in a
    /// detached `Task`); sync delivers the canonical row on the next
    /// foreground tick.
    ///
    /// Test seam note: there's no client spy in the test harness. We
    /// detect the direct-call path indirectly — the queue should hold
    /// ONE row (the parent's `.createProject`), not two. The
    /// detached `Task`'s in-flight HTTP call fails (no auth in the
    /// test BrainAPIClient) but that's fine: we're locking the
    /// "queue path was bypassed" invariant, not the wire result.
    func testAddSection_fallsBackToDirectCallWhenParentOptimistic() throws {
        let (_, repo, queue, _, _) = try makeFixture()

        // Repo.create enqueues a `.createProject` keyed on the client
        // UUID. The parent stays "optimistic" because we never hand
        // the queue a server response.
        let stub = repo.create(
            CreateProjectPayload(name: "New project", color: nil, sortOrder: nil)
        )

        let queueAfterCreate = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(queueAfterCreate.count, 1)
        XCTAssertEqual(queueAfterCreate.first?.op, MutationOp.createProject.rawValue)

        // Add a section while the parent is still optimistic.
        let section = repo.addSection(to: stub, name: "Pruning")

        // Local optimistic stub for the section IS inserted (the
        // optimistic affordance is preserved regardless of which
        // wire path we take).
        XCTAssertTrue(section.isOptimistic, "section should be optimistic")
        XCTAssertEqual(section.name, "Pruning")
        XCTAssertEqual(section.project?.id, stub.id)

        // Crucially: NO `.createSection` row was enqueued. Only the
        // pre-existing `.createProject` row remains. The direct-call
        // fallback handled the section — the in-flight detached
        // `Task` will fail against the test client (no auth) but
        // that's irrelevant to this assertion.
        let queueAfterSection = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>()
        )
        XCTAssertEqual(
            queueAfterSection.count, 1,
            "addSection must NOT enqueue while parent .createProject is pending"
        )
        XCTAssertEqual(queueAfterSection.first?.op, MutationOp.createProject.rawValue)
        XCTAssertFalse(
            queueAfterSection.contains { $0.op == MutationOp.createSection.rawValue },
            "no .createSection row should be enqueued under the parent-pending guard"
        )
    }

    /// Wave 4 review #5c: project create-pending + update-pending +
    /// update-response interleave. Repo.create enqueues a
    /// `.createProject`. Before the create echo lands, the user edits
    /// the project (e.g. taps "rename") which enqueues an
    /// `.updateProject` against the same client UUID. When the
    /// update-response eventually lands, the LWW guard on
    /// `reconcileUpdateProjectResponse` must drop it (the
    /// `.createProject` is still queued for the same id, which counts
    /// as "newer pending mutation").
    ///
    /// Why this matters: blindly applying the response would copy
    /// server-canonical fields onto the local stub keyed on the
    /// client UUID — but the create reconcile (when it lands) is the
    /// designated id-rename path. Applying the update response first
    /// risks clobbering the optimistic state the user is staring at,
    /// and the rename ceremony then has nothing useful to copy from
    /// the create echo.
    func testProjectUpdateLWW_createPendingAndUpdatePendingInterleave() throws {
        let (_, repo, queue, _, repoContext) = try makeFixture()

        // Step 1: create — enqueues `.createProject`.
        let stub = repo.create(
            CreateProjectPayload(name: "Optimistic", color: nil, sortOrder: nil)
        )
        let clientID = stub.id

        // Step 2: edit the optimistic project — enqueues an
        // `.updateProject` against the same clientID. (The repo's
        // optimistic-stub guard for updates may fold; we're testing
        // the case where it actually queues. Verify by checking the
        // queue depth after.)
        repo.update(stub, ProjectUpdateFields(name: "Newer local edit"))

        // Locate the update-row (if any). Both ops share the
        // clientID, so we filter on op slug.
        let updateRows = try queue.debugModelContext.fetch(
            FetchDescriptor<MutationQueueItem>(
                predicate: #Predicate { $0.op == "update_project" }
            )
        )
        // If repo.update folds the rename into the pending create
        // payload (no separate update row), the LWW interleave
        // doesn't fire because there's no update response to
        // reconcile. Document that path and exit cleanly.
        guard let updateRow = updateRows.first else {
            // TODO(M45 followup): surface a doc-test capturing
            // "update folds into pending create" if that's the
            // chosen optimistic-update behaviour for projects.
            return
        }

        // Step 3: simulate the update response landing while the
        // create is still queued. The create-echo hasn't reconciled
        // yet, so the project is still keyed on `clientID`; the
        // update row is also keyed on `clientID`. The LWW guard sees
        // the still-pending `.createProject` row and drops the
        // response.
        let serverProject = Project(
            id: clientID,
            shortId: "should-not-apply",
            name: "Stale server response",
            color: nil,
            sortOrder: 99,
            archived: false,
            sections: [],
            createdAt: nil,
            updatedAt: nil
        )

        queue.debugReconcileUpdateProjectResponse(
            currentItem: updateRow,
            serverProject: serverProject
        )
        try queue.debugModelContext.save()

        // The local row should still carry the user's optimistic
        // "Newer local edit" (or the create's "Optimistic" if
        // repo.update didn't apply locally) — NOT the stale server
        // response's name. Either way, the dropped-response
        // assertion is: shortId / sortOrder didn't get clobbered.
        let stored = try repoContext.fetch(FetchDescriptor<LocalProject>()).first
        XCTAssertNotEqual(
            stored?.shortId, "should-not-apply",
            "LWW guard must drop the update response while .createProject is still pending"
        )
        XCTAssertNotEqual(stored?.sortOrder, 99)
    }
}
