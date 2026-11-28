import SwiftUI

/// Playback controls pinned under the Transcript tab once a recording is
/// loaded, so a meeting started by tapping a line can be paused or scrubbed
/// without going back to the Recordings tab. Its own view so the player's
/// 0.1 s tick re-renders only this bar, not `MeetingDetailView`.
struct TranscriptPlaybackBar: View {
    let player: AudioPlayerService
    let recording: Recording
    let enhancement: PlaybackEnhancementViewModel
    let onToggleEnhancement: () -> Void

    var body: some View {
        SegmentPlaybackScrubber(
            currentTime: player.currentTime,
            duration: player.duration > 0 ? player.duration : recording.duration,
            isPlaying: player.isPlaying,
            playbackRate: player.playbackRate,
            isEnhanced: player.isPlayingEnhanced,
            enhancementProgress: enhancement.progress(for: recording),
            onSeek: { player.seek(to: $0) },
            onSkip: { player.skip(by: $0) },
            onCycleRate: { player.cycleRate() },
            onToggleEnhancement: onToggleEnhancement,
            onTogglePlay: { player.togglePlayPause() },
            leadingInset: 0
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
