//
//  RemoteCollectionGroupService.swift
//  SwiftfulDataManagers
//
//  Created by Andrew Coyle on 27/02/2026.
//

import Foundation

@MainActor
public protocol RemoteCollectionGroupService<T>: Sendable {
    associatedtype T: DataSyncModelProtocol

    func getDocuments(query: QueryBuilder) async throws -> [T]
    func streamCollection(query: QueryBuilder) -> AsyncThrowingStream<[T], Error>
    func streamCollectionUpdates(query: QueryBuilder) -> (
        updates: AsyncThrowingStream<T, Error>,
        deletions: AsyncThrowingStream<String, Error>
    )

    /// Stream the documents matching `query` as one batch per snapshot, the first complete.
    /// See `RemoteCollectionService.streamCollectionChanges(query:)`.
    func streamCollectionChanges(query: QueryBuilder) -> AsyncThrowingStream<CollectionChanges<T>, Error>
}

extension RemoteCollectionGroupService {
    public func streamCollectionChanges(query: QueryBuilder) -> AsyncThrowingStream<CollectionChanges<T>, Error> {
        collectionChangesStream(
            fetchAll: { try await getDocuments(query: query) },
            streamUpdates: { streamCollectionUpdates(query: query) }
        )
    }
}

