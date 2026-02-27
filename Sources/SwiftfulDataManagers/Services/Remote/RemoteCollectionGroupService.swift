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
}

