import Foundation
import PutawayCore

let usage = """
    putaway: file what's in a folder into the folders you already have.

    usage:
      putaway plan <folder> --into <dir> [--into <dir>...] [--engine auto|snap|local] [--json]
          Shows where each file would go. Moves nothing. Subfolders of each --into dir are the choices.
      putaway apply     Moves the files marked MOVE in the last plan.
      putaway undo      Puts the last applied batch back.
      putaway key       Reads a SubQ API key from stdin and stores it in the Keychain.

    Only the first \(textLimit) characters of a file's text leave the Mac, and only with the snap engine.
    Files with credential-like names are never read.
    """

let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "putaway")
let planFile = state.appending(path: "plan.json")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("putaway: \(message)\n".utf8))
    exit(1)
}

func classifier(_ engine: String) throws -> any Classifier {
    switch engine {
    case "snap", "auto":
        if let key = try KeyStore.load() { return SnapClassifier(key: key) }
        if engine == "snap" { fail("no SubQ key. Run `putaway key` or set SUBQ_API_KEY.") }
        if let reason = OnDeviceClassifier.unavailableReason { fail("no SubQ key, and \(reason)") }
        return OnDeviceClassifier()
    case "local":
        if let reason = OnDeviceClassifier.unavailableReason { fail(reason) }
        return OnDeviceClassifier()
    default:
        fail("unknown engine \"\(engine)\"")
    }
}

func row(_ item: PlanItem) -> String {
    let name = item.file.lastPathComponent
    switch item.decision {
    case .move(let target, let confidence): return "MOVE  \(name) -> \(target.name) (\(String(format: "%.2f", confidence)))"
    case .ask(let target, let confidence): return "ASK   \(name) -> \(target.name)? (\(confidence.map { String(format: "%.2f", $0) } ?? "no score"))"
    case .skip(let reason): return "SKIP  \(name): \(reason)"
    }
}

func plan(_ args: [String]) async throws {
    var source: URL?
    var parents: [URL] = []
    var engine = "auto"
    var json = false
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--into", "--engine":
            guard let value = rest.popFirst() else { fail("\(arg) needs a value") }
            if arg == "--into" { parents.append(URL(filePath: value, directoryHint: .isDirectory)) } else { engine = value }
        case "--json": json = true
        default:
            if source != nil || arg.hasPrefix("-") { fail("unexpected argument \(arg)\n\n\(usage)") }
            source = URL(filePath: arg, directoryHint: .isDirectory)
        }
    }
    guard let source, !parents.isEmpty else { fail(usage) }
    let chosen = try classifier(engine)
    let started = Date()
    // The on-device model serves one request at a time; Snap handles parallel calls.
    let result = try await makePlan(source: source, targets: targets(in: parents, excluding: source), classifier: chosen, concurrency: chosen is SnapClassifier ? 8 : 1)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    try data.write(to: planFile)
    if json {
        FileHandle.standardOutput.write(data)
        return
    }
    result.items.forEach { print(row($0)) }
    let moves = result.items.filter { if case .move = $0.decision { true } else { false } }.count
    let asks = result.items.filter { if case .ask = $0.decision { true } else { false } }.count
    print("\n\(result.items.count) files: \(moves) to move, \(asks) to check, \(result.items.count - moves - asks) skipped. \(result.engine), \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    if moves > 0 { print("Run `putaway apply` to move \(moves) files. `putaway undo` puts them back.") }
}

func apply() throws {
    guard let data = FileManager.default.contents(atPath: planFile.path) else { fail("no plan yet. Run `putaway plan` first.") }
    let result = try History(directory: state).apply(JSONDecoder().decode(Plan.self, from: data))
    result.moved.forEach { print("moved  \($0.from.lastPathComponent) -> \($0.to.deletingLastPathComponent().lastPathComponent)") }
    result.skipped.forEach { print("kept   \($0.file.lastPathComponent): \($0.reason)") }
    print("\(result.moved.count) moved.")
    try FileManager.default.removeItem(at: planFile)
}

func undo() throws {
    guard let result = try History(directory: state).undo() else { fail("nothing to undo") }
    result.skipped.forEach { print("kept   \($0.file.lastPathComponent): \($0.reason)") }
    print("\(result.restored.count) files put back.")
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "plan": try await plan(Array(args.dropFirst()))
    case "apply": try apply()
    case "undo": try undo()
    case "key":
        let key = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        if key.isEmpty { fail("no key on stdin") }
        try KeyStore.save(key)
        print("Saved the SubQ key to the Keychain.")
    default: print(usage)
    }
} catch {
    fail(error.localizedDescription)
}
