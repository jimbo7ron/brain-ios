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
    /// the unassigned bucket until the sync delivery completes.
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

    // MARK: - Section ops (multi-step)

    /// Append a section to a project. Wave 1 ships this as a direct-
    /// call (NOT optimistic) because `LocalSection`'s composite id
    /// (`projectID:slug`) doesn't fit the single-UUID `OptimisticStub`
    /// protocol. Wave 4 will introduce an `OptimisticCompositeStub`
    /// sibling and migrate this to the optimistic path; the spec
    /// (§8.6) tracks the deferral.
    ///
    /// The async direct call returns the full project, so the next
    /// sync delivery + change-coalescing rewrites the local
    /// `LocalSection` set against the server's authoritative slug +
    /// position. Returning a `LocalSection` placeholder for the caller
    /// here means the UI (Wave 4) can stand in a row until the sync
    /// arrives, but it's a best-effort stub and any caller that needs
    /// the canonical server slug must wait for the next sync.
    @discardableResult
    func addSection(to project: LocalProject, name: String) -> LocalSection {
        // Optimistic local insert with a placeholder slug derived from
        // the name. The slug will be rewritten by the sync delta after
        // the server's canonical slug ships back. This is best-effort
        // — if a caller passes a name that the server rejects, the
        // sync won't deliver a row to overwrite this one and the
        // placeholder will sit until the user retries.
        let placeholderSlug = "tmp-" + UUID().uuidString.lowercased().prefix(8)
        let section = LocalSection(
            id: LocalSection.makeID(projectID: project.id, slug: String(placeholderSlug)),
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
            NSLog("ProjectRepository.addSection: save failed for \(project.id): \(error)")
        }

        // TODO(M45 Wave 4): migrate to OptimisticCompositeStub. See
        // spec §4.5 / §8.6 for the composite-id rationale; the section
        // case can't ride the `OptimisticStub` ceremony because
        // `adoptServerID(_ String)` assumes a single-UUID identity.
        guard let client else {
            NSLog("ProjectRepository.addSection: no client; local-only insert.")
            return section
        }
        Task { [client] in
            do {
                _ = try await client.addProjectSection(
                    projectId: project.id,
                    name: name
                )
                // Sync delta lands the canonical section; the
                // placeholder above will be tombstoned by the sync
                // engine's section reconcile (handled in `SyncEngine`).
            } catch {
                NSLog(
                    "ProjectRepository.addSection: server call failed for " +
                    "\(project.id) / \(name): \(error). Placeholder section " +
                    "remains until next sync overwrites."
                )
            }
        }

        return section
    }

    /// Rename a section. Same direct-call rationale as `addSection` —
    /// `LocalSection` keys on a composite id, the spec defers the
    /// optimistic path to Wave 4. Apply the local rename and fire the
    /// HTTP call; the sync delta reconciles the canonical state.
    func renameSection(_ section: LocalSection, to newName: String) {
        guard let project = section.project else {
            NSLog("ProjectRepository.renameSection: section has no project.")
            return
        }
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

        // TODO(M45 Wave 4): migrate to OptimisticCompositeStub.
        guard let client else {
            NSLog("ProjectRepository.renameSection: no client; local-only.")
            return
        }
        let projectID = project.id
        let slug = section.slug
        Task { [client] in
            do {
                _ = try await client.renameProjectSection(
                    projectId: projectID,
                    slug: slug,
                    name: newName
                )
            } catch {
                NSLog(
                    "ProjectRepository.renameSection: server call failed " +
                    "for \(projectID):\(slug): \(error). Local rename " +
                    "remains until next sync."
                )
            }
        }
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
