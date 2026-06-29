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
    /// string if neither. Server emits naive
    /// `yyyy-MM-dd'T'HH:mm:ss[.SSSSSS][Z]` timestamps that are
    /// wall-clock/local time. `ServerDate` parses them in
    /// `TimeZone.current` and we render with `DateFormatter` in the
    /// user's current locale + `TimeZone.current`, so the wall-clock
    /// value is shown unchanged (a 10:00 appointment reads as 10:00).
    private var timeRange: String {
        let start = formatClock(note.appointmentStartTime)
        let end = formatClock(note.appointmentEndTime)
        if !start.isEmpty, !end.isEmpty { return "\(start) – \(end)" }
        return start
    }

    /// Parse a server-emitted timestamp and format it as a short
    /// locale-aware time. Falls back to the raw string if the
    /// payload doesn't parse — better to show something than crash
    /// on malformed input.
    private func formatClock(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let date = ServerDate.parse(raw) else { return raw }
        return AppointmentRow.displayTimeFormatter.string(from: date)
    }

    /// Shared short-time formatter. Picks up the user's current
    /// locale and timezone automatically (e.g. "10:00 AM" in en_US,
    /// "10:00" in en_GB). `TimeZone.current` matches the parser's zone
    /// so the wall-clock value round-trips without an offset shift.
    private static let displayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale.current
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
                .font(.headline)
                // Match the section header tint (web `--section-later`
                // / slate) so the row icon doesn't disagree with the
                // header it sits beneath.
                .foregroundStyle(BrainColors.slate.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.callout)
                    .lineLimit(2)
                if !subline.isEmpty {
                    Text(subline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Match `TodoRow`'s tightened vertical row insets so the
        // Appointments-today section reads at the same density as
        // the todo sections above it.
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
