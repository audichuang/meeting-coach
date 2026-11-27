//
//  LiveSpeakerDiarizationService.swift
//  Kurn
//
//  Runs on-device streaming speaker diarization alongside live cloud
//  transcription so each `LiveTranscriptSegment` can receive an anonymous
//  meeting-local speaker label (A/B/C/D) by time overlap.
//
//  Audio capture never blocks on this service: `append(_:)` is `nonisolated`,
//  copies mono Float samples into a bounded `BoundedSessionQueue`, and returns
//  immediately. Inference runs off the main actor; when the streaming model is
//  not installed locally (or fails to load), the service stays inactive and
//  `dominantSpeaker(from:to:)` simply returns `nil`.
//

import AVFoundation
import Foundation
import KurnCore
import Observation
import Synchronization

struct LiveDiarizerUpdate: Sendable, Equatable {
    let finalized: [LiveSpeakerSpan]
    let tentative: [LiveSpeakerSpan]
}

protocol LiveSpeakerDiarizerEngine: Sendable {
    func process(samples: [Float], sampleRate: Double) async throws -> LiveDiarizerUpdate?
    func finish() async throws -> LiveDiarizerUpdate?
    func cleanup() async
}

private struct LiveSpeakerAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
}

private final class LiveSpeakerTimelineBox: Sendable {
    private let mutex = Mutex(LiveSpeakerTimeline())

    func reset() {
        mutex.withLock { $0.reset() }
    }

    func ingest(finalized: [LiveSpeakerSpan], tentative: [LiveSpeakerSpan]) {
        mutex.withLock { $0.ingest(finalized: finalized, tentative: tentative) }
    }

    func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> String? {
        mutex.withLock { $0.dominantSpeaker(from: start, to: end) }
    }
}

@MainActor
@Observable
final class LiveSpeakerDiarizationService {
    typealias EngineFactory = @Sendable () async throws -> any LiveSpeakerDiarizerEngine

    private(set) var isAvailable = false

    private let isInstalled: @Sendable () -> Bool
    private let engineFactory: EngineFactory
    private var engine: (any LiveSpeakerDiarizerEngine)?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    /// Bounded audio handoff from the real-time render thread to the background
    /// diarization task. Never creates Tasks on the audio callback.
    private nonisolated let audioQueue = BoundedSessionQueue<LiveSpeakerAudioChunk>(maximumCost: 16)
    private nonisolated let timelineBox = LiveSpeakerTimelineBox()

    init(
        isInstalled: @escaping @Sendable () -> Bool = { FluidAudioModelAvailability.isStreamingDiarizationInstalled },
        engineFactory: @escaping EngineFactory = LiveSpeakerDiarizationService.makeDefaultEngine
    ) {
        self.isInstalled = isInstalled
        self.engineFactory = engineFactory
    }

    deinit {
        audioQueue.invalidate()
        pumpTask?.cancel()
    }

    /// Start streaming diarization when the local model is installed.
    /// Never downloads models at runtime; stays inactive if unavailable.
    func start(onUpdate: @escaping @MainActor @Sendable () -> Void = {}) async {
        guard engine == nil else { return }
        timelineBox.reset()
        guard isInstalled() else {
            isAvailable = false
            return
        }
        let session = audioQueue.begin()
        let loadedEngine: any LiveSpeakerDiarizerEngine
        do {
            loadedEngine = try await Task.detached(priority: .utility) { [engineFactory] in
                try await engineFactory()
            }.value
        } catch {
            guard audioQueue.isCurrent(session) else { return }
            AppLog.transcription.atNotice.notice(
                "LiveSpeakerDiarizationService: streaming diarizer unavailable code=\(error.publicLogCode, privacy: .public)"
            )
            audioQueue.invalidate(session)
            isAvailable = false
            return
        }
        guard audioQueue.isCurrent(session) else {
            await loadedEngine.cleanup()
            return
        }
        guard audioQueue.activate(session) else {
            await loadedEngine.cleanup()
            return
        }
        engine = loadedEngine
        isAvailable = true
        startPump(engine: loadedEngine, session: session, onUpdate: onUpdate)
    }

    /// Called on the audio render thread via `AudioRecorderService.onAudioBuffer`.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let session = audioQueue.receivingToken else { return }
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0,
              let channel = buffer.floatChannelData?[0] else { return }
        let duration = Double(frameCount) / sampleRate
        guard duration.isFinite, duration > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        audioQueue.enqueue(
            LiveSpeakerAudioChunk(samples: samples, sampleRate: sampleRate, duration: duration),
            cost: duration,
            for: session
        )
    }

    /// Returns the dominant meeting-local speaker label for `[start, end]`,
    /// or `nil` when diarization is unavailable or no speaker overlapped.
    nonisolated func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> String? {
        timelineBox.dominantSpeaker(from: start, to: end)
    }

    func stop(discarding: Bool = false, onUpdate: (@MainActor @Sendable () -> Void)? = nil) async {
        audioQueue.invalidate()
        let activeEngine = engine
        engine = nil
        let activePump = pumpTask
        pumpTask = nil
        isAvailable = false
        activePump?.cancel()
        await activePump?.value
        guard let activeEngine else { return }
        if !discarding {
            do {
                if let update = try await activeEngine.finish() {
                    ingest(update)
                    onUpdate?()
                }
            } catch {
                AppLog.transcription.atNotice.notice(
                    "LiveSpeakerDiarizationService: finish failed code=\(error.publicLogCode, privacy: .public)"
                )
            }
        }
        await activeEngine.cleanup()
    }

    private func startPump(
        engine: any LiveSpeakerDiarizerEngine,
        session: BoundedSessionQueue<LiveSpeakerAudioChunk>.Token,
        onUpdate: @escaping @MainActor @Sendable () -> Void
    ) {
        let queue = audioQueue
        let box = timelineBox
        pumpTask = Task.detached(priority: .utility) {
            while let chunk = await queue.next(for: session) {
                guard queue.isCurrent(session), !Task.isCancelled else { return }
                do {
                    if let update = try await engine.process(samples: chunk.samples, sampleRate: chunk.sampleRate) {
                        box.ingest(finalized: update.finalized, tentative: update.tentative)
                        await MainActor.run { onUpdate() }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    AppLog.transcription.atNotice.notice(
                        "LiveSpeakerDiarizationService: chunk failed code=\(error.publicLogCode, privacy: .public)"
                    )
                }
            }
        }
    }

    private nonisolated func ingest(_ update: LiveDiarizerUpdate) {
        timelineBox.ingest(finalized: update.finalized, tentative: update.tentative)
    }
}
