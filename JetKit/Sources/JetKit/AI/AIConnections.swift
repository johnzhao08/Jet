#if os(macOS)
import Foundation

/// An AI app that can use Jet's MCP helper, and how to register a vault with it.
public struct AIClient: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// Claude's Mac app: an entry in its `claude_desktop_config.json`.
        case claudeDesktop
        /// A command-line agent with `mcp add/get/remove` subcommands.
        case cli(executableCandidates: [String], addArguments: @Sendable (String, [String]) -> [String],
                 removeArguments: @Sendable (String) -> [String])
    }

    public let id: String
    public let name: String
    public let detail: String
    public let kind: Kind

    public static let all: [AIClient] = [
        AIClient(
            id: "claude-desktop", name: "Claude", detail: "The Claude app for Mac. Restart it after connecting.",
            kind: .claudeDesktop),
        AIClient(
            id: "claude-code", name: "Claude Code", detail: "Anthropic's coding agent in the terminal.",
            kind: .cli(executableCandidates: ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                       addArguments: { name, command in ["mcp", "add", "--scope", "user", name, "--"] + command },
                       removeArguments: { name in ["mcp", "remove", "--scope", "user", name] })),
        AIClient(
            id: "codex", name: "Codex (ChatGPT)", detail: "OpenAI's agent; signs in with your ChatGPT account.",
            kind: .cli(executableCandidates: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"],
                       addArguments: { name, command in ["mcp", "add", name, "--"] + command },
                       removeArguments: { name in ["mcp", "remove", name] })),
    ]
}

/// Registers vaults with AI apps. Everything runs off the main thread; CLIs can take a second.
public enum AIConnections {
    /// The helper bundled inside Jet.app.
    public static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jet-mcp").path
    }

    /// True when Jet runs from /Applications (or ~/Applications), so the helper path stays valid.
    public static var isInstalledApp: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// The MCP server name for a vault, e.g. "jet-my-notes".
    public static func serverName(for vault: VaultRef) -> String {
        let slug = vault.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "jet" : "jet-\(collapsed)"
    }

    public static func command(for vault: VaultRef) -> [String] {
        [helperPath, "--vault", vault.url.path]
    }

    /// What a user would type, for copying.
    public static func shellCommand(_ client: AIClient, vault: VaultRef) -> String? {
        guard case .cli(let candidates, let add, _) = client.kind else { return nil }
        let tool = (candidates.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        return ([tool] + add(serverName(for: vault), command(for: vault))).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ argument: String) -> String {
        argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@=".contains($0) }
            ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Availability and status

    public enum Status: Equatable, Sendable {
        case notInstalled
        case notConnected
        case connected
        case failed(String)
    }

    public static func status(of client: AIClient, vault: VaultRef) async -> Status {
        await Task.detached {
            switch client.kind {
            case .claudeDesktop:
                guard claudeDesktopInstalled else { return .notInstalled }
                let servers = (readClaudeConfig()["mcpServers"] as? [String: Any]) ?? [:]
                return servers[serverName(for: vault)] == nil ? .notConnected : .connected
            case .cli(let candidates, _, _):
                guard let tool = executable(candidates) else { return .notInstalled }
                let name = serverName(for: vault)
                let result = run(tool, ["mcp", "get", name])
                // `get` prints the configuration (including our helper's path) when the server exists.
                return result.status == 0 && result.output.contains("jet-mcp") ? .connected : .notConnected
            }
        }.value
    }

    public static func connect(_ client: AIClient, vault: VaultRef) async -> Status {
        await Task.detached {
            let name = serverName(for: vault)
            switch client.kind {
            case .claudeDesktop:
                var config = readClaudeConfig()
                var servers = (config["mcpServers"] as? [String: Any]) ?? [:]
                let command = command(for: vault)
                servers[name] = ["command": command[0], "args": Array(command.dropFirst())]
                config["mcpServers"] = servers
                do {
                    try writeClaudeConfig(config)
                    return .connected
                } catch {
                    return .failed(error.localizedDescription)
                }
            case .cli(let candidates, let add, let remove):
                guard let tool = executable(candidates) else { return .notInstalled }
                _ = run(tool, remove(name))  // replace an older registration (e.g. a moved vault)
                let result = run(tool, add(name, command(for: vault)))
                return result.status == 0 ? .connected : .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    public static func disconnect(_ client: AIClient, vault: VaultRef) async -> Status {
        await Task.detached {
            let name = serverName(for: vault)
            switch client.kind {
            case .claudeDesktop:
                var config = readClaudeConfig()
                var servers = (config["mcpServers"] as? [String: Any]) ?? [:]
                servers[name] = nil
                config["mcpServers"] = servers
                do {
                    try writeClaudeConfig(config)
                    return .notConnected
                } catch {
                    return .failed(error.localizedDescription)
                }
            case .cli(let candidates, _, let remove):
                guard let tool = executable(candidates) else { return .notInstalled }
                let result = run(tool, remove(name))
                return result.status == 0 ? .notConnected : .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    // MARK: Claude Desktop config

    static var claudeSupportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
    }

    static var claudeConfigURL: URL { claudeSupportFolder.appendingPathComponent("claude_desktop_config.json") }

    static var claudeDesktopInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: claudeSupportFolder.path)
    }

    static func readClaudeConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeConfigURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Writes the config, keeping every other setting, after saving a one-time backup of the original.
    static func writeClaudeConfig(_ config: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeSupportFolder, withIntermediateDirectories: true)
        let backup = claudeConfigURL.appendingPathExtension("before-jet")
        if fm.fileExists(atPath: claudeConfigURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: claudeConfigURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeConfigURL, options: .atomic)
    }

    // MARK: Command-line tools

    static func executable(_ candidates: [String]) -> String? {
        candidates.map { ($0 as NSString).expandingTildeInPath }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // GUI apps get a minimal PATH; CLIs installed by npm or Homebrew may need theirs.
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
