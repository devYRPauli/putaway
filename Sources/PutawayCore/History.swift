import Foundation

public struct Move: Codable, Sendable, Equatable {
    public var from: URL
    public var to: URL
    public var stamp: Stamp
}

public struct Skipped: Sendable, Equatable {
    public var file: URL
    public var reason: String
}

/// Every apply writes a batch file, one line per move, so the latest batch can be undone.
/// A move is recorded before it happens; undo skips records whose move never landed.
public struct History: Sendable {
    let batches: URL

    public init(directory: URL) {
        batches = directory.appending(path: "batches", directoryHint: .isDirectory)
    }

    public func apply(_ plan: Plan) throws -> (moved: [Move], skipped: [Skipped]) {
        let fm = FileManager.default
        try fm.createDirectory(at: batches, withIntermediateDirectories: true)
        let batch = batches.appending(path: String(format: "%015.0f.jsonl", Date().timeIntervalSince1970 * 1000))
        fm.createFile(atPath: batch.path, contents: nil)
        let log = try FileHandle(forWritingTo: batch)
        defer { try? log.close() }

        var moved: [Move] = []
        var skipped: [Skipped] = []
        for item in plan.items {
            guard let target = item.decision.destination else { continue }
            guard fm.fileExists(atPath: item.file.path), try Stamp(of: item.file) == item.stamp else {
                skipped.append(Skipped(file: item.file, reason: "missing or changed since the plan"))
                continue
            }
            let move = Move(from: item.file, to: freeName(in: target.url, for: item.file.lastPathComponent), stamp: item.stamp)
            try log.write(contentsOf: JSONEncoder().encode(move) + Data("\n".utf8))
            do {
                try fm.moveItem(at: move.from, to: move.to)
                moved.append(move)
            } catch {
                // The batch keeps the record; undo skips it because the file never arrived.
                skipped.append(Skipped(file: item.file, reason: error.localizedDescription))
            }
        }
        if moved.isEmpty { try fm.removeItem(at: batch) }
        return (moved, skipped)
    }

    /// Reverses the latest batch. Returns nil when there is nothing to undo.
    public func undo() throws -> (restored: [Move], skipped: [Skipped])? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: batches.path) else { return nil }
        let pending = try fm.contentsOfDirectory(at: batches, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let batch = pending.last else { return nil }

        let moves = try String(contentsOf: batch, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Move.self, from: Data($0.utf8)) }
        var restored: [Move] = []
        var skipped: [Skipped] = []
        for move in moves.reversed() {
            if !fm.fileExists(atPath: move.to.path) {
                skipped.append(Skipped(file: move.to, reason: "no longer there"))
            } else if fm.fileExists(atPath: move.from.path) {
                skipped.append(Skipped(file: move.to, reason: "another file now has its old name"))
            } else if try Stamp(of: move.to) != move.stamp {
                skipped.append(Skipped(file: move.to, reason: "changed since it was moved"))
            } else {
                try fm.moveItem(at: move.to, to: move.from)
                restored.append(move)
            }
        }
        try fm.moveItem(at: batch, to: batch.appendingPathExtension("undone"))
        return (restored, skipped)
    }
}

/// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`, ... if that name is taken. Never overwrites.
func freeName(in folder: URL, for name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = folder.appending(path: name)
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
    }
    return candidate
}
