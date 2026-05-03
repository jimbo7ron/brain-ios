// TodayView.swift
// brain-ios
//
// The M34 Today surface. Mirrors `web/src/app/page.tsx` exactly:
//
//   * Overdue       — open todos with due_date < today
//   * Due today     — open todos with due_date == today
//   * Coming up     — open todos with today < due_date <= today + 6,
//                     grouped by day with relative-day headers
//   * Appointments  — appointments whose start_time falls today
//
// Pull-to-refresh triggers `SyncEngine.sync()` so the user has an
// explicit "give me the latest" affordance — the app also runs the
// 5-minute foreground Timer (M33) and a future M41 background fetch,
// but PTR remains the manual lever.
//
// Data strategy:
// SwiftData `#Predicate` can compare `String` columns lexicographically
// against captured `String` constants. Because the server stores
// `due_date` as `yyyy-MM-dd` (ISO local-day), lexicographic order
// matches calendar order — so we *could* push the partition into the
// predicate. We don't, for two reasons:
//   1. The "today" string changes when the calendar day rolls over;
//      a single fetch of all open todos lets the view update on the
//      next render without rebuilding `@Query` state.
//   2. The dataset is small (personal-app scale, <200 open todos
//      per the web Today page's defensive limit).
// So: one @Query for "open todos with a due_date" plus one for
// "appointments", and we partition + group in Swift.

import SwiftData
import SwiftUI

@MainActor
struct TodayView: View {

    @Environment(\.syncEngine) private var syncEngine

    /// Open todos with a `due_date`. Filtered server-side via the
    /// predicate so we don't drag completed / undated todos into the
    /// view's working set. Sort by `dueDate` (string sort matches
    /// calendar order for `yyyy-MM-dd`) then `sortOrder` so within
    /// a day the user's manual ordering still wins — same as the web.
    @Query(
        filter: #Predicate<LocalNote> {
            $0.type == "todo" && $0.completed == false && $0.dueDate != nil && $0.archived == false
        },
        sort: [SortDescriptor(\.dueDate), SortDescriptor(\.sortOrder)]
    )
    private var openTodos: [LocalNote]

    /// All non-archived appointments. We filter to "today" in Swift
    /// because the appointment start time is stored as a full ISO
    /// UTC timestamp string and "today" depends on the user's local
    /// timezone — a server-side date prefix won't be correct in
    /// non-UTC zones, so we parse and compare via `Calendar`.
    @Query(
        filter: #Predicate<LocalNote> {
            $0.type == "appointment" && $0.archived == false && $0.appointmentStartTime != nil
        },
        sort: [SortDescriptor(\.appointmentStartTime)]
    )
    private var appointments: [LocalNote]

    /// All non-archived projects. We hoist this to the view level
    /// so each `TodoRow` can look up its project's accent color from
    /// a parent-built dict rather than running its own per-row
    /// `@Query`. Project lists are personal-app scale (<50), so
    /// fetching them all is cheaper than 100+ individual queries.
    @Query(filter: #Predicate<LocalProject> { $0.archived == false })
    private var projects: [LocalProject]

    /// `projectId` → `LocalProject` lookup, rebuilt per render.
    /// Constant-time access during the row builds.
    private var projectsById: [String: LocalProject] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    /// Local "today" recomputed each render. Cheap — a couple of
    /// `DateFormatter.string(from:)` calls — and lets the view
    /// react to a midnight rollover without extra plumbing.
    private var todayISO: String { TodayDate.todayISO() }

    /// Inclusive horizon for "Coming up" (today + 6).
    private var horizonISO: String {
        TodayDate.isoDate(offsetByDays: TodayDate.comingUpDays)
    }

    private var overdue: [LocalNote] {
        openTodos.filter { ($0.dueDate ?? "") < todayISO }
    }

    private var dueToday: [LocalNote] {
        openTodos.filter { $0.dueDate == todayISO }
    }

    private var comingUp: [LocalNote] {
        openTodos.filter {
            guard let due = $0.dueDate else { return false }
            return due > todayISO && due <= horizonISO
        }
    }

    /// "Coming up" grouped by `dueDate` ISO, with the days returned
    /// in chronological order. Mirrors the web page's
    /// `comingUpByDay` Map.
    private var comingUpDays: [(date: String, todos: [LocalNote])] {
        var grouped: [String: [LocalNote]] = [:]
        for note in comingUp {
            let key = note.dueDate ?? ""
            grouped[key, default: []].append(note)
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private var appointmentsToday: [LocalNote] {
        let calendar = Calendar.current
        return appointments.filter {
            guard let raw = $0.appointmentStartTime,
                  let date = TodayView.iso8601.date(from: raw)
            else { return false }
            // Compare in the user's local timezone — a UTC-suffixed
            // ISO timestamp can land on a different calendar day in
            // BST, PT, JST, etc. than its date prefix suggests.
            return calendar.isDateInToday(date)
        }
    }

    /// Shared parser for the server's ISO-8601 UTC timestamps.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                // Overdue is the only section that hides when empty —
                // matches the web (`overdue.length > 0 ? ... : null`)
                // because an empty Overdue is the desired state and
                // the destructive-tint header otherwise reads as a
                // visual alarm with no content.
                if !overdue.isEmpty {
                    Section {
                        ForEach(overdue, id: \.id) { todo(for: $0) }
                    } header: {
                        TodaySectionHeader(
                            title: "Overdue",
                            symbol: BrainSymbols.overdue,
                            tint: .red,
                            count: overdue.count
                        )
                    }
                }

                Section {
                    if dueToday.isEmpty {
                        EmptySectionLine(text: "Nothing due today.")
                    } else {
                        ForEach(dueToday, id: \.id) { todo(for: $0) }
                    }
                } header: {
                    TodaySectionHeader(
                        title: "Due today",
                        symbol: BrainSymbols.dueToday,
                        // Web maps Due Today → `--section-next` (sky).
                        tint: BrainColors.sky.color
                    )
                }

                Section {
                    if comingUp.isEmpty {
                        EmptySectionLine(text: "Nothing scheduled in the next \(TodayDate.comingUpDays) days.")
                    } else {
                        ForEach(comingUpDays, id: \.date) { day in
                            // Per-day subheader inside the section so
                            // the user sees "Tomorrow", "Mon May 5"
                            // etc. Matches the web grouping.
                            Text(TodayDate.relativeDayLabel(forISO: day.date))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            ForEach(day.todos, id: \.id) { todo(for: $0) }
                        }
                    }
                } header: {
                    TodaySectionHeader(
                        title: "Coming up",
                        // Web uses Lucide `CalendarRange`; SF Symbols
                        // closest is `calendar.badge.clock`.
                        symbol: BrainSymbols.comingUp,
                        // Web maps Coming Up → `--section-now` (violet).
                        tint: BrainColors.violet.color,
                        trailingNote: "next \(TodayDate.comingUpDays) days"
                    )
                }

                Section {
                    if appointmentsToday.isEmpty {
                        EmptySectionLine(text: "No appointments today.")
                    } else {
                        ForEach(appointmentsToday, id: \.id) { AppointmentRow(note: $0) }
                    }
                } header: {
                    TodaySectionHeader(
                        title: "Appointments today",
                        symbol: BrainSymbols.location,
                        // Web maps Appointments → `--section-later` (slate/zinc).
                        tint: BrainColors.slate.color
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .refreshable {
                // Pull-to-refresh: explicit user-initiated sync.
                // SyncEngine debounces if a sync just ran, so this
                // is safe to spam.
                if let syncEngine {
                    await syncEngine.sync()
                } else {
                    // Surfaces a wiring bug in development without
                    // crashing release. PTR with no engine is a
                    // silent no-op for users.
                    assertionFailure("syncEngine should be injected")
                }
            }
        }
    }

    /// Build a `TodoRow` for `note`, resolving its project's accent
    /// color from the parent-built `projectsById` dict so the row
    /// itself doesn't have to run a per-row `@Query`.
    @ViewBuilder
    private func todo(for note: LocalNote) -> some View {
        let project = note.projectId.flatMap { projectsById[$0] }
        TodoRow(note: note, accentColor: TodayView.accentColor(for: project))
    }

    /// Resolve a `LocalProject.color` (a CSS HSL string) to a
    /// SwiftUI `Color`. Falls back to the system tint when the
    /// project is `nil` or the CSS string is unrecognised.
    static func accentColor(for project: LocalProject?) -> Color {
        guard let css = project?.color else { return .accentColor }
        if let match = BrainColors.palette.first(where: { $0.cssValue == css }) {
            return match.color
        }
        return .accentColor
    }
}

/// Header pill rendered at the top of each Today section. Uses the
/// SF Symbol mapped from the corresponding Lucide icon (see
/// `BrainSymbols`) and a tint color drawn from the BrainColor
/// palette so iOS / web stay visually aligned.
struct TodaySectionHeader: View {

    let title: String
    let symbol: String
    let tint: Color
    var count: Int?
    var trailingNote: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(title)
                .font(.caption.bold())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(tint)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.regular))
                    .foregroundStyle(tint.opacity(0.7))
                    .monospacedDigit()
            }
            if let trailingNote {
                Text(trailingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Inline empty-state line shown beneath a section header when the
/// section has no rows. Mirrors the web's italic "Nothing due
/// today." treatment so the user sees every section consistently
/// rather than a layout that lurches as data arrives.
struct EmptySectionLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .italic()
            .foregroundStyle(.secondary)
    }
}

#Preview {
    TodayView()
}
