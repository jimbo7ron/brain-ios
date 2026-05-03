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
    /// timestamp string, so the prefix-matching logic is cleaner in
    /// code than in a predicate.
    @Query(
        filter: #Predicate<LocalNote> {
            $0.type == "appointment" && $0.archived == false && $0.appointmentStartTime != nil
        },
        sort: [SortDescriptor(\.appointmentStartTime)]
    )
    private var appointments: [LocalNote]

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
        appointments.filter {
            guard let start = $0.appointmentStartTime else { return false }
            // Server emits `2026-05-03T10:00:00Z` — ISO local-day
            // prefix matching is enough to filter to "today".
            return start.hasPrefix(todayISO)
        }
    }

    private var isEmpty: Bool {
        overdue.isEmpty && dueToday.isEmpty && comingUp.isEmpty && appointmentsToday.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isEmpty {
                    EmptyTodayView()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                }

                if !overdue.isEmpty {
                    Section {
                        ForEach(overdue, id: \.id) { TodoRow(note: $0) }
                    } header: {
                        TodaySectionHeader(
                            title: "Overdue",
                            symbol: BrainSymbols.overdue,
                            tint: .red,
                            count: overdue.count
                        )
                    }
                }

                if !dueToday.isEmpty {
                    Section {
                        ForEach(dueToday, id: \.id) { TodoRow(note: $0) }
                    } header: {
                        TodaySectionHeader(
                            title: "Due today",
                            symbol: BrainSymbols.dueToday,
                            tint: BrainColors.amber.color
                        )
                    }
                }

                if !comingUp.isEmpty {
                    Section {
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
                            ForEach(day.todos, id: \.id) { TodoRow(note: $0) }
                        }
                    } header: {
                        TodaySectionHeader(
                            title: "Coming up",
                            symbol: BrainSymbols.now,
                            tint: BrainColors.violet.color,
                            trailingNote: "next \(TodayDate.comingUpDays) days"
                        )
                    }
                }

                if !appointmentsToday.isEmpty {
                    Section {
                        ForEach(appointmentsToday, id: \.id) { AppointmentRow(note: $0) }
                    } header: {
                        TodaySectionHeader(
                            title: "Appointments today",
                            symbol: BrainSymbols.location,
                            tint: BrainColors.teal.color
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .refreshable {
                // Pull-to-refresh: explicit user-initiated sync.
                // SyncEngine debounces if a sync just ran, so this
                // is safe to spam.
                await syncEngine?.sync()
            }
        }
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

/// Empty state when every section is empty (fresh sign-in, or all
/// caught up). Sized to match the section spacing so the layout
/// doesn't lurch when the first todo arrives.
struct EmptyTodayView: View {
    var body: some View {
        ContentUnavailableView {
            Label("All clear", systemImage: BrainSymbols.checkmarkCircle)
        } description: {
            Text("Nothing overdue, due today, or on the next 6 days. Pull to sync.")
        }
    }
}

#Preview {
    TodayView()
}
