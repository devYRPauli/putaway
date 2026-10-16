import Foundation

/// Where the last plan and the undo batches live. The app and the CLI share it, so either can undo.
public let stateDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "putaway", directoryHint: .isDirectory)

public enum Engine: String, Sendable, CaseIterable {
    /// Snap when a SubQ key is set, otherwise the on-device model.
    case auto
    case snap
    case local
}

public func chooseClassifier(_ engine: Engine) throws -> any Classifier {
    if engine != .local, let key = try KeyStore.load() {
        return SnapClassifier(key: key)
    }
    if engine == .snap {
        throw PutawayError(errorDescription: "No SubQ key. Add one in Putaway, run `putaway key`, or set SUBQ_API_KEY.")
    }
    if let reason = OnDeviceClassifier.unavailableReason {
        throw PutawayError(errorDescription: engine == .auto ? "No SubQ key, and \(reason)" : reason)
    }
    return OnDeviceClassifier()
}

/// The on-device model serves one request at a time; Snap handles parallel calls.
public func concurrency(for classifier: any Classifier) -> Int {
    classifier is SnapClassifier ? 8 : 1
}
