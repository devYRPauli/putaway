import Foundation
import PutawayCore

let usage = """
    putaway: file what's in a folder into the folders you already have.

    usage:
      putaway plan <folder> --into <dir> [--into <dir>...] [--json]
          Shows where each file would go. Moves nothing. Subfolders of each --into dir are the choices.
      putaway apply     Moves the files marked MOVE in the last plan.
      putaway undo      Puts the last applied batch back.
      putaway key subq|jev
          Reads a SubQ or Jev API key from stdin and stores it in the Keychain.
      putaway engine [apple | subq | jev | own <base-url> <model>]
          Shows or sets the engine. The app uses the same one. With none set, Putaway uses
          a SubQ key, then a Jev key, then Apple's on-device model.
          own: a server with the OpenAI chat API, such as Ollama at http://localhost:11434/v1.

    Your folder names and the first \(textLimit) characters of a file's text go to the engine you set.
    Apple's model keeps everything on the Mac. Files with credential-like names are never read.
    """

let planFile = stateDirectory.appending(path: "plan.json")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("putaway: \(message)\n".utf8))
    exit(1)
}

func row(_ item: PlanItem) -> String {
    let name = item.file.lastPathComponent
    switch item.decision {
    case .move(let target, let confidence): return "MOVE  \(name) -> \(target.name) (\(String(format: "%.2f", confidence)))"
    case .ask(let target, let confidence): return "ASK   \(name) -> \(target.name)? (\(confidence.map { String(format: "%.2f", $0) } ?? "no score"))"
    case .approved(let target): return "MOVE  \(name) -> \(target.name) (chosen)"
    case .skip(let reason): return "SKIP  \(name): \(reason)"
    }
}

func plan(_ args: [String]) async throws {
    var source: URL?
    var parents: [URL] = []
    var json = false
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--into":
            guard let value = rest.popFirst() else { fail("--into needs a value") }
            parents.append(URL(filePath: value, directoryHint: .isDirectory))
        case "--json": json = true
        default:
            if source != nil || arg.hasPrefix("-") { fail("unexpected argument \(arg)\n\n\(usage)") }
            source = URL(filePath: arg, directoryHint: .isDirectory)
        }
    }
    guard let source, !parents.isEmpty else { fail(usage) }
    let chosen = try chooseClassifier(EngineChoice.load())
    let started = Date()
    let result = try await makePlan(source: source, targets: targets(in: parents, excluding: source), classifier: chosen, concurrency: concurrency(for: chosen))
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    try data.write(to: planFile)
    if json {
        FileHandle.standardOutput.write(data)
        return
    }
    result.items.forEach { print(row($0)) }
    let moves = result.items.filter { $0.decision.destination != nil }.count
    let asks = result.items.filter { if case .ask = $0.decision { true } else { false } }.count
    print("\n\(result.items.count) files: \(moves) to move, \(asks) to check, \(result.items.count - moves - asks) skipped. \(result.engine), \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    if moves > 0 { print("Run `putaway apply` to move \(moves) files. `putaway undo` puts them back.") }
}

func apply() throws {
    guard let data = FileManager.default.contents(atPath: planFile.path) else { fail("no plan yet. Run `putaway plan` first.") }
    let result = try History(directory: stateDirectory).apply(JSONDecoder().decode(Plan.self, from: data))
    result.moved.forEach { print("moved  \($0.from.lastPathComponent) -> \($0.to.deletingLastPathComponent().lastPathComponent)") }
    result.skipped.forEach { print("kept   \($0.file.lastPathComponent): \($0.reason)") }
    print("\(result.moved.count) moved.")
    try FileManager.default.removeItem(at: planFile)
}

func engine(_ args: [String]) throws {
    let choice: EngineChoice
    switch (args.first, args.count) {
    case (nil, _):
        let saved = try EngineChoice.load()
        print("\(try chooseClassifier(saved).name)\(saved == nil ? " (automatic)" : "")")
        return
    case ("apple", 1): choice = .apple
    case ("own", 3): choice = .own(try OwnModel(baseURL: args[1], model: args[2]))
    case (let name?, 1):
        guard let provider = Provider(rawValue: name) else { fail(usage) }
        choice = .hosted(provider)
    default: fail(usage)
    }
    // Check first, so a choice that cannot run, such as SubQ with no key, is never saved.
    let classifier = try chooseClassifier(choice)
    try choice.save()
    print("Engine: \(classifier.name).")
}

func undo() throws {
    guard let result = try History(directory: stateDirectory).undo() else { fail("nothing to undo") }
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
        guard args.count == 2, let provider = Provider(rawValue: args[1]) else { fail(usage) }
        let key = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        if key.isEmpty { fail("no key on stdin") }
        try KeyStore.save(key, for: provider)
        print("Saved the \(provider.name) key to the Keychain.")
    case "engine": try engine(Array(args.dropFirst()))
    default: print(usage)
    }
} catch {
    fail(error.localizedDescription)
}
