// ProjectRepository.swift
// brain-ios
//
// M45 Wave 1: project-side write contract. Same shape as
// `NoteRepository` for create / update / archive — optimistic local
// mutation + enqueue + status-store-pending — plus multi-step section
// ops that don't fit the `OptimisticStub` ceremony cleanly (per spec
// §4.5 and §8.6).
//
// **Section ops are direct-call for now**: `LocalSection` keys on a
// composite id (`projectID:slug`), not a single UUID, so the
// `OptimisticStub` protocol's `adoptServerID(_ String)` doesn't fit. The
// spec defers a proper `OptimisticCompositeStub` to Wave 4; until then
// `addSection` and `renameSection` perform direct `await
// client.addProjectSection` / `client.renameProjectSection` calls and
// rely on the next sync delta to land the server's authoritative view.
// `reorderSections` is a sortOrder problem and stays explicit-stub
// (throws `unimplemented`) per spec §3.
//
// See `docs/M45-write-coordinator.md` for the full migration plan.

import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ProjectRepository {

    // MARK: - Errors

    /// Thrown by the explicit-stub paths (`reorderSections`) so the
    /// caller knows Wave 1 didn't ship the implementation. Picked over
    /// returning silently because the next milestone (sortOrder) needs
    /// to fail loudly if a view accidentally calls into it before the
    /// server's renumber endpoint is wired.
    enum RepositoryError: Swift.Error, CustomStringConvertible {
        case unimplemented(String)

        var description: String {
            switch self {
            case .unimplemented(let detail):
                return "ProjectRepository: \(detail) is not implemented yet."
            }
        }
    }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let queue: MutationQueue?
    private let statusStore: MutationStatusStore?
    private let client: BrainAPIClient?

    // MARK: - Init

    /// Construct against the shared `ModelContainer`'s third
    /// `ModelContext` (alongside the queue's, the SyncEngine's, and the
    /// SwiftUI environment context). `client` is held for the section-
    /// op direct-call path; `queue` + `statusStore` for the create /
    /// update / archive optimistic path.
    init(
        modelContext: ModelContext,
        queue: MutationQueue?,
        statusStore: MutationStatusStore?,
        client: BrainAPIClient?
    ) {
        self.modelContext = modelContext
        self.queue = queue
        self.statusStore = statusStore
        self.client = client
    }

    // MARK: - Create

    /// Optimistically insert a new project locally and enqueue the
    /// matching `.createProject` mutation. Returns the SwiftData row so
    /// callers can navigate to it. The row's `id` is a client UUID
    /// until the queue's reconcile (Wave 2 wiring of
    /// `executeMutation(.createProject)`) renames it to the server-
    /// issued id.
    ///
    /// Default sections: the server applies M26's Now/Next/Later when
    /// the create payload omits `sections`, and the next sync delta
    /// lands them locally. The optimistic local row therefore ships
    /// with an empty `sections` relationship — UI that depends on
    /// section presence (project detail screens) should fall back to
    /// the inbox bucket until the sync delivery completes.
    @discardableResult
    func create(_ payload: CreateProjectPayload) -> LocalProject {
        let clientID = UUID().uuidString.lowercased()
        let now = Date()
        let stub = LocalProject(
            id: clientID,
            shortId: "",
            name: payload.name,
            color: payload.color,
            sortOrder: payload.sortOrder ?? 0,
            archived: false,
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(stub)
        do {
            try modelContext.save()
        } catch {
            NSLog("ProjectRepository.create: save failed for \(clientID): \(error)")
        }

        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("ProjectRepository.create: failed to encode payload for \(clientID)")
            return stub
        }

        enqueue(
            op: .createProject,
            resourceType: "project",
            resourceId: clientID,
            payload: body,
            baseUpdatedAt: nil
        )

        return stub
    }

    // MARK: - Update

    /// Apply a typed diff to a local project and enqueue the matching
    /// `.updateProject` mutation. Only non-nil fields on `fields` are
    /// applied locally and serialised onto the wire.
    func update(_ project: LocalProject, _ fields: ProjectUpdateFields) {
        let base = project.updatedAt

        if let name = fields.name { project.name = name }
        if let color = fields.color {
            project.color = color.isEmpty ? nil : color
        }
        if let sortOrder = fields.sortOrder { project.sortOrder = sortOrder }
        project.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("ProjectRepository.update: save failed for \(project.id): \(error)")
        }

        let payload = UpdateProjectPayload(
            name: fields.name,
            color: fields.color,
            sortOrder: fields.sortOrder,
            archived: nil
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("ProjectRepository.update: failed to encode payload for \(project.id)")
            return
        }

        enqueue(
            op: .updateProject,
            resourceType: "project",
            resourceId: project.id,
            payload: body,
            baseUpdatedAt: base
        )
    }

    // MARK: - Archive

    /// Optimistically set `archived = true` and enqueue an
    /// `.updateProject` carrying `archived: true` — the server has no
    /// dedicated archive-project endpoint, so the partial-update path
    /// is the existing wire shape. Sectioning out an `archiveProject`
    /// op slug would require server changes that aren't in scope for
    /// Wave 1.
    func archive(_ project: LocalProject) {
        guard !project.archived else { return }
        let base = project.updatedAt
        project.archived = true
        project.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("ProjectRepository.archive: save failed for \(project.id): \(error)")
        }

        let payload = UpdateProjectPayload(
            name: nil,
            color: nil,
            sortOrder: nil,
            archived: true
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("ProjectRepository.archive: failed to encode payload for \(project.id)")
            return
        }

        enqueue(
            op: .updateProject,
            resourceType: "project",
            resourceId: project.id,
            payload: body,
            baseUpdatedAt: base
        )
    }

    /// Optimistically set `archived = false` and enqueue an
    /// `.updateProject` carrying `archived: false`. Symmetric with
    /// `archive(_:)` and mirrors `NoteRepository.unarchive` —
    /// added in the M45 Wave 1 review pass so Wave 3 view migrations
    /// have the matching pair without a contract change.
    ///
    /// **Server endpoint**: unlike notes, the server's `ProjectUpdate`
    /// schema *does* carry an `archived` field (verified against
    /// `brain/src/brain/schemas.py:ProjectUpdate` and
    /// `server.py:2219-2220`), so we enqueue a real `.updateProject`
    /// op rather than NSLog-and-skip. The server will flip
    /// `projects.archived` back to false when the queue replays the
    /// PUT.
    func unarchive(_ project: LocalProject) {
        guard project.archived else { return }
        let base = project.updatedAt
        project.archived = false
        project.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            NSLog("ProjectRepository.unarchive: save failed for \(project.id): \(error)")
        }

        let payload = UpdateProjectPayload(
            name: nil,
            color: nil,
            sortOrder: nil,
            archived: false
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            NSLog("ProjectRepository.unarchive: failed to encode payload for \(project.id)")
            return
        }

        enqueue(
            op: .updateProject,
            resourceType: "project",
            resourceId: project.id,
            payload: body,
            baseUpdatedAt: base
        )
    }

    // MARK: - Section ops (multi-step)

    /// Append a section to a project (M45 Wave 4). Optimistic-path
    /// migration of the previous Wave-1 direct-call: mints a
    /// `tmp-<uuid>`-prefixed placeholder slug, inserts the
    /// `LocalSection` stub, and enqueues a `.createSection` row
    /// targeting the composite id `<projectID>:<tmp-slug>`. The
    /// queue's reconcile path (see
    /// `MutationQueue.reconcileCreateSectionResponse`) finds the new
    /// section in the server response by matching on the requested
    /// `name`, renames the composite id from `tmp-<uuid>` to the
    /// canonical server slug, and rewrites any pending mutation rows
    /// targeting the temporary composite to the canonical one.
    ///
    /// **Sync-race / parent-project safeguard:** if the parent
    /// project's own create echo hasn't reconciled yet (rapid
    /// "create project then add section before the create echo
    /// returns"), the section's composite id would carry the *client*
    /// project UUID, and the queue can't safely fire the section
    /// create until the project rename lands. We detect this by
    /// looking for a pending `.createProject` queue row keyed on the
    /// parent's id and **fall back to a direct call** so the section
    /// lands cleanly on the server-side project. Sync will deliver
    /// the canonical section on the next foreground tick. Documented
    /// in spec §8.6 / Wave 4 part A.
    @discardableResult
    func addSection(to project: LocalProject, name: String) -> LocalSection {
        let projectID = project.id
        let placeholderSlug = LocalSection.optimisticSlugPrefix
            + UUID().uuidString.lowercased().prefix(8)
        let composite = LocalSection.makeID(
            projectID: projectID,
            slug: String(placeholderSlug)
        )
        let section = LocalSection(
            id: composite,
            slug: String(placeholderSlug),
            name: name,
            position: project.sections.count,
            project: project
        )
        modelContext.insert(section)
        project.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            NSLog("ProjectRepository.addSection: save failed for \(projectID): \(error)")
        }

        // Parent-project guard: if a `.createProject` is still pending
        // for the parent, the project's own id is the client UUID and
        // the server doesn't know about it yet. Fall back to direct
        // call so the section lands on the server-side project; the
        // local optimistic stub stays put and gets reconciled by the
        // next sync delivery (sync's `reconcileSections` is
        // idempotent against the slug-keyed lookup).
        if let queue, let parentPending = queue.pendingMutation(forResourceId: projectID),
           parentPending.op == MutationOp.createProject.rawValue {
            NSLog(
                "ProjectRepository.addSection: parent project \(projectID) " +
                "still has a pending .createProject — falling back to direct " +
                "call so the section attaches to the server-side project."
            )
            if let client {
                Task { [client] in
                    do {
                        _ = try await client.addProjectSection(
                            projectId: projectID,
                            name: name
                        )
                    } catch {
                        NSLog(
                            "ProjectRepository.addSection: direct fallback " +
                            "failed for \(projectID) / \(name): \(error)."
                        )
                    }
                }
            }
            return section
        }

        guard let body = try? JSONEncoder().encode(CreateSectionPayload(name: name)) else {
            NSLog("ProjectRepository.addSection: failed to encode payload.")
            return section
        }

        enqueue(
            op: .createSection,
            resourceType: "section",
            resourceId: composite,
            payload: body,
            baseUpdatedAt: nil
        )

        return section
    }

    /// Rename a section (M45 Wave 4). Optimistic-path migration of
    /// the Wave-1 direct-call: applies the new name locally and
    /// enqueues a `.updateSection` row keyed on the section's
    /// composite id `<projectID>:<slug>`.
    ///
    /// **Slug stability**: the brain server preserves the slug
    /// server-side on rename (verified against
    /// `BrainAPIClient.renameProjectSection`'s contract — the slug is
    /// path-only, the body carries `{name}`). The reconcile path
    /// re-mirrors the server's canonical sections via
    /// `LocalProject.reconcileSections` so any drift in slug or
    /// position is corrected in lock-step.
    ///
    /// **Optimistic-stub guard**: when the section is still
    /// optimistic (`tmp-<uuid>` slug — the `.createSection` for it
    /// hasn't reconciled yet), enqueueing an `.updateSection` against
    /// the tmp composite would race the create. Instead, mutate the
    /// optimistic local row's `name` in place — the create
    /// reconcile's response carries the latest name (the server
    /// extracts it from the request body), so the rename is
    /// effectively folded into the in-flight create.
    func renameSection(_ section: LocalSection, to newName: String) {
        guard let project = section.project else {
            NSLog("ProjectRepository.renameSection: section has no project.")
            return
        }
        let base = project.updatedAt
        section.name = newName
        project.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            NSLog(
                "ProjectRepository.renameSection: save failed for " +
                "\(section.id): \(error)"
            )
        }

        // Optimistic-stub guard: the create echo for this section
        // hasn't reconciled, so the queue still has a `.createSection`
        // row targeting the tmp composite. We can't enqueue a
        // .updateSection against a tmp slug (the server doesn't know
        // it). The optimistic apply above is enough — the next replay
        // of the .createSection will pick up the latest `section.name`
        // because we never re-encode the body... wait — the payload
        // is fixed at enqueue time. Best fallback: rewrite the queued
        // .createSection row's payload to carry the new name. That
        // way the eventual server create uses the renamed value.
        if section.isOptimistic {
            if let queue,
               let pendingCreate = queue.pendingMutation(forResourceId: section.id),
               pendingCreate.op == MutationOp.createSection.rawValue,
               let body = try? JSONEncoder().encode(CreateSectionPayload(name: newName))
            {
                pendingCreate.payload = body
                NSLog(
                    "ProjectRepository.renameSection: section \(section.id) " +
                    "is still optimistic — folded the rename into the " +
                    "pending .createSection payload."
                )
            }
            return
        }

        guard let body = try? JSONEncoder().encode(UpdateSectionPayload(name: newName)) else {
            NSLog("ProjectRepository.renameSection: failed to encode payload.")
            return
        }

        enqueue(
            op: .updateSection,
            resourceType: "section",
            resourceId: section.id,
            payload: body,
            baseUpdatedAt: base
        )
    }

    /// Reorder a project's sections. Throws `unimplemented` per spec
    /// §3 — multi-record renumbering is its own milestone (FIFO ordering
    /// vs LWW base comparison across siblings). The signature is
    /// pinned now so Wave 4 / the sortOrder milestone can fill it in
    /// without a contract change.
    func reorderSections(of project: LocalProject, to ids: [String]) throws {
        _ = (project, ids)
        throw RepositoryError.unimplemented("reorderSections")
    }

    // MARK: - Internal helpers

    /// Same shape as `NoteRepository.enqueue`. Centralises the
    /// `queue.enqueue + statusStore.mark(.pending)` pairing.
    private func enqueue(
        op: MutationOp,
        resourceType: String,
        resourceId: String,
        payload: Data,
        baseUpdatedAt: Date?
    ) {
        guard let queue else { return }
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
            NSLog(
                "ProjectRepository.enqueue: failed to enqueue \(op.rawValue) " +
                "for \(resourceId): \(error). Local mutation remains; " +
                "next sync will reconcile."
            )
        }
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `ProjectRepository` via
/// `@Environment(\.projectRepository)`. Same pattern as `\.noteRepository`.
private struct ProjectRepositoryKey: EnvironmentKey {
    static let defaultValue: ProjectRepository? = nil
}

extension EnvironmentValues {
    var projectRepository: ProjectRepository? {
        get { self[ProjectRepositoryKey.self] }
        set { self[ProjectRepositoryKey.self] = newValue }
    }
}
