//
//  DebugFileCaptureEngine.swift
//  Kurn
//
//  DEBUG only. Plays an audio file into the real capture pipeline at 1x, as
//  if it were the microphone, so live features can be exercised on a machine
//  with no input device (the simulator on a Mac mini). Everything downstream
//  — sink, file, journal, live transcription — is the production path.
//
//  Enable with the launch environment variable KURN_DEBUG_CAPTURE_FILE=<path>
//  (e.g. `SIMCTL_CHILD_KURN_DEBUG_CAPTURE_FILE=… xcrun simctl launch …`).
//  After the file ends it keeps feeding silence so the stall watchdog stays
//  quiet until the user stops the recording.
//

#if DEBUG
import AVFoundation
import Foundation

final class DebugFileCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var sink: (any AudioSinkWriting)?
    private var thread: Thread?
    private var running = false
    private var handler: (@Sendable (AudioCaptureEvent) -> Void)?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    /// A recorder fed from `KURN_DEBUG_CAPTURE_FILE`, or `nil` when it is unset.
    @MainActor
    static func recorderIfRequested() -> AudioRecorderService? {
        guard let path = ProcessInfo.processInfo.environment["KURN_DEBUG_CAPTURE_FILE"], !path.isEmpty else { return nil }
        do {
            let engine = try DebugFileCaptureEngine(url: URL(fileURLWithPath: path))
            AppLog.recorder.atNotice.notice("DebugFileCaptureEngine: feeding capture from a file")
            return AudioRecorderService(engine: engine, microphonePermission: { true })
        } catch {
            AppLog.recorder.atError.error("DebugFileCaptureEngine: cannot open file code=\(error.publicLogCode, privacy: .public)")
            return nil
        }
    }

    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    var isRunning: Bool { lock.withLock { running } }
    var inputFormat: AVAudioFormat? { file.processingFormat }

    func configureSession(pickup: MicPickup, forceBuiltIn: Bool, preferredInputUID: String?) async throws {}
    func reactivateSession() {}
    func deactivateSession() {}

    func openOutputFile(at url: URL, bitRate: Int) throws -> any AudioFileWriting {
        try CaptureOutputFile.openJournaled(at: url, bitRate: bitRate)
    }

    func installTap(format: AVAudioFormat, sink: any AudioSinkWriting) { lock.withLock { self.sink = sink } }
    func removeTap() { lock.withLock { sink = nil } }
    func disableVoiceProcessing() {}
    func prepare() {}

    func start() throws {
        lock.withLock { running = true }
        guard thread == nil else { return }
        let thread = Thread { [weak self] in Self.pump(weak: self) }
        thread.name = "DebugFileCaptureEngine"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func stop() { lock.withLock { running = false } }

    /// Holds the engine only per tick, so the thread ends once the recorder lets go of it.
    private static func pump(weak engine: DebugFileCaptureEngine?) {
        weak let engine = engine
        guard let format = engine?.file.processingFormat else { return }
        let frames = AVAudioFrameCount(format.sampleRate / 10) // 100 ms
        let begin = ProcessInfo.processInfo.systemUptime
        var fed = 0.0
        while let current = engine {
            current.tick(format: format, frames: frames)
            fed += Double(frames) / format.sampleRate
            let wait = begin + fed - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    private func tick(format: AVAudioFormat, frames: AVAudioFrameCount) {
        let (isRunning, sink) = lock.withLock { (running, self.sink) }
        guard isRunning, let sink, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        if (try? file.read(into: buffer, frameCount: frames)) == nil || buffer.frameLength == 0 {
            buffer.frameLength = frames // silence after EOF
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(frames))
            }
        }
        sink.write(buffer)
    }
}
#endif
