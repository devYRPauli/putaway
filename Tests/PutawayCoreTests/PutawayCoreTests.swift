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

/// Picks `folder` with high confidence, or fails for any file whose text contains "fail".
/// Counts its calls so a test can prove a file was never sent.
final class CountingClassifier: Classifier, @unchecked Sendable {
    let name = "counting"
    let folder: String
    let failure: (any Error)?
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(folder: String, failure: (any Error)? = nil) {
        self.folder = folder
        self.failure = failure
    }

    func classify(_ content: FileContent, folders: [String]) async throws -> Verdict {
        lock.withLock { count += 1 }
        if let failure, case .text(let text) = content, text.contains("fail") { throw failure }
        return Verdict(folder: folder, confidence: 0.9)
    }
}

let taxes = Target(name: "Taxes", url: URL(filePath: "/tmp/Taxes"))

func skipReason(_ decision: Decision) -> String? {
    if case .skip(let reason) = decision { reason } else { nil }
}

/// An inbox with the given files and two empty folders, Taxes and Work, to sort into.
func inbox(_ files: [String: Data]) throws -> (inbox: URL, targets: [Target]) {
    let root = try tempDir()
    let inbox = root.appending(path: "Downloads")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    for (name, data) in files { try data.write(to: inbox.appending(path: name)) }
    for folder in ["Taxes", "Work"] {
        try FileManager.default.createDirectory(at: root.appending(path: "Docs/\(folder)"), withIntermediateDirectories: true)
    }
    return (inbox, try targets(in: [root.appending(path: "Docs")], excluding: inbox))
}

@Test func confidenceThresholdDecidesMoveOrAsk() throws {
    #expect(try decide(Verdict(folder: "Taxes", confidence: 0.80), content: .text("w2"), targets: [taxes]) == .move(taxes, confidence: 0.80))
    #expect(try decide(Verdict(folder: "Taxes", confidence: 0.79), content: .text("w2"), targets: [taxes]) == .ask(taxes, confidence: 0.79))
    #expect(try decide(Verdict(folder: "Taxes", confidence: nil), content: .text("w2"), targets: [taxes]) == .ask(taxes, confidence: nil))
    #expect(try decide(Verdict(folder: "Taxes", confidence: 0.99), content: .nameOnly("w2.zip"), targets: [taxes]) == .ask(taxes, confidence: 0.99))
    #expect(throws: PutawayError.self) { try decide(Verdict(folder: "Nope", confidence: 0.9), content: .text("w2"), targets: [taxes]) }
}

@Test func credentialNamesAreSensitive() {
    for name in [".env", "id_ed25519", "github-recovery-codes.txt", "server.pem", "Passwords.csv",
                 "prod.env", "Chrome Passwords.csv", "my passwords.docx", "Recovery Key.txt", "Backup-codes-yash.txt",
                 "1Password Emergency Kit.pdf", "credentials.json", "new_user_credentials.csv",
                 "client_secret_1234.apps.googleusercontent.com.json", "secrets.yaml", "accessKeys.csv", "rootkey.csv",
                 "server.key", "AuthKey_ABC123.p8", "putty.ppk", "release.keystore", "login.keychain-db", "seed phrase.txt"] {
        #expect(isSensitive(URL(filePath: "/x/\(name)")), "\(name)")
    }
    for name in ["paper.pdf", "invoice-2026.pdf", "keynote.key.pdf", "environment.md",
                 "Secret Santa list.pdf", "Victoria's Secret receipt.pdf", "Credentials evaluation.pdf", "Recovery plan.pdf",
                 "ACL recovery exercises.pdf", "Password reset instructions.pdf", "Time Machine backup.pdf", "keychain.pdf",
                 "turkey.jpg", "environment.yaml"] {
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

@Test func htmlGivesTitleThenVisibleText() async throws {
    let dir = try tempDir()
    let html = """
    <html><head><title>Mortgage &amp; loans</title><style>p { color: red }</style></head>
    <body><script>var x = "<b>hidden</b>";</script><nav>Main menu</nav><img src="http://127.0.0.1:9/x.png">
    <p>A mortgage is a <b>loan</b>.</p><!-- note --></body></html>
    """
    try write(html, to: dir.appending(path: "page.html"))
    #expect(try await extractText(dir.appending(path: "page.html")) == "Mortgage & loans\nA mortgage is a loan .")
}

@Test func excelWorkbookGivesItsCellText() async throws {
    let dir = try tempDir()
    let parts = dir.appending(path: "parts")
    try write(#"<sst><si><t>Region</t></si><si><t>Sales 2024</t></si></sst>"#, to: parts.appending(path: "xl/sharedStrings.xml"))
    let zip = Process()
    zip.executableURL = URL(filePath: "/usr/bin/zip")
    zip.currentDirectoryURL = parts
    zip.arguments = ["-qr", dir.appending(path: "q[1].xlsx").path, "xl"]
    try zip.run()
    zip.waitUntilExit()
    #expect(try await extractText(dir.appending(path: "q[1].xlsx")) == "Region Sales 2024")
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

@Test func keynoteDecksAreNotSecrets() throws {
    let dir = try tempDir()
    try write("PK\u{03}\u{04}rest", to: dir.appending(path: "deck.key"))
    try write("-----BEGIN RSA PRIVATE KEY-----", to: dir.appending(path: "server.key"))
    try write("", to: dir.appending(path: "x.key"))
    #expect(!isSensitive(dir.appending(path: "deck.key")))
    #expect(isSensitive(dir.appending(path: "server.key")))
    #expect(isSensitive(dir.appending(path: "x.key")))
}

@Test func secretLookingTextIsNeverSent() async throws {
    let (inbox, found) = try inbox([
        "my-project-1a2b3c.json": Data(#"{"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\nMIIE"}"#.utf8),
        "keys.csv": Data("id,secret\nAKIAIOSFODNN7EXAMPLE,abc".utf8),
        "w2.txt": Data("2026 W-2 wages".utf8),
    ])
    let classifier = CountingClassifier(folder: "Taxes")
    let plan = try await makePlan(source: inbox, targets: found, classifier: classifier, concurrency: 4)
    #expect(plan.items.map { skipReason($0.decision) } == ["looks like it contains credentials; not sent", "looks like it contains credentials; not sent", nil])
    #expect(classifier.calls == 1)
    #expect(!looksLikeSecret("-----BEGIN CERTIFICATE-----"))
    #expect(!looksLikeSecret("Keep your private key safe."))
}

@Test func oneBadFileDoesNotStopThePlan() async throws {
    let (inbox, found) = try inbox([
        "broken.docx": Data("PK\u{03}\u{04}truncated".utf8),
        "note.txt": Data("please fail this one".utf8),
        "w2.txt": Data("2026 W-2 wages".utf8),
    ])
    let plan = try await makePlan(source: inbox, targets: found, classifier: CountingClassifier(folder: "Taxes", failure: PutawayError(errorDescription: "HTTP 500")), concurrency: 4)
    #expect(plan.items.map(\.file.lastPathComponent) == ["broken.docx", "note.txt", "w2.txt"])
    #expect(plan.items[0].decision == .ask(found[0], confidence: 0.9))
    #expect(plan.items[1].decision == .skip("could not pick a folder: HTTP 500"))
    #expect(plan.items[2].decision.destination?.name == "Taxes")
}

@Test func aRejectedKeyStopsThePlan() async throws {
    let (inbox, found) = try inbox(["a.txt": Data("fail".utf8), "b.txt": Data("fail too".utf8)])
    await #expect(throws: ClassifierUnavailable.self) {
        try await makePlan(source: inbox, targets: found, classifier: CountingClassifier(folder: "Taxes", failure: ClassifierUnavailable(errorDescription: "SubQ rejected the key")), concurrency: 2)
    }
}

@Test func aPlanWhereEveryFileFailsThrows() async throws {
    let (inbox, found) = try inbox(["a.txt": Data("fail".utf8), "b.txt": Data("fail too".utf8)])
    await #expect(throws: PutawayError.self) {
        try await makePlan(source: inbox, targets: found, classifier: CountingClassifier(folder: "Taxes", failure: PutawayError(errorDescription: "offline")), concurrency: 2)
    }
}

@Test func applyKeepsGoingWhenOneMoveFails() throws {
    let root = try tempDir()
    let good = root.appending(path: "Work")
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    var items: [PlanItem] = []
    for (name, folder) in [("a.txt", root.appending(path: "Gone")), ("b.txt", good)] {
        let file = root.appending(path: "in/\(name)")
        try write(name, to: file)
        items.append(PlanItem(file: file, stamp: try Stamp(of: file), decision: .approved(Target(name: folder.lastPathComponent, url: folder))))
    }
    let plan = Plan(source: root.appending(path: "in"), engine: "fixed", targets: [], items: items)
    let applied = try History(directory: root.appending(path: "state")).apply(plan)
    #expect(applied.moved.map(\.to.lastPathComponent) == ["b.txt"])
    #expect(applied.skipped.map(\.file.lastPathComponent) == ["a.txt"])
}
