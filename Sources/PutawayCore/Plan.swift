import Foundation

/// Below this confidence a file is never moved without the user's say.
public let autoMoveConfidence = 0.8

public struct Target: Codable, Sendable, Hashable {
    public var name: String
    public var url: URL
}

/// Size and modification time, used to tell whether a file changed since it was planned or moved.
public struct Stamp: Codable, Sendable, Equatable {
    public var size: Int
    public var modifiedMs: Int64

    public init(of url: URL) throws {
        // URL caches resource values per instance; a stale size would hide a change.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        size = values.fileSize ?? 0
        modifiedMs = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
    }
}

public enum Decision: Codable, Sendable, Equatable {
    case move(Target, confidence: Double)
    case ask(Target, confidence: Double?)
    /// The user chose this folder, from a suggestion or by hand.
    case approved(Target)
    case skip(String)

    /// Where the file goes if the plan is applied now.
    public var destination: Target? {
        switch self {
        case .move(let target, _), .approved(let target): target
        case .ask, .skip: nil
        }
    }
}

public struct PlanItem: Codable, Sendable, Equatable {
    public var file: URL
    public var stamp: Stamp
    public var decision: Decision
}

public struct Plan: Codable, Sendable {
    public var source: URL
    public var engine: String
    public var targets: [Target]
    public var items: [PlanItem]
}

public func decide(_ verdict: Verdict, content: FileContent, targets: [Target]) throws -> Decision {
    guard let target = targets.first(where: { $0.name == verdict.folder }) else {
        throw PutawayError(errorDescription: "The engine picked \"\(verdict.folder)\", which is not one of your folders")
    }
    if case .text = content, let confidence = verdict.confidence, confidence >= autoMoveConfidence {
        return .move(target, confidence: confidence)
    }
    return .ask(target, confidence: verdict.confidence)
}

/// The folders a file can go to: the subfolders of each parent, by name.
public func targets(in parents: [URL], excluding source: URL) throws -> [Target] {
    var found: [Target] = []
    for parent in parents {
        let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true, child.standardizedFileURL != source.standardizedFileURL else { continue }
            // Only apps make ".localized" folders, such as Parallels VMs. Finder hides the suffix, so the user never chose them.
            if child.lastPathComponent.hasSuffix(".localized") { continue }
            if let other = found.first(where: { $0.name == child.lastPathComponent }) {
                throw PutawayError(errorDescription: "Two folders share the name \"\(child.lastPathComponent)\": \(other.url.path) and \(child.path)")
            }
            found.append(Target(name: child.lastPathComponent, url: child))
        }
    }
    guard found.count >= 2 else {
        let names = parents.map(\.lastPathComponent).joined(separator: ", ")
        throw PutawayError(errorDescription: "Putaway needs at least 2 folders inside \(names) to sort files into, and found \(found.count). Make a few in Finder, such as Taxes, Receipts, and Work, or choose another folder.")
    }
    return found
}

let partialDownload: Set<String> = ["download", "crdownload", "part", "partial"]

/// The files a plan looks at: regular, visible files directly inside `source`, in Finder order.
public func plannableFiles(in source: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

public func makePlan(source: URL, targets: [Target], classifier: any Classifier, concurrency: Int, onItem: @escaping @Sendable (PlanItem) -> Void = { _ in }) async throws -> Plan {
    let files = try plannableFiles(in: source)
    let folders = targets.map(\.name)

    /// One planned file, and the classifier error if it was sent and failed.
    struct Planned: Sendable {
        var item: PlanItem
        var sent = false
        var error: (any Error)?
    }

    /// Nil when the file disappeared after it was listed. One bad file must not stop the plan,
    /// so read and classify failures become decisions; only an unusable engine throws.
    @Sendable func planOne(_ file: URL) async throws -> Planned? {
        try Task.checkCancellation()
        let stamp: Stamp
        do {
            stamp = try Stamp(of: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        func skip(_ reason: String) -> Planned { Planned(item: PlanItem(file: file, stamp: stamp, decision: .skip(reason))) }
        if isSensitive(file) { return skip("name suggests credentials; not read") }
        if partialDownload.contains(file.pathExtension.lowercased()) { return skip("still downloading") }
        // An unreadable file, such as a broken .docx, is filed by name, which never auto-moves.
        let text = (try? await extractText(file)) ?? nil
        try Task.checkCancellation()
        let content: FileContent = text.map { .text($0) } ?? .nameOnly(file.lastPathComponent)
        if let text, looksLikeSecret(text) { return skip("looks like it contains credentials; not sent") }
        do {
            let verdict = try await classifier.classify(content, folders: folders)
            return Planned(item: PlanItem(file: file, stamp: stamp, decision: try decide(verdict, content: content, targets: targets)), sent: true)
        } catch let error as ClassifierUnavailable {
            throw error
        } catch {
            try Task.checkCancellation()
            var planned = skip("could not pick a folder: \(error.localizedDescription)")
            planned.sent = true
            planned.error = error
            return planned
        }
    }

    var planned: [Planned] = []
    try await withThrowingTaskGroup(of: Planned?.self) { group in
        var next = files.makeIterator()
        for _ in 0..<concurrency {
            guard let file = next.next() else { break }
            group.addTask { try await planOne(file) }
        }
        while let result = try await group.next() {
            if let result {
                planned.append(result)
                onItem(result.item)
            }
            if let file = next.next() { group.addTask { try await planOne(file) } }
        }
    }
    // When every file sent to the engine failed, the engine is down; an all-skipped plan would hide that.
    let sent = planned.filter(\.sent)
    if !sent.isEmpty, sent.allSatisfy({ $0.error != nil }), let error = sent[0].error { throw error }
    let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
    return Plan(source: source, engine: classifier.name, targets: targets, items: planned.map(\.item).sorted { order[$0.file]! < order[$1.file]! })
}
