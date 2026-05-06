// OptimisticStub.swift
// brain-ios
//
// M45 Wave 0: a tiny "ceremony-only" protocol that lets `MutationQueue`'s
// reconcile path share the create-echo machinery (B1 dedupe, B2 pending-
// mutation rewrite, stub fetch, id rename) across entity types without
// open-coding the same dance once per resource.
//
// Why not a fatter protocol with an `associatedtype ServerDTO` and a
// generic `reconcileCreate<T>(... copyFields:)` that also forces a
// uniform field-copy contract? Because:
//
//   1. SwiftData's `#Predicate` macro doesn't accept a generic type
//      parameter cleanly on iOS 17. Writing
//      `FetchDescriptor<T>(predicate: #Predicate { $0.id == id })` either
//      fails to compile or runtime-faults when the macro can't reify
//      `T.id` against a concrete model. Each concrete model has to
//      declare its own `#Predicate`-based descriptor, which is exactly
//      what `makeFetchByID(_:)` does.
//
//   2. The `@Model` macro's synthesised init doesn't satisfy a protocol
//      requirement of the form `init()`. Anything we'd want to construct
//      generically would have to be threaded through a closure anyway.
//
//   3. The shared part across reconcile paths is the *ceremony* — fetch
//      by id, rewrite stale pending mutations, delete sync-inserted
//      duplicates, rename in place. The *field copy* is meaningfully
//      per-entity (notes have ~22 fields with todo+appointment
//      substructures; projects layer the M26 default-section reconcile
//      on top). Folding the copy into the protocol forces every future
//      entity to fit a contract that doesn't naturally fit.
//
// So the contract here is small: "given an id, here's the FetchDescriptor
// the macro is happy with, and here's how I rename myself to the server's
// canonical id." Everything else stays at the per-entity level, passed
// into `reconcileCreate<T:>` as a closure.
//
// See `docs/M45-write-coordinator.md` §4.2 / §6.4 for the full rationale.

import Foundation
import SwiftData

/// Models that can stand in as an optimistic local row before the server
/// confirms a create. Conforming models declare a fetch descriptor keyed
/// on their `id` field (the only sensible composite is the model's own
/// concrete `#Predicate`) and an `adoptServerID(_:)` mutator that
/// rewrites their primary key in place.
///
/// Note: the conforming model's `id` is a `String` field on the model,
/// NOT SwiftData's `PersistentIdentifier`. That's intentional — we mirror
/// the server's UUID into the SwiftData column directly so cross-context
/// fetches (SwiftUI ↔ MutationQueue ↔ SyncEngine) can resolve a row by
/// the same key the server uses. SwiftData's `@Attribute(.unique)`
/// constraint on the column is rechecked on every save, so renaming the
/// id from a client UUID to the server-issued UUID is legal as long as
/// any duplicate is deleted first (which is exactly what the B1 step in
/// `MutationQueue.reconcileCreate(...)` does).
protocol OptimisticStub: PersistentModel {

    /// Build a `FetchDescriptor<Self>` whose predicate matches the row
    /// whose `id` String column equals `id`. Implemented per-entity so
    /// the `#Predicate` macro can resolve `$0.id` against a concrete
    /// model (see file header for the iOS 17 macro caveat).
    ///
    /// Implementations should set `fetchLimit = 1` — id is unique by
    /// schema constraint, so there can be at most one match anyway.
    static func makeFetchByID(_ id: String) -> FetchDescriptor<Self>

    /// Rewrite the model's `id` String column to the server-issued UUID.
    /// Caller is responsible for ensuring no other row exists under the
    /// new id at save time (otherwise SwiftData's unique constraint will
    /// throw on the next save). The shared ceremony in
    /// `MutationQueue.reconcileCreate(...)` handles the dedupe step
    /// before invoking this mutator.
    func adoptServerID(_ newID: String)
}

/// Sibling of `OptimisticStub` for models whose primary key is a
/// composite id (e.g. `LocalSection`, keyed `"<projectID>:<slug>"` —
/// see `LocalSection.makeID(projectID:slug:)`). Introduced in M45
/// Wave 4 (spec §8.6) when section ops moved through the Repository
/// path. The single-UUID `OptimisticStub.adoptServerID(_:)` doesn't
/// fit because:
///
///   * Renaming a section in place means rewriting only the *slug*
///     half of the composite — the project prefix is stable for the
///     duration of the rename.
///   * The "create" path mints a temporary slug client-side
///     (`tmp-<uuid>`); reconcile rewrites it to the server's
///     canonical slug while the project prefix is unchanged.
///   * Optimistic-vs-canonical detection (`isOptimistic`) is a
///     property of the slug (does it carry the `tmp-` prefix?), not
///     a property of "we have a queued create row". The latter would
///     be true for any queued mutation, which is not the same thing.
///
/// Same `#Predicate` macro caveat as `OptimisticStub`: each
/// conformance owns its own `makeFetchByID(_:)` so the macro can
/// resolve `$0.id` against a concrete model on iOS 17.
protocol OptimisticCompositeStub: PersistentModel {

    /// Fetch the row whose composite `id` equals `id`.
    static func makeFetchByID(_ id: String) -> FetchDescriptor<Self>

    /// Rewrite the model's composite `id` to a new value. For
    /// `LocalSection` that means swapping the `<projectID>:<tmp-slug>`
    /// composite for `<projectID>:<server-slug>` (and updating the
    /// `slug` column alongside so the read-side queries stay in
    /// agreement). Caller is responsible for ensuring no other row
    /// already exists under `newID` at save time.
    func adoptServerID(_ newID: String)

    /// True iff this entity was inserted optimistically with a
    /// client-side composite id and is awaiting reconciliation. For
    /// `LocalSection` this is "does the slug start with the `tmp-`
    /// prefix used by `ProjectRepository.addSection`?". The flag
    /// lets reconcile paths and view code distinguish "this row is
    /// awaiting server confirmation" from "this row IS the canonical
    /// server state" without reaching into a separate
    /// `MutationStatusStore` lookup.
    var isOptimistic: Bool { get }
}

// MARK: - LocalNote conformance

extension LocalNote: OptimisticStub {

    static func makeFetchByID(_ id: String) -> FetchDescriptor<LocalNote> {
        var descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    func adoptServerID(_ newID: String) {
        self.id = newID
    }
}

// MARK: - LocalProject conformance

extension LocalProject: OptimisticStub {

    static func makeFetchByID(_ id: String) -> FetchDescriptor<LocalProject> {
        var descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    func adoptServerID(_ newID: String) {
        self.id = newID
    }
}

// MARK: - LocalSection conformance

extension LocalSection: OptimisticCompositeStub {

    /// Shared `tmp-` prefix used by `ProjectRepository.addSection` to
    /// mint a placeholder slug before the server has assigned the
    /// canonical one. Centralised here so the optimistic-detection
    /// path (`isOptimistic`) and the call-site mint stay in
    /// agreement — a future change to the prefix shape (e.g. `tmp_`,
    /// or a numeric suffix) only flips one constant.
    static let optimisticSlugPrefix = "tmp-"

    static func makeFetchByID(_ id: String) -> FetchDescriptor<LocalSection> {
        var descriptor = FetchDescriptor<LocalSection>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    func adoptServerID(_ newID: String) {
        // Composite id is `"<projectID>:<slug>"`. The caller hands us
        // the full new composite; we update both the `id` column (so
        // `@Attribute(.unique)` constraints / FetchDescriptor lookups
        // resolve to this row) AND the `slug` column (so the read-side
        // section-by-slug queries see the canonical slug). The two are
        // intentionally redundant — see `LocalSection.makeID(...)` —
        // and must stay in agreement.
        self.id = newID
        if let colon = newID.firstIndex(of: ":") {
            self.slug = String(newID[newID.index(after: colon)...])
        }
    }

    var isOptimistic: Bool {
        slug.hasPrefix(Self.optimisticSlugPrefix)
    }
}

// MARK: - LocalNote field copy

extension LocalNote {

    /// Mirror every server-derived field from a `Note` DTO onto this
    /// model in a single pass. Pulled out of the open-coded reconcile
    /// path in `MutationQueue.reconcileCreateResponse` so the per-entity
    /// copy is named, testable, and reusable from a future
    /// `repo.update`-driven reconcile path (Wave 3).
    ///
    /// Behaviour parity: this is the same field list as
    /// `MutationQueue.reconcileCreateResponse` had pre-M45, in the same
    /// order, with the same default fallbacks (`completed` → false,
    /// `priority` → "medium", `sortOrder` → 0). It is also a near-twin
    /// of `SyncEngine.upsert(_ note:)` — the only functional difference
    /// is which date-parser is in scope (`parseServerDate` vs
    /// `parseDate`). The two parsers are documented as equivalent, so
    /// the resulting field values are byte-identical.
    ///
    /// This method does NOT touch `self.id` — the rename happens in
    /// `adoptServerID(_:)` on the M45 ceremony path so the dedupe-then-
    /// rename ordering stays explicit at the call site.
    func copyFields(from note: Note, parseDate: (String?) -> Date?) {
        // IMPORTANT: must not read `self.id`. MutationQueue.reconcileCreate
        // relies on this — see the rename-before-copyFields ordering rationale
        // in MutationQueue.swift's reconcileCreate doc-comment.
        let createdAt = parseDate(note.createdAt)
        let updatedAt = parseDate(note.updatedAt)
        let tagsCSV = note.tags.joined(separator: ",")
        let todo = note.todo
        let appointment = note.appointment

        self.shortId = note.shortId
        self.title = note.title
        self.content = note.content
        self.type = note.type
        self.archived = note.archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tagsCSV = tagsCSV
        self.dueDate = todo?.dueDate
        self.dueTime = todo?.dueTime
        self.completed = todo?.completed ?? false
        self.completedAt = parseDate(todo?.completedAt)
        self.priority = todo?.priority ?? "medium"
        self.recurrence = todo?.recurrence ?? appointment?.recurrence
        self.projectId = todo?.projectId
        self.section = todo?.section
        self.url = todo?.url
        self.urlTitle = todo?.urlTitle
        self.urlState = todo?.urlState
        self.urlFetchedAt = parseDate(todo?.urlFetchedAt)
        self.sortOrder = todo?.sortOrder ?? 0
        self.appointmentStartTime = appointment?.startTime
        self.appointmentEndTime = appointment?.endTime
        self.appointmentLocation = appointment?.location
        self.appointmentRecurrence = appointment?.recurrence
    }
}

// MARK: - LocalProject field copy

extension LocalProject {

    /// Mirror server-derived fields from a `Project` DTO onto this model.
    /// Section reconcile is NOT included here — it lives on the queue's
    /// caller path (or on `SyncEngine.reconcileSections(_:on:)` for the
    /// sync path) because section diffing needs the project's existing
    /// `sections` relationship and cross-entity context that doesn't
    /// belong on this method.
    ///
    /// This method does NOT touch `self.id` — the rename happens in
    /// `adoptServerID(_:)` on the M45 ceremony path. M26's default-
    /// section reconcile is owned by the caller (or by SyncEngine).
    func copyFields(from project: Project, parseDate: (String?) -> Date?) {
        // IMPORTANT: must not read `self.id`. MutationQueue.reconcileCreate
        // relies on this — see the rename-before-copyFields ordering rationale
        // in MutationQueue.swift's reconcileCreate doc-comment.
        self.shortId = project.shortId
        self.name = project.name
        self.color = project.color
        self.sortOrder = project.sortOrder
        self.archived = project.archived
        self.createdAt = parseDate(project.createdAt)
        self.updatedAt = parseDate(project.updatedAt)
    }

    /// Bring `project.sections` into agreement with the wire payload.
    /// Mirrors `SyncEngine.reconcileSections` but lives here so the
    /// M45 Wave 2 project-create reconcile path (`MutationQueue`) can
    /// share the diff-and-insert logic without each call site open-
    /// coding the same dedupe.
    ///
    /// Idempotency (B1): if a sync delta already inserted the canonical
    /// `LocalSection` rows for this project while the create echo was
    /// in flight, the slug-keyed lookup mutates them in place rather
    /// than inserting duplicates against `LocalSection.id`'s
    /// `@Attribute(.unique)` constraint.
    ///
    /// The caller is responsible for `modelContext.save()`.
    static func reconcileSections(
        _ wireSections: [SectionDTO],
        on project: LocalProject,
        in modelContext: ModelContext
    ) {
        let projectID = project.id
        let wantedIDs = Set(wireSections.map { LocalSection.makeID(projectID: projectID, slug: $0.slug) })

        for existing in project.sections where !wantedIDs.contains(existing.id) {
            modelContext.delete(existing)
        }

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
}
