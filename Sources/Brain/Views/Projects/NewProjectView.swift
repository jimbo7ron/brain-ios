// NewProjectView.swift
// brain-ios
//
// Minimal "New project" sheet, presented from the Projects list's
// trailing "+" toolbar button. Mirrors the structure of
// `EditProjectView` but trimmed down to what's essential for create:
//
//   * Name (single-line)
//   * Colour (swatch picker drawn from `BrainColors.palette`)
//
// Sort order, archived flag, and custom sections are deliberately
// omitted from the create surface:
//   * Sort order — the server assigns a sane default (0); the user
//     can reorder later via `EditProjectView` if they care.
//   * Archived — a freshly-created project is always non-archived;
//     the server's `ProjectCreate` schema has no such field.
//   * Sections — M26 applies `DEFAULT_SECTIONS` (Now/Next/Later) when
//     the create payload omits `sections`. Custom section editing is
//     reachable from `EditProjectView` once the project exists.
//
// Submission goes via a direct `BrainAPIClient.createProject(...)` call
// — not through the M37 mutation queue — for the same reason the M39
// quick-add path goes direct: the user's intent is "save this thing I
// just typed and tell me if it failed", which is far better served by
// an immediate round-trip than by an enqueue + replay. A subsequent
// `SyncEngine.sync()` pulls the freshly-minted project into SwiftData
// so the list view's `@Query` re-renders without a manual insert.
//
// Live testing on iPhone surfaced this gap: the brain server's
// `POST /api/v1/projects` has been there since M23 but iOS had no UI
// surface for it — projects could only be created via the web client.

import SwiftUI

@MainActor
struct NewProjectView: View {

    @Environment(\.dismiss) private var dismiss
    /// M45 Wave 2: project create now goes through `ProjectRepository`
    /// instead of the direct `await client.createProject(...)` round-
    /// trip this view shipped with. The repository owns the optimistic
    /// local insert + queue enqueue + status-store mark, so the new
    /// project appears in the list instantly. The `\.brainAPIClient`
    /// and `\.syncEngine` env-keys were removed — the repository owns
    /// both responsibilities now.
    @Environment(\.projectRepository) private var projectRepo

    @State private var name: String = ""
    @State private var selectedColorCSS: String?
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !isCreating && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        // Tier 2 e2e harness hook.
                        .accessibilityIdentifier("new-project.name-field")
                }
                Section("Colour") {
                    // Same FlowChips palette + selection styling as
                    // `EditProjectView.colorSection` so the two surfaces
                    // feel identical. Default-unselected is fine — the
                    // server accepts a missing key as "no colour".
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
                        // "No colour" affordance — mirrors the slash-circle
                        // option in `EditProjectView`. Lets the user clear
                        // a previously-chosen swatch without dismissing.
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
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create").bold()
                        }
                    }
                    .disabled(!canCreate)
                    // Tier 2 e2e harness hook.
                    .accessibilityIdentifier("new-project.create-button")
                }
            }
        }
    }

    /// Build the create payload and hand it to `ProjectRepository.create`,
    /// which owns the optimistic local insert + queue enqueue. The
    /// project list's `@Query` picks up the new row in the next render
    /// pass; the queue replays the create against `POST /api/v1/projects`
    /// in the background and reconciles the server's canonical id back
    /// onto the same SwiftData object.
    ///
    /// M45 Wave 2: this used to do `await client.createProject + Task {
    /// await syncEngine?.sync() }`. The repository owns both
    /// responsibilities now.
    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }
        errorMessage = nil

        // sortOrder = nil → server assigns the default (0). Custom
        // ordering is reachable via EditProjectView once the project
        // exists.
        let payload = CreateProjectPayload(
            name: trimmed,
            color: selectedColorCSS,
            sortOrder: nil
        )

        guard let projectRepo else {
            // Preview / non-production host. Production wires the
            // repository in `BrainApp.init`.
            errorMessage = "Configuration error — please report."
            return
        }

        _ = projectRepo.create(payload)
        // TODO(M45 Wave 4): Server-side validation errors from create surface
        // only via MutationStatusStore — wire the failure banner so the user
        // sees them instead of a silent persisted-then-rolled-back stub. The
        // pre-Wave-2 path read `BrainAPIClient.Error.userFacingMessage` here
        // synchronously; the optimistic path makes it asynchronous.
        BrainHaptics.light()
        dismiss()
    }
}

#Preview {
    NewProjectView()
}
