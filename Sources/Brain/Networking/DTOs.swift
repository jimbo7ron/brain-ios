// DTOs.swift
// brain-ios
//
// Codable wire-format structs for the brain HTTP API. Field names match
// brain/src/brain/schemas.py 1:1 (snake_case via CodingKeys). Keep these
// in lock-step with the server — when a field is added there, mirror it
// here so the M33 sync engine doesn't silently drop new data.
//
// These are pure DTOs. Mapping to SwiftData (`LocalNote`, `LocalProject`,
// etc.) lives in the sync engine, which lands in M33.

import Foundation

// MARK: - Auth (M30 + M27)

struct LoginRequest: Encodable {
    let email: String
    let password: String
    /// Sent by iOS so the server can auto-mint a named API key (M30).
    let deviceName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case deviceName = "device_name"
    }
}

struct ApiKeyRecord: Codable, Hashable {
    let id: String
    let name: String
    let createdAt: String?
    let lastUsedAt: String?
    let revokedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case revokedAt = "revoked_at"
    }
}

/// Returned by `POST /auth/login`. When the request includes a
/// `device_name` (M30), the server mints a named API key and inlines
/// it on the response so the iOS client can stash the plaintext key
/// in Keychain. Web login omits `device_name`, so `apiKey` is `nil`.
struct LoginResponse: Codable {
    let token: String
    let tokenType: String
    let expiresIn: Int
    let userId: String
    let email: String
    let apiKey: NewApiKey?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case userId = "user_id"
        case email
        case apiKey = "api_key"
    }
}

/// The freshly-minted API key block returned alongside the JWT on the
/// M30 login path. `key` is plaintext and shown exactly once — store it
/// in Keychain immediately and never log it.
struct NewApiKey: Codable, Hashable {
    let id: String
    let name: String
    let key: String
}

// MARK: - User

struct User: Codable, Hashable {
    let id: String
    let email: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case createdAt = "created_at"
    }
}

// MARK: - Project / Section

struct Section: Codable, Hashable {
    let slug: String
    let name: String
    let position: Int
}

struct Project: Codable, Hashable {
    let id: String
    let shortId: String
    let name: String
    let color: String?
    let sortOrder: Int
    let archived: Bool
    let sections: [Section]
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case shortId = "short_id"
        case name
        case color
        case sortOrder = "sort_order"
        case archived
        case sections
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ProjectListResponse: Codable {
    let projects: [Project]
    let total: Int
}

// MARK: - Note / Todo / Appointment

struct TodoFields: Codable, Hashable {
    let dueDate: String?
    let dueTime: String?
    let completed: Bool
    let completedAt: String?
    let priority: String
    let recurrence: String?
    let projectId: String?
    let section: String
    let url: String?
    let urlTitle: String?
    let urlState: String?
    let urlFetchedAt: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case dueDate = "due_date"
        case dueTime = "due_time"
        case completed
        case completedAt = "completed_at"
        case priority
        case recurrence
        case projectId = "project_id"
        case section
        case url
        case urlTitle = "url_title"
        case urlState = "url_state"
        case urlFetchedAt = "url_fetched_at"
        case sortOrder = "sort_order"
    }
}

struct AppointmentFields: Codable, Hashable {
    let startTime: String?
    let endTime: String?
    let location: String?
    let recurrence: String?

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case location
        case recurrence
    }
}

struct Note: Codable, Hashable {
    let id: String
    let shortId: String
    let title: String?
    let content: String
    /// "note" | "todo" | "appointment"
    let type: String
    let tags: [String]
    let createdAt: String?
    let updatedAt: String?
    let archived: Bool
    let todo: TodoFields?
    let appointment: AppointmentFields?

    enum CodingKeys: String, CodingKey {
        case id
        case shortId = "short_id"
        case title
        case content
        case type
        case tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archived
        case todo
        case appointment
    }
}

struct NoteListResponse: Codable {
    let notes: [Note]
    let total: Int
}

/// Patch body for `PATCH /api/v1/notes/{id}` — mirrors `NoteUpdate` in
/// `brain/src/brain/schemas.py`. Every field is optional; the server
/// applies whatever is present and ignores keys that aren't sent. We use
/// explicit `CodingKeys` (rather than `keyEncodingStrategy =
/// .convertToSnakeCase`) so the wire shape stays obvious in source and
/// is greppable against the Python schema.
///
/// Note: completing a todo uses a dedicated endpoint (`POST /notes/{id}/
/// complete`) and is not modelled here — `NoteUpdate` on the server has
/// no `completed` field.
struct UpdateNotePayload: Encodable, Hashable {
    var content: String?
    var title: String?
    /// Use the literal string `"none"` to clear an existing due date —
    /// matches the server's convention.
    var dueDate: String?
    /// "low" | "medium" | "high".
    var priority: String?
    /// Project name, short id, or `"unassigned"` to clear.
    var project: String?
    /// Section slug.
    var section: String?
    /// Empty string clears the URL.
    var url: String?
    // Appointment fields
    var startTime: String?
    var endTime: String?
    var location: String?

    enum CodingKeys: String, CodingKey {
        case content
        case title
        case dueDate = "due_date"
        case priority
        case project
        case section
        case url
        case startTime = "start_time"
        case endTime = "end_time"
        case location
    }
}

// MARK: - Sync feed (M28)

struct SyncTombstones: Codable, Hashable {
    let notes: [String]
    let projects: [String]
}

struct SyncResponse: Codable {
    let projects: [Project]
    let notes: [Note]
    let tombstones: SyncTombstones
    /// ISO-8601 cursor — pass back as `?since=` on the next call.
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case projects
        case notes
        case tombstones
        case serverTime = "server_time"
    }
}

// MARK: - Health

struct HealthResponse: Codable {
    let status: String
    let version: String
}

// MARK: - Error envelope

/// FastAPI returns errors as `{"detail": "..."}`. Decoded for the
/// `validationError` path in `BrainAPIClient`.
struct ErrorEnvelope: Codable {
    let detail: String
}
