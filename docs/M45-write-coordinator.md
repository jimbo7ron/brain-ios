# M45 — Write Coordinator (iOS Phase 6)

**Status**: SPEC — not implemented
**Drafted**: 2026-05-05
**Author**: drafted by Claude Opus 4.7, reviewed by an iOS-architecture specialist agent
**Supersedes**: PR #33 (`claude/optimistic-add-everywhere`) — that PR's tactical fixes are absorbed into Wave 2 of this milestone

## 1. Problem

Every iOS write today is hand-rolled at the call site. The contract for "user mutates something" is approximately:

```swift
// 1. mutate SwiftData
modelContext.insert(stub)            // or note.field = newValue
try? modelContext.save()
// 2. encode payload
let body = try JSONEncoder().encode(payload)
// 3. enqueue mutation
mutationQueue.enqueue(.createTodo(clientId, body))
// 4. dismiss
dismiss()
```

This contract is repeated ~15 times across `QuickAddView`, `ProjectDetailView`, `UnassignedDetailView`, `NewProjectView`, `EditTodoView`, `EditProjectView`, `TodoRow.archive`, `TodoRow.toggleComplete`, and growing. PR #31 fixed one site; PR #33 fixed four more; the user (correctly) flagged this as a smell:

> "shouldn't this be ALL CRUD paths? Maybe we should think more architecturally?"

The duplication is worse than just LOC: each site has subtly different error handling, some skip the rollback path, some `await` the network round-trip, some don't, and the section-rename + sortOrder paths are still entirely round-trip-blocked. The next CRUD surface added will repeat the dance, and the next reviewer will catch a regression that exists because the contract isn't centralised.

## 2. Goals

- Single contract: every iOS write goes through one Repository entry point.
- Optimistic local mutation by default. Views never see the network.
- Generalised reconcile: the create-echo / id-rename / pending-mutation rewrite ceremony lives once, not per entity.
- Update-response reconcile: server-canonical fields flow back to local state under LWW protection — closes the silent-divergence window.
- Surfaceable failure state: the UI can render "N pending writes / M failed" and per-row indicators without polluting `LocalNote`.
- Migration is parallel-shadow, not big-bang. Every wave's PR builds clean and ships independently.

## 3. Non-goals

- **sortOrder / drag-reorder** — multi-record renumbering is its own design problem (FIFO ordering vs LWW base comparison across siblings). Tracked as a follow-up milestone, not addressed here. The Repository will expose a `repo.reorder(...)` placeholder that throws `unimplemented`.
- **Rewriting MutationQueue** — the queue's enqueue / replay / retry / poison-class logic stays. Only the reconcile internals are refactored.
- **Bumping deploy target** — stays on iOS 17. iOS 18 SwiftData additions (`#Index`, `#Unique`, `willSave/didSave` notifications) would help marginally but aren't load-bearing.
- **Server-side changes** — none. Client-supplied UUIDs still aren't accepted (we bridge with reconcile rename); idempotency-key-only-caches-2xx is a known small risk, separate fix.

## 4. Architecture decisions

Reflects feedback from the iOS specialist review:

### 4.1 Three ModelContexts, one container

Repository owns its own `ModelContext`, separate from the SwiftUI environment context and the queue's context. All three are constructed in `BrainApp.init` against the same `ModelContainer`. SwiftData's SQLite-backed save propagation is what makes cross-context observation work — preserve the comment at `MutationQueue.swift:450-460`, repeat the pattern.

Repository must not share the SwiftUI environment context. The Repository's lifetime is the app, not the view tree.

### 4.2 No protocol-with-associatedtype generic reconcile

The strawman proposed `protocol ReconcilableEntity: PersistentModel { associatedtype ServerDTO; ... }` with a generic `reconcileCreate<T>(...)`. The specialist (correctly) shot this down:

- `#Predicate` macro doesn't accept generic type parameters cleanly on iOS 17 — `FetchDescriptor<T>(predicate: #Predicate { $0.id == clientId })` either fails to compile or runtime-faults.
- `@Model` macro's synthesised init doesn't satisfy a protocol that requires `init()`.
- The shared part across reconcile paths is the *ceremony* (B1 dedupe + B2 rewrite + stub fetch). The *field copy* differs meaningfully between entities (notes copy ~22 fields including substructures, projects copy 7 + the M26 default-section re-mirror). Generic abstraction hides only ~15 lines and forces every future entity to fit a contract that doesn't naturally fit.

Use a smaller "ceremony-only" protocol:

```swift
protocol OptimisticStub: PersistentModel {
    static func makeFetchByID(_ id: String) -> FetchDescriptor<Self>
    func adoptServerID(_ newID: String)
}
```

The B1 dedupe + B2 pending-mutation rewrite + stub fetch happens once, generic over `T: OptimisticStub`. The field copy stays per-entity — passed in as a closure or called via a non-generic `MutationOp` switch. Each concrete model declares its own `#Predicate`-based fetch descriptor where the macro is happy.

### 4.3 Update-response reconcile under LWW guard

Today, `updateTodo` discards the server response. The server applies derivations (server-extracted title from content, server-recomputed `updatedAt`, etc.) that the client doesn't replicate. Between dispatch and the next sync (up to 5 minutes), local state silently diverges from server.

Plumb the update response through `MutationResult.note(let updated)` and apply it under the M38 LWW guard: if a *second* pending mutation exists for the same id with a `baseUpdatedAt` matching the response's pre-state, drop the response copy (the user has edited again — don't clobber). Otherwise apply. ~15 lines, removes a class of "why did my edit revert" bugs.

### 4.4 MutationStatusStore — separate observable, not a model column

UI needs both:
- Queue-level: "N pending / M failed" banner. Today's `MutationQueue.lastError`, `pendingCount`, `conflictsResolved` already cover this once we add a `failedCount` derived from rows where `nextRetryAt == .distantFuture`.
- Per-row: spinner / red dot on individual notes that are mid-flight or have failed.

Per-row state lives in a separate `@Observable MutationStatusStore` keyed `[String: Status]` where the key is the note's *current* id. The Repository populates on enqueue, the queue clears on success, the rollback path marks `.failed`. The B2 reconcile ceremony rewrites the key from clientID → serverID in lock-step.

Do not put `syncStatus` on `LocalNote`. It's transient state, doesn't survive app restart, and isn't the model's concern. (Bear shipped this and got bitten by ghost-pending rows after force-quit.)

### 4.5 Multi-step ops are first-class

`renameSection`, `addSection`, future `mergeProject` etc. are atomic from the user's POV. Don't compose them from `repo.update` calls. Add explicit methods that own the optimistic application + reconcile of the whole batch.

## 5. The contract

After M45 lands, iOS code conforms to:

- **Views never call** `modelContext.insert/save` directly for entities owned by a Repository.
- **Views never call** `client.create*` / `client.update*` / `client.archive*` directly. Always via Repository.
- **Views never call** `mutationQueue.enqueue` directly. Repository owns enqueueing.
- **Views may read** `MutationStatusStore` and `MutationQueue.pendingCount/lastError/failedCount` for UI affordances.
- **Sync engine still owns reads** (the unified delta feed). Repository is write-only.
- **App Intents / AppDelegate callbacks** also call through Repository (or a parallel Intent-safe variant — see §8.1).

A lint rule (`swiftlint custom_rules` regex on `\.modelContext\.insert\(` outside `Repository`/`Sync` modules) makes the contract enforceable.

## 6. Components

### 6.1 NoteRepository

```swift
@MainActor
@Observable
final class NoteRepository {
    @discardableResult
    func create(_ payload: CreateNotePayload) -> LocalNote
    func update(_ note: LocalNote, _ fields: NoteUpdateFields)
    func toggleComplete(_ note: LocalNote)
    func archive(_ note: LocalNote)
    func unarchive(_ note: LocalNote)
}
```

Notes:
- `update` takes a typed `NoteUpdateFields` struct (10 fields: `content`, `title`, `url`, `dueDate`, `priority`, `projectId`, `section`, `startTime`, `endTime`, `location`), not a closure mutating the LocalNote, so the diff is explicit and serialisable. `dueTime` and `recurrence` are intentionally omitted — the server's `NoteUpdate` schema has no matching keys, so any value would be silently dropped on the wire. `LocalNote.dueTime` / `LocalNote.recurrence` still exist and are surfaced via SyncEngine pull.
- Nullable-update sentinel semantics today follow `UpdateNotePayload`'s existing convention (`"none"` clears `dueDate`, `""` clears `url`, `"unassigned"` clears `projectId`). Wave 3 will likely unify these via a typed `.clear` enum or `Optional<Optional<T>>` — flagged as `TODO(M45 Wave 3)`.
- `create` returns the optimistic stub so the caller can navigate to it / select it. The id will be a client UUID until reconcile renames it.
- `archive` is a soft delete (server `DELETE` = archived flip). No separate `delete` until v2.

### 6.2 ProjectRepository

```swift
@MainActor
@Observable
final class ProjectRepository {
    @discardableResult
    func create(_ payload: CreateProjectPayload) -> LocalProject
    func update(_ project: LocalProject, _ fields: ProjectUpdateFields)
    func archive(_ project: LocalProject)
    func unarchive(_ project: LocalProject)

    @discardableResult
    func addSection(to project: LocalProject, name: String) -> LocalSection
    func renameSection(_ section: LocalSection, to newName: String)
    func reorderSections(of project: LocalProject, to ids: [String])
}
```

### 6.3 MutationStatusStore

```swift
@MainActor
@Observable
final class MutationStatusStore {
    enum Status { case pending, failed(Error) }

    func status(for id: String) -> Status?
    func mark(_ id: String, _ status: Status)
    func clear(_ id: String)
    func rename(_ oldId: String, to newId: String)
}
```

Observed by views via `@Environment(MutationStatusStore.self)`. Failed entries persist until the user dismisses (so the user has time to notice before the row vanishes).

### 6.4 OptimisticStub protocol + extension

```swift
protocol OptimisticStub: PersistentModel {
    static func makeFetchByID(_ id: String) -> FetchDescriptor<Self>
    func adoptServerID(_ newID: String)
}

extension MutationQueue {
    func reconcileCreate<T: OptimisticStub>(
        clientId: String,
        serverId: String,
        type: T.Type,
        copyFields: (T) -> Void
    ) throws
}
```

`copyFields` is the closure handed in by the per-entity helper (e.g. `LocalNote.copyFields(from: serverNote)`). The ceremony — dedupe, rewrite pending mutations, fetch-or-find stub, rename — happens once.

**Save responsibility:** `reconcileCreate` performs interim saves where it must (B1 dupe-delete to free the unique-id slot before rename; B2 stub-missing branch to land the queue-row rewrite). The *final* save (the rename + queue-row deletion) is the caller's responsibility — `replay()` already wraps that in a single `try modelContext.save()` so reconcile + queue-row removal land atomically.

**`throws` is speculative.** Today no path inside the helper actually throws (every save is `try?` or `do/catch`). The `throws` signature is kept for forward compatibility with Waves 1+, where Repository callers may want exceptions surfaced.

## 7. Migration plan — five waves

Each wave is one PR. Each PR builds clean and ships independently. Do NOT bundle waves.

### Wave 0 — Refactor `MutationQueue` reconcile around `OptimisticStub`

- Add `OptimisticStub` protocol.
- Make `LocalNote` and `LocalProject` conform. (Validates the protocol shape against two distinct SwiftData models before any caller depends on it.)
- Refactor `reconcileCreateResponse` to share its ceremony via `reconcileCreate<T>`. Per-entity field copy stays.
- Note: there is no `reconcileCreateProjectResponse` today — project create currently goes through `BrainAPIClient.createProject(_:)` directly (the `MutationOp.createProject` arm is `notImplemented`). Wave 0 prepares `LocalProject` for the queue-path migration that lands in Wave 2.
- No view changes. No call site changes. Build + tests pass identically.

### Wave 1 — `NoteRepository`, `ProjectRepository`, `MutationStatusStore` skeletons

- All three constructed in `BrainApp.init` against a fresh `ModelContext`.
- Exposed via `@Environment` keys.
- Methods implemented but no view migrated yet.
- Unit tests exercise create / update / archive against an in-memory `ModelContainer` — verifies the optimistic path, the enqueue, the reconcile, and the rollback.
- Status store lifecycle tested end-to-end (enqueue → success → cleared; enqueue → poison → marked failed).

### Wave 2 — Migrate create paths

Replaces PR #33 wholesale.

- `QuickAddView.submit()` → `noteRepo.create(payload)`.
- `ProjectDetailView.createTodoInline()` → same.
- `UnassignedDetailView.createTodoInline()` → same.
- `NewProjectView.submit()` → `projectRepo.create(payload)`.
- Each view loses the manual `modelContext.insert + save + queue.enqueue` block.

PR #33 is closed at the end of this wave (or rebased into it).

### Wave 3 — Migrate update + archive paths

- `EditTodoView` → `noteRepo.update(note, fields)`.
- `EditProjectView` (project metadata only) → `projectRepo.update(project, fields)`.
- `TodoRow.archive()` → `noteRepo.archive(note)`.
- `TodoRow.toggleComplete()` → `noteRepo.toggleComplete(note)`. Resolves the `M37+` TODO comment in `TodoRow.swift:274`.
- Update-response reconcile lands here (§4.3).

### Wave 4 — Multi-step ops + Mutation Status UI

- `EditProjectView.addSection / renameSection / reorderSections` → `projectRepo.addSection / renameSection / reorderSections`.
- The reorderSections placeholder throws `unimplemented` for now (sortOrder is its own milestone — see §3).
- Banner UI: a small status pill in the toolbar showing pending / failed counts.
- Per-row indicators: spinner overlay or red-dot on `TodoRow` when `MutationStatusStore.status(for: note.id)` is non-nil.

## 8. Risks & open questions

### 8.1 App Intents / AppDelegate callbacks

`AddTodoIntent` (Siri) currently does a direct call (the file's existing rationale is "spoken confirmation must reflect a confirmed save"). Repository-route would change that semantic. Either:
- Skip Intents — they're an "always confirmed" edge.
- Add a `repo.createSync(...) async throws` variant that bypasses optimistic state. Recommended: skip in M45, revisit if Intents grow.

### 8.2 ID-rename audit

`LocalNote.id` is a `String` field, *not* the SwiftData `PersistentIdentifier`. SwiftUI views that captured the **string id** (e.g. `NavigationLink(value: note.id)`) silently break on rename. Views that captured the **live `LocalNote` reference** are safe.

Action: pre-Wave-2, grep for `note\.id` and `project\.id` outside the Sync/Networking modules. Audit each capture site. The codebase as currently written mostly passes live references — verify, don't assume.

### 8.3 Preview / testability

`@MainActor @Observable` repos with a real `ModelContext` will fight Xcode previews. Repeat the `mutationQueue` pattern: env-key default = `nil`, views fall back gracefully. `QuickAddView.swift:50` has the template.

### 8.4 SwiftLint contract enforcement

The "views never touch `modelContext.insert` directly" rule should be a `swiftlint custom_rules` regex. Add in Wave 4 or a follow-up. Without it, the contract decays.

### 8.5 `.delete()` is not a Repository method (yet)

Brain's server uses soft-delete (`DELETE` = archive). `repo.archive(note)` is the public API. Hard delete only appears if the user wants permanent purge — defer.

### 8.6 Composite ids — `OptimisticStub` doesn't fit `LocalSection`

`LocalSection` identifies as `projectID:slug` (see `SyncEngine.swift:514`), not a single UUID. `adoptServerID(_ newID: String)` assumes single-string identity and won't fit cleanly.

**Decision (deferred to Wave 4):** introduce a sibling protocol — `OptimisticCompositeStub` or similar — when `addSection` / `renameSection` migrate. Don't pre-generalize `OptimisticStub` now — Wave 0 keeps `Note` + `Project` clean, and the section variation gets the shape it actually needs when we know more.

## 9. Tests

Per `brain` testing philosophy ("test each behavior ONCE at the lowest layer; don't test framework behavior"):

- `Tests/BrainTests/RepositoryTests.swift` (new XCTest target — first one for brain-ios)
  - Note create: optimistic insert appears in fetch; queue has matching entry; reconcile renames to server id.
  - Note update: optimistic mutation; LWW guard skips response when concurrent edit pending.
  - Note archive: optimistic flag; queue entry; reconcile no-op (no id rename).
  - Project create: parity with note create + default section reconcile.
  - Multi-step: addSection optimistically inserts a `LocalSection`; reconcile renames.
- `Tests/BrainTests/MutationStatusStoreTests.swift` — pending → cleared; pending → failed; rename(old, new) preserves status.
- Existing `BrainDebugMutationQueue` smoke checks stay (cover B1, B2, S1, the multi-op test, the stub-missing test).
- One integration-shaped test per wave's view migration: simulate the view's submit path, assert the optimistic stub appears in the SwiftUI ModelContext and the queue's payload matches.

## 10. Verification

- All existing tests pass.
- New tests pass.
- `xcodebuild build` succeeds at every wave (per memory: `swiftc -parse` is not enough).
- Manual TestFlight test plan (run between waves):
  1. Add 5 todos rapidly via QuickAdd. All appear instantly.
  2. Add 5 todos via inline section field. All appear instantly.
  3. Add a project. Appears instantly. Reopen — still there with server id.
  4. Edit a todo's content. Appears instantly. Server-derived title (if any) appears within the next sync without clobbering local edits made in between.
  5. Archive via swipe. Disappears instantly.
  6. Create a todo while offline (airplane mode). Appears instantly. Toggle online. Within ~30s, queue drains, todo persists across app restart.
  7. Create a todo with intentionally invalid payload (server-side validation fails — needs a test hook). Optimistic stub disappears within a few seconds; failure surfaces in banner / per-row indicator (Wave 4 only).
  8. Rapid create + immediate edit + immediate archive. All three replay correctly; final state matches user expectation.

## 11. Out of scope (explicit)

- sortOrder / drag-reorder. Tracked as M46 (future).
- Conflict UI (current behavior: silent LWW based on `updated_at`). M38 covers; M45 doesn't change.
- Hard delete. Not an iOS surface today.
- Push (M41) re-enable. Tracked separately for v0.2.
- App icon final design. Tracked separately for v0.2.

---

**Decision points before dispatch**:

1. Confirm Waves 0-4 ordering and PR cadence (one PR per wave).
2. Confirm Wave 4's status UI design surface (banner shape, per-row indicator style) — or punt to a designer pass.
3. Confirm M45 numbering (next available iOS milestone after M44 TestFlight).
4. Confirm where this SPEC lives long-term (`brain-ios/docs/` per this draft, vs. `brain/SPEC.md` as new section).
