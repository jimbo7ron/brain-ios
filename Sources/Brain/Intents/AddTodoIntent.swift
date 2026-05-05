// AddTodoIntent.swift
// brain-ios
//
// M43 — Siri / Shortcuts intent that creates a todo. Voice trigger:
// "Hey Siri, add to Brain: buy bread tomorrow !high" (resolved
// against `BrainAppShortcuts`'s phrase list, with `\.$content`
// taking the trailing free-form text).
//
// Parsing path: reuses `QuickAddParser` (the M39 trailing-keyword
// parser) so a Shortcut command produces the same fields as typing
// the same string into the QuickAdd sheet. A user who learns the
// "buy bread tomorrow !high #shopping" muscle memory in one surface
// gets it for free in the other.
//
// Mutation routing: direct `POST /api/v1/notes` via the shared
// `BrainAPIClient`, matching the M39 QuickAddView path. We do NOT
// go through the M37 mutation queue because:
//   * The queue's `createTodo` op isn't fully wired (M40 deferred
//     to M41+, which became M43 territory). Wiring it just for
//     intents would mean shipping a lot of new code with no test
//     coverage.
//   * App Intents typically fire when the network is reachable
//     (Siri is itself a network operation). Offline Siri commands
//     are rare; the failure mode is acceptable for v1.
//   * Direct calls keep the spoken confirmation accurate — "Got
//     it" implies the server saved it. A queue-route would have to
//     either lie ("Got it") or speak a confusing "Saved offline"
//     response that most users wouldn't act on.

import AppIntents
import Foundation

/// "Add a todo" — voice-triggerable todo creation. The free-form
/// `content` parameter rides through `QuickAddParser` so trailing
/// keywords (date phrases, priority bangs, hashtags, wiki-links)
/// behave the same as in QuickAddView.
struct AddTodoIntent: AppIntent {

    /// User-visible name. Phrased as a verb so it reads naturally in
    /// Settings → Shortcuts ("Add a todo").
    static var title: LocalizedStringResource = "Add a todo"

    static var description = IntentDescription(
        "Creates a Brain todo from free-form text. Trailing keywords like 'tomorrow', '!high', and '#tag' are parsed automatically."
    )

    /// `false` because the intent is one-shot — Siri speaks the
    /// confirmation and the user goes back to whatever they were
    /// doing. Opening the app would interrupt the flow that made
    /// them invoke Siri in the first place.
    static var openAppWhenRun: Bool = false

    /// Free-form todo text. Marked `@Parameter` so Shortcuts users
    /// can pipe text in from another action ("Get text from clipboard"
    /// → "Add a todo"). For voice triggers, the phrase template
    /// `\(\.$content)` captures everything the user spoke after the
    /// trigger phrase.
    @Parameter(
        title: "Content",
        description: "What you want to remember. Try \"Buy bread tomorrow !high\".",
        requestValueDialog: IntentDialog("What should I add?")
    )
    var content: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = await Self.createTodo(rawContent: content)
        return .result(dialog: IntentDialog(stringLiteral: response))
    }

    /// Parse `raw`, build a `CreateNotePayload`, fire it through the
    /// shared API client, return the spoken response. Hopped to the
    /// main actor because the bridge and the API client's call site
    /// expect it.
    @MainActor
    private static func createTodo(rawContent: String) async -> String {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "I didn't catch what to add."
        }

        guard BrainIntentsBridge.authSession?.isSignedIn == true else {
            return "You need to sign in to Brain first."
        }
        guard let client = BrainIntentsBridge.apiClient else {
            return "Brain is still starting up. Try again in a moment."
        }

        let parsed = QuickAddParser.parse(trimmed)

        // If the parser couldn't extract a meaningful title, send the
        // raw text as-is. This happens for inputs like "tomorrow"
        // where the parser conservatively bails — the user clearly
        // meant *something*, so storing the raw string is better than
        // dropping the command.
        let bodyContent = parsed.title.isEmpty ? trimmed : parsed.bodyForServer()

        let payload = CreateNotePayload(
            content: bodyContent,
            title: nil,
            type: "todo",
            dueDate: parsed.dueDateISO(),
            dueTime: parsed.dueTimeHHMM(),
            priority: parsed.priority?.rawValue,
            recurrence: parsed.recurrence?.rawValue,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        do {
            _ = try await client.createNote(payload)
            return successDialog(for: parsed, fallbackTitle: trimmed)
        } catch let error as BrainAPIClient.Error {
            return "Couldn't save: \(error.userFacingMessage)"
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Build the spoken confirmation. We surface the parsed title and
    /// the resolved due date when present so the user can hear that
    /// "tomorrow" was understood. Kept pure (no SwiftData / network
    /// reads) so the format is unit-checkable.
    static func successDialog(for parsed: QuickAddResult, fallbackTitle: String) -> String {
        let title = parsed.title.isEmpty ? fallbackTitle : parsed.title
        if let isoDue = parsed.dueDateISO() {
            // Fold the date into the response so the user knows we
            // didn't misparse "tomorrow" as a tag. We surface the ISO
            // date verbatim; Siri's TTS reads "2026-05-04" cleanly
            // enough.
            return "Added: \(title), due \(isoDue)."
        }
        return "Added: \(title)."
    }
}
