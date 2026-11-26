import Testing
@testable import KurnCore

struct SpeakerPrivacyPolicyTests {
    @Test func automaticIdentityMatchingDefaultsOff() {
        #expect(!SpeakerPrivacyPolicy.allowsAutomaticIdentityMatching)
    }

    @Test func syntheticVoiceprintsAreNotPersisted() {
        let synthetic: [String: [Float]] = ["Speaker 1": [0.1, 0.2], "Speaker 2": [0.3, 0.4]]
        #expect(SpeakerPrivacyPolicy.voiceprintsForStorage(synthetic).isEmpty)
    }

    @Test func emptyVoiceprintsRemainEmpty() {
        #expect(SpeakerPrivacyPolicy.voiceprintsForStorage([:]).isEmpty)
    }
}
