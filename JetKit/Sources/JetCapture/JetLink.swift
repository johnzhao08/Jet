import Foundation

/// Something a widget, control or Shortcut asks the app to do when it opens.
public enum JetAction: String, Codable, Sendable, CaseIterable {
    /// The quick-capture sheet.
    case capture
    /// Today's daily note.
    case daily
    /// A new Markdown note.
    case newNote
    /// A new handwritten note.
    case newInk
}

/// `jet://` links: how widgets open the app to a place.
///
///     jet://capture   jet://daily   jet://new/note   jet://new/ink
///     jet://open?vault=<uuid>&path=Folder/Note.md
public enum JetLink: Equatable, Sendable {
    public static let scheme = "jet"

    case action(JetAction)
    case open(vault: UUID?, path: String)

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.first) {
        case ("capture", nil): self = .action(.capture)
        case ("daily", nil): self = .action(.daily)
        case ("new", "note"): self = .action(.newNote)
        case ("new", "ink"): self = .action(.newInk)
        case ("open", nil):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let path = items.first(where: { $0.name == "path" })?.value, Self.isSafeVaultPath(path) else { return nil }
            self = .open(vault: items.first(where: { $0.name == "vault" })?.value.flatMap(UUID.init(uuidString:)), path: path)
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .action(.capture): URL(string: "jet://capture")!
        case .action(.daily): URL(string: "jet://daily")!
        case .action(.newNote): URL(string: "jet://new/note")!
        case .action(.newInk): URL(string: "jet://new/ink")!
        case .open(let vault, let path):
            {
                var components = URLComponents()
                components.scheme = Self.scheme
                components.host = "open"
                components.queryItems = (vault.map { [URLQueryItem(name: "vault", value: $0.uuidString)] } ?? [])
                    + [URLQueryItem(name: "path", value: path)]
                return components.url!
            }()
        }
    }

    /// A relative path that stays inside a vault: no leading slash, `..`, or hidden folders.
    public static func isSafeVaultPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == ".." || $0.hasPrefix(".") }
    }
}

/// An action left for the app by an intent that opens it (a Control Center button, a Shortcut). It's
/// a file in the App Group so it survives the app being launched cold, and it expires so a stale
/// request never fires minutes later.
public enum PendingAction {
    public static let didRequest = Notification.Name("com.johnzhao.jet.actionRequested")
    private static let lifetime: TimeInterval = 120

    private struct Stored: Codable { var action: JetAction; var requested: Date }

    private static func file(_ inbox: CaptureInbox) -> URL { inbox.base.appendingPathComponent("action.json") }

    /// Leaves `action` for the app, and wakes it if it's already running.
    public static func request(_ action: JetAction, inbox: CaptureInbox? = .shared) {
        if let inbox, (try? FileManager.default.createDirectory(at: inbox.base, withIntermediateDirectories: true)) != nil,
           let data = try? JSONEncoder().encode(Stored(action: action, requested: Date())) {
            try? data.write(to: file(inbox), options: .atomic)
        }
        NotificationCenter.default.post(name: didRequest, object: nil)
    }

    /// The waiting action, if any and still fresh; it is removed.
    public static func take(inbox: CaptureInbox? = .shared, now: Date = Date()) -> JetAction? {
        guard let inbox, let data = try? Data(contentsOf: file(inbox)) else { return nil }
        try? FileManager.default.removeItem(at: file(inbox))
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              now.timeIntervalSince(stored.requested) < lifetime else { return nil }
        return stored.action
    }
}
