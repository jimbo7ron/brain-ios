// WhatsDueIntent.swift
// brain-ios
//
// M43 — Siri / Shortcuts intent that summarises overdue and
// due-today items. Voice trigger: "Hey Siri, what's due in Brain?"
// (resolved against `BrainAppShortcuts`'s phrase list).
//
// Data path: read-only against the local SwiftData store. We use the
// cache rather than hitting the API on every Siri ask because:
//   * Latency matters — Siri is impatient. The local count is <10 ms;
//     a cellular round-trip is 200–500 ms.
//   * The cache is fresh enough — the foreground 5-minute Timer (M33)
//     and the M41 silent-push wake keep it within minutes of server
//     state. For "what's due today?" that drift is negligible.
//   * It works offline. A Siri command on the train shouldn't fail
//     because the network is flaky.
//
// We materialise a fresh `ModelContext` against the shared
// ModelContainer rather than reusing the SwiftUI view tree's context
// — App Intents run outside that environment, and pulling a context
// from the container is the canonical way to read SwiftData from
// non-UI code.

import AppIntents
import Foundation
import SwiftData

/// "What's due today?" — voice-triggerable summary of overdue +
/// due-today items. Mirrors the data the M34 Today view's top two
/// sections render, but folded into a single spoken sentence.
struct WhatsDueIntent: AppIntent {

    /// User-visible name in Settings → Shortcuts and the Shortcuts
    /// app. iOS shows this verbatim; keep it as a question because
    /// that's the natural Siri phrasing.
    static var title: LocalizedStringResource = "What's due today?"

    /// Long-form description shown when the user inspects the intent
    /// in the Shortcuts app. Says exactly what data the response
    /// covers so power-users can decide whether to chain it.
    static var description = IntentDescription(
        "Speaks a short summary of overdue and due-today items from your Brain inbox."
    )

    /// `false` because the intent is read-only and side-effect-free
    /// — Siri can fold the spoken result into a card without
    /// confirmation, matching the "What's the weather?" pattern
    /// users already expect from voice queries.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // App Intents run on the system's actor; hop to the main
        // actor before touching the bridge (which holds main-actor-
        // isolated singletons) and SwiftData (which prefers main-
        // actor access for shared contexts).
        let summary = await Self.buildSummary()
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }

    /// Read overdue + due-today counts and titles from the local
    /// store. Hopped to the main actor because the bridge and the
    /// SwiftData context both want it.
    @MainActor
    private static func buildSummary() async -> String {
        guard let container = BrainIntentsBridge.modelContainer else {
            // Bridge not populated — happens only in the
            // pathological cold-launch race (BrainApp.init not yet
            // run). The system retries shortly after, so a friendly
            // "ask me again in a moment" is the right shape.
            return "Brain is still starting up. Try again in a moment."
        }
        guard BrainIntentsBridge.authSession?.isSignedIn == true else {
            // Signed-out state: no data to read locally. Tell the
            // user explicitly rather than handing back zero.
            return "You need to sign in to Brain first."
        }

        let context = ModelContext(container)
        let todayISO = TodayDate.todayISO()

        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate<LocalNote> {
                $0.type == "todo" &&
                $0.completed == false &&
                $0.archived == false &&
                $0.dueDate != nil
            }
        )
        let openTodos: [LocalNote]
        do {
            openTodos = try context.fetch(descriptor)
        } catch {
            return "Brain couldn't read your todos. Try again."
        }

        let overdue = openTodos.filter { ($0.dueDate ?? "") < todayISO }
        let dueToday = openTodos.filter { $0.dueDate == todayISO }

        return formatSummary(overdue: overdue, dueToday: dueToday)
    }

    /// Render the spoken summary. Kept pure so the format is unit-
    /// checkable from `IntentChecks.swift` without standing up a
    /// full SwiftData container.
    ///
    /// Format rules:
    ///   * Both empty → "You're all caught up. Nothing due today."
    ///   * Overdue-only → "You have N overdue: ..." (max 3 listed).
    ///   * Due-today-only → "You have N due today: ..." (max 3).
    ///   * Both → combined sentence with both counts and the top
    ///     overdue title (the most pressing thing).
    static func formatSummary(overdue: [LocalNote], dueToday: [LocalNote]) -> String {
        let overdueCount = overdue.count
        let todayCount = dueToday.count

        if overdueCount == 0 && todayCount == 0 {
            return "You're all caught up. Nothing due today."
        }

        var sentences: [String] = []

        if overdueCount > 0 {
            let label = overdueCount == 1 ? "overdue item" : "overdue items"
            sentences.append("You have \(overdueCount) \(label).")
        }
        if todayCount > 0 {
            let label = todayCount == 1 ? "item" : "items"
            sentences.append("\(todayCount) \(label) due today.")
        }

        // Lead with the top overdue (most pressing) or top due-today
        // title so the spoken response is actionable, not just a
        // count. Three is the cap — any more and Siri clips the
        // dialog with "and N others".
        let topItems = (overdue + dueToday).prefix(3)
        let topTitles = topItems.compactMap { titleForSummary($0) }
        if !topTitles.isEmpty {
            sentences.append("Top: \(topTitles.joined(separator: "; ")).")
        }

        return sentences.joined(separator: " ")
    }

    /// Pick a short, speakable title for one row. Trims to the first
    /// line of `content` if no explicit title — same convention
    /// `TodoRow` uses.
    private static func titleForSummary(_ note: LocalNote) -> String? {
        if let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let firstLineRaw = note.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let firstLine = firstLineRaw.trimmingCharacters(in: .whitespaces)
        return firstLine.isEmpty ? nil : firstLine
    }
}
