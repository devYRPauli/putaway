import Foundation
import Testing
@testable import PutawayCore

/// Answers every request on a session made by `session()` with `reply`, and keeps the last request and its body.
final class FakeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: String)? = (200, "")
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var body: [String: Any] = [:]

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.request = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        guard let reply = Self.reply else {
            // What macOS reports for a localhost port with nothing listening.
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

let folders = ["Receipts", "Taxes", "Work"]

func chat(_ content: String) throws -> String {
    let reply = ["choices": [["message": ["role": "assistant", "content": content]]]]
    return String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
}

@Suite(.serialized) struct NetworkEngines {
    let ollama = try! OwnModel(baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b-instruct")

    @Test func jevUsesTheChoiceProbabilityNotItsSpreadConfidence() async throws {
        FakeServer.reply = (200, #"{"model":"jev-1.13.0","answers":{"folder":{"type":"choice","choice":"Taxes","confidence":0.78,"probabilities":{"Receipts":0.15,"Taxes":0.85,"Work":0.0}}}}"#)
        let verdict = try await DecisionClassifier(provider: .jev, key: "k-test", session: FakeServer.session()).classify(.text("2026 W-2"), folders: folders)
        #expect(verdict == Verdict(folder: "Taxes", confidence: 0.85))
        #expect(FakeServer.request?.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(FakeServer.request?.value(forHTTPHeaderField: "Authorization") == "Bearer k-test")
        #expect(FakeServer.body["model"] as? String == "jev-latest")
    }

    @Test func subqGoesToSubq() async throws {
        FakeServer.reply = (200, #"{"answers":{"folder":{"type":"choice","choice":"Work","confidence":0.9,"probabilities":{"Receipts":0.05,"Taxes":0.05,"Work":0.9}}}}"#)
        let verdict = try await DecisionClassifier(provider: .subq, key: "k", session: FakeServer.session()).classify(.nameOnly("deck.key"), folders: folders)
        #expect(verdict == Verdict(folder: "Work", confidence: 0.9))
        #expect(FakeServer.request?.url?.absoluteString == "https://api.subq.ai/v1/systemone")
        #expect(FakeServer.body["model"] as? String == "subq-snap-preview")
    }

    @Test func outOfCreditsStopsThePlan() async throws {
        FakeServer.reply = (402, #"{"detail":{"error_type":"credits","message":"no credits"}}"#)
        await #expect(throws: ClassifierUnavailable.self) {
            try await DecisionClassifier(provider: .subq, key: "k", session: FakeServer.session()).classify(.text("x"), folders: folders)
        }
    }

    @Test func ownModelAsksForOneOfTheFoldersAndNeverAutoMoves() async throws {
        FakeServer.reply = (200, try chat(#"{"folder": "Receipts"}"#))
        let verdict = try await OwnModelClassifier(server: ollama, session: FakeServer.session()).classify(.text("Total $12.40"), folders: folders)
        #expect(verdict == Verdict(folder: "Receipts", confidence: nil))
        #expect(FakeServer.request?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(FakeServer.request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(FakeServer.body["model"] as? String == "qwen2.5:7b-instruct")
        let format = FakeServer.body["response_format"] as? [String: Any]
        let schema = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        let folder = (schema?["properties"] as? [String: Any])?["folder"] as? [String: Any]
        #expect(folder?["enum"] as? [String] == folders)
    }

    @Test func ownModelAcceptsABareFolderName() async throws {
        FakeServer.reply = (200, try chat("\"Taxes\"\n"))
        let verdict = try await OwnModelClassifier(server: ollama, session: FakeServer.session()).classify(.text("1040"), folders: folders)
        #expect(verdict == Verdict(folder: "Taxes", confidence: nil))
    }

    @Test func ownModelRejectsAnAnswerThatIsNotAFolder() async throws {
        FakeServer.reply = (200, try chat("I think this belongs in Taxes or Receipts."))
        await #expect(throws: PutawayError.self) {
            try await OwnModelClassifier(server: ollama, session: FakeServer.session()).classify(.text("1040"), folders: folders)
        }
    }

    @Test func aStoppedModelServerStopsThePlan() async throws {
        FakeServer.reply = nil
        await #expect(throws: ClassifierUnavailable.self) {
            try await OwnModelClassifier(server: ollama, session: FakeServer.session()).classify(.text("1040"), folders: folders)
        }
    }
}

@Test func engineFallsBackFromSubqToJevToApple() {
    #expect(resolve(nil, hasKey: { _ in true }) == .hosted(.subq))
    #expect(resolve(nil, hasKey: { $0 == .jev }) == .hosted(.jev))
    #expect(resolve(nil, hasKey: { _ in false }) == .apple)
    #expect(resolve(.apple, hasKey: { _ in true }) == .apple)
}

@Test func ownModelAddressIsCheckedWhenTyped() throws {
    #expect(throws: PutawayError.self) { try OwnModel(baseURL: "localhost:11434/v1", model: "qwen") }
    #expect(throws: PutawayError.self) { try OwnModel(baseURL: "http://localhost:1234/v1", model: " ") }
    let saved = try JSONEncoder().encode(EngineChoice.own(try OwnModel(baseURL: " http://studio.local:1234/v1", model: "qwen3-4b ")))
    #expect(try JSONDecoder().decode(EngineChoice.self, from: saved) == .own(try OwnModel(baseURL: "http://studio.local:1234/v1", model: "qwen3-4b")))
}
