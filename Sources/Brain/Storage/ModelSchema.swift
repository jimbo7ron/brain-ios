// ModelSchema.swift
// brain-ios
//
// SwiftData @Model definitions. These mirror the brain server resources
// so the M33 sync engine can drop server JSON into local storage with a
// shallow translation layer.
//
// Conventions:
//   - `id` matches the server's UUID exactly. We use it as `@Attribute(.unique)`.
//   - Date strings come from the server as ISO-8601 (e.g. `2026-04-29T12:00:00Z`).
//     We persist them as `Date` and let the DTO layer parse on the way in.
//   - Optional fields stay optional; SwiftData handles `nil` cleanly.
//   - Don't add sync logic here — these models are pure data shells.

import Foundation
import SwiftData

// MARK: - User

@Model
final class LocalUser {
    @Attribute(.unique) var id: String
    var email: String
    var createdAt: Date?

    init(id: String, email: String, createdAt: Date? = nil) {
        self.id = id
        self.email = email
        self.createdAt = createdAt
    }
}

// MARK: - Project

@Model
final class LocalProject {
    @Attribute(.unique) var id: String
    var shortId: String
    var name: String
    /// Raw CSS value from the server (e.g. `hsl(262 83% 58%)`). Match
    /// against `BrainColors.palette` by `cssValue` if recognised;
    /// otherwise fall back to the system tint.
    var color: String?
    var sortOrder: Int
    var archived: Bool
    var createdAt: Date?
    var updatedAt: Date?

    /// Sections cascade-delete with the project — server treats sections as
    /// children, so the local store should too.
    @Relationship(deleteRule: .cascade, inverse: \LocalSection.project)
    var sections: [LocalSection] = []

    init(
        id: String,
        shortId: String,
        name: String,
        color: String? = nil,
        sortOrder: Int = 0,
        archived: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.shortId = shortId
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Section

@Model
final class LocalSection {
    /// Composite primary key: `"<projectId>:<slug>"`. The server returns
    /// sections as `{slug, name, position}` scoped to a project — `slug`
    /// alone collides across projects, so we mint a globally-unique id
    /// at insert time so SwiftData can dedupe with `@Attribute(.unique)`.
    /// This lets the M33 sync engine upsert by id instead of doing a
    /// per-project slug scan on every batch.
    @Attribute(.unique) var id: String
    /// Stable section slug (server-generated from name). Unique within a
    /// project, not globally — see `id` for the composite form.
    var slug: String
    var name: String
    var position: Int
    var project: LocalProject?

    init(id: String, slug: String, name: String, position: Int, project: LocalProject? = nil) {
        self.id = id
        self.slug = slug
        self.name = name
        self.position = position
        self.project = project
    }

    /// Build the composite id used for `@Attribute(.unique)`. Centralised
    /// so callers (sync engine, tests) don't reinvent the format.
    static func makeID(projectID: String, slug: String) -> String {
        "\(projectID):\(slug)"
    }
}

// MARK: - Note / Todo / Appointment

/// Single shape for all three note types — matches the server's
/// `NoteResponse` which inlines `todo` and `appointment` substructures.
/// The `type` field discriminates ("note" | "todo" | "appointment").
@Model
final class LocalNote {
    @Attribute(.unique) var id: String
    var shortId: String
    var title: String?
    var content: String
    /// One of "note", "todo", "appointment".
    var type: String
    var archived: Bool
    var createdAt: Date?
    var updatedAt: Date?

    /// Tags stored as a JSON array string. SwiftData supports `[String]`
    /// natively in iOS 17 but it's worth keeping the type explicit for
    /// when we add per-tag indexing later.
    var tagsCSV: String

    // Todo fields (populated when type == "todo")
    var dueDate: String?       // server stores as flexible string ("today", "2026-05-01")
    var dueTime: String?
    var completed: Bool
    var completedAt: Date?
    var priority: String        // "low" | "medium" | "high"
    var recurrence: String?
    var projectId: String?
    var section: String?        // section slug
    var url: String?
    var urlTitle: String?
    var urlState: String?       // "pending" | "ok" | "error"
    var urlFetchedAt: Date?
    var sortOrder: Int

    // Appointment fields (populated when type == "appointment").
    // Co-located here rather than in a separate model so we don't have
    // to do a join on the read path; LocalAppointment exists for cases
    // where we need a typed reference (e.g. calendar imports).
    var appointmentStartTime: String?
    var appointmentEndTime: String?
    var appointmentLocation: String?
    var appointmentRecurrence: String?

    init(
        id: String,
        shortId: String,
        title: String? = nil,
        content: String,
        type: String = "note",
        archived: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        tagsCSV: String = "",
        dueDate: String? = nil,
        dueTime: String? = nil,
        completed: Bool = false,
        completedAt: Date? = nil,
        priority: String = "medium",
        recurrence: String? = nil,
        projectId: String? = nil,
        section: String? = nil,
        url: String? = nil,
        urlTitle: String? = nil,
        urlState: String? = nil,
        urlFetchedAt: Date? = nil,
        sortOrder: Int = 0,
        appointmentStartTime: String? = nil,
        appointmentEndTime: String? = nil,
        appointmentLocation: String? = nil,
        appointmentRecurrence: String? = nil
    ) {
        self.id = id
        self.shortId = shortId
        self.title = title
        self.content = content
        self.type = type
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tagsCSV = tagsCSV
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.completed = completed
        self.completedAt = completedAt
        self.priority = priority
        self.recurrence = recurrence
        self.projectId = projectId
        self.section = section
        self.url = url
        self.urlTitle = urlTitle
        self.urlState = urlState
        self.urlFetchedAt = urlFetchedAt
        self.sortOrder = sortOrder
        self.appointmentStartTime = appointmentStartTime
        self.appointmentEndTime = appointmentEndTime
        self.appointmentLocation = appointmentLocation
        self.appointmentRecurrence = appointmentRecurrence
    }
}

/// Minimal projection used by views that only care about appointment
/// shape — the canonical row lives on `LocalNote`. Fleshed out in M34.
@Model
final class LocalAppointment {
    @Attribute(.unique) var id: String
    var noteId: String
    var startTime: String?
    var endTime: String?
    var location: String?

    init(id: String, noteId: String, startTime: String? = nil, endTime: String? = nil, location: String? = nil) {
        self.id = id
        self.noteId = noteId
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
    }
}

// MARK: - Sync state

/// Singleton row tracking the last-seen `server_time` cursor. We store it
/// in SwiftData (rather than UserDefaults) so it lives next to the data
/// it cursors over. Keyed by `key = "default"` so future multi-account
/// support has a place to put a second cursor.
@Model
final class LocalSyncState {
    @Attribute(.unique) var key: String
    var lastServerTime: String?
    var lastSyncAt: Date?

    init(key: String = "default", lastServerTime: String? = nil, lastSyncAt: Date? = nil) {
        self.key = key
        self.lastServerTime = lastServerTime
        self.lastSyncAt = lastSyncAt
    }
}

// MARK: - Mutation queue (M37 — minimal scaffold)

/// Pending API mutation captured while offline. The replayer in M37 walks
/// these in `createdAt` order and POSTs them with `Idempotency-Key:
/// idempotencyKey` so retries are safe.
@Model
final class LocalMutationQueueItem {
    @Attribute(.unique) var id: String
    /// Operation discriminator, e.g. "createTodo", "completeTodo", "archiveNote".
    var op: String
    var resourceType: String
    var resourceId: String?
    /// JSON-encoded request body, decoded by the replayer per `op`.
    var payload: Data
    /// Idempotency key sent with every replay attempt. Generated once
    /// when the mutation is enqueued and never rotated.
    var idempotencyKey: String
    var attempts: Int
    var nextRetryAt: Date?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        op: String,
        resourceType: String,
        resourceId: String? = nil,
        payload: Data,
        idempotencyKey: String = UUID().uuidString,
        attempts: Int = 0,
        nextRetryAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.op = op
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.createdAt = createdAt
    }
}
