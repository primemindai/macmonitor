import Foundation

/// Copy-paste setup for the Connect AI page: where the MCP server is, and the exact command or config snippet
/// for Claude Code, Codex, Claude Desktop and Codex's config.toml. Nothing here writes a config file.
public enum MCPSetup {
    public static let serverName = "macmonitor"
    public static let claudeDesktopConfig = "~/Library/Application Support/Claude/claude_desktop_config.json"
    public static let codexConfig = "~/.codex/config.toml"

    /// The server inside the running app, so the path is right wherever the app was dragged.
    public static func serverURL(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/MacOS/macmonitor-mcp")
    }

    /// macOS runs a downloaded app from a random temp copy until it is moved. That path changes on every launch.
    public static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    /// One shell word: left bare when it is plain, else single quoted (a ' inside becomes '\'').
    public static func shellQuote(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(plain.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func claudeCodeCommand(server: String) -> String {
        "claude mcp add -s user \(serverName) -- \(shellQuote(server))"
    }

    public static func codexCommand(server: String) -> String {
        "codex mcp add \(serverName) -- \(shellQuote(server))"
    }

    /// The entry for claude_desktop_config.json, pretty printed.
    public static func claudeDesktopJSON(server: String) -> String {
        JSONRPC.pretty(["mcpServers": [serverName: ["command": server]]])
    }

    /// The table for ~/.codex/config.toml.
    public static func codexTOML(server: String) -> String {
        "[mcp_servers.\(serverName)]\ncommand = \(tomlString(server))"
    }

    /// A TOML basic string: backslash, quote and control characters escaped.
    static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += #"\\"#
            case "\"": out += #"\""#
            case _ where u.value < 0x20 || u.value == 0x7F: out += String(format: "\\u%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// The server's tools with the first sentence of each description, read from the list the server serves.
    public static let tools: [(name: String, summary: String)] = MCPTools.list.compactMap { t in
        guard let name = t["name"] as? String, let desc = t["description"] as? String else { return nil }
        let first = desc.range(of: ". ").map { String(desc[..<$0.lowerBound]) + "." } ?? desc
        return (name, first)
    }
}

/// "Test connection": starts the server, sends initialize and tools/list over stdio, and reads the answers.
public enum MCPProbe {
    public enum Outcome: Equatable, Sendable {
        case connected(tools: Int)
        case failed(String)

        public var message: String {
            switch self {
            case .connected(let n): return "Connected: \(n) \(n == 1 ? "tool" : "tools")"
            case .failed(let why): return why
            }
        }
    }

    /// Newline-delimited JSON-RPC, the same framing Claude and Codex use.
    public static let requestLines: [String] = [
        JSONRPC.encode(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": MCPHandler.supportedVersions[0], "capabilities": [String: Any](),
            "clientInfo": ["name": "macmonitor-connect-test", "version": "1"],
        ]]),
        JSONRPC.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]),
        JSONRPC.encode(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]),
    ]

    /// Connected only when initialize answered and tools/list returned at least one tool.
    public static func parse(_ output: String) -> Outcome {
        var initialized = false, initError: String?
        var tools: [[String: Any]]?, toolsError: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            let err = (obj["error"] as? [String: Any])?["message"] as? String
            let result = obj["result"] as? [String: Any]
            if id == 1 {
                if result?["serverInfo"] != nil { initialized = true } else { initError = err ?? "no server info" }
            } else if id == 2 {
                if let t = result?["tools"] as? [[String: Any]] { tools = t } else { toolsError = err ?? "no tool list" }
            }
        }
        guard initialized else {
            return .failed(initError.map { "The server refused to start: \($0)." } ?? "The server did not answer the MCP handshake.")
        }
        guard let tools else {
            return .failed(toolsError.map { "The server did not list its tools: \($0)." } ?? "The server did not list its tools.")
        }
        guard !tools.isEmpty else { return .failed("The server answered but lists no tools.") }
        return .connected(tools: tools.count)
    }

    /// Runs the handshake off the calling thread. The child process is always stopped, even when it hangs.
    public static func run(server: URL, timeout: Double = 5) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            return .failed("The MCP server was not found at \(server.path).")
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: runBlocking(server, timeout)) }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private static func runBlocking(_ server: URL, _ timeout: Double) -> Outcome {
        let p = Process()
        p.executableURL = server
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failed("Could not start the MCP server: \(error.localizedDescription)") }
        defer { stop(p) }

        let w = input.fileHandleForWriting
        _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)  // a server that already quit must not kill the app with SIGPIPE
        try? w.write(contentsOf: Data((requestLines.joined(separator: "\n") + "\n").utf8))
        try? w.close()  // end of input: the server answers what it read, then exits

        // Read until both answers are in or the server closes its output.
        let buf = Buffer()
        let done = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                if case .connected = parse(buf.text) { break }
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            stop(p)
            _ = done.wait(timeout: .now() + 2)
            return .failed("The MCP server did not answer within \(Int(timeout)) seconds.")
        }
        return parse(buf.text)
    }

    /// SIGTERM, then SIGKILL after a second, then reap.
    private static func stop(_ p: Process) {
        if p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
    }
}
