import Foundation

#if canImport(CloudKit)
import CloudKit

actor CloudKitLibrarySync: LibrarySyncing {
    static let shared = CloudKitLibrarySync()

    private let container: CKContainer
    private let database: CKDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let recordType = "Collection"
    private let payloadField: CKRecord.FieldKey = "payload"
    private let schemaVersionField: CKRecord.FieldKey = "schemaVersion"
    private let updatedAtField: CKRecord.FieldKey = "updatedAt"
    private let currentSchemaVersion = 2

    init(container: CKContainer = .default()) {
        self.container = container
        self.database = container.privateCloudDatabase

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchRemoteCollections() async throws -> [AudiobookCollection] {
        var collections: [AudiobookCollection] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            if let currentCursor = cursor {
                let result = try await database.records(continuingMatchFrom: currentCursor)
                collections.append(contentsOf: decode(matchResults: result.matchResults))
                cursor = result.queryCursor
            } else {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let result = try await database.records(matching: query)
                collections.append(contentsOf: decode(matchResults: result.matchResults))
                cursor = result.queryCursor
            }
        } while cursor != nil

        return collections
    }

    func saveRemoteCollection(_ collection: AudiobookCollection) async throws {
        let recordID = CKRecord.ID(recordName: collection.id.uuidString)
        let record: CKRecord

        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

        let data = try encoder.encode(collection)
        record[payloadField] = data as CKRecordValue
        record[schemaVersionField] = currentSchemaVersion as CKRecordValue
        record[updatedAtField] = collection.updatedAt as CKRecordValue

        _ = try await database.save(record)
    }

    func deleteRemoteCollection(withID id: UUID) async throws {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted; ignore.
        } catch {
            throw error
        }
    }

    private func decode(matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]) -> [AudiobookCollection] {
        matchResults.compactMap { _, result in
            guard case .success(let record) = result,
                  let data = record[payloadField] as? Data
            else {
                return nil
            }

            return try? decoder.decode(AudiobookCollection.self, from: data)
        }
    }
}
#endif
