// ServerDate.swift
// brain-ios
//
// Parser for the brain server's wire-format `datetime` strings.
//
// Server emits naive `yyyy-MM-dd'T'HH:mm:ss[.SSSSSS][Z]` timestamps;
// production server is pinned to UTC (per roadmap M28), so we parse
// them in UTC and display in `TimeZone.current`. Examples seen on the
// wire:
//   * `2026-05-03T10:00:00`           — clean second precision, no TZ
//   * `2026-05-03T10:00:00.123456`    — fractional microseconds, no TZ
//   * `2026-05-03T10:00:00Z`          — clean second precision with Z
//   * `2026-05-03T10:00:00.123Z`      — fractional + Z
//
// We deliberately avoid `ISO8601DateFormatter`. Even with
// `.withFractionalSeconds` it is strict about the TZ designator and
// rejects naive timestamps — the previous M34 review-fix used it and
// the appointments section went permanently empty in production.

import Foundation

enum ServerDate {

    /// Parse a server-emitted `datetime` string.
    ///
    /// Strips an optional trailing `Z` and any fractional-seconds
    /// component, then parses the remaining `yyyy-MM-dd'T'HH:mm:ss`
    /// fragment as UTC clock time. Returns `nil` for inputs that
    /// don't match (callers fall back to displaying the raw string
    /// or hiding the row).
    static func parse(_ raw: String) -> Date? {
        // Drop the optional `Z` first; some codepaths emit it, some
        // don't — production server is UTC-pinned either way.
        let trimmed = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
        // Drop the fractional-seconds component if present. Apple's
        // fixed-format `DateFormatter` can't represent a six-digit
        // fraction without bespoke `.SSSSSS` handling, and the time
        // we render is to-the-minute anyway.
        let withoutFraction: String
        if let dotIndex = trimmed.firstIndex(of: ".") {
            withoutFraction = String(trimmed[..<dotIndex])
        } else {
            withoutFraction = trimmed
        }
        return Self.formatter.date(from: withoutFraction)
    }

    /// Fixed-format parser, pinned to UTC + `en_US_POSIX` + Gregorian
    /// — Apple's recommended invariants for parsing fixed-format
    /// ISO-like strings. Without these the formatter breaks on
    /// devices set to non-Gregorian calendars (Buddhist, Persian,
    /// Japanese imperial, etc.).
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
}

#if DEBUG
// Parser sanity checks — there's no XCTest target yet, so we surface
// regressions in dev builds via `precondition` crashes when this is
// invoked from a SwiftUI preview or temporary debug hook.
enum ServerDateChecks {
    static func runChecks() {
        precondition(ServerDate.parse("2026-05-03T10:00:00") != nil, "no fraction, no Z")
        precondition(ServerDate.parse("2026-05-03T10:00:00.123456") != nil, "fraction, no Z")
        precondition(ServerDate.parse("2026-05-03T10:00:00Z") != nil, "no fraction, Z")
        precondition(ServerDate.parse("2026-05-03T10:00:00.123Z") != nil, "fraction, Z")
        precondition(ServerDate.parse("not a date") == nil, "rejects garbage")
    }
}
#endif
