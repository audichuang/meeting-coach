//
//  ModelDownloadController+StreamingDiarization.swift
//  Kurn
//
//  Download, deletion, and on-disk size refresh for the meeting coach's
//  on-device streaming speaker-tagging model (FluidAudio Sortformer).
//

import Foundation
import KurnCore

extension ModelDownloadController {
    func refreshStreamingDiarizationState() {
        let installed = isStreamingDiarizationInstalled()
        isStreamingDiarizationReady = installed
        streamingDiarizationBytes = installed ? streamingDiarizationSizeBytes() : 0
    }

    func requestStreamingDiarizationDownload() {
        guard !isDownloading, !isStreamingDiarizationReady else { return }
        error = nil
        showingStreamingDiarizationConsent = true
    }

    func confirmStreamingDiarization(settings: AppSettings) {
        showingStreamingDiarizationConsent = false
        download(.streamingDiarization, recordingAs: .streamingDiarization, policy: settings.largeTransferPolicy) { [self] in
            refreshStreamingDiarizationState()
        } cleanup: { [self] in
            refreshStreamingDiarizationState()
        }
    }

    func requestDeleteStreamingDiarization() {
        guard !isDownloading, isStreamingDiarizationReady else { return }
        showingStreamingDiarizationDeleteConfirm = true
    }

    func confirmDeleteStreamingDiarization() {
        showingStreamingDiarizationDeleteConfirm = false
        deleteStreamingDiarizationFiles()
        refreshStreamingDiarizationState()
        refreshInstalledModels()
    }
}
