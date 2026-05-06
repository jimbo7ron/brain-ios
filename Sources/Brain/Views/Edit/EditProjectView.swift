// EditProjectView.swift
// brain-ios
//
// M40 — full edit dialog for an existing project. Mirrors the web's
// `web/src/components/edit-project-dialog.tsx`:
//
//   * Name (single-line)
//   * Colour (swatch picker drawn from `BrainColors.palette`)
//   * Sort order (numeric stepper, behind a disclosure)
//   * Sections — add + rename for M40. Delete and reorder defer to M43
//     polish (see PR description). The reasoning: section delete needs
//     a "move orphans to" picker UI to avoid stranding todos, and
//     reorder needs a drag-to-reorder list; both are non-trivial and
//     not on the M40 critical path.
//   * Archived toggle (sparingly used; tucked under Advanced).
//
// **Mutation routing (M45 Wave 3):**
// Project name / colour / sort_order metadata edits go through
// `ProjectRepository.update(project, fields)` — the repo owns the
// optimistic apply, the wire encode, and the queue enqueue
// (`.updateProject`) with `baseUpdatedAt` populated so M38's pull-side
// LWW conflict resolution can drop stale queue items if the web edits
// the same project mid-flight.
//
// The "archived" toggle still rides this dialog but routes through
// `projectRepo.archive(...)` / `projectRepo.unarchive(...)` to keep the
// soft-delete intent distinct from a metadata patch (spec §6.2).
//
// Section adds and renames go through DIRECT API calls (not the queue)
// because:
//   * The server's section endpoints are POST/PATCH at distinct
//     URLs — they don't fit the `MutationOp.updateProject` PUT shape.
//   * Wiring `MutationOp.addSection` end-to-end is M41 work; the spec
//     for M40 explicitly defers it.
//   * The optimistic local mutation is straightforward (we update the
//     project's `sections` array in SwiftData) and the surfaces stay
//     responsive even while the network round-trip is in flight.
//
// Section editing is therefore a hybrid: the field is editable but the
// user needs to be online for it to actually sync. M37/M38 still cover
// the project's name/colour/etc. correctly in the offline path.

import SwiftData
import SwiftUI

/// Editable representation of a project section, used in the local
/// state of `EditProjectView`. Distinct from `LocalSection` (the
/// SwiftData model) because the dialog tracks edits-in-progress that
/// haven't yet been persisted, and from `Section` (the wire DTO)
/// because we want a value type SwiftUI can diff in `ForEach`.
///
/// Also referenced by `BrainDebugEditDialogChecks.assertSectionSpec
/// Mutations` so the array-shape contract has a checked test target.
struct SectionMutationSpec: Hashable, Identifiable {
    let slug: String
    var name: String
    var position: Int

    var id: String { slug }
}

@MainActor
struct EditProjectView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.brainAPIClient) private var client
    /// M45 Wave 3: project-metadata edits route through the repo. The
    /// view no longer reaches into `\.mutationQueue` directly — the
    /// repository owns the optimistic apply + enqueue. Section adds /
    /// renames still use direct API calls (see file header).
    @Environment(\.projectRepository) private var projectRepository

    /// The project being edited. `@Bindable` so the optimistic local
    /// updates flow back through `@Query` subscribers without a
    /// re-fetch.
    @Bindable var project: LocalProject

    // MARK: - Form state

    @State private var name: String = ""
    @State private var selectedColorCSS: String?
    @State private var sortOrder: Int = 0
    @State private var archived: Bool = false
    @State private var showAdvanced: Bool = false

    /// Local snapshot of the project's sections. Edited optimistically;
    /// committed via direct API calls in `addSection(...)` and
    /// `renameSection(...)`.
    @State private var sections: [SectionMutationSpec] = []

    /// New-section input. Cleared on successful add.
    @State private var newSectionName: String = ""
    /// Slug currently being renamed (nil = none). Mirrors the web
    /// dialog's inline-rename UX.
    @State private var renamingSlug: String?
    @State private var renameDraft: String = ""

    @State private var isSaving: Bool = false
    @State private var isMutatingSection: Bool = false
    @State private var errorMessage: String?

    // MARK: - Init

    init(project: LocalProject) {
        self.project = project
    }

    // MARK: - Derived

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when the project's name / colour / sort_order / archived
    /// match the form state. Used to skip a no-op enqueue on Save.
    private var topLevelHasChanges: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != project.name { return true }
        if selectedColorCSS != project.color { return true }
        if sortOrder != project.sortOrder { return true }
        if archived != project.archived { return true }
        return false
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                colorSection
                sectionsBlock
                advancedSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit project")
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
                }
            }
            .onAppear { hydrateFromProject() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var nameSection: some View {
        Section("Name") {
            TextField("Project name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        Section("Colour") {
            // Lay out the 10-slot palette in a wrap-friendly grid via
            // FlowChips so iPhone widths still fit. Each swatch is a
            // tappable circle; the selected swatch gets a ring.
            FlowChips(spacing: 12) {
                ForEach(BrainColors.palette) { swatch in
                    Button {
                        selectedColorCSS = swatch.cssValue
                    } label: {
                        ZStack {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 28, height: 28)
                            Circle()
                                .stroke(
                                    selectedColorCSS == swatch.cssValue
                                        ? Color.primary
                                        : Color.secondary.opacity(0.25),
                                    lineWidth: selectedColorCSS == swatch.cssValue ? 2 : 0.5
                                )
                                .frame(width: 32, height: 32)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(
                        selectedColorCSS == swatch.cssValue ? .isSelected : []
                    )
                }
                Button {
                    selectedColorCSS = nil
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                            .frame(width: 28, height: 28)
                        Image(systemName: "slash.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No colour")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sectionsBlock: some View {
        Section {
            ForEach(sections) { spec in
                sectionRow(for: spec)
            }
            HStack(spacing: 8) {
                TextField("New section", text: $newSectionName)
                    .textInputAutocapitalization(.words)
                Button {
                    Task { await addSection() }
                } label: {
                    if isMutatingSection {
                        ProgressView()
                    } else {
                        Image(systemName: BrainSymbols.add)
                    }
                }
                .disabled(
                    isMutatingSection ||
                    newSectionName.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Sections")
        } footer: {
            Text("Add and rename for now. Reorder and remove are coming.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func sectionRow(for spec: SectionMutationSpec) -> some View {
        HStack {
            if renamingSlug == spec.slug {
                TextField("Section name", text: $renameDraft)
                    .submitLabel(.done)
                    .onSubmit { Task { await commitRename(spec.slug) } }
                Button {
                    Task { await commitRename(spec.slug) }
                } label: {
                    Image(systemName: BrainSymbols.checkmarkCircle)
                }
                .buttonStyle(.borderless)
                .disabled(
                    isMutatingSection ||
                    renameDraft.trimmingCharacters(in: .whitespaces).isEmpty
                )
                Button {
                    renamingSlug = nil
                    renameDraft = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            } else {
                Text(spec.name)
                Spacer()
                Text(spec.slug)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Button {
                    renamingSlug = spec.slug
                    renameDraft = spec.name
                } label: {
                    Image(systemName: BrainSymbols.edit)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename \(spec.name)")
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Stepper(
                    "Sort order: \(sortOrder)",
                    value: $sortOrder,
                    in: -100...100
                )
                Toggle("Archived", isOn: $archived)
            }
        }
    }

    // MARK: - Hydrate

    private func hydrateFromProject() {
        name = project.name
        selectedColorCSS = project.color
        sortOrder = project.sortOrder
        archived = project.archived
        sections = project.sections
            .sorted { $0.position < $1.position }
            .map { SectionMutationSpec(slug: $0.slug, name: $0.name, position: $0.position) }
    }

    // MARK: - Save (top-level fields)

    /// Build a typed `ProjectUpdateFields` and hand it to the
    /// repository. The repo applies the optimistic local mutation,
    /// encodes the wire payload, and enqueues `.updateProject`. The
    /// archived toggle, when changed, routes through the repo's
    /// dedicated archive/unarchive entry points so the soft-delete
    /// intent stays distinct from a metadata patch (spec §6.2).
    /// Section edits are NOT included here — they ride direct API
    /// calls from `addSection` / `commitRename` so the user gets
    /// per-row feedback as they go (Wave 4 will migrate them).
    private func save() async {
        guard canSave else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if !topLevelHasChanges {
            // No-op save. Dismiss without queuing.
            dismiss()
            return
        }

        guard let repo = projectRepository else {
            errorMessage = "Project repository unavailable. Try again."
            return
        }

        isSaving = true
        defer { isSaving = false }

        // Metadata diff — only fields that differ from the live row.
        // Empty `ProjectUpdateFields` is a no-op on the repo, but we
        // skip the call entirely when there's nothing AND no archive
        // flip to avoid an empty `.updateProject` enqueue.
        var fields = ProjectUpdateFields()
        if trimmedName != project.name {
            fields.name = trimmedName
        }
        if selectedColorCSS != project.color {
            // Server treats a missing key as "leave alone"; a non-nil
            // value (incl. empty string) is taken literally. The wire
            // encoder skips nil Optionals so passing `nil` here means
            // "leave alone", not "clear" — same semantic as before.
            fields.color = selectedColorCSS
        }
        if sortOrder != project.sortOrder {
            fields.sortOrder = sortOrder
        }
        let metadataChanged = fields.name != nil
            || fields.color != nil
            || fields.sortOrder != nil
        if metadataChanged {
            repo.update(project, fields)
        }

        // Archive flip is its own intent — route through the repo's
        // dedicated entry point so the soft-delete vs metadata-patch
        // distinction is visible at the call site (and so the future
        // hard-delete path can hook the same method).
        if archived != project.archived {
            if archived {
                repo.archive(project)
            } else {
                repo.unarchive(project)
            }
        }

        // M43: medium haptic mirrors EditTodoView — the dialog
        // committed a multi-field save and the user benefits from a
        // stronger tactile confirmation.
        BrainHaptics.medium()
        dismiss()
    }

    // MARK: - Section editing (direct API)

    /// Add a new section to the project. Direct call to the
    /// `POST /api/v1/projects/{id}/sections` endpoint — see the
    /// file-header comment for why this isn't on the queue today.
    private func addSection() async {
        let trimmed = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client else {
            errorMessage = "Server unavailable. Try again."
            return
        }

        isMutatingSection = true
        defer { isMutatingSection = false }
        errorMessage = nil

        do {
            let response = try await client.addProjectSection(
                projectId: project.id,
                name: trimmed
            )
            applyServerSections(response.sections)
            newSectionName = ""
        } catch let error as BrainAPIClient.Error {
            errorMessage = error.userFacingMessage
        } catch {
            errorMessage = "Couldn't add section: \(error.localizedDescription)"
        }
    }

    /// Commit a section rename. Direct call to
    /// `PATCH /api/v1/projects/{id}/sections/{slug}`. Slug is
    /// preserved server-side so any todos in the section stay
    /// attached.
    private func commitRename(_ slug: String) async {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client else {
            errorMessage = "Server unavailable. Try again."
            return
        }

        isMutatingSection = true
        defer { isMutatingSection = false }
        errorMessage = nil

        do {
            let response = try await client.renameProjectSection(
                projectId: project.id,
                slug: slug,
                name: trimmed
            )
            applyServerSections(response.sections)
            renamingSlug = nil
            renameDraft = ""
        } catch let error as BrainAPIClient.Error {
            errorMessage = error.userFacingMessage
        } catch {
            errorMessage = "Couldn't rename section: \(error.localizedDescription)"
        }
    }

    /// Reflect a server-returned `Project.sections` list into both the
    /// local @State (so the dialog UI updates) and the SwiftData
    /// `LocalProject.sections` (so other views observing it via
    /// `@Query` re-render). We don't wait for the next sync — the
    /// server's response IS the canonical view, so applying it
    /// immediately keeps the UI from looking stale.
    private func applyServerSections(_ wireSections: [SectionDTO]) {
        // Update local @State for the dialog.
        sections = wireSections
            .sorted { $0.position < $1.position }
            .map { SectionMutationSpec(slug: $0.slug, name: $0.name, position: $0.position) }

        // Mirror onto the SwiftData project so background views update.
        // Reuse the same logic shape as `SyncEngine.reconcileSections`
        // so this surface and the read path agree.
        let projectID = project.id
        let wantedIDs = Set(wireSections.map {
            LocalSection.makeID(projectID: projectID, slug: $0.slug)
        })
        for existing in project.sections where !wantedIDs.contains(existing.id) {
            modelContext.delete(existing)
        }
        let currentBySlug = Dictionary(
            project.sections
                .filter { wantedIDs.contains($0.id) }
                .map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for wire in wireSections {
            if let local = currentBySlug[wire.slug] {
                local.name = wire.name
                local.position = wire.position
            } else {
                let composite = LocalSection.makeID(projectID: projectID, slug: wire.slug)
                let local = LocalSection(
                    id: composite,
                    slug: wire.slug,
                    name: wire.name,
                    position: wire.position,
                    project: project
                )
                modelContext.insert(local)
            }
        }
        try? modelContext.save()
    }
}
