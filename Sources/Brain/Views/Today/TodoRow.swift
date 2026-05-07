// TodoRow.swift
// brain-ios
//
// Single todo row used in the Today view's section lists. Mirrors
// `web/src/components/todo-item.tsx` — checkbox on the left, title
// + due-date hint + tag pills in the middle.
//
// M45 Wave 3: both row-level mutations go through `NoteRepository`:
//   * Tap-to-complete checkbox calls `noteRepo.toggleComplete(note)`,
//     which optimistically flips `completed` + `completedAt` and
//     enqueues `.completeTodo` / `.uncompleteTodo` against the M37
//     queue. Pre-Wave-3 the row called `client.completeTodo(...)`
//     directly with a hand-rolled rollback on failure (the M37+ TODO
//     comment that lived here noted the queue migration was pending).
//   * Trailing swipe-to-archive calls `noteRepo.archive(note)`. The
//     repo applies the local flip and enqueues `.archiveNote`.
//
// Project tint: the parent view (`TodayView` / `ProjectDetailView`)
// resolves the accent from a hoisted `[String: LocalProject]` dict and
// passes it in, so this row does not run its own per-row `@Query`.

import SwiftData
import SwiftUI

@MainActor
struct TodoRow: View {

    let note: LocalNote
    /// Pre-resolved accent color for the row's project. The parent
    /// builds it once from a hoisted projects @Query and passes it
    /// in to avoid per-row SwiftData lookups.
    let accentColor: Color

    @Environment(\.modelContext) private var modelContext
    /// M45 Wave 3: the only write surface this row reads from. Both
    /// `archive()` and `toggle()` route through it. Optional because
    /// the env key default is `nil` (preview / non-production hosts);
    /// production `BrainApp.init` always wires a real repository.
    /// When the repo is missing we fall back to a local-only flip so
    /// SwiftUI previews still feel responsive — production never hits
    /// that branch.
    @Environment(\.noteRepository) private var noteRepository
    /// M45 Wave 4 (spec §4.4 per-row indicator): observe the global
    /// status store. Reading `status(for: note.id)` re-renders this
    /// row whenever the dictionary mutates anywhere — at 50+ rows
    /// that's coarse but acceptable for now (see `MutationStatusStore`
    /// header for the rebuild-coarseness caveat). If profiling shows
    /// it's a problem, switch to an `Equatable`-on-Status read or a
    /// per-key Bindable wrapper.
    @Environment(\.mutationStatusStore) private var mutationStatusStore

    /// Tracks whether a toggle is currently in flight. Prevents a
    /// rapid double-tap from firing two POSTs against the server
    /// before the first response lands; the optimistic flip would
    /// otherwise oscillate.
    @State private var isToggling: Bool = false

    /// Drives the M40 edit-todo sheet. Long-press on the row sets
    /// this to true and the sheet binding presents `EditTodoView` for
    /// the row's note. State lives here (not on the parent) because
    /// the row is the natural owner of the per-row affordance —
    /// promoting it would force the parent to track which row is
    /// being edited via id, which is more wiring than the gain.
    ///
    /// Pre-M44.1 the affordance lived behind a `.contextMenu` with
    /// "Edit" and a disabled "Archive" placeholder. Live iPhone
    /// testing flagged the menu as friction — long-press → tap-edit
    /// is two beats for an action that's the only enabled menu item.
    /// We swapped the menu for a direct `onLongPressGesture`. Archive
    /// will come back via a swipe-action when M41+ wires archive
    /// through the mutation queue.
    @State private var isEditPresented: Bool = false

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
                    .font(.headline)
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
            // Tier 2 e2e harness: per-row complete-toggle hook.
            .accessibilityIdentifier("todo-complete-\(note.id)")

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.callout)
                    .strikethrough(note.completed)
                    .foregroundStyle(note.completed ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    // Tier 2 e2e harness: title hook so tests can
                    // assert on the displayed string after an edit.
                    .accessibilityIdentifier("todo-title-\(note.id)")

                if !subline.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(subline, id: \.self) { piece in
                            Text(piece)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // M45 Wave 4: per-row status affordance. Pending rows get
            // a small spinner (subtle — the row content is the primary
            // signal); failed rows get a red exclamation glyph so a
            // permanent failure surfaces inline rather than only in
            // the queue-level pill. Both are no-rendered when the
            // store has no entry for this id (which is the common
            // case — fully reconciled rows clear).
            statusIndicator

            if note.priority == "high" {
                // Mirrors the web's high-priority indicator. Low /
                // medium are the unmarked default — rendering all
                // three would clutter the row.
                Image(systemName: "exclamationmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("High priority")
            }
        }
        .contentShape(Rectangle())
        // Tighter row insets than the system default (~11pt top/bottom)
        // for higher information density on iPhone. Halved vertically;
        // horizontal kept at the system 16pt so the row aligns with
        // section headers and other inset-grouped chrome. Tap targets
        // remain reachable thanks to the row-area hit-testing below
        // and the parent List's `defaultMinListRowHeight` of 32pt.
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        // Long-press → Edit. The checkbox is its own `.borderless`
        // Button (see above), so the row itself isn't a button —
        // SwiftUI delivers the long-press gesture to the row content
        // without intercepting the checkbox tap. Tapping the checkbox
        // still toggles complete; long-pressing anywhere on the row
        // (including the checkbox) opens the edit sheet.
        //
        // Pre-M44.1 this lived behind a `.contextMenu` with "Edit"
        // and a disabled "Archive" placeholder. Going straight to the
        // sheet shaves a tap and removes the dead Archive entry that
        // was confusing in live testing.
        .onLongPressGesture(minimumDuration: 0.4) {
            BrainHaptics.light()
            isEditPresented = true
        }
        .sheet(isPresented: $isEditPresented) {
            EditTodoView(note: note)
        }
        // M44.x: trailing swipe → Archive. The destructive role gives us
        // the standard right-edge red treatment and (with the default
        // `allowsFullSwipe: true`) a full swipe also triggers the action,
        // matching iOS Mail / Reminders. The optimistic flip happens
        // inside `archive()` *before* the queue replays so the row leaves
        // the @Query result set immediately. The TodoRow's own pre-M44.1
        // doc-comment promised this affordance once the queue understood
        // archive — that wiring landed in M44.x via `MutationOp.archiveNote`.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                archive()
            } label: {
                Label("Archive", systemImage: BrainSymbols.archive)
            }
            .tint(.red)
        }
    }

    /// M45 Wave 3: hand off to `NoteRepository.archive(...)`. The repo
    /// flips `archived = true` locally and enqueues `.archiveNote`
    /// (the brain server treats DELETE as soft-delete / archive — see
    /// `delete_note_endpoint`). Pre-Wave-3 this method open-coded the
    /// `mutationQueue.enqueue(.archiveNote, ...)` dance; the repo now
    /// owns it.
    private func archive() {
        // Already archived — defensive guard. Shouldn't happen because
        // the row is filtered out of every list that hosts it before
        // the user can swipe, but a stale query result + a fast tap
        // could in theory race here. Mirrored on the repo too; doing
        // the check here lets us skip the haptic on the no-op path.
        guard !note.archived else { return }

        // Light haptic: matches the M36 complete-toggle weight rather
        // than the heavier `.medium` used for multi-field saves. An
        // archive is a single-tap action, so the lighter pulse keeps
        // the haptic vocabulary consistent with the rest of the row.
        BrainHaptics.light()

        guard let repo = noteRepository else {
            // Preview / non-production host: do a local-only flip so
            // SwiftUI previews still feel responsive. Production never
            // hits this branch.
            note.archived = true
            try? modelContext.save()
            return
        }
        repo.archive(note)
    }

    /// M45 Wave 3 (resolves the M37+ TODO that lived in this method's
    /// previous incarnation): hand off to
    /// `NoteRepository.toggleComplete(...)`. The repo applies the
    /// optimistic flip on `completed` + `completedAt`, enqueues
    /// `.completeTodo` or `.uncompleteTodo` against the M37 queue, and
    /// the queue's replay handles the round-trip + LWW reconcile.
    ///
    /// Pre-Wave-3 this method called `client.completeTodo(...)`
    /// directly with a hand-rolled rollback on failure and a manual
    /// 401 → `signOutDueToUnauthorized` branch. Both responsibilities
    /// now live in the queue's `replay()` taxonomy: rollback is the
    /// `rollbackOptimisticStateIfNeeded` path, and 401 handoff is the
    /// queue's `handleUnauthorized()` (which mirrors the SyncEngine's
    /// behaviour). The recovery latency stays at "next replay tick" —
    /// in practice still seconds, since `enqueue` fires a background
    /// `replay()` Task immediately.
    private func toggle() async {
        // No `/uncomplete` endpoint on the server today (server has
        // only `/complete`); the repo's `.uncompleteTodo` arm in
        // `BrainAPIClient.executeMutation` throws `.notImplemented`
        // and the queue parks the row. Until the server endpoint
        // lands, tapping a completed row is a deliberate no-op rather
        // than a misleading optimistic flip the queue would then
        // poison.
        guard !note.completed else { return }

        isToggling = true
        defer { isToggling = false }

        guard let repo = noteRepository else {
            // Preview / non-production host: local-only flip so
            // previews still feel responsive. Production never hits
            // this branch.
            note.completed = true
            note.completedAt = Date()
            try? modelContext.save()
            return
        }

        repo.toggleComplete(note)
        // Light tactile confirmation. The repo's optimistic apply has
        // already landed, so the haptic fires alongside the visible
        // strike-through.
        BrainHaptics.light()
    }

    /// M45 Wave 4: per-row indicator overlay. Reads from the
    /// MutationStatusStore on every render — the row keeps the
    /// indicator attached across the create-echo's id rename because
    /// the queue's `reconcileCreate<T:>` calls
    /// `MutationStatusStore.rename(clientId, to: serverId)` in lock-
    /// step. No-op when the store is missing (preview hosts) or when
    /// the row's id isn't tracked.
    @ViewBuilder
    private var statusIndicator: some View {
        if let status = mutationStatusStore?.status(for: note.id) {
            switch status {
            case .pending:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Saving")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Save failed")
            }
        } else {
            EmptyView()
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
