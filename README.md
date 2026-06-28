# brain-ios

Native iOS app for [brain](https://github.com/jimbo7ron/brain) — the personal
knowledge / todo / appointment system at [mindkeeper.io](https://mindkeeper.io).

This repo is mirrored from the brain server's data model and uses the public
HTTP API at `https://api.mindkeeper.io`. SwiftUI + SwiftData, iOS 17+.

> **Status:** v0.1 shipped to internal **TestFlight** on
> 2026-05-05 as **Mindkeeper** ([App Store
> Connect](https://appstoreconnect.apple.com) → My Apps → Mindkeeper,
> bundle id `io.mindkeeper.brain`). The home-screen icon is still
> labelled **brain** — the App Store name "brain" was taken, so the
> store listing uses *Mindkeeper* (matching the
> [mindkeeper.io](https://mindkeeper.io) domain) while
> `CFBundleDisplayName` keeps the original *brain* name for the
> lock-/home-screen tile.
>
> v0.1 ships **without push notifications** — APNs registration code
> (M41/M42) is in the tree but disabled until a `.p8` APNs auth key
> lands on the prod server. Push returns in v0.2. Everything else
> from M30–M43 is in: email/password sign-in, incremental read sync,
> queued/replayed writes with idempotency keys, Today / Projects /
> Quick add / edit / Search tabs, swipe-to-archive on todos, dark
> mode, haptics, and "What's due in Brain?" / "Add to Brain: …" Siri
> triggers. See the
> [iOS roadmap](https://github.com/jimbo7ron/brain/blob/main/docs/ios-roadmap.md)
> for the full milestone plan.
>
> **v0.2 in flight (M45 — Write Coordinator):** every CRUD path now
> flows through a single `Repository` contract with optimistic UI,
> server reconcile under a last-write-wins guard, an app-wide status
> pill, and per-row pending / failed indicators. Section ops are
> optimistic too. See [`docs/M45-write-coordinator.md`](docs/M45-write-coordinator.md).

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

Then in Xcode: pick an iPhone simulator and hit Run. The app launches to the
login screen — sign in with your brain account email + password and the
server auto-mints a device API key for the app to use. Sync engine + UI
content lands in M33/M34.

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
├── Brain.entitlements            # APNs (`aps-environment`) entitlement (M41)
├── .swiftlint.yml                # lint config
├── Sources/Brain/
│   ├── BrainApp.swift            # @main, sets up SwiftData ModelContainer
│   ├── ContentView.swift         # auth-state-driven root router
│   ├── Assets.xcassets/          # AppIcon (M43), AccentColor (M43)
│   ├── Intents/                  # App Intents — Siri "What's due", "Add a todo" (M43)
│   ├── Networking/               # BrainAPIClient (actor), DTOs
│   ├── Notifications/            # NotificationManager + AppDelegate adapter (M41)
│   ├── Parsing/                  # quick-add NLP (M39)
│   ├── Storage/                  # KeychainStore, SwiftData models
│   ├── Sync/                     # SyncEngine + MutationQueue
│   ├── Theme/                    # color palette, SF Symbol map, BrainHaptics (M43)
│   └── Views/                    # LoginView, Today, Projects, Search (M43), SettingsView, QuickAdd
└── .github/workflows/ci.yml      # SwiftLint on PRs
```

The `.xcodeproj` is **not** committed — regenerate it with `xcodegen generate`
whenever `project.yml` changes or when you first clone the repo.

## TestFlight builds

Before each archive uploaded to App Store Connect, **bump
`CURRENT_PROJECT_VERSION` in `project.yml`** (1 → 2 → 3 …) and re-run
`xcodegen generate`. App Store Connect rejects uploads whose
`(MARKETING_VERSION, CURRENT_PROJECT_VERSION)` pair has been seen
before, so re-archiving without a bump fails with a duplicate-build
error. `MARKETING_VERSION` only needs to change between
user-facing releases (0.1.0 → 0.2.0).

## Releases

- **v0.4.0 (build 4) — 2026-06-29** — failed-mutation recovery. The
  toolbar status pill's red "⚠ M" indicator is now tappable: it opens
  a **Failed changes** sheet listing each poisoned queue row (the
  action in plain language, the resource, and the captured error) with
  per-row **Retry** / **Discard** plus Retry-all / Discard-all. Retry
  un-poisons the row and kicks a replay; discard drops it. Surfaces a
  recovery path that previously only existed via Console logs or a
  debug-menu queue drain (PR #42).
- **v0.2.x — Write Coordinator (M45, in flight 2026-05-06)** — every
  iOS write (add / edit / archive / section add / section rename)
  goes through a single `Repository` contract with optimistic UI:
  the change appears instantly, the server response reconciles in
  the background, and a last-write-wins guard prevents server-derived
  fields (NLP-extracted titles, slugs) from clobbering local edits
  the user has made since dispatch. New status pill in the toolbar
  surfaces pending / failed mutations app-wide; per-row spinners and
  red dots show in-flight or failed todos. Section operations are
  optimistic too via `OptimisticCompositeStub`. Internal-only
  refactor — see [`docs/M45-write-coordinator.md`](docs/M45-write-coordinator.md)
  for the architecture.
- **v0.1.0 (build 1) — 2026-05-05** — first internal TestFlight build,
  shipped as *Mindkeeper*. Includes basic CRUD across notes / todos /
  appointments, swipe-to-archive on todos, compact-density list
  rows, dark mode, haptics, Siri shortcuts, and Search.
  *Not in v0.1:* push notifications (waiting on APNs `.p8` on the
  prod server), final app icon (placeholder only).

## Architecture

iOS writes flow through a single `Repository` contract (M45). Every
mutation (create / update / archive / section op) is dispatched
optimistically: the local SwiftData store is updated immediately, a
queued mutation is sent to the server, and the response is reconciled
back into the store under a per-field last-write-wins guard so
server-derived fields (e.g. NLP-parsed titles, generated slugs) flow
back without overwriting local edits the user has typed since
dispatch. Pending / failed state is exposed via `MutationStatusStore`
and rendered as a toolbar status pill plus per-row indicators. See
[`docs/M45-write-coordinator.md`](docs/M45-write-coordinator.md).

## Roadmap

See [`docs/ios-roadmap.md`](https://github.com/jimbo7ron/brain/blob/main/docs/ios-roadmap.md)
in the brain repo for the full M28–M44 plan. Short version:

- **Phase 1** (M31–M33): foundation, login, read-only sync.
- **Phase 2** (M34–M36): Today, Project list/detail, toggle complete.
- **Phase 3** (M37–M40): mutation queue, conflicts, quick add, edit flows.
- **Phase 4** (M41–M42): APNs push notifications + preferences.
- **Phase 5** (M43–M44): polish, App Icon, TestFlight (v0.1 shipped 2026-05-05).

## License

[MIT](LICENSE).
