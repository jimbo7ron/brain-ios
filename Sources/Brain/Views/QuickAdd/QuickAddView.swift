// QuickAddView.swift
// brain-ios
//
// Quick-add sheet (M39). Mirrors the web's quick-capture box: the user
// types a single line like `"Pay tax tomorrow !high #finance"` and the
// app extracts the trailing date, priority bang, hashtags, wiki-links,
// and recurrence keyword as they type. A live preview renders the
// parsed result so the user can confirm we understood them before
// hitting Add.
//
// Submission goes straight through `BrainAPIClient.createNote` — direct
// call, not via the M37 mutation queue. M40 will revisit when the full
// edit dialog lands and the queue grows a `createTodo` arm. Until then
// the round-trip is short and the user sees the new row appear after
// the next sync (foreground 5-min Timer or PTR on Today).

import SwiftData
import SwiftUI

/// Modal sheet that converts free-form text into a todo. Presented
/// from the FAB on `TodayView`.
@MainActor
struct QuickAddView: View {

    @Environment(\.brainAPIClient) private var client
    @Environment(\.syncEngine) private var syncEngine
    @Environment(\.dismiss) private var dismiss

    @State private var rawText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    /// The parsed result is recomputed every keystroke. Cheap — the
    /// regex passes are linear in input length.
    private var parsed: QuickAddResult {
        QuickAddParser.parse(rawText)
    }

    /// Cleared title means "no useful content" — a single date phrase
    /// like `"tomorrow"` survives as the title, but a fully-stripped
    /// input (e.g. just `#tag1 #tag2` after we drop priorities) leaves
    /// a usable title in `tagged`. We use the raw input length as the
    /// final guard so the user can't submit just whitespace.
    private var canSubmit: Bool {
        !isSubmitting && !rawText.trimmingCharacters(in: .whitespaces).isEmpty && !parsed.title.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputSection

                    if !parsed.title.isEmpty {
                        QuickAddPreview(result: parsed)
                            .transition(.opacity)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("quick-add.error")
                    }

                    helpFooter
                }
                .padding()
            }
            .navigationTitle("Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Add").bold()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    /// Big multi-line text field. Auto-focused on appear so the user
    /// can start typing immediately — the FAB is one tap, the keyboard
    /// is the next thing they expect.
    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's on your mind?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(
                "Try \"Ship migration by Friday !high #work\"",
                text: $rawText,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.done)
            .accessibilityIdentifier("quick-add.field")
        }
    }

    /// Inline cheat-sheet rendered below the preview — tells the user
    /// what the parser knows about. Kept compact; it's only useful
    /// once.
    @ViewBuilder
    private var helpFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hints")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("Add a date: tomorrow, next monday, in 3 days, 2026-05-12")
            Text("Add a time: at 9am, at 15:00")
            Text("Priority: !high  |  !medium  |  !low")
            Text("Tags: #work  #finance      Wiki link: [[Project Alpha]]")
            Text("Recurrence: daily, weekly, monthly, weekdays")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build the wire payload, fire `createNote`, kick a sync to
    /// rehydrate the row through the read path, then dismiss.
    /// On any error we surface a message but stay open so the user
    /// can retry without re-typing.
    private func submit() async {
        guard canSubmit, let client else {
            errorMessage = "Couldn't reach the server. Try again."
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let payload = CreateNotePayload(
            content: parsed.bodyForServer(),
            title: nil,
            type: "todo",
            dueDate: parsed.dueDateISO(),
            dueTime: parsed.dueTimeHHMM(),
            priority: parsed.priority?.rawValue,
            recurrence: parsed.recurrence?.rawValue,
            project: nil,
            section: nil,
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )

        do {
            _ = try await client.createNote(payload)
            // Pull the newly-created row through the read-path sync so
            // it appears on Today / Projects without waiting for the
            // 5-minute Timer. Fire-and-forget — we've already saved
            // server-side, so the user can dismiss even if sync lags.
            Task { await syncEngine?.sync() }
            dismiss()
        } catch let error as BrainAPIClient.Error {
            errorMessage = error.userFacingMessage
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Live preview of the parsed result. Renders title + chips for date,
/// time, priority, recurrence, tags, wiki-links. Mirrors the web's
/// quick-add affordance.
struct QuickAddPreview: View {

    let result: QuickAddResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text(result.title)
                    .font(.headline)
                    .accessibilityIdentifier("quick-add.preview.title")

                FlowChips {
                    if let date = result.dueDate {
                        QuickAddChip(
                            symbol: BrainSymbols.dueToday,
                            text: formatPreviewDate(date),
                            tint: BrainColors.sky.color
                        )
                    }
                    if let time = result.dueTime {
                        QuickAddChip(
                            symbol: "clock",
                            text: formatPreviewTime(time),
                            tint: BrainColors.sky.color
                        )
                    }
                    if let priority = result.priority {
                        QuickAddChip(
                            symbol: "exclamationmark.circle",
                            text: priority.rawValue.capitalized,
                            tint: priorityTint(priority)
                        )
                    }
                    if let recurrence = result.recurrence {
                        QuickAddChip(
                            symbol: "arrow.triangle.2.circlepath",
                            text: recurrence.rawValue.capitalized,
                            tint: BrainColors.violet.color
                        )
                    }
                    ForEach(result.tags, id: \.self) { tag in
                        QuickAddChip(
                            symbol: "number",
                            text: tag,
                            tint: BrainColors.emerald.color
                        )
                    }
                    ForEach(result.wikiLinkTargets, id: \.self) { target in
                        QuickAddChip(
                            symbol: "link",
                            text: target,
                            tint: BrainColors.indigo.color
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    /// Map a parsed `Date` into a short label like "Today", "Tomorrow",
    /// or `"Mon May 5"`. We reuse `TodayDate.relativeDayLabel` for
    /// near-term dates so the preview matches the Today view's
    /// vocabulary.
    private func formatPreviewDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfDate = calendar.startOfDay(for: date)
        if startOfDate == startOfToday { return "Today" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let label = formatter.string(from: date)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           startOfDate == tomorrow {
            return "Tomorrow"
        }
        return label
    }

    private func formatPreviewTime(_ time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: time)
    }

    private func priorityTint(_ priority: QuickAddPriority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        }
    }
}

/// Single labelled chip used in the preview row. Symbol + short text
/// inside a soft-tinted capsule.
struct QuickAddChip: View {

    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
    }
}

/// Tiny flow-layout shim so chips wrap onto multiple lines on narrow
/// devices. SwiftUI's `Layout` protocol exists since iOS 16 and is the
/// minimal way to do this without dragging in a 3rd-party package.
struct FlowChips: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Quick add — empty") {
    QuickAddView()
}

#Preview("Quick add — populated") {
    let preview = QuickAddPreview(
        result: QuickAddParser.parse("Ship migration tomorrow at 9am !high #work [[Project Alpha]]")
    )
    return preview
        .padding()
}
