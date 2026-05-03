// TodoRow.swift
// brain-ios
//
// Single todo row used in the Today view's section lists. Mirrors
// `web/src/components/todo-item.tsx` — checkbox on the left, title
// + due-date hint + tag pills in the middle. The checkbox is a
// read-only stub here; toggling completion is M36.
//
// Project tint: the parent view (`TodayView`) resolves the accent
// from a hoisted `[String: LocalProject]` dict and passes it in,
// so this row does not run its own per-row `@Query`.

import SwiftUI

@MainActor
struct TodoRow: View {

    let note: LocalNote
    /// Pre-resolved accent color for the row's project. The parent
    /// builds it once from a hoisted projects @Query and passes it
    /// in to avoid per-row SwiftData lookups.
    let accentColor: Color

    init(note: LocalNote, accentColor: Color = .accentColor) {
        self.note = note
        self.accentColor = accentColor
    }

    private var displayTitle: String {
        let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return note.content
    }

    private var tags: [String] {
        note.tagsCSV
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Read-only checkbox stub. M36 wires up the toggle.
            Image(systemName: note.completed ? BrainSymbols.checkmarkCircle : BrainSymbols.circle)
                .font(.title3)
                .foregroundStyle(note.completed ? accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.body)
                    .strikethrough(note.completed)
                    .foregroundStyle(note.completed ? Color.secondary : Color.primary)
                    .lineLimit(2)

                if !subline.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(subline, id: \.self) { piece in
                            Text(piece)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if note.priority == "high" {
                // Mirrors the web's high-priority indicator. Low /
                // medium are the unmarked default — rendering all
                // three would clutter the row.
                Image(systemName: "exclamationmark")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("High priority")
            }
        }
        .contentShape(Rectangle())
    }

    /// Bottom-line metadata: due-date hint, then any tags. Matches
    /// the web `todo-item.tsx` ordering.
    private var subline: [String] {
        var pieces: [String] = []
        if let dueDate = note.dueDate, !dueDate.isEmpty {
            // Web renders "due 2026-05-03". For Today view we drop
            // the "due " prefix in Overdue / Due-today / Coming-up
            // because the section header already conveys timing —
            // showing the raw date as a tail hint is enough.
            if let time = note.dueTime, !time.isEmpty {
                pieces.append("\(dueDate) \(time)")
            } else {
                pieces.append(dueDate)
            }
        }
        for tag in tags { pieces.append("#\(tag)") }
        return pieces
    }
}
