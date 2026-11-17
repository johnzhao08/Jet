import Foundation

/// How the sidebar orders the files in each folder.
public enum SortMode: String, CaseIterable, Identifiable, Sendable {
    case manual, name, modified, kind

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .modified: "Date Modified"
        case .kind: "Kind"
        }
    }
}

extension VaultSession {
    nonisolated static let orderFile = ".jet/order.json"

    nonisolated static func loadOrder(root: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(orderFile)),
              let order = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return order
    }

    func saveOrder() {
        let url = url(for: Self.orderFile)
        // Folders that no longer exist and empty lists aren't kept.
        let order = manualOrder.filter { !$0.value.isEmpty && ($0.key.isEmpty || isDirectory($0.key)) }
        manualOrder = order
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(order) else { return }
        if (try? Data(contentsOf: url)) == data { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        didWriteFile()
    }

    /// One folder's children, in the current sort order (folders first, except in manual order).
    func arranged(_ nodes: [FileNode], in folder: String) -> [FileNode] {
        let sorted = Self.sorted(nodes, by: sortMode == .manual ? .name : sortMode)
        var result = sorted
        if sortMode == .manual {
            let order = manualOrder[folder] ?? []
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            // Placed items in their order; anything new goes after them, by name.
            result = sorted.enumerated().sorted { a, b in
                switch (rank[a.element.fileName], rank[b.element.fileName]) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }
        return result.map { node in
            var node = node
            if node.isDirectory { node.children = arranged(node.children ?? [], in: node.path) }
            return node
        }
    }

    nonisolated static func sorted(_ nodes: [FileNode], by mode: SortMode) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch mode {
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return x > y }
            case .kind:
                let x = a.isDirectory ? "" : a.fileExtension, y = b.isDirectory ? "" : b.fileExtension
                if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            case .manual, .name:
                break
            }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    /// The children of `folder` as the sidebar shows them.
    public func children(of folder: String) -> [FileNode] {
        if folder.isEmpty { return tree }
        func find(_ nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.path == folder { return node }
                if folder.hasPrefix(node.path + "/"), let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(tree)?.children ?? []
    }

    /// Puts `path` just before `sibling` in its folder (at the end when `sibling` is nil), switching
    /// the sidebar to manual order, which keeps the current arrangement as its starting point.
    public func place(_ path: String, before sibling: String?) {
        if sortMode != .manual { freezeCurrentOrder() }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var names = children(of: folder).map(\.fileName).filter { $0 != name }
        if let sibling, let index = names.firstIndex(of: (sibling as NSString).lastPathComponent) {
            names.insert(name, at: index)
        } else {
            names.append(name)
        }
        manualOrder[folder] = names
        saveOrder()
        if sortMode == .manual { refreshTree() } else { sortMode = .manual }
    }

    /// Moves `path` into `folder` (if it isn't there already) and places it before `sibling`.
    @discardableResult
    public func move(_ path: String, into folder: String, before sibling: String?) -> String? {
        var current = path
        if (path as NSString).deletingLastPathComponent != folder {
            guard let moved = move(path, into: folder) else { return nil }
            current = moved
        }
        guard sibling != path else { return current }
        place(current, before: sibling)
        return current
    }

    /// Makes what the sidebar shows now the manual order, for every folder.
    func freezeCurrentOrder() {
        var order: [String: [String]] = [:]
        func walk(_ nodes: [FileNode], in folder: String) {
            order[folder] = nodes.map(\.fileName)
            for node in nodes where node.isDirectory { walk(node.children ?? [], in: node.path) }
        }
        walk(tree, in: "")
        manualOrder = order
    }

    /// Swaps `path` with its neighbour above (-1) or below (+1).
    public func nudge(_ path: String, by offset: Int) {
        let folder = (path as NSString).deletingLastPathComponent
        let siblings = children(of: folder).map(\.path)
        guard let index = siblings.firstIndex(of: path) else { return }
        let target = index + offset
        guard siblings.indices.contains(target) else { return }
        // Before the item now at `target` when moving up; before the one after it when moving down.
        let before = offset < 0 ? siblings[target] : (target + 1 < siblings.count ? siblings[target + 1] : nil)
        place(path, before: before)
    }

    /// Finder's Clean Up By: every folder's manual order becomes `mode`'s order.
    public func cleanUp(by mode: SortMode) {
        var order: [String: [String]] = [:]
        func walk(_ nodes: [FileNode], in folder: String) {
            let sorted = Self.sorted(nodes, by: mode)
            order[folder] = sorted.map(\.fileName)
            for node in sorted where node.isDirectory { walk(node.children ?? [], in: node.path) }
        }
        walk(Self.scan(root: root, relative: ""), in: "")
        manualOrder = order
        saveOrder()
        if sortMode == .manual { refreshTree() } else { sortMode = .manual }
    }

    /// Keeps the manual order right when something is renamed, moved (`to` its new path) or deleted (`to` nil).
    func orderRenamed(from path: String, to newPath: String?) {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var changed = false
        if var names = manualOrder[folder], let index = names.firstIndex(of: name) {
            if let newPath, (newPath as NSString).deletingLastPathComponent == folder {
                names[index] = (newPath as NSString).lastPathComponent
            } else {
                names.remove(at: index)
                if let newPath {
                    let target = (newPath as NSString).deletingLastPathComponent
                    if manualOrder[target] != nil { manualOrder[target]?.append((newPath as NSString).lastPathComponent) }
                }
            }
            manualOrder[folder] = names
            changed = true
        }
        // A folder's own order list follows it.
        for key in manualOrder.keys where key == path || key.hasPrefix(path + "/") {
            let list = manualOrder.removeValue(forKey: key)
            if let newPath, let list { manualOrder[newPath + key.dropFirst(path.count)] = list }
            changed = true
        }
        if changed { saveOrder() }
    }
}
