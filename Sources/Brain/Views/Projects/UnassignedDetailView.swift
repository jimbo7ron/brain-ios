// UnassignedDetailView.swift
// brain-ios
//
// Detail surface for the synthetic "Unassigned" virtual project.
// Mirrors `web/src/app/projects/[id]/page.tsx` lines 30-33, where the
// route param `unassigned` is special-cased to render todos with no
// `project_id`. The brain server treats the same string as a sentinel
// for `WHERE project_id IS NULL` (`src/brain/server.py:1722-1723,
// 1751`), so the iOS surface stays in sync with the same backing
// store the web exposes.
//
// Why a separate view (rather than reusing `ProjectDetailView` with a
// nullable project arg)?
//   1. There's no `LocalProject` to bind — the row's data is "the
//      complement of all projects", which a `@Query` filter expresses
//      naturally but a `@Bindable var project` cannot.
//   2. Unassigned doesn't have user-defined sections. The web renders
//      it as a single flat list, so we do the same here — no Now /
//      Next / Later split, no per-section "+" affordances. The
//      simpler shape reads better on a phone.
//   3. There's nothing to *edit* about the virtual project itself
//      (no name, no color, no sections), so the toolbar drops the
//      Edit button that `ProjectDetailView` carries. The long-press
//      Archive / Edit menu is also absent on the sidebar row — see
//      `ProjectListView.UnassignedRow`.
//
// Add affordance: a "+ Add to Unassigned" button presents
// `QuickAddView` with `projectID: "unassigned"`, threading the
// sentinel through to the server's create path so the new todo lands
// with NULL `project_id`. Edit / complete on existing rows continue
// to work via the M40 dialog and M36 toggle.

import SwiftData
import SwiftUI

@MainActor
struct UnassignedDetailView: View {

    @Environment(\.syncEngine) private var syncEngine
    /// M45 Wave 2: inline-add now goes through `NoteRepository`. The
    /// repository owns the optimistic insert + queue enqueue, so the
    /// new row lands in the list instantly. The `\.brainAPIClient`
    /// env-key was removed alongside the migration — no other code
    /// path in this view used it.
    @Environment(\.noteRepository) private var noteRepo

    /// All todos in the working set, narrowed to type `"todo"` only at
    /// the SwiftData layer. We then filter for `!archived` and
    /// `projectId == nil` in Swift to avoid the type-checker timeout
    /// that hits multi-condition `#Predicate` macros with optionals
    /// (the macro chokes on 3+ conditions when one operand is an
    /// `Optional` field). Sort is applied in Swift too so the
    /// predicate stays trivial.
    @Query(filter: UnassignedDetailView.todoPredicate)
    private var todosRaw: [LocalNote]

    /// Minimal predicate the SwiftData macro can compile in
    /// reasonable time. Anything more is filtered in Swift below.
    private static let todoPredicate: Predicate<LocalNote> = #Predicate { note in
        note.type == "todo"
    }

    /// All non-archived todos with no `project_id`, sorted by the
    /// user's manual ordering then by `createdAt` (stable tiebreak)
    /// — matches `ProjectDetailView.todos` so the two surfaces feel
    /// like siblings.
    private var todos: [LocalNote] {
        todosRaw
            .filter { !$0.archived && $0.projectId == nil }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                // `createdAt` is optional on the schema (rows synced
                // before the field was added). Treat missing values as
                // `.distantPast` so they sort to the bottom — matches
                // the convention `ProjectDetailView.completedTodos`
                // uses for `completedAt`.
                return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
            }
    }

    /// Transient inline-add error surfaced as a banner above the list.
    /// Cleared on the next successful submit. Same shape
    /// `ProjectDetailView` carries.
    @State private var inlineAddError: String?

    /// Tracks whether the "Done (N)" tray is expanded. Defaults to
    /// collapsed — same default `ProjectDetailView` carries — so the
    /// user lands on a focused open-todo list.
    @State private var isDoneExpanded: Bool = false

    private var openTodos: [LocalNote] { todos.filter { !$0.completed } }
    private var doneTodos: [LocalNote] {
        // Sort completed by `completedAt` desc so most-recently
        // ticked sits on top — same shape `SectionView.completedTodos`
        // uses for project sections.
        todos
            .filter { $0.completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var totalCount: Int { todos.count }
    private var openCount: Int { openTodos.count }
    private var doneCount: Int { doneTodos.count }

    /// Neutral grey accent, matching the sidebar row. Unassigned has
    /// no `LocalProject.color` to sample, so we deliberately render
    /// rows in the same secondary tint to read as "system bucket"
    /// rather than "user-coloured project".
    private var accentColor: Color { .secondary }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
            }

            if let inlineAddError {
                Section {
                    Text(inlineAddError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("unassigned.inline-add.error")
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                if openTodos.isEmpty {
                    EmptySectionLine(text: "Nothing here yet.")
                } else {
                    ForEach(openTodos, id: \.id) { note in
                        TodoRow(note: note, accentColor: accentColor)
                    }
                }

                // Inline add — same affordance `ProjectDetailView`
                // gets per-section. Replaces the M44 sheet-based
                // button so the user can capture rapidly without
                // summoning a sheet for one line of text.
                InlineAddRow(
                    placeholder: "Add to Inbox",
                    accessibilityIdentifier: "unassigned.inline-add",
                    onCommit: { rawText in
                        createTodoInline(content: rawText)
                    }
                )
            } header: {
                openSectionHeader
            }

            if !doneTodos.isEmpty {
                Section {
                    if isDoneExpanded {
                        ForEach(doneTodos, id: \.id) { note in
                            TodoRow(note: note, accentColor: accentColor)
                        }
                    }
                } header: {
                    DoneTrayHeader(
                        count: doneTodos.count,
                        isExpanded: $isDoneExpanded
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        // Density pass: mirror `ProjectDetailView`. `.compact` section
        // spacing trims the inter-section gutter, and the lower row
        // min-height lets the inline-add row + done-tray header read
        // as compact chrome rather than full-height entries.
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            // PTR pulls the freshly-created row through the sync
            // pipeline so it appears in the list without waiting for
            // the 5-min foreground Timer. Mirrors the PTR treatment
            // on `ProjectListView` and `TodayView`.
            if let syncEngine {
                await syncEngine.sync()
                BrainHaptics.light()
            } else {
                assertionFailure("syncEngine should be injected")
            }
        }
    }

    // MARK: - Header

    /// Header summary line below the navigation title — same shape
    /// `ProjectDetailView` uses ("X open · Y done · Z total") so the
    /// two surfaces read as siblings. No color dot — see
    /// `accentColor`.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: BrainSymbols.inbox)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerSummary: String {
        "\(openCount) open · \(doneCount) done · \(totalCount) total"
    }

    // MARK: - Inline add

    /// Create a todo from inline-add text in the Unassigned bucket.
    /// Threads the `"unassigned"` sentinel through as the `project`
    /// field — the server resolves this to `project_id = NULL` on
    /// insert (`src/brain/server.py:1858, 2032-2044`); the
    /// `NoteRepository` mirrors that locally by storing `nil` for
    /// `projectId` so the new row lands in this Unassigned bucket's
    /// `@Query` (which filters on `projectId == nil`).
    ///
    /// M45 Wave 2: hands off to `NoteRepository.create(_:)` instead of
    /// the original `await client.createNote(...)` round-trip.
    private func createTodoInline(content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let parsed = QuickAddParser.parse(trimmed)
        let bodyContent = parsed.title.isEmpty ? trimmed : parsed.bodyForServer()

        let payload = CreateNotePayload(
            content: bodyContent,
            title: nil,
            type: "todo",
            dueDate: parsed.dueDateISO(),
            dueTime: parsed.dueTimeHHMM(),
            priority: parsed.priority?.rawValue,
            recurrence: parsed.recurrence?.rawValue,
            project: ProjectListView.unassignedProjectID,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        guard let noteRepo else {
            // Preview / non-production host. Production wires the
            // repository in `BrainApp.init`.
            inlineAddError = "Couldn't add — try again."
            BrainHaptics.error()
            return
        }

        _ = noteRepo.create(payload)
        inlineAddError = nil
        BrainHaptics.light()
    }

    /// Open-section header. Matches the visual cadence of
    /// `ProjectSectionHeader` (icon + uppercased label + open/total
    /// count) so the row above the list reads as a section header
    /// rather than a vague label.
    private var openSectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: BrainSymbols.inbox)
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Open")
                .font(.caption2.bold())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(openCount)/\(totalCount)")
                .font(.caption2.weight(.regular))
                .foregroundStyle(.secondary.opacity(0.7))
                .monospacedDigit()
        }
    }
}

// No #Preview — UnassignedDetailView relies on a SwiftData
// `@Query` which needs a `modelContainer` injected by the host
// scene. Mirrors `ProjectDetailView`, which also omits a preview
// for the same reason.
