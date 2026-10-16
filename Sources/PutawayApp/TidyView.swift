import AppKit
import PutawayCore
import SwiftUI

struct TidyView: View {
    @Bindable var tidy: Tidy
    @State private var showEngine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 440)
        .sheet(isPresented: $showEngine) { EngineSheet(tidy: tidy) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Tidy").font(.title2.bold())
                FolderButton(url: tidy.plan?.source ?? tidy.source, multiple: false) { tidy.source = $0[0] }
                Text("into folders in").font(.title2.bold())
                FolderButton(url: tidy.parents[0], label: tidy.parents.map(\.lastPathComponent).joined(separator: ", "), multiple: true) { tidy.parents = $0 }
            }
            HStack(spacing: 6) {
                switch tidy.engine {
                case let hosted as DecisionClassifier:
                    Label("Using \(hosted.name). It sees your folder names and the first 1,000 characters of each file's text.", systemImage: "lock.shield")
                case let own as OwnModelClassifier:
                    Label("Using \(own.name). It suggests folders; you confirm each one. Text goes only to that server.", systemImage: "server.rack")
                case let engine?:
                    Label("Using \(engine.name). It suggests folders; you confirm each one. Nothing leaves your Mac.", systemImage: "desktopcomputer")
                case nil:
                    Label(tidy.engineProblem ?? "Choose an engine to start.", systemImage: "key")
                }
                Button("Change engine") { showEngine = true }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch tidy.phase {
        case .idle:
            VStack(spacing: 12) {
                Button("Tidy \(tidy.source.lastPathComponent)") { tidy.start() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tidy.engine == nil)
                Text("Nothing moves until you confirm. Undo is always available.")
                    .foregroundStyle(.secondary)
            }
        case .planning(let done, let total):
            VStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 280)
                Text("Reading files: \(done) of \(total)").foregroundStyle(.secondary)
                Button("Cancel") { tidy.cancel() }.keyboardShortcut(.cancelAction)
            }
        case .review:
            review
        case .applied(let moved, let kept):
            Outcome(title: "Moved \(moved.count) \(moved.count == 1 ? "file" : "files").", moved: moved, kept: kept) {
                Button("Undo") { tidy.undo() }
                Button("Done") { tidy.cancel() }.keyboardShortcut(.defaultAction)
            }
        case .undone(let restored, let kept):
            Outcome(title: "Put \(restored) \(restored == 1 ? "file" : "files") back.", kept: kept) {
                Button("Done") { tidy.cancel() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Outcome(title: message, kept: []) {
                Button("OK") { tidy.cancel() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var review: some View {
        VStack(spacing: 0) {
            List {
                section("Ready to move", rows: { if case .move = $0.item.decision { true } else { false } })
                section("Your call", rows: { if case .ask = $0.item.decision { true } else { false } })
                let skipped = tidy.rows.filter { if case .skip = $0.item.decision { true } else { false } }
                if !skipped.isEmpty {
                    Section("Not touched (\(skipped.count))") {
                        ForEach(skipped) { row in
                            HStack {
                                FileLabel(url: row.item.file)
                                Spacer()
                                if case .skip(let reason) = row.item.decision { Text(reason).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(tidy.rows.count) files read").foregroundStyle(.secondary)
                Spacer()
                let open = tidy.openSuggestions.count
                if open > 0 {
                    Button("Accept \(open) \(open == 1 ? "suggestion" : "suggestions")") { tidy.acceptAllSuggestions() }
                }
                Button("Cancel") { tidy.cancel() }.keyboardShortcut(.cancelAction)
                Button("Move \(tidy.chosenCount) \(tidy.chosenCount == 1 ? "file" : "files")") { tidy.apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tidy.chosenCount == 0)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows include: @escaping (Row) -> Bool) -> some View {
        let rows = tidy.rows.filter(include)
        if !rows.isEmpty {
            Section("\(title) (\(rows.count))") {
                ForEach(rows) { row in
                    RowView(row: binding(for: row), targets: tidy.plan?.targets ?? [])
                }
            }
        }
    }

    /// Binds by file, not index: apply empties `rows` while the list may still be rendering.
    private func binding(for row: Row) -> Binding<Row> {
        Binding(
            get: { tidy.rows.first { $0.id == row.id } ?? row },
            set: { new in
                if let i = tidy.rows.firstIndex(where: { $0.id == row.id }) { tidy.rows[i] = new }
            }
        )
    }
}

struct RowView: View {
    @Binding var row: Row
    let targets: [Target]

    var body: some View {
        HStack {
            FileLabel(url: row.item.file)
            Spacer()
            if let suggestion = row.suggestion, row.choice == nil {
                Button("\(suggestion.target.name)?") { row.choice = suggestion.target }
                    .buttonStyle(.link)
                    .help("Suggested folder. Click to accept.")
                    .accessibilityLabel("Accept suggestion: \(suggestion.target.name)")
            }
            Picker("", selection: $row.choice) {
                Text("Leave here").tag(Target?.none)
                Divider()
                ForEach(targets, id: \.self) { Text($0.name).tag(Target?.some($0)) }
            }
            .labelsHidden()
            .accessibilityLabel("Folder for \(row.item.file.lastPathComponent)")
            .frame(width: 200)
            Text(row.suggestion?.confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .help("How sure the model is about its suggestion")
        }
    }
}

struct FileLabel: View {
    let url: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

struct FolderButton: View {
    let url: URL
    var label: String?
    let multiple: Bool
    let onPick: ([URL]) -> Void

    var body: some View {
        Button(label ?? url.lastPathComponent) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = multiple
            panel.directoryURL = url
            panel.prompt = "Choose"
            if panel.runModal() == .OK, !panel.urls.isEmpty { onPick(panel.urls) }
        }
        .font(.title2.bold())
        .buttonStyle(.link)
        .help(multiple ? "The subfolders of these folders are where files can go" : "The folder to tidy")
    }
}

struct Outcome<Actions: View>: View {
    let title: String
    var moved: [Move] = []
    let kept: [Skipped]
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if !moved.isEmpty {
                List(moved, id: \.to) { move in
                    HStack {
                        FileLabel(url: move.to)
                        Spacer()
                        Text(move.to.deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 260)
            }
            if !kept.isEmpty {
                Text("Left in place: " + kept.map { "\($0.file.lastPathComponent) (\($0.reason))" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            }
            HStack { actions }
        }
        .padding()
    }
}

struct EngineSheet: View {
    enum Kind: Hashable {
        case apple, subq, jev, own
    }

    let tidy: Tidy
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    @State private var key = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var error: String?

    init(tidy: Tidy) {
        self.tidy = tidy
        var kind = Kind.apple
        switch tidy.engine {
        case let hosted as DecisionClassifier: kind = hosted.provider == .subq ? .subq : .jev
        case let own as OwnModelClassifier:
            kind = .own
            _baseURL = State(initialValue: own.server.baseURL.absoluteString)
            _model = State(initialValue: own.server.model)
        default: break
        }
        _kind = State(initialValue: kind)
    }

    private var provider: Provider? {
        switch kind {
        case .subq: .subq
        case .jev: .jev
        case .apple, .own: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine").font(.headline)
            Picker("Engine", selection: $kind) {
                Text("Apple Intelligence on this Mac").tag(Kind.apple)
                Text("Your own model").tag(Kind.own)
                Text("SubQ Snap, with your API key").tag(Kind.subq)
                Text("Jev, with your API key").tag(Kind.jev)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Group {
                switch kind {
                case .apple:
                    Text("Nothing leaves your Mac. Apple's model suggests a folder for each file, and you confirm each one. It needs Apple Intelligence turned on.")
                case .subq, .jev:
                    Text("Putaway sends your folder names and the first 1,000 characters of each file's text to \(provider!.name). Files it is sure about are ready to move. Files with names like passwords or recovery codes are never read, and text that looks like a key or token is never sent. The key is stored in your Keychain.")
                case .own:
                    Text("Any server with the OpenAI chat API, such as Ollama, LM Studio, llama.cpp, or mlx_lm. Text goes only to that server. It suggests a folder for each file, and you confirm each one.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let provider {
                SecureField(((try? KeyStore.load(provider)) ?? nil) == nil ? "\(provider.name) API key" : "Key saved. Type a new one to replace it.", text: $key)
            }
            if kind == .own {
                TextField("Server, such as http://localhost:11434/v1", text: $baseURL)
                TextField("Model, such as qwen2.5:7b-instruct", text: $model)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save()
                        tidy.refreshEngine()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() throws {
        let choice: EngineChoice
        switch kind {
        case .apple: choice = .apple
        case .own: choice = .own(try OwnModel(baseURL: baseURL, model: model))
        case .subq, .jev:
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try KeyStore.save(key, for: provider!) }
            choice = .hosted(provider!)
        }
        // Throws for a choice that cannot run, such as SubQ with no key, before it is saved.
        _ = try chooseClassifier(choice)
        try choice.save()
    }
}
