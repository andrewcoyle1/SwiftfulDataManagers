//
//  CollectionChanges.swift
//  SwiftfulDataManagers
//
//  Created by Andrew Coyle on 01/10/2026.
//

import Foundation

/// Everything a collection listener delivered in one snapshot.
///
/// Engines apply a whole batch at once: one assignment to `currentCollection` and one local save,
/// however many documents it holds. Applying documents one at a time meant a linear search, a
/// main-thread SwiftData save and an observation change per document, so a listener's first
/// snapshot cost O(n²) and n saves on every launch.
public struct CollectionChanges<T: DataSyncModelProtocol>: Sendable {

    /// Documents added or modified. When `isComplete`, every document in the result.
    public var upserted: [T]

    /// IDs of documents removed. Always empty when `isComplete`.
    public var deletedIds: [String]

    /// The batch is the whole collection, replacing what was held rather than adding to it.
    /// A listener's first snapshot is complete, which is what makes a separate bulk load
    /// before listening unnecessary.
    public var isComplete: Bool

    public init(upserted: [T] = [], deletedIds: [String] = [], isComplete: Bool = false) {
        self.upserted = upserted
        self.deletedIds = deletedIds
        self.isComplete = isComplete
    }

    public var isEmpty: Bool {
        !isComplete && upserted.isEmpty && deletedIds.isEmpty
    }

    /// `collection` with this batch applied. An upserted document replaces the one with its ID
    /// in place, or is appended.
    public func applied(to collection: [T]) -> [T] {
        if isComplete { return upserted }

        var result = collection
        var indexById = [String: Int](minimumCapacity: result.count)
        for (index, document) in result.enumerated() where indexById[document.id] == nil {
            indexById[document.id] = index
        }
        for document in upserted {
            if let index = indexById[document.id] {
                result[index] = document
            } else {
                indexById[document.id] = result.count
                result.append(document)
            }
        }
        if !deletedIds.isEmpty {
            let deleted = Set(deletedIds)
            result.removeAll { deleted.contains($0.id) }
        }
        return result
    }
}

/// Builds a batched stream from a one-off fetch and the per-document streams, for remotes that
/// cannot deliver snapshots as batches. The fetch becomes the complete first batch, and each
/// document after it a batch of its own, which is what engines did before batching.
@MainActor
func collectionChangesStream<T: DataSyncModelProtocol>(
    fetchAll: @escaping @MainActor () async throws -> [T],
    streamUpdates: @escaping @MainActor () -> (
        updates: AsyncThrowingStream<T, Error>,
        deletions: AsyncThrowingStream<String, Error>
    )
) -> AsyncThrowingStream<CollectionChanges<T>, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: CollectionChanges<T>.self)
    let task = Task { @MainActor in
        do {
            continuation.yield(CollectionChanges(upserted: try await fetchAll(), isComplete: true))
            let (updates, deletions) = streamUpdates()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await document in updates {
                        continuation.yield(CollectionChanges(upserted: [document]))
                    }
                }
                group.addTask {
                    for try await id in deletions {
                        continuation.yield(CollectionChanges(deletedIds: [id]))
                    }
                }
                try await group.waitForAll()
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}
