// SettingsView.swift
// brain-ios
//
// M31 settings screen. Users can:
//   - View / edit the server URL (default https://api.mindkeeper.io)
//   - "Sign out" — clears Keychain (no server-side revoke yet; M32 adds
//     the DELETE /auth/api-keys/{id} call)
//
// The server URL is persisted in Keychain alongside the (eventual) API
// key so it survives app reinstalls and lives next to the credential
// it pairs with.

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String = ""
    @State private var savedServerURL: String = ""
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    Button(role: .destructive) {
                        signOut()
                    } label: {
                        Label("Sign out", systemImage: BrainSymbols.signOut)
                    }
                } footer: {
                    if let status = statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Bundle id", value: "io.mindkeeper.brain")
                    LabeledContent("Roadmap milestone", value: "M31")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                loadServerURL()
            }
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

    private func signOut() {
        // M32 will issue a DELETE /auth/api-keys/{id} before wiping
        // Keychain so the device key is revoked server-side. For now,
        // the local wipe is a no-op for the user (nothing's stored yet)
        // but the call exercises the code path.
        do {
            try KeychainStore.wipe()
            statusMessage = "Signed out (local wipe only — server revoke lands in M32)."
        } catch {
            statusMessage = "Couldn't sign out: \(error)"
        }
    }
}

#Preview {
    SettingsView()
}
