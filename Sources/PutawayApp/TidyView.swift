import AppKit
import PutawayCore
import SwiftUI

struct TidyView: View {
    @Bindable var tidy: Tidy
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 440)
        .sheet(isPresented: $showKey) { KeySheet(tidy: tidy) }
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
                if tidy.hasSnapKey {
                    Label("Using \(tidy.engineName). It sees your folder names and the first 1,000 characters of each file's text.", systemImage: "lock.shield")
                } else if tidy.engineName.isEmpty {
                    Label(tidy.engineProblem ?? "Add a SubQ key to start.", systemImage: "key")
                } else {
                    Label("Using \(tidy.engineName). It suggests folders; you confirm each one. Nothing leaves your Mac.", systemImage: "desktopcomputer")
                }
                Button(tidy.hasSnapKey ? "Change key" : "Add SubQ key") { showKey = true }
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
                    .disabled(tidy.engineName.isEmpty)
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

struct KeySheet: View {
    let tidy: Tidy
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SubQ API key").font(.headline)
            Text("Putaway sends your folder names and the first 1,000 characters of each file's text to SubQ to pick a folder. Files with names like passwords or recovery codes are never read, and text that looks like a key or token is never sent. The key is stored in your Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Key", text: $key)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try KeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        tidy.refreshEngine()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
