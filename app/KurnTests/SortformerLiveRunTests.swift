import AVFoundation
import Foundation
import Testing
@testable import Kurn

/// Manual check against the real downloaded Sortformer model; skipped unless
/// `MC_SORTFORMER_WAV` points at a mono WAV (set `TEST_RUNNER_MC_SORTFORMER_WAV`).
struct SortformerLiveRunTests {
    static let wavPath = ProcessInfo.processInfo.environment["MC_SORTFORMER_WAV"]

    @Test(.enabled(if: wavPath != nil && FluidAudioModelAvailability.isStreamingDiarizationInstalled))
    func printsSpansForASyntheticTwoVoiceFile() async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(Self.wavPath)))
        let format = file.processingFormat
        let engine = try SortformerLiveDiarizerEngine()
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        while let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            if let update = try await engine.process(samples: samples, sampleRate: format.sampleRate) {
                for span in update.finalized { print("SORTFORMER final slot=\(span.speakerSlot) \(span.start)-\(span.end)") }
            }
        }
        if let update = try await engine.finish() {
            for span in update.finalized { print("SORTFORMER final slot=\(span.speakerSlot) \(span.start)-\(span.end)") }
            for span in update.tentative { print("SORTFORMER tentative slot=\(span.speakerSlot) \(span.start)-\(span.end)") }
        }
        await engine.cleanup()
    }
}
