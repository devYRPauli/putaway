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

public struct PutawayError: LocalizedError {
    public var errorDescription: String?
}

/// The engine cannot classify anything, for example because the key was rejected. Stops the whole plan.
public struct ClassifierUnavailable: LocalizedError {
    public var errorDescription: String?
}

/// SubQ Snap decisions API. The answer set is closed: Snap must pick one of `folders`.
public struct SnapClassifier: Classifier {
    public let name = "SubQ Snap"
    let key: String
    let endpoint = URL(string: "https://api.subq.ai/v1/systemone")!

    public init(key: String) {
        self.key = key
    }

    struct Response: Decodable {
        struct Answer: Decodable {
            var choice: String
            var confidence: Double
        }
        var answers: [String: Answer]
    }

    public func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        let body: [String: Any] = [
            "model": "subq-snap-preview",
            "state": describe(content),
            "questions": [
                "folder": [
                    "type": "choice",
                    "instructions": "Which of my folders should this file be filed in?",
                    "criteria": Dictionary(uniqueKeysWithValues: folders.map { ($0, NSNull()) }),
                ],
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw ClassifierUnavailable(errorDescription: "SubQ rejected the API key (HTTP \(status)). Check the key and try again.")
        }
        guard status == 200 else {
            throw PutawayError(errorDescription: "SubQ returned HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let answer = try JSONDecoder().decode(Response.self, from: data).answers["folder"], folders.contains(answer.choice) else {
            throw PutawayError(errorDescription: "SubQ returned no valid folder choice")
        }
        return Verdict(folder: answer.choice, confidence: answer.confidence)
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
        let prompt = "\(describe(content))\n\nMy folders: \(folders.joined(separator: "; ")).\nWhich folder does this file belong in?"
        let response = try await session.respond(to: prompt, schema: schema)
        return Verdict(folder: try response.content.value(String.self), confidence: nil)
    }
}
