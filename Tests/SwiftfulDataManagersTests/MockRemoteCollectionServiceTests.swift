//
//  MockRemoteCollectionServiceTests.swift
//  SwiftfulDataManagers
//

import Foundation
import Testing
@testable import SwiftfulDataManagers

@Suite("MockRemoteCollectionService Tests")
@MainActor
struct MockRemoteCollectionServiceTests {

    struct TestItem: DataSyncModelProtocol {
        let id: String
        var title: String
    }

    /// The collection mock had the same gap as the document mock: an update re-yielded the
    /// stored item with none of its fields applied.
    @Test("An update merges its fields into the stored item")
    func testUpdateMergesFieldsIntoStoredItem() async throws {
        let remote = MockRemoteCollectionService<TestItem>(collection: [TestItem(id: "item-1", title: "original")])

        try await remote.updateDocument(id: "item-1", data: ["title": "later"])

        let stored = try await remote.getCollection()
        #expect(stored.first?.title == "later")
    }
}
