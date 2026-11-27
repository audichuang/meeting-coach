//
//  DebugCoachPreview.swift
//  Kurn
//
//  DEBUG only. Provides a fully local, zero-network `MeetingCoachSession` and
//  no-op `LiveTranscriptionService` when `KURN_DEBUG_COACH_PREVIEW=1` is set
//  in the launch environment, so UI layout tests and simulator screenshots can
//  exercise the paper screen with a visible suggestion card and live transcript
//  without making paid API calls or touching any Worker URL/token.
//

#if DEBUG
import AVFoundation
import Foundation
import KurnCore
import SwiftData

#if canImport(FluidAudio)
import FluidAudio

private final class DebugPreviewCoachLLM: CoachLLM, @unchecked Sendable {
    private let lock = NSLock()
    private let stopStatusCode: Int?
    private var askCount = 0

    init(stopStatusCode: Int? = nil) {
        self.stopStatusCode = stopStatusCode
    }

    func call(
        model: String,
        instructions: String,
        input: String,
        tools: [CoachTool],
        force: String?
    ) async throws -> CoachCallResult {
        let name = tools.first?.name ?? "emit_suggestion"
        if name == "emit_suggestion", let stopStatusCode {
            let count = lock.withLock { () -> Int in
                askCount += 1
                return askCount
            }
            if count >= 2 {
                throw AppError.apiError(statusCode: stopStatusCode, message: "preview_stopped")
            }
        }
        let json: String
        switch name {
        case "judge":
            json = #"{"decision":"emit","reason":"排程與驗收口徑待對齊"}"#
        case "emit_wrapup":
            json = """
            {"common_goal":"確認下週版本驗收標準","disagreements":"介面欄位與測試排程仍待確認",\
            "open_questions":"是否需要預留兩天回歸測試","next_steps":"今天內確認清單並同步時程",\
            "spoken_text":"我們目前的共同目標是對齊下週版本驗收標準；排程與測試窗口還需要確認，建議今天內先敲定清單。"}
            """
        default:
            json = """
            {"short_text":"我們要不要先對齊下週交付範圍，再確認測試時間？",\
            "reason":"前兩段對範圍與時程的假設不同，先釐清可避免返工。",\
            "evidence_start":12,"evidence_end":26,"category":"clarify"}
            """
        }
        return CoachCallResult(
            calls: [CoachToolCall(name: name, arguments: Data(json.utf8))],
            usage: CoachTokenUsage(input: 420, cached: 0, output: 64)
        )
    }
}

private actor DebugPreviewStreamingEngine: StreamingAsrManager {
    nonisolated var displayName: String { "DebugCoachPreview" }
    private let onStart: @Sendable () -> Void
    private var partialCallback: (@Sendable (String) -> Void)?

    init(onStart: @escaping @Sendable () -> Void) {
        self.onStart = onStart
    }

    func loadModels() async throws {
        onStart()
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {}
    func processBufferedAudio() async throws {}
    func finish() async throws -> String { "" }
    func reset() async throws {}
    func cleanup() async { partialCallback = nil }
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        partialCallback = callback
    }
    func getPartialTranscript() -> String { "" }
}

@MainActor
enum DebugCoachPreview {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KURN_DEBUG_COACH_PREVIEW"] == "1"
    }

    static func makeIfRequested(
        meeting: Meeting,
        modelContext: ModelContext,
        elapsed: @escaping @MainActor () -> TimeInterval
    ) -> (session: MeetingCoachSession, liveTranscription: LiveTranscriptionService)? {
        guard isEnabled, let baseURL = URL(string: "https://localhost.invalid/v1") else { return nil }
        let configuration = MeetingCoachConfiguration(
            userName: "測試者",
            budgetUSD: 10,
            backend: CoachBackend(baseURL: baseURL, token: "preview", viaWorker: true)
        )
        let stopMode = ProcessInfo.processInfo.environment["KURN_DEBUG_COACH_PREVIEW_STOP"]
        let stopStatusCode: Int? = switch stopMode {
        case "quota": 402
        case "unauthorized": 401
        default: nil
        }
        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: modelContext,
            configuration: configuration,
            llm: DebugPreviewCoachLLM(stopStatusCode: stopStatusCode),
            elapsed: elapsed
        )
        let live = LiveTranscriptionService(engineFactory: { [weak session] _, _ in
            let engine = DebugPreviewStreamingEngine {
                Task { @MainActor in
                    guard let session else { return }
                    session.eventSink.yield(.connection(.live))
                    session.eventSink.yield(.billedSeconds(35))
                    session.eventSink.yield(.final(LiveTranscriptSegment(
                        start: 4,
                        end: 14,
                        text: "這週我們先把核心流程收斂，再決定下週的驗收項目。",
                        arrivedAt: 14
                    )))
                    session.eventSink.yield(.final(LiveTranscriptSegment(
                        start: 15,
                        end: 28,
                        text: "如果測試窗口只剩兩天，介面調整可能要拆到下一個版本。",
                        arrivedAt: 28
                    )))
                    for _ in 0..<20 where session.segments.count < 2 {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    await session.askForCard()
                    if stopStatusCode != nil {
                        await session.askForCard()
                    }
                }
            }
            try await engine.loadModels()
            return engine
        })
        return (session, live)
    }
}
#endif
#endif
