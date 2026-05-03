// SettingsView.swift
// brain-ios
//
// Settings screen. Users can view / edit the server URL (default
// https://api.mindkeeper.io). The server URL is persisted in Keychain
// alongside the API key so it survives app reinstalls and lives next
// to the credential it pairs with.
//
// Sign-out moved to the signed-in placeholder view in M32 so it can
// own the full revoke + wipe + auth-state-flip flow; keeping it in
// two places risked partial-revoke states.

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

                if let status = statusMessage {
                    Section {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Bundle id", value: "io.mindkeeper.brain")
                    LabeledContent("Roadmap milestone", value: "M32")
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

}

#Preview {
    SettingsView()
}
