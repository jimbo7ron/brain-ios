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

    /// "10:00 – 11:00" if both ends present, "10:00" if only the
    /// start, empty string if neither. The server emits ISO-8601
    /// timestamps, but we keep them as strings here so we don't
    /// have to round-trip through Date for a row that's not
    /// time-sorted. M40 may upgrade this to a localized formatter.
    private var timeRange: String {
        let start = note.appointmentStartTime ?? ""
        let end = note.appointmentEndTime ?? ""
        let trimmedStart = formatClock(start)
        let trimmedEnd = formatClock(end)
        if !trimmedStart.isEmpty, !trimmedEnd.isEmpty { return "\(trimmedStart) – \(trimmedEnd)" }
        return trimmedStart
    }

    /// Pull the `HH:mm` portion out of an ISO-8601 string. Falls
    /// back to the raw string if it doesn't look like ISO — better
    /// to show something than crash on malformed payloads.
    private func formatClock(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        // ISO format: `2026-05-03T10:00:00Z` → split on "T", take
        // the time, drop seconds and any timezone suffix.
        let parts = raw.split(separator: "T", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return raw }
        let timePart = parts[1]
        let timeOnly = timePart
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .prefix(2)
            .joined(separator: ":")
        return timeOnly.isEmpty ? raw : timeOnly
    }

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
                .foregroundStyle(BrainColors.teal.color)
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
