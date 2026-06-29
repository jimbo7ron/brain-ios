// ServerDate.swift
// brain-ios
//
// Parser for the brain server's wire-format `datetime` strings.
//
// Server emits naive `yyyy-MM-dd'T'HH:mm:ss[.SSSSSS][Z]` timestamps
// that represent wall-clock/local time (the value the user entered,
// e.g. a 09:30 appointment arrives as `2026-06-29T09:30:00`). We parse
// them in `TimeZone.current` and display in `TimeZone.current`, so the
// wall-clock value round-trips unchanged. Parsing as UTC instead shifted
// every appointment by the device's UTC offset (e.g. +10h in Sydney).
// Examples seen on the wire:
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
    /// fragment as local clock time. Returns `nil` for inputs that
    /// don't match (callers fall back to displaying the raw string
    /// or hiding the row).
    static func parse(_ raw: String) -> Date? {
        // Drop the optional `Z` first; some codepaths emit it, some
        // don't. The clock value is wall-clock/local either way, so a
        // trailing `Z` here is noise rather than a real UTC designator.
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

    /// Fixed-format parser, pinned to `TimeZone.current` + `en_US_POSIX`
    /// + Gregorian. The wire value is wall-clock/local, so parsing in the
    /// device's current zone makes the resulting `Date` the correct
    /// instant and lets the local-zone display formatter render it
    /// unchanged. `en_US_POSIX` + Gregorian are Apple's recommended
    /// invariants so the formatter doesn't break on devices set to
    /// non-Gregorian calendars (Buddhist, Persian, Japanese imperial, etc.).
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current
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
