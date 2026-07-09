// QuickAddDueDateTests.swift
// brain-ios — BrainTests
//
// Covers `QuickAddParser.resolveDueDateISO`, the helper the edit screen
// uses to resolve a typed natural-language due date to `yyyy-MM-dd` before
// it reaches the server. Regression: the edit screen used to send the raw
// string, so "This Monday" went to the server verbatim and 400'd
// ("Could not parse due_date"). Also guards the new "this <weekday>"
// phrase, which mirrors the server's parse_date_string.

import XCTest
@testable import brain

final class QuickAddDueDateTests: XCTestCase {

    /// Deterministic calendar pinned to UTC so weekday maths doesn't
    /// depend on the CI machine's timezone.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return calendar.date(from: c)!
    }

    /// 2026-07-09 is a Thursday. "this <weekday>" = the upcoming
    /// occurrence (if today IS that weekday it rolls to next week),
    /// identical to a bare weekday.
    func testResolvesThisWeekday() {
        let now = date(2026, 7, 9) // Thursday
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("This Monday", now: now, calendar: calendar), "2026-07-13")
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("this mon", now: now, calendar: calendar), "2026-07-13")
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("this friday", now: now, calendar: calendar), "2026-07-10")
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("this thursday", now: now, calendar: calendar), "2026-07-16")
    }

    func testResolvesCommonPhrases() {
        let now = date(2026, 7, 9)
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("today", now: now, calendar: calendar), "2026-07-09")
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("tomorrow", now: now, calendar: calendar), "2026-07-10")
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("next monday", now: now, calendar: calendar), "2026-07-20")
    }

    /// An already-ISO date round-trips unchanged; empty / unparseable
    /// input returns nil so the caller can fall back to the raw string.
    func testIsoRoundTripsAndUnparseableIsNil() {
        let now = date(2026, 7, 9)
        XCTAssertEqual(QuickAddParser.resolveDueDateISO("2026-05-12", now: now, calendar: calendar), "2026-05-12")
        XCTAssertNil(QuickAddParser.resolveDueDateISO("", now: now, calendar: calendar))
        XCTAssertNil(QuickAddParser.resolveDueDateISO("   ", now: now, calendar: calendar))
        XCTAssertNil(QuickAddParser.resolveDueDateISO("not a date", now: now, calendar: calendar))
    }
}
