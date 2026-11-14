#if os(macOS)
import AppKit
import SwiftUI

/// Mac only: register this vault with Claude, Claude Code or Codex so they can read (handwriting
/// included, as images), search and edit its notes through Jet's MCP helper.
struct ConnectAIView: View {
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession

    @State private var statuses: [String: AIConnections.Status] = [:]
    @State private var working: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect AI to “\(session.ref.name)”").font(.title2.bold())
                Text("Lets an AI assistant list, read, search and edit the notes in this vault, including handwritten notes, which it reads as images. It can create notes and change text, but can't delete anything. The notes it reads are sent to that assistant's service.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !AIConnections.isInstalledApp {
                Label("Jet is running from \(Bundle.main.bundlePath). Install it in Applications first (./install-mac.sh), so the AI apps keep finding it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(AIClient.all) { client in
                    row(client)
                    if client.id != AIClient.all.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            DisclosureGroup("Other apps and ChatGPT") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Any app that supports local MCP servers can use Jet. Point it at this command:")
                    commandBox(AIConnections.command(for: session.ref).map(AIConnections.shellQuote).joined(separator: " "))
                    Text("The ChatGPT app itself only connects to MCP servers on the internet, not to programs on this Mac, so use Codex (above) to work with your notes through your ChatGPT account.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await refresh() }
    }

    private func row(_ client: AIClient) -> some View {
        let status = statuses[client.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name).font(.headline)
                    Text(client.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if working.contains(client.id) || status == nil {
                    ProgressView().controlSize(.small)
                } else {
                    switch status {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { act(client, connect: false) }
                    case .notInstalled:
                        Text("Not installed").foregroundStyle(.secondary)
                    default:
                        Button("Connect") { act(client, connect: true) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if case .failed(let message) = status {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }
            if case .notInstalled = status, let command = AIConnections.shellCommand(client, vault: session.ref) {
                Text("Once it's installed, connect it here or run:").font(.caption).foregroundStyle(.secondary)
                commandBox(command)
            }
        }
        .padding(12)
    }

    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func refresh() async {
        await withTaskGroup(of: (String, AIConnections.Status).self) { group in
            for client in AIClient.all {
                group.addTask { (client.id, await AIConnections.status(of: client, vault: session.ref)) }
            }
            for await (id, status) in group { statuses[id] = status }
        }
    }

    private func act(_ client: AIClient, connect: Bool) {
        working.insert(client.id)
        Task {
            let status = connect
                ? await AIConnections.connect(client, vault: session.ref)
                : await AIConnections.disconnect(client, vault: session.ref)
            statuses[client.id] = status
            working.remove(client.id)
        }
    }
}
#endif
