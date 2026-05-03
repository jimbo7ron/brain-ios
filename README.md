# brain-ios

Native iOS app for [brain](https://github.com/jimbo7ron/brain) — the personal
knowledge / todo / appointment system at [mindkeeper.io](https://mindkeeper.io).

This repo is mirrored from the brain server's data model and uses the public
HTTP API at `https://api.mindkeeper.io`. SwiftUI + SwiftData, iOS 17+.

> **Status:** M31 (project foundation). Builds and launches but doesn't do
> anything yet. See the [iOS roadmap](https://github.com/jimbo7ron/brain/blob/main/docs/ios-roadmap.md)
> for the full milestone plan.

## Prerequisites

- macOS with Xcode 15 or later (iOS 17 SDK).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — generates the
  `.xcodeproj` from `project.yml` so we don't have to commit a giant pbxproj.
- [SwiftLint](https://github.com/realm/SwiftLint) — style/lint checks (CI runs
  `swiftlint --strict`).

```bash
brew install xcodegen swiftlint
```

## Getting started

```bash
git clone https://github.com/jimbo7ron/brain-ios.git
cd brain-ios
xcodegen generate
open Brain.xcodeproj
```

Then in Xcode: pick an iPhone simulator and hit Run. The app launches to a
placeholder login screen. Nothing else is wired up yet — login lands in M32.

## Configuring the server

The default server URL is `https://api.mindkeeper.io`. To point the app at a
different server (e.g. a local `brain serve` instance):

- Edit it in-app under **Settings → Server URL**, or
- Set the `BRAIN_SERVER_URL` environment variable in the Xcode scheme
  (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables).

The chosen URL is persisted in the iOS Keychain alongside the API key so it
survives app restarts.

## Layout

```
brain-ios/
├── project.yml                   # XcodeGen spec — single source of truth
├── .swiftlint.yml                # lint config
├── Sources/Brain/
│   ├── BrainApp.swift            # @main, sets up SwiftData ModelContainer
│   ├── ContentView.swift         # placeholder root view
│   ├── Networking/               # BrainAPIClient (actor), DTOs
│   ├── Storage/                  # KeychainStore, SwiftData models
│   ├── Theme/                    # color palette, SF Symbol map
│   └── Views/                    # LoginPlaceholderView, SettingsView
└── .github/workflows/ci.yml      # SwiftLint on PRs
```

The `.xcodeproj` is **not** committed — regenerate it with `xcodegen generate`
whenever `project.yml` changes or when you first clone the repo.

## Roadmap

See [`docs/ios-roadmap.md`](https://github.com/jimbo7ron/brain/blob/main/docs/ios-roadmap.md)
in the brain repo for the full M28–M44 plan. Short version:

- **Phase 1** (M31–M33): foundation, login, read-only sync.
- **Phase 2** (M34–M36): Today, Project list/detail, toggle complete.
- **Phase 3** (M37–M40): mutation queue, conflicts, quick add, edit flows.
- **Phase 4** (M41–M42): APNs push notifications + preferences.
- **Phase 5** (M43–M44): polish, App Icon, TestFlight.

## License

[MIT](LICENSE).
