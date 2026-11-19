import Foundation

/// Something captured outside the app (share sheet, Shortcuts, the widget) that is waiting to be
/// written into a vault. The extensions never touch a vault themselves: they leave a `CaptureItem`
/// in the shared inbox, and Jet files it when it next runs, through the same code as everything
/// else it writes. That keeps a half-written note from being committed, and keeps two processes
/// from writing the same vault at once.
public struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    public enum Destination: String, Codable, Sendable, CaseIterable {
        /// A new note in the vault's `Inbox/` folder.
        case inbox
        /// A new entry at the end of today's daily note.
        case dailyNote
    }

    public var id: UUID
    public var created: Date
    public var destination: Destination
    /// The vault it's meant for; nil means whichever vault is open when Jet files it.
    public var vaultID: UUID?
    public var title: String
    public var text: String
    /// The page or link it came from.
    public var link: String?
    /// File names inside the item's folder in the inbox (see `CaptureInbox.attachmentURLs`).
    public var attachments: [String]
    /// Where it came from ("Share Sheet", "Shortcuts", "Quick Capture"), for debugging.
    public var origin: String

    public init(id: UUID = UUID(), created: Date = Date(), destination: Destination = .inbox, vaultID: UUID? = nil,
                title: String = "", text: String = "", link: String? = nil, attachments: [String] = [],
                origin: String = "") {
        self.id = id
        self.created = created
        self.destination = destination
        self.vaultID = vaultID
        self.title = title
        self.text = text
        self.link = link
        self.attachments = attachments
        self.origin = origin
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (link ?? "").isEmpty && attachments.isEmpty
    }
}

/// Rules shared by the extensions and the app so a capture can't name its way out of the vault.
public enum CaptureLimits {
    /// Git hosts refuse files over 100 MB, which would stop the vault syncing.
    public static let largestAttachment = 100_000_000
    public static let mostAttachments = 20
    public static let longestText = 1_000_000
    /// Unfiled captures older than this are dropped from the inbox's scratch space, never the vault.
    public static let staleScratch: TimeInterval = 24 * 3600
}

public enum CaptureNaming {
    /// A safe single path component for `name`: no separators, no leading dots, no control
    /// characters, at most `limit` characters. Nil when nothing usable is left.
    public static func fileName(_ name: String, limit: Int = 80) -> String? {
        var clean = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "\u{0}"..."\u{1F}", "\u{7F}": clean.append("-")
            default: clean.unicodeScalars.append(scalar)
            }
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.count > limit { clean = String(clean.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return clean.isEmpty ? nil : clean
    }

    /// True for a plain file name (what `CaptureItem.attachments` must hold).
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A note title for a capture that has none: its first line, or the date.
    public static func fallbackTitle(for item: CaptureItem, calendar: Calendar = .current) -> String {
        let firstLine = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let stripped = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] \t"))
        if let name = fileName(stripped, limit: 60) { return name }
        if let link = item.link, let host = URL(string: link)?.host, let name = fileName(host) { return name }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Capture " + formatter.string(from: item.created)
    }
}
