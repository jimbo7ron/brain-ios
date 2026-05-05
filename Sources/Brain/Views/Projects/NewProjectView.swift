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
    @Environment(\.brainAPIClient) private var client
    @Environment(\.syncEngine) private var syncEngine

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
                        Task { await submit() }
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create").bold()
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    /// Build the create payload, hit `POST /api/v1/projects`, then fire
    /// a sync so the new row lands in SwiftData and the list view's
    /// `@Query` re-renders before the user sees the dismissed sheet.
    private func submit() async {
        guard let client else {
            // Should never happen in production — the environment is
            // injected at the root scene. If it does, surface enough
            // for the user to file a sensible bug report.
            errorMessage = "Configuration error — please report."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }
        errorMessage = nil

        do {
            // sortOrder = nil → server assigns the default (0). Custom
            // ordering is reachable via EditProjectView once the
            // project exists.
            let payload = CreateProjectPayload(
                name: trimmed,
                color: selectedColorCSS,
                sortOrder: nil
            )
            _ = try await client.createProject(payload)
            // Pull through sync so the new row shows up immediately in
            // the list. We don't await it — the response from
            // createProject is already canonical; sync just mirrors it
            // into SwiftData for the @Query subscribers. Awaiting would
            // delay the dismiss for no perceptible benefit.
            Task { await syncEngine?.sync() }
            BrainHaptics.light()
            dismiss()
        } catch let error as BrainAPIClient.Error {
            errorMessage = error.userFacingMessage
            BrainHaptics.error()
        } catch {
            errorMessage = "Couldn't create project: \(error.localizedDescription)"
            BrainHaptics.error()
        }
    }
}

#Preview {
    NewProjectView()
}
