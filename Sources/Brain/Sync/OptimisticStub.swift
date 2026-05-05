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
        self.shortId = project.shortId
        self.name = project.name
        self.color = project.color
        self.sortOrder = project.sortOrder
        self.archived = project.archived
        self.createdAt = parseDate(project.createdAt)
        self.updatedAt = parseDate(project.updatedAt)
    }
}
