//
//  RecorderDeviceLayoutTests.swift
//  KurnTests
//
//  Verifies that the paper recording screen is restricted to iPad, while
//  iPhone keeps the legacy dark recording screen (with `MeetingCoachPanel`
//  when the meeting coach is active) and never mounts a PencilKit paper canvas.
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

    @Test func iPhoneWithCoachDoesNotUsePaperCanvas() async throws {
        let (container, session) = try makeCoachedSession()
        _ = container
        defer { session.discard() }

        #expect(session.viewModel?.coach != nil)

        let hosting = UIHostingController(rootView: NavigationStack { RecorderView(session: session, idiom: .phone) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.view.layoutIfNeeded()

        #expect(
            findSubview(of: PKCanvasView.self, in: hosting.view) == nil,
            "iPhone with meeting coach must keep the legacy recording screen and never mount PKCanvasView"
        )
        window.isHidden = true
    }

    @Test func iPadWithCoachUsesPaperCanvas() async throws {
        let (container, session) = try makeCoachedSession()
        _ = container
        defer { session.discard() }

        let hosting = UIHostingController(rootView: RecorderView(session: session, idiom: .pad))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1_133))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.view.layoutIfNeeded()

        #expect(
            findSubview(of: PKCanvasView.self, in: hosting.view) != nil,
            "iPad must mount the PencilKit paper recording screen"
        )
        window.isHidden = true
    }

    @Test func usesPaperScreenPolicyRestrictsPaperToIPad() {
        #expect(PaperCanvasMetrics.usesPaperScreen(for: .pad))
        #expect(!PaperCanvasMetrics.usesPaperScreen(for: .phone))
        #expect(!PaperCanvasMetrics.usesPaperScreen(for: .mac))
        #expect(!PaperCanvasMetrics.usesPaperScreen(for: .unspecified))
    }
}
