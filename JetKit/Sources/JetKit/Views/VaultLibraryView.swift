import SwiftUI

struct VaultLibraryView: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var section = "Properties"
    @State private var board = false
    @State private var selectedKey = ""

    private var keys: [String] {
        Set(session.index.noteProperties.values.flatMap { $0.map(\.key) }).sorted()
    }
    private var activeKey: String { keys.contains(selectedKey) ? selectedKey : keys.first ?? "" }
    private var notes: [FileNode] { session.allNotes.filter { FileKind(path: $0.path) == .markdown } }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Library", selection: $section) {
                    ForEach(["Properties", "Deleted notes", "Conflicts"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).padding(.horizontal)
                switch section {
                case "Deleted notes": NoteHistoryList(session: session, path: nil)
                case "Conflicts": conflictList
                default: properties
                }
            }
            .navigationTitle("Vault library")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.sheetSize(width: 720, height: 540)
    }

    @ViewBuilder private var properties: some View {
        if keys.isEmpty {
            ContentUnavailableView("No note properties", systemImage: "tablecells",
                                   description: Text("Open a Markdown note and choose Edit Properties."))
        } else {
            HStack {
                Picker("View", selection: $board) { Text("Table").tag(false); Text("Board").tag(true) }
                    .fixedSize()
                if board {
                    Picker("Group by", selection: Binding(get: { activeKey }, set: { selectedKey = $0 })) {
                        ForEach(keys, id: \.self) { Text($0) }
                    }
                }
                Spacer()
            }.padding(.horizontal)
            ScrollView([.vertical, .horizontal]) {
                if board {
                    let groups = Dictionary(grouping: notes, by: { value($0.path, activeKey) })
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(groups.keys.sorted(), id: \.self) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.isEmpty ? "No value" : group).font(.headline)
                                ForEach(groups[group] ?? []) { note in noteButton(note.path) }
                            }.frame(minWidth: 130, alignment: .leading)
                        }
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow { Text("Note"); ForEach(keys, id: \.self) { Text($0) } }.font(.headline)
                        ForEach(notes) { note in
                            GridRow {
                                noteButton(note.path)
                                ForEach(keys, id: \.self) { Text(value(note.path, $0)) }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding()
        }
    }

    private func value(_ path: String, _ key: String) -> String {
        session.index.noteProperties[path]?.first { $0.key == key }?.values.joined(separator: ", ") ?? ""
    }

    private func noteButton(_ path: String) -> some View {
        Button(path) { session.selection = path; dismiss() }.buttonStyle(.borderless)
    }

    @ViewBuilder private var conflictList: some View {
        let copies = VaultSession.flatten(session.tree).compactMap { node -> (copy: String, original: String)? in
            let name = node.fileName as NSString
            guard !node.isDirectory, let range = name.deletingPathExtension.range(of: #" \(conflict \d{4}-\d{2}-\d{2} \d{2}\.\d{2}(?: \d+)?\)$"#, options: .regularExpression)
            else { return nil }
            let originalName = String(name.deletingPathExtension[..<range.lowerBound])
                + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension)
            return (node.path, ((node.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(originalName))
        }
        if copies.isEmpty && session.lastConflictPaths.isEmpty {
            ContentUnavailableView("No sync conflicts", systemImage: "checkmark.circle")
        } else {
            List {
                if !copies.isEmpty {
                    Section("Versions kept side by side") {
                        ForEach(copies, id: \.copy) { item in
                            VStack(alignment: .leading) {
                                if session.exists(item.original) {
                                    noteButton(item.original)
                                    if [.markdown, .text].contains(FileKind(path: item.original)) {
                                        NavigationLink("Compare text") {
                                            ConflictComparison(root: session.root, local: item.original, remote: item.copy)
                                        }
                                    }
                                }
                                noteButton(item.copy)
                            }
                        }
                    }
                }
                if !session.lastConflictPaths.isEmpty {
                    Section("Files affected in the last merge with conflicts") {
                        ForEach(session.lastConflictPaths, id: \.self) { path in
                            if session.exists(path), !path.hasPrefix(".") { noteButton(path) }
                            else { Text(path) }
                        }
                    }
                }
            }
        }
    }
}

private struct ConflictComparison: View {
    let root: URL
    let local: String
    let remote: String
    @State private var texts: [String: String] = [:]
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach([local, remote], id: \.self) { path in
                    Text(path).font(.headline)
                    Text(texts[path] ?? "").font(.body.monospaced()).textSelection(.enabled)
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Compare conflict versions")
        .task {
            let paths = [local, remote], root = root
            do {
                texts = try await Task.detached {
                    try Dictionary(uniqueKeysWithValues: paths.map { path -> (String, String) in
                        let handle = try FileHandle(forReadingFrom: root.vaultFile(path))
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 65537) ?? Data()
                        let preview = String(decoding: data.prefix(65536), as: UTF8.self)
                        return (path, preview + (data.count > 65536 ? "\n… (preview truncated)" : ""))
                    })
                }.value
            } catch { failure = error.localizedDescription }
        }
    }
}

struct NoteHistoryList: View {
    let session: VaultSession
    let path: String?
    @State private var revisions: [NoteRevision]?
    @State private var failure: String?
    @State private var restore: NoteRevision?
    @State private var preview: String?
    @State private var load = 0

    var body: some View {
        Group {
            if let revisions {
                if revisions.isEmpty {
                    ContentUnavailableView(path == nil ? "No deleted notes in Git" : "No committed versions", systemImage: "clock")
                } else {
                    List(revisions) { revision in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(path == nil ? revision.path : revision.summary)
                                Text("\(revision.date.formatted()) · \(revision.commit.prefix(8))").font(.caption)
                            }
                            Spacer()
                            if FileKind(path: revision.path) == .markdown {
                                Button("Preview") { read(revision) }
                            }
                            Button("Restore") { restore = revision }.disabled(session.syncState == .syncing)
                        }.buttonStyle(.borderless)
                    }
                }
            } else if failure == nil { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.red).padding() }
        }
        .task(id: load) {
            let root = session.root.path, path = path
            do {
                revisions = try await Task.detached {
                    guard GitRepository.isRepository(at: root) else { return [NoteRevision]() }
                    return try GitRepository.open(at: root).noteHistory(path: path)
                }.value
            } catch { failure = error.localizedDescription }
        }
        .confirmationDialog("Restore this version?", isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } }),
                            presenting: restore) { revision in
            Button("Restore version") { recover(revision) }
        } message: { _ in Text(path == nil ? "Re-create the deleted note at its original path." : "Replace the current note. Jet keeps a copy of your current file beside it.") }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .trailing) {
                Button("Done") { preview = nil }
                ScrollView { Text(preview ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding().sheetSize(width: 560, height: 440)
        }
    }

    private func read(_ revision: NoteRevision) {
        do {
            let bytes = try GitRepository.open(at: session.root.path).noteVersion(path: revision.path, commit: revision.commit)
            preview = String(decoding: bytes, as: UTF8.self)
        } catch { failure = error.localizedDescription }
    }

    private func recover(_ revision: NoteRevision) {
        guard session.syncState != .syncing else { return }
        session.flushEditors()
        do {
            let file = try session.root.vaultFile(revision.path)
            let bytes = try GitRepository.open(at: session.root.path).noteVersion(path: revision.path, commit: revision.commit)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path == nil || !FileManager.default.fileExists(atPath: file.path) {
                try bytes.write(to: file, options: .withoutOverwriting)
            } else {
                let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
                var n = 1
                var backup: URL
                repeat {
                    let suffix = n == 1 ? "" : " \(n)"
                    backup = file.deletingLastPathComponent().appendingPathComponent("\(stem) (before restore\(suffix)).\(ext)")
                    n += 1
                } while FileManager.default.fileExists(atPath: backup.path)
                try FileManager.default.copyItem(at: file, to: backup)
                try bytes.write(to: file, options: .atomic)
            }
            session.contentVersion += 1
            session.didWriteFile()
            session.refreshTree()
            failure = nil
            load += 1
        } catch { failure = error.localizedDescription }
    }
}
