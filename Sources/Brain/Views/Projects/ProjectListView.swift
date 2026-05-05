// ProjectListView.swift
// brain-ios
//
// M35 — replaces the M34 `ProjectsPlaceholderView` with the real
// project picker. Mirrors the web sidebar (`web/src/app/layout.tsx`)
// for the list shape and feeds into `ProjectDetailView`, which
// mirrors `web/src/app/projects/[id]/page.tsx`.
//
// Adaptive chrome: this view is built around `NavigationSplitView`
// rather than `NavigationStack`, so on iPad we get a sidebar +
// detail pane out of the box and on iPhone the same view collapses
// to a push-stack. The roadmap calls for "Sidebar drawer (iPad) /
// sheet (iPhone)" — `NavigationSplitView` lands the iPad half
// directly; the iPhone half is the natural collapsed form, which is
// the SwiftUI-canonical way to render a master/detail flow on a
// phone (a true "sheet" would conflict with the surrounding TabView
// chrome owned by `SignedInRootView`).
//
// Data: `@Query` on `LocalProject` filtered to `archived == false`,
// sorted by the server-provided `sortOrder`. SwiftData drives the
// re-render whenever the M33 sync engine writes a new batch — no
// extra plumbing required.
//
// Long-press: per spec, the context menu on each row exposes
// Archive / Edit *as disabled placeholders*. M40 wires them up.

import SwiftData
import SwiftUI

@MainActor
struct ProjectListView: View {

    @Environment(\.syncEngine) private var syncEngine

    /// All non-archived projects, ordered by the server's `sortOrder`.
    /// `@Query` re-runs whenever SwiftData publishes a change, so the
    /// list refreshes immediately after the next sync writes a new
    /// project or flips an archived flag.
    @Query(
        filter: #Predicate<LocalProject> { !$0.archived },
        sort: [SortDescriptor(\LocalProject.sortOrder), SortDescriptor(\LocalProject.name)]
    )
    private var projects: [LocalProject]

    /// All open todos that belong to *some* project. Hoisted at the
    /// parent so each `ProjectRow` doesn't have to run its own
    /// `@Query` — same pattern the M34 Today view uses to avoid
    /// per-row SwiftData lookups.
    @Query(
        filter: #Predicate<LocalNote> {
            $0.type == "todo"
                && $0.completed == false
                && $0.archived == false
                && $0.projectId != nil
        }
    )
    private var openProjectTodos: [LocalNote]

    /// `projectId` → open-todo count. Rebuilt per render — cheap
    /// (linear scan over a small list) and SwiftUI's diffing means
    /// rows whose count didn't change skip re-rendering.
    private var openCountsByProjectID: [String: Int] {
        var counts: [String: Int] = [:]
        for note in openProjectTodos {
            guard let projectID = note.projectId else { continue }
            counts[projectID, default: 0] += 1
        }
        return counts
    }

    /// Drives the iPad split layout. We hold the selection in a
    /// `@State` rather than `@SceneStorage` because (a) the value is a
    /// `LocalProject.id` string the server can change, and (b) the
    /// selection should reset when the user signs out and back in.
    /// Selection is bound to `LocalProject.id` (a stable server UUID)
    /// rather than the model object itself so SwiftData re-fetches in
    /// the detail pane don't drop the selection.
    @State private var selectedProjectID: String?

    /// The project being edited via the M40 long-press → Edit flow,
    /// or nil when the sheet is dismissed. We use the
    /// `sheet(item:)` form (not `isPresented`) so SwiftUI rebuilds the
    /// sheet body whenever a different row is targeted — that's the
    /// shape that lets a single sheet host serialise across all rows
    /// without per-row state.
    @State private var projectToEdit: LocalProject?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        // `.balanced` keeps the sidebar visible alongside the detail
        // on iPad in landscape; on iPhone the split collapses to a
        // push-stack regardless of this value, so it's a no-op there.
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedProjectID) {
            if projects.isEmpty {
                EmptyProjectListView()
                    // Hide the row separator + selection chrome so the
                    // empty-state copy reads as a static message rather
                    // than a (selectable) list row.
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            } else {
                ForEach(projects) { project in
                    NavigationLink(value: project.id) {
                        ProjectRow(
                            project: project,
                            openTodoCount: openCountsByProjectID[project.id] ?? 0
                        )
                    }
                    .contextMenu {
                        // M40 — long-press → Edit lands the
                        // edit-project dialog. Archive remains a
                        // placeholder (M41 wires `MutationOp.archive
                        // Project` end-to-end).
                        Button {
                            // M41: archive flow
                        } label: {
                            Label("Archive", systemImage: BrainSymbols.archive)
                        }
                        .disabled(true)

                        Button {
                            projectToEdit = project
                        } label: {
                            Label("Edit", systemImage: BrainSymbols.edit)
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .sheet(item: $projectToEdit) { project in
            EditProjectView(project: project)
        }
        .navigationDestination(for: String.self) { projectID in
            // Resolve the id back into the live `LocalProject` so the
            // detail view can subscribe to changes via `@Bindable` /
            // `@Query`. We look up by id rather than threading the
            // model object through `NavigationLink(value:)` because
            // `@Query` results can churn under us — the id is the
            // stable handle.
            if let project = projects.first(where: { $0.id == projectID }) {
                ProjectDetailView(project: project)
            } else {
                // Project disappeared (archived elsewhere, deleted,
                // sync tombstone) — show a graceful fallback rather
                // than crashing. The user can pop back to the list.
                ContentUnavailableView(
                    "Project unavailable",
                    systemImage: "folder.badge.questionmark",
                    description: Text("This project is no longer available. Pull to refresh.")
                )
            }
        }
        .refreshable {
            // PTR triggers an explicit sync. SyncEngine debounces, so
            // a tap-spammer can't pile up overlapping requests.
            if let syncEngine {
                await syncEngine.sync()
                // M43: light haptic on PTR completion. Mirrors the
                // TodayView treatment so the two pull-to-refresh
                // surfaces feel identical to the user.
                BrainHaptics.light()
            } else {
                assertionFailure("syncEngine should be injected")
            }
        }
    }

    // MARK: - Detail (iPad)

    /// Detail-pane content shown on iPad when no project is selected.
    /// On iPhone the user always lands on the sidebar first, so this
    /// branch is only reachable on regular-width layouts.
    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedProjectID,
           let project = projects.first(where: { $0.id == id }) {
            ProjectDetailView(project: project)
        } else {
            ContentUnavailableView {
                Label("Pick a project", systemImage: "folder")
            } description: {
                Text("Select a project from the sidebar to see its sections.")
            }
        }
    }
}

/// Empty-state copy for the project list. Mirrors the web sidebar:
/// "No projects yet — hit + to create one." iOS doesn't yet have a
/// project-create affordance (M40 ships *edit* only — create lands in
/// a follow-up), so we point the user at the web in the meantime.
struct EmptyProjectListView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No projects yet.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Create one on the web — project creation on iOS is coming soon.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    ProjectListView()
}
