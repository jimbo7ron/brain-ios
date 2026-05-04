// IntentChecks.swift
// brain-ios
//
// M43 — debug-only sanity checks for the App Intent surface. The
// brain-ios target has no test runner yet (per the milestone spec),
// so we surface regressions through `precondition` crashes invoked
// from a future debug hook or a `#Preview` that calls `runChecks`.
// The pattern matches `ServerDateChecks` / `EditDialogChecks` /
// `BrainDebugMutationQueue` already in the codebase.
//
// We only check the pure, side-effect-free helpers — the spoken
// summary format and the parsed-result → confirmation dialog. The
// network paths and SwiftData reads aren't checked here because
// they need a live container; that's CI/manual-testing territory.

#if DEBUG

import Foundation

enum IntentChecks {

    /// Smoke-check the spoken summary across the four meaningful
    /// branches: both empty, overdue-only, due-today-only, both
    /// non-empty. We exercise the formatter through dummy
    /// `LocalNote`s that we construct ourselves; the function
    /// signature is `[LocalNote]` but only `title` / `content` are
    /// read for the "Top:" trailer, so the values we set are
    /// what matter.
    @MainActor
    static func assertWhatsDueSummaryShape() {
        let empty = WhatsDueIntent.formatSummary(overdue: [], dueToday: [])
        precondition(empty.contains("caught up"), "empty summary should be reassuring; got \(empty)")

        // Construct lightweight stand-ins. We don't insert them into
        // a context — the formatter only reads `title` / `content`.
        let overdueOne = LocalNote(
            id: "00000000-0000-0000-0000-000000000001",
            shortId: "abc",
            title: "Pay tax",
            content: "Pay tax",
            type: "todo"
        )
        let overdueTwo = LocalNote(
            id: "00000000-0000-0000-0000-000000000002",
            shortId: "def",
            title: nil,
            content: "Renew passport",
            type: "todo"
        )
        let todayOne = LocalNote(
            id: "00000000-0000-0000-0000-000000000003",
            shortId: "ghi",
            title: "Stand-up",
            content: "Stand-up",
            type: "todo"
        )

        let overdueOnly = WhatsDueIntent.formatSummary(
            overdue: [overdueOne, overdueTwo],
            dueToday: []
        )
        precondition(overdueOnly.contains("2 overdue"),
                     "overdue plural label missing; got \(overdueOnly)")
        precondition(overdueOnly.contains("Pay tax"),
                     "top item title missing from summary; got \(overdueOnly)")
        precondition(overdueOnly.contains("Renew passport"),
                     "second item title missing from summary; got \(overdueOnly)")

        let todayOnly = WhatsDueIntent.formatSummary(
            overdue: [],
            dueToday: [todayOne]
        )
        precondition(todayOnly.contains("1 item due today"),
                     "due-today singular label missing; got \(todayOnly)")
        precondition(todayOnly.contains("Stand-up"),
                     "top due-today title missing; got \(todayOnly)")

        let both = WhatsDueIntent.formatSummary(
            overdue: [overdueOne],
            dueToday: [todayOne]
        )
        precondition(both.contains("1 overdue"),
                     "overdue singular label missing; got \(both)")
        precondition(both.contains("1 item due today"),
                     "today label missing in combined summary; got \(both)")
    }

    /// Smoke-check the AddTodo confirmation dialog rendering. Confirms
    /// that the parsed title takes precedence and the due-date is
    /// folded into the spoken response when present.
    static func assertAddTodoDialogShape() {
        let parsedNoDate = QuickAddParser.parse("Buy bread")
        let withoutDate = AddTodoIntent.successDialog(
            for: parsedNoDate,
            fallbackTitle: "Buy bread"
        )
        precondition(withoutDate.contains("Buy bread"),
                     "parsed title missing from confirmation; got \(withoutDate)")
        precondition(!withoutDate.contains(" due "),
                     "no-date confirmation shouldn't say 'due'; got \(withoutDate)")

        let parsedWithDate = QuickAddParser.parse("Buy bread tomorrow")
        let withDate = AddTodoIntent.successDialog(
            for: parsedWithDate,
            fallbackTitle: "Buy bread tomorrow"
        )
        precondition(withDate.contains("Buy bread"),
                     "parsed title missing from dated confirmation; got \(withDate)")
        precondition(withDate.contains("due "),
                     "dated confirmation should include due date; got \(withDate)")
    }

    /// Run every check. Convenience entrypoint for a future debug
    /// menu / CI smoke step. Mirrors `BrainDebugMutationQueue.runAll`
    /// in `MutationQueue.swift`.
    @MainActor
    static func runChecks() {
        assertWhatsDueSummaryShape()
        assertAddTodoDialogShape()
    }
}

#endif
