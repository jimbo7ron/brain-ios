// BrainAppShortcuts.swift
// brain-ios
//
// M43 — `AppShortcutsProvider` registration. The system reads this
// type at app install / launch and surfaces the listed shortcuts in
// Spotlight, Siri, and the Shortcuts app. Each `AppShortcut` binds
// an `AppIntent` to a list of trigger phrases.
//
// Phrase grammar:
//   * `\(.applicationName)` is replaced at runtime by the user-facing
//     app name (`brain`). Apple requires every phrase to include this
//     placeholder so users can disambiguate from other apps' shortcuts.
//   * `\(\.$content)` (in AddTodoIntent's phrases) binds the rest of
//     the spoken / typed input to the intent's `@Parameter` named
//     `content`. The user can phrase the trigger as natural language
//     and the parameter captures everything after the trigger token.
//
// We deliberately ship a small set of phrases per shortcut. iOS
// limits the total to 10 across all shortcuts in an app; over-
// crowding makes Spotlight matches less reliable. The patterns we
// chose mirror the iOS first-party patterns ("What's on my list",
// "Remind me to ...") so users who already speak fluent Siri don't
// have to learn a new vocabulary.

import AppIntents
import Foundation

/// Registers every Brain App Intent that should appear in
/// Spotlight / Siri / the Shortcuts app. The `appShortcuts` builder
/// is read by the system at launch — there is no explicit
/// registration call.
struct BrainAppShortcuts: AppShortcutsProvider {

    /// Tile colour for the Shortcuts app card. We pick a tint name
    /// that resolves cleanly in both light and dark mode (the system
    /// supplies the actual colour). `purple` matches the BrainColors
    /// violet that the rest of the app already uses for the FAB and
    /// Coming-Up section, so the Shortcuts tile reads as on-brand
    /// without us shipping a custom asset.
    static var shortcutTileColor: ShortcutTileColor = .purple

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsDueIntent(),
            phrases: [
                "What's due in \(.applicationName)",
                "What's on my list in \(.applicationName)",
                "What's overdue in \(.applicationName)",
            ],
            shortTitle: "What's due today?",
            systemImageName: "calendar.badge.exclamationmark"
        )

        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "Add to \(.applicationName) \(\.$content)",
                "Add \(\.$content) to \(.applicationName)",
                "Remind me to \(\.$content) in \(.applicationName)",
            ],
            shortTitle: "Add a todo",
            systemImageName: "plus.circle.fill"
        )
    }
}
