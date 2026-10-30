// macmonitor-mcp: stdio MCP server for MacMonitor. Read only: no network, no file writes.
// It reads the app's history database read only, and samples live when the app is not running.
import Foundation
import MonitorCore

setvbuf(stdout, nil, _IOLBF, 0)

/// Opens the app's database read only, once it exists. A missing or old file means "no history".
final class StoreBox: @unchecked Sendable {
    private var store: HistoryStore?
    private let lock = NSLock()
    func get() -> HistoryStore? {
        lock.lock(); defer { lock.unlock() }
        if store == nil { store = try? HistoryStore(path: HistoryStore.defaultURL, readOnly: true) }
        return store
    }
}

/// Reuses a live sample for 3 s, so a client calling several tools in a row pays for one sample.
actor LiveCache {
    private var last: Snapshot?
    func get() async -> Snapshot {
        if let l = last, Date().timeIntervalSince(l.ts) < 3 { return l }
        let s = await SampleEngine.oneShot()
        last = s
        return s
    }
}

let box = StoreBox()
let cache = LiveCache()
let handler = MCPHandler(store: { box.get() }, live: { await cache.get() })

for try await line in FileHandle.standardInput.bytes.lines {
    if let reply = await handler.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
