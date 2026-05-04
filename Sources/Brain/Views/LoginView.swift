// LoginView.swift
// brain-ios
//
// Real login screen — replaces the M31 `LoginPlaceholderView`. Posts to
// `POST /api/v1/auth/login` with a `device_name` so the M30 server
// auto-mints a named API key and inlines it on the response. We stash
// the api_key plaintext (account `.apiKey`), the api_key id
// (`.apiKeyId`), the user id (`.userId`) and the user's email
// (`.userEmail`) in Keychain, push the API key into the shared
// `BrainAPIClient` actor, and finally call
// `authSession.didSignIn(...)` — ContentView observes the session
// and re-renders into the signed-in UI.
//
// JWTs from the login response are intentionally discarded: the
// named API key is what we use for ongoing requests (it's longer
// lived, it's what gets revoked on sign-out, and it produces clean
// per-device audit attribution server-side via `X-API-Key`). See
// `BrainAPIClient.apiKey` for the full rationale.
//
// Design intentionally mirrors the web login screen
// (`web/src/app/login/login-form.tsx`): brand mark + "brain" wordmark,
// "Sign in to your second brain." subtitle, single primary action in
// our violet accent.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LoginView: View {

    @Environment(\.brainAPIClient) private var apiClient
    @Environment(AuthSession.self) private var authSession
    @Environment(\.notificationManager) private var notificationManager

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: BrainSymbols.appGlyph)
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(BrainColors.violet.color)
                .accessibilityHidden(true)

            Text("brain")
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            Text("Sign in to your second brain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            Button {
                submit()
            } label: {
                ZStack {
                    // Reserve the button's height so the spinner doesn't
                    // shrink the row when isSubmitting flips.
                    Text("Sign in").bold().opacity(isSubmitting ? 0 : 1)
                    if isSubmitting {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrainColors.violet.color)
            .disabled(email.isEmpty || password.isEmpty || isSubmitting)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    // MARK: - Actions

    @MainActor
    private func submit() {
        guard let apiClient else {
            // Should never happen in practice — BrainApp injects the
            // client at the root scene — but report it rather than
            // silently no-op'ing so a misconfigured environment is
            // visible instead of confusing.
            errorMessage = "Configuration error — please report."
            return
        }

        // `UIDevice.current.name` is @MainActor-isolated under strict
        // concurrency. We're already on the main actor here (SwiftUI
        // button callbacks run on it), so capture the value before
        // hopping into the Task.
        let deviceName = Self.deviceName()
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPassword = password

        isSubmitting = true
        errorMessage = nil

        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let response = try await apiClient.login(
                    email: trimmedEmail,
                    password: submittedPassword,
                    deviceName: deviceName
                )

                // Persist creds. Each `try` is wrapped so a single
                // Keychain hiccup doesn't leave us partially signed-in.
                //
                // Order: write Keychain first, then update the API
                // client's key, then flip the AuthSession last.
                // ContentView observes `authSession.state` and will
                // re-render synchronously on the flip — by that
                // point Keychain and the API client are already
                // consistent so any immediately-fired authenticated
                // request reads the right key.
                if let mintedKey = response.apiKey {
                    try KeychainStore.save(mintedKey.key, for: .apiKey)
                    try KeychainStore.save(mintedKey.id, for: .apiKeyId)
                    await apiClient.setApiKey(mintedKey.key)
                }
                try KeychainStore.save(response.userId, for: .userId)
                try KeychainStore.save(response.email, for: .userEmail)

                authSession.didSignIn(userId: response.userId, email: response.email)

                // M41: kick APNs registration once the session is
                // established. Fire-and-forget — registration is
                // intentionally non-load-bearing; we don't block the
                // UI on the permission prompt or the device-register
                // round-trip, and a denial / failure leaves the user
                // signed in normally. NotificationManager owns the
                // permission state so subsequent calls are idempotent
                // (no second prompt if the user already responded).
                if let notificationManager {
                    Task { @MainActor in
                        await notificationManager.requestAuthorizationAndRegister()
                    }
                }
            } catch let error as BrainAPIClient.Error {
                errorMessage = error.userFacingMessage
            } catch let error as KeychainError {
                errorMessage = "Couldn't save credentials: \(error)"
            } catch {
                errorMessage = "Couldn't reach the server. Check your connection."
            }
        }
    }

    /// Build the `device_name` sent on the login request. Read on the
    /// main actor (UIKit isolation) so we don't trip strict concurrency.
    @MainActor
    private static func deviceName() -> String {
        #if canImport(UIKit)
        return "iPhone — \(UIDevice.current.name)"
        #else
        return "iPhone"
        #endif
    }
}

#Preview {
    LoginView()
        .environment(AuthSession(state: .signedOut))
}
