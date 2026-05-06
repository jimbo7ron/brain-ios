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

/// Response shape for `GET /api/v1/auth/api-keys` — mirrors
/// `ApiKeyListResponse` in `brain/src/brain/schemas.py`. Used by the
/// M30 4-step recovery in `BrainAPIClient.loginWithRecovery(...)`:
/// after a 409 we list the user's keys (via JWT bearer auth, not the
/// usual `X-API-Key` header — we don't have a key yet) and look for
/// the orphan whose `name` matches the requested `device_name` and
/// whose `revokedAt` is nil. The revokedAt filter is load-bearing —
/// without it we'd try to revoke an already-revoked key and the
/// server would happily no-op, leaving the orphan still blocking
/// the next login attempt.
struct ApiKeyListResponse: Codable {
    let keys: [ApiKeyRecord]
    let total: Int
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

struct SectionDTO: Codable, Hashable {
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
    let sections: [SectionDTO]
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

/// Patch body for `PUT /api/v1/projects/{id}` — mirrors `ProjectUpdate`
/// in `brain/src/brain/schemas.py`. Every field is optional; the server
/// applies whatever is present and ignores keys that aren't sent. Used
/// by M40's edit-project dialog.
///
/// Note: this struct intentionally does NOT carry `sections`. Section
/// editing rides separate endpoints (`POST /projects/{id}/sections`,
/// `PUT /projects/{id}/sections`, `PATCH /projects/{id}/sections/{slug}`,
/// `DELETE /projects/{id}/sections/{slug}`) — see `server.py`. Mirroring
/// the wire shape exactly here means the M37 queue's PUT body matches
/// what `update_project_endpoint` expects field-for-field.
struct UpdateProjectPayload: Encodable, Hashable {
    var name: String?
    /// Raw CSS colour string (e.g. `hsl(262 83% 58%)`). Pick from
    /// `BrainColors.palette` so iOS and web render identically.
    var color: String?
    var sortOrder: Int?
    var archived: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case color
        case sortOrder = "sort_order"
        case archived
    }
}

/// Body for `POST /api/v1/projects` — mirrors `ProjectCreate` in
/// `brain/src/brain/schemas.py`. Used by the iOS "New project" sheet
/// to create a project directly through the API. `name` is required;
/// `color` and `sortOrder` are optional and the server applies sane
/// defaults when omitted.
///
/// Note: this struct intentionally does NOT carry `archived` — the
/// server's `ProjectCreate` schema has no such field (a freshly-created
/// project is always non-archived). It also does NOT carry `sections`
/// for the iOS create flow: M26's `DEFAULT_SECTIONS` (Now/Next/Later)
/// are applied server-side when `sections` is omitted, which is the
/// shape we want here. Custom sections are reachable later via
/// `EditProjectView` once the project exists.
struct CreateProjectPayload: Encodable, Hashable {
    /// Required by the server — minimum 1, maximum 200 characters.
    let name: String
    /// Raw CSS colour string (e.g. `hsl(262 83% 58%)`). Pick from
    /// `BrainColors.palette` so iOS and web render identically.
    let color: String?
    /// Optional — server defaults to 0.
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case color
        case sortOrder = "sort_order"
    }
}

/// Typed diff for `NoteRepository.update(...)` (M45 Wave 1). Every
/// field is optional; the repository serialises only the non-nil fields
/// onto the wire `UpdateNotePayload` and ships them as the queue
/// payload. Lives next to `CreateNotePayload` because it's the create-
/// shape's update-shape sibling — same field surface, all-optional.
///
/// Why a separate struct from `UpdateNotePayload`:
///   * `UpdateNotePayload` is the wire shape (snake_case, matches
///     `brain/src/brain/schemas.py:NoteUpdate` 1:1). The repository
///     contract sits one level above the wire — view callers shouldn't
///     have to know the server's PATCH shape.
///   * `NoteUpdateFields` carries iOS-side concepts the wire shape
///     doesn't (e.g. a future `due_time` will land here as a typed
///     `Date?` first, then get formatted to `"HH:MM"` on the way to
///     the server). For Wave 1 the two are near-twins; the divergence
///     starts in Wave 3 when typed fields land.
///
/// Field set (per M45 spec §6.1): `content`, `title`, `url`,
/// `dueDate`, `priority`, `projectId`, `section`, plus the appointment
/// trio (`startTime`, `endTime`, `location`). All optional — only
/// non-nil fields are applied locally and sent in the update.
///
/// **Why no `dueTime` or `recurrence`**: the server's `NoteUpdate`
/// schema (`brain/src/brain/schemas.py`) has no keys for either, so
/// any value here would be silently dropped on the wire. Rather than
/// a footgun for Wave 3 callers, the fields are omitted entirely.
/// `LocalNote.dueTime` / `LocalNote.recurrence` still exist and are
/// surfaced via the SyncEngine pull and other server-side write paths.
///
/// **Nullable-update semantics (Wave 1)**: the wire shape skips nil
/// fields. To clear an existing value the caller passes a sentinel:
///   * `dueDate: "none"` clears the due date (server convention).
///   * `url: ""`, `section: ""`, `location: ""` are treated as clears
///     locally; the wire ships the empty string and the server
///     interprets it as a clear (or leaves the field alone, depending
///     on the field — see `NoteUpdate` in
///     `brain/src/brain/schemas.py`).
///   * `projectId: "unassigned"` is the wire-side clear sentinel.
/// A unified sentinel design (e.g. an explicit `.clear` enum case) is
/// out of scope for Wave 1 — see TODO(M45 Wave 3) below.
struct NoteUpdateFields: Hashable {
    var content: String?
    /// New title. Empty string is sent verbatim (server keeps the
    /// title alongside `content`); pass nil to leave alone.
    var title: String?
    /// New URL. Empty string clears server-side per
    /// `NoteUpdate.url` convention.
    var url: String?
    /// "yyyy-MM-dd", "today", "tomorrow", or `"none"` to clear.
    var dueDate: String?
    /// "low" | "medium" | "high".
    var priority: String?
    /// Project name, short id, or `"unassigned"` to clear.
    var projectId: String?
    /// Section slug.
    var section: String?
    // Appointment fields — populated when editing a "appointment"-type
    // note. The wire shape carries `start_time` / `end_time` as
    // ISO-8601 strings; we mirror that here rather than typed `Date`
    // because the server stores them as flexible strings.
    var startTime: String?
    var endTime: String?
    var location: String?
    // TODO(M45 Wave 3): unify nullable-update semantics — replace the
    // current mix of "none" / "" / "unassigned" sentinels with a typed
    // `Optional<Optional<T>>` (`.some(nil)` = clear, `.none` = leave
    // alone) or a per-field `.clear` enum. Wave 1 keeps the existing
    // sentinel mix to match `UpdateNotePayload` 1:1; Wave 3's typed
    // edit dialog migration is the natural place to clean this up.
}

/// Typed diff for `ProjectRepository.update(...)` (M45 Wave 1). Every
/// field is optional; the repository serialises only the non-nil fields
/// onto the wire `UpdateProjectPayload`. Same rationale as
/// `NoteUpdateFields` — a repository-level diff that view callers can
/// build without knowing the server's wire shape.
///
/// Field set (per M45 spec §6.2): `name`, `color`, `sortOrder`. The
/// `archived` field stays out — `archive(_:)` is its own repository
/// method per the spec (soft-delete is a distinct intent from a metadata
/// patch).
struct ProjectUpdateFields: Hashable {
    var name: String?
    /// Raw CSS colour string (e.g. `hsl(262 83% 58%)`).
    var color: String?
    var sortOrder: Int?
}

/// Body for `POST /api/v1/projects/{projectId}/sections` (M45 Wave 4).
/// Mirrors the wire shape used by `BrainAPIClient.addProjectSection` —
/// a single `name` string. Lifted into a typed Codable struct so the
/// queue's pre-encoded payload survives a cold-launch decode cleanly
/// (the queue stores the JSON `Data` and `executeMutation` re-uses it
/// directly without re-encoding).
struct CreateSectionPayload: Codable, Hashable {
    let name: String
}

/// Body for `PATCH /api/v1/projects/{projectId}/sections/{slug}`
/// (M45 Wave 4). Same shape as `CreateSectionPayload` — server
/// accepts `{name}` and preserves the existing slug. Kept distinct so
/// future per-op fields (e.g. `position` for a server-side reorder)
/// land on the right struct.
struct UpdateSectionPayload: Codable, Hashable {
    let name: String
}

/// Body for `POST /api/v1/notes` — mirrors `NoteCreate` in
/// `brain/src/brain/schemas.py`. Used by M39's quick-add flow to mint a
/// todo (or, in future, an appointment) directly through the API. Every
/// type-specific field is optional; the server applies sane defaults
/// when the key is absent. We use explicit `CodingKeys` (rather than
/// `keyEncodingStrategy = .convertToSnakeCase`) so the wire shape stays
/// obvious in source and is greppable against the Python schema.
struct CreateNotePayload: Encodable, Hashable {
    /// Required by the server — minimum 1, maximum 100k characters.
    var content: String
    /// Optional — extracted from `content` server-side when omitted.
    var title: String?
    /// `"note"` | `"todo"` | `"appointment"`. Defaults to `"note"` on
    /// the server, but the M39 path always sends `"todo"`.
    var type: String
    // Todo fields
    var dueDate: String?
    var dueTime: String?
    /// `"low"` | `"medium"` | `"high"`. Server defaults to `"medium"`.
    var priority: String?
    /// `"daily"` | `"weekly"` | `"monthly"` | `"weekdays"`.
    var recurrence: String?
    /// Project name or short id.
    var project: String?
    /// Section slug.
    var section: String?
    var url: String?
    // Appointment fields
    var startTime: String?
    var endTime: String?
    var location: String?

    enum CodingKeys: String, CodingKey {
        case content
        case title
        case type
        case dueDate = "due_date"
        case dueTime = "due_time"
        case priority
        case recurrence
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

// MARK: - Devices (M29 / M41)

/// Body for `POST /api/v1/devices` — mirrors the M29 server's
/// device-registration shape. Sent on the iOS side once APNs hands us
/// a device token (M41). The server upserts on `apns_token`, so
/// duplicate calls (re-sign-in, app reinstall with the same token)
/// are no-ops — `last_seen_at` is bumped but no new row is inserted.
///
/// We use explicit `CodingKeys` (rather than
/// `keyEncodingStrategy = .convertToSnakeCase`) so the wire shape stays
/// obvious in source and is greppable against the Python schema. The
/// keys must match `device_tokens` columns in `brain/src/brain/db.py`.
struct DeviceRegisterPayload: Encodable, Hashable {
    let apnsToken: String
    /// Always `"ios"` from this client. Server enum also accepts
    /// future platforms (e.g. macOS Catalyst) but we only register
    /// iPhone today.
    let platform: String
    /// Human-readable label for the user's device list. Mirrors the
    /// format used by the M30 login flow (`iPhone — <name>`) so the
    /// device shows the same name in the API key list and the APNs
    /// device list.
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case platform
        case deviceName = "device_name"
    }
}

// MARK: - Notification preferences (M42)

/// Mirrors the M42 server response from
/// `GET /api/v1/preferences/notifications`. The server returns a full
/// snapshot with the four toggle / time fields plus the user's stored
/// timezone. Defaults (`defaults`) match what the server returns the
/// very first time a user reads the endpoint — useful as a fallback so
/// the form doesn't crash on a transient decode error during the
/// rollout window when the server hasn't redeployed yet.
///
/// We use explicit `CodingKeys` (rather than
/// `keyEncodingStrategy = .convertToSnakeCase`) so the wire shape stays
/// obvious in source and is greppable against the Python schema. Match
/// the existing pattern used for every other DTO in this file.
struct NotificationPreferences: Codable, Equatable {
    /// Master switch for the daily summary push. When false the M42
    /// scheduler skips this user entirely; the time field is ignored.
    var morningBriefingEnabled: Bool
    /// `"HH:MM"` 24-hour string. Server interprets it in the user's
    /// stored `timezone`. We round-trip it as a string rather than a
    /// `Date` so DST edges don't drift the value silently.
    var morningBriefingTime: String
    /// Per-todo reminder at the row's `due_time`. Off by default to
    /// avoid spamming users on first sign-in before they've opted in.
    var dueRemindersEnabled: Bool
    /// Once-a-day 9 AM digest of items due today with no specific
    /// `due_time`. Complements `dueRemindersEnabled` rather than
    /// duplicating it — they fire on disjoint sets of todos.
    var dueTodayEnabled: Bool
    /// IANA tz identifier (e.g. `"Europe/London"`). Read-only in the
    /// M42 UI; M43 polish will add a picker. The view auto-syncs the
    /// device's identifier to the server on first load if the server
    /// has the placeholder `"UTC"` default.
    var timezone: String

    enum CodingKeys: String, CodingKey {
        case morningBriefingEnabled = "morning_briefing_enabled"
        case morningBriefingTime = "morning_briefing_time"
        case dueRemindersEnabled = "due_reminders_enabled"
        case dueTodayEnabled = "due_today_enabled"
        case timezone
    }

    static let defaults = NotificationPreferences(
        morningBriefingEnabled: false,
        morningBriefingTime: "08:00",
        dueRemindersEnabled: false,
        dueTodayEnabled: false,
        timezone: TimeZone.current.identifier
    )
}

/// Patch body for `PUT /api/v1/preferences/notifications`. Mirrors the
/// agreed M42 contract: any subset of fields, partial-update semantics
/// (the server treats unspecified fields as "leave alone"). All-nil is
/// a legal request body — it encodes to `{}` and is a no-op server-side.
///
/// Why a separate struct from `NotificationPreferences`: the GET
/// response is required-fields-only, but PATCH bodies need optionals so
/// we don't accidentally clobber unset fields with their zero values
/// (e.g. sending `morning_briefing_enabled: false` on a save that only
/// touched the time picker would silently disable the briefing).
struct NotificationPreferencesUpdate: Encodable, Hashable {
    var morningBriefingEnabled: Bool?
    var morningBriefingTime: String?
    var dueRemindersEnabled: Bool?
    var dueTodayEnabled: Bool?
    var timezone: String?

    enum CodingKeys: String, CodingKey {
        case morningBriefingEnabled = "morning_briefing_enabled"
        case morningBriefingTime = "morning_briefing_time"
        case dueRemindersEnabled = "due_reminders_enabled"
        case dueTodayEnabled = "due_today_enabled"
        case timezone
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
