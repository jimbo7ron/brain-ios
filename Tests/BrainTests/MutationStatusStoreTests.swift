// MutationStatusStoreTests.swift
// brain-ios — BrainTests
//
// M45 Wave 1: per-row status store smoke coverage. The store is a thin
// `[String: Status]` wrapper, so the tests cover the named mutators
// (mark / clear / rename) and the `status(for:)` read path. The
// `@Observable` rebuild surface is framework behaviour and not tested
// here per the brain testing philosophy ("don't test framework
// behaviour"; see brain/CLAUDE.md).

import XCTest
@testable import brain

@MainActor
final class MutationStatusStoreTests: XCTestCase {

    // Test 1 (spec §6.3): set + read round-trips through `status(for:)`.
    func testMarkAndStatus() {
        let store = MutationStatusStore()
        XCTAssertNil(store.status(for: "abc"))

        store.mark("abc", .pending)

        guard case .pending = store.status(for: "abc") else {
            XCTFail("expected .pending after mark, got \(String(describing: store.status(for: "abc")))")
            return
        }
    }

    // Test 2: clear removes the entry. Verifies the queue's success
    // terminal can release the per-row indicator (Wave 4 UI rebuilds
    // off this).
    func testClear() {
        let store = MutationStatusStore()
        store.mark("abc", .pending)
        XCTAssertNotNil(store.status(for: "abc"))

        store.clear("abc")

        XCTAssertNil(store.status(for: "abc"))
    }

    // Test 3: rename(old, new) preserves the status under the new key.
    // This is the hook that `MutationQueue.reconcileCreate<T:>` calls
    // after the create-echo's id rename — the per-row indicator must
    // stay attached across the clientId → serverId transition.
    func testRename() {
        let store = MutationStatusStore()
        store.mark("client-uuid", .pending)

        store.rename("client-uuid", to: "server-uuid")

        guard case .pending = store.status(for: "server-uuid") else {
            XCTFail("expected .pending under new key after rename")
            return
        }
    }

    // Test 4: rename clears the old key. Otherwise the status would
    // double-count and a per-row UI keyed on either id would render.
    func testRename_clearsOld() {
        let store = MutationStatusStore()
        store.mark("client-uuid", .pending)
        store.rename("client-uuid", to: "server-uuid")

        XCTAssertNil(
            store.status(for: "client-uuid"),
            "rename should remove the old key"
        )
    }

    // Edge case: rename of a non-existent id is a no-op (no crash, no
    // phantom entry under the new key). Important because most reconcile
    // calls fire even when the repository didn't pre-mark — preview /
    // debug builds.
    func testRename_missingOldId_isNoop() {
        let store = MutationStatusStore()
        store.rename("missing", to: "new")
        XCTAssertNil(store.status(for: "missing"))
        XCTAssertNil(store.status(for: "new"))
    }

    // Edge case: rename(old, old) is a no-op. The reconcile path
    // shouldn't actually hit this (clientId != serverId by design), but
    // exercising the guard avoids a future bug if a caller miscomputes.
    func testRename_sameId_preservesStatus() {
        let store = MutationStatusStore()
        store.mark("abc", .pending)
        store.rename("abc", to: "abc")

        guard case .pending = store.status(for: "abc") else {
            XCTFail("expected .pending preserved when rename old==new")
            return
        }
    }

    // Test 5: failed status round-trips with the underlying error
    // wrapped. The queue's rollback path uses `.failed` to surface a
    // permanent failure to the per-row UI.
    func testMarkFailed() {
        let store = MutationStatusStore()
        struct DummyError: Error {}
        store.mark("abc", .failed(DummyError()))

        guard case .failed = store.status(for: "abc") else {
            XCTFail("expected .failed after mark")
            return
        }
    }
}
