//
//  ScreenshotSeedData+LongTranscript.swift
//  Kurn
//
//  A synthetic two-hour meeting (1,500 segments and a silent two-hour audio
//  file) for checking that the Transcript tab scrolls and plays smoothly at
//  real meeting length. Off unless `KURN_DEBUG_SEED_LONG_TRANSCRIPT=1`.
//

#if DEBUG
import AVFoundation
import Foundation
import KurnCore
import SwiftData

extension ScreenshotSeedData {
    static func seedLongTranscript(into context: ModelContext) {
        let duration: TimeInterval = 7200
        let meeting = Meeting(title: "Long transcript (2 h)", createdAt: Date())
        context.insert(meeting)
        for (index, color) in ["#5E5CE6", "#34C759", "#FF9500"].enumerated() {
            context.insert(Speaker(meeting: meeting, label: "Speaker \(index + 1)", name: "", color: color))
        }
        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: duration,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudio(fileName: recording.fileName, seconds: Int(duration))

        let count = 1500
        let step = duration / Double(count)
        let segments = (0..<count).map { index in
            TranscriptSegment(
                speakerLabel: "Speaker \(index % 3 + 1)",
                startTime: Double(index) * step,
                endTime: Double(index + 1) * step,
                text: "Segment \(index + 1). Synthetic transcript text long enough to wrap onto a second or third line, "
                    + "the way a real meeting turn does when somebody explains a point at length."
            )
        }
        context.insert(Transcript(recording: recording, segments: segments, language: "en-US"))
    }

    private static func writeSilentAudio(fileName: String, seconds: Int) {
        let rate = 16_000.0
        guard let directory = try? AudioFileStore.ensureRecordingsDirectory(),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(
                  forWriting: directory.appendingPathComponent(fileName),
                  settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate) * 60)
        else { return }
        buffer.frameLength = buffer.frameCapacity
        for _ in 0..<(seconds / 60) { try? file.write(from: buffer) }
    }
}
#endif
