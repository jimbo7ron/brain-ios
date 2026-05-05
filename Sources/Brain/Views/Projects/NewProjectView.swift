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
// M44.x: submission is OPTIMISTIC. We mint a client UUID, insert a
// `LocalProject` stub (with the M26 default sections — Now/Next/Later —
// pre-populated locally so the project detail view renders the right
// shape if the user navigates straight in), save, dismiss, and enqueue a
// `MutationOp.createProject` mutation. The `MutationQueue` replays it
// against `POST /api/v1/projects` and `reconcileCreateProjectResponse`
// patches the stub's id / shortId / canonical sections in place once the
// server confirms.
//
// This replaces the original M40-era direct-call shape (await
// `client.createProject(...)` → fire sync → dismiss) which made rapid
// project creation feel laggy on slow networks. Mirrors the same fix
// `QuickAddView` got in PR #31 for todo creation.
//
// Live testing on iPhone surfaced this gap: the brain server's
// `POST /api/v1/projects` has been there since M23 but iOS had no UI
// surface for it — projects could only be created via the web client.

import SwiftData
import SwiftUI

@MainActor
struct NewProjectView: View {

    @Environment(\.dismiss) private var dismiss
    /// SwiftData context for the optimistic local insert.
    @Environment(\.modelContext) private var modelContext
    /// Mutation queue (M37) — owns the create round-trip after the
    /// optimistic insert. Same wiring `QuickAddView` uses.
    @Environment(\.mutationQueue) private var mutationQueue

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
                        // submit() is synchronous — the optimistic
                        // insert lands immediately and the create
                        // round-trip is enqueued on the M37 mutation
                        // queue. No `Task { await … }` wrapper needed;
                        // the spinner state survives only as a
                        // belt-and-braces guard against double-taps.
                        submit()
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

    /// Optimistic-add path. Insert a local `LocalProject` stub keyed by
    /// a client-minted UUID, save it so SwiftUI's @Query picks it up
    /// immediately, then enqueue a `.createProject` mutation for the
    /// M37 queue to replay against `POST /api/v1/projects`. The
    /// replayer reconciles the server's canonical id back onto the same
    /// SwiftData object via `MutationQueue.reconcileCreateProjectResponse`,
    /// so the user never sees a duplicate row in the Projects list.
    ///
    /// Pre-populates the M26 default sections (Now/Next/Later) on the
    /// stub so a user who taps Create and immediately navigates into
    /// the new project sees a non-empty section list. Once the
    /// reconcile lands those locally-staged sections get replaced with
    /// the server's canonical set (same slugs / names by default, but
    /// keyed off the server's project id).
    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        // We don't await anything below — single SwiftData save plus a
        // non-blocking enqueue — so the busy state is reset
        // immediately. Same shape as `QuickAddView.submit()`.
        defer { isCreating = false }

        let payload = CreateProjectPayload(
            name: trimmed,
            color: selectedColorCSS,
            // sortOrder = nil → server assigns the default (0). Custom
            // ordering is reachable via EditProjectView once the
            // project exists.
            sortOrder: nil
        )

        let clientID = UUID().uuidString.lowercased()
        let now = Date()
        let stub = LocalProject(
            id: clientID,
            // shortId is server-assigned; leave empty until the create
            // echo backfills it.
            shortId: "",
            name: trimmed,
            color: selectedColorCSS,
            sortOrder: 0,
            archived: false,
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(stub)
        // Stage the M26 default sections locally so navigating into
        // the new project before the server confirms shows the right
        // shape. The reconcile path replaces these with the server's
        // canonical set (same defaults, just renamed onto the server
        // project id).
        let defaultSections: [(slug: String, name: String, position: Int)] = [
            ("now", "Now", 0),
            ("next", "Next", 1),
            ("later", "Later", 2),
        ]
        for spec in defaultSections {
            let composite = LocalSection.makeID(projectID: clientID, slug: spec.slug)
            let local = LocalSection(
                id: composite,
                slug: spec.slug,
                name: spec.name,
                position: spec.position,
                project: stub
            )
            modelContext.insert(local)
        }
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            BrainHaptics.error()
            return
        }

        let encoder = JSONEncoder()
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            // Encoding a fixed Codable struct can't realistically fail,
            // but the throws-style API forces us to handle it. Roll
            // back the optimistic insert in this (essentially
            // unreachable) path.
            modelContext.delete(stub)
            try? modelContext.save()
            errorMessage = "Couldn't encode the request. Try again."
            BrainHaptics.error()
            return
        }

        if let queue = mutationQueue {
            do {
                _ = try queue.enqueue(
                    op: .createProject,
                    resourceType: "project",
                    resourceId: clientID,
                    payload: body,
                    baseUpdatedAt: nil
                )
            } catch {
                // Enqueue failure (SwiftData fault on the queue row).
                // Same trade-off as `QuickAddView.submit()` — leave
                // the optimistic stub visible rather than ripping it
                // back out on a transient SwiftData hiccup.
                BrainHaptics.error()
                NSLog(
                    "NewProjectView: failed to enqueue createProject for \(clientID): \(error). " +
                    "Local stub remains visible; no server replay."
                )
            }
        } else {
            // Preview / non-production host: local insert is the
            // entire effect. Production never hits this branch.
            NSLog("NewProjectView: no mutation queue in environment — local-only insert.")
        }

        BrainHaptics.light()
        dismiss()
    }
}

#Preview {
    NewProjectView()
}
