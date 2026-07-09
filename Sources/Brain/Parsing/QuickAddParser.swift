// QuickAddParser.swift
// brain-ios
//
// Trailing-keyword NLP for quick-capture todo entry (M39). Swift port of
// the web's `web/src/lib/parse-todo.ts` plus the richer keyword set the
// spec asks for: priorities (`!high|!medium|!low`), hashtags (`#tag`),
// wiki-links (`[[Title]]`), recurrence words (`daily|weekly|monthly|
// weekdays`), and trailing date / time phrases (`tomorrow`, `next mon
// at 9am`, `2026-05-12`, etc.).
//
// Why a fresh implementation rather than calling the server: the user
// wants live preview chips as they type — that has to run in-process.
// The server's parser (`brain/src/brain/parsers.py`) is canonical for
// stored representation; we pass parsed `due_date` strings back through
// the server on submit, where it canonicalises them again. So a small
// parser drift here is not a correctness issue — the worst case is the
// preview chip doesn't show but the server still accepts the raw text.
//
// Conservative: every extraction step strips a *trailing* phrase
// from the title only when the rest of the title is non-empty.
// Single-word inputs like `"tomorrow"` stay as title text — same
// rule the web uses.

import Foundation

/// Result of parsing a free-form quick-capture string.
struct QuickAddResult: Equatable {
    /// Cleaned title with all keywords stripped. Empty when the user
    /// has typed nothing meaningful (e.g. just a date phrase).
    let title: String
    /// Calendar-day component of the parsed due date, in the user's
    /// local timezone. `nil` when no date phrase was matched.
    let dueDate: Date?
    /// Wall-clock time component when the user typed something like
    /// `"at 9am"`. Stored as a `Date` whose date components are pinned
    /// to a reference day; only the hour/minute matter on submit.
    let dueTime: Date?
    let priority: QuickAddPriority?
    /// Tags found in the input (with their `#`-prefix stripped, lowercase).
    /// Mirrors the server's `extract_hashtags` convention.
    let tags: [String]
    /// Wiki-link targets `[[X]]` extracted from the input. The server
    /// stores these as pending links.
    let wikiLinkTargets: [String]
    let recurrence: QuickAddRecurrence?
}

enum QuickAddPriority: String, CaseIterable, Equatable {
    case low
    case medium
    case high
}

enum QuickAddRecurrence: String, CaseIterable, Equatable {
    case daily
    case weekly
    case monthly
    case weekdays
}

enum QuickAddParser {

    /// Parse free-form quick-add text into a `QuickAddResult`. Always
    /// returns a result — fields are `nil` / empty when no match is
    /// found. `now` is injectable so previews and unit checks can pin
    /// "today" without faking the system clock.
    static func parse(
        _ raw: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> QuickAddResult {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Wiki-links — extract and REMOVE from the working title.
        //    The web does this so the rendered title doesn't include
        //    the `[[…]]` brackets. We collect targets in document
        //    order, deduplicated, preserving casing for display.
        let (afterWiki, wikiLinks) = extractWikiLinks(working)
        working = afterWiki

        // 2) Hashtags — extract AND strip from the working title so
        //    the trailing-date pass below can match the *real* end of
        //    the title (otherwise an input like
        //    `"Pay tax tomorrow #finance"` would never strip the
        //    `tomorrow`). The spec confirms the cleaned title shouldn't
        //    contain the hashtag (`title="Pay tax"`). We re-append the
        //    tags as `#tag` on the server payload via
        //    `bodyForServer()` so the server's hashtag extractor still
        //    sees them.
        let (afterTags, tags) = extractAndStripHashtags(working)
        working = afterTags

        // 3) Priority bang — `!high` / `!medium` / `!low` anywhere,
        //    case-insensitive. First match wins; the slice is removed
        //    from the working title so the bang doesn't survive into
        //    the body.
        let (afterPriority, priority) = extractPriority(working)
        working = afterPriority

        // 4) Recurrence keyword — `daily|weekly|monthly|weekdays` as a
        //    standalone whole-word, case-insensitive. We strip the
        //    matched word from the working title so the body doesn't
        //    repeat it.
        let (afterRecurrence, recurrence) = extractRecurrence(working)
        working = afterRecurrence

        // 5) Trailing date + optional time phrase. Returns the cleaned
        //    title with the phrase stripped, plus the resolved date /
        //    time. Conservative: leaves the title alone when stripping
        //    would empty it (single-word "tomorrow" case).
        let (afterDue, dueDate, dueTime) = extractTrailingDue(
            working,
            now: now,
            calendar: calendar
        )
        working = afterDue

        // Final tidy: collapse runs of whitespace left behind by the
        // earlier strips, trim, and we're done.
        let cleaned = collapseWhitespace(working)

        return QuickAddResult(
            title: cleaned,
            dueDate: dueDate,
            dueTime: dueTime,
            priority: priority,
            tags: tags,
            wikiLinkTargets: wikiLinks,
            recurrence: recurrence
        )
    }

    // MARK: - Wiki links

    /// `[[Target Page]]` — extracts the targets and removes the bracketed
    /// span from `text`. We preserve original casing on the way out
    /// because wiki-link resolution is case-sensitive on the server side
    /// (the link target is matched against `Note.title`).
    private static func extractWikiLinks(_ text: String) -> (cleaned: String, targets: [String]) {
        // Manual scan rather than `Regex` so we can rebuild the cleaned
        // string in one pass without recomputing offsets after each
        // strip.
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        var targets: [String] = []
        var seen = Set<String>()
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("[[") {
                let afterOpen = text.index(index, offsetBy: 2)
                if let closeRange = text.range(of: "]]", range: afterOpen..<text.endIndex) {
                    let inner = String(text[afterOpen..<closeRange.lowerBound])
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !seen.contains(trimmed) {
                        targets.append(trimmed)
                        seen.insert(trimmed)
                    }
                    index = closeRange.upperBound
                    continue
                }
            }
            cleaned.append(text[index])
            index = text.index(after: index)
        }
        return (cleaned, targets)
    }

    // MARK: - Hashtags

    /// `#tag` — letters / digits / hyphens / underscores. Matches the
    /// server's `HASHTAG_PATTERN` exactly. Returns the working text
    /// with every `#tag` stripped, plus the lowercased-deduped slug
    /// list (without the `#`).
    ///
    /// We build the regex via `NSRegularExpression` (rather than a
    /// `/#.../` literal) because Swift's regex-literal parser treats a
    /// leading `#` as a pound-literal token — `let pattern = /#.../`
    /// fails to compile. The string-init form sidesteps that gotcha
    /// and the pattern is small enough that the readability hit is
    /// negligible.
    private static func extractAndStripHashtags(_ text: String) -> (cleaned: String, tags: [String]) {
        guard let regex = try? NSRegularExpression(pattern: "#([A-Za-z0-9_\\-]+)") else {
            return (text, [])
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var ordered: [String] = []
        // Walk matches in reverse so removing slices doesn't shift the
        // indices of the matches we haven't visited yet.
        let matches = regex.matches(in: text, options: [], range: nsRange)
        var working = text
        for match in matches.reversed() {
            guard
                match.numberOfRanges >= 2,
                let fullRange = Range(match.range, in: working),
                let captured = Range(match.range(at: 1), in: working)
            else { continue }
            let slug = String(working[captured]).lowercased()
            if !seen.contains(slug) {
                seen.insert(slug)
                ordered.append(slug)
            }
            working.removeSubrange(fullRange)
        }
        // Reverse the ordered list so the first hashtag in the
        // original input is first in the returned array. (Matches
        // would otherwise come out in last-to-first order.)
        return (working, Array(ordered.reversed()))
    }

    // MARK: - Priority

    /// `!high` / `!medium` / `!low` — case-insensitive, word-bounded on
    /// the right so `!highly` doesn't trigger. We strip the matched span
    /// out of the working title.
    ///
    /// Note the `#/.../#` extended literal: a regex starting with `!` is
    /// otherwise parsed as a logical-not expression. The extended form
    /// disambiguates without us reaching for an `NSRegularExpression`.
    private static func extractPriority(_ text: String) -> (cleaned: String, priority: QuickAddPriority?) {
        let pattern = #/!(?i:(high|medium|low))\b/#
        guard let match = text.firstMatch(of: pattern) else {
            return (text, nil)
        }
        let priority = QuickAddPriority(rawValue: String(match.1).lowercased())
        var working = text
        working.removeSubrange(match.range)
        return (working, priority)
    }

    // MARK: - Recurrence

    /// `daily` / `weekly` / `monthly` / `weekdays` — whole-word, case-
    /// insensitive. Matches the first occurrence and removes it from
    /// the working title.
    private static func extractRecurrence(_ text: String) -> (cleaned: String, recurrence: QuickAddRecurrence?) {
        // `\b` on each side keeps `weekdays` from also matching inside
        // `"weekdayschedule"` (paranoia — but cheap). Extended literal
        // (`#/.../#`) so the leading `\b` doesn't get confused with a
        // bare-word expression in the Swift grammar.
        let pattern = #/\b(?i:(daily|weekly|monthly|weekdays))\b/#
        guard let match = text.firstMatch(of: pattern) else {
            return (text, nil)
        }
        let recurrence = QuickAddRecurrence(rawValue: String(match.1).lowercased())
        var working = text
        working.removeSubrange(match.range)
        return (working, recurrence)
    }

    // MARK: - Trailing date + time

    /// Words that link a title to a trailing date phrase (`by`, `on`,
    /// `for`, `due`). Optional in the regex; we strip them along with
    /// the date phrase so the cleaned title doesn't end with a stray
    /// preposition.
    private static let dateKeywords =
        "today|tomorrow|tonight" +
        "|monday|tuesday|wednesday|thursday|friday|saturday|sunday" +
        "|mon|tue|wed|thu|fri|sat|sun" +
        "|next\\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)" +
        "|in\\s+\\d+\\s+(?:day|days|week|weeks)" +
        "|\\d{4}-\\d{2}-\\d{2}"

    /// Time forms we recognise after a date phrase (`at 3pm`, `at
    /// 15:00`, `at 9:30am`). The `at ` is required — bare digits at the
    /// end of a sentence are too ambiguous (could be a year, a unit,
    /// part of a tag).
    private static let timeFragment = "(?:\\s+at\\s+(\\d{1,2}(?::\\d{2})?\\s*(?:am|pm)?|\\d{1,2}:\\d{2}))"

    /// Scan `text` for a trailing date (and optional time) phrase.
    /// Returns the cleaned title, the resolved `Date` for the day, and
    /// a separate `Date` carrying the wall-clock time (`nil` when no
    /// time was given).
    ///
    /// Conservative: bails when the cleaned title would be empty (e.g.
    /// the user typed only `"tomorrow"`).
    private static func extractTrailingDue(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> (cleaned: String, dueDate: Date?, dueTime: Date?) {
        let stripped = text.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return (stripped, nil, nil) }

        // Build the regex via NSRegularExpression — Swift `Regex`
        // literals can't interpolate runtime strings, and the date /
        // time fragments are easier to read as joined string parts.
        // Pattern is anchored: title content (group 1), optional
        // preposition, the date token (group 2), optional time
        // fragment (group 3), optional period, end of string.
        let pattern = "^(.+?\\S)\\s+(?:by|on|for|due)?\\s*(\(dateKeywords))\(timeFragment)?\\s*\\.?$"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return (stripped, nil, nil)
        }
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        guard let match = regex.firstMatch(in: stripped, options: [], range: range) else {
            return (stripped, nil, nil)
        }

        guard
            let contentRange = Range(match.range(at: 1), in: stripped),
            let phraseRange = Range(match.range(at: 2), in: stripped)
        else {
            return (stripped, nil, nil)
        }

        let content = String(stripped[contentRange]).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Can happen on inputs like `"by tomorrow"` where group 1
            // captured `"by"` and got trimmed away. Leave the input
            // alone rather than dropping the user's text.
            return (stripped, nil, nil)
        }

        let phrase = String(stripped[phraseRange])
        guard let resolvedDate = resolveDatePhrase(phrase, now: now, calendar: calendar) else {
            // Phrase matched the regex but didn't resolve (very
            // unlikely given the keyword list above). Conservative:
            // leave the input alone rather than silently swallow words.
            return (stripped, nil, nil)
        }

        var dueTime: Date?
        if match.numberOfRanges >= 4,
           let timeRange = Range(match.range(at: 3), in: stripped) {
            let timePhrase = String(stripped[timeRange])
            dueTime = resolveTimePhrase(timePhrase, on: resolvedDate, calendar: calendar)
        }

        return (content, resolvedDate, dueTime)
    }

    /// Map the matched date phrase to a concrete `Date`. Mirrors the
    /// web's `resolveDuePhrase` and the server's `parse_date_string`
    /// for the keyword set we recognise.
    private static func resolveDatePhrase(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let phrase = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let startOfToday = calendar.startOfDay(for: now)

        if phrase == "today" || phrase == "tonight" {
            return startOfToday
        }
        if phrase == "tomorrow" {
            return calendar.date(byAdding: .day, value: 1, to: startOfToday)
        }
        if phrase == "next week" {
            // Monday of next week. `weekday` is 1=Sunday on Calendar's
            // default Gregorian wiring; we want Monday so subtract 2
            // and modulo. Matches `parse_date_string(... "next week"
            // ...)` in the server.
            let weekday = calendar.component(.weekday, from: startOfToday)
            // Convert Sunday=1..Saturday=7 -> Monday=0..Sunday=6.
            let mondayOffset = (weekday + 5) % 7
            // Days until next Monday: full week minus the offset to today's Monday.
            let daysUntilMonday = (7 - mondayOffset) % 7
            let delta = daysUntilMonday == 0 ? 7 : daysUntilMonday
            return calendar.date(byAdding: .day, value: delta, to: startOfToday)
        }

        // ISO date — `2026-05-12`.
        if let iso = parseISODate(phrase, calendar: calendar) {
            return iso
        }

        // `in N days` / `in N weeks`. Extended `#/.../#` literal so the
        // leading `^` isn't parsed as a Swift expression token.
        // `wholeMatch` throws on regex-engine errors that can't trigger
        // for these compile-time-known patterns; `try?` keeps the call
        // sites tidy.
        if let inMatch = try? #/^in\s+(\d+)\s+(day|days|week|weeks)$/#.wholeMatch(in: phrase) {
            let n = Int(inMatch.1) ?? 0
            let mult = String(inMatch.2).hasPrefix("week") ? 7 : 1
            return calendar.date(byAdding: .day, value: n * mult, to: startOfToday)
        }

        // `next monday` / `next mon`
        if phrase.hasPrefix("next ") {
            let rest = String(phrase.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let target = weekdayIndex(forName: rest) {
                return nextWeekdayOccurrence(after: startOfToday, target: target, skipNextWeek: true, calendar: calendar)
            }
        }

        // `this monday` / `this mon` — the upcoming occurrence, same as a
        // bare weekday (if today is that weekday it rolls to next week).
        // Mirrors the server's `parse_date_string`.
        if phrase.hasPrefix("this ") {
            let rest = String(phrase.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let target = weekdayIndex(forName: rest) {
                return nextWeekdayOccurrence(after: startOfToday, target: target, skipNextWeek: false, calendar: calendar)
            }
        }

        // Bare weekday name — next occurrence (today counts as 7 days
        // out, not 0). Matches the server.
        if let target = weekdayIndex(forName: phrase) {
            return nextWeekdayOccurrence(after: startOfToday, target: target, skipNextWeek: false, calendar: calendar)
        }

        return nil
    }

    /// Resolve a free-text due-date phrase ("today", "this monday",
    /// "2026-05-12") to a `yyyy-MM-dd` string for the wire payload, or
    /// `nil` if it can't be parsed. The edit screen uses this so a typed
    /// natural-language date is resolved client-side before it reaches the
    /// server — the create path already does this via `dueDateISO()`.
    /// An already-ISO string round-trips unchanged.
    static func resolveDueDateISO(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let date = resolveDatePhrase(trimmed, now: now, calendar: calendar) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Map a time fragment (`9am`, `15:00`, `9:30am`) to a `Date` whose
    /// date components are pinned to `day` and whose time components
    /// are the parsed hour/minute. The caller treats this as a
    /// wall-clock time and renders just the time portion.
    private static func resolveTimePhrase(_ raw: String, on day: Date, calendar: Calendar) -> Date? {
        let phrase = raw.trimmingCharacters(in: .whitespaces).lowercased()

        // 12-hour with am/pm: `9am`, `9:30pm`. Extended `#/.../#`
        // literal — leading `^` would otherwise confuse the Swift
        // grammar with an expression token. `try?` because
        // `wholeMatch` throws on engine errors that can't fire for
        // a compile-time-known pattern.
        if let match = try? #/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/#.wholeMatch(in: phrase) {
            let hour = Int(match.1) ?? 0
            let minute = match.2.map { Int($0) ?? 0 } ?? 0
            let isPM = match.3 == "pm"
            // Normalise: 12am → 0, 12pm → 12, 1-11pm → +12.
            let normalisedHour: Int
            if hour == 12 {
                normalisedHour = isPM ? 12 : 0
            } else {
                normalisedHour = isPM ? hour + 12 : hour
            }
            return calendar.date(bySettingHour: normalisedHour, minute: minute, second: 0, of: day)
        }

        // 24-hour: `15:00`, `9:30`.
        if let match = try? #/^(\d{1,2}):(\d{2})$/#.wholeMatch(in: phrase) {
            let hour = Int(match.1) ?? 0
            let minute = Int(match.2) ?? 0
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }

        // Bare hour without am/pm: `9`. Treat as 24-hour.
        if let match = try? #/^(\d{1,2})$/#.wholeMatch(in: phrase) {
            let hour = Int(match.1) ?? 0
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }

        return nil
    }

    /// `yyyy-MM-dd` parser using the same `en_US_POSIX` lock that the
    /// rest of the codebase uses (see `TodayDate`).
    private static func parseISODate(_ phrase: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: phrase)
    }

    /// Resolve a weekday name (full or short) to Calendar's
    /// Sunday=1...Saturday=7 numbering. Returns `nil` for unrecognised
    /// strings.
    private static func weekdayIndex(forName name: String) -> Int? {
        switch name {
        case "sunday", "sun":       return 1
        case "monday", "mon":       return 2
        case "tuesday", "tue":      return 3
        case "wednesday", "wed":    return 4
        case "thursday", "thu":     return 5
        case "friday", "fri":       return 6
        case "saturday", "sat":     return 7
        default: return nil
        }
    }

    /// Resolve "the next time it's `target` weekday" relative to
    /// `from`. When `skipNextWeek` is true (`"next monday"`), we
    /// always advance past the upcoming occurrence and use the one
    /// after — matching the server / web behaviour.
    private static func nextWeekdayOccurrence(
        after from: Date,
        target: Int,
        skipNextWeek: Bool,
        calendar: Calendar
    ) -> Date? {
        let current = calendar.component(.weekday, from: from)
        var delta = (target - current + 7) % 7
        if delta == 0 { delta = 7 }
        if skipNextWeek { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: from)
    }

    // MARK: - Helpers

    /// Replace runs of whitespace (left behind after stripping
    /// keywords from the middle of a string) with single spaces, then
    /// trim. Keeps the preview text tidy.
    private static func collapseWhitespace(_ text: String) -> String {
        // Extended `#/.../#` literal so a leading `/\s` doesn't trip
        // up the Swift expression parser when the regex appears in an
        // argument list.
        let collapsed = text.replacing(#/\s+/#, with: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire-format helpers

extension QuickAddResult {

    /// `yyyy-MM-dd` representation of `dueDate` for the wire payload.
    /// The brain server's `NoteCreate.due_date` accepts a flexible
    /// string — ISO is the safest shape; the server canonicalises it
    /// regardless. Returns `nil` when no date was parsed.
    func dueDateISO(calendar: Calendar = .current) -> String? {
        guard let dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: dueDate)
    }

    /// Wall-clock `HH:mm` time for the wire payload. Server's
    /// `NoteCreate.due_time` accepts `"9am"` / `"14:30"` etc.; we
    /// pick 24-hour to avoid am/pm parsing ambiguity.
    func dueTimeHHMM(calendar: Calendar = .current) -> String? {
        guard let dueTime else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: dueTime)
    }

    /// Build the body text that gets sent as `content` on the create
    /// request. We re-append the wiki-link targets as `[[X]]` so the
    /// server's link extractor picks them up, and the tag slugs as
    /// `#tag` so the server's `extract_hashtags` finds them. The
    /// rendered title in the local row will still come from the
    /// server's parsed response, so this is just the raw input the
    /// server needs to reconstruct everything.
    func bodyForServer() -> String {
        var pieces: [String] = []
        if !title.isEmpty {
            pieces.append(title)
        }
        // Tags get stripped from the cleaned title (so the preview
        // shows `"Pay tax"` not `"Pay tax #finance"`); re-append them
        // here so the server still sees the canonical hashtags.
        for tag in tags {
            pieces.append("#\(tag)")
        }
        for target in wikiLinkTargets {
            pieces.append("[[\(target)]]")
        }
        return pieces.joined(separator: " ")
    }
}
