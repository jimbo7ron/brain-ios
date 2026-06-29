// QuickAddView.swift
// brain-ios
//
// Quick-add sheet (M39). Mirrors the web's quick-capture box: the user
// types a single line like `"Pay tax tomorrow !high #finance"` and the
// app extracts the trailing date, priority bang, hashtags, wiki-links,
// and recurrence keyword as they type. A live preview renders the
// parsed result so the user can confirm we understood them before
// hitting Add.
//
// Submission is OPTIMISTIC: we mint a client UUID, insert a `LocalNote`
// stub immediately, save, and dismiss the sheet. The list view's
// `@Query` re-renders with the new row right away — no waiting on the
// network. We then enqueue a `.createTodo` mutation; the M37 queue
// replays it in the background, the server returns the canonical
// note, and `MutationQueue.reconcileCreateResponse` patches the
// stub's id / shortId / timestamps in place.
//
// This replaces the original M39 direct-call shape (`await
// client.createNote(...)` then dismiss) which made rapid adds appear
// to "pile up" — the user would type three todos in a row but only
// see them all once a sync completed. The optimistic insert renders
// each one instantly; the create round-trip becomes invisible.

import SwiftData
import SwiftUI

/// Modal sheet that converts free-form text into a todo. Presented
/// from the FAB on `TodayView`, from per-project surfaces (e.g. the
/// "Inbox" virtual project), and from the per-section "+" row on
/// `ProjectDetailView` — each callsite threads a project id (and
/// optionally a section slug) through the optional context init so
/// the new todo lands in the right bucket without an extra round-trip.
@MainActor
struct QuickAddView: View {

    /// M45 Wave 2: write contract goes through `NoteRepository` rather
    /// than the open-coded `modelContext.insert + save + queue.enqueue`
    /// shape this view shipped with. The repository owns the
    /// optimistic stub construction, the queue enqueue, and the
    /// per-row status mark — the view just builds the payload and
    /// calls `noteRepo.create(payload)`. Optional because the env-key
    /// default is `nil`; in production `BrainApp.init` always injects a
    /// real repository. Previews / non-production hosts fall back to
    /// the no-op branch in `submit()` below.
    @Environment(\.noteRepository) private var noteRepo
    @Environment(\.dismiss) private var dismiss

    /// Optional project id to pre-fill on the wire payload. The
    /// server's `NoteCreate.project` field accepts either a project
    /// name, a project id, or the literal sentinel `"inbox"`
    /// (which clears any inferred project association). `nil` means
    /// "no project context — let the server's defaults apply"
    /// (Inbox-style capture from the Today FAB).
    let prefilledProjectID: String?
    /// Optional section slug to pre-fill on the wire payload. Must be
    /// the slug, not the display name — the server rejects unknown
    /// slugs with a 400. `nil` means "let the server pick the default
    /// section" (typically `now`). Used by the per-section "+" row on
    /// `ProjectDetailView` to drop the new todo straight into the
    /// section the user tapped.
    let prefilledSectionSlug: String?
    /// Optional human-readable project name, used purely for the
    /// in-sheet "Adding to <Project>" caption so the user knows where
    /// the todo will land. Not sent on the wire.
    let prefilledProjectName: String?

    @State private var rawText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    /// Designated init. All three context parameters default to `nil`
    /// so existing callsites (the Today FAB) keep their previous
    /// behaviour — no project, no section, no caption. New callsites
    /// pass `projectID: "inbox"` (the Inbox virtual project)
    /// or a real project UUID (optionally with a section slug) to
    /// scope the capture.
    init(
        projectID: String? = nil,
        sectionSlug: String? = nil,
        projectName: String? = nil
    ) {
        self.prefilledProjectID = projectID
        self.prefilledSectionSlug = sectionSlug
        self.prefilledProjectName = projectName
    }

    /// The parsed result is recomputed every keystroke. Cheap — the
    /// regex passes are linear in input length.
    private var parsed: QuickAddResult {
        QuickAddParser.parse(rawText)
    }

    /// Cleared title means "no useful content" — a single date phrase
    /// like `"tomorrow"` survives as the title, but a fully-stripped
    /// input (e.g. just `#tag1 #tag2` after we drop priorities) leaves
    /// a usable title in `tagged`. We use the raw input length as the
    /// final guard so the user can't submit just whitespace.
    private var canSubmit: Bool {
        !isSubmitting && !rawText.trimmingCharacters(in: .whitespaces).isEmpty && !parsed.title.isEmpty
    }

    /// "Adding to <Project>" or "Adding to <Project> · <slug>" when a
    /// section is also pinned. Returns `nil` when no project context is
    /// set, so the Today FAB renders without a caption (unchanged).
    /// Exposed as `internal` so the DEBUG checks file can verify the
    /// formatter without going through SwiftUI rendering.
    var contextCaption: String? {
        guard let name = prefilledProjectName else { return nil }
        if let slug = prefilledSectionSlug {
            return "Adding to \(name) · \(slug)"
        }
        return "Adding to \(name)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let contextCaption {
                        Text(contextCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("quick-add.context")
                    }

                    inputSection

                    if !parsed.title.isEmpty {
                        QuickAddPreview(result: parsed)
                            .transition(.opacity)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("quick-add.error")
                    }

                    helpFooter
                }
                .padding()
            }
            .navigationTitle("Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        // submit() is synchronous now — the optimistic
                        // local insert lands immediately and the create
                        // round-trip is enqueued on the M37 mutation
                        // queue. No `Task { await … }` wrapper needed;
                        // the spinner state survives only as a
                        // belt-and-braces guard against double-taps.
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Add").bold()
                        }
                    }
                    .disabled(!canSubmit)
                    // Tier 2 e2e harness: stable XCUITest hook.
                    .accessibilityIdentifier("quick-add.submit")
                }
            }
        }
    }

    /// Big multi-line text field. Auto-focused on appear so the user
    /// can start typing immediately — the FAB is one tap, the keyboard
    /// is the next thing they expect.
    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's on your mind?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(
                "Try \"Ship migration by Friday !high #work\"",
                text: $rawText,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.done)
            .accessibilityIdentifier("quick-add.field")
        }
    }

    /// Inline cheat-sheet rendered below the preview — tells the user
    /// what the parser knows about. Kept compact; it's only useful
    /// once.
    @ViewBuilder
    private var helpFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hints")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("Add a date: tomorrow, next monday, in 3 days, 2026-05-12")
            Text("Add a time: at 9am, at 15:00")
            Text("Priority: !high  |  !medium  |  !low")
            Text("Tags: #work  #finance      Wiki link: [[Project Alpha]]")
            Text("Recurrence: daily, weekly, monthly, weekdays")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Optimistic-add path. Builds the wire payload from the parsed
    /// preview and hands it to `NoteRepository.create(_:)`, which owns
    /// the entire optimistic-insert + queue-enqueue + status-store-mark
    /// dance. The repository's `ModelContext` lives on the same
    /// `ModelContainer` as the SwiftUI environment context, so the
    /// `@Query` subscribers in `TodayView` / `ProjectDetailView` /
    /// `InboxDetailView` pick up the new row in the next render
    /// pass — same UX as the open-coded path this replaces.
    ///
    /// M45 Wave 2: this used to do `modelContext.insert + save +
    /// queue.enqueue` inline. Wave 1 moved that ceremony into
    /// `NoteRepository`; Wave 2 deletes it from the call site.
    private func submit() {
        guard canSubmit else { return }

        isSubmitting = true
        errorMessage = nil
        // We don't await anything below — `repo.create` is a
        // synchronous SwiftData apply plus a non-blocking enqueue —
        // so the busy state is reset immediately. We still flip the
        // flag for symmetry with the spinner in the toolbar.
        defer { isSubmitting = false }

        // Wire-payload `project` — pass through the prefilled id verbatim.
        // The server resolves three cases:
        //   * `nil`            → leave any inferred association alone
        //   * `"inbox"`   → clear `project_id` to NULL (sentinel)
        //   * any UUID / name  → look up the project by id then by name
        // See `src/brain/server.py` lines 1858, 2032-2044 for the
        // create/update resolution path the server takes.
        // M45 Wave 2 review: pass `parsed.title` explicitly. Without it,
        // `NoteRepository.create` re-derives the title by re-parsing
        // `payload.content` — which is `parsed.bodyForServer()`, the
        // already-stripped form. Re-parsing stripped content can yield
        // a slightly different title than `parsed.title` on the raw
        // input (the parser's title heuristic strips date/priority
        // tokens, and double-stripping isn't strictly idempotent in
        // edge cases). The repo prefers caller-supplied title when
        // present, so passing it preserves pre-migration semantics.
        let payload = CreateNotePayload(
            content: parsed.bodyForServer(),
            title: parsed.title.isEmpty ? nil : parsed.title,
            type: "todo",
            dueDate: parsed.dueDateISO(),
            dueTime: parsed.dueTimeHHMM(),
            priority: parsed.priority?.rawValue,
            recurrence: parsed.recurrence?.rawValue,
            project: prefilledProjectID,
            section: prefilledSectionSlug,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        guard let noteRepo else {
            // Preview / non-production host. Production wires the
            // repository in `BrainApp.init`, so this branch is only
            // hit by SwiftUI previews.
            NSLog("QuickAddView: no NoteRepository in environment — preview host.")
            BrainHaptics.light()
            dismiss()
            return
        }

        _ = noteRepo.create(payload)

        // M43: light haptic on dismiss. Matches the M36 toggle-
        // complete pattern — a brief confirmation that the capture
        // landed before the sheet animates away.
        BrainHaptics.light()
        dismiss()
    }
}

/// Live preview of the parsed result. Renders title + chips for date,
/// time, priority, recurrence, tags, wiki-links. Mirrors the web's
/// quick-add affordance.
struct QuickAddPreview: View {

    let result: QuickAddResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text(result.title)
                    .font(.headline)
                    .accessibilityIdentifier("quick-add.preview.title")

                FlowChips {
                    if let date = result.dueDate {
                        QuickAddChip(
                            symbol: BrainSymbols.dueToday,
                            text: formatPreviewDate(date),
                            tint: BrainColors.sky.color
                        )
                    }
                    if let time = result.dueTime {
                        QuickAddChip(
                            symbol: "clock",
                            text: formatPreviewTime(time),
                            tint: BrainColors.sky.color
                        )
                    }
                    if let priority = result.priority {
                        QuickAddChip(
                            symbol: "exclamationmark.circle",
                            text: priority.rawValue.capitalized,
                            tint: priorityTint(priority)
                        )
                    }
                    if let recurrence = result.recurrence {
                        QuickAddChip(
                            symbol: "arrow.triangle.2.circlepath",
                            text: recurrence.rawValue.capitalized,
                            tint: BrainColors.violet.color
                        )
                    }
                    ForEach(result.tags, id: \.self) { tag in
                        QuickAddChip(
                            symbol: "number",
                            text: tag,
                            tint: BrainColors.emerald.color
                        )
                    }
                    ForEach(result.wikiLinkTargets, id: \.self) { target in
                        QuickAddChip(
                            symbol: "link",
                            text: target,
                            tint: BrainColors.indigo.color
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    /// Map a parsed `Date` into a short label like "Today", "Tomorrow",
    /// or `"Mon May 5"`. We reuse `TodayDate.relativeDayLabel` for
    /// near-term dates so the preview matches the Today view's
    /// vocabulary.
    private func formatPreviewDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfDate = calendar.startOfDay(for: date)
        if startOfDate == startOfToday { return "Today" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let label = formatter.string(from: date)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           startOfDate == tomorrow {
            return "Tomorrow"
        }
        return label
    }

    private func formatPreviewTime(_ time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: time)
    }

    private func priorityTint(_ priority: QuickAddPriority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        }
    }
}

/// Single labelled chip used in the preview row. Symbol + short text
/// inside a soft-tinted capsule.
struct QuickAddChip: View {

    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
    }
}

/// Tiny flow-layout shim so chips wrap onto multiple lines on narrow
/// devices. SwiftUI's `Layout` protocol exists since iOS 16 and is the
/// minimal way to do this without dragging in a 3rd-party package.
struct FlowChips: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Quick add — empty") {
    QuickAddView()
}

#Preview("Quick add — populated") {
    let preview = QuickAddPreview(
        result: QuickAddParser.parse("Ship migration tomorrow at 9am !high #work [[Project Alpha]]")
    )
    return preview
        .padding()
}
