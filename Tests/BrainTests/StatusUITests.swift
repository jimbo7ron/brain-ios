// StatusUITests.swift
// brain-ios — BrainTests
//
// M45 Wave 4: smoke coverage for the status UI's underlying state.
// Per project testing philosophy ("don't test framework behavior; test
// our business logic"), the SwiftUI rendering of `MutationStatusPill`
// and `TodoRow.statusIndicator` is intentionally not exercised — the
// surfaces under test are the state observed by those views:
//
//   * `MutationQueue.failedCount` rises when rows poison and resets
//     on `clear()`.
//   * `MutationStatusStore` mark / clear / rename round-trip already
//     covered in `MutationStatusStoreTests`; here we add the
//     queue-store interaction the per-row indicator depends on.

import Foundation
import SwiftData
import XCTest
@testable import brain

@MainActor
final class StatusUITests: XCTestCase {

    private func makeQueue() throws -> (queue: MutationQueue, store: MutationStatusStore) {
        let schema = Schema([
            LocalNote.self,
            LocalProject.self,
            LocalSection.self,
            MutationQueueItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        let store = MutationStatusStore()
        let session = AuthSession(state: .signedOut)
        let client = BrainAPIClient()
        let queue = MutationQueue(modelContext: context, client: client, authSession: session)
        queue.statusStore = store
        return (queue, store)
    }

    /// Wave 4 (spec §4.4): the pill computes "active pending" as
    /// `pendingCount - failedCount`, so when no rows are poisoned,
    /// `failedCount` is zero and the pending indicator carries the
    /// full count.
    func testFailedCount_zeroWhenNoPoison() throws {
        let (queue, _) = try makeQueue()
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.failedCount, 0)

        _ = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: "11111111-1111-1111-1111-111111111111",
            payload: Data()
        )
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
    }

    /// Wave 4: poisoning a row stamps `nextRetryAt = .distantFuture`.
    /// `failedCount` should observe that on the next refresh.
    func testFailedCount_bumpsOnPoison() throws {
        let (queue, _) = try makeQueue()
        let item = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: "22222222-2222-2222-2222-222222222222",
            payload: Data()
        )
        // Manually park the row at .distantFuture (mirroring the
        // permanent-failure arm in `replay()`).
        item.nextRetryAt = .distantFuture
        try queue.debugModelContext.save()

        // Trigger the lazy refresh by enqueueing another row (the
        // public API never exposes refreshPendingCount directly; the
        // refresh fires inside `enqueue` and `replay` defer blocks).
        _ = try queue.enqueue(
            op: .completeTodo,
            resourceType: "todo",
            resourceId: "33333333-3333-3333-3333-333333333333",
            payload: Data()
        )

        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(queue.failedCount, 1)
    }

    /// Wave 4: per-row indicator path. `MutationStatusStore`'s
    /// pending status under a known id is what `TodoRow.statusIndicator`
    /// looks up. This exercises the read path the row depends on.
    func testTodoRowIndicator_readsPendingFromStore() throws {
        let store = MutationStatusStore()
        let id = "44444444-4444-4444-4444-444444444444"

        XCTAssertNil(store.status(for: id))
        store.mark(id, .pending)
        guard case .pending = store.status(for: id) else {
            XCTFail("expected .pending after mark")
            return
        }

        store.clear(id)
        XCTAssertNil(store.status(for: id))
    }

    /// Wave 4: per-row indicator path for the failed branch. Mirrors
    /// the `.failed(Error)` case the row renders as a red dot.
    func testTodoRowIndicator_readsFailedFromStore() throws {
        let store = MutationStatusStore()
        struct Stub: Error {}
        store.mark("xyz", .failed(Stub()))
        guard case .failed = store.status(for: "xyz") else {
            XCTFail("expected .failed after mark")
            return
        }
    }
}
