// NotificationPreferencesView.swift
// brain-ios
//
// M42 — per-category notification preferences. Reachable from the
// Settings tab when the user has granted notification permission. The
// view is a thin SwiftUI form over the
// `/api/v1/preferences/notifications` GET/PUT pair (see
// `BrainAPIClient.getNotificationPreferences` /
// `BrainAPIClient.updateNotificationPreferences`).
//
// Behaviour summary
// -----------------
// 1. On appear: GET the snapshot. Show `ProgressView` while loading;
//    show "Couldn't load" if the server isn't yet deployed (graceful
//    empty state — iOS may ship before the server-side M42 PR).
// 2. First-load timezone bootstrap: if the server returned the literal
//    `"UTC"` default (the server's M42 row default), and the device is
//    not in UTC, push the device timezone immediately so future morning
//    briefings fire at the user's local time.
// 3. Toggle taps update local state synchronously (optimistic UI) and
//    enqueue a 500 ms debounced PUT. Fast toggling does NOT spam the
//    server — only the latest state is sent after the debounce window.
// 4. PUT failure: leave the local state alone (the user can retry by
//    toggling again) and surface the error inline. v1 deliberately
//    skips automatic rollback — the toggle remembering its target
//    state is friendlier than snapping back, and a stale error banner
//    is the same signal as "your save didn't land".
//
// Out of scope (deferred)
// -----------------------
// - Timezone picker (M43 polish — read-only display for now).
// - Per-tag prefs (out of v1 scope per the M42 spec).
// - Quiet hours (M43+).

import SwiftUI

/// Per-category notification preferences form. Hosted from
/// `SettingsView` via a `NavigationLink` (gated on
/// `notificationManager.authorizationStatus == .authorized` — there's
/// no point letting the user tweak categories if push is off at the OS
/// level).
@MainActor
struct NotificationPreferencesView: View {

    @Environment(\.brainAPIClient) private var client

    /// Authoritative current preferences. `nil` until the first GET
    /// resolves (or fails). The form is keyed off this — a non-nil
    /// value means we have something the user can edit.
    @State private var prefs: NotificationPreferences?

    /// True only during the initial load. Subsequent saves don't flip
    /// this; the optimistic UI means the user shouldn't see a spinner
    /// during a debounced PUT.
    @State private var isLoading = false

    /// Last error from either GET or PUT, surfaced inline. Cleared on
    /// the next successful save so a transient blip doesn't sit on
    /// screen forever.
    @State private var errorMessage: String?

    /// Active debounced save. Cancelled when a new toggle fires so
    /// rapid taps coalesce into a single PUT after 500 ms.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            if let prefs {
                prefsForm(for: prefs)
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                // Server-side endpoints not deployed yet, network
                // error, or auth issue — show the same empty state in
                // all cases. The error banner below distinguishes them.
                Section {
                    Text("Couldn't load preferences")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Form sections

    @ViewBuilder
    private func prefsForm(for current: NotificationPreferences) -> some View {
        Section {
            Toggle("Enabled", isOn: binding(\.morningBriefingEnabled))
            if current.morningBriefingEnabled {
                TimePickerRow(time: binding(\.morningBriefingTime))
            }
        } header: {
            Text("Morning briefing")
        } footer: {
            Text("Daily summary of overdue + due-today items.")
        }

        Section {
            Toggle("Enabled", isOn: binding(\.dueRemindersEnabled))
        } header: {
            Text("Due reminders")
        } footer: {
            Text("Fires at the scheduled time on todos with a specific due time.")
        }

        Section {
            Toggle("Enabled", isOn: binding(\.dueTodayEnabled))
        } header: {
            Text("Due today")
        } footer: {
            Text("Once-a-day reminder at 9 AM for items due today with no specific time.")
        }

        Section {
            LabeledContent("Timezone", value: current.timezone)
        } footer: {
            // M43 polish will add a picker; for now, surface the value
            // so the user can sanity-check what their morning briefing
            // is anchored to.
            Text("Auto-synced from your device on first sign-in.")
        }
    }

    // MARK: - Bindings

    /// Build a two-way binding into a single field of `prefs`. The
    /// setter mutates the local copy and kicks the debounced save —
    /// every toggle/picker in the form goes through this one helper so
    /// the optimistic + debounced behaviour is uniform.
    ///
    /// The force-unwrap on `prefs!` is safe by construction: this
    /// helper is only called from `prefsForm(for:)`, which the body
    /// gates on `if let prefs`. Using the bang here (rather than a
    /// nil-coalescing default) means a regression — a binding leaking
    /// outside the gated branch — would crash loudly in DEBUG instead
    /// of silently writing to a sentinel struct.
    ///
    /// M43 polish — haptic on toggle changes: a `Bool` field flipping
    /// is a discrete commit the user actively chose, so we fire a
    /// light haptic before the debounced save. We deliberately skip
    /// non-Bool fields (e.g. the time picker) because a wheel-drag
    /// would otherwise fire dozens of haptics per gesture.
    private func binding<T>(_ keyPath: WritableKeyPath<NotificationPreferences, T>) -> Binding<T> {
        Binding(
            get: { self.prefs![keyPath: keyPath] },
            set: { newValue in
                if T.self == Bool.self {
                    BrainHaptics.light()
                }
                self.prefs?[keyPath: keyPath] = newValue
                self.scheduleDebouncedSave()
            }
        )
    }

    // MARK: - Loading

    /// Fetch the preferences snapshot. On a fresh account the server
    /// returns its row defaults, including `timezone = "UTC"`. We
    /// promote the device timezone in that case so the morning
    /// briefing fires at the user's local 8 AM rather than 8 AM UTC.
    private func load() async {
        guard let client else {
            errorMessage = "API client unavailable."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.getNotificationPreferences()
            // First-load timezone bootstrap. The server's M42 row
            // default is "UTC"; if that's what came back and the
            // device knows better, sync immediately. We swallow the
            // PUT error here — the GET-loaded prefs are still valid,
            // and the user can edit anything else without the tz
            // mismatch blocking them.
            if loaded.timezone == "UTC" {
                let deviceTZ = TimeZone.current.identifier
                if deviceTZ != "UTC" {
                    let update = NotificationPreferencesUpdate(timezone: deviceTZ)
                    if let bumped = try? await client.updateNotificationPreferences(update) {
                        prefs = bumped
                        return
                    }
                }
            }
            prefs = loaded
            errorMessage = nil
        } catch let apiError as BrainAPIClient.Error {
            // 404 here = server-side M42 endpoints not deployed yet
            // (we may ship the iOS PR first). Don't crash; the empty
            // state above renders gracefully.
            errorMessage = "Failed to load: \(apiError.userFacingMessage)"
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
    }

    // MARK: - Saving

    /// Cancel any in-flight save and schedule a fresh one 500 ms out.
    /// The 500 ms window is the same one the web `/settings` page
    /// uses; tight enough to feel responsive but loose enough that
    /// fast toggling (e.g. flipping a Section header expand/collapse
    /// that re-renders rows) collapses to a single PUT.
    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { [currentPrefs = prefs] in
            // 500 ms debounce. `Task.sleep` throws on cancel, which we
            // swallow with `try?` — cancellation is the expected path
            // when the user toggles again before the window expires.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let currentPrefs else { return }
            await save(currentPrefs)
        }
    }

    /// Push the current local snapshot to the server. Sends every
    /// editable field rather than just the changed one — the form is
    /// small, the server is forgiving, and "send everything" sidesteps
    /// race-window bugs where two debounced saves disagree on which
    /// field they were tracking. `timezone` is omitted because it's
    /// read-only in the M42 UI (the bootstrap path in `load()` is the
    /// only place we ever PUT it).
    private func save(_ snapshot: NotificationPreferences) async {
        guard let client else { return }
        let update = NotificationPreferencesUpdate(
            morningBriefingEnabled: snapshot.morningBriefingEnabled,
            morningBriefingTime: snapshot.morningBriefingTime,
            dueRemindersEnabled: snapshot.dueRemindersEnabled,
            dueTodayEnabled: snapshot.dueTodayEnabled
        )
        do {
            // Discard the response — the server returns a full
            // snapshot but it should match what we just sent. We
            // don't reassign `prefs` because that would clobber any
            // edit the user made between the debounce starting and
            // the response arriving (the next debounced save will
            // pick up the latest state anyway).
            _ = try await client.updateNotificationPreferences(update)
            errorMessage = nil
        } catch let apiError as BrainAPIClient.Error {
            errorMessage = "Failed to save: \(apiError.userFacingMessage)"
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Time picker row

/// Wraps a `DatePicker(displayedComponents: .hourAndMinute)` over a
/// `"HH:MM"` string binding. The form persists the time as a string so
/// DST transitions / device-locale changes don't silently drift the
/// user's intended fire time — `Date` would re-anchor against the
/// current calendar every render.
///
/// Edge cases:
/// - Malformed input ("garbage"): we fall back to midnight rather
///   than crashing. The server side defaults to `"08:00"` so the
///   only way this kicks in is a future DTO drift.
/// - Single-component input ("9"): we treat the missing minute as 0.
struct TimePickerRow: View {
    @Binding var time: String  // "HH:MM"
    @State private var date: Date

    init(time: Binding<String>) {
        self._time = time
        self._date = State(initialValue: Self.date(from: time.wrappedValue))
    }

    var body: some View {
        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
            .onChange(of: date) { _, newDate in
                time = Self.string(from: newDate)
            }
    }

    /// Parse `"HH:MM"` into a `Date` anchored to today's midnight in
    /// the current calendar. The date portion is irrelevant — only
    /// `.hour` and `.minute` are read by the picker — but using
    /// `Calendar.current.date(from:)` keeps the value timezone-correct
    /// for whichever locale the user has set.
    static func date(from raw: String) -> Date {
        let parts = raw.split(separator: ":")
        let hour = parts.first.flatMap { Int($0) } ?? 0
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    /// Format a `Date` back into the wire `"HH:MM"` shape. We zero-pad
    /// both components so the server's parser doesn't have to special-
    /// case `"9:5"` vs `"09:05"`.
    static func string(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
}

#Preview {
    NavigationStack {
        NotificationPreferencesView()
    }
}
