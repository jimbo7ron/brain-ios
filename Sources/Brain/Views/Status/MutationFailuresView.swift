// MutationFailuresView.swift
// brain-ios
//
// M45 Wave 4 follow-up: the tap-through surface behind the status
// pill's red "⚠ M" indicator. The pill answers "how many of my changes
// didn't save?"; this sheet answers "*which* ones, *why*, and what can
// I do about it?".
//
// Before this view, a poisoned mutation was a dead end for the user: the
// count surfaced in the toolbar pill (and a red dot on the row), but the
// only recovery path was an operator draining the queue from a debug
// menu or reading the Console logs. This sheet promotes both halves to
// the user:
//
//   * Visibility — each parked row lists the action ("Edit to-do"), the
//     resource bucket, and the captured error string.
//   * Recovery — per-row Retry / Discard, plus Retry-all / Discard-all
//     in the toolbar menu.
//
// "Retry" un-poisons the row (`MutationQueue.retry`) and kicks a replay;
// a genuinely-permanent failure re-poisons and resurfaces here. "Discard"
// drops the row for good (`MutationQueue.discard`) — the user's escape
// hatch for a change that will never succeed (a 422 they can't fix from
// the device, a resource deleted on the web).
//
// The list is read once on appear and re-read after each action rather
// than bound to a live `@Query`: the actions mutate the queue's own
// `ModelContext` (not the SwiftUI one), and re-reading via
// `queue.failedItems()` keeps the view's source of truth identical to
// what the recovery methods operate on. When the last row clears, the
// sheet dismisses itself — there's nothing left to act on.

import SwiftUI

@MainActor
struct MutationFailuresView: View {

    let queue: MutationQueue

    @Environment(\.dismiss) private var dismiss

    /// Snapshot of the poisoned rows, refreshed on appear and after each
    /// action. Not a `@Query` — see the file header for why we re-read
    /// from `queue.failedItems()` instead.
    @State private var items: [MutationQueueItem] = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Failed changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    if !items.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    queue.retryAllFailed()
                                    reload()
                                } label: {
                                    Label("Retry all", systemImage: "arrow.clockwise")
                                }
                                Button(role: .destructive) {
                                    queue.discardAllFailed()
                                    reload()
                                } label: {
                                    Label("Discard all", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More actions")
                        }
                    }
                }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            // Defensive: the pill only opens this sheet when the failed
            // count is non-zero, but a race (the last row replaying
            // successfully between tap and present) can land us here.
            ContentUnavailableView(
                "No failed changes",
                systemImage: "checkmark.circle",
                description: Text("Everything has synced. You're all caught up.")
            )
        } else {
            List {
                Section {
                    ForEach(items, id: \.id) { item in
                        row(for: item)
                    }
                } footer: {
                    Text(
                        "These changes couldn't be saved to the server. "
                        + "Retry to try again — useful once a connection or "
                        + "server problem is fixed — or discard to drop the "
                        + "change for good."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: MutationQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(actionLabel(for: item))
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
                Text(item.resourceType.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(errorMessage(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Spacer(minLength: 0)
                // `.borderless` so each button captures its own tap
                // rather than the whole row — two tap targets in one
                // list row need explicit, isolated styles.
                Button(role: .destructive) {
                    queue.discard(item)
                    reload()
                } label: {
                    Text("Discard")
                }
                .buttonStyle(.borderless)

                Button {
                    queue.retry(item)
                    reload()
                } label: {
                    Text("Retry")
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        // Belt-and-braces discoverability: the buttons are the primary
        // affordance, but swipe-to-act matches the platform habit for a
        // list of removable rows.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                queue.discard(item)
                reload()
            } label: {
                Label("Discard", systemImage: "trash")
            }
            Button {
                queue.retry(item)
                reload()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
    }

    // MARK: - Data

    /// Re-read the poisoned rows from the queue. Dismiss when the list
    /// empties out as a result of an action — there's nothing left to
    /// act on, and leaving an empty sheet up reads as a dead end.
    private func reload() {
        items = queue.failedItems()
        if items.isEmpty {
            dismiss()
        }
    }

    /// Decode the persisted op slug into its user-facing label. An
    /// unknown slug (a downgrade reading a forward-build's queue row)
    /// falls back to the raw slug so the row is still identifiable.
    private func actionLabel(for item: MutationQueueItem) -> String {
        MutationOp(rawValue: item.op)?.displayName ?? item.op
    }

    /// The captured failure string, or a generic fallback. `lastError`
    /// is set on every poison path (`replay()`'s permanent / cap-exceeded
    /// arms), so the fallback only fires for a row poisoned by a code
    /// path that forgot to stamp it.
    private func errorMessage(for item: MutationQueueItem) -> String {
        item.lastError ?? "This change couldn't be saved."
    }
}
