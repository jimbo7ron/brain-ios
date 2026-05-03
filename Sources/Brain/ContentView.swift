// ContentView.swift
// brain-ios
//
// Root view. For M31 this is a placeholder: we show a "not signed in"
// state with a Sign In button (opens LoginPlaceholderView) and a gear
// icon to reach Settings. M32 will gate this on a Keychain-stored API
// key and route to the actual app once authenticated.

import SwiftUI

struct ContentView: View {

    @State private var showingLogin = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: BrainSymbols.appGlyph)
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(BrainColors.violet)
                    .accessibilityHidden(true)

                Text("brain")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))

                Text("Not signed in")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    showingLogin = true
                } label: {
                    Text("Sign in")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrainColors.violet)
                .padding(.horizontal, 32)
                .padding(.top, 16)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: BrainSymbols.settings)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingLogin) {
                LoginPlaceholderView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
}
