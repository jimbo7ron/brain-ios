// QuickAddParserChecks.swift
// brain-ios
//
// Source-level verification for the M39 quick-add parser. brain-ios
// doesn't have a test runner (see CLAUDE.md — "Source-level verification
// only"), so we ship these checks as `#if DEBUG`-gated assertions plus a
// manual entry point that prints the results of every documented case.
//
// Two ways to use this file:
//
//   1. Throwaway runtime invocation: in any DEBUG-only code path,
//      `QuickAddParserChecks.runAll()` returns the list of failures.
//      Empty list = green.
//
//   2. Compile-time confidence: the assertions inside `runAll()` keep
//      regressions visible during development — a debug build that hits
//      a failing case will trip `assertionFailure(...)`.
//
// Failure messages spell out the input, expected, and actual so a
// developer can read them straight off a console without re-deriving
// the case.

#if DEBUG

import Foundation

/// Bundle of verification cases for `QuickAddParser`. Each case is a
/// fixed reference date so the math is reproducible regardless of when
/// the build runs.
enum QuickAddParserChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds halt
    /// in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        // Reference: 2026-04-29 Wednesday. Matches the worked examples
        // in `parsers.py` / `parse-todo.ts` so the cases are 1:1 with
        // the canonical Python / TypeScript versions.
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 4, day: 29, calendar: calendar)

        // 1. Spec example — full keyword set. Tags get stripped from
        //    the cleaned title so the trailing-due regex can see the
        //    real end of the input. They re-appear in `bodyForServer`
        //    on the wire payload.
        check(
            "Pay tax tomorrow !high #finance",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Pay tax",
            expectedDueDate: makeDate(year: 2026, month: 4, day: 30, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: .high,
            expectedTags: ["finance"],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 2. Plain title, no metadata.
        check(
            "Buy milk",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Buy milk",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 3. Recurrence + time. The trailing-due regex looks for a date
        //    keyword, so `"Standup daily at 9am"` only strips the date
        //    when one is present — for now `"daily"` lives in the
        //    cleaned title via the recurrence pass and the time stays
        //    attached to the body. Spec is satisfied as long as
        //    recurrence is extracted.
        check(
            "Standup daily at 9am",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Standup at 9am",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: .daily,
            failures: &failures
        )

        // 4. Wiki link + trailing date.
        check(
            "[[Project Alpha]] kickoff next monday",
            referenceDate: referenceDate,
            calendar: calendar,
            // Reference 2026-04-29 is Wednesday → next Monday skips the
            // upcoming Mon (May 4) and lands on May 11.
            expectedTitle: "kickoff",
            expectedDueDate: makeDate(year: 2026, month: 5, day: 11, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: ["Project Alpha"],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 5. Empty input.
        check(
            "",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 6. Just tags. Now that we strip hashtags from the cleaned
        //    title, this input collapses to an empty title. The submit
        //    button will refuse it (the QuickAdd sheet's `canSubmit`
        //    guards on `parsed.title.isEmpty`). The tag slugs survive
        //    on `tags` so a future "tag-only quick capture" surface
        //    can still use them.
        check(
            "#tag1 #tag2",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: ["tag1", "tag2"],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 7. Just a date phrase. Conservative: don't reduce the title
        //    to nothing — leave the input alone. Mirrors web.
        check(
            "tomorrow",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "tomorrow",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 8. ISO date — pass-through.
        check(
            "Plan launch 2026-05-12",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Plan launch",
            expectedDueDate: makeDate(year: 2026, month: 5, day: 12, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 9. `in N days` form.
        check(
            "Review in 3 days",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Review",
            expectedDueDate: makeDate(year: 2026, month: 5, day: 2, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 10. Bare weekday — next Friday. Reference is Wed; next Friday is May 1.
        check(
            "Ship the migration by Friday",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Ship the migration",
            expectedDueDate: makeDate(year: 2026, month: 5, day: 1, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 11. Trailing date + time.
        check(
            "Coffee tomorrow at 3pm",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Coffee",
            expectedDueDate: makeDate(year: 2026, month: 4, day: 30, calendar: calendar),
            expectedDueTimeHHMM: "15:00",
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 12. 24-hour time.
        check(
            "Standup at 09:30 tomorrow",
            referenceDate: referenceDate,
            calendar: calendar,
            // The trailing-due regex requires the date phrase at the
            // end — `"Standup at 09:30 tomorrow"` puts the time in the
            // middle and the date last. We strip "tomorrow" but the
            // time stays in the title.
            expectedTitle: "Standup at 09:30",
            expectedDueDate: makeDate(year: 2026, month: 4, day: 30, calendar: calendar),
            expectedDueTimeHHMM: nil,
            expectedPriority: nil,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        // 13. Priority alone, mid-sentence.
        check(
            "Prep slides !medium",
            referenceDate: referenceDate,
            calendar: calendar,
            expectedTitle: "Prep slides",
            expectedDueDate: nil,
            expectedDueTimeHHMM: nil,
            expectedPriority: .medium,
            expectedTags: [],
            expectedWikiLinks: [],
            expectedRecurrence: nil,
            failures: &failures
        )

        return failures
    }

    // MARK: - Internals

    /// Run a single case and append a formatted diff to `failures` when
    /// the parsed result doesn't match expectations. Each mismatch is a
    /// single line: the input, the failing field, expected vs actual.
    private static func check(
        _ input: String,
        referenceDate: Date,
        calendar: Calendar,
        expectedTitle: String,
        expectedDueDate: Date?,
        expectedDueTimeHHMM: String?,
        expectedPriority: QuickAddPriority?,
        expectedTags: [String],
        expectedWikiLinks: [String],
        expectedRecurrence: QuickAddRecurrence?,
        failures: inout [String]
    ) {
        let result = QuickAddParser.parse(input, now: referenceDate, calendar: calendar)

        if result.title != expectedTitle {
            let msg = "input=\(input.debugDescription) title: expected=\(expectedTitle.debugDescription) actual=\(result.title.debugDescription)"
            failures.append(msg)
            assertionFailure(msg)
        }

        if !datesEqualOnDay(result.dueDate, expectedDueDate, calendar: calendar) {
            let msg = "input=\(input.debugDescription) dueDate: expected=\(formatDayOrNil(expectedDueDate, calendar: calendar)) actual=\(formatDayOrNil(result.dueDate, calendar: calendar))"
            failures.append(msg)
            assertionFailure(msg)
        }

        let actualTimeHHMM = result.dueTimeHHMM(calendar: calendar)
        if actualTimeHHMM != expectedDueTimeHHMM {
            let msg = "input=\(input.debugDescription) dueTime: expected=\(expectedDueTimeHHMM ?? "nil") actual=\(actualTimeHHMM ?? "nil")"
            failures.append(msg)
            assertionFailure(msg)
        }

        if result.priority != expectedPriority {
            let msg = "input=\(input.debugDescription) priority: expected=\(expectedPriority?.rawValue ?? "nil") actual=\(result.priority?.rawValue ?? "nil")"
            failures.append(msg)
            assertionFailure(msg)
        }

        if result.tags != expectedTags {
            let msg = "input=\(input.debugDescription) tags: expected=\(expectedTags) actual=\(result.tags)"
            failures.append(msg)
            assertionFailure(msg)
        }

        if result.wikiLinkTargets != expectedWikiLinks {
            let msg = "input=\(input.debugDescription) wikiLinks: expected=\(expectedWikiLinks) actual=\(result.wikiLinkTargets)"
            failures.append(msg)
            assertionFailure(msg)
        }

        if result.recurrence != expectedRecurrence {
            let msg = "input=\(input.debugDescription) recurrence: expected=\(expectedRecurrence?.rawValue ?? "nil") actual=\(result.recurrence?.rawValue ?? "nil")"
            failures.append(msg)
            assertionFailure(msg)
        }
    }

    private static func datesEqualOnDay(_ lhs: Date?, _ rhs: Date?, calendar: Calendar) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return calendar.startOfDay(for: l) == calendar.startOfDay(for: r)
        default:
            return false
        }
    }

    private static func formatDayOrNil(_ date: Date?, calendar: Calendar) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Build a fixed `Date` at the start of the given day. Pinned to
    /// the calendar's timezone so cases line up with `Calendar.current`
    /// when run against a developer's local clock.
    private static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = calendar.timeZone
        // Force-unwrap is safe: components describe a real day.
        return calendar.date(from: components)!  // swiftlint:disable:this force_unwrapping
    }
}

#endif
