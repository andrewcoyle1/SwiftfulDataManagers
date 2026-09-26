//
//  MockRemoteDocumentServiceTests.swift
//  SwiftfulDataManagers
//
//  Tests for MockRemoteDocumentService's continuation bookkeeping.
//

import Foundation
import Testing
@testable import SwiftfulDataManagers

// The app extends `Date` the same way; the package itself does not.
extension Date: DMCodableSendable {}

@Suite("MockRemoteDocumentService Tests")
@MainActor
struct MockRemoteDocumentServiceTests {

    // MARK: - Test Model

    struct TestItem: DataSyncModelProtocol {
        let id: String
        var title: String
        var count: Int? = nil
        var updatedAt: Date? = nil
    }

    /// `updateDocument` used to re-yield the stored document untouched, so a field written
    /// through it never changed and the engine's `currentDocument` stayed as it was. The mock
    /// now merges the fields in, as Firestore does, including a `Date`.
    @Test("An update merges its fields into the stored document")
    func testUpdateMergesFieldsIntoStoredDocument() async throws {
        let remote = MockRemoteDocumentService<TestItem>(document: TestItem(id: "item-1", title: "original"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        try await remote.updateDocument(id: "item-1", data: ["title": "later", "count": 3, "updatedAt": when])

        let stored = try await remote.getDocument(id: "item-1")
        #expect(stored.title == "later")
        #expect(stored.count == 3)
        #expect(stored.updatedAt == when)
    }

    // MARK: - Tests

    /// The service holds a single continuation, and both registering it and clearing it on
    /// termination hop to the main actor. When a listener is stopped and immediately restarted —
    /// the shape `DocumentSyncEngine.deleteDocument` produces, since it stops its listener and
    /// leaves callers to put it back — the old stream's termination could land *after* the new
    /// stream had registered, clearing a continuation it no longer owned. Every later
    /// `saveDocument` then yielded to nothing: the document never reached the engine and
    /// `currentDocument` stayed nil until the next sign-in.
    ///
    /// Ordered explicitly rather than by racing the two, because the interleaving that loses the
    /// continuation is the one where termination trails registration, and a plain stop-then-start
    /// does not reliably produce it on every platform.
    @Test("An older stream terminating does not silence the current one")
    func testOlderStreamTerminationDoesNotSilenceCurrentStream() async throws {
        let item = TestItem(id: "item-1", title: "original")
        let remote = MockRemoteDocumentService<TestItem>(document: item)

        let first = Task {
            for try await _ in remote.streamDocument(id: item.id) { }
        }
        try await Task.sleep(for: .milliseconds(100))

        var received: TestItem?
        let second = Task {
            for try await document in remote.streamDocument(id: item.id) {
                received = document
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        // The older stream ends only once the newer one holds the continuation.
        first.cancel()
        try await Task.sleep(for: .milliseconds(100))

        try await remote.saveDocument(TestItem(id: "item-1", title: "later"))
        try await Task.sleep(for: .milliseconds(300))
        second.cancel()

        #expect(received?.title == "later")
    }

    /// Presenters route on the engine's `currentDocument` straight after an update returns, so
    /// the stream must have carried the update before `updateDocument` comes back.
    @Test("A listener holds the update by the time updateDocument returns")
    func testListenerHoldsUpdateWhenUpdateReturns() async throws {
        let remote = MockRemoteDocumentService<TestItem>(document: TestItem(id: "item-1", title: "original"))
        var received: TestItem?
        let listener = Task {
            for try await document in remote.streamDocument(id: "item-1") {
                received = document
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        try await remote.updateDocument(id: "item-1", data: ["title": "later"])
        listener.cancel()

        #expect(received?.title == "later")
    }

    /// A delete clears the stored document, and a stream attached afterwards must still report
    /// what is saved next — the end of the same path, without depending on task interleaving.
    @Test("A stream attached after a delete receives the next save")
    func testStreamAttachedAfterDeleteReceivesNextSave() async throws {
        let item = TestItem(id: "item-1", title: "original")
        let remote = MockRemoteDocumentService<TestItem>(document: item)

        let first = Task {
            for try await _ in remote.streamDocument(id: item.id) { }
        }
        try await Task.sleep(for: .milliseconds(100))

        try await remote.deleteDocument(id: item.id)
        first.cancel()
        try await Task.sleep(for: .milliseconds(100))

        var received: TestItem?
        let second = Task {
            for try await document in remote.streamDocument(id: item.id) {
                received = document
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        try await remote.saveDocument(TestItem(id: "item-1", title: "saved after delete"))
        try await Task.sleep(for: .milliseconds(300))
        second.cancel()

        #expect(received?.title == "saved after delete")
    }
}
