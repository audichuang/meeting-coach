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
    /// Recording time up to which the engine's frame predictions are final.
    var finalizedThrough: TimeInterval = 0
}

protocol LiveSpeakerDiarizerEngine: Sendable {
    func process(samples: [Float], sampleRate: Double) async throws -> LiveDiarizerUpdate?
    func finish() async throws -> LiveDiarizerUpdate?
    func cleanup() async
}

private struct LiveSpeakerAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// Index of the first sample counted from the session's first captured buffer, so the
    /// pump can fill dropped audio with silence and keep spans on the transcript's clock.
    let startSample: Int
}

private final class LiveSpeakerTimelineBox: Sendable {
    private struct State {
        var timeline = LiveSpeakerTimeline()
        var finalizedThrough: TimeInterval = 0
    }

    private let mutex = Mutex(State())

    func reset() {
        mutex.withLock { $0 = State() }
    }

    func ingest(_ update: LiveDiarizerUpdate) {
        mutex.withLock {
            $0.timeline.ingest(finalized: update.finalized, tentative: update.tentative)
            $0.finalizedThrough = max($0.finalizedThrough, update.finalizedThrough)
        }
    }

    /// `nil` until every frame up to `end` is final, so a label is never decided on tentative audio.
    func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> String? {
        mutex.withLock { end <= $0.finalizedThrough ? $0.timeline.dominantSpeaker(from: start, to: end) : nil }
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
    /// Returns `true` when the pump gave up on live diarization for this meeting.
    @ObservationIgnored private var pumpTask: Task<Bool, Never>?
    /// Longer gaps mean inference is falling behind real time; filling them with silence only adds work.
    private nonisolated static let maximumSilenceFill: TimeInterval = 30

    /// Bounded audio handoff from the real-time render thread to the background
    /// diarization task. Never creates Tasks on the audio callback.
    private nonisolated let audioQueue = BoundedSessionQueue<LiveSpeakerAudioChunk>(maximumCost: 16)
    private nonisolated let timelineBox = LiveSpeakerTimelineBox()
    private nonisolated let capturedSamples = Mutex(0)

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
        capturedSamples.withLock { $0 = 0 }
        // Accept audio while the model loads so its samples are counted on the recording clock.
        audioQueue.activate(session)
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
        let startSample = capturedSamples.withLock { position in
            defer { position += frameCount }
            return position
        }
        audioQueue.enqueue(
            LiveSpeakerAudioChunk(samples: samples, sampleRate: sampleRate, startSample: startSample),
            cost: duration,
            for: session
        )
    }

    /// Returns the dominant meeting-local speaker label for `[start, end]`, or `nil` when
    /// diarization is unavailable, has not finalized through `end` yet, or no speaker overlapped.
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
        let gaveUp = await activePump?.value ?? false
        guard let activeEngine else { return }
        if !discarding, !gaveUp {
            do {
                if let update = try await activeEngine.finish() {
                    timelineBox.ingest(update)
                }
            } catch {
                AppLog.transcription.atNotice.notice(
                    "LiveSpeakerDiarizationService: finish failed code=\(error.publicLogCode, privacy: .public)"
                )
            }
            onUpdate?()
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
        let markUnavailable: @MainActor @Sendable () -> Void = { [weak self] in self?.isAvailable = false }
        pumpTask = Task.detached(priority: .utility) {
            func feed(_ samples: [Float], sampleRate: Double) async throws {
                if let update = try await engine.process(samples: samples, sampleRate: sampleRate) {
                    box.ingest(update)
                    await MainActor.run { onUpdate() }
                }
            }
            // Already-finalized labels stay; later segments get none, so labels never drift.
            func giveUp(_ code: String) async -> Bool {
                AppLog.transcription.atNotice.notice(
                    "LiveSpeakerDiarizationService: stopping live diarization code=\(code, privacy: .public)"
                )
                queue.invalidate(session)
                await markUnavailable()
                return true
            }
            var fedSamples = 0
            while let chunk = await queue.next(for: session) {
                guard queue.isCurrent(session), !Task.isCancelled else { return false }
                do {
                    // Silence stands in for audio dropped on overflow, so the engine's frame
                    // clock keeps counting recording time.
                    let gap = chunk.startSample - fedSamples
                    if gap > 0 {
                        guard Double(gap) / chunk.sampleRate <= Self.maximumSilenceFill else {
                            return await giveUp("gap_too_long")
                        }
                        try await feed([Float](repeating: 0, count: gap), sampleRate: chunk.sampleRate)
                    }
                    try await feed(chunk.samples, sampleRate: chunk.sampleRate)
                    fedSamples = chunk.startSample + chunk.samples.count
                } catch is CancellationError {
                    return false
                } catch {
                    AppLog.transcription.atNotice.notice(
                        "LiveSpeakerDiarizationService: chunk failed code=\(error.publicLogCode, privacy: .public)"
                    )
                }
            }
            return false
        }
    }
}
