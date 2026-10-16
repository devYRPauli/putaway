import Foundation
import Testing
@testable import PutawayCore

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "putaway-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Stands in for the network or model: always picks `folder` with `confidence`.
struct FixedClassifier: Classifier {
    let name = "fixed"
    var folder: String
    var confidence: Double?
    func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        Verdict(folder: folder, confidence: confidence)
    }
}

let taxes = Target(name: "Taxes", url: URL(filePath: "/tmp/Taxes"))

@Test func confidenceThresholdDecidesMoveOrAsk() {
    #expect(decide(Verdict(folder: "Taxes", confidence: 0.80), content: .text("w2"), targets: [taxes]) == .move(taxes, confidence: 0.80))
    #expect(decide(Verdict(folder: "Taxes", confidence: 0.79), content: .text("w2"), targets: [taxes]) == .ask(taxes, confidence: 0.79))
    #expect(decide(Verdict(folder: "Taxes", confidence: nil), content: .text("w2"), targets: [taxes]) == .ask(taxes, confidence: nil))
    #expect(decide(Verdict(folder: "Taxes", confidence: 0.99), content: .nameOnly("w2.zip"), targets: [taxes]) == .ask(taxes, confidence: 0.99))
}

@Test func credentialNamesAreSensitive() {
    for name in [".env", "id_ed25519", "github-recovery-codes.txt", "server.pem", "Passwords.csv"] {
        #expect(isSensitive(URL(filePath: "/x/\(name)")), "\(name)")
    }
    for name in ["paper.pdf", "invoice-2026.pdf", "keynote.key.pdf", "environment.md"] {
        #expect(!isSensitive(URL(filePath: "/x/\(name)")), "\(name)")
    }
}

@Test func textIsCappedAndBinariesHaveNoText() async throws {
    let dir = try tempDir()
    try write(String(repeating: "word ", count: 1000), to: dir.appending(path: "a.txt"))
    try Data([0, 1, 2, 3]).write(to: dir.appending(path: "b.dmg"))
    #expect(try await extractText(dir.appending(path: "a.txt"))?.count == 1000)
    #expect(try await extractText(dir.appending(path: "b.dmg")) == nil)
}

@Test func planSkipsCredentialsAndPartialDownloadsWithoutReadingThem() async throws {
    let root = try tempDir()
    let inbox = root.appending(path: "Downloads")
    try write("2026 W-2 wages", to: inbox.appending(path: "w2.txt"))
    try write("token=abc", to: inbox.appending(path: ".env.local"))
    try write("half", to: inbox.appending(path: "big.zip.crdownload"))
    try write("hunter2", to: inbox.appending(path: "recovery-codes.txt"))
    for folder in ["Taxes", "Work"] {
        try FileManager.default.createDirectory(at: root.appending(path: "Docs/\(folder)"), withIntermediateDirectories: true)
    }
    let found = try targets(in: [root.appending(path: "Docs")], excluding: inbox)
    let plan = try await makePlan(source: inbox, targets: found, classifier: FixedClassifier(folder: "Taxes", confidence: 0.9), concurrency: 4)
    let rows = plan.items.map { ($0.file.lastPathComponent, $0.decision) }
    #expect(rows.map(\.0) == ["big.zip.crdownload", "recovery-codes.txt", "w2.txt"])
    #expect(rows[0].1 == .skip("still downloading"))
    #expect(rows[1].1 == .skip("name suggests credentials; not read"))
    guard case .move(let target, 0.9) = rows[2].1 else { Issue.record("w2.txt not moved: \(rows[2].1)"); return }
    #expect(target.name == "Taxes")
}

@Test func duplicateFolderNamesAreRejected() throws {
    let root = try tempDir()
    for path in ["A/Taxes", "A/Work", "B/Taxes"] {
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }
    #expect(throws: PutawayError.self) { try targets(in: [root.appending(path: "A"), root.appending(path: "B")], excluding: root) }
}

func onePlan(_ file: URL, to folder: URL) throws -> Plan {
    let target = Target(name: folder.lastPathComponent, url: folder)
    return Plan(source: file.deletingLastPathComponent(), engine: "fixed", targets: [target], items: [PlanItem(file: file, stamp: try Stamp(of: file), decision: .move(target, confidence: 0.9))])
}

@Test func applyThenUndoRestoresAndNeverOverwrites() throws {
    let root = try tempDir()
    let file = root.appending(path: "in/report.pdf")
    let folder = root.appending(path: "Work")
    try write("new", to: file)
    try write("old", to: folder.appending(path: "report.pdf"))
    let history = History(directory: root.appending(path: "state"))

    let applied = try history.apply(try onePlan(file, to: folder))
    #expect(applied.moved.map(\.to.lastPathComponent) == ["report 2.pdf"])
    #expect(try String(contentsOf: folder.appending(path: "report.pdf"), encoding: .utf8) == "old")

    let undone = try #require(try history.undo())
    #expect(undone.restored.count == 1 && undone.skipped.isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    #expect(try history.undo() == nil)
}

@Test func undoKeepsAFileThatChangedAfterTheMove() throws {
    let root = try tempDir()
    let file = root.appending(path: "in/notes.txt")
    let folder = root.appending(path: "Work")
    try write("v1", to: file)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let history = History(directory: root.appending(path: "state"))
    _ = try history.apply(try onePlan(file, to: folder))
    try write("v2 edited", to: folder.appending(path: "notes.txt"))

    let undone = try #require(try history.undo())
    #expect(undone.restored.isEmpty)
    #expect(undone.skipped.map(\.reason) == ["changed since it was moved"])
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "notes.txt").path))
}

@Test func applySkipsAFileThatChangedSinceThePlan() throws {
    let root = try tempDir()
    let file = root.appending(path: "in/a.txt")
    try write("v1", to: file)
    let plan = try onePlan(file, to: root.appending(path: "Work"))
    try write("v2 longer", to: file)
    let applied = try History(directory: root.appending(path: "state")).apply(plan)
    #expect(applied.moved.isEmpty && applied.skipped.count == 1)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func applyMovesApprovedFilesAndLeavesAsksAlone() throws {
    let root = try tempDir()
    let folder = root.appending(path: "Work")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = Target(name: "Work", url: folder)
    var items: [PlanItem] = []
    for (name, decision) in [("chosen.txt", Decision.approved(target)), ("unsure.txt", .ask(target, confidence: 0.5))] {
        let file = root.appending(path: "in/\(name)")
        try write(name, to: file)
        items.append(PlanItem(file: file, stamp: try Stamp(of: file), decision: decision))
    }
    let plan = Plan(source: root.appending(path: "in"), engine: "fixed", targets: [target], items: items)
    let applied = try History(directory: root.appending(path: "state")).apply(plan)
    #expect(applied.moved.map(\.to.lastPathComponent) == ["chosen.txt"])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "in/unsure.txt").path))
}
