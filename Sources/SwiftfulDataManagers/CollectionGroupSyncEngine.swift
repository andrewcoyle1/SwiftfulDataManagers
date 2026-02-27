//
//  CollectionGroupSyncEngine.swift
//  SwiftfulDataManagers
//
//  Created by Andrew Coyle on 27/02/2026.
//

import Foundation
import Observation

/// Real-time collection-group sync engine (read-only).
///
/// Manages a cross-collection query (e.g., Firestore `collectionGroup`) with streaming updates
/// and optional SwiftData caching. No write operations — use `CollectionSyncEngine` when you need those.
///
/// Uses hybrid sync: bulk loads all documents on `startListening()`, then streams individual changes.
///
/// Example:
/// ```swift
/// let engine = CollectionGroupSyncEngine<Review>(
///     remote: FirebaseRemoteCollectionGroupService(groupName: "reviews"),
///     managerKey: "reviews",
///     logger: logManager
/// )
///
/// // Start real-time sync
/// await engine.startListening { query in
///     query.where("rating", isGreaterThan: 3)
/// }
///
/// // Access current collection (Observable — SwiftUI auto-updates)
/// for review in engine.currentCollection {
///     print(review.text)
/// }
///
/// // Stop listening
/// engine.stopListening()
/// ```
@MainActor
@Observable
public final class CollectionGroupSyncEngine<T: DataSyncModelProtocol> {

    // MARK: - Public Properties

    /// The current collection. Observable — SwiftUI views reading this will auto-update.
    public private(set) var currentCollection: [T] = []

    /// The logger instance, accessible for domain-specific logging in consuming code.
    public let logger: (any DataSyncLogger)?

    // MARK: - Internal Properties

    internal let remote: any RemoteCollectionGroupService<T>
    internal let local: (any LocalCollectionPersistence<T>)?
    internal let managerKey: String
    internal let enableLocalPersistence: Bool

    // MARK: - Private Properties

    private var updatesListenerTask: Task<Void, Never>?
    private var deletionsListenerTask: Task<Void, Never>?
    private var listenerFailedToAttach: Bool = false
    private var listenerRetryCount: Int = 0
    private var listenerRetryTask: Task<Void, Never>?
    private var currentQuery: QueryBuilder?

    // MARK: - Initialization

    /// Initialize the CollectionGroupSyncEngine.
    /// - Parameters:
    ///   - remote: The remote collection group service (e.g., FirebaseRemoteCollectionGroupService)
    ///   - managerKey: Unique key for local persistence paths and analytics event prefixes (e.g., "reviews", "comments")
    ///   - enableLocalPersistence: Whether to persist the collection locally via SwiftData. Default `true`.
    ///   - logger: Optional logger for analytics events.
    public init(
        remote: any RemoteCollectionGroupService<T>,
        managerKey: String,
        enableLocalPersistence: Bool = true,
        logger: (any DataSyncLogger)? = nil
    ) {
        self.remote = remote
        self.managerKey = managerKey
        self.enableLocalPersistence = enableLocalPersistence
        self.logger = logger

        if enableLocalPersistence {
            let persistence = SwiftDataCollectionPersistence<T>(managerKey: managerKey)
            self.local = persistence

            // Load cached collection from local storage
            self.currentCollection = (try? persistence.getCollection(managerKey: managerKey)) ?? []
        } else {
            self.local = nil
        }
    }

    // MARK: - Lifecycle

    /// Start listening for real-time collection-group updates, optionally filtered by a query.
    ///
    /// This will:
    /// 1. Bulk load the collection from remote using the provided query (or an empty query)
    /// 2. Start streaming individual document changes (adds, updates, deletions)
    ///
    /// Calling again with the same query is a no-op. Calling with a different query stops
    /// the old listener, clears the collection, and starts fresh with the new query.
    ///
    /// - Parameter buildQuery: Optional closure to build a query. Pass `nil` (default) to use
    ///   an empty query (all documents in the collection group).
    public func startListening(
        buildQuery: ((QueryBuilder) -> QueryBuilder)? = nil
    ) async {
        let newQuery: QueryBuilder? = buildQuery.map { $0(QueryBuilder()) } ?? QueryBuilder()

        // If query hasn't changed and listener is already running, no-op
        let queryChanged = newQuery != currentQuery

        if !queryChanged && (updatesListenerTask != nil || deletionsListenerTask != nil) {
            return
        }

        // If query changed, stop old listener
        if queryChanged {
            logger?.trackEvent(event: Event.queryChanged(key: managerKey, filterCount: newQuery?.getFilters().count ?? 0))
            stopListener()
        }

        currentQuery = newQuery

        logger?.trackEvent(event: Event.listenerStart(key: managerKey))

        // Hybrid sync: Bulk load all documents, then stream changes
        await bulkLoadCollection()
        startListener()
    }

    /// Stop listening for real-time updates.
    ///
    /// - Parameter clearCaches: If true (default), clears `currentCollection`. If false, only cancels the listeners.
    public func stopListening(clearCaches: Bool = true) {
        logger?.trackEvent(event: Event.listenerStopped(key: managerKey))
        stopListener()

        if clearCaches {
            currentCollection = []

            if enableLocalPersistence {
                Task {
                    try? await local?.saveCollection(managerKey: managerKey, [])
                }
            }

            logger?.trackEvent(event: Event.cachesCleared(key: managerKey))
        }
    }

    // MARK: - Read: Collection

    /// Get the entire collection synchronously from cache.
    ///
    /// Returns empty if `startListening()` has not been called.
    /// - Returns: Array of all documents in the collection.
    public func getCollection() -> [T] {
        return currentCollection
    }

    // MARK: - Read: Filtered

    /// Get documents filtered by a condition synchronously from cache.
    ///
    /// Returns empty if `startListening()` has not been called.
    /// - Parameter predicate: Filtering condition.
    /// - Returns: Filtered array of documents.
    public func getDocuments(where predicate: (T) -> Bool) -> [T] {
        return currentCollection.filter(predicate)
    }

    /// Query documents using QueryBuilder — always fetches from remote.
    /// - Parameter buildQuery: Closure to build the query.
    /// - Returns: Array of documents matching the query from remote.
    /// - Throws: Error if query fails.
    public func getDocumentsAsync(buildQuery: (QueryBuilder) -> QueryBuilder) async throws -> [T] {
        defer {
            if listenerFailedToAttach {
                startListener()
            }
        }

        let query = buildQuery(QueryBuilder())
        let filterCount = query.getFilters().count

        logger?.trackEvent(event: Event.getDocumentsQueryStart(key: managerKey, filterCount: filterCount))

        do {
            let documents = try await remote.getDocuments(query: query)
            logger?.trackEvent(event: Event.getDocumentsQuerySuccess(key: managerKey, count: documents.count, filterCount: filterCount))
            return documents
        } catch {
            logger?.trackEvent(event: Event.getDocumentsQueryFail(key: managerKey, filterCount: filterCount, error: error))
            throw error
        }
    }

    /// Stream real-time snapshots of documents matching a query.
    ///
    /// Returns the filtered collection array on each change, without affecting `currentCollection`.
    /// - Parameter buildQuery: Closure to build the query.
    /// - Returns: An async stream of the filtered collection array.
    public func streamCollection(
        buildQuery: (QueryBuilder) -> QueryBuilder
    ) -> AsyncThrowingStream<[T], Error> {
        defer {
            if listenerFailedToAttach {
                startListener()
            }
        }

        let query = buildQuery(QueryBuilder())
        let filterCount = query.getFilters().count
        logger?.trackEvent(event: Event.streamCollectionQueryStart(key: managerKey, filterCount: filterCount))
        return remote.streamCollection(query: query)
    }

    /// Stream real-time updates for documents matching a query.
    ///
    /// Returns update and deletion streams scoped to the query, without affecting `currentCollection`.
    /// - Parameter buildQuery: Closure to build the query.
    /// - Returns: Tuple of (updates stream, deletions stream) for documents matching the query.
    public func streamCollectionUpdates(
        buildQuery: (QueryBuilder) -> QueryBuilder
    ) -> (updates: AsyncThrowingStream<T, Error>, deletions: AsyncThrowingStream<String, Error>) {
        defer {
            if listenerFailedToAttach {
                startListener()
            }
        }

        let query = buildQuery(QueryBuilder())
        let filterCount = query.getFilters().count
        logger?.trackEvent(event: Event.streamCollectionUpdatesQueryStart(key: managerKey, filterCount: filterCount))
        return remote.streamCollectionUpdates(query: query)
    }

    // MARK: - Private: Collection Update Handler

    private func handleCollectionUpdate(_ collection: [T]) {
        currentCollection = collection

        Task {
            try? await local?.saveCollection(managerKey: managerKey, collection)
        }
        logger?.trackEvent(event: Event.collectionUpdated(key: managerKey, count: collection.count))
    }

    // MARK: - Private: Bulk Load

    private func bulkLoadCollection() async {
        logger?.trackEvent(event: Event.bulkLoadStart(key: managerKey))

        do {
            let query = currentQuery ?? QueryBuilder()
            let collection = try await remote.getDocuments(query: query)
            handleCollectionUpdate(collection)
            logger?.trackEvent(event: Event.bulkLoadSuccess(key: managerKey, count: collection.count))
        } catch {
            logger?.trackEvent(event: Event.bulkLoadFail(key: managerKey, error: error))
        }
    }

    // MARK: - Private: Listener

    private func startListener() {
        logger?.trackEvent(event: Event.listenerStart(key: managerKey))
        listenerFailedToAttach = false

        stopListener()

        let query = currentQuery ?? QueryBuilder()
        let (updates, deletions) = remote.streamCollectionUpdates(query: query)

        updatesListenerTask = Task { @MainActor in
            await handleCollectionUpdates(updates)
        }

        deletionsListenerTask = Task { @MainActor in
            await handleCollectionDeletions(deletions)
        }
    }

    private func handleCollectionUpdates(_ updates: AsyncThrowingStream<T, Error>) async {
        var isFirstUpdate = true

        do {
            for try await document in updates {
                // Reset retry count on successful connection
                self.listenerRetryCount = 0

                // Log success only on first update (listener connected successfully)
                if isFirstUpdate {
                    logger?.trackEvent(event: Event.listenerSuccess(key: managerKey, count: currentCollection.count))
                    isFirstUpdate = false
                }

                // Update or add document in collection
                if let index = currentCollection.firstIndex(where: { $0.id == document.id }) {
                    currentCollection[index] = document
                } else {
                    currentCollection.append(document)
                }

                // Save to local persistence
                Task {
                    try? await local?.saveCollection(managerKey: managerKey, currentCollection)
                }
            }
        } catch {
            logger?.trackEvent(event: Event.listenerFail(key: managerKey, error: error))
            self.listenerFailedToAttach = true

            // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 60s (max)
            self.listenerRetryCount += 1
            let delay = min(pow(2.0, Double(self.listenerRetryCount)), 60.0)

            logger?.trackEvent(event: Event.listenerRetrying(key: managerKey, retryCount: self.listenerRetryCount, delaySeconds: delay))

            // Schedule retry with exponential backoff
            self.listenerRetryTask?.cancel()
            self.listenerRetryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled && self.listenerFailedToAttach {
                    self.startListener()
                }
            }
        }
    }

    private func handleCollectionDeletions(_ deletions: AsyncThrowingStream<String, Error>) async {
        do {
            for try await documentId in deletions {
                currentCollection.removeAll { $0.id == documentId }

                // Save to local persistence
                Task {
                    try? await local?.saveCollection(managerKey: managerKey, currentCollection)
                }
            }
        } catch {
            logger?.trackEvent(event: Event.listenerFail(key: managerKey, error: error))
            self.listenerFailedToAttach = true
        }
    }

    private func stopListener() {
        updatesListenerTask?.cancel()
        updatesListenerTask = nil
        deletionsListenerTask?.cancel()
        deletionsListenerTask = nil
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        listenerRetryCount = 0
    }

    // MARK: - Events

    enum Event: DataSyncLogEvent {
        case getDocumentsQueryStart(key: String, filterCount: Int)
        case getDocumentsQuerySuccess(key: String, count: Int, filterCount: Int)
        case getDocumentsQueryFail(key: String, filterCount: Int, error: Error)
        case bulkLoadStart(key: String)
        case bulkLoadSuccess(key: String, count: Int)
        case bulkLoadFail(key: String, error: Error)
        case listenerStart(key: String)
        case listenerSuccess(key: String, count: Int)
        case listenerFail(key: String, error: Error)
        case listenerRetrying(key: String, retryCount: Int, delaySeconds: Double)
        case listenerStopped(key: String)
        case collectionUpdated(key: String, count: Int)
        case streamCollectionQueryStart(key: String, filterCount: Int)
        case streamCollectionUpdatesQueryStart(key: String, filterCount: Int)
        case queryChanged(key: String, filterCount: Int)
        case cachesCleared(key: String)

        var eventName: String {
            switch self {
            case .getDocumentsQueryStart(let key, _):       return "\(key)_getDocumentsQuery_start"
            case .getDocumentsQuerySuccess(let key, _, _):  return "\(key)_getDocumentsQuery_success"
            case .getDocumentsQueryFail(let key, _, _):     return "\(key)_getDocumentsQuery_fail"
            case .bulkLoadStart(let key):                   return "\(key)_bulkLoad_start"
            case .bulkLoadSuccess(let key, _):              return "\(key)_bulkLoad_success"
            case .bulkLoadFail(let key, _):                 return "\(key)_bulkLoad_fail"
            case .listenerStart(let key):                   return "\(key)_listener_start"
            case .listenerSuccess(let key, _):              return "\(key)_listener_success"
            case .listenerFail(let key, _):                 return "\(key)_listener_fail"
            case .listenerRetrying(let key, _, _):          return "\(key)_listener_retrying"
            case .listenerStopped(let key):                 return "\(key)_listener_stopped"
            case .collectionUpdated(let key, _):            return "\(key)_collectionUpdated"
            case .streamCollectionQueryStart(let key, _):           return "\(key)_streamCollectionQuery_start"
            case .streamCollectionUpdatesQueryStart(let key, _):    return "\(key)_streamCollectionUpdatesQuery_start"
            case .queryChanged(let key, _):                         return "\(key)_queryChanged"
            case .cachesCleared(let key):                           return "\(key)_cachesCleared"
            }
        }

        var parameters: [String: Any]? {
            var dict: [String: Any] = [:]

            switch self {
            case .getDocumentsQueryStart(_, let filterCount):
                dict["filter_count"] = filterCount
            case .getDocumentsQuerySuccess(_, let count, let filterCount):
                dict["count"] = count
                dict["filter_count"] = filterCount
            case .getDocumentsQueryFail(_, let filterCount, let error):
                dict["filter_count"] = filterCount
                dict.merge(error.eventParameters)
            case .bulkLoadSuccess(_, let count), .listenerSuccess(_, let count), .collectionUpdated(_, let count):
                dict["count"] = count
            case .bulkLoadFail(_, let error), .listenerFail(_, let error):
                dict.merge(error.eventParameters)
            case .listenerRetrying(_, let retryCount, let delaySeconds):
                dict["retry_count"] = retryCount
                dict["delay_seconds"] = delaySeconds
            case .streamCollectionQueryStart(_, let filterCount),
                 .streamCollectionUpdatesQueryStart(_, let filterCount):
                dict["filter_count"] = filterCount
            case .queryChanged(_, let filterCount):
                dict["filter_count"] = filterCount
            default:
                break
            }

            return dict.isEmpty ? nil : dict
        }

        var type: DataLogType {
            switch self {
            case .getDocumentsQueryFail, .bulkLoadFail, .listenerFail:
                return .severe
            default:
                return .info
            }
        }
    }
}
