import Foundation
import FoundationModels

/// What a classifier knows about one file. Files without text are described by name only.
public enum FileContent: Sendable, Equatable {
    case text(String)
    case nameOnly(String)
}

public struct Verdict: Sendable, Equatable {
    public var folder: String
    /// The engine's probability for `folder`, or nil when the engine gives none.
    public var confidence: Double?

    public init(folder: String, confidence: Double?) {
        self.folder = folder
        self.confidence = confidence
    }
}

public protocol Classifier: Sendable {
    var name: String { get }
    func classify(_ content: FileContent, folders: [String]) async throws -> Verdict
}

private func describe(_ content: FileContent) -> String {
    switch content {
    case .text(let text): "A file from my computer. Text from its start:\n\n\(text)"
    case .nameOnly(let name): "A file from my computer named \"\(name)\". It has no readable text."
    }
}

/// The prompt for chat models, which see the folder list in the text.
private func question(_ content: FileContent, folders: [String]) -> String {
    "\(describe(content))\n\nMy folders: \(folders.joined(separator: "; ")).\nWhich folder does this file belong in?"
}

public struct PutawayError: LocalizedError {
    public var errorDescription: String?
}

/// The engine cannot classify anything, for example because the key was rejected. Stops the whole plan.
public struct ClassifierUnavailable: LocalizedError {
    public var errorDescription: String?
}

/// A hosted System One decisions API. SubQ and TypeSafe's Jev take the same request and return the same answer.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case subq
    case jev

    public var name: String {
        switch self {
        case .subq: "SubQ Snap"
        case .jev: "Jev"
        }
    }

    var endpoint: URL {
        switch self {
        case .subq: URL(string: "https://api.subq.ai/v1/systemone")!
        case .jev: URL(string: "https://api.typesafe.ai/v1/systemone")!
        }
    }

    var model: String {
        switch self {
        case .subq: "subq-snap-preview"
        case .jev: "jev-latest"
        }
    }

    public var environmentKey: String {
        switch self {
        case .subq: "SUBQ_API_KEY"
        case .jev: "TYPESAFE_API_KEY"
        }
    }
}

func post(_ url: URL, bearer: String?, body: [String: Any], session: URLSession) async throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
}

/// The answer set is closed: the API must pick one of `folders`.
public struct DecisionClassifier: Classifier {
    public let provider: Provider
    let key: String
    let session: URLSession
    public var name: String { provider.name }

    public init(provider: Provider, key: String, session: URLSession = .shared) {
        self.provider = provider
        self.key = key
        self.session = session
    }

    struct Response: Decodable {
        struct Answer: Decodable {
            var choice: String
            /// Jev's `confidence` measures how peaked the distribution is, not how likely `choice` is, so use this.
            var probabilities: [String: Double]
        }
        var answers: [String: Answer]
    }

    public func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        let body: [String: Any] = [
            "model": provider.model,
            "state": describe(content),
            "questions": [
                "folder": [
                    "type": "choice",
                    "instructions": "Which of my folders should this file be filed in?",
                    "criteria": Dictionary(uniqueKeysWithValues: folders.map { ($0, NSNull()) }),
                ],
            ],
        ]
        let (data, status) = try await post(provider.endpoint, bearer: key, body: body, session: session)
        switch status {
        case 200: break
        case 401, 403:
            throw ClassifierUnavailable(errorDescription: "\(provider.name) rejected the API key (HTTP \(status)). Check the key and try again.")
        case 402:
            throw ClassifierUnavailable(errorDescription: "\(provider.name) says the account is out of credits (HTTP 402).")
        default:
            throw PutawayError(errorDescription: "\(provider.name) returned HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let answer = try JSONDecoder().decode(Response.self, from: data).answers["folder"], folders.contains(answer.choice),
              let probability = answer.probabilities[answer.choice] else {
            throw PutawayError(errorDescription: "\(provider.name) returned no valid folder choice")
        }
        return Verdict(folder: answer.choice, confidence: probability)
    }
}

/// A model server the user runs. Small local models give no usable probability, so every pick is a suggestion.
public struct OwnModelClassifier: Classifier {
    public let server: OwnModel
    let session: URLSession
    public var name: String { "\(server.model) at \(server.baseURL.host() ?? server.baseURL.absoluteString)" }

    public init(server: OwnModel, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    struct Answer: Decodable { var folder: String }

    public func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        let body: [String: Any] = [
            "model": server.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "You file documents. Pick the folder the file belongs in. Reply only with JSON: {\"folder\": \"<one of my folders>\"}."],
                ["role": "user", "content": question(content, folders: folders)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "folder",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": ["folder": ["type": "string", "enum": folders]],
                        "required": ["folder"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let url = server.baseURL.appending(path: "chat/completions")
        let data: Data, status: Int
        do {
            (data, status) = try await post(url, bearer: nil, body: body, session: session)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code) {
            throw ClassifierUnavailable(errorDescription: "Cannot reach \(server.baseURL.absoluteString). Is your model server running?")
        }
        let reply = String(decoding: data.prefix(300), as: UTF8.self)
        switch status {
        case 200: break
        // Ollama and LM Studio answer 404 for an unknown model as well as a wrong path.
        case 404: throw ClassifierUnavailable(errorDescription: "\(url.absoluteString) answered HTTP 404. Check the address and the model name. \(reply)")
        default: throw PutawayError(errorDescription: "Your model server returned HTTP \(status): \(reply)")
        }
        let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        // Servers that ignore response_format may answer with the bare folder name.
        let folder = (try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)))?.folder
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.")))
        guard folders.contains(folder) else {
            throw PutawayError(errorDescription: "Your model answered \"\(text.prefix(80))\", which is not one of your folders")
        }
        return Verdict(folder: folder, confidence: nil)
    }
}

/// Apple's on-device model. It returns a constrained choice but no probability.
public struct OnDeviceClassifier: Classifier {
    public let name = "Apple on-device model"

    public init() {}

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off. Turn it on in System Settings > Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model. Try again later."
        case .unavailable(let reason): "Apple Intelligence is unavailable: \(reason)."
        }
    }

    public func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Folder", anyOf: folders), dependencies: [])
        let session = LanguageModelSession(instructions: "You file documents. Pick the folder the file belongs in.")
        // Apple's guardrails refuse some ordinary government forms, such as a 1040, and call them "unsafe".
        let refused = PutawayError(errorDescription: "Apple's on-device model would not read this file")
        let response: LanguageModelSession.Response<GeneratedContent>
        do {
            response = try await session.respond(to: question(content, folders: folders), schema: schema)
        } catch {
            // macOS 27.0 still throws GenerationError, which it deprecates for LanguageModelError.
            switch error {
            case LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal:
                throw refused
            default:
                if #available(macOS 27, *) {
                    switch error {
                    case LanguageModelError.guardrailViolation, LanguageModelError.refusal: throw refused
                    default: break
                    }
                }
                throw error
            }
        }
        return Verdict(folder: try response.content.value(String.self), confidence: nil)
    }
}
