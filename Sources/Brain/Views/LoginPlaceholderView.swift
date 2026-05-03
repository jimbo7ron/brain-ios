// LoginPlaceholderView.swift
// brain-ios
//
// M31 placeholder — shows the email/password fields and a "Sign in"
// button but doesn't actually authenticate. M32 will fill in the
// `BrainAPIClient.login(...)` call and Keychain storage.
//
// We deliberately keep the visual shape final-ish (matching the web
// design) so M32 is purely behavioural — no big layout reshuffle.

import SwiftUI

struct LoginPlaceholderView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@example.com", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Login isn't wired up yet — this is the M31 placeholder. " +
                         "Coming in M32: server auto-mints a device key on login.")
                        .font(.caption)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task { await attemptLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text("Sign in")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isWorking)
                }
            }
            .navigationTitle("brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Stub — M32 replaces this with a real call to
    /// `BrainAPIClient.login(...)` and stashes the returned API key in
    /// Keychain.
    private func attemptLogin() async {
        isWorking = true
        defer { isWorking = false }
        // Tiny artificial delay so the spinner shows up; remove in M32.
        try? await Task.sleep(nanoseconds: 400_000_000)
        errorMessage = "Login lands in M32. Stay tuned."
    }
}

#Preview {
    LoginPlaceholderView()
}
