//
//  SchemaV9MigrationTests.swift
//  KurnTests
//
//  V9 exists so the opt-in iCloud sync can mirror the store: CloudKit refuses
//  a model with unique constraints, attributes without defaults or non-optional
//  relationships (it lists every offender when the container loads). These
//  pin both halves: the live graph obeys those rules, and a 1.7.0 store keeps
//  every relationship through the rename to `…Storage`.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaV9MigrationTests {
    @Test func theCurrentSchemaIsV9() {
        #expect(KurnModelGraph.currentSchemaVersion == Schema.Version(1, 8, 0))
        let liveIdentifiers = Set(KurnSchemaV9.models.map { ObjectIdentifier($0) })
        #expect(KurnSchemaV8.models.allSatisfy { !liveIdentifiers.contains(ObjectIdentifier($0)) })
    }

    @Test func theLiveGraphMeetsCloudKitsRules() {
        var violations: [String] = []
        for entity in KurnModelGraph.schema.entities {
            for attribute in entity.attributes {
                if attribute.isUnique { violations.append("\(entity.name).\(attribute.name) is unique") }
                if !attribute.isOptional, attribute.defaultValue == nil {
                    violations.append("\(entity.name).\(attribute.name) has no default")
                }
            }
            for relationship in entity.relationships where !relationship.isOptional {
                violations.append("\(entity.name).\(relationship.name) is not optional")
            }
            if !entity.uniquenessConstraints.isEmpty {
                violations.append("\(entity.name) has uniqueness constraints")
            }
        }
        #expect(violations == [])
    }

    @Test func aV8StoreKeepsEveryRelationship() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV9MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v8.store")
        let meetingID = UUID()
        do {
            let schema = Schema(versionedSchema: KurnSchemaV8.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let context = container.mainContext
            let parent = KurnSchemaV8.Folder(name: "Clients", iconName: "folder.fill", colorHex: "#FF0000")
            let child = KurnSchemaV8.Folder(name: "Acme", iconName: "folder.fill", colorHex: "#00FF00", parent: parent)
            let meeting = KurnSchemaV8.Meeting(id: meetingID, title: "Before sync", notes: "n",
                                               languageRaw: MeetingLanguage.english.rawValue, folder: child)
            let tag = KurnSchemaV8.Tag(name: "Q3", colorHex: "#0000FF")
            context.insert(parent)
            context.insert(child)
            context.insert(meeting)
            context.insert(tag)
            meeting.tags = [tag]
            let recording = KurnSchemaV8.Recording(meeting: meeting, fileName: "a.m4a", duration: 60,
                                                   transcriptionStatusRaw: "done", transcriptionModeRaw: "auto")
            context.insert(recording)
            context.insert(KurnSchemaV8.MeetingPhoto(recording: recording, fileName: "p.jpg", capturedAt: 5))
            context.insert(KurnSchemaV8.CoachRecord(meeting: meeting, recordingID: recording.id, userName: "Tester"))
            try context.save()
        }

        let container = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let context = container.mainContext
        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.id == meetingID)
        #expect(meeting.title == "Before sync")
        #expect(meeting.tags.map(\.name) == ["Q3"])
        #expect(meeting.tags.first?.meetings.map(\.id) == [meetingID])
        #expect(meeting.folder?.name == "Acme")
        #expect(meeting.folder?.parent?.children.map(\.name) == ["Acme"])
        #expect(meeting.folder?.meetings.map(\.id) == [meetingID])
        let recording = try #require(meeting.recordings.first)
        #expect(recording.fileName == "a.m4a")
        #expect(recording.photos.map(\.fileName) == ["p.jpg"])
        #expect(meeting.coachRecords.map(\.userName) == ["Tester"])

        // The renamed storage still writes through the computed accessors.
        let second = Tag(name: "Q4", colorHex: "#FFFFFF")
        context.insert(second)
        meeting.tags.append(second)
        try context.save()
        #expect(Set(meeting.tags.map(\.name)) == ["Q3", "Q4"])
        #expect(second.meetings.map(\.id) == [meetingID])
    }
}
