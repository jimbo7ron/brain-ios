// SearchView.swift
// brain-ios
//
// M43 — in-app search across notes / todos. Reachable from the 4th
// tab in `SignedInRootView`. Mirrors the web's search-box: the user
// types a substring, the app debounces 300 ms, then hits
// `GET /api/v1/notes?q=<query>` and renders the matches as a tappable
// list. Tapping a row presents the M40 `EditTodoView` for the row's
// `LocalNote` if the SwiftData cache has it; otherwise the tap is a
// no-op (cache hasn't synced this row yet — same graceful degradation
// we use elsewhere). Appointments and plain notes share the same
// edit surface; a dedicated read-only detail view is M44+.
//
// Why server-side search rather than scanning the SwiftData store:
//   * The server's `q` parameter is full-text against `title` +
//     `content` and respects archived / completed flags consistently.
//     Reproducing that in SwiftData would mean either (a) a `#Predicate`
//     with `localizedStandardContains` (iOS 18+ only) or (b) fetching
//     all notes and filtering in memory. Both are fine for personal-app
//     scale but drift from server semantics over time.
//   * Server-side search picks up notes the local cache hasn't synced
//     yet — useful when the user signs in on a new device and starts
//     searching before the first full sync completes.
//   * One round-trip is fast enough at our scale (typically <100 ms
//     LAN, <500 ms over cellular). The 300 ms debounce already
//     dominates perceived latency.
//
// Recent searches are persisted to `UserDefaults` so the user gets a
// "you searched for these recently" affordance without us needing a
// separate SwiftData table. Capped at 10 entries to avoid runaway
// growth; oldest entries roll off when a new search is added.

import SwiftData
import SwiftUI

@MainActor
struct SearchView: View {

    @Environment(\.brainAPIClient) private var client

    /// Live text in the search field. Bound to a `searchable`
    /// modifier so the system surfaces a cancel button + scope bar
    /// for free, matching iOS HIG patterns.
    @State private var query: String = ""

    /// Latest decoded search hits. Empty when no query is active or
    /// the last query returned nothing.
    @State private var results: [Note] = []

    /// True between the start of a debounced fetch and its
    /// completion. We surface a small spinner inline so the user sees
    /// the network round-trip is in flight rather than wondering if
    /// the field broke.
    @State private var isSearching: Bool = false

    /// Most recent error string from the API client, or nil. We
    /// surface this in-list so it appears between the field and any
    /// stale results — the user knows the latest fetch failed but
    /// doesn't lose context of what they were looking at.
    @State private var errorMessage: String?

    /// Active debounced fetch. Cancelled by every keystroke so a
    /// burst of typing collapses to one request 300 ms after the last
    /// character.
    @State private var searchTask: Task<Void, Never>?

    /// Cached recent-search history (10 entries, newest first). Read
    /// from UserDefaults on first appear; written back on each
    /// successful search.
    @State private var recentSearches: [String] = []

    /// All non-archived projects, hoisted so result rows can look up
    /// their project's accent color from a parent-built dict rather
    /// than running per-row queries (matches the TodayView pattern).
    @Query(filter: #Predicate<LocalProject> { $0.archived == false })
    private var projects: [LocalProject]

    private var projectsById: [String: LocalProject] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    /// All non-archived local notes, used to resolve a tapped wire
    /// `Note` (DTO) back into the `LocalNote` SwiftData model that
    /// `EditTodoView` expects. Cheap at personal-app scale — the same
    /// pattern TodayView uses to bucket todos for its sections.
    @Query(filter: #Predicate<LocalNote> { $0.archived == false })
    private var localNotes: [LocalNote]

    private var localNotesById: [String: LocalNote] {
        Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id, $0) })
    }

    /// The note currently being edited, or `nil` when no sheet is
    /// presented. Mirrors `ProjectListView.projectToEdit` — using
    /// `sheet(item:)` lets a single sheet host serialise across all
    /// rows without per-row state. M43 routing decision (tap → edit
    /// dialog vs project navigation): we open `EditTodoView` for any
    /// row whose `Note.id` resolves to a cached `LocalNote`, regardless
    /// of `type`. Appointments are rare in search results today and a
    /// dedicated read-only detail view is M44+; until then, the edit
    /// dialog is the only existing surface that can show a note's
    /// fields, so reusing it keeps the tap target meaningful instead
    /// of dead. Rows whose id isn't in the local cache (cache hasn't
    /// synced yet) are no-ops — same graceful degradation we use
    /// elsewhere when the cache lags the server.
    @State private var noteToEdit: LocalNote?

    /// UserDefaults key for recent searches. Scoped under the bundle
    /// so a future "shared container with widget extension" wouldn't
    /// collide on the bare key.
    private static let recentSearchesKey = "io.mindkeeper.brain.recentSearches"

    /// Cap for the recent-searches list. Picked to fit a couple of
    /// scrolls of the recents section without overwhelming the
    /// initial empty-state view.
    private static let recentSearchesCap = 10

    /// Debounce window for keystroke-driven search. 300 ms is the
    /// same value the web search box uses — long enough that mid-
    /// word typing doesn't fire a request, short enough that the
    /// user perceives results as "live".
    private static let debounceMillis: UInt64 = 300_000_000

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search notes and todos"
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { _, newValue in
                    scheduleDebouncedSearch(newValue)
                }
                .task {
                    loadRecentSearches()
                }
                .onDisappear {
                    // M43 polish: cancel any in-flight debounced fetch
                    // when the user leaves the Search tab. Without this
                    // a slow request would keep running in the
                    // background, mutate `results` after we're off
                    // screen, and (worse) push a stale entry into the
                    // recents list once it resolved.
                    searchTask?.cancel()
                    searchTask = nil
                }
                .sheet(item: $noteToEdit) { note in
                    // Reuse the M40 edit dialog for any tapped result.
                    // See `noteToEdit` doc-comment for why we don't
                    // branch on `note.type` — appointments and plain
                    // notes get the same surface today.
                    EditTodoView(note: note)
                }
        }
    }

    // MARK: - Content branches

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            recentsView
        } else if isSearching && results.isEmpty {
            // First fetch in progress and we don't have a stale
            // result set to keep on screen — show a centred spinner.
            // Subsequent debounced fetches keep stale results visible
            // so the list doesn't flash empty mid-typing.
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            resultsList
        }
    }

    /// Shown when the field is empty: either the recents list or
    /// the iOS HIG-canonical empty search state.
    @ViewBuilder
    private var recentsView: some View {
        if recentSearches.isEmpty {
            ContentUnavailableView(
                "Search",
                systemImage: "magnifyingglass",
                description: Text("Find notes, todos, and appointments by title or content.")
            )
        } else {
            List {
                Section {
                    ForEach(recentSearches, id: \.self) { recent in
                        Button {
                            // M43 polish: light haptic on a recents
                            // tap — the field about to repopulate is
                            // a meaningful state change worth
                            // confirming by feel. Matches the
                            // TodoRow.toggle() / QuickAdd.submit()
                            // treatment.
                            BrainHaptics.light()
                            query = recent
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(recent)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                    .onDelete { offsets in
                        recentSearches.remove(atOffsets: offsets)
                        persistRecentSearches()
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") {
                            recentSearches = []
                            persistRecentSearches()
                        }
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    }
                }
            }
        }
    }

    /// Result list. Kept as a plain `List` so the system search bar's
    /// keyboard-dismiss-on-scroll behaves naturally and rows pick up
    /// the standard tap-to-select chrome.
    @ViewBuilder
    private var resultsList: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Section {
                ForEach(results, id: \.id) { note in
                    // Wrap each row in a Button so the entire row is
                    // tappable. We picked the `Button { selectedNote }`
                    // + `.sheet(item:)` pattern over `NavigationLink`
                    // here because (a) it matches what M35's
                    // ProjectListView already uses for "long-press →
                    // edit" so iOS feels uniform, and (b) the search
                    // result list shouldn't push onto the stack — the
                    // user wants to edit and bounce back to refine
                    // their query.
                    Button {
                        if let local = localNotesById[note.id] {
                            noteToEdit = local
                        }
                        // Cache miss: silently no-op. The most
                        // common cause is "user just signed in on a
                        // new device and the row hasn't synced yet"
                        // — surfacing an error here would be more
                        // confusing than just letting the next tap
                        // succeed once sync catches up.
                    } label: {
                        SearchResultRow(
                            note: note,
                            accentColor: SearchView.accentColor(
                                for: note,
                                projectsById: projectsById
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Debounce + fetch

    /// Cancel any in-flight fetch and schedule a new one 300 ms out.
    /// Empty query short-circuits — we just clear the result list and
    /// let `recentsView` take over.
    private func scheduleDebouncedSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        searchTask = Task { [trimmed] in
            try? await Task.sleep(nanoseconds: Self.debounceMillis)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    /// Hit `searchNotes(query:)` and update state. Stale results stay
    /// on screen until the new fetch resolves so the list doesn't
    /// flash empty mid-typing.
    private func runSearch(_ trimmed: String) async {
        guard let client else {
            errorMessage = "API client unavailable."
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let response = try await client.searchNotes(query: trimmed, limit: 50)
            // Guard against a late response landing after the user
            // typed past the query that fired this fetch. We only
            // keep the result if the trimmed live query still matches
            // what we asked for.
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }
            results = response.notes
            errorMessage = nil
            recordRecentSearch(trimmed)
        } catch let error as BrainAPIClient.Error {
            errorMessage = error.userFacingMessage
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Recent searches

    /// Read the persisted recent-search list from UserDefaults. We
    /// don't worry about migration — the schema has been a flat
    /// `[String]` since M43 introduction and is read tolerantly
    /// (missing key, wrong type, malformed entries all collapse to
    /// empty).
    private func loadRecentSearches() {
        let raw = UserDefaults.standard.array(forKey: Self.recentSearchesKey) as? [String]
        recentSearches = raw ?? []
    }

    /// Push `query` onto the recent-search list, dedupe, cap, write
    /// back. Called on every successful search rather than on every
    /// keystroke so single-letter half-typed queries don't poison
    /// the history.
    private func recordRecentSearch(_ query: String) {
        // Dedupe: drop existing entry, prepend, cap.
        var updated = recentSearches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        updated.insert(query, at: 0)
        if updated.count > Self.recentSearchesCap {
            updated.removeLast(updated.count - Self.recentSearchesCap)
        }
        recentSearches = updated
        persistRecentSearches()
    }

    /// Write the in-memory list back to UserDefaults. Synchronous —
    /// the list is tiny (<= 10 short strings) and the call is cheap
    /// enough to skip the Task hop.
    private func persistRecentSearches() {
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    // MARK: - Accent color resolution

    /// Resolve a result's project accent color, mirroring the same
    /// logic `TodayView` uses for its rows. Falls back to the system
    /// accent when the note has no project or the project's CSS
    /// colour string isn't in the palette.
    static func accentColor(
        for note: Note,
        projectsById: [String: LocalProject]
    ) -> Color {
        guard
            let projectId = note.todo?.projectId,
            let project = projectsById[projectId],
            let css = project.color
        else { return .accentColor }
        if let match = BrainColors.palette.first(where: { $0.cssValue == css }) {
            return match.color
        }
        return .accentColor
    }
}

/// Single row in the search-results list. Renders title + a one-line
/// snippet of body content, plus a trailing badge for type ("todo",
/// "note", "appointment") and the project pill when present.
///
/// We render against the wire `Note` DTO rather than a `LocalNote`
/// because the search endpoint returns rows the local cache may not
/// yet have. Hopping through `LocalNote` would mean either fetching
/// each id from SwiftData (extra queries per row) or skipping rows
/// the cache hasn't seen yet — both worse for a feature whose whole
/// point is "find things fast".
struct SearchResultRow: View {

    let note: Note
    let accentColor: Color

    private var displayTitle: String {
        if let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        // Fall back to the first line of content if no explicit
        // title — same convention TodoRow uses for the local cache.
        let firstLineRaw = note.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let firstLine = firstLineRaw.trimmingCharacters(in: .whitespaces)
        return firstLine.isEmpty ? note.content : firstLine
    }

    /// One-line snippet of additional context: due-date for todos,
    /// start-time for appointments, or the second line of content for
    /// plain notes. Matches the web search-result layout.
    private var subtitle: String? {
        if let todo = note.todo {
            var parts: [String] = []
            if let due = todo.dueDate, !due.isEmpty {
                parts.append(todo.completed ? "completed" : "due \(due)")
            } else if todo.completed {
                parts.append("completed")
            }
            if !todo.section.isEmpty, todo.section != "now" {
                parts.append("#\(todo.section)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if let appointment = note.appointment {
            if let start = appointment.startTime, !start.isEmpty {
                return "starts \(start)"
            }
            return nil
        }
        // Plain note — show the second line if the content has one,
        // skipping the title we already render above.
        let lines = note.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1 {
            let trailing = lines.dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return trailing.isEmpty ? nil : trailing
        }
        return nil
    }

    private var typeIcon: String {
        switch note.type {
        case "todo":
            return note.todo?.completed == true
                ? BrainSymbols.checkmarkCircle
                : BrainSymbols.circle
        case "appointment":
            return BrainSymbols.location
        default:
            return "doc.text"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: typeIcon)
                .font(.headline)
                .foregroundStyle(accentColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.callout)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !note.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(note.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Search — empty") {
    SearchView()
}
