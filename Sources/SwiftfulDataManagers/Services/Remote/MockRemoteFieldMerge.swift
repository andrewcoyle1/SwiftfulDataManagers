//
//  MockRemoteFieldMerge.swift
//  SwiftfulDataManagers
//

import Foundation

/// Applies an `updateDocument` field dictionary to a model the way Firestore's merge does, for
/// the mock remotes. The model is round-tripped through JSON so any `Codable` model works
/// without knowing its fields; the update's values are encoded the same way, so a `Date` or a
/// nested `Codable` lands in the shape the model's decoder expects.
enum MockRemoteFieldMerge {

    static func apply<T: DataSyncModelProtocol>(_ data: [String: any DMCodableSendable], to document: T) throws -> T {
        let encoder = JSONEncoder()
        guard var object = try JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any] else {
            return document
        }
        for (key, value) in data {
            let encoded = try encoder.encode(AnyEncodable(value: value))
            object[key] = try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed)
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}
