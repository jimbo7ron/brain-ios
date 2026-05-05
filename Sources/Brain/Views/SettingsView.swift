// SettingsView.swift
// brain-ios
//
// Settings screen. Users can view / edit the server URL (default
// https://api.mindkeeper.io) and sign out. The server URL is
// persisted in Keychain alongside the API key so it survives app
// reinstalls and lives next to the credential it pairs with.
//
// In M34 this view also hosts the signed-in user's email and the
// "Sign out" button — the M32 placeholder view that previously owned
// sign-out has been replaced by the Today view, so the action moves
// here. Sign-out still drives the full revoke + Keychain wipe +
// `AuthSession.signedOut()` flow; we just relocated the surface.
// Settings is a sheet during sign-in (toolbar gear) and a tab once
// signed in (`SignedInRootView`), so this single screen serves both
// presentations without redesign — that's M43's job.

import SwiftUI
#if canImport(UserNotifications)
import UserNotifications
#endif

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.brainAPIClient) private var apiClient
    @Environment(AuthSession.self) private var authSession
    @Environment(\.mutationQueue) private var mutationQueue
    @Environment(\.notificationManager) private var notificationManager

    @State private var serverURL: String = ""
    @State private var savedServerURL: String = ""
    @State private var statusMessage: String?
    @State private var isSigningOut: Bool = false

    /// Mirrors the `@AppStorage("compactDensity")` flag read in
    /// `BrainApp` — the same key, so changes here propagate to the
    /// app-root `.dynamicTypeSize` modifier without further plumbing.
    /// Defaults to `true` so first launches start in the user-
    /// requested denser layout; flipping the toggle persists across
    /// relaunches via `UserDefaults`.
    @AppStorage("compactDensity") private var compactDensity: Bool = true

    /// Hide the "Done" toolbar button when this view is presented as a
    /// tab (no sheet to dismiss). The presence of an injected
    /// `dismiss` action isn't enough on its own — SwiftUI always
    /// provides one — so callers presenting as a tab pass `false` to
    /// suppress the button.
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = true) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            Form {
                if let email = authSession.email {
                    Section {
                        LabeledContent("Signed in as", value: email)
                    }
                }

                Section("Display") {
                    Toggle("Compact density", isOn: $compactDensity)
                        .accessibilityHint("Shrinks the UI by ~15% to fit more on screen.")
                }

                Section {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Defaults to https://api.mindkeeper.io. Override to point at " +
                         "a local `brain serve` instance for development.")
                        .font(.caption)
                }

                Section {
                    Button {
                        saveServerURL()
                    } label: {
                        Text("Save server URL")
                    }
                    .disabled(serverURL == savedServerURL || serverURL.isEmpty)
                }

                if let status = statusMessage {
                    Section {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if authSession.isSignedIn {
                    notificationsSection

                    Section {
                        Button(role: .destructive) {
                            isSigningOut = true
                            Task { @MainActor in
                                await signOut()
                                isSigningOut = false
                            }
                        } label: {
                            Label("Sign out", systemImage: BrainSymbols.signOut)
                        }
                        .disabled(isSigningOut)
                    }
                }

                Section {
                    LabeledContent("Bundle id", value: "io.mindkeeper.brain")
                    LabeledContent("Roadmap milestone", value: "M43")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                loadServerURL()
                // Refresh permission state every time the screen
                // appears — the user can flip the system toggle in
                // Settings.app while the app is backgrounded, and
                // the only way to notice is to re-read on next mount.
                await notificationManager?.refreshAuthorizationStatus()
            }
        }
    }

    // MARK: - Notifications section (M41)

    /// Renders the current APNs authorization status and offers an
    /// action button matching the state. The view is intentionally
    /// minimal — full preferences UI (per-category toggles, quiet
    /// hours) is M42's territory.
    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            LabeledContent("Permission", value: notificationStatusLabel)
            notificationActionButton
            // M42: only expose the per-category preferences once the
            // user has actually granted notification permission. If
            // permission is denied or not yet determined, there's
            // nothing the prefs page can do for them — the OS-level
            // toggle dominates, and every category would be silently
            // suppressed regardless of what they tweak here.
            if notificationManager?.authorizationStatus == .authorized {
                NavigationLink {
                    NotificationPreferencesView()
                } label: {
                    Label("Preferences", systemImage: "bell.badge")
                }
            }
            if let lastError = notificationManager?.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Used for due-date reminders and the morning briefing. " +
                 "Push delivery requires the brain server to be configured " +
                 "with an APNs key — registration here just stores the " +
                 "device token.")
                .font(.caption)
        }
    }

    /// Action button whose label and behaviour depend on the current
    /// permission status. We branch on the raw enum (rather than
    /// rendering both buttons unconditionally) so the row stays
    /// uncluttered and the affordance is unambiguous.
    @ViewBuilder
    private var notificationActionButton: some View {
        let status = notificationManager?.authorizationStatus ?? .notDetermined
        switch status {
        case .denied:
            // The only path back to granted is the system Settings
            // app — `requestAuthorization` is one-shot, so a denial
            // is sticky from the SDK's point of view.
            Button {
                notificationManager?.openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: BrainSymbols.settings)
            }
        case .notDetermined:
            // Prompt hasn't been shown yet (or was somehow reset).
            // Same code path as the sign-in trigger — idempotent.
            Button {
                Task { @MainActor in
                    await notificationManager?.requestAuthorizationAndRegister()
                }
            } label: {
                Label("Enable notifications", systemImage: "bell.badge")
            }
        case .authorized, .provisional, .ephemeral:
            // No action — the user has granted permission. Settings
            // app remains the only place to revoke, but we don't
            // need a button for that (Apple's HIG prefers users go
            // through Settings.app for permission revocation).
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    /// Human-readable rendering of `UNAuthorizationStatus`. The system
    /// API doesn't ship with a `description`, so we map the four cases
    /// we actually surface.
    private var notificationStatusLabel: String {
        let status = notificationManager?.authorizationStatus ?? .notDetermined
        switch status {
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    // MARK: - Actions

    private func loadServerURL() {
        let stored = (try? KeychainStore.load(.serverURL)) ?? nil
        let initial = stored ?? defaultBrainServerURL.absoluteString
        serverURL = initial
        savedServerURL = initial
    }

    private func saveServerURL() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else {
            statusMessage = "That doesn't look like a valid URL."
            return
        }
        do {
            try KeychainStore.save(trimmed, for: .serverURL)
            savedServerURL = trimmed
            statusMessage = "Server URL saved."
        } catch {
            statusMessage = "Couldn't save: \(error)"
        }
    }

    /// Sign-out flow lifted from the M32 ContentView. Order matters:
    /// best-effort revoke (network) -> wipe queue -> wipe Keychain
    /// -> clear API client -> flip session. The session flip lands
    /// last so any view that re-renders on `.signedOut` (e.g.
    /// LoginView) reads a consistent post-wipe state.
    ///
    /// Queue-wipe placement: we clear the queue between the revoke
    /// and the Keychain wipe so that a network-revoke failure (which
    /// short-circuits before we reach `clear()`) leaves the queue
    /// intact — the user might tap "Sign out" again after the
    /// network recovers. Once revoke succeeds we commit to the
    /// local wipe; the queue must go with it, otherwise User A's
    /// queued mutations would replay against User B's tenant after
    /// a sign-in switch. We also wipe if there's no key id to
    /// revoke (already-broken state) since there's nothing to
    /// preserve.
    @MainActor
    private func signOut() async {
        let keyId = (try? KeychainStore.load(.apiKeyId)) ?? nil
        if let keyId, let apiClient {
            do {
                try await apiClient.revokeApiKey(id: keyId)
            } catch {
                // Revoke failed — leave the queue and Keychain
                // alone so the user can retry sign-out once the
                // network is healthy again. Surface the failure as
                // an inline message so the button isn't a silent
                // no-op.
                statusMessage = "Couldn't sign out (revoke failed): \(error). Try again."
                return
            }
        }
        mutationQueue?.clear()
        try? KeychainStore.wipe()
        await apiClient?.setApiKey(nil)
        authSession.signedOut()
        // M43 polish: medium haptic on the success path only. The
        // revoke-failure branch above returns early without flipping
        // the session, so a stronger "you've actually signed out"
        // confirmation here is meaningful — matches the EditTodoView
        // Save treatment for committed mutations.
        BrainHaptics.medium()
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(state: .signedIn(userId: "preview", email: "preview@example.com")))
}
