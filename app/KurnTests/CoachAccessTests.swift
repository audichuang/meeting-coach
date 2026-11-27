import Foundation
import Testing
@testable import Kurn

/// Every Worker request carries the Cloudflare Access service token; OpenAI requests never do.
@Suite(.serialized)
struct CoachAccessTests {
    private static let access = ["CF-Access-Client-Id": "id.access", "CF-Access-Client-Secret": "secret"]
    private let worker = CoachBackend(
        baseURL: URL(string: "https://worker.test/v1")!, token: "mc_test", viaWorker: true, accessHeaders: Self.access
    )

    private func expectAccess(_ request: URLRequest?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let request = try #require(request, sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access", sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret", sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mc_test", sourceLocation: sourceLocation)
    }

    @Test func usageRequestCarriesAccessHeaders() async throws {
        MockURLProtocol.enqueue([MockURLProtocol.json(["month": ["usd": 1.0], "monthly_cap_usd": 30.0])])
        _ = try await worker.usage(session: MockURLProtocol.session())
        try expectAccess(MockURLProtocol.lastRequest)
    }

    @Test func responsesRequestCarriesAccessHeaders() async throws {
        MockURLProtocol.enqueue([MockURLProtocol.json([:])])
        _ = try await CoachResponsesClient(backend: worker, session: MockURLProtocol.session()).send(["model": "m"], timeout: 5)
        try expectAccess(MockURLProtocol.lastRequest)
    }

    @Test func realtimeSessionMintCarriesAccessHeaders() async throws {
        MockURLProtocol.enqueue([MockURLProtocol.json(["value": "ek_short"])])
        let key = try await OpenAILiveTranscriber.mintClientSecret(backend: worker, session: MockURLProtocol.session())
        #expect(key == "ek_short")
        try expectAccess(MockURLProtocol.lastRequest)
        #expect(MockURLProtocol.lastRequest?.url?.host == "worker.test")
    }

    @Test func workerTranscriptionCarriesAccessHeadersButOpenAIDoesNot() async throws {
        MockURLProtocol.enqueue([MockURLProtocol.json(["text": "hi", "language": "en"])])
        let viaWorker = OpenAIProvider(apiKey: "mc_test", session: MockURLProtocol.session(), extraHeaders: Self.access)
        _ = try await viaWorker.transcribe(audioData: Data([1]), fileName: "c.m4a", language: .english)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")

        MockURLProtocol.enqueue([MockURLProtocol.json(["text": "hi", "language": "en"])])
        let direct = OpenAIProvider(apiKey: "sk-test", session: MockURLProtocol.session())
        _ = try await direct.transcribe(audioData: Data([1]), fileName: "c.m4a", language: .english)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func directBackendSendsOnlyTheBearerKey() {
        let direct = CoachBackend(baseURL: URL(string: "https://api.openai.com/v1")!, token: "sk-test", viaWorker: false)
        var request = URLRequest(url: direct.baseURL)
        direct.authorize(&request)
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer sk-test"])
    }
}
