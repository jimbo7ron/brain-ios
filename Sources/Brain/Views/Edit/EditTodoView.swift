// EditTodoView.swift
// brain-ios
//
// M40 — full edit dialog for an existing todo. Mirrors the web's
// `web/src/components/todo-edit-dialog.tsx` field set:
//
//   * Title (single-line) + Notes (multi-line) — server stores both as
//     a single `content` string with the title on line 1 and notes from
//     line 3 onward (line 2 is a blank separator). Same convention the
//     web uses; see `splitContent` in the web dialog.
//   * Due date (text — accepts "today" / "tomorrow" / "yyyy-MM-dd").
//     Web does this with a free-text input rather than a DatePicker
//     because the server stores due_date as a flexible string and we
//     want to preserve that latitude on iOS too.
//   * Priority (segmented: Low / Medium / High).
//   * Project (picker, with "Inbox" sentinel).
//   * Section (segmented: drawn from the selected project's sections,
//     or DEFAULT_SECTIONS — Now/Next/Later — when no project is set).
//   * URL (single-line text — server resolves GitHub PR/issue metadata
//     server-side; we just hand off the raw string).
//   * Tags (read-only display of tags extracted from `content`).
//
// **Mutation routing (M45 Wave 3):**
// Save builds a typed `NoteUpdateFields` from the form state and hands
// it to `NoteRepository.update(note, fields)`. The repo applies the
// optimistic local mutation, encodes the wire `UpdateNotePayload`, and
// enqueues `.updateTodo` with `baseUpdatedAt: note.updatedAt` (the
// local row's last-known server `updated_at`). M38's pull-side LWW
// conflict resolution drops the queue item if a newer server-side
// write lands during the offline window; M45 Wave 3 (spec §4.3) adds
// a write-side LWW guard so the server's response doesn't clobber a
// later edit the user enqueued before the first response landed.
//
// Pre-Wave-3 this view open-coded the encode + enqueue + optimistic
// apply (see `applyOptimisticLocalUpdate` in the git history). The
// repository now owns all three so every iOS write goes through one
// contract — see `docs/M45-write-coordinator.md`.
//
// What this view deliberately does NOT do:
//   * Tag editor — tags ride along inside `content` via `#hashtag`
//     syntax; a dedicated tag editor is M43 polish.
//   * Recurrence editor — `NoteUpdate` on the server has no recurrence
//     field today; M40 spec calls this out explicitly.
//   * Due time editor — same reason. The web dialog also doesn't ship
//     time editing.
//   * Convert-to-appointment — server has a separate `/notes/{id}/
//     convert` endpoint that the queue doesn't yet model.

import SwiftData
import SwiftUI

/// Title/notes split helpers and tag extraction for `EditTodoView`.
/// Extracted from the view so the struct body stays under swiftlint's
/// `type_body_length` warning, and so the debug round-trip checks
/// (`EditDialogChecks.swift`) can call them via a stable namespace
/// without depending on view-state.
///
/// Why an enum-as-namespace instead of a free function: keeps the
/// related helpers grouped, lets us mark the type with `@MainActor`
/// only on the methods that need it, and reads cleanly at the call
/// site (`TodoContentText.split(...)` rather than a bare global).
enum TodoContentText {

    /// Split a server-stored `content` string into a (title, notes)
    /// pair. Mirrors `splitContent` in
    /// `web/src/components/todo-edit-dialog.tsx` so titles round-trip
    /// the same way across both clients.
    static func split(_ content: String, fallbackTitle: String?) -> (title: String, notes: String) {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let title: String
        if !firstLine.isEmpty {
            title = firstLine
        } else if let fallback = fallbackTitle, !fallback.isEmpty {
            title = fallback
        } else {
            title = ""
        }
        let restJoined: String
        if lines.count > 1 {
            restJoined = lines.dropFirst().joined(separator: "\n")
        } else {
            restJoined = ""
        }
        // Strip the leading blank-line separator the web dialog
        // inserts between title and notes — without this, every
        // round-trip would accumulate an extra newline.
        var trimmed = restJoined
        while trimmed.hasPrefix("\n") {
            trimmed.removeFirst()
        }
        return (title: title, notes: trimmed)
    }

    /// Inverse of `split`. Web inserts a blank separator line between
    /// title and notes; we match that so the round-trip is a no-op
    /// when the user doesn't change anything.
    static func join(title: String, notes: String) -> String {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes.isEmpty {
            return title
        }
        return "\(title)\n\n\(trimmedNotes)"
    }

    /// Extract `#hashtag` tokens from a free-form string. Preserves
    /// first-seen order, lowercases for case-insensitive dedupe.
    /// Mirrors the web's tag-extraction regex (word chars + dashes).
    static func extractTags(from combined: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        let pattern = "#([A-Za-z0-9_-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(combined.startIndex..., in: combined)
        regex.enumerateMatches(in: combined, range: range) { match, _, _ in
            guard
                let match = match,
                let captureRange = Range(match.range(at: 1), in: combined)
            else { return }
            let tag = String(combined[captureRange]).lowercased()
            if seen.insert(tag).inserted {
                ordered.append(tag)
            }
        }
        return ordered
    }
}

@MainActor
struct EditTodoView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.noteRepository) private var noteRepository

    /// The todo being edited. `@Bindable` so the optimistic local
    /// updates we apply on Save flow back through SwiftUI's render
    /// without us having to re-fetch.
    @Bindable var note: LocalNote

    // MARK: - Form state
    //
    // Each field is mirrored into `@State` on appear. We don't bind
    // SwiftUI controls directly to `note.content` etc. because (a) we
    // want a Cancel button that doesn't persist anything, and (b) the
    // local note's content is a single string we have to split into
    // title + notes for the UI and rejoin on Save.

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var dueDate: String = ""
    @State private var priority: String = "medium"
    /// Project id, or `"inbox"` for "no project". Matches the
    /// server's sentinel — see `NoteUpdate.project` in
    /// `brain/src/brain/schemas.py`.
    @State private var projectId: String = "inbox"
    @State private var sectionSlug: String = "now"
    @State private var url: String = ""

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    /// All non-archived projects, used to populate the Project picker
    /// and resolve the section picker's options. We hoist the @Query
    /// here (rather than in the row dropdown) so a fresh edit-dialog
    /// open always sees the latest project list.
    @Query(
        filter: #Predicate<LocalProject> { !$0.archived },
        sort: [SortDescriptor(\LocalProject.sortOrder), SortDescriptor(\LocalProject.name)]
    )
    private var projects: [LocalProject]

    // MARK: - Derived

    /// Tags extracted from the current `notes` field, plus any inline
    /// hashtags in the title. Read-only — editing tags as discrete
    /// pills is M43 polish.
    private var extractedTags: [String] { TodoContentText.extractTags(from: title + "\n" + notes) }

    /// Section options for the currently-selected project. Falls back
    /// to the canonical Now/Next/Later trio when no project is picked
    /// (matches the web dialog's behaviour).
    private var sectionOptions: [(slug: String, name: String)] {
        if projectId == "inbox" {
            return defaultSectionOptions
        }
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return defaultSectionOptions
        }
        let sorted = project.sections.sorted { $0.position < $1.position }
        if sorted.isEmpty {
            return defaultSectionOptions
        }
        return sorted.map { (slug: $0.slug, name: $0.name) }
    }

    private var defaultSectionOptions: [(slug: String, name: String)] {
        SectionView.Spec.defaults.map { (slug: $0.slug, name: $0.name) }
    }

    /// Submit-eligibility — title must be non-empty after trimming, and
    /// we can't double-submit while a save is already in flight.
    private var canSave: Bool {
        !isSaving && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Init

    init(note: LocalNote) {
        self.note = note
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                schedulingSection
                organisationSection
                linkSection
                tagsSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(!canSave)
                    // Tier 2 e2e harness hook.
                    .accessibilityIdentifier("edit-todo.save-button")
                }
            }
            .onAppear { hydrateFromNote() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var contentSection: some View {
        Section("Content") {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.next)
                // Tier 2 e2e harness hook.
                .accessibilityIdentifier("edit-todo.title-field")
            TextField(
                "Notes (optional). Markdown supported.",
                text: $notes,
                axis: .vertical
            )
            .lineLimit(4...12)
            .font(.callout.monospaced())
        }
    }

    @ViewBuilder
    private var schedulingSection: some View {
        Section("Schedule") {
            // Free-text due date — mirrors the web. Server accepts
            // `today`, `tomorrow`, `yyyy-MM-dd`, and the literal
            // `"none"` to clear an existing date.
            TextField("today, tomorrow, 2026-05-12", text: $dueDate)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("Priority", selection: $priority) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var organisationSection: some View {
        Section("Project") {
            Picker("Project", selection: $projectId) {
                Text("— Inbox —").tag("inbox")
                ForEach(projects, id: \.id) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: projectId) { _, _ in
                // Cascading picker: when project changes, snap section
                // back to the first option of the new project's
                // section list. Otherwise the user could end up with
                // a stale slug that the server rejects.
                let options = sectionOptions
                if !options.contains(where: { $0.slug == sectionSlug }) {
                    sectionSlug = options.first?.slug ?? "now"
                }
            }

            // Section picker — segmented when there are <=4 sections
            // (most projects), menu when more so the segmented control
            // doesn't get cramped.
            if sectionOptions.count <= 4 {
                Picker("Section", selection: $sectionSlug) {
                    ForEach(sectionOptions, id: \.slug) { opt in
                        Text(opt.name).tag(opt.slug)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("Section", selection: $sectionSlug) {
                    ForEach(sectionOptions, id: \.slug) { opt in
                        Text(opt.name).tag(opt.slug)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        Section {
            TextField("https://github.com/org/repo/pull/123", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("URL")
        } footer: {
            Text("GitHub PRs and issues auto-resolve to title and state on the server.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        Section {
            if extractedTags.isEmpty {
                Text("Add #hashtags inside the notes to tag this todo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips {
                    ForEach(extractedTags, id: \.self) { tag in
                        QuickAddChip(
                            symbol: "number",
                            text: tag,
                            tint: BrainColors.emerald.color
                        )
                    }
                }
            }
        } header: {
            Text("Tags")
        }
    }

    // MARK: - Hydrate

    /// Copy the note's current state into the form fields. Called from
    /// `.onAppear` rather than via init-time defaults so reopening the
    /// dialog after a sync picks up the freshest values.
    private func hydrateFromNote() {
        let split = TodoContentText.split(note.content, fallbackTitle: note.title)
        title = split.title
        notes = split.notes
        dueDate = note.dueDate ?? ""
        priority = note.priority
        projectId = note.projectId ?? "inbox"
        sectionSlug = note.section ?? "now"
        url = note.url ?? ""
    }

    // MARK: - Save

    /// Build a typed `NoteUpdateFields` from the form state and hand it
    /// to `NoteRepository.update(...)`. The repository owns the
    /// optimistic apply, the wire encode, and the queue enqueue (spec
    /// §6.1) — this view never touches `mutationQueue` or
    /// `modelContext` directly.
    ///
    /// We do NOT wait for the queue replay to complete before
    /// dismissing. The replay is fire-and-forget per M37 / M45 Wave 1 —
    /// the user's optimistic UI is correct, and a slow server shouldn't
    /// pin them in the dialog. The repository's response reconcile
    /// (M45 Wave 3, spec §4.3) brings down the server's authoritative
    /// fields under the LWW guard once the round-trip lands.
    ///
    /// Field diff: only fields that diverge from the live `LocalNote`
    /// are populated. The server is forgiving on missing keys, but
    /// narrowing the surface keeps the queue payload small and reduces
    /// the chance of accidentally overwriting a field some other client
    /// just changed.
    private func save() async {
        guard canSave else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedContent = TodoContentText.join(title: trimmedTitle, notes: notes)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields = NoteUpdateFields()
        if combinedContent != note.content {
            fields.content = combinedContent
        }
        // Title: send the (possibly empty) title as a separate hint —
        // the server keeps the explicit title alongside `content`. We
        // always send it when changed so a clear of the title actually
        // sticks.
        let originalTitle = (note.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle != originalTitle {
            fields.title = trimmedTitle
        }
        // Due date: the literal string "none" clears the field, per
        // server convention (and `NoteUpdateFields.dueDate` doc-comment).
        // An empty string from the user means the same thing — translate
        // to "none" so the wire shape is explicit.
        let trimmedDue = dueDate.trimmingCharacters(in: .whitespaces)
        let normalisedDue = trimmedDue.isEmpty ? "none" : trimmedDue
        let originalDue = (note.dueDate ?? "").trimmingCharacters(in: .whitespaces)
        if (originalDue.isEmpty && normalisedDue != "none") ||
           (!originalDue.isEmpty && normalisedDue != originalDue) {
            fields.dueDate = normalisedDue
        }
        if priority != note.priority {
            fields.priority = priority
        }
        let currentProject = note.projectId ?? "inbox"
        if projectId != currentProject {
            fields.projectId = projectId
        }
        if sectionSlug != (note.section ?? "now") {
            fields.section = sectionSlug
        }
        let currentURL = (note.url ?? "")
        if trimmedURL != currentURL {
            // Empty string explicitly clears server-side per
            // `NoteUpdateFields.url` convention.
            fields.url = trimmedURL
        }

        // Nothing changed — short-circuit the save so we don't enqueue
        // an empty PUT. Saves a wasted round-trip and keeps the queue
        // tidy.
        if isFieldsEmpty(fields) {
            dismiss()
            return
        }

        guard let repo = noteRepository else {
            errorMessage = "Note repository unavailable. Try again."
            return
        }

        isSaving = true
        defer { isSaving = false }

        repo.update(note, fields)
        // M43: medium haptic on a committed multi-field save. Stronger
        // than the M36 toggle haptic (which is `.light`) because the
        // user just typed and chose; the heavier tap reinforces the
        // "yes, this stuck" signal.
        BrainHaptics.medium()
        dismiss()
    }

    /// True if the diff has no fields set — every field is nil. We
    /// don't want to enqueue a PUT with an empty body when the user
    /// opened the dialog, made no changes, and hit Save.
    private func isFieldsEmpty(_ fields: NoteUpdateFields) -> Bool {
        fields.content == nil && fields.title == nil && fields.dueDate == nil &&
        fields.priority == nil && fields.projectId == nil && fields.section == nil &&
        fields.url == nil && fields.startTime == nil && fields.endTime == nil &&
        fields.location == nil
    }
}

// Debug-only sanity checks live in `EditDialogChecks.swift` (DEBUG
// builds only). Splitting them out keeps this file focused on the
// user-facing dialog and avoids tripping swiftlint's `file_length`.
