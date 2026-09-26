//
//  MockRemoteDocumentService.swift
//  SwiftfulDataManagers
//
//  Created by Nick Sarno on 1/17/25.
//

import Foundation

/// Mock implementation of RemoteDocumentService for testing and previews.
@MainActor
public final class MockRemoteDocumentService<T: DataSyncModelProtocol>: RemoteDocumentService, @unchecked Sendable {

    // MARK: - Properties

    private var currentDocument: T?
    private var continuation: AsyncThrowingStream<T?, Error>.Continuation?

    /// Identifies which stream owns `continuation`. A terminated stream must only clear the slot
    /// if it still holds its own continuation: registration and termination both hop to the main
    /// actor, so a listener stopped and immediately restarted — as `DocumentSyncEngine.deleteDocument`
    /// does — can otherwise have the old stream's termination wipe the new stream's continuation,
    /// leaving later `saveDocument` yields with nowhere to go.
    private var continuationGeneration: Int = 0

    // MARK: - Initialization

    public nonisolated init(document: T? = nil) {
        self.currentDocument = document
    }

    // MARK: - RemoteDocumentService Implementation

    public func getDocument(id: String) async throws -> T {
        try await Task.sleep(for: .seconds(0.5))

        guard let currentDocument, currentDocument.id == id else {
            throw MockError.documentNotFound
        }

        return currentDocument
    }

    public func saveDocument(_ model: T) async throws {
        try await Task.sleep(for: .seconds(0.5))
        currentDocument = model
        continuation?.yield(model)
    }

    public func updateDocument(id: String, data: [String: any DMCodableSendable]) async throws {
        try await Task.sleep(for: .seconds(0.5))

        guard let currentDocument, currentDocument.id == id else {
            throw MockError.documentNotFound
        }

        let updated = try MockRemoteFieldMerge.apply(data, to: currentDocument)
        self.currentDocument = updated
        continuation?.yield(updated)
    }

    public nonisolated func streamDocument(id: String) -> AsyncThrowingStream<T?, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                self.continuationGeneration += 1
                let generation = self.continuationGeneration
                self.continuation = continuation
                continuation.yield(self.currentDocument)

                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in
                        guard self.continuationGeneration == generation else { return }
                        self.continuation = nil
                    }
                }
            }
        }
    }

    public func deleteDocument(id: String) async throws {
        try await Task.sleep(for: .seconds(0.5))

        guard currentDocument?.id == id else {
            throw MockError.documentNotFound
        }

        currentDocument = nil
        continuation?.yield(nil)
    }

    // MARK: - Mock Error

    enum MockError: LocalizedError {
        case documentNotFound

        var errorDescription: String? {
            switch self {
            case .documentNotFound:
                return "Document not found"
            }
        }
    }
}
