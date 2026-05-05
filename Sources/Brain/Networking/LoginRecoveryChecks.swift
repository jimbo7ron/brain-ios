// LoginRecoveryChecks.swift
// brain-ios
//
// Source-level verification for the M30 4-step login-409 recovery
// (`BrainAPIClient.loginWithRecovery`). brain-ios has no test runner
// today (see CLAUDE.md — "Source-level verification only"); this file
// follows the same pattern as `NotFoundClassificationChecks.swift` and
// `SchemaFallbackChecks.swift`:
//
//   1. `BrainDebugLoginRecoveryChecks.runAll()` returns the list of
//      failures (empty list = green). Hookable from a future debug menu
//      or a one-shot CI step.
//   2. Each failed check fires `assertionFailure(...)` so debug builds
//      halt in the debugger when a regression lands.
//
// Coverage is deliberately narrow — we exercise the pieces that would
// silently break the recovery flow:
//
//   * `BrainAPIClient.Error.nameConflict` is exhaustively handled in
//     `userFacingMessage` (so a future contributor adding a new error
//     case can't accidentally drop this one — Swift's switch
//     exhaustiveness already enforces it at compile time, but
//     `userFacingMessage` returning a non-empty string is what the
//     view actually depends on).
//   * `ApiKeyRecord` round-trips the wire shape the server emits at
//     `GET /api/v1/auth/api-keys` — specifically the `revoked_at`
//     field, which the orphan filter in `loginWithRecovery` depends
//     on. If the field name drifted or the optional decoding broke,
//     every recovery attempt would skip the revoke step (because
//     `revokedAt` would always be nil) and the second login would
//     still 409.
//
// We don't try to exercise the multi-call recovery flow itself — the
// actor-based client doesn't have a clean injection point for fake
// HTTP responses without dragging in a full URLSession test double,
// and the wiring (catch on `.nameConflict` → list → filter → revoke
// → retry) is straight-line code with no branching the type system
// doesn't already cover. Manual TestFlight verification is the right
// tool for the end-to-end path; see the PR body's test plan.

#if DEBUG

import Foundation

/// Bundle of debug-only verification cases for the M30 login-409
/// recovery. Production binaries strip the entire enum.
enum BrainDebugLoginRecoveryChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds
    /// halt in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        checkNameConflictHasUserFacingMessage(into: &failures)
        checkApiKeyRecordRoundTripsRevokedAt(into: &failures)
        checkApiKeyRecordRoundTripsNullRevokedAt(into: &failures)
        checkApiKeyListResponseDecodesServerShape(into: &failures)

        return failures
    }

    // MARK: - Cases

    /// `BrainAPIClient.Error.nameConflict` must have a non-empty
    /// `userFacingMessage`. The login flow handles 409 internally so
    /// this copy is a fallback (rare path), but if the case ever falls
    /// through to `description` because someone removed the switch
    /// arm, the user would see a noisy raw string. Keep the contract
    /// explicit.
    private static func checkNameConflictHasUserFacingMessage(into failures: inout [String]) {
        let error = BrainAPIClient.Error.nameConflict(detail: "device-key 'iPhone — Test' already exists")
        let message = error.userFacingMessage
        if message.isEmpty {
            record(&failures, ".nameConflict.userFacingMessage is empty")
            return
        }
        // Also ensure we're NOT leaking the raw `detail` (which
        // contains the exact device name and is more confusing than
        // helpful in the rare-fallback case). The message should be
        // the friendly fixed copy, not the server's `detail` text.
        if message.contains("iPhone — Test") {
            record(&failures, ".nameConflict.userFacingMessage leaks raw detail string: \(message)")
        }
    }

    /// `ApiKeyRecord` (used by `ApiKeyListResponse`) must round-trip
    /// the `revoked_at` field from the server's wire shape. The
    /// orphan-filter in `BrainAPIClient.loginWithRecovery` reads
    /// `revokedAt == nil` to decide whether to issue the DELETE; if
    /// decoding silently dropped the field (because of a CodingKey
    /// typo, say) the filter would always match and the recovery
    /// would loop on a stale-but-revoked row.
    private static func checkApiKeyRecordRoundTripsRevokedAt(into failures: inout [String]) {
        let json = #"""
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "iPhone — Living Room",
            "created_at": "2026-04-30T10:00:00Z",
            "last_used_at": "2026-05-02T18:30:00Z",
            "revoked_at": "2026-05-03T09:15:00Z"
        }
        """#
        guard let decoded = try? JSONDecoder().decode(ApiKeyRecord.self, from: Data(json.utf8)) else {
            record(&failures, "ApiKeyRecord failed to decode the server's wire shape")
            return
        }
        if decoded.revokedAt != "2026-05-03T09:15:00Z" {
            record(&failures, "ApiKeyRecord.revokedAt didn't round-trip: got \(decoded.revokedAt ?? "nil")")
        }
        if decoded.id != "11111111-1111-1111-1111-111111111111" {
            record(&failures, "ApiKeyRecord.id didn't round-trip: got \(decoded.id)")
        }
    }

    /// The orphan-filter in `loginWithRecovery` keys off
    /// `revokedAt == nil`. Make sure null on the wire decodes as nil
    /// on the swift side (rather than the literal string "null", say).
    private static func checkApiKeyRecordRoundTripsNullRevokedAt(into failures: inout [String]) {
        let json = #"""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "iPhone — Office",
            "created_at": "2026-04-30T10:00:00Z",
            "last_used_at": null,
            "revoked_at": null
        }
        """#
        guard let decoded = try? JSONDecoder().decode(ApiKeyRecord.self, from: Data(json.utf8)) else {
            record(&failures, "ApiKeyRecord failed to decode the null-revoked_at shape")
            return
        }
        if decoded.revokedAt != nil {
            record(&failures, "ApiKeyRecord.revokedAt should be nil for null on the wire, got \(decoded.revokedAt ?? "nil")")
        }
        if decoded.lastUsedAt != nil {
            record(&failures, "ApiKeyRecord.lastUsedAt should be nil for null on the wire, got \(decoded.lastUsedAt ?? "nil")")
        }
    }

    /// Full `ApiKeyListResponse` decode against the server's wire
    /// shape. Catches drift between the `keys` / `total` field names
    /// or the nesting structure that the recovery flow's call to
    /// `listApiKeys` depends on.
    private static func checkApiKeyListResponseDecodesServerShape(into failures: inout [String]) {
        let json = #"""
        {
            "keys": [
                {
                    "id": "33333333-3333-3333-3333-333333333333",
                    "name": "iPhone — Bedroom",
                    "created_at": "2026-04-30T10:00:00Z",
                    "last_used_at": null,
                    "revoked_at": null
                }
            ],
            "total": 1
        }
        """#
        guard let listing = try? JSONDecoder().decode(ApiKeyListResponse.self, from: Data(json.utf8)) else {
            record(&failures, "ApiKeyListResponse failed to decode the server's wire shape")
            return
        }
        if listing.total != 1 {
            record(&failures, "ApiKeyListResponse.total didn't round-trip: got \(listing.total)")
        }
        if listing.keys.count != 1 {
            record(&failures, "ApiKeyListResponse.keys count wrong: got \(listing.keys.count)")
            return
        }
        if listing.keys[0].name != "iPhone — Bedroom" {
            record(&failures, "ApiKeyListResponse.keys[0].name didn't round-trip: got \(listing.keys[0].name)")
        }
    }

    // MARK: - Helpers

    private static func record(_ failures: inout [String], _ message: String) {
        failures.append(message)
        assertionFailure(message)
    }
}

#endif
