// FakeBrainURLProtocol.swift
// brain-ios
//
// In-process fake brain server, plumbed in as a `URLProtocol` so it
// intercepts every request the production `BrainAPIClient` makes
// without forcing a protocol-extraction refactor on the actor itself.
//
// Why URLProtocol-injection (vs a `BrainAPIClientProtocol` extraction):
// `BrainAPIClient` is an `actor` with non-trivial cross-actor contracts
// (mutation queue replay, sync engine, repositories all type-check
// against the concrete actor type). Splitting it into a protocol +
// `LiveBrainAPIClient` + `FakeBrainAPIClient` would touch ~10 files
// (queue, engine, repositories, intents bridge, two view layers) and
// invert the actor's isolation semantics — a protocol-conforming class
// can't be an actor, so every consumer would need to be re-audited.
// Intercepting at the URLSession layer hands us:
//   * The same hermetic in-memory "server" without changing a single
//     consumer call site.
//   * Real exercise of the JSON encode/decode, error-classification,
//     and sync-reconcile paths (the fake speaks real HTTP/JSON).
//   * Determinism — no real network, no flakiness from DNS / TLS /
//     timing.
// Trade-off: an actor `BrainAPIClient` instance still exists in the
// test-mode process; the URLProtocol just answers its requests. That
// matches "stateful in-process fake server" (the spec's intent) more
// faithfully than a protocol fake would have.
//
// The fake holds an in-memory snapshot of the server's data model
// (notes, projects, sections) keyed by UUID. Mutations land via the
// real wire endpoints (`POST /api/v1/notes`, `PUT /api/v1/projects/{id}`,
// etc.); the sync endpoint returns the full snapshot as a delta feed
// every time. Test-side helpers can seed state and reset between
// methods via `FakeBrainState.shared`.
//
// Mirrors only the endpoints the initial 6-test set drives:
//   * GET  /api/v1/sync
//   * POST /api/v1/notes
//   * PUT  /api/v1/notes/{id}
//   * DELETE /api/v1/notes/{id}
//   * POST /api/v1/notes/{id}/complete
//   * POST /api/v1/projects
//   * POST /api/v1/projects/{projectId}/sections
//
// Future PRs will extend the fake as more tests demand more endpoints.

import Foundation

/// Singleton in-memory server state. `FakeBrainURLProtocol` reads /
/// writes through `shared`; XCUITest controls it by injecting
/// `-uiTestingResetState` (handled in `BrainApp.init`) which calls
/// `reset()` at process launch.
final class FakeBrainState: @unchecked Sendable {

    static let shared = FakeBrainState()

    /// Serialises mutation/read across actor and main-thread callers.
    /// `URLProtocol` callbacks may fire on private NSURLSession queues,
    /// so we cannot assume the main actor.
    private let lock = NSLock()

    private var notes: [String: NoteRecord] = [:]
    private var projects: [String: ProjectRecord] = [:]
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Wipe state. Called at app launch when `-uiTestingResetState`
    /// is passed, and from XCUITest fixtures that want a fresh fake.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        notes.removeAll()
        projects.removeAll()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// Test seam: pre-populate a project so a test can navigate to it
    /// without driving the create UI first.
    @discardableResult
    func seedProject(name: String, color: String? = nil, forcedID: String? = nil) -> ProjectRecord {
        lock.lock(); defer { lock.unlock() }
        var project = makeProject(name: name, color: color)
        if let forcedID {
            project.id = forcedID
            project.shortId = String(forcedID.prefix(8))
        }
        projects[project.id] = project
        return project
    }

    /// Test seam: pre-populate a todo. Title is derived from `content`
    /// (first line) when not supplied — same behaviour as the real
    /// server. Pass `forcedID` to use a deterministic id (so a UI
    /// test can locate the resulting row by `todo-row-<id>` without
    /// rendezvousing with the in-process state).
    @discardableResult
    func seedTodo(
        content: String,
        title: String? = nil,
        projectID: String? = nil,
        section: String = "now",
        dueDate: String? = nil,
        completed: Bool = false,
        forcedID: String? = nil
    ) -> NoteRecord {
        lock.lock(); defer { lock.unlock() }
        var note = makeNote(
            content: content,
            title: title,
            type: "todo",
            projectID: projectID,
            section: section,
            dueDate: dueDate,
            completed: completed
        )
        if let forcedID {
            note.id = forcedID
            note.shortId = String(forcedID.prefix(8))
        }
        notes[note.id] = note
        return note
    }

    /// Read snapshot for the sync endpoint — returns all live records.
    fileprivate func snapshot() -> (notes: [NoteRecord], projects: [ProjectRecord], serverTime: String) {
        lock.lock(); defer { lock.unlock() }
        let n = Array(notes.values)
        let p = Array(projects.values)
        return (n, p, FakeBrainState.iso8601(from: clock))
    }

    fileprivate func upsertNote(_ note: NoteRecord) {
        lock.lock(); defer { lock.unlock() }
        notes[note.id] = note
    }

    fileprivate func getNote(_ id: String) -> NoteRecord? {
        lock.lock(); defer { lock.unlock() }
        return notes[id]
    }

    fileprivate func deleteNote(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var existing = notes[id] else { return false }
        existing.archived = true
        existing.updatedAt = nextClock()
        notes[id] = existing
        return true
    }

    fileprivate func upsertProject(_ project: ProjectRecord) {
        lock.lock(); defer { lock.unlock() }
        projects[project.id] = project
    }

    fileprivate func getProject(_ id: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return projects[id]
    }

    /// Build a fresh project record with server-assigned id, default
    /// sections, and current clock timestamp.
    fileprivate func makeProject(name: String, color: String?) -> ProjectRecord {
        let id = UUID().uuidString.lowercased()
        let now = FakeBrainState.iso8601(from: nextClockDate())
        return ProjectRecord(
            id: id,
            shortId: String(id.prefix(8)),
            name: name,
            color: color,
            sortOrder: 0,
            archived: false,
            sections: ProjectRecord.defaultSections(),
            createdAt: now,
            updatedAt: now
        )
    }

    /// Build a fresh note record. Mirrors the brain server's
    /// `NoteCreate` derivations — server-assigned id, derived title
    /// when missing, default section "now".
    fileprivate func makeNote(
        content: String,
        title: String?,
        type: String,
        projectID: String?,
        section: String,
        dueDate: String?,
        completed: Bool
    ) -> NoteRecord {
        let id = UUID().uuidString.lowercased()
        let now = FakeBrainState.iso8601(from: nextClockDate())
        let derivedTitle = title ?? content.split(separator: "\n").first.map(String.init) ?? content
        return NoteRecord(
            id: id,
            shortId: String(id.prefix(8)),
            title: derivedTitle,
            content: content,
            type: type,
            tags: [],
            createdAt: now,
            updatedAt: now,
            archived: false,
            todo: type == "todo" ? NoteRecord.Todo(
                dueDate: dueDate,
                dueTime: nil,
                completed: completed,
                completedAt: completed ? now : nil,
                priority: "medium",
                recurrence: nil,
                projectId: projectID,
                section: section,
                url: nil,
                urlTitle: nil,
                urlState: nil,
                urlFetchedAt: nil,
                sortOrder: 0
            ) : nil,
            appointment: nil
        )
    }

    /// Bump the in-process clock by one second so successive
    /// `updatedAt` values strictly increase. The exact duration is
    /// arbitrary — only ordering matters for the LWW reconcile path.
    fileprivate func nextClock() -> String {
        clock = clock.addingTimeInterval(1)
        return FakeBrainState.iso8601(from: clock)
    }

    private func nextClockDate() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    static func iso8601(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Records (mirror the wire DTOs in DTOs.swift)

struct NoteRecord {
    var id: String
    var shortId: String
    var title: String?
    var content: String
    var type: String
    var tags: [String]
    var createdAt: String
    var updatedAt: String
    var archived: Bool
    var todo: Todo?
    var appointment: Appointment?

    struct Todo {
        var dueDate: String?
        var dueTime: String?
        var completed: Bool
        var completedAt: String?
        var priority: String
        var recurrence: String?
        var projectId: String?
        var section: String
        var url: String?
        var urlTitle: String?
        var urlState: String?
        var urlFetchedAt: String?
        var sortOrder: Int
    }

    struct Appointment {
        var startTime: String?
        var endTime: String?
        var location: String?
        var recurrence: String?
    }

    /// Encode to JSON bytes matching the production `Note` decoder. We
    /// hand-roll the dictionary rather than reaching for `Note` because
    /// `Note` is `Decodable` (not `Encodable`) — we'd have to mirror
    /// the entire CodingKeys set anyway.
    func encodeJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "short_id": shortId,
            "content": content,
            "type": type,
            "tags": tags,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "archived": archived,
        ]
        if let title { dict["title"] = title }
        if let todo {
            var t: [String: Any] = [
                "completed": todo.completed,
                "priority": todo.priority,
                "section": todo.section,
                "sort_order": todo.sortOrder,
            ]
            if let v = todo.dueDate { t["due_date"] = v }
            if let v = todo.dueTime { t["due_time"] = v }
            if let v = todo.completedAt { t["completed_at"] = v }
            if let v = todo.recurrence { t["recurrence"] = v }
            if let v = todo.projectId { t["project_id"] = v }
            if let v = todo.url { t["url"] = v }
            if let v = todo.urlTitle { t["url_title"] = v }
            if let v = todo.urlState { t["url_state"] = v }
            if let v = todo.urlFetchedAt { t["url_fetched_at"] = v }
            dict["todo"] = t
        }
        if let appointment {
            var a: [String: Any] = [:]
            if let v = appointment.startTime { a["start_time"] = v }
            if let v = appointment.endTime { a["end_time"] = v }
            if let v = appointment.location { a["location"] = v }
            if let v = appointment.recurrence { a["recurrence"] = v }
            dict["appointment"] = a
        }
        return dict
    }
}

struct ProjectRecord {
    var id: String
    var shortId: String
    var name: String
    var color: String?
    var sortOrder: Int
    var archived: Bool
    var sections: [Section]
    var createdAt: String
    var updatedAt: String

    struct Section {
        var slug: String
        var name: String
        var position: Int
    }

    /// brain server's M26 default sections.
    static func defaultSections() -> [Section] {
        [
            Section(slug: "now", name: "Now", position: 0),
            Section(slug: "next", name: "Next", position: 1),
            Section(slug: "later", name: "Later", position: 2),
        ]
    }

    func encodeJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "short_id": shortId,
            "name": name,
            "sort_order": sortOrder,
            "archived": archived,
            "sections": sections.map { ["slug": $0.slug, "name": $0.name, "position": $0.position] },
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]
        if let color { dict["color"] = color }
        return dict
    }
}

// MARK: - URLProtocol intercept

/// Intercepts every request issued through a `URLSession` whose
/// `configuration.protocolClasses` contains this class. Returns a JSON
/// response by routing on `(method, path)` against `FakeBrainState`.
final class FakeBrainURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        // We only want to intercept brain API traffic. The fake server
        // URL is a `*.brain.test` host (see `BrainTestMode.testServerURL`),
        // so canonicalise on host suffix rather than full URL match —
        // this lets a future test point the client at any sub-host
        // (e.g. an "offline" host) without re-registering.
        guard let host = request.url?.host else { return false }
        return host.hasSuffix("brain.test")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let path = url.path
        let body = request.httpBody ?? readStreamBody()

        let response = route(method: method, path: path, body: body, url: url)
        deliver(response: response, requestURL: url)
    }

    override func stopLoading() {
        // No-op — all responses are produced synchronously in
        // startLoading. URLProtocol's contract requires this method
        // even if there's nothing to cancel.
    }

    /// Read the request body when `httpBody` is nil but `httpBodyStream`
    /// is set — URLSession sometimes prefers the stream form for
    /// uploads. Mutation queue payloads ride as `httpBody` data, so this
    /// is belt-and-braces; the fake doesn't currently exercise the
    /// streaming path.
    private func readStreamBody() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Routing

    /// Route a single request to its handler. Each handler returns
    /// `(status, body)` — the caller serialises and delivers.
    private func route(
        method: String,
        path: String,
        body: Data?,
        url: URL
    ) -> (status: Int, body: [String: Any]?) {
        let state = FakeBrainState.shared
        switch (method, path) {
        case ("GET", "/api/v1/sync"):
            return handleSync(state: state)
        case ("POST", "/api/v1/notes"):
            return handleCreateNote(body: body, state: state)
        case ("POST", "/api/v1/projects"):
            return handleCreateProject(body: body, state: state)
        default:
            // Path-pattern matches.
            if method == "PUT", let id = matchPathID(path, prefix: "/api/v1/notes/") {
                return handleUpdateNote(id: id, body: body, state: state)
            }
            if method == "DELETE", let id = matchPathID(path, prefix: "/api/v1/notes/") {
                return handleArchiveNote(id: id, state: state)
            }
            if method == "POST",
               path.hasPrefix("/api/v1/notes/"),
               path.hasSuffix("/complete"),
               let id = extractCompleteID(path) {
                return handleCompleteNote(id: id, state: state)
            }
            if method == "POST",
               let id = matchPathSuffix(path, prefix: "/api/v1/projects/", suffix: "/sections") {
                return handleAddSection(projectID: id, body: body, state: state)
            }
            // Quietly 404 unknown routes — production code paths
            // surface this through `BrainAPIClient.classify404` and
            // tests can assert on the resulting error if needed.
            return (404, ["detail": "Not Found"])
        }
    }

    // MARK: - Handlers

    private func handleSync(state: FakeBrainState) -> (Int, [String: Any]?) {
        let snap = state.snapshot()
        let payload: [String: Any] = [
            "projects": snap.projects.map { $0.encodeJSON() },
            "notes": snap.notes.map { $0.encodeJSON() },
            "tombstones": ["notes": [], "projects": []],
            "server_time": snap.serverTime,
        ]
        return (200, payload)
    }

    private func handleCreateNote(body: Data?, state: FakeBrainState) -> (Int, [String: Any]?) {
        guard let body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (422, ["detail": "missing body"])
        }
        let content = (json["content"] as? String) ?? ""
        let title = json["title"] as? String
        let type = (json["type"] as? String) ?? "note"
        let dueDate = json["due_date"] as? String
        let projectID = json["project"] as? String
        let section = (json["section"] as? String) ?? "now"
        let note = state.makeNote(
            content: content,
            title: title,
            type: type,
            projectID: (projectID == "unassigned") ? nil : projectID,
            section: section,
            dueDate: dueDate,
            completed: false
        )
        state.upsertNote(note)
        return (200, note.encodeJSON())
    }

    private func handleUpdateNote(id: String, body: Data?, state: FakeBrainState) -> (Int, [String: Any]?) {
        guard var existing = state.getNote(id) else {
            return (404, ["detail": "Note not found: \(id)"])
        }
        guard let body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (422, ["detail": "invalid body"])
        }
        if let v = json["content"] as? String { existing.content = v }
        if let v = json["title"] as? String { existing.title = v }
        if let v = json["due_date"] as? String, var todo = existing.todo {
            todo.dueDate = (v == "none") ? nil : v
            existing.todo = todo
        }
        if let v = json["priority"] as? String, var todo = existing.todo {
            todo.priority = v
            existing.todo = todo
        }
        if let v = json["section"] as? String, var todo = existing.todo {
            todo.section = v
            existing.todo = todo
        }
        if let v = json["url"] as? String, var todo = existing.todo {
            todo.url = v.isEmpty ? nil : v
            existing.todo = todo
        }
        existing.updatedAt = state.nextClock()
        state.upsertNote(existing)
        return (200, existing.encodeJSON())
    }

    private func handleArchiveNote(id: String, state: FakeBrainState) -> (Int, [String: Any]?) {
        let ok = state.deleteNote(id)
        if ok {
            return (200, ["status": "archived"])
        } else {
            return (404, ["detail": "Note not found: \(id)"])
        }
    }

    private func handleCompleteNote(id: String, state: FakeBrainState) -> (Int, [String: Any]?) {
        guard var existing = state.getNote(id), var todo = existing.todo else {
            return (404, ["detail": "Note not found: \(id)"])
        }
        todo.completed = true
        todo.completedAt = state.nextClock()
        existing.todo = todo
        existing.updatedAt = todo.completedAt ?? existing.updatedAt
        state.upsertNote(existing)
        return (200, existing.encodeJSON())
    }

    private func handleCreateProject(body: Data?, state: FakeBrainState) -> (Int, [String: Any]?) {
        guard let body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (422, ["detail": "invalid body"])
        }
        let name = (json["name"] as? String) ?? "Untitled"
        let color = json["color"] as? String
        let project = state.makeProject(name: name, color: color)
        state.upsertProject(project)
        return (200, project.encodeJSON())
    }

    private func handleAddSection(projectID: String, body: Data?, state: FakeBrainState) -> (Int, [String: Any]?) {
        guard var project = state.getProject(projectID) else {
            return (404, ["detail": "Project not found: \(projectID)"])
        }
        guard let body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let name = json["name"] as? String else {
            return (422, ["detail": "missing section name"])
        }
        // Slugify the name. Server uses a richer slugifier; this is
        // enough for the tests we drive — lowercase, spaces -> hyphens,
        // strip non-alphanumeric / hyphen.
        let slug = slugify(name)
        let position = (project.sections.map(\.position).max() ?? -1) + 1
        project.sections.append(.init(slug: slug, name: name, position: position))
        project.updatedAt = state.nextClock()
        state.upsertProject(project)
        return (200, project.encodeJSON())
    }

    // MARK: - Helpers

    private func matchPathID(_ path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let tail = String(path.dropFirst(prefix.count))
        guard !tail.isEmpty, !tail.contains("/") else { return nil }
        return tail
    }

    private func matchPathSuffix(_ path: String, prefix: String, suffix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let middle = path.dropFirst(prefix.count).dropLast(suffix.count)
        let id = String(middle)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    private func extractCompleteID(_ path: String) -> String? {
        // /api/v1/notes/{id}/complete
        let prefix = "/api/v1/notes/"
        let suffix = "/complete"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let middle = path.dropFirst(prefix.count).dropLast(suffix.count)
        let id = String(middle)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    private func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        var lastWasHyphen = false
        for ch in lowered {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func deliver(response: (status: Int, body: [String: Any]?), requestURL: URL) {
        let status = response.status
        let body: Data
        if let dict = response.body, let serialised = try? JSONSerialization.data(withJSONObject: dict) {
            body = serialised
        } else {
            body = Data()
        }
        let httpResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - URLSession factory

extension URLSession {
    /// Build a URLSession that routes every request through
    /// `FakeBrainURLProtocol`. Used by `BrainApp.init` when
    /// `BrainTestMode.isUITesting` is true.
    static func brainTestModeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeBrainURLProtocol.self] + (config.protocolClasses ?? [])
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }
}
