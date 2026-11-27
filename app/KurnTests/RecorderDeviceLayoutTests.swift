//
//  RecorderDeviceLayoutTests.swift
//  KurnTests
//
//  Verifies that iPad and iPhone both mount the PencilKit paper recording
//  screen, and that the Release drawing policy lets a finger write on iPhone
//  while iPad stays Pencil-first.
//

import Foundation
import KurnCore
import PencilKit
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Kurn

@MainActor
struct RecorderDeviceLayoutTests {

    private func findSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = findSubview(of: type, in: child) { return found }
        }
        return nil
    }

    private func makeCoachedSession() throws -> (container: ModelContainer, session: RecordingSessionController) {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Phone Coach Test")
        context.insert(meeting)
        try context.save()

        let coachConfig = MeetingCoachConfiguration(userName: "測試者", budgetUSD: 10, backend: .test)
        let session = RecordingSessionController(
            modelContext: context,
            settings: AppSettings(),
            makeViewModel: { meeting, ctx in
                RecorderViewModel(
                    meeting: meeting,
                    modelContext: ctx,
                    defaultMode: .onDevice,
                    options: RecorderOptions(alwaysUseBuiltInMic: true, coach: coachConfig),
                    recorder: AudioRecorderService(
                        engine: FakeAudioCaptureEngine(),
                        sink: FakeAudioSinkWriting(),
                        stallInterval: 3_600,
                        microphonePermission: { true }
                    ),
                    liveTranscription: LiveTranscriptionService(),
                    fileFinalizer: StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)),
                    lifecycleSaver: ScriptedRecordingLifecycleSaver()
                )
            },
            prepare: { _ in }
        )
        session.begin(meeting: meeting)
        return (container, session)
    }

    @Test func iPhoneWithCoachUsesPaperCanvas() async throws {
        let (container, session) = try makeCoachedSession()
        defer {
            session.discard()
            _ = container
        }

        #expect(session.viewModel?.coach != nil)

        do {
            let hosting = UIHostingController(rootView: NavigationStack { RecorderView(session: session, idiom: .phone) })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            hosting.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            hosting.view.layoutIfNeeded()

            #expect(
                findSubview(of: PKCanvasView.self, in: hosting.view) != nil,
                "iPhone must mount the PencilKit paper recording screen"
            )
        }
        session.discard()
        await Task.yield()
    }

    @Test func iPadWithCoachUsesPaperCanvas() async throws {
        let (container, session) = try makeCoachedSession()
        defer {
            session.discard()
            _ = container
        }

        do {
            let hosting = UIHostingController(rootView: RecorderView(session: session, idiom: .pad))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1_133))
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            hosting.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            hosting.view.layoutIfNeeded()

            #expect(
                findSubview(of: PKCanvasView.self, in: hosting.view) != nil,
                "iPad must mount the PencilKit paper recording screen"
            )
        }
        session.discard()
        await Task.yield()
    }

    @Test func usesPaperScreenOnIPadAndIPhone() {
        #expect(PaperCanvasMetrics.usesPaperScreen(for: .pad))
        #expect(PaperCanvasMetrics.usesPaperScreen(for: .phone))
        #expect(!PaperCanvasMetrics.usesPaperScreen(for: .mac))
        #expect(!PaperCanvasMetrics.usesPaperScreen(for: .unspecified))
    }

    /// The Release policy, not the DEBUG simulator override (`.anyInput`
    /// everywhere): iPad keeps Pencil-first, iPhone lets a finger write.
    @Test func releaseDrawingPolicyAllowsFingerOnlyWithoutPencil() {
        #expect(PaperCanvasMetrics.releaseDrawingPolicy(for: .pad) == .default)
        #expect(PaperCanvasMetrics.releaseDrawingPolicy(for: .phone) == .anyInput)
    }
}
