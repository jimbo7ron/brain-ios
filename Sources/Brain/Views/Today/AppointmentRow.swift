// AppointmentRow.swift
// brain-ios
//
// Single appointment row for the Today view. Mirrors the web's
// "Appointments today" section in `web/src/app/page.tsx` —
// title on top, then a metadata line of `start_time · location`.
// Server-side appointments use `LocalNote` with `type ==
// "appointment"` and the `appointment*` fields populated.

import SwiftUI

@MainActor
struct AppointmentRow: View {

    let note: LocalNote

    private var displayTitle: String {
        let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return note.content
    }

    /// "10:00 AM – 11:00 AM" (or "10:00 – 11:00" depending on locale)
    /// if both ends present, "10:00 AM" if only the start, empty
    /// string if neither. The server emits ISO-8601 UTC timestamps
    /// (`2026-05-03T10:00:00Z`); we parse them through
    /// `ISO8601DateFormatter` and render with `DateFormatter` in the
    /// user's current locale + timezone so a 10:00 UTC appointment
    /// shows as 11:00 in BST, 03:00 in PT, etc.
    private var timeRange: String {
        let start = formatClock(note.appointmentStartTime)
        let end = formatClock(note.appointmentEndTime)
        if !start.isEmpty, !end.isEmpty { return "\(start) – \(end)" }
        return start
    }

    /// Parse a server-emitted ISO-8601 timestamp and format it as a
    /// short locale-aware time. Falls back to the raw string if the
    /// payload doesn't parse — better to show something than crash
    /// on malformed input.
    private func formatClock(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let date = AppointmentRow.iso8601.date(from: raw) else { return raw }
        return AppointmentRow.timeFormatter.string(from: date)
    }

    /// Shared parser for the server's ISO-8601 timestamps. `Z`
    /// suffix is required, which the server always emits.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Shared short-time formatter. Picks up the user's current
    /// locale and timezone automatically (e.g. "10:00 AM" in en_US,
    /// "10:00" in en_GB).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var subline: String {
        var pieces: [String] = []
        let range = timeRange
        if !range.isEmpty { pieces.append(range) }
        if let location = note.appointmentLocation, !location.isEmpty {
            pieces.append(location)
        }
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: BrainSymbols.location)
                .font(.title3)
                // Match the section header tint (web `--section-later`
                // / slate) so the row icon doesn't disagree with the
                // header it sits beneath.
                .foregroundStyle(BrainColors.slate.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(2)
                if !subline.isEmpty {
                    Text(subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
