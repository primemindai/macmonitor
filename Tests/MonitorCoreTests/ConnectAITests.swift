import Testing
import Foundation
@testable import MonitorCore

/// The Connect AI page: copy-paste setup for Claude and Codex, and the "Test connection" handshake.
@Suite struct ConnectAITests {
    /// The words a shell hands to the program after parsing `command` (run through /bin/sh, nothing executed).
    func shellWords(_ command: String) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -- \(command); printf '%s\\0' \"$@\""]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// A wrong quote breaks setup for anyone whose app path has a space, a quote or a $ in it.
    @Test(arguments: [
        ("/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp",
         #"command = "/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp""#),
        ("/Users/user/My Apps/MacMonitor.app/Contents/MacOS/macmonitor-mcp",
         #"command = "/Users/user/My Apps/MacMonitor.app/Contents/MacOS/macmonitor-mcp""#),
        (#"/Users/user/Bob's "Apps" $HOME `id` \x/MacMonitor.app/Contents/MacOS/macmonitor-mcp"#,
         #"command = "/Users/user/Bob's \"Apps\" $HOME `id` \\x/MacMonitor.app/Contents/MacOS/macmonitor-mcp""#),
    ])
    func setupSnippetsKeepThePathWhole(path: String, tomlLine: String) throws {
        #expect(try shellWords(MCPSetup.claudeCodeCommand(server: path)) == ["claude", "mcp", "add", "-s", "user", "macmonitor", "--", path])
        #expect(try shellWords(MCPSetup.codexCommand(server: path)) == ["codex", "mcp", "add", "macmonitor", "--", path])

        let json = MCPSetup.claudeDesktopJSON(server: path)
        #expect(json.contains("\n"), "pretty printed")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entry = try #require((root["mcpServers"] as? [String: Any])?["macmonitor"] as? [String: Any])
        #expect(entry["command"] as? String == path)

        #expect(MCPSetup.codexTOML(server: path) == "[mcp_servers.macmonitor]\n" + tomlLine)
    }

    /// The probe's requests, answered by the real handler, read back as a connection, and the page lists the same tools.
    @Test func probeReadsTheRealServer() async throws {
        let h = MCPHandler(store: { nil }, live: { liveSnap() })
        var out = ""
        for line in MCPProbe.requestLines {
            if let reply = await h.handle(line: line) { out += reply + "\n" }
        }
        let outcome = MCPProbe.parse(out)
        #expect(outcome == .connected(tools: 8))
        #expect(outcome.message == "Connected: 8 tools")
        #expect(MCPSetup.tools.map(\.name) == MCPTools.list.compactMap { $0["name"] as? String })
        #expect(MCPSetup.tools.allSatisfy { !$0.summary.isEmpty && !$0.summary.contains("\n") })
    }

    /// Anything short of a full handshake must never read as "Connected".
    @Test(arguments: [
        "",
        "not json at all",
        #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"macmonitor"}}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"}]}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"macmonitor"}}}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"macmonitor"}}}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#,
    ])
    func probeRejectsPartialAnswers(output: String) {
        guard case .failed(let why) = MCPProbe.parse(output) else {
            Issue.record("parsed as connected: \(output)")
            return
        }
        #expect(!why.isEmpty)
    }

    func script(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("server-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The real process path: a working server connects, a hung one times out and is killed, a missing one says so.
    @Test func probeRunsTheServerAndAlwaysCleansUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try script("""
            read a; case "$a" in *'"initialize"'*) ;; *) exit 1 ;; esac
            read b; read c
            echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"macmonitor"}}}'
            echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"},{"name":"b"}]}}'
            """, in: dir)
        #expect(await MCPProbe.run(server: good, timeout: 5) == .connected(tools: 2))

        let pidFile = dir.appendingPathComponent("hung.pid")
        let hung = try script("echo $$ > '\(pidFile.path)'\nexec sleep 30\n", in: dir)
        let start = Date()
        let r = await MCPProbe.run(server: hung, timeout: 1)
        #expect(Date().timeIntervalSince(start) < 5)
        guard case .failed(let why) = r else { Issue.record("hung server read as \(r)"); return }
        #expect(why.contains("did not answer"))
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "the hung server is still running")

        let quiet = try script("exit 3\n", in: dir)
        guard case .failed = await MCPProbe.run(server: quiet, timeout: 5) else { Issue.record("silent server read as connected"); return }

        let missing = URL(fileURLWithPath: "/Applications/Nope.app/Contents/MacOS/macmonitor-mcp")
        guard case .failed(let gone) = await MCPProbe.run(server: missing, timeout: 5) else { Issue.record("missing server read as connected"); return }
        #expect(gone.contains("not found"))
    }
}
