//
//  LiveSpeakerDiarizationService+Sortformer.swift
//  Kurn
//
//  Thin FluidAudio adapter backing `LiveSpeakerDiarizationService` with
//  NVIDIA Sortformer (4 fixed speaker slots, 80 ms frame resolution).
//

import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

actor SortformerLiveDiarizerEngine: LiveSpeakerDiarizerEngine {
    private let diarizer: SortformerDiarizer
    private let frameDuration: TimeInterval

    init() throws {
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        // Do not retain raw frame probabilities or duplicate segment arrays in memory
        // over a 2-hour meeting; `LiveSpeakerTimeline` owns the accumulated spans.
        timelineConfig.maxStoredFrames = 0
        timelineConfig.storeSegments = false
        self.frameDuration = TimeInterval(timelineConfig.frameDurationSeconds)
        self.diarizer = try FluidAudioDiarizationModelRuntime.makeLocalSortformerDiarizer(
            timelineConfig: timelineConfig
        )
    }

    func process(samples: [Float], sampleRate: Double) throws -> LiveDiarizerUpdate? {
        guard let update = try diarizer.process(samples: samples, sourceSampleRate: sampleRate) else {
            return nil
        }
        return convert(update)
    }

    func finish() throws -> LiveDiarizerUpdate? {
        guard let update = try diarizer.finalizeSession() else {
            return nil
        }
        return convert(update)
    }

    func cleanup() {
        diarizer.cleanup()
    }

    private func convert(_ update: DiarizerTimelineUpdate) -> LiveDiarizerUpdate {
        LiveDiarizerUpdate(
            finalized: update.finalizedSegments.map {
                LiveSpeakerSpan(speakerSlot: $0.speakerIndex, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime))
            },
            tentative: update.tentativeSegments.map {
                LiveSpeakerSpan(speakerSlot: $0.speakerIndex, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime))
            },
            // `startFrame` is Sortformer's cumulative processed-frame count.
            finalizedThrough: TimeInterval(update.chunkResult.startFrame + update.chunkResult.finalizedFrameCount) * frameDuration
        )
    }
}

extension LiveSpeakerDiarizationService {
    nonisolated static func makeDefaultEngine() async throws -> any LiveSpeakerDiarizerEngine {
        try SortformerLiveDiarizerEngine()
    }
}
#else
extension LiveSpeakerDiarizationService {
    nonisolated static func makeDefaultEngine() async throws -> any LiveSpeakerDiarizerEngine {
        throw AppError.modelDownloadRequired("Sortformer")
    }
}
#endif
