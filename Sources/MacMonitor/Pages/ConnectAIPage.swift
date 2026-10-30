import SwiftUI
import AppKit
import MonitorCore

/// How to connect Claude and Codex to the bundled MCP server. Copy only: it never edits a Claude or Codex config file.
struct ConnectAIPage: View {
    @Environment(\.theme) private var theme
    @State private var probe: ProbeState = .idle

    private enum ProbeState { case idle, running, done(MCPProbe.Outcome) }

    /// Read from the running app, so it is right in /Applications, ~/Applications or anywhere else.
    private let server = MCPSetup.serverURL(bundleURL: Bundle.main.bundleURL).path

    var body: some View {
        PageScroll(title: "Connect AI", subtitle: "Let Claude and Codex read this Mac's hardware") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI agents like Claude and Codex can read this Mac's hardware data through MacMonitor's MCP server. It is read only: they can look, but never change anything.")
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Caps("MCP server")
                    CopyRow(text: server)
                    if let warning = serverWarning {
                        Text(warning).font(.system(size: 11)).foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            RowGroup(title: "Claude Code", note: "Run once in Terminal.") {
                CopyRow(text: MCPSetup.claudeCodeCommand(server: server), boxed: true)
            }
            RowGroup(title: "Codex CLI", note: "Run once in Terminal.") {
                CopyRow(text: MCPSetup.codexCommand(server: server), boxed: true)
            }
            RowGroup(title: "Claude Desktop", note: "Add to \(MCPSetup.claudeDesktopConfig), then restart Claude.") {
                CopyRow(text: MCPSetup.claudeDesktopJSON(server: server), boxed: true)
                Text("If the file already has \"mcpServers\", copy only the \"macmonitor\" entry into it.")
                    .font(.system(size: 11)).foregroundStyle(theme.mut)
            }
            RowGroup(title: "Codex config file", note: "Or add to \(MCPSetup.codexConfig) instead of running the Codex command.") {
                CopyRow(text: MCPSetup.codexTOML(server: server), boxed: true)
            }

            RowGroup(title: "Test connection", note: "Starts the server and asks for its tools, the same way Claude and Codex do.") {
                Card {
                    HStack(spacing: 12) {
                        PillButton(title: isRunning ? "Testing..." : "Test connection", symbol: "bolt.horizontal") { test() }
                            .disabled(isRunning)
                        probeText
                        Spacer()
                    }
                }
            }

            RowGroup(title: "Tools", note: "All read only.") {
                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(MCPSetup.tools, id: \.name) { t in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(t.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .frame(width: 170, alignment: .leading)
                                Text(t.summary).font(.system(size: 12)).foregroundStyle(theme.mut)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var serverWarning: String? {
        if MCPSetup.isTranslocated(server) {
            return "macOS is running MacMonitor from a temporary copy, so this path changes every launch. Move MacMonitor to your Applications folder, open it again, then copy."
        }
        if !FileManager.default.isExecutableFile(atPath: server) {
            return "No server at this path. Open MacMonitor from its MacMonitor.app to get the right path."
        }
        return nil
    }

    private var isRunning: Bool { if case .running = probe { return true } else { return false } }

    @ViewBuilder private var probeText: some View {
        switch probe {
        case .idle:
            Text("Not tested yet").font(.system(size: 12)).foregroundStyle(theme.mut)
        case .running:
            ProgressView().controlSize(.small)
        case .done(let r):
            if case .connected = r {
                Label(r.message, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good)
            } else {
                Label(r.message, systemImage: "xmark.octagon.fill").font(.system(size: 12)).foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func test() {
        probe = .running
        let url = URL(fileURLWithPath: server)
        Task { probe = .done(await MCPProbe.run(server: url)) }
    }
}

/// Monospaced text with a Copy button. Copies to the clipboard only.
private struct CopyRow: View {
    var text: String
    var boxed = false
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        let row = HStack(alignment: .top, spacing: 12) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PillButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") { copy() }
        }
        if boxed { Card { row } } else { row }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
