// ProjectRow.swift
// brain-ios
//
// Single row in the M35 project list. Mirrors the web sidebar item
// (`web/src/app/layout.tsx`) — a small color dot followed by the
// project name. The dot's color is resolved from `LocalProject.color`
// (a CSS HSL string) via `BrainColors.palette`, the same lookup
// `TodoRow.accentColor` uses in the M34 Today view.
//
// We also surface a small open-todo count on the trailing edge so
// the user has a quick read on which projects have outstanding work
// — equivalent to the web's "X open" badge concept (the web shows
// it on the project detail header rather than the sidebar, but on a
// phone the count is more useful inline because the detail view is
// one tap away).
//
// Open-count strategy: the parent (`ProjectListView`) runs ONE
// global @Query for open todos and passes the per-project count in
// here. Mirrors the M34 `TodoRow.accentColor` pattern — keeping the
// SwiftData subscription at the parent avoids one query per row.

import SwiftUI

@MainActor
struct ProjectRow: View {

    let project: LocalProject
    /// Pre-computed open-todo count, supplied by the parent. Defaults
    /// to 0 so previews and tests don't have to thread the dict in.
    let openTodoCount: Int

    init(project: LocalProject, openTodoCount: Int = 0) {
        self.project = project
        self.openTodoCount = openTodoCount
    }

    /// Resolve the project's CSS color string against the BrainColors
    /// palette. Falls back to the system tint when the server emits a
    /// color that isn't in the canonical 10-slot palette (e.g. a
    /// future custom-color feature).
    private var dotColor: Color {
        guard let css = project.color else { return .accentColor }
        if let match = BrainColors.palette.first(where: { $0.cssValue == css }) {
            return match.color
        }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                // Match the web's subtle ring around the swatch so a
                // light-color dot still reads against a light row bg.
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )

            Text(project.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if openTodoCount > 0 {
                Text("\(openTodoCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(openTodoCount) open todos")
            }
        }
        .contentShape(Rectangle())
    }
}
