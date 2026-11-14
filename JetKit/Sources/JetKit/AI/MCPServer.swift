#if os(macOS)
import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC), as launched by
/// Claude Desktop, Claude Code, Codex and other MCP clients: `jet-mcp --vault <folder>`.
public final class MCPServer {
    public static let name = "jet"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    These tools work on the user's Jet notes vault: a folder of Markdown notes (.md) and handwritten \
    notes (.ink, written with Apple Pencil), synced with git. Notes link to each other with \
    [[Note title]] wikilinks and use #tags and YAML frontmatter properties, like Obsidian. \
    Handwritten notes are returned as images; read the handwriting from them. \
    Change notes with edit_note, append_to_note or create_note; there is no way to delete notes.
    """

    let tools: VaultTools

    public init(vault: URL) {
        tools = VaultTools(root: vault)
    }

    /// Entry point for the `jet-mcp` executable.
    public static func main(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--vault"), arguments.count > flag + 1 else {
            FileHandle.standardError.write(Data("usage: jet-mcp --vault <folder>\n".utf8))
            return 64
        }
        let vault = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            FileHandle.standardError.write(Data("jet-mcp: no vault folder at \(vault.path)\n".utf8))
            return 66
        }
        MCPServer(vault: vault).run()
        return 0
    }

    /// Reads one JSON-RPC message per line from stdin and answers on stdout until stdin closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply: [String: Any]?
            if let data = line.data(using: .utf8),
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                reply = handle(message)
            } else {
                reply = Self.error(id: NSNull(), code: -32700, message: "Parse error")
            }
            if let reply, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    /// The reply to one message, or nil for notifications (and replies to requests we never make).
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }  // a notification
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "title": "Jet notes", "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": VaultTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            let result = tools.call(name, params["arguments"] as? [String: Any] ?? [:])
            return Self.result(id: id, ["content": result.content, "isError": result.isError])
        case "resources/list":
            return Self.result(id: id, ["resources": []])
        case "prompts/list":
            return Self.result(id: id, ["prompts": []])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
#endif
