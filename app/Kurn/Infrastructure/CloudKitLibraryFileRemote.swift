//
//  CloudKitLibraryFileRemote.swift
//  Kurn
//
//  Adapter: `LibraryFileRemote` over the private CloudKit database, one
//  `LibraryFile` record per file name with the bytes as a `CKAsset` streamed
//  from disk. Uses the default zone of the same container SwiftData mirrors
//  into; its records live beside, not inside, the store's own zone. Every
//  decision about what to send, fetch or delete lives in `LibraryFileSync`.
//

import CloudKit
import Foundation

struct CloudKitLibraryFileRemote: LibraryFileRemote {
    static let recordType = "LibraryFile"
    static let assetKey = "file"

    private let database: CKDatabase

    init(containerIdentifier: String = LibrarySync.containerIdentifier) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    func upload(fileName: String, from url: URL) async throws {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: fileName))
        record[Self.assetKey] = CKAsset(fileURL: url)
        // `.allKeys` overwrites a record another device already uploaded for the same file.
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        if case .failure(let error) = saved[record.recordID] { throw error }
    }

    func download(fileName: String) async throws -> URL? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: fileName))
            return (record[Self.assetKey] as? CKAsset)?.fileURL
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func delete(fileNames: [String]) async -> Set<String> {
        let ids = fileNames.map { CKRecord.ID(recordName: $0) }
        guard let (_, results) = try? await database.modifyRecords(saving: [], deleting: ids) else { return [] }
        var removed: Set<String> = []
        for (id, result) in results {
            switch result {
            case .success:
                removed.insert(id.recordName)
            case .failure(let error as CKError) where error.code == .unknownItem:
                removed.insert(id.recordName)
            case .failure:
                break
            }
        }
        return removed
    }
}
