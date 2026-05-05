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
        /// Server returned 404 for a specific RESOURCE the client asked
        /// about (e.g. note that no longer exists). Mutation queue
        /// poisons this — replaying will never succeed.
        case notFound
        /// Server returned 404 for the PATH itself (route not registered
        /// in the server's router, or a reverse-proxy 404). Distinct
        /// from `.notFound` because:
        ///   * resource-404 = "the thing is gone, give up"
        ///   * route-404 = "iOS expects an endpoint the server doesn't
        ///     have" — typically a misconfigured server URL or an iOS
        ///     build that's newer than the deployed server. Should
        ///     backoff + surface loudly, NOT poison.
        case routeNotFound
        case rateLimited(retryAfter: TimeInterval?)
        case validationError(detail: String)
        /// Server returned 409 — a uniqueness constraint was violated.
        /// In the auth flow this is M30's "non-revoked named API key
        /// with the same name already exists" rejection (see
        /// `brain/src/brain/server.py:805-807` and the recovery
        /// contract at `:824-840`). Surfaced as a typed case so
        /// `loginWithRecovery(...)` can intercept and run the
        /// 4-step orphan-revoke flow without the caller seeing a
        /// generic `.unknown` error.
        case nameConflict(detail: String)
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
                return "Resource not found."
            case .routeNotFound:
                return "Server endpoint not found — check server URL or update the app."
            case .rateLimited(let retry):
                if let retry = retry {
                    return "Rate limited — retry in \(Int(retry))s."
                }
                return "Rate limited."
            case .validationError(let detail):
                return "Validation error: \(detail)"
            case .nameConflict(let detail):
                return "Name conflict: \(detail)"
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
    ///
    /// `bearerToken` is set only by `loginWithRecovery(...)` during
    /// the M30 4-step orphan-revoke: at that point we have a JWT but
    /// no API key yet (the orphan is the one currently squatting on
    /// the requested name). When set, the request authenticates via
    /// `Authorization: Bearer` instead of `X-API-Key`. Mutually
    /// exclusive with the actor's persisted `apiKey` — see
    /// `makeRequest` for the routing rule.
    func revokeApiKey(id: String, bearerToken: String? = nil) async throws {
        let request = try makeRequest(
            method: "DELETE",
            path: "/api/v1/auth/api-keys/\(id)",
            body: nil,
            requiresAuth: true,
            bearerToken: bearerToken
        )
        try await performIgnoringBody(request)
    }

    /// `GET /api/v1/auth/api-keys` — list the current user's named API
    /// keys (no plaintext, no hashes). Used by `loginWithRecovery(...)`
    /// during the M30 4-step recovery to find an orphan device key
    /// whose name matches the requested `device_name`.
    ///
    /// `bearerToken` follows the same convention as `revokeApiKey`:
    /// when set, the request authenticates via `Authorization: Bearer`
    /// instead of the actor's persisted `apiKey`. The recovery flow is
    /// the only legitimate caller that supplies it; future code that
    /// surfaces "your devices" in Settings should pass nil and let the
    /// usual `X-API-Key` path do its job.
    ///
    /// We always pass `include_revoked=true` (the server's default) so
    /// the recovery can also notice keys that were revoked but whose
    /// names are still indexed — though M30's uniqueness constraint
    /// only fires on non-revoked keys, so the `revokedAt == nil`
    /// filter on the result is what actually identifies the orphan.
    func listApiKeys(bearerToken: String? = nil) async throws -> ApiKeyListResponse {
        let request = try makeRequest(
            method: "GET",
            path: "/api/v1/auth/api-keys",
            body: nil,
            requiresAuth: true,
            bearerToken: bearerToken
        )
        return try await perform(request, as: ApiKeyListResponse.self)
    }

    /// Login with auto-recovery from M30's HTTP 409 ("named API key
    /// with that device name already exists"). The brain server
    /// documents the recovery contract at
    /// `brain/src/brain/server.py:824-840`; iOS implements it
    /// transparently here so the user sees a single Sign-in tap with
    /// no error path.
    ///
    /// Steps:
    ///   1. Try `POST /auth/login` WITH `device_name` (mints a fresh
    ///      key + returns its plaintext on the response).
    ///   2. On 409: retry login WITHOUT `device_name`. The server
    ///      returns a JWT but no key — we use the JWT as Bearer for
    ///      the next two calls because no API key is in Keychain yet.
    ///   3. `GET /auth/api-keys` (with the JWT). Find the entry whose
    ///      `name == deviceName` AND `revokedAt == nil`. Both filters
    ///      are load-bearing: if we revoke the wrong row we lose an
    ///      unrelated device's access; if we don't filter on
    ///      `revokedAt == nil` we'll keep retrying-then-revoking the
    ///      same dead row forever.
    ///   4. `DELETE /auth/api-keys/{id}` (with the JWT) to revoke the
    ///      orphan. Skip cleanly if no match — step 5 will then
    ///      surface the original 409 for the caller to handle.
    ///   5. Retry login WITH `device_name`. Returns the response with
    ///      the new plaintext key inlined.
    ///
    /// Termination: the recovery is single-shot — if step 5 still
    /// throws (e.g. a race where another client minted a key in
    /// between, or step 4 was a no-op), we let the second 409 propagate
    /// to the caller as `.nameConflict` rather than looping. Looping
    /// would mask a genuine server-side bug or a duplicate-mint race
    /// the human needs to know about.
    ///
    /// Why this lives on the client (not in the server's login path):
    /// the server contract explicitly hands the policy choice to the
    /// caller (see `server.py:815-840` — clients can choose to retry
    /// with a name suffix instead of revoking). iOS chooses revoke
    /// because the orphan is by definition unreachable (its plaintext
    /// is lost forever in Keychain on the prior install).
    func loginWithRecovery(
        email: String,
        password: String,
        deviceName: String
    ) async throws -> LoginResponse {
        do {
            return try await login(
                email: email,
                password: password,
                deviceName: deviceName
            )
        } catch BrainAPIClient.Error.nameConflict {
            // Step 2: re-login without device_name to obtain a JWT
            // we can use to clean up the orphan. The server returns
            // a JWT-only response (no `api_key` block) on this path
            // because `device_name` is omitted.
            let jwtResponse = try await login(
                email: email,
                password: password,
                deviceName: nil
            )
            // Step 3: list keys with the JWT and find the orphan.
            let listing = try await listApiKeys(bearerToken: jwtResponse.token)
            // Step 4: revoke the orphan iff one is present. If no
            // match (the 409 was for some other reason — e.g. a
            // server-side race where the row already got revoked),
            // we skip cleanly and let step 5 either succeed or
            // surface a fresh 409 to the caller.
            if let orphan = listing.keys.first(
                where: { $0.name == deviceName && $0.revokedAt == nil }
            ) {
                try await revokeApiKey(
                    id: orphan.id,
                    bearerToken: jwtResponse.token
                )
            }
            // Step 5: retry the original login. A second 409 here is
            // intentionally NOT recovered — see the doc-comment for
            // the rationale.
            return try await login(
                email: email,
                password: password,
                deviceName: deviceName
            )
        }
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
        case .updateTodo:
            // M40: PUT /api/v1/notes/{id} with the queue item's pre-
            // encoded JSON body. The server treats unspecified fields as
            // "leave alone", so the payload is naturally PATCH-style
            // (only changed fields ride). The dispatch site doesn't
            // re-decode the body — it's already exactly what the server
            // expects, captured at enqueue time when the user hit Save.
            let request = try makeRequest(
                method: "PUT",
                path: "/api/v1/notes/\(resourceId)",
                body: item.payload,
                requiresAuth: true,
                idempotencyKey: key
            )
            try await performIgnoringBody(request)
        case .updateProject:
            // M40: PUT /api/v1/projects/{id}. Same shape as updateTodo;
            // the body is `UpdateProjectPayload` JSON encoded at
            // enqueue. Note: this endpoint covers name/colour/sort_order
            // /archived only — section editing rides separate endpoints
            // and (for M40) is handled by direct API calls in
            // `EditProjectView`, not the queue.
            let request = try makeRequest(
                method: "PUT",
                path: "/api/v1/projects/\(resourceId)",
                body: item.payload,
                requiresAuth: true,
                idempotencyKey: key
            )
            try await performIgnoringBody(request)
        case .uncompleteTodo,
             .createTodo,
             .archiveNote,
             .createProject,
             .addSection:
            // TODO(M41+): Wire each of these to its server endpoint.
            // The shape is the same as `.updateTodo`: build a request
            // via `makeRequest(...)` with `idempotencyKey: key`, then
            // perform/performIgnoringBody depending on whether the
            // caller cares about the response body. Keep `body` typed
            // via the structs in `DTOs.swift` (e.g. `UpdateNotePayload`)
            // and encode the payload at the call site before enqueue.
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

    /// `GET /api/v1/notes?q=<query>&limit=<limit>` — free-text search
    /// across `title` and `content`. Implemented in M43 for the in-app
    /// SearchView.
    ///
    /// Why this endpoint rather than `POST /api/v1/search`:
    ///   * `/api/v1/search` is the semantic-similarity endpoint backed
    ///     by embeddings; it requires the server to have run
    ///     `_ensure_embeddings()` and is the right hammer for "find
    ///     things related to X".
    ///   * `/api/v1/notes?q=...` is a substring/full-text match against
    ///     title + content. For the iOS user typing into a search box
    ///     ("milk", "PR review"), this is what they want — instant
    ///     literal matches, not "things semantically near milk".
    ///   * It also avoids the embeddings warm-up cost on cold cache,
    ///     which can be 200–500 ms on the server's first request.
    ///
    /// We pass `include_completed: true` so the user can find a todo
    /// they completed last week and re-open it (M44 territory). The
    /// list is sorted server-side by `updated_at` desc which matches
    /// the "most recent first" expectation users have for search.
    func searchNotes(query: String, limit: Int = 50) async throws -> NoteListResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty query is a programmer error — the caller should
            // have suppressed the request when the field cleared.
            // Returning an empty list is the friendliest default; we
            // don't want to round-trip `?q=` and have the server
            // return everything.
            return NoteListResponse(notes: [], total: 0)
        }
        let base = endpoint("/api/v1/notes")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw Error.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            // Pull completed todos into the result set — search is the
            // canonical path for finding old work, and excluding them
            // would surprise users who explicitly typed a substring of
            // a completed todo's title.
            URLQueryItem(name: "include_completed", value: "true"),
        ]
        guard let url = components.url else {
            throw Error.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        return try await perform(request, as: NoteListResponse.self)
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

    /// `POST /api/v1/projects` — create a new project. Direct call (NOT
    /// via the M37 mutation queue) because the user is in an interactive
    /// "New project" sheet and benefits from immediate feedback, and
    /// because the M37 queue's `MutationOp.createProject` isn't fully
    /// wired yet (M41+ territory). Same direct-call rationale as
    /// `createNote(...)` for the M39 quick-add path.
    ///
    /// Returns the freshly-created project (with server-assigned id,
    /// sort_order, and the canonical M26 default sections — Now/Next/
    /// Later). The caller (`NewProjectView`) discards the response and
    /// instead fires a sync; the next sync delta writes the new row into
    /// SwiftData and the Projects list re-renders via `@Query`.
    func createProject(_ payload: CreateProjectPayload) async throws -> Project {
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode create-project body: \(error)")
        }
        let request = try makeRequest(
            method: "POST",
            path: "/api/v1/projects",
            body: body,
            requiresAuth: true
        )
        return try await perform(request, as: Project.self)
    }

    /// `POST /api/v1/projects/{id}/sections` — append a new section
    /// to a project. Implemented in M40 for the edit-project dialog.
    /// Direct call (NOT via the M37 mutation queue) because the
    /// queue's `MutationOp.addSection` isn't fully wired yet (M41
    /// territory) and the user is in the middle of an interactive
    /// edit flow that benefits from immediate per-row feedback.
    /// Returns the full project so the caller can re-render the
    /// section list with the server's authoritative slug + position.
    func addProjectSection(projectId: String, name: String) async throws -> Project {
        struct Body: Encodable { let name: String }
        let body: Data
        do {
            body = try encoder.encode(Body(name: name))
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode add-section body: \(error)")
        }
        let request = try makeRequest(
            method: "POST",
            path: "/api/v1/projects/\(projectId)/sections",
            body: body,
            requiresAuth: true
        )
        return try await perform(request, as: Project.self)
    }

    /// `PATCH /api/v1/projects/{id}/sections/{slug}` — rename an
    /// existing section. The slug is preserved server-side so any
    /// todos pointing at it stay attached. Used by M40's edit-project
    /// dialog. Same direct-call rationale as `addProjectSection`.
    func renameProjectSection(projectId: String, slug: String, name: String) async throws -> Project {
        struct Body: Encodable { let name: String }
        let body: Data
        do {
            body = try encoder.encode(Body(name: name))
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode rename-section body: \(error)")
        }
        let request = try makeRequest(
            method: "PATCH",
            path: "/api/v1/projects/\(projectId)/sections/\(slug)",
            body: body,
            requiresAuth: true
        )
        return try await perform(request, as: Project.self)
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

    /// `POST /api/v1/devices` — register an APNs device token (M41).
    /// Wraps the M29 server endpoint that upserts on `apns_token`, so
    /// calling this every sign-in is safe: a duplicate token just
    /// bumps `last_seen_at` server-side rather than minting a new row.
    /// Caller is `NotificationManager.handleAPNsToken(_:)`; the body
    /// carries the lowercase-hex token plus a human-readable
    /// `device_name` for the user's device list.
    ///
    /// We discard the response body — the server returns the inserted
    /// row but the iOS client doesn't need any of it (the token is
    /// what we already sent). M42 will revisit if a "list devices"
    /// surface lands on the iOS side.
    func registerDevice(
        apnsToken: String,
        platform: String = "ios",
        deviceName: String
    ) async throws {
        let payload = DeviceRegisterPayload(
            apnsToken: apnsToken,
            platform: platform,
            deviceName: deviceName
        )
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode device-register body: \(error)")
        }
        let request = try makeRequest(
            method: "POST",
            path: "/api/v1/devices",
            body: body,
            requiresAuth: true
        )
        try await performIgnoringBody(request)
    }

    /// `GET /api/v1/preferences/notifications` — fetch the per-user
    /// notification preferences (M42). The server returns a full
    /// snapshot every time, so callers don't need to merge — assign
    /// the response straight onto state.
    ///
    /// Returns the typed `NotificationPreferences` or throws a
    /// `BrainAPIClient.Error`. A 404 here means the server doesn't yet
    /// have the M42 endpoints deployed (iOS may ship before the
    /// server-side PR lands); the view treats that as a graceful
    /// "couldn't load" rather than a hard failure.
    func getNotificationPreferences() async throws -> NotificationPreferences {
        try await get("/api/v1/preferences/notifications", as: NotificationPreferences.self)
    }

    /// `PUT /api/v1/preferences/notifications` — partial update of the
    /// notification preferences (M42). Send only the fields you want to
    /// change; the server merges and returns the full updated snapshot.
    /// Direct call (NOT via the M37 mutation queue) because the user is
    /// in an interactive form and benefits from immediate feedback —
    /// failures surface as an inline error banner, and the local toggle
    /// state is preserved so the user can retry by re-toggling.
    func updateNotificationPreferences(
        _ payload: NotificationPreferencesUpdate
    ) async throws -> NotificationPreferences {
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw Error.unknown(statusCode: -1, body: "failed to encode notification-prefs body: \(error)")
        }
        let request = try makeRequest(
            method: "PUT",
            path: "/api/v1/preferences/notifications",
            body: body,
            requiresAuth: true
        )
        return try await perform(request, as: NotificationPreferences.self)
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
        idempotencyKey: String? = nil,
        bearerToken: String? = nil
    ) throws -> URLRequest {
        let url = endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresAuth {
            // `bearerToken` and the actor's persisted `apiKey` are
            // mutually exclusive — only one auth header is set per
            // request. The bearer path is reserved for the M30 4-step
            // recovery in `loginWithRecovery(...)`, where we have a
            // freshly-issued JWT but the previous device's API key is
            // still occupying the requested name server-side and
            // there's no key in Keychain yet. Every other authenticated
            // call falls through to the `X-API-Key` branch so audit
            // attribution (`request.state.api_key_id`) and
            // `last_used_at` bookkeeping stay correct on the device
            // key row. See the `apiKey` doc-comment above for the full
            // rationale on the header choice.
            if let bearerToken = bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            } else if let apiKey = apiKey {
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
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
            throw Self.classify404(response: http, data: data, decoder: decoder)
        case 409:
            // M30 device-key name conflict — see the `nameConflict`
            // doc-comment for the recovery contract.
            let detail = (try? decoder.decode(ErrorEnvelope.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8)
                ?? "name conflict"
            throw Error.nameConflict(detail: detail)
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
            throw Self.classify404(response: http, data: data, decoder: decoder)
        case 409:
            // Mirror `perform`'s 409 handling. No-body endpoints
            // currently never legitimately 409 (DELETE is idempotent
            // server-side, so revoking an already-revoked key is a
            // 200 no-op), but the case is wired here for symmetry so
            // a future endpoint that returns 409 + empty body doesn't
            // silently fall through to `.unknown`.
            let detail = (try? decoder.decode(ErrorEnvelope.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8)
                ?? "name conflict"
            throw Error.nameConflict(detail: detail)
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

    /// Decide whether a 404 means "the resource you asked about doesn't
    /// exist" (poison-worthy) or "the path you asked for isn't routed
    /// on this server" (transient — likely a deploy / config issue).
    ///
    /// Heuristic — necessarily fuzzy because HTTP doesn't distinguish
    /// these cases at the status-code layer. Discrimination order:
    ///
    ///   1. **Non-JSON body / `Content-Type: text/html`** → routeNotFound.
    ///      This is what reverse proxies (nginx, Cloudflare) emit when
    ///      the request never reaches the brain server, e.g. because
    ///      the configured base URL is wrong.
    ///
    ///   2. **JSON body with `detail` of `"Not Found"`** → routeNotFound.
    ///      This is FastAPI's default for an unrouted path.
    ///
    ///   3. **JSON body with `detail` starting with a known resource
    ///      label (`"Note "`, `"Project "`, `"Section "`, etc.)** →
    ///      notFound. brain's server uniformly emits `"<Type> not
    ///      found: <id>"` for resource-404s; matching the prefix lets
    ///      us distinguish from a future endpoint we haven't routed
    ///      yet whose 404 happens to be JSON.
    ///
    ///   4. **Anything else** (JSON body that doesn't match either
    ///      shape, missing/empty body, etc.) → routeNotFound. This is
    ///      the conservative choice: false-positive routeNotFound
    ///      means "backoff + log loudly" (recoverable on next replay
    ///      once config is fixed), whereas a false-positive notFound
    ///      poisons a queue item permanently. Better to over-retry
    ///      than to silently drop a user's mutation.
    ///
    /// Caveat: the `detail`-prefix list is hand-maintained against the
    /// brain server. Adding a new resource type that emits
    /// `"<NewType> not found: ..."` requires adding a prefix here, or
    /// every legitimate not-found will be classified as routeNotFound
    /// and the queue will retry forever (until the maxAttempts cap).
    /// That's a recoverable failure mode, not data loss.
    static func classify404(
        response: HTTPURLResponse,
        data: Data,
        decoder: JSONDecoder
    ) -> Error {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // If the response body isn't JSON at all, we're almost
        // certainly looking at a reverse-proxy or load-balancer 404.
        if !contentType.contains("application/json") {
            return .routeNotFound
        }
        guard let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) else {
            // JSON Content-Type but body didn't parse as
            // `{"detail": "..."}`. Could be a stub server / mock
            // returning weird JSON. Treat as route-not-found rather
            // than poisoning a real mutation.
            return .routeNotFound
        }
        let detail = envelope.detail
        // FastAPI's default 404 for an unrouted path.
        if detail == "Not Found" {
            return .routeNotFound
        }
        // brain server's resource-404 envelopes start with a known
        // resource type label. Match case-insensitively so a server
        // tweak ("note not found:") doesn't break classification.
        let lower = detail.lowercased()
        for label in Self.resourceNotFoundPrefixes {
            if lower.hasPrefix(label) {
                return .notFound
            }
        }
        // JSON envelope but `detail` doesn't match any known shape.
        // Conservatively classify as routeNotFound so we don't poison
        // a queue item on a 404 we don't recognise.
        return .routeNotFound
    }

    /// Lowercase prefixes of `detail` strings the brain server emits
    /// when a specific resource is missing. Maintained alongside
    /// `server.py` raise sites — keep in sync when a new resource
    /// type lands. Lower-cased so the match in `classify404` is
    /// case-insensitive (server actually uses Title Case today).
    private static let resourceNotFoundPrefixes: [String] = [
        "note not found",
        "project not found",
        "section not found",
        "api key not found",
        "device token not found",
        "appointment not found",
    ]

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
            return "That item was deleted on the server."
        case .routeNotFound:
            return "Server doesn't recognise that endpoint. Update the app or check the server URL."
        case .rateLimited(let retry):
            if let retry = retry {
                return "Too many attempts — try again in \(Int(retry))s."
            }
            return "Too many attempts — try again soon."
        case .validationError(let detail):
            return detail
        case .nameConflict:
            // Rarely surfaced — the login flow handles 409 internally
            // via `loginWithRecovery(...)`. This copy only shows if
            // the recovery itself fails (e.g. step 5 still 409s after
            // the orphan revoke), which means something genuinely odd
            // is going on server-side and the user should retry.
            return "That name is already in use. Try again."
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
