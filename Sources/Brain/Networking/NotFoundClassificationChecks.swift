// NotFoundClassificationChecks.swift
// brain-ios
//
// Source-level verification for `BrainAPIClient.classify404` — the
// heuristic that distinguishes a server-side resource-not-found (poison
// the queue item) from a server-side route-not-found (back off and surface
// loudly so an operator notices the misconfiguration). brain-ios has no
// test runner today (see CLAUDE.md — "Source-level verification only");
// this file follows the same pattern as `NotificationPrefsChecks.swift`
// and `ServerDateChecks` from M42 / earlier polish rounds:
//
//   1. `BrainDebugNotFoundChecks.runAll()` returns the list of failures
//      (empty list = green). Hookable from a future debug menu or a
//      one-shot CI step.
//   2. Each failed check fires `assertionFailure(...)` so debug builds
//      halt in the debugger when a regression lands.
//
// Coverage is deliberately narrow: we exercise the classifier with the
// concrete shapes the brain server emits today (and the typical reverse-
// proxy / FastAPI default 404s) but NOT framework behaviour
// (`HTTPURLResponse.value(forHTTPHeaderField:)`, `JSONDecoder`).

#if DEBUG

import Foundation

/// Bundle of debug-only verification cases for the polish-round 404
/// disambiguation. Production binaries strip the entire enum.
enum BrainDebugNotFoundChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds
    /// halt in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        checkResourceNotFoundJSONClassifiesAsNotFound(into: &failures)
        checkProjectNotFoundJSONClassifiesAsNotFound(into: &failures)
        checkFastAPIDefault404ClassifiesAsRouteNotFound(into: &failures)
        checkHTMLBodyClassifiesAsRouteNotFound(into: &failures)
        checkEmptyBodyClassifiesAsRouteNotFound(into: &failures)
        checkUnknownDetailShapeClassifiesAsRouteNotFound(into: &failures)
        checkCaseInsensitivePrefixMatch(into: &failures)

        return failures
    }

    // MARK: - Cases

    /// Server's typical resource-404 envelope: `Content-Type:
    /// application/json` + `{"detail": "Note not found: <uuid>"}`.
    /// Should classify as `.notFound` so the queue poisons the row —
    /// the resource is genuinely gone server-side and replaying will
    /// never succeed.
    private static func checkResourceNotFoundJSONClassifiesAsNotFound(into failures: inout [String]) {
        let body = #"{"detail": "Note not found: 11111111-1111-1111-1111-111111111111"}"#
        let result = classify(
            body: Data(body.utf8),
            contentType: "application/json"
        )
        if case .notFound = result {
            return
        }
        record(&failures, "resource-404 JSON should classify as .notFound, got \(result)")
    }

    /// Same shape but for a different resource type — exercises the
    /// prefix list. Catches the case where a future contributor only
    /// adds one resource label and forgets the others.
    private static func checkProjectNotFoundJSONClassifiesAsNotFound(into failures: inout [String]) {
        let body = #"{"detail": "Project not found: home"}"#
        let result = classify(
            body: Data(body.utf8),
            contentType: "application/json"
        )
        if case .notFound = result {
            return
        }
        record(&failures, "project-404 JSON should classify as .notFound, got \(result)")
    }

    /// FastAPI's default 404 for an unrouted path: same JSON envelope
    /// shape, but `detail` is the generic `"Not Found"`. Should
    /// classify as `.routeNotFound` so the queue backs off rather
    /// than poisoning a real mutation against a misconfigured server.
    private static func checkFastAPIDefault404ClassifiesAsRouteNotFound(into failures: inout [String]) {
        let body = #"{"detail": "Not Found"}"#
        let result = classify(
            body: Data(body.utf8),
            contentType: "application/json"
        )
        if case .routeNotFound = result {
            return
        }
        record(&failures, "FastAPI default 404 should classify as .routeNotFound, got \(result)")
    }

    /// Reverse-proxy / load-balancer 404: HTML body with
    /// `Content-Type: text/html`. The request never reached the brain
    /// server — typically because the user pointed iOS at the wrong
    /// host. Must classify as `.routeNotFound`.
    private static func checkHTMLBodyClassifiesAsRouteNotFound(into failures: inout [String]) {
        let body = "<html><head><title>404 Not Found</title></head><body><h1>404</h1></body></html>"
        let result = classify(
            body: Data(body.utf8),
            contentType: "text/html; charset=utf-8"
        )
        if case .routeNotFound = result {
            return
        }
        record(&failures, "HTML 404 body should classify as .routeNotFound, got \(result)")
    }

    /// Empty body / no Content-Type: some intermediaries strip the
    /// body entirely. Should fall through to `.routeNotFound` because
    /// without evidence of a structured server response we can't
    /// safely poison a mutation.
    private static func checkEmptyBodyClassifiesAsRouteNotFound(into failures: inout [String]) {
        let result = classify(
            body: Data(),
            contentType: ""
        )
        if case .routeNotFound = result {
            return
        }
        record(&failures, "empty body should classify as .routeNotFound, got \(result)")
    }

    /// JSON body whose `detail` doesn't match any known resource
    /// prefix and isn't FastAPI's generic. Conservative behaviour:
    /// classify as `.routeNotFound` rather than poisoning. Better to
    /// over-retry than to silently drop a user's mutation on a 404
    /// shape we don't recognise.
    private static func checkUnknownDetailShapeClassifiesAsRouteNotFound(into failures: inout [String]) {
        let body = #"{"detail": "Some other thing went wrong"}"#
        let result = classify(
            body: Data(body.utf8),
            contentType: "application/json"
        )
        if case .routeNotFound = result {
            return
        }
        record(&failures, "unknown JSON detail should classify as .routeNotFound, got \(result)")
    }

    /// The brain server emits Title Case ("Note not found: ...") but
    /// our classifier should also accept lower-case ("note not
    /// found: ...") so a server tweak doesn't silently regress to
    /// retrying-forever on a real resource-404. Enforces the
    /// case-insensitive contract.
    private static func checkCaseInsensitivePrefixMatch(into failures: inout [String]) {
        let body = #"{"detail": "note not found: 22222222-2222-2222-2222-222222222222"}"#
        let result = classify(
            body: Data(body.utf8),
            contentType: "application/json"
        )
        if case .notFound = result {
            return
        }
        record(&failures, "case-insensitive resource-404 should classify as .notFound, got \(result)")
    }

    // MARK: - Helpers

    /// Build a synthetic `HTTPURLResponse` and route it through the
    /// real classifier. We can't construct an `HTTPURLResponse` with
    /// arbitrary headers via the public initialiser cleanly, so we
    /// pass the headers through the dedicated `headerFields` arg.
    /// Force-unwrap is safe — the URL literal is valid and the
    /// initialiser only fails on a nil URL.
    private static func classify(body: Data, contentType: String) -> BrainAPIClient.Error {
        let url = URL(string: "https://example.com/api/v1/notes/abc")! // swiftlint:disable:this force_unwrapping
        var headers: [String: String] = [:]
        if !contentType.isEmpty {
            headers["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )! // swiftlint:disable:this force_unwrapping
        return BrainAPIClient.classify404(
            response: response,
            data: body,
            decoder: JSONDecoder()
        )
    }

    private static func record(_ failures: inout [String], _ message: String) {
        failures.append(message)
        assertionFailure(message)
    }
}

#endif
