// BrainAPIClient.swift
// brain-ios
//
// Async client for the brain HTTP API. Wraps URLSession + Codable in an
// `actor` so calls from multiple SwiftUI views serialise safely without
// extra locking.
//
// Lifecycle: one instance per app launch, owned by `BrainApp` (see
// `BrainApp.init`) and injected into the SwiftUI environment via
// `\.brainAPIClient`. Views read the shared instance with
// `@Environment(\.brainAPIClient)`; the same actor instance carries the
// `apiKey` state across login (M32), sync (M33), and mutations (M36+).
// Do NOT construct ad-hoc instances inside views — that would split the
// auth state and break sync.
//
// M31 wired `health()` to prove the URLSession plumbing works.
// M32 wires `login()` and `revokeApiKey()` for the auth flow. Other
// methods are declared with their final signatures and throw
// `BrainAPIClient.Error.notImplemented` until their milestone lands —
// M33 wires sync, etc. Keeping the signatures pinned means callers
// (sync engine, login view) don't have to chase compile errors when
// each method is filled in.

import Foundation
import SwiftUI

/// Default production server. Override via Settings or env var.
let defaultBrainServerURL: URL = {
    if let raw = ProcessInfo.processInfo.environment["BRAIN_SERVER_URL"],
       let url = URL(string: raw) {
        return url
    }
    // Force-unwrap is safe — string literal is a valid URL.
    return URL(string: "https://api.mindkeeper.io")!  // swiftlint:disable:this force_unwrapping
}()

actor BrainAPIClient {

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case unauthorized
        case notFound
        case rateLimited(retryAfter: TimeInterval?)
        case validationError(detail: String)
        case network(URLError)
        case decoding(DecodingError)
        case unknown(statusCode: Int, body: String)
        case notImplemented(String)
        case invalidURL

        var description: String {
            switch self {
            case .unauthorized:
                return "Unauthorized — sign in again."
            case .notFound:
                return "Not found."
            case .rateLimited(let retry):
                if let retry = retry {
                    return "Rate limited — retry in \(Int(retry))s."
                }
                return "Rate limited."
            case .validationError(let detail):
                return "Validation error: \(detail)"
            case .network(let urlError):
                return "Network error: \(urlError.localizedDescription)"
            case .decoding(let decodingError):
                return "Failed to decode server response: \(decodingError)"
            case .unknown(let status, let body):
                return "Unexpected response \(status): \(body)"
            case .notImplemented(let name):
                return "\(name) is not implemented yet (M31 stub)."
            case .invalidURL:
                return "Invalid URL."
            }
        }
    }

    // MARK: - State

    private let serverURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// The named API key minted at login (M30/M32) — the plaintext
    /// `api_key.key` returned once on `/auth/login`. Sent as
    /// `X-API-Key: <key>` on every authenticated request.
    ///
    /// Why API key (not JWT) for ongoing requests: after login we get
    /// back both a JWT and a freshly-minted named API key. We persist
    /// and use the API key because (a) it's what the user revokes when
    /// they sign out, (b) it's longer-lived than the JWT (12 months
    /// vs minutes), and (c) it produces clean per-device audit
    /// attribution server-side — `get_api_key_user` sets
    /// `request.state.api_key_id` and bumps `last_used_at` on the
    /// device-key row, neither of which the JWT path does. The JWT is
    /// discarded after the login response is consumed.
    ///
    /// Why `X-API-Key` (not `Authorization: Bearer`): the server's
    /// bearer path runs `decode_jwt_token` first and 401s on a 32-byte
    /// hex API key (it's not a JWT). Using `X-API-Key` routes through
    /// `get_api_key_user`, which is the only path that emits audit
    /// attribution and updates `last_used_at`.
    private var apiKey: String?

    // MARK: - Init

    init(serverURL: URL = defaultBrainServerURL, apiKey: String? = nil, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
        self.apiKey = apiKey

        let decoder = JSONDecoder()
        // Server emits ISO-8601 strings for timestamps; we decode them as
        // strings on the DTOs and convert in the sync layer. Keep the
        // default strategy.
        self.decoder = decoder

        let encoder = JSONEncoder()
        // Server is forgiving on missing fields, so we can omit nils
        // from request bodies.
        self.encoder = encoder
    }

    /// Update the named API key after login (M32) or rotation. Sent as
    /// `X-API-Key` on subsequent authenticated requests.
    func setApiKey(_ key: String?) {
        self.apiKey = key
    }

    // MARK: - Endpoints

    /// `GET /health` — implemented in M31 to prove the plumbing works.
    func health() async throws -> HealthResponse {
        try await get("/health", as: HealthResponse.self, requiresAuth: false)
    }

    /// `POST /api/v1/auth/login` — exchange email + password for a JWT
    /// and (when `device_name` is supplied) a freshly-minted named API
    /// key. The plaintext key on the response is shown exactly once;
    /// callers must stash it in Keychain immediately. iOS always passes
    /// a `deviceName` so the M30 server inlines the key on the response.
    func login(email: String, password: String, deviceName: String?) async throws -> LoginResponse {
        let body = LoginRequest(email: email, password: password, deviceName: deviceName)
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            // Encoding our own struct shouldn't fail; surface as a generic
            // unknown error if it ever does so callers can show *something*.
            throw Error.unknown(statusCode: -1, body: "failed to encode login body: \(error)")
        }
        let request = try makeRequest(
            method: "POST",
            path: "/api/v1/auth/login",
            body: payload,
            requiresAuth: false
        )
        return try await perform(request, as: LoginResponse.self)
    }

    /// `DELETE /api/v1/auth/api-keys/{id}` — revoke a named API key
    /// server-side. Used by sign-out to retire the device key before we
    /// wipe Keychain. Authenticates with the current `apiKey` via
    /// `X-API-Key` so the server can authorise the deletion against
    /// the same user.
    func revokeApiKey(id: String) async throws {
        let request = try makeRequest(
            method: "DELETE",
            path: "/api/v1/auth/api-keys/\(id)",
            body: nil,
            requiresAuth: true
        )
        try await performIgnoringBody(request)
    }

    /// Replay one queued mutation (M37). The replayer hands us the queue
    /// row; we route by `MutationOp` to the matching endpoint and thread
    /// the row's `idempotencyKey` UUID into the `Idempotency-Key` header
    /// so retries are server-deduped.
    ///
    /// Currently only the `.completeTodo` op is wired end-to-end — M36
    /// is the first feature that will exercise the queue, and it only
    /// needs `POST /api/v1/notes/{id}/complete`. The other cases throw
    /// `notImplemented` until the milestones that own them (M38+) fill
    /// them in. The dispatch shape is fixed now so those milestones
    /// don't have to chase compile errors across the queue, the API
    /// client, and the call sites.
    func executeMutation(_ item: MutationQueueItem) async throws {
        let key = item.idempotencyKey.uuidString
        // Validate `resourceId` shape before splicing into a URL path.
        // The queue is local-only and SwiftData rows can't be tampered
        // with by a remote attacker, but defence-in-depth: a future
        // bug that lets a non-UUID slip in (e.g. a typo'd literal in a
        // call site) shouldn't be able to inject path segments. UUIDs
        // are the only legal shape for the resources the queue
        // currently mutates.
        guard let resourceId = Self.validateResourceId(item.resourceId) else {
            throw Error.validationError(detail: "invalid resourceId on queue row: \(item.resourceId)")
        }
        guard let op = MutationOp(rawValue: item.op) else {
            // Unknown slug — almost certainly a downgrade from a build
            // that introduced a new op. Surface as `notImplemented` so
            // the replayer parks the row with `lastError` set; the user
            // can drop the queue from a debug menu if needed.
            throw Error.notImplemented(item.op)
        }
        switch op {
        case .completeTodo:
            // POST with no body — the server reads `{note_id}` from the
            // path. We still pass `body: nil` (not an empty `Data()`) so
            // URLSession doesn't send a 0-byte payload that confuses
            // some intermediaries.
            let request = try makeRequest(
                method: "POST",
                path: "/api/v1/notes/\(resourceId)/complete",
                body: nil,
                requiresAuth: true,
                idempotencyKey: key
            )
            try await performIgnoringBody(request)
        case .uncompleteTodo,
             .createTodo,
             .updateTodo,
             .archiveNote,
             .createProject,
             .updateProject,
             .addSection:
            // TODO(M38+): Wire each of these to its server endpoint.
            // The shape is the same as `.completeTodo`: build a request
            // via `makeRequest(...)` with `idempotencyKey: key`, then
            // perform/perfomIgnoringBody depending on whether the caller
            // cares about the response body. Keep `body` typed via the
            // structs in `DTOs.swift` (e.g. `UpdateNotePayload`) and
            // decode `item.payload` into them at the dispatch site.
            throw Error.notImplemented("executeMutation(\(op.rawValue))")
        }
    }

    /// `GET /api/v1/sync` — incremental delta feed implemented in M33.
    ///
    /// `since` is the `server_time` cursor returned by the previous call
    /// (URL-safe `Z`-suffixed ISO-8601 per the M28 server contract). Pass
    /// `nil` on first launch to get the full data set. The string is sent
    /// straight back to the server — we percent-encode it for transport
    /// but never parse it, so timezone/precision quirks stay opaque to
    /// the client.
    func sync(since: String?) async throws -> SyncResponse {
        let request = try makeSyncRequest(since: since)
        return try await perform(request, as: SyncResponse.self)
    }

    /// Build the `GET /api/v1/sync[?since=...]` request. Split out from
    /// `makeRequest(method:path:...)` because the latter resolves a path
    /// via `endpoint(_:)` and has no clean place to attach a query —
    /// `appendingPathComponent` would encode the `?` as part of the path.
    private func makeSyncRequest(since: String?) throws -> URLRequest {
        let base = endpoint("/api/v1/sync")
        let url: URL
        if let since = since {
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw Error.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "since", value: since)]
            guard let resolved = components.url else {
                throw Error.invalidURL
            }
            url = resolved
        } else {
            url = base
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = apiKey {
            // `X-API-Key` (not `Authorization: Bearer`) — see the
            // `apiKey` doc-comment for why. Using the same header here
            // as `makeRequest` keeps audit attribution consistent
            // across the sync path and every other authenticated call.
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        return request
    }

    /// `GET /api/v1/projects` — implemented in M33/M35.
    func listProjects() async throws -> ProjectListResponse {
        throw Error.notImplemented("listProjects")
    }

    /// `GET /api/v1/notes` — implemented in M33/M34.
    func listNotes(type: String? = nil, archived: Bool? = nil) async throws -> NoteListResponse {
        _ = (type, archived)
        throw Error.notImplemented("listNotes")
    }

    /// `PATCH /api/v1/notes/{id}` — implemented in M36 (edit/move).
    /// Takes a typed `UpdateNotePayload` so callers can't accidentally
    /// hand-roll JSON that drifts from `NoteUpdate` on the server.
    func updateNote(
        id: String,
        patch: UpdateNotePayload,
        idempotencyKey: String? = nil
    ) async throws -> Note {
        _ = (id, patch, idempotencyKey)
        throw Error.notImplemented("updateNote")
    }

    /// `POST /api/v1/notes/{id}/complete` — flip a todo to completed.
    /// Implemented in M36. The server returns the updated `NoteResponse`
    /// (including authoritative `completed_at` timestamp) but callers
    /// in the M36 toggle path discard the body — they've already done
    /// the optimistic flip locally and the next M33 sync will reconcile
    /// the server-side timestamp. Wiring the response through means M37
    /// can replumb this through the mutation queue without changing the
    /// signature.
    ///
    /// There is intentionally no sibling `uncompleteTodo`: the brain
    /// server has no `/uncomplete` endpoint as of the M28 contract, so
    /// re-opening a completed todo from the iOS client is deferred to
    /// M40. `TodoRow`'s tap handler treats a completed-row tap as a
    /// no-op until then.
    /// `POST /api/v1/notes` — create a new note / todo / appointment.
    /// Implemented in M39 for the quick-add path. Direct call (NOT via
    /// the M37 mutation queue) — the user's intent is "save this thing
    /// I just typed and tell me if it failed", which is far better
    /// served by an immediate round-trip than by an enqueue + replay.
    /// M40 will revisit this once the full edit dialog lands and the
    /// queue understands `createTodo` payloads end-to-end.
    func createNote(_ payload: CreateNotePayload) async throws -> Note {
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode create-note body: \(error)")
        }
        let request = try makeRequest(
            method: "POST",
            path: "/api/v1/notes",
            body: body,
            requiresAuth: true
        )
        return try await perform(request, as: Note.self)
    }

    func completeTodo(noteId: String) async throws -> Note {
        let request = try makeRequest(
            method: "POST",
            // Empty JSON body — the server endpoint takes no payload but
            // `Content-Type: application/json` is set unconditionally
            // by `makeRequest`, and FastAPI is happy with `{}` there.
            path: "/api/v1/notes/\(noteId)/complete",
            body: Data("{}".utf8),
            requiresAuth: true
        )
        return try await perform(request, as: Note.self)
    }

    // MARK: - Internal HTTP

    /// Generic GET helper. `path` should start with `/`.
    private func get<T: Decodable>(
        _ path: String,
        as type: T.Type,
        requiresAuth: Bool = true
    ) async throws -> T {
        let request = try makeRequest(method: "GET", path: path, body: nil, requiresAuth: requiresAuth)
        return try await perform(request, as: type)
    }

    /// Resolve an API path against `serverURL`.
    ///
    /// We intentionally use `appendingPathComponent` rather than
    /// `URL(string:relativeTo:)`. The relative-URL initialiser drops any
    /// existing path on `serverURL` when the supplied string starts with
    /// `/` — e.g. `URL(string: "/api/v1/notes", relativeTo:
    /// "https://api.example.com/v2")` resolves to
    /// `https://api.example.com/api/v1/notes`, silently losing `/v2`. By
    /// stripping the leading slash and appending we preserve any path
    /// prefix the user configured in Settings.
    private func endpoint(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return serverURL.appendingPathComponent(trimmed)
    }

    private func makeRequest(
        method: String,
        path: String,
        body: Data?,
        requiresAuth: Bool,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        let url = endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresAuth, let apiKey = apiKey {
            // Use `X-API-Key` (not `Authorization: Bearer`) so the
            // server routes through `get_api_key_user`, which sets
            // `request.state.api_key_id` for audit logging and updates
            // `last_used_at` on the device key row. The bearer path
            // runs `decode_jwt_token` first and 401s on a non-JWT key.
            // See the `apiKey` doc-comment above for the full
            // rationale.
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let idempotencyKey = idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = body
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unknown(statusCode: -1, body: "non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch let decodingError as DecodingError {
                throw Error.decoding(decodingError)
            }
        case 401:
            throw Error.unauthorized
        case 404:
            throw Error.notFound
        case 422:
            let detail = (try? decoder.decode(ErrorEnvelope.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8)
                ?? "validation failed"
            throw Error.validationError(detail: detail)
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Error.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.unknown(statusCode: http.statusCode, body: body)
        }
    }

    /// Like `perform`, but for endpoints that return no body we care
    /// about (e.g. `DELETE /auth/api-keys/{id}`). Maps non-2xx statuses
    /// onto the same typed error cases as `perform` so callers don't
    /// need to special-case revocation failures.
    private func performIgnoringBody(_ request: URLRequest) async throws {
        let (data, response) = try await sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unknown(statusCode: -1, body: "non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw Error.unauthorized
        case 404:
            throw Error.notFound
        case 422:
            let detail = (try? decoder.decode(ErrorEnvelope.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8)
                ?? "validation failed"
            throw Error.validationError(detail: detail)
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Error.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.unknown(statusCode: http.statusCode, body: body)
        }
    }

    /// Validate that `raw` is a UUID before it gets spliced into a URL
    /// path. Returns the canonical (lowercased, hyphenated) string on
    /// success or nil if the input doesn't parse as a UUID. We don't
    /// just trust `UUID.init?` because it accepts both upper- and
    /// lower-case input; canonicalising here keeps server-side caches
    /// (Idempotency-Key dedupe, audit logs) keyed off a single shape.
    fileprivate static func validateResourceId(_ raw: String) -> String? {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// Wraps `URLSession.data(for:)` to convert URLError into our typed
    /// error case. Kept as a separate method so tests can override it.
    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw Error.network(urlError)
        }
    }
}

// MARK: - User-facing error copy

extension BrainAPIClient.Error {
    /// Friendly one-liner suitable for surfacing in a SwiftUI error view.
    /// Falls back to `description` for cases where the raw text is
    /// already presentable (network errors, validation details).
    var userFacingMessage: String {
        switch self {
        case .unauthorized:
            return "That email and password didn't match. Try again."
        case .notFound:
            return "Server endpoint not found. Check the server URL in Settings."
        case .rateLimited(let retry):
            if let retry = retry {
                return "Too many attempts — try again in \(Int(retry))s."
            }
            return "Too many attempts — try again soon."
        case .validationError(let detail):
            return detail
        case .network:
            return "Couldn't reach the server. Check your connection."
        case .decoding:
            return "Got an unexpected response from the server."
        case .unknown(_, _):
            return "Something went wrong. Try again."
        case .notImplemented:
            return "This feature isn't available yet."
        case .invalidURL:
            return "The configured server URL is invalid."
        }
    }
}

// MARK: - SwiftUI Environment

/// Lets views read the app-wide `BrainAPIClient` instance via
/// `@Environment(\.brainAPIClient)`. The instance is constructed once in
/// `BrainApp.init` and injected at the root scene; views never build
/// their own — that would split `apiKey` state across instances.
private struct BrainAPIClientKey: EnvironmentKey {
    static let defaultValue: BrainAPIClient? = nil
}

extension EnvironmentValues {
    var brainAPIClient: BrainAPIClient? {
        get { self[BrainAPIClientKey.self] }
        set { self[BrainAPIClientKey.self] = newValue }
    }
}
