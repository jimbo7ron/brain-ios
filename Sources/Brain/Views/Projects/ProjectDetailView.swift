// ProjectDetailView.swift
// brain-ios
//
// M35 — project detail surface. Mirrors `web/src/app/projects/[id]/
// page.tsx` + `web/src/components/section-block.tsx`:
//
//   * Header with the color dot, project name, and open/done counts.
//   * One block per section (`now` / `next` / `later`, plus any
//     server-defined custom slugs from M26).
//   * Each block lists the section's open todos, then a collapsible
//     "Done (N)" tray. Per spec the tray defaults to **collapsed**.
//
// Data strategy: a single `@Query` for "todos belonging to this
// project" rather than one query per section. SwiftData's
// `#Predicate` macro can't easily express a per-section filter
// keyed off a captured `[String]` of section slugs, and the dataset
// is personal-app scale (per-project todo lists are small). We
// partition into buckets in Swift, the same way the web does
// (`for (const n of todos) { grouped[n.todo.section].push(n) }`).
//
// The captured `projectId` flows into the predicate via the row's
// init, mirroring the pattern from `ProjectRow`.

import SwiftData
import SwiftUI

@MainActor
struct ProjectDetailView: View {

    /// M45 Wave 2: inline-add now goes through `NoteRepository` rather
    /// than the direct `await client.createNote(...)` round-trip this
    /// view shipped with. The repository owns the optimistic local
    /// insert + queue enqueue, so the new row appears in the section
    /// instantly instead of waiting for the network. The
    /// `\.brainAPIClient` and `\.syncEngine` env-keys were removed
    /// alongside the migration — no other code path in this view used
    /// them.
    @Environment(\.noteRepository) private var noteRepo

    /// The project this view describes. Bindable so SwiftData
    /// updates from the sync engine flow through without us having
    /// to re-fetch.
    @Bindable var project: LocalProject

    /// All non-archived todos belonging to this project, completed or
    /// not. We sort by `sortOrder` (the user's manual ordering) and
    /// then by `createdAt` (stable tiebreak so render order is
    /// deterministic across sync passes).
    @Query private var todos: [LocalNote]

    /// Tracks which sections have their "Done (N)" tray expanded.
    /// Sections are absent by default → collapsed (matches the web's
    /// `useState(false)` per section).
    @State private var expandedDoneSlugs: Set<String> = []

    /// Drives the M40 edit-project sheet. Toolbar Edit button toggles
    /// this; the sheet hosts `EditProjectView` bound to the same
    /// `@Bindable` project so optimistic edits flow through SwiftUI
    /// without a re-fetch.
    @State private var isEditPresented: Bool = false

    /// Transient inline-add error surfaced as a banner above the list.
    /// Cleared on the next successful submit. We don't gate on
    /// per-section error state because the user is only typing into
    /// one field at a time; a single banner reads cleaner than a
    /// red row buried inside a section.
    @State private var inlineAddError: String?

    init(project: LocalProject) {
        self.project = project
        // Type-check shortcut: a 3-condition AND inside `#Predicate`
        // with an optional `projectId` exhausts the constraint solver
        // under Xcode 26 (per the swiftc-parse-insufficient feedback
        // note). Pin the optional to a typed local + use `!archived`
        // instead of `== false`, then split predicate / sort out so
        // each piece type-checks in isolation.
        let projectID: String? = project.id
        let predicate = #Predicate<LocalNote> { note in
            note.type == "todo" && !note.archived && note.projectId == projectID
        }
        let sortDescriptors: [SortDescriptor<LocalNote>] = [
            SortDescriptor(\.sortOrder),
            SortDescriptor(\.createdAt),
        ]
        _todos = Query(filter: predicate, sort: sortDescriptors)
    }

    // MARK: - Derived state

    /// Sections in `position` order. If the server hasn't sent any
    /// (legacy projects predating M26 customisation), we fall back to
    /// the canonical default trio so the UI never renders an empty
    /// project — matches `DEFAULT_SECTIONS` on the web.
    private var orderedSections: [SectionView.Spec] {
        if project.sections.isEmpty {
            return SectionView.Spec.defaults
        }
        return project.sections
            .sorted { $0.position < $1.position }
            .map { SectionView.Spec(slug: $0.slug, name: $0.name) }
    }

    /// Bucketed by section slug. Notes whose section slug isn't in
    /// the project's section list (stale from before a section was
    /// renamed) get bucketed under the first section, mirroring the
    /// `fallback = sections[0]?.slug ?? "now"` rule on the web.
    private var todosBySection: [String: [LocalNote]] {
        var grouped: [String: [LocalNote]] = [:]
        for spec in orderedSections {
            grouped[spec.slug] = []
        }
        let fallbackSlug = orderedSections.first?.slug ?? "now"
        for note in todos {
            let slug = note.section ?? fallbackSlug
            if grouped[slug] != nil {
                grouped[slug]?.append(note)
            } else {
                grouped[fallbackSlug, default: []].append(note)
            }
        }
        return grouped
    }

    private var totalCount: Int { todos.count }
    private var doneCount: Int { todos.filter { $0.completed }.count }
    private var openCount: Int { totalCount - doneCount }

    /// Resolved accent color for the project header dot. Same lookup
    /// as `ProjectRow.dotColor`.
    private var headerDotColor: Color {
        guard let css = project.color else { return .accentColor }
        if let match = BrainColors.palette.first(where: { $0.cssValue == css }) {
            return match.color
        }
        return .accentColor
    }

    // MARK: - View

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
                        .accessibilityIdentifier("project.inline-add.error")
                        .listRowSeparator(.hidden)
                }
            }

            ForEach(orderedSections, id: \.slug) { spec in
                SectionView(
                    spec: spec,
                    todos: todosBySection[spec.slug] ?? [],
                    accentColor: headerDotColor,
                    isDoneTrayExpanded: Binding(
                        get: { expandedDoneSlugs.contains(spec.slug) },
                        set: { newValue in
                            if newValue {
                                expandedDoneSlugs.insert(spec.slug)
                            } else {
                                expandedDoneSlugs.remove(spec.slug)
                            }
                        }
                    ),
                    onInlineAdd: { rawText in
                        createTodoInline(
                            content: rawText,
                            sectionSlug: spec.slug
                        )
                    }
                )
            }

            if openCount == 0 {
                // Project-wide empty state. The web doesn't render an
                // explicit "all caught up" surface — it just shows the
                // sections empty — but on a phone the section bodies
                // collapse to a single "Nothing here" line and a
                // top-level affordance reads better.
                Section {
                    EmptyProjectStateView()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Density pass: collapse the inter-section gutter (`compact`
        // on iOS 17+) and drop the system default row min-height from
        // 44pt to 32pt. Combined with the per-row `.listRowInsets`
        // tightening on `TodoRow`, this knocks ~25-30% off the
        // vertical space each row occupies. Tap targets stay reachable
        // because hit-testing on a List row extends to the full row
        // area, not just the icon glyphs.
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // M40 — top-right Edit button mirrors the web project
            // header's pencil affordance. We could also have wired this
            // through the long-press menu in `ProjectListView`, but
            // that's a separate surface; users on the detail view
            // shouldn't have to back out to edit.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditPresented = true
                } label: {
                    Image(systemName: BrainSymbols.edit)
                }
                .accessibilityLabel("Edit project")
            }
        }
        .sheet(isPresented: $isEditPresented) {
            EditProjectView(project: project)
        }
    }

    // MARK: - Inline add

    /// Create a todo from inline-add text, scoped to `sectionSlug`. The
    /// text rides through `QuickAddParser` so trailing keywords
    /// ("tomorrow", "!high", "#tag") behave the same way they do in
    /// `QuickAddView.submit()`.
    ///
    /// M45 Wave 2: hands off to `NoteRepository.create(_:)` instead of
    /// the original `await client.createNote(...)` round-trip. The
    /// repository owns the optimistic insert + queue enqueue + status-
    /// store mark, so the new row appears in the section instantly and
    /// the SectionView's `@Query` re-renders before the user can blink.
    /// The `inlineAddError` banner is now only used for the
    /// preview/no-repo branch — production never reaches it.
    private func createTodoInline(content: String, sectionSlug: String) {
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
            project: project.id,
            section: sectionSlug,
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(headerDotColor)
                .frame(width: 14, height: 14)
                .padding(.top, 3)
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        .padding(.top, 3)
                )

            VStack(alignment: .leading, spacing: 4) {
                // Project name lives in the nav title (large) — this
                // line shows the count summary the web puts under the
                // header. Mirrors "X open · Y done · Z total".
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
}

// MARK: - Section

/// One section block. Mirrors the web's `SectionBlock` — header pill
/// (icon + name + counts), a list of open todos, then a collapsible
/// Done tray.
struct SectionView: View {

    /// Light spec carried into the view. We don't reach for
    /// `LocalSection` directly because (a) the project's sections
    /// might be the synthesised default trio and (b) SwiftUI is
    /// happier diffing value types in `ForEach`.
    struct Spec: Hashable {
        let slug: String
        let name: String

        /// Canonical default sections, matching `DEFAULT_SECTIONS` on
        /// the web. Used when a project hasn't customised its layout.
        static let defaults: [Spec] = [
            Spec(slug: "now", name: "Now"),
            Spec(slug: "next", name: "Next"),
            Spec(slug: "later", name: "Later"),
        ]
    }

    let spec: Spec
    let todos: [LocalNote]
    /// Project-level accent color, used as the fallback for
    /// custom-named sections (M26) where we don't have a built-in
    /// known color mapping.
    let accentColor: Color
    @Binding var isDoneTrayExpanded: Bool
    /// Invoked when the user submits inline-add text at the bottom of
    /// this section's open todos. The parent (`ProjectDetailView` /
    /// `UnassignedDetailView`) owns the project context, so it threads
    /// the project id + section slug onto the wire payload — the
    /// section block just hands up the raw user-typed text.
    var onInlineAdd: (String) -> Void

    private var openTodos: [LocalNote] { todos.filter { !$0.completed } }
    private var completedTodos: [LocalNote] {
        // Sort completed by `completedAt` desc so most-recently
        // ticked sits on top — same as the web's done tray feel.
        todos
            .filter { $0.completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Pick the icon for this section. The three known slugs
    /// (now/next/later) get their canonical SF Symbols; user-renamed
    /// or custom sections (M26) fall back to a neutral generic icon.
    private var sectionSymbol: String {
        switch spec.slug {
        case "now":   return BrainSymbols.now
        case "next":  return BrainSymbols.next
        case "later": return BrainSymbols.later
        default:      return "circle.fill"
        }
    }

    /// Section accent. Maps the three canonical slugs to the same
    /// CSS colors the web uses for `--section-now` (violet),
    /// `--section-next` (sky), `--section-later` (slate). Custom
    /// sections fall back to the project's own accent color so the
    /// rendering stays cohesive.
    private var sectionTint: Color {
        switch spec.slug {
        case "now":   return BrainColors.violet.color
        case "next":  return BrainColors.sky.color
        case "later": return BrainColors.slate.color
        default:      return accentColor
        }
    }

    var body: some View {
        Section {
            if openTodos.isEmpty && completedTodos.isEmpty {
                EmptySectionLine(text: "Nothing here yet.")
            } else {
                ForEach(openTodos, id: \.id) { note in
                    TodoRow(note: note, accentColor: accentColor)
                }
            }

            // Inline add row. Always rendered — including empty
            // sections — because that's the most useful place to tap.
            // Sits below the open todos and above the Done tray so
            // the affordance never gets pushed off-screen by a long
            // completed list. Replaces the M44-era sheet-based
            // affordance: the user types into the field directly and
            // submits with return; the field stays focused so they can
            // capture rapidly without dismissing the keyboard.
            InlineAddRow(
                placeholder: "Add to \(spec.name)",
                accessibilityIdentifier: "project.section.add.\(spec.name)",
                onCommit: onInlineAdd
            )

            if !completedTodos.isEmpty {
                DoneTrayHeader(
                    count: completedTodos.count,
                    isExpanded: $isDoneTrayExpanded
                )

                if isDoneTrayExpanded {
                    ForEach(completedTodos, id: \.id) { note in
                        TodoRow(note: note, accentColor: accentColor)
                    }
                }
            }
        } header: {
            ProjectSectionHeader(
                title: spec.name,
                symbol: sectionSymbol,
                tint: sectionTint,
                openCount: openTodos.count,
                totalCount: todos.count
            )
        }
    }
}

// MARK: - Inline add row

/// Inline add affordance at the bottom of each section. Shows a
/// placeholder text field that the user can tap straight into; on
/// return the text is handed up to the parent (which threads the
/// project id + section slug onto the wire payload) and the field
/// clears + re-focuses so the user can keep capturing without
/// dismissing the keyboard.
///
/// Replaces the M44-era `AddToSectionRow` button that opened a
/// `QuickAddView` sheet. The sheet still ships — it's the right
/// affordance for the global Today FAB, where there's no section
/// context — but for a user already scrolled to "Now" in a project,
/// summoning a sheet for one line of text is too much friction.
///
/// `QuickAddParser` still runs in the parent's commit handler, so
/// trailing keywords ("tomorrow", "!high", "#work") behave exactly the
/// same as in the sheet — only the surface changes.
struct InlineAddRow: View {

    let placeholder: String
    /// Accessibility identifier the parent assigns. Kept distinct from
    /// the placeholder so we can locate the row in UI tests without
    /// depending on the section name's localised form.
    let accessibilityIdentifier: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.callout)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(submit)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Halve the vertical row insets vs. the system default so the
        // inline-add line doesn't visually punch a 44pt hole in an
        // otherwise dense section. The text field's own intrinsic
        // height keeps the tap target large enough to land on.
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// Trim, guard against empty submits, hand up to the parent, then
    /// clear + re-focus so the user can keep typing the next todo
    /// without dismissing the keyboard. Empty / whitespace-only
    /// submits are a deliberate no-op — the user pressed return on an
    /// empty field, which usually means "I'm done capturing".
    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        text = ""
        focused = true
    }
}

// MARK: - Section header

/// Section header rendered above each block. Mirrors the M34
/// `TodaySectionHeader` shape so the iOS look stays consistent
/// across the Today + Project surfaces, but tuned for the
/// project-detail context (open/total count, no trailing note).
struct ProjectSectionHeader: View {

    let title: String
    let symbol: String
    let tint: Color
    let openCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(title)
                .font(.caption2.bold())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            // "open / total" — mirrors `{completed}/{total}` on the
            // web but flipped to lead with the actionable number.
            Text("\(openCount)/\(totalCount)")
                .font(.caption2.weight(.regular))
                .foregroundStyle(tint.opacity(0.7))
                .monospacedDigit()
        }
    }
}

// MARK: - Done tray header

/// Tappable "Done (N)" header. Collapsed by default; tapping toggles
/// the parent's binding which the section view uses to gate the
/// completed todos.
struct DoneTrayHeader: View {

    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: BrainSymbols.chevronRight)
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: BrainSymbols.checkmarkCircle)
                    .imageScale(.small)
                    .opacity(0.6)
                Text("\(count) completed")
                    .font(.caption2)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tighter row insets — the tray header is a ~12pt-tall caption,
        // so the system's 11pt vertical row inset more than doubles
        // the visual height. Drop to 4pt each side for a row that
        // reads as "header" rather than "another full-height entry".
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .accessibilityLabel(isExpanded ? "Hide \(count) completed" : "Show \(count) completed")
    }
}

// MARK: - Empty states

/// Rendered when a project has no open todos in any section.
struct EmptyProjectStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All caught up.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text("Nothing open in this project right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
