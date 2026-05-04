// NotificationChecks.swift
// brain-ios
//
// Source-level verification for the M41 APNs registration plumbing.
// brain-ios doesn't have a test runner (see CLAUDE.md — "Source-level
// verification only"), so we ship `#if DEBUG`-gated assertions and a
// manual entry point that prints failures to the console.
//
// Mirrors the M39 `QuickAddParserChecks.swift` pattern:
//
//   1. Throwaway runtime invocation: `NotificationChecks.runAll()`
//      returns the list of failures. Empty list = green.
//
//   2. Compile-time confidence: each failed check fires
//      `assertionFailure(...)` so debug builds halt in the debugger
//      when a regression lands.
//
// Coverage is deliberately narrow — we test our own glue (token-bytes
// to hex, DTO encoding) but NOT framework behaviour (Foundation's
// `JSONEncoder`, the system `UNUserNotificationCenter`).

#if DEBUG && canImport(UIKit)

import Foundation
import UserNotifications

/// Bundle of verification cases for the M41 APNs registration code.
enum NotificationChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds
    /// halt in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        checkTokenHexEncoding(into: &failures)
        checkDeviceRegisterPayloadEncodes(into: &failures)
        checkAuthorizationStatusValuesAreStable(into: &failures)

        return failures
    }

    // MARK: - Cases

    /// `NotificationManager.hex(from:)` produces a lowercase hex
    /// string with two characters per byte and no separators. The
    /// brain server's M29 schema stores `apns_token` as TEXT and
    /// `aioapns` expects exactly this format, so any drift here
    /// would make every push undeliverable.
    private static func checkTokenHexEncoding(into failures: inout [String]) {
        // Bytes: 0x00 0x01 0xff 0xab — covers leading zero, low value,
        // high value, and a mixed nibble case in one fixture.
        let data = Data([0x00, 0x01, 0xff, 0xab])
        let hex = NotificationManager.hex(from: data)
        let expected = "0001ffab"
        check(
            hex == expected,
            "hex encoding produced \(hex), expected \(expected)",
            into: &failures
        )

        // Apple's APNs tokens are 32 bytes -> 64 hex chars. Verify the
        // length math holds for a realistic payload.
        let realistic = Data(repeating: 0x42, count: 32)
        let realisticHex = NotificationManager.hex(from: realistic)
        check(
            realisticHex.count == 64,
            "32-byte token produced \(realisticHex.count) hex chars, expected 64",
            into: &failures
        )
        check(
            realisticHex == String(repeating: "42", count: 32),
            "32-byte token of 0x42 produced unexpected hex \(realisticHex)",
            into: &failures
        )
    }

    /// `DeviceRegisterPayload` round-trips through `JSONEncoder` with
    /// snake_case wire keys. The brain server's M29 endpoint expects
    /// `apns_token`, `platform`, `device_name` exactly — any drift in
    /// the `CodingKeys` would silently break registration.
    private static func checkDeviceRegisterPayloadEncodes(into failures: inout [String]) {
        let payload = DeviceRegisterPayload(
            apnsToken: "abcd1234",
            platform: "ios",
            deviceName: "iPhone — Check"
        )
        let encoder = JSONEncoder()
        // Sort keys for deterministic comparison — encoding order
        // isn't guaranteed otherwise and the assertion would flake.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            check(false, "encoding DeviceRegisterPayload threw", into: &failures)
            return
        }
        // Spot-check the wire keys rather than the whole string — any
        // future change to the struct that adds optional fields shouldn't
        // flake this case.
        check(
            json.contains("\"apns_token\":\"abcd1234\""),
            "expected snake_case `apns_token` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"device_name\":\"iPhone — Check\""),
            "expected snake_case `device_name` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"platform\":\"ios\""),
            "expected `platform` in payload, got: \(json)",
            into: &failures
        )
    }

    /// `UNAuthorizationStatus` cases match the values
    /// `NotificationManager` switches on for SettingsView copy. If
    /// Apple ever renames a case (they've added `.ephemeral` and
    /// `.provisional` in past iOS releases), the SettingsView switch
    /// would silently fall through to a default branch. This check
    /// just pins the four statuses we care about so the tickle is
    /// visible in CI / dev builds.
    private static func checkAuthorizationStatusValuesAreStable(into failures: inout [String]) {
        // Use the raw values to assert the enum cases still resolve.
        // Any rename or removal in a future SDK trips a compile error
        // here — which is the goal.
        let cases: [UNAuthorizationStatus] = [
            .notDetermined,
            .denied,
            .authorized,
            .provisional,
        ]
        check(
            cases.count == 4,
            "expected exactly 4 referenced authorization statuses, got \(cases.count)",
            into: &failures
        )
    }

    // MARK: - Helpers

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        into failures: inout [String]
    ) {
        if !condition() {
            let msg = message()
            failures.append(msg)
            assertionFailure(msg)
        }
    }
}

#endif
