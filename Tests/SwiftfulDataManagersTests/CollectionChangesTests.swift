//
//  CollectionChangesTests.swift
//  SwiftfulDataManagers
//
//  Tests for batched listener delivery: applying a batch, the engine waiting for the first one,
//  and the SwiftData batch save.
//

import Foundation
import SwiftData
import Testing
@testable import SwiftfulDataManagers

@Suite("CollectionChanges Tests")
@MainActor
struct CollectionChangesTests {

    struct TestItem: DataSyncModelProtocol {
        let id: String
        var title: String
    }

    private func item(_ id: String, _ title: String = "") -> TestItem {
        TestItem(id: id, title: title)
    }

    // MARK: - Applying a batch

    @Test("A complete batch replaces the collection")
    func testCompleteBatchReplaces() {
        let changes = CollectionChanges(upserted: [item("2")], isComplete: true)

        #expect(changes.applied(to: [item("1")]).map(\.id) == ["2"])
    }

    @Test("Upserts replace in place and append, deletions remove")
    func testIncrementalBatch() {
        let changes = CollectionChanges(upserted: [item("2", "new"), item("4")], deletedIds: ["1"])

        let result = changes.applied(to: [item("1"), item("2", "old"), item("3")])

        #expect(result.map(\.id) == ["2", "3", "4"])
        #expect(result.first?.title == "new")
    }

    // MARK: - Engine

    /// A remote that delivers whatever batches the test sends it.
    final class ScriptedRemote: RemoteCollectionService, @unchecked Sendable {
        typealias T = TestItem
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CollectionChanges<TestItem>.self)

        func streamCollectionChanges(query: QueryBuilder?) -> AsyncThrowingStream<CollectionChanges<TestItem>, Error> {
            stream
        }

        func getCollection() async throws -> [TestItem] { [] }
        func getDocument(id: String) async throws -> TestItem { throw URLError(.fileDoesNotExist) }
        func streamDocument(id: String) -> AsyncThrowingStream<TestItem?, Error> { AsyncThrowingStream { $0.finish() } }
        func saveDocument(_ model: TestItem) async throws { }
        func updateDocument(id: String, data: [String: any DMCodableSendable]) async throws { }
        func streamCollection() -> AsyncThrowingStream<[TestItem], Error> { AsyncThrowingStream { $0.finish() } }
        func streamCollection(query: QueryBuilder) -> AsyncThrowingStream<[TestItem], Error> { AsyncThrowingStream { $0.finish() } }
        func streamCollectionUpdates() -> (updates: AsyncThrowingStream<TestItem, Error>, deletions: AsyncThrowingStream<String, Error>) {
            (AsyncThrowingStream { $0.finish() }, AsyncThrowingStream { $0.finish() })
        }
        func streamCollectionUpdates(query: QueryBuilder) -> (updates: AsyncThrowingStream<TestItem, Error>, deletions: AsyncThrowingStream<String, Error>) {
            streamCollectionUpdates()
        }
        func deleteDocument(id: String) async throws { }
        func getDocuments(query: QueryBuilder) async throws -> [TestItem] { [] }
    }

    private func engine(_ remote: ScriptedRemote) -> CollectionSyncEngine<TestItem> {
        CollectionSyncEngine(remote: remote, managerKey: "changes_tests", enableLocalPersistence: false)
    }

    /// Callers seed and import straight after signing in, so `startListening()` must not return
    /// before the listener's first batch has landed.
    @Test("startListening returns once the first batch is applied", .timeLimit(.minutes(1)))
    func testStartListeningWaitsForFirstBatch() async {
        let remote = ScriptedRemote()
        let engine = engine(remote)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            remote.continuation.yield(CollectionChanges(upserted: [item("1"), item("2")], isComplete: true))
        }

        await engine.startListening()

        #expect(engine.currentCollection.map(\.id) == ["1", "2"])
    }

    @Test("Later batches are applied as changes", .timeLimit(.minutes(1)))
    func testLaterBatchesApply() async throws {
        let remote = ScriptedRemote()
        let engine = engine(remote)
        remote.continuation.yield(CollectionChanges(upserted: [item("1")], isComplete: true))
        await engine.startListening()

        remote.continuation.yield(CollectionChanges(upserted: [item("2"), item("3")], deletedIds: ["1"]))

        while engine.currentCollection.map(\.id) != ["2", "3"] {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A listener that fails before delivering anything would otherwise hold sign-in for ever.
    @Test("startListening returns when the listener fails first", .timeLimit(.minutes(1)))
    func testStartListeningReturnsOnFailure() async {
        let remote = ScriptedRemote()
        let engine = engine(remote)
        remote.continuation.finish(throwing: URLError(.notConnectedToInternet))

        await engine.startListening()

        #expect(engine.currentCollection.isEmpty)
    }

    // MARK: - SwiftData batch save

    @Test("applyChanges replaces on a complete batch, then upserts and deletes")
    func testSwiftDataApplyChanges() async throws {
        let key = "changes_tests_\(UUID().uuidString)"
        let persistence = SwiftDataCollectionPersistence<TestItem>(managerKey: key)
        defer {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SwiftfulDataManagers", isDirectory: true)
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key).store\(suffix)"))
            }
        }

        try await persistence.applyChanges(managerKey: key, CollectionChanges(upserted: [item("1"), item("2", "old")], isComplete: true))
        try await persistence.applyChanges(managerKey: key, CollectionChanges(upserted: [item("2", "new"), item("3")], deletedIds: ["1"]))

        let stored = try persistence.getCollection(managerKey: key).sorted { $0.id < $1.id }
        #expect(stored.map(\.id) == ["2", "3"])
        #expect(stored.first?.title == "new")
    }
}
