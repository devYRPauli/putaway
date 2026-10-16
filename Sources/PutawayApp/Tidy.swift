import Foundation
import Observation
import PutawayCore

/// One file in the review list. `choice` is where it goes; nil leaves it in place.
struct Row: Identifiable {
    let item: PlanItem
    var choice: Target?
    var id: URL { item.file }

    var suggestion: (target: Target, confidence: Double?)? {
        switch item.decision {
        case .move(let target, let confidence): (target, confidence)
        case .ask(let target, let confidence): (target, confidence)
        case .approved(let target): (target, nil)
        case .skip: nil
        }
    }
}

@MainActor @Observable
final class Tidy {
    enum Phase {
        case idle
        case planning(done: Int, total: Int)
        case review
        case applied(moved: [Move], kept: [Skipped])
        case undone(restored: Int, kept: [Skipped])
        case failed(String)
    }

    var phase = Phase.idle
    var plan: Plan?
    var rows: [Row] = []
    var engineName = ""
    /// Why no engine can run, shown instead of the Tidy button.
    var engineProblem: String?
    private var work: Task<Void, Never>?

    var source: URL {
        didSet { UserDefaults.standard.set(source.path, forKey: "source") }
    }
    var parents: [URL] {
        didSet { UserDefaults.standard.set(parents.map(\.path), forKey: "parents") }
    }

    init() {
        let fm = FileManager.default
        source = UserDefaults.standard.string(forKey: "source").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        parents = (UserDefaults.standard.stringArray(forKey: "parents") ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
        if parents.isEmpty { parents = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0]] }
        refreshEngine()
    }

    private(set) var hasSnapKey = false

    /// Empty `engineName` means no engine can run: no SubQ key and no on-device model.
    func refreshEngine() {
        do {
            let classifier = try chooseClassifier(.auto)
            engineName = classifier.name
            hasSnapKey = classifier is SnapClassifier
            engineProblem = nil
        } catch {
            engineName = ""
            hasSnapKey = false
            engineProblem = error.localizedDescription
        }
    }

    func start(folder: URL? = nil) {
        work?.cancel()
        work = Task { await run(folder ?? source) }
    }

    private func run(_ folder: URL) async {
        do {
            let classifier = try chooseClassifier(.auto)
            engineName = classifier.name
            let found = try targets(in: parents, excluding: folder)
            let total = try plannableFiles(in: folder).count
            phase = .planning(done: 0, total: total)
            let plan = try await makePlan(source: folder, targets: found, classifier: classifier, concurrency: concurrency(for: classifier)) { _ in
                Task { @MainActor in
                    if case .planning(let done, let total) = self.phase { self.phase = .planning(done: done + 1, total: total) }
                }
            }
            if Task.isCancelled { return }
            self.plan = plan
            rows = plan.items.map { Row(item: $0, choice: $0.decision.destination) }
            phase = .review
        } catch {
            // cancel() has already reset the window.
            if Task.isCancelled { return }
            phase = .failed(describe(error))
        }
    }

    /// Folder access refused in Privacy & Security reads as a bare "no permission"; say where to fix it.
    private func describe(_ error: any Error) -> String {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError else { return error.localizedDescription }
        let name = (error.userInfo[NSFilePathErrorKey] as? String).map { URL(filePath: $0).lastPathComponent } ?? "this folder"
        return "Putaway is not allowed to open \(name). Allow it in System Settings > Privacy & Security > Files & Folders, then try again."
    }

    /// "Your call" rows the user has not picked a folder for yet.
    var openSuggestions: [Row] {
        rows.filter { row in
            if case .ask = row.item.decision { row.choice == nil } else { false }
        }
    }

    func acceptAllSuggestions() {
        for row in openSuggestions {
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].choice = row.suggestion?.target }
        }
    }

    var chosenCount: Int { rows.filter { $0.choice != nil }.count }

    func apply() {
        guard var plan else { return }
        plan.items = rows.map { row in
            var item = row.item
            if row.choice != row.item.decision.destination {
                item.decision = row.choice.map { .approved($0) } ?? .skip("left in place")
            }
            return item
        }
        do {
            let result = try History(directory: stateDirectory).apply(plan)
            phase = .applied(moved: result.moved, kept: result.skipped)
            self.plan = nil
            rows = []
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func undo() {
        do {
            guard let result = try History(directory: stateDirectory).undo() else {
                phase = .failed("Nothing to undo.")
                return
            }
            phase = .undone(restored: result.restored.count, kept: result.skipped)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        plan = nil
        rows = []
        phase = .idle
    }
}
