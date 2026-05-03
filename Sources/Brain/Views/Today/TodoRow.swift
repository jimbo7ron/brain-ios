// TodoRow.swift
// brain-ios
//
// Single todo row used in the Today view's section lists. Mirrors
// `web/src/components/todo-item.tsx` — checkbox on the left, title
// + due-date hint + tag pills in the middle.
//
// M36 wires the checkbox to `POST /api/v1/notes/{id}/complete`:
//   1. Capture the row's prior `completed` / `completedAt` state.
//   2. Optimistically flip both local fields and `try? save()`.
//   3. Fire the server call. On failure, revert the local fields and
//      save again — SwiftUI re-renders from the SwiftData mutation.
//
// There's no `/uncomplete` server endpoint yet (deferred to M40), so
// tapping an already-completed row is a no-op — we leave the strike-
// through styling and the foreground stay-put. Spec calls this out
// explicitly: "Fall back to 'complete only' gracefully if /uncomplete
// doesn't exist." When M40 lands we'll branch on `note.completed`
// here and call the new endpoint.
//
// Project tint: the parent view (`TodayView` / `ProjectDetailView`)
// resolves the accent from a hoisted `[String: LocalProject]` dict
// and passes it in, so this row does not run its own per-row
// `@Query`. Both parents already inject `\.brainAPIClient` and the
// SwiftData `\.modelContext` from the app scene, so the toggle has
// everything it needs without extra plumbing.

import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct TodoRow: View {

    let note: LocalNote
    /// Pre-resolved accent color for the row's project. The parent
    /// builds it once from a hoisted projects @Query and passes it
    /// in to avoid per-row SwiftData lookups.
    let accentColor: Color

    @Environment(\.modelContext) private var modelContext
    /// Optional because the environment key default is `nil` (see
    /// `BrainAPIClientKey.defaultValue`). In production `BrainApp`
    /// always injects a real client; previews and unit hosts may not.
    /// When the client is missing the toggle becomes a local-only
    /// flip with no rollback — fine for previews, never hit in
    /// production.
    @Environment(\.brainAPIClient) private var client

    /// Tracks whether a toggle is currently in flight. Prevents a
    /// rapid double-tap from firing two POSTs against the server
    /// before the first response lands; the optimistic flip would
    /// otherwise oscillate.
    @State private var isToggling: Bool = false

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
            // Tap-to-complete checkbox. Already-completed rows are a
            // no-op until the server gets an `/uncomplete` endpoint
            // (M40). We keep the button enabled either way so the
            // accessibility label still reads, but the action exits
            // early when there's nothing to do.
            Button {
                guard !isToggling else { return }
                Task { await toggle() }
            } label: {
                Image(systemName: note.completed ? BrainSymbols.checkmarkCircle : BrainSymbols.circle)
                    .font(.title3)
                    .foregroundStyle(note.completed ? accentColor : Color.secondary)
                    .contentShape(Rectangle())
            }
            // `.borderless` (rather than `.plain`) because M35 puts
            // these rows inside a List in `ProjectDetailView`. Without
            // an explicit borderless style, SwiftUI promotes the row
            // itself to a button surface and a tap anywhere in the
            // row activates the checkbox — we want the tap target
            // limited to the icon.
            .buttonStyle(.borderless)
            .accessibilityLabel(note.completed ? "Completed" : "Mark complete")
            .accessibilityHint(note.completed ? "Reopening is coming in a future update." : "")

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

    /// Flip the row to completed with optimistic UI + rollback on
    /// failure. Spec (M36): "Optimistic update + API call. Failure
    /// rolls back the local view." We capture the original state up
    /// front so the rollback path doesn't have to recompute it from
    /// possibly-already-stale fields.
    ///
    /// We do NOT trigger `SyncEngine.sync()` after success: the next
    /// 5-minute foreground tick (M33) or scenePhase-active rehydrate
    /// will pick up the server's authoritative `completed_at`
    /// timestamp. Firing sync per-tap would amplify network load on
    /// rapid completions and racy-mutate the row we just touched.
    /// M37 will replumb this through the mutation queue and that's
    /// where bulk-replay-then-sync coordination belongs.
    private func toggle() async {
        // No `/uncomplete` endpoint yet (server has only `/complete`,
        // see brain/src/brain/server.py). Re-opening a completed row
        // is M40. Until then, tapping a done row is a deliberate
        // no-op rather than a misleading optimistic flip that the
        // next sync would silently revert.
        guard !note.completed else { return }
        guard let client = client else {
            // Preview / non-production host: do a local-only flip so
            // SwiftUI previews still feel responsive, and skip the
            // server call. Production never hits this branch.
            note.completed = true
            note.completedAt = Date()
            try? modelContext.save()
            return
        }

        isToggling = true
        defer { isToggling = false }

        // Capture rollback state.
        let wasCompleted = note.completed
        let originalCompletedAt = note.completedAt

        // Optimistic flip — render-immediate.
        note.completed = true
        note.completedAt = Date()
        try? modelContext.save()

        do {
            _ = try await client.completeTodo(noteId: note.id)
            // Light tactile confirmation on success. Matches the iOS
            // system idiom for a "thing happened" affordance — the
            // web equivalent is the brief Lucide `Check` flash on
            // todo-item.tsx. Skipped on platforms without UIKit
            // (e.g. previews on macOS hosts).
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } catch {
            // Revert. Don't surface a toast — UX polish is M43, and
            // the visual revert is itself the failure signal.
            note.completed = wasCompleted
            note.completedAt = originalCompletedAt
            try? modelContext.save()
        }
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
