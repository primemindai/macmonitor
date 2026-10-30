import Testing
import Foundation
@testable import MonitorCore

/// `Optional<UInt64>.map(Double.init)` picks `Double(bitPattern:)` and turns 1 GB into about 5e-315.
/// These pin every byte-sized number that flows into history, MCP and the process table.
@Suite struct ByteMetricTests {
    @Test func byteMetricsKeepTheirValue() throws {
        var s = Snapshot.empty(ts: Date())
        s.memory.usedBytes = 24_000_000_000
        s.memory.compressedBytes = 8_200_000_000
        s.memory.swapUsed = 1_500_000_000
        s.gpu.inUseBytes = 1_400_000_000
        let cases: [(String, Double)] = [("mem.used_bytes", 24e9), ("mem.compressed_bytes", 8.2e9),
                                         ("mem.swap_used_bytes", 1.5e9), ("gpu.mem_used_bytes", 1.4e9)]
        for (name, want) in cases {
            let m = try #require(MetricCatalog.metric(named: name))
            #expect(m.extract(s) == want, "\(name)")
        }
    }

    @Test func topUnionRanksByRealMemory() {
        let small = ProcSample(pid: 1, name: "small", memBytes: 10_000_000, isOwn: false)
        let big = ProcSample(pid: 2, name: "big", memBytes: 9_000_000_000, isOwn: false)
        let picked = SampleEngine.topUnion([small, big], n: 1)
        #expect(picked.map(\.name) == ["big"])
    }

    @Test func storedProcessMemoryRoundTrips() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        var s = Snapshot.empty(ts: Date(timeIntervalSince1970: 1_800_000_000))
        s.topProcesses = [ProcSample(pid: 7, name: "Safari", cpuPercent: 12, memBytes: 2_500_000_000, isOwn: true)]
        s.processesAt = s.ts
        try store.write(s)
        let back = try store.topProcesses(at: nil)
        #expect(back.first?.memBytes == 2_500_000_000)
    }

    @Test func mcpMemorySortUsesRealBytes() async throws {
        var s = Snapshot.empty(ts: Date())
        s.topProcesses = [ProcSample(pid: 1, name: "small", cpuPercent: 50, memBytes: 10_000_000, isOwn: false),
                          ProcSample(pid: 2, name: "big", cpuPercent: 1, memBytes: 9_000_000_000, isOwn: false)]
        let snap = s
        let h = MCPHandler(store: { nil }, live: { snap })
        let req = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"top_processes","arguments":{"sort_by":"memory","limit":1}}}"#
        let reply = try #require(await h.handle(line: req))
        #expect(reply.contains("big"))
        #expect(!reply.contains("\\\"small\\\"") && !reply.contains("small"))
    }
}
