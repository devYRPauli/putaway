import Foundation

/// Where the last plan and the undo batches live. The app and the CLI share it, so either can undo.
public let stateDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "putaway", directoryHint: .isDirectory)

/// The app's preferences domain. CFPreferences reaches it from the CLI too, so both use the same engine;
/// UserDefaults refuses the app's own bundle id as a suite name.
let preferencesDomain = "io.github.devyrpauli.putaway"

/// A model server the user runs, such as Ollama or LM Studio, that speaks the OpenAI chat API.
public struct OwnModel: Codable, Sendable, Equatable {
    /// The API base, such as http://localhost:11434/v1. Requests go to `baseURL/chat/completions`.
    public var baseURL: URL
    public var model: String

    /// Parses what the user typed. Throws instead of saving a server Putaway cannot call.
    public init(baseURL: String, model: String) throws {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme), url.host() != nil else {
            throw PutawayError(errorDescription: "\"\(baseURL)\" is not a server address. Use one like http://localhost:11434/v1.")
        }
        guard !model.isEmpty else { throw PutawayError(errorDescription: "Name the model to use, such as qwen2.5:7b-instruct.") }
        self.baseURL = url
        self.model = model
    }
}

/// The engine the user chose. With no choice saved, Putaway uses a SubQ key, then a Jev key, then Apple's model.
public enum EngineChoice: Codable, Sendable, Equatable {
    case apple
    case hosted(Provider)
    case own(OwnModel)

    static let key = "engine"

    public static func load() throws -> EngineChoice? {
        guard let data = CFPreferencesCopyAppValue(key as CFString, preferencesDomain as CFString) as? Data else { return nil }
        return try JSONDecoder().decode(EngineChoice.self, from: data)
    }

    public func save() throws {
        CFPreferencesSetAppValue(Self.key as CFString, try JSONEncoder().encode(self) as CFData, preferencesDomain as CFString)
        guard CFPreferencesAppSynchronize(preferencesDomain as CFString) else { throw PutawayError(errorDescription: "Could not save the engine choice.") }
    }
}

/// What `chooseClassifier` resolves to, before any key is read from the Keychain or any model is checked.
public func resolve(_ choice: EngineChoice?, hasKey: (Provider) throws -> Bool) rethrows -> EngineChoice {
    if let choice { return choice }
    return try Provider.allCases.first(where: hasKey).map { .hosted($0) } ?? .apple
}

public func chooseClassifier(_ choice: EngineChoice?) throws -> any Classifier {
    switch try resolve(choice, hasKey: { try KeyStore.load($0) != nil }) {
    case .hosted(let provider):
        guard let key = try KeyStore.load(provider) else {
            throw PutawayError(errorDescription: "No \(provider.name) key. Add one in Putaway, run `putaway key \(provider.rawValue)`, or set \(provider.environmentKey).")
        }
        return DecisionClassifier(provider: provider, key: key)
    case .own(let server):
        return OwnModelClassifier(server: server)
    case .apple:
        if let reason = OnDeviceClassifier.unavailableReason {
            throw PutawayError(errorDescription: choice == nil ? "\(reason) Or add a SubQ or Jev key, or use your own model." : reason)
        }
        return OnDeviceClassifier()
    }
}

/// Apple's model and a local server serve one request at a time; the hosted APIs handle parallel calls.
public func concurrency(for classifier: any Classifier) -> Int {
    classifier is DecisionClassifier ? 8 : 1
}
