/// Default policy until an explicit, reviewed consent flow exists.
/// Anonymous diarization may use transient features within a run, but no
/// voiceprints are persisted or used to identify a person across runs.
public enum SpeakerPrivacyPolicy {
    public static let allowsAutomaticIdentityMatching = false

    public static func voiceprintsForStorage(_ voiceprints: [String: [Float]]) -> [String: [Float]] {
        [:]
    }
}
