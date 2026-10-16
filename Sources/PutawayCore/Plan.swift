import Foundation

/// Below this confidence a file is never moved without the user's say.
public let autoMoveConfidence = 0.8

public struct Target: Codable, Sendable, Equatable {
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
    case skip(String)
}

public struct PlanItem: Codable, Sendable, Equatable {
    public var file: URL
    public var stamp: Stamp
    public var decision: Decision
}

public struct Plan: Codable, Sendable {
    public var engine: String
    public var items: [PlanItem]
}

public func decide(_ verdict: Verdict, content: FileContent, targets: [Target]) -> Decision {
    let target = targets.first { $0.name == verdict.folder }!
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
            if let other = found.first(where: { $0.name == child.lastPathComponent }) {
                throw PutawayError(errorDescription: "Two folders share the name \"\(child.lastPathComponent)\": \(other.url.path) and \(child.path)")
            }
            found.append(Target(name: child.lastPathComponent, url: child))
        }
    }
    guard found.count >= 2 else {
        throw PutawayError(errorDescription: "Need at least 2 folders to sort into, found \(found.count)")
    }
    return found
}

let partialDownload: Set<String> = ["download", "crdownload", "part", "partial"]

public func makePlan(source: URL, targets: [Target], classifier: any Classifier, concurrency: Int) async throws -> Plan {
    let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    let folders = targets.map(\.name)

    @Sendable func planOne(_ file: URL) async throws -> PlanItem {
        let stamp = try Stamp(of: file)
        if isSensitive(file) {
            return PlanItem(file: file, stamp: stamp, decision: .skip("name suggests credentials; not read"))
        }
        if partialDownload.contains(file.pathExtension.lowercased()) {
            return PlanItem(file: file, stamp: stamp, decision: .skip("still downloading"))
        }
        let content: FileContent = try await extractText(file).map { .text($0) } ?? .nameOnly(file.lastPathComponent)
        let verdict = try await classifier.classify(content, folders: folders)
        return PlanItem(file: file, stamp: stamp, decision: decide(verdict, content: content, targets: targets))
    }

    var items: [PlanItem] = []
    try await withThrowingTaskGroup(of: PlanItem.self) { group in
        var next = files.makeIterator()
        for _ in 0..<concurrency {
            guard let file = next.next() else { break }
            group.addTask { try await planOne(file) }
        }
        while let item = try await group.next() {
            items.append(item)
            if let file = next.next() { group.addTask { try await planOne(file) } }
        }
    }
    let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
    return Plan(engine: classifier.name, items: items.sorted { order[$0.file]! < order[$1.file]! })
}
