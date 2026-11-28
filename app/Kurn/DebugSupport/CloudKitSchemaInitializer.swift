//
//  CloudKitSchemaInitializer.swift
//  Kurn
//
//  DEBUG-only: creates every record type iCloud sync uses in the container's
//  Development environment, so the schema can be deployed to Production
//  (which TestFlight and App Store builds use) from the CloudKit console.
//  SwiftData has no equivalent of `initializeCloudKitSchema()`, so this
//  builds a throwaway Core Data container from the live model graph. Needs a
//  device or simulator signed in to iCloud. Launch with the
//  `-InitializeCloudKitSchema` argument; the result is logged.
//

#if DEBUG
import CloudKit
import CoreData
import Foundation
import SwiftData

enum CloudKitSchemaInitializer {
    static let launchArgument = "-InitializeCloudKitSchema"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        Task.detached {
            do {
                try initializeStoreSchema()
                try await initializeFileRecordType()
                AppLog.persistence.atNotice.notice("cloudkit schema: initialized")
                print("CKSCHEMA: initialized")
            } catch {
                AppLog.persistence.atError.error("cloudkit schema: failed \(String(describing: error), privacy: .public)")
                print("CKSCHEMA: failed \(error)")
            }
        }
    }

    private static func initializeStoreSchema() throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: KurnModelGraph.currentModels) else {
            throw CocoaError(.featureUnsupported)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudkit-schema-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: LibrarySync.containerIdentifier
        )
        description.shouldAddStoreAsynchronously = false
        let container = NSPersistentCloudKitContainer(name: "CloudKitSchema", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        try container.initializeCloudKitSchema()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    /// `LibraryFile` is created just in time by its first save; save and delete one.
    private static func initializeFileRecordType() async throws {
        let placeholder = FileManager.default.temporaryDirectory.appendingPathComponent("cloudkit-schema-placeholder")
        try Data("schema".utf8).write(to: placeholder)
        let remote = CloudKitLibraryFileRemote()
        let name = "schema-placeholder-\(UUID().uuidString)"
        try await remote.upload(fileName: name, from: placeholder)
        _ = await remote.delete(fileNames: [name])
    }
}
#endif
