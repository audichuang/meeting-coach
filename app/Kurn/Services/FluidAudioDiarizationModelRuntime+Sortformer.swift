//
//  FluidAudioDiarizationModelRuntime+Sortformer.swift
//  Kurn
//
//  Thin adapter for loading a locally cached Sortformer streaming diarizer
//  model (never downloads at runtime) and for explicit opt-in download.
//  Cache completeness checks live in `FluidAudioDiarizationModelRuntime`.
//

import Foundation
import KurnCore

#if canImport(FluidAudio)
import CoreML
import FluidAudio

extension FluidAudioDiarizationModelRuntime {
    /// Load the cached Sortformer CoreML bundle locally without touching the network.
    static func makeLocalSortformerDiarizer(
        timelineConfig: DiarizerTimelineConfig
    ) throws -> SortformerDiarizer {
        try Task.checkCancellation()
        guard isSortformerInstalled else {
            throw AppError.modelDownloadRequired("Sortformer")
        }
        let config = sortformerConfig
        let modelURL = sortformerDirectory.appendingPathComponent(sortformerBundleName)
        let started = Date()
        let mlConfig = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The simulator's emulated GPU runs the fp16 model but collapses every
        // voice into slot 0 (measured on a two-voice file); CPU separates them.
        mlConfig.computeUnits = .cpuOnly
        #else
        mlConfig.computeUnits = SortformerModels.recommendedComputeUnits(for: config)
        mlConfig.allowLowPrecisionAccumulationOnGPU = true
        #endif
        let mainModel = try MLModel(contentsOf: modelURL, configuration: mlConfig)
        let models = try SortformerModels(
            config: config,
            main: mainModel,
            compilationDuration: Date().timeIntervalSince(started)
        )
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        diarizer.initialize(models: models)
        return diarizer
    }

    /// Explicitly download the Sortformer streaming diarization bundle into FluidAudio's cache.
    static func downloadSortformer(
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        let progressHandler: ProgressHandler = { progress in
            let phase: ModelDownloadPhase
            switch progress.phase {
            case .listing: phase = .preparing
            case .downloading: phase = .downloading
            case .compiling: phase = .compiling
            }
            onProgress(.scaled(progress.fractionCompleted, from: 0, to: 1, phase: phase))
        }
        _ = try await SortformerModels.loadFromHuggingFace(
            config: sortformerConfig,
            cacheDirectory: ModelStore.modelsDirectory,
            computeUnits: nil,
            progressHandler: progressHandler
        )
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
    }
}
#endif
