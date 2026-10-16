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
        case applied(moved: Int, kept: [Skipped])
        case undone(restored: Int, kept: [Skipped])
        case failed(String)
    }

    var phase = Phase.idle
    var plan: Plan?
    var rows: [Row] = []
    var engineName = ""

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
        let classifier = try? chooseClassifier(.auto)
        engineName = classifier?.name ?? ""
        hasSnapKey = classifier is SnapClassifier
    }

    func start(folder: URL? = nil) async {
        let folder = folder ?? source
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
            self.plan = plan
            rows = plan.items.map { Row(item: $0, choice: $0.decision.destination) }
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
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
            phase = .applied(moved: result.moved.count, kept: result.skipped)
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
        plan = nil
        rows = []
        phase = .idle
    }
}
