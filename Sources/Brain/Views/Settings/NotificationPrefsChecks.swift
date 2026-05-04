// NotificationPrefsChecks.swift
// brain-ios
//
// Source-level verification for the M42 notification-preferences DTOs
// and `TimePickerRow` time/string conversion. brain-ios has no test
// runner today (see CLAUDE.md — "Source-level verification only"); this
// file follows the same pattern as `NotificationChecks.swift` (M41) and
// `EditDialogChecks.swift` (M40):
//
//   1. `BrainDebugNotificationPrefsChecks.runAll()` returns the list of
//      failures (empty list = green). Hookable from a future debug menu
//      or a one-shot CI step.
//
//   2. Each failed check fires `assertionFailure(...)` so debug builds
//      halt in the debugger when a regression lands.
//
// Coverage is deliberately narrow: we test our own glue (snake_case
// CodingKeys round-trip, sparse PUT bodies, "HH:MM" <-> Date conversion)
// but NOT framework behaviour (Foundation's `JSONEncoder`, SwiftUI's
// `Binding`, `Calendar.current.date(from:)`).

#if DEBUG

import Foundation

/// Bundle of debug-only verification cases for the M42 notification
/// preferences plumbing. Production binaries strip the entire enum.
enum BrainDebugNotificationPrefsChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds
    /// halt in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        checkPreferencesRoundTrip(into: &failures)
        checkUpdateAllNilEncodesEmptyObject(into: &failures)
        checkUpdateSubsetEncodesOnlySetFields(into: &failures)
        checkTimePickerRowConversion(into: &failures)

        return failures
    }

    // MARK: - Cases

    /// Encode → decode round-trip on `NotificationPreferences`. Catches
    /// the case where an `enum CodingKeys` rename silently breaks the
    /// wire shape against the server's `NotificationPreferences` schema.
    /// Spot-checks the snake_case wire keys are present on encode (the
    /// in-memory struct uses camelCase, so a missing CodingKey would
    /// silently emit camelCase keys the server doesn't recognise).
    private static func checkPreferencesRoundTrip(into failures: inout [String]) {
        let original = NotificationPreferences(
            morningBriefingEnabled: true,
            morningBriefingTime: "07:30",
            dueRemindersEnabled: true,
            dueTodayEnabled: false,
            timezone: "Europe/London"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(original),
              let json = String(data: data, encoding: .utf8) else {
            check(false, "encoding NotificationPreferences threw", into: &failures)
            return
        }

        // Snake_case wire keys must appear on encode. The server's
        // schema uses these exact names (M42 contract).
        check(
            json.contains("\"morning_briefing_enabled\":true"),
            "expected snake_case `morning_briefing_enabled` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"morning_briefing_time\":\"07:30\""),
            "expected snake_case `morning_briefing_time` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"due_reminders_enabled\":true"),
            "expected snake_case `due_reminders_enabled` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"due_today_enabled\":false"),
            "expected snake_case `due_today_enabled` in payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"timezone\":\"Europe/London\""),
            "expected `timezone` in payload, got: \(json)",
            into: &failures
        )

        // Decode round-trip — proves the CodingKeys are wired both
        // directions.
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(NotificationPreferences.self, from: data) else {
            check(false, "decoding NotificationPreferences threw", into: &failures)
            return
        }
        check(
            decoded == original,
            "round-trip mismatch: \(decoded) != \(original)",
            into: &failures
        )
    }

    /// `NotificationPreferencesUpdate` with every field nil encodes to
    /// `{}` — no keys. Critical for the "send only what changed" PUT
    /// path: a future regression that swaps in `keyEncodingStrategy =
    /// .convertToSnakeCase` without setting the optional-omission
    /// flag would emit `{"morning_briefing_enabled":null,...}` and
    /// silently clobber server-side state with nulls.
    private static func checkUpdateAllNilEncodesEmptyObject(into failures: inout [String]) {
        let update = NotificationPreferencesUpdate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(update),
              let json = String(data: data, encoding: .utf8) else {
            check(false, "encoding all-nil NotificationPreferencesUpdate threw", into: &failures)
            return
        }
        check(
            json == "{}",
            "expected all-nil update to encode as {}, got: \(json)",
            into: &failures
        )
    }

    /// `NotificationPreferencesUpdate` with a subset of fields set
    /// encodes only those fields. Server treats absent keys as
    /// "leave alone", so the absence here is load-bearing — a regression
    /// that emitted nulls for unset fields would clobber unrelated
    /// state every time the user nudged one toggle.
    private static func checkUpdateSubsetEncodesOnlySetFields(into failures: inout [String]) {
        var update = NotificationPreferencesUpdate()
        update.morningBriefingEnabled = true
        update.morningBriefingTime = "06:15"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(update),
              let json = String(data: data, encoding: .utf8) else {
            check(false, "encoding subset NotificationPreferencesUpdate threw", into: &failures)
            return
        }

        check(
            json.contains("\"morning_briefing_enabled\":true"),
            "expected `morning_briefing_enabled` in subset payload, got: \(json)",
            into: &failures
        )
        check(
            json.contains("\"morning_briefing_time\":\"06:15\""),
            "expected `morning_briefing_time` in subset payload, got: \(json)",
            into: &failures
        )
        check(
            !json.contains("due_reminders_enabled"),
            "subset payload must not include unset `due_reminders_enabled`, got: \(json)",
            into: &failures
        )
        check(
            !json.contains("due_today_enabled"),
            "subset payload must not include unset `due_today_enabled`, got: \(json)",
            into: &failures
        )
        check(
            !json.contains("timezone"),
            "subset payload must not include unset `timezone`, got: \(json)",
            into: &failures
        )
    }

    /// `TimePickerRow.date(from:)` and `TimePickerRow.string(from:)`
    /// round-trip a `"HH:MM"` value through a `Date`. Specifically:
    ///
    /// - `"08:30"` parses to a `Date` whose hour/minute components are
    ///   8 and 30 in the current calendar.
    /// - Formatting that `Date` back returns the original `"08:30"`.
    /// - Single-digit values are zero-padded on the way out (`"9:5"`
    ///   → parsed as 9:05 → formatted as `"09:05"`).
    private static func checkTimePickerRowConversion(into failures: inout [String]) {
        let date = TimePickerRow.date(from: "08:30")
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        check(
            comps.hour == 8 && comps.minute == 30,
            "expected 08:30 → hour=8, minute=30; got hour=\(comps.hour ?? -1), minute=\(comps.minute ?? -1)",
            into: &failures
        )

        let formatted = TimePickerRow.string(from: date)
        check(
            formatted == "08:30",
            "expected round-trip 08:30, got \(formatted)",
            into: &failures
        )

        // Zero-padding on the way out: parser tolerates `"9:5"`, and
        // we always emit two-digit fields so the server-side parser
        // doesn't have to special-case them.
        let lazyDate = TimePickerRow.date(from: "9:5")
        let lazyFormatted = TimePickerRow.string(from: lazyDate)
        check(
            lazyFormatted == "09:05",
            "expected `9:5` → `09:05`, got \(lazyFormatted)",
            into: &failures
        )

        // Garbage in: parser falls back to midnight rather than
        // crashing. The server's row default is "08:00" so this only
        // kicks in if a future DTO drift slips bad data into local
        // state.
        let garbageDate = TimePickerRow.date(from: "garbage")
        let garbageFormatted = TimePickerRow.string(from: garbageDate)
        check(
            garbageFormatted == "00:00",
            "expected garbage input → midnight fallback, got \(garbageFormatted)",
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
