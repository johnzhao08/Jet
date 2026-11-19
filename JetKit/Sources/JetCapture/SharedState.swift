import Foundation

/// What the app tells the extensions: which vaults exist and what's recent. Extensions can't read
/// the app's own storage, so the app publishes just this much to the App Group. Titles only, never
/// note contents.
public struct VaultDirectory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public var vaults: [Entry]
    /// The vault open when the app last ran: where captures go by default.
    public var current: UUID?

    public init(vaults: [Entry] = [], current: UUID? = nil) { self.vaults = vaults; self.current = current }

    public static func load(from inbox: CaptureInbox? = .shared) -> VaultDirectory {
        inbox.flatMap { SharedFile.read(VaultDirectory.self, "vaults.json", in: $0) } ?? VaultDirectory()
    }

    public func save(to inbox: CaptureInbox? = .shared) {
        guard let inbox else { return }
        SharedFile.write(self, "vaults.json", in: inbox)
    }
}

/// The few notes a widget lists.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Identifiable, Sendable {
        public var path: String
        public var title: String
        public var isInk: Bool
        public var id: String { path }
        public init(path: String, title: String, isInk: Bool) { self.path = path; self.title = title; self.isInk = isInk }
    }

    public var vaultID: UUID?
    public var vaultName: String
    public var recents: [Note]

    public init(vaultID: UUID? = nil, vaultName: String = "", recents: [Note] = []) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.recents = recents
    }

    public static func load(from inbox: CaptureInbox? = .shared) -> WidgetSnapshot {
        inbox.flatMap { SharedFile.read(WidgetSnapshot.self, "widget.json", in: $0) } ?? WidgetSnapshot()
    }

    /// Writes the snapshot, and refreshes the widgets only if it changed.
    public func save(to inbox: CaptureInbox? = .shared) {
        guard let inbox, Self.load(from: inbox) != self else { return }
        SharedFile.write(self, "widget.json", in: inbox)
        CaptureInbox.reloadWidgets()
    }
}

enum SharedFile {
    static func read<T: Decodable>(_ type: T.Type, _ name: String, in inbox: CaptureInbox) -> T? {
        guard let data = try? Data(contentsOf: inbox.base.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String, in inbox: CaptureInbox) {
        try? FileManager.default.createDirectory(at: inbox.base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: inbox.base.appendingPathComponent(name), options: .atomic) }
    }
}
