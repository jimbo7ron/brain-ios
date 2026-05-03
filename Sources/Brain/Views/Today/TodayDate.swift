// TodayDate.swift
// brain-ios
//
// Date helpers for the M34 Today view. Mirrors web/src/app/page.tsx —
// "today" is the user's local calendar day (NOT UTC), and the ISO
// strings the server stores in `due_date` use the same local-day
// convention. Centralising the math here keeps the Today view's
// predicates and grouping logic from re-deriving it.

import Foundation

/// "Local ISO" date: `yyyy-MM-dd` in the user's current calendar.
/// Mirrors `localISO()` in `web/src/app/page.tsx` so iOS and web
/// agree on which todos count as "today" near midnight.
///
/// Note: we deliberately don't use `ISO8601DateFormatter`. That
/// formatter assumes UTC and would treat a 23:59 local time on
/// 2026-05-03 (in a UTC+offset timezone) as 2026-05-04 — which
/// disagrees with the web's `Date` math.
enum TodayDate {

    /// Number of days the "Coming up" section spans. Matches
    /// `COMING_UP_DAYS` in the web Today page.
    static let comingUpDays: Int = 6

    /// Returns the user's local "today" as `yyyy-MM-dd`. Computed
    /// each call so a long-running app session crossing midnight
    /// updates the section assignments on the next render.
    static func todayISO(now: Date = .now, calendar: Calendar = .current) -> String {
        formatter(calendar: calendar).string(from: calendar.startOfDay(for: now))
    }

    /// Returns the local ISO date `daysFromToday` days from `now`.
    /// Used to compute the "Coming up" horizon (today + 6).
    static func isoDate(
        offsetByDays daysFromToday: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let start = calendar.startOfDay(for: now)
        // `byAdding(.day, ...)` returns nil only on calendars where
        // the resulting date can't be represented (e.g. far-future
        // overflow). Falling back to `start` preserves a sensible
        // string instead of crashing — the section will just be
        // empty.
        let target = calendar.date(byAdding: .day, value: daysFromToday, to: start) ?? start
        return formatter(calendar: calendar).string(from: target)
    }

    /// Parse a `yyyy-MM-dd` string back into a local-noon `Date`,
    /// for relative-day labels in the "Coming up" group headers.
    /// Returns nil if the string isn't an ISO date — caller falls
    /// back to displaying the raw string.
    ///
    /// Noon (12:00) is intentional: it's far from the DST transition
    /// edges, so `.day` arithmetic against `Date.now`'s start-of-day
    /// stays stable across spring-forward / fall-back days.
    static func date(fromISO iso: String, calendar: Calendar = .current) -> Date? {
        let parser = parser(calendar: calendar)
        return parser.date(from: iso)
    }

    /// Relative day label for the "Coming up" group headers, mirroring
    /// `dayLabel()` in the web Today page:
    ///   * tomorrow → "Tomorrow"
    ///   * any other day in the next 7 → weekday + month/day
    ///     (e.g. "Mon, May 5")
    ///   * unparseable → the raw ISO string (defensive)
    static func relativeDayLabel(
        forISO iso: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard let date = date(fromISO: iso, calendar: calendar) else { return iso }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfToday = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.day], from: startOfToday, to: startOfDate)
        if components.day == 1 { return "Tomorrow" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date)
    }

    /// `yyyy-MM-dd` formatter, en_US_POSIX so it stays stable
    /// regardless of the device locale (Arabic numerals, Gregorian
    /// calendar). Calendar is parameterised so tests can pin it.
    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func parser(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
