// BrainAPIClient.swift
// brain-ios
//
// Async client for the brain HTTP API. Wraps URLSession + Codable in an
// `actor` so calls from multiple SwiftUI views serialise safely without
// extra locking.
//
// M31 implements only `health()` — proves the URLSession plumbing works
// end-to-end. Other methods are declared with their final signatures and
// throw `BrainAPIClient.Error.notImplemented`. M32 wires login, M33 wires
// sync, etc. Keeping the signatures pinned now means callers (sync
// engine, login view) don't have to chase compile errors when each
// method is filled in.

import Foundation

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
    /// JWT or named API key. Sent as `Authorization: Bearer <key>`.
    /// Either auth method is accepted by the server; iOS uses the named
    /// API key minted at login (M30/M32).
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

    /// Update the bearer token after login (M32) or rotation.
    func setApiKey(_ key: String?) {
        self.apiKey = key
    }

    // MARK: - Endpoints

    /// `GET /health` — implemented in M31 to prove the plumbing works.
    func health() async throws -> HealthResponse {
        try await get("/health", as: HealthResponse.self, requiresAuth: false)
    }

    /// `POST /api/v1/auth/login` — implemented in M32.
    func login(email: String, password: String, deviceName: String?) async throws -> LoginResponse {
        _ = (email, password, deviceName)
        throw Error.notImplemented("login")
    }

    /// `DELETE /api/v1/auth/api-keys/{id}` — implemented in M32 (logout
    /// revokes the device key server-side).
    func revokeApiKey(id: String) async throws {
        _ = id
        throw Error.notImplemented("revokeApiKey")
    }

    /// `GET /api/v1/sync` — implemented in M33.
    func sync(since: String?) async throws -> SyncResponse {
        _ = since
        throw Error.notImplemented("sync")
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

    /// `PATCH /api/v1/notes/{id}` — implemented in M36 (toggle complete).
    func updateNote(id: String, payload: Data, idempotencyKey: String?) async throws -> Note {
        _ = (id, payload, idempotencyKey)
        throw Error.notImplemented("updateNote")
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

    private func makeRequest(
        method: String,
        path: String,
        body: Data?,
        requiresAuth: Bool,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: serverURL)?.absoluteURL else {
            throw Error.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresAuth, let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
