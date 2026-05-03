// TodoRow.swift
// brain-ios
//
// Single todo row used in the Today view's section lists. Mirrors
// `web/src/components/todo-item.tsx` — checkbox on the left, title
// + due-date hint + tag pills in the middle. The checkbox is a
// read-only stub here; toggling completion is M36.
//
// Project tint: we color-code the leading checkbox border with the
// project's accent so the user can scan the list and tell which
// project a todo belongs to without an extra column. Sourced from
// `LocalProject.color` (a CSS HSL string) via `BrainColors.bySlug`
// when we recognise it; otherwise the system tint. Resolution
// happens here rather than in a separate model lookup so the row is
// drop-in usable without extra wiring.

import SwiftData
import SwiftUI

@MainActor
struct TodoRow: View {

    let note: LocalNote

    /// Cached project lookup for the accent color. SwiftData will
    /// re-fetch once per render; the project list is tiny so the
    /// cost is negligible compared to the visual benefit.
    @Query private var projects: [LocalProject]

    init(note: LocalNote) {
        self.note = note
        let projectId = note.projectId
        // Predicate on `id` is fine because LocalProject.id is the
        // server UUID and dedupes via @Attribute(.unique).
        if let projectId {
            _projects = Query(filter: #Predicate<LocalProject> { $0.id == projectId })
        } else {
            // No project — return an empty result. The view falls
            // back to the system tint.
            _projects = Query(filter: #Predicate<LocalProject> { _ in false })
        }
    }

    private var displayTitle: String {
        let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return note.content
    }

    private var accentColor: Color {
        guard let css = projects.first?.color else { return .accentColor }
        // Server stores CSS like `hsl(262 83% 58%)` — match against
        // the palette's `cssValue`. Falls back to the slug match
        // (server may eventually emit slugs directly), then to the
        // system tint.
        if let match = BrainColors.palette.first(where: { $0.cssValue == css }) {
            return match.color
        }
        if let match = BrainColors.bySlug(css) {
            return match.color
        }
        return .accentColor
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
