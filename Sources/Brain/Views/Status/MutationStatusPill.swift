// MutationStatusPill.swift
// brain-ios
//
// M45 Wave 4 (spec §4.4 "Queue-level: 'N pending / M failed' banner"):
// a small toolbar pill that surfaces the live queue counts. The pill
// is information-dense and intentionally subtle:
//
//   * Hidden entirely when both counts are zero (the queue is idle —
//     there's nothing for the user to act on, so no chrome).
//   * Shows "↻ N" in `.secondary` when N pending writes are in flight
//     or backing off (no error yet, no user action required).
//   * Shows "⚠ M" in `.red` when M rows have poisoned (permanent
//     failure or retry cap exceeded). The user can't retry today —
//     a debug-menu drain is the operator path — but seeing the count
//     means a "why didn't my edit save?" question has an immediate
//     answer.
//   * When both counts are non-zero, both indicators render side by
//     side. They can overlap conceptually (a poisoned row also counts
//     toward `pendingCount` because it's still on disk), so the pill
//     computes "active pending" as `pendingCount - failedCount` to
//     avoid double-counting.
//
// Why a separate file rather than inlining in `SignedInRootView`:
// keeps the toolbar's view-builder small, makes the pill testable in
// isolation, and the visibility-by-counts logic ("hide when both
// zero") is something the next surface that wants this affordance
// (Settings, in-row debug pane) can pull in unchanged.

import SwiftUI

/// Live status pill rendered in the signed-in root's toolbar. Reads
/// `MutationQueue.pendingCount` + `MutationQueue.failedCount` directly
/// — `@Observable` triggers a re-render on every change. The pill is
/// stateless; all the truth lives on the queue.
@MainActor
struct MutationStatusPill: View {

    /// Optional because env keys default to nil for previews / non-
    /// production hosts. When the queue is missing the pill renders
    /// as `EmptyView` (no chrome), matching the production "queue is
    /// idle" branch.
    let queue: MutationQueue?

    var body: some View {
        // `pendingCount` is now the derived "active pending"
        // (`totalCount - failedCount`) per M45 Wave 4 review fix —
        // poisoned rows already count toward `failedCount` so reading
        // both directly avoids the double-count the previous code did
        // by hand.
        let activePending = queue?.pendingCount ?? 0
        let failed = queue?.failedCount ?? 0

        if activePending == 0 && failed == 0 {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if activePending > 0 {
                    Label {
                        Text("\(activePending)")
                            .font(.caption2.monospacedDigit())
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(activePending) pending writes")
                }
                if failed > 0 {
                    Label {
                        Text("\(failed)")
                            .font(.caption2.monospacedDigit())
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(failed) failed writes")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
        }
    }
}

#Preview("idle") {
    NavigationStack {
        Text("body")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MutationStatusPill(queue: nil)
                }
            }
    }
}
