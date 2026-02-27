//
//  MockRemoteCollectionGroupService.swift
//  SwiftfulDataManagers
//
//  Created by Andrew Coyle on 27/02/2026.
//

import Foundation

/// Mock implementation of RemoteCollectionGroupService for testing and previews.
@MainActor
public final class MockRemoteCollectionGroupService<T: DataSyncModelProtocol>: RemoteCollectionGroupService, @unchecked Sendable {

    // MARK: - Properties

    private var currentCollection: [T] = []
    private var updatesContinuation: AsyncThrowingStream<T, Error>.Continuation?
    private var deletionsContinuation: AsyncThrowingStream<String, Error>.Continuation?

    // MARK: - Initialization

    public nonisolated init(collection: [T] = []) {
        self.currentCollection = collection
    }

    // MARK: - RemoteCollectionGroupService Implementation

    public func getDocuments(query: QueryBuilder) async throws -> [T] {
        try await Task.sleep(for: .seconds(0.5))
        // Mock implementation returns all documents (query filtering not implemented)
        return currentCollection
    }

    public nonisolated func streamCollection(query: QueryBuilder) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                continuation.yield(self.currentCollection)
                continuation.onTermination = { @Sendable _ in }
            }
        }
    }

    public nonisolated func streamCollectionUpdates(query: QueryBuilder) -> (
        updates: AsyncThrowingStream<T, Error>,
        deletions: AsyncThrowingStream<String, Error>
    ) {
        let updates = AsyncThrowingStream<T, Error> { continuation in
            Task { @MainActor in
                self.updatesContinuation = continuation

                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in
                        self.updatesContinuation = nil
                    }
                }
            }
        }

        let deletions = AsyncThrowingStream<String, Error> { continuation in
            Task { @MainActor in
                self.deletionsContinuation = continuation

                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in
                        self.deletionsContinuation = nil
                    }
                }
            }
        }

        return (updates, deletions)
    }

    // MARK: - Simulation Helpers

    /// Simulate a document being added or updated in the stream.
    public func simulateUpdate(_ document: T) {
        if let index = currentCollection.firstIndex(where: { $0.id == document.id }) {
            currentCollection[index] = document
        } else {
            currentCollection.append(document)
        }
        updatesContinuation?.yield(document)
    }

    /// Simulate a document being deleted from the stream.
    public func simulateDelete(id: String) {
        currentCollection.removeAll { $0.id == id }
        deletionsContinuation?.yield(id)
    }
}
