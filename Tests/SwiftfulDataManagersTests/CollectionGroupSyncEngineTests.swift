//
//  CollectionGroupSyncEngineTests.swift
//  SwiftfulDataManagers
//
//  Tests for CollectionGroupSyncEngine query-based streaming.
//

import Foundation
import Testing
@testable import SwiftfulDataManagers

@Suite("CollectionGroupSyncEngine Tests")
@MainActor
struct CollectionGroupSyncEngineTests {

    // MARK: - Test Model

    struct TestItem: DataSyncModelProtocol {
        let id: String
        var title: String
        var priority: Int
    }

    // MARK: - Helper

    func createEngine(collection: [TestItem] = []) -> (CollectionGroupSyncEngine<TestItem>, MockRemoteCollectionGroupService<TestItem>) {
        let remote = MockRemoteCollectionGroupService<TestItem>(collection: collection)
        let engine = CollectionGroupSyncEngine<TestItem>(
            remote: remote,
            managerKey: "test_items",
            enableLocalPersistence: false,
            logger: nil
        )
        return (engine, remote)
    }

    // MARK: - Tests

    @Test("startListening with no query loads collection")
    func testStartListeningNoQuery() async {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, _) = createEngine(collection: items)

        await engine.startListening()

        #expect(engine.currentCollection.count == 2)
        #expect(engine.currentCollection.contains(where: { $0.id == "1" }))
        #expect(engine.currentCollection.contains(where: { $0.id == "2" }))
    }

    @Test("startListening with query sets currentCollection from query results")
    func testStartListeningWithQuery() async {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, _) = createEngine(collection: items)

        // Mock doesn't filter, but we verify the code path works
        await engine.startListening { query in
            query.where("priority", isGreaterThan: 1)
        }

        // Mock returns all items (doesn't apply filter), but the path is exercised
        #expect(engine.currentCollection.count == 2)
    }

    @Test("Calling startListening with same query is a no-op")
    func testSameQueryNoOp() async {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1)
        ]
        let (engine, _) = createEngine(collection: items)

        // First call starts listening
        await engine.startListening { query in
            query.where("priority", isGreaterThan: 0)
        }
        let firstCount = engine.currentCollection.count

        // Second call with identical query should be a no-op
        await engine.startListening { query in
            query.where("priority", isGreaterThan: 0)
        }

        #expect(engine.currentCollection.count == firstCount)
    }

    @Test("Calling startListening with different query clears and reloads")
    func testDifferentQueryClearsAndReloads() async {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, _) = createEngine(collection: items)

        // Start with first query
        await engine.startListening { query in
            query.where("priority", isEqualTo: 1)
        }
        #expect(engine.currentCollection.count == 2) // Mock returns all

        // Switch to different query — should clear and reload
        await engine.startListening { query in
            query.where("priority", isEqualTo: 2)
        }

        // Collection was reloaded (mock still returns all items)
        #expect(engine.currentCollection.count == 2)
    }

    @Test("stopListening with clearCaches true clears currentCollection")
    func testStopListeningClearsCaches() async {
        let items = [TestItem(id: "1", title: "Item 1", priority: 1)]
        let (engine, _) = createEngine(collection: items)

        await engine.startListening()
        #expect(engine.currentCollection.count == 1)

        engine.stopListening(clearCaches: true)

        #expect(engine.currentCollection.isEmpty)
    }

    @Test("stopListening with clearCaches false preserves currentCollection")
    func testStopListeningPreservesCollection() async {
        let items = [TestItem(id: "1", title: "Item 1", priority: 1)]
        let (engine, _) = createEngine(collection: items)

        await engine.startListening()
        #expect(engine.currentCollection.count == 1)

        engine.stopListening(clearCaches: false)

        #expect(engine.currentCollection.count == 1)
    }

    @Test("simulateUpdate reflects updated document in currentCollection")
    func testSimulateUpdateReflectsInCollection() async throws {
        let items = [TestItem(id: "1", title: "Item 1", priority: 1)]
        let (engine, remote) = createEngine(collection: items)

        await engine.startListening()
        #expect(engine.currentCollection.count == 1)

        // Allow listener tasks and continuation setup to complete
        try await Task.sleep(for: .milliseconds(100))

        let updatedItem = TestItem(id: "1", title: "Updated", priority: 10)
        remote.simulateUpdate(updatedItem)

        // Allow listener task to process the streamed update
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.currentCollection.count == 1)
        #expect(engine.currentCollection.first?.title == "Updated")
    }

    @Test("simulateDelete removes document from currentCollection")
    func testSimulateDeleteRemovesFromCollection() async throws {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, remote) = createEngine(collection: items)

        await engine.startListening()
        #expect(engine.currentCollection.count == 2)

        // Allow listener tasks and continuation setup to complete
        try await Task.sleep(for: .milliseconds(100))

        remote.simulateDelete(id: "1")

        // Allow listener task to process the streamed deletion
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.currentCollection.count == 1)
        #expect(!engine.currentCollection.contains(where: { $0.id == "1" }))
    }

    @Test("getDocuments(where:) filters currentCollection in memory")
    func testGetDocumentsWhereFilters() async {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, _) = createEngine(collection: items)

        await engine.startListening()

        let filtered = engine.getDocuments(where: { $0.priority > 1 })

        #expect(filtered.count == 1)
        #expect(filtered.first?.id == "2")
    }

    @Test("getDocumentsAsync(buildQuery:) fetches from remote directly")
    func testGetDocumentsAsyncFetchesFromRemote() async throws {
        let items = [
            TestItem(id: "1", title: "Item 1", priority: 1),
            TestItem(id: "2", title: "Item 2", priority: 2)
        ]
        let (engine, _) = createEngine(collection: items)

        let results = try await engine.getDocumentsAsync { query in
            query.where("priority", isGreaterThan: 0)
        }

        #expect(results.count == 2)
    }
}
