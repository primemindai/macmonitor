import Testing
import Foundation
@testable import MonitorCore

func json(_ s: String?) throws -> [String: Any] {
    let s = try #require(s)
    return try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

func call(_ h: MCPHandler, _ name: String, _ args: [String: Any] = [:], id: Int = 7) async throws -> (text: String, isError: Bool, raw: [String: Any]) {
    let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": args]]
    let line = String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)
    let r = try json(await h.handle(line: line))
    let result = try #require(r["result"] as? [String: Any], "no result in \(r)")
    let content = try #require(result["content"] as? [[String: Any]])
    let text = try #require(content.first?["text"] as? String)
    return (text, result["isError"] as? Bool ?? false, r)
}

func liveSnap() -> Snapshot {
    var s = sampleSnapshot(ts: Date())
    var b = BatteryInfo(cellVoltagesMV: [4_281], cellResistance: [76], pdMenu: [PDOption(voltageMV: 20_000, maxCurrentMA: 4_690)])
    b.adapterName = "96W USB-C Power Adapter"; b.cycleCount = 179; b.iopsHealth = "Check Battery"
    b.appleMaxCapacityPercent = 84; b.rawHealthPercent = 81.6
    s.battery = b
    s.disks.smart = SMARTInfo(tempC: 64, percentUsed: 25, spare: 100, spareThreshold: 99, tbWritten: 111.7, tbRead: 120.6,
                              powerOnHours: 2_424, powerCycles: 199, unsafeShutdowns: 12, mediaErrors: 0, criticalWarning: 0)
    s.thermal.allSensors = [SensorReading(key: "Tp0A", celsius: 90, group: "P cores", proven: false, source: "SMC"),
                            SensorReading(key: "TB0T", celsius: 36, group: "Battery", proven: true, source: "SMC")]
    return s
}

@Suite struct MCPTests {
    func handler(store: HistoryStore? = nil) -> MCPHandler {
        MCPHandler(store: { store }, live: { liveSnap() })
    }

    func historyStore() throws -> HistoryStore {
        let st = try HistoryStore(path: tempDBURL(), readOnly: false)
        let now = Date().timeIntervalSince1970
        for i in 0..<120 { try st.write(snap(now - 120 + Double(i), cpu: Double(i))) }
        return st
    }

    @Test func initializeNegotiatesVersion() async throws {
        let h = handler()
        for (asked, want) in [("2025-03-26", "2025-03-26"), ("2024-11-05", "2024-11-05"), ("2025-06-18", "2025-06-18"), ("1999-01-01", "2025-06-18")] {
            let r = try json(await h.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(asked)","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#))
            let res = try #require(r["result"] as? [String: Any])
            #expect(res["protocolVersion"] as? String == want)
            #expect((res["serverInfo"] as? [String: Any])?["name"] as? String == "macmonitor")
            #expect((res["capabilities"] as? [String: Any])?["tools"] != nil)
            #expect(r["id"] as? Int == 1)
        }
        #expect(await h.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let ping = try json(await h.handle(line: #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(ping["id"] as? String == "abc")
        #expect(ping["result"] != nil)
    }

    @Test func toolsListHasEightTools() async throws {
        let r = try json(await handler().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["get_snapshot", "get_history", "list_metrics", "top_processes", "why_fan", "get_events", "get_sensors", "get_hardware_health"])
        for t in tools {
            #expect(t["description"] is String)
            #expect((t["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    @Test func getHistoryUnknownMetricIsToolError() async throws {
        let r = try await call(handler(store: try historyStore()), "get_history", ["metric": "cpu.bogus", "minutes": 10])
        #expect(r.isError)
        #expect(r.text.contains("list_metrics"))
    }

    @Test func minutesClamped() async throws {
        let h = handler(store: try historyStore())
        for m in [0, -5, 100_000] {
            let r = try await call(h, "get_history", ["metric": "cpu.total_pct", "minutes": m])
            #expect(!r.isError, "minutes \(m): \(r.text)")
        }
        let ok = try await call(h, "get_history", ["metric": "cpu.total_pct", "minutes": 5])
        let body = try json(ok.text)
        #expect((body["count"] as? Int ?? 0) > 100)
        #expect(body["unit"] as? String == "%")
        // A missing metric argument is a tool error, not a crash.
        #expect(try await call(h, "get_history", [:]).isError)
    }

    @Test func limitClamped() async throws {
        let h = handler()
        let big = try json(try await call(h, "top_processes", ["sort_by": "energy", "limit": 10_000]).text)
        #expect(((big["processes"] as? [Any])?.count ?? 99) <= 50)
        let zero = try json(try await call(h, "top_processes", ["sort_by": "cpu", "limit": 0]).text)
        #expect((zero["processes"] as? [Any])?.count == 1)
        #expect(try await call(h, "top_processes", ["sort_by": "shoe size"]).isError)
        let ev = try await call(handler(store: try historyStore()), "get_events", ["hours": 100_000])
        #expect(!ev.isError)
    }

    @Test func unknownToolIsError() async throws {
        let r = try json(await handler().handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"format_disk","arguments":{}}}"#))
        let e = try #require(r["error"] as? [String: Any])
        #expect(e["code"] as? Int == -32602)
        let m = try json(await handler().handle(line: #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#))
        #expect((m["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func malformedLineIsParseError() async throws {
        let h = handler()
        let r = try json(await h.handle(line: "{not json"))
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(r["id"] is NSNull)
        let bad = try json(await h.handle(line: "[1,2]"))
        #expect((bad["error"] as? [String: Any])?["code"] as? Int == -32600)
        let next = try json(await h.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#))
        #expect(next["result"] != nil)
        #expect(await h.handle(line: "   ") == nil)
    }

    @Test func noHistoryMessage() async throws {
        let h = handler(store: nil)
        let hist = try await call(h, "get_history", ["metric": "cpu.total_pct", "minutes": 10])
        #expect(hist.text == "No history yet. Is MacMonitor running?")
        #expect(try await call(h, "get_events", ["hours": 1]).text == "No history yet. Is MacMonitor running?")
        let snap = try json(try await call(h, "get_snapshot").text)
        #expect((snap["cpu"] as? [String: Any])?["total_pct"] as? Double == 42)
        #expect((snap["source"] as? String)?.contains("live") == true)
        let why = try json(try await call(h, "why_fan").text)
        #expect(why["headline"] as? String != nil)
        let sensors = try json(try await call(h, "get_sensors", ["group": "battery"]).text)
        #expect((sensors["sensors"] as? [[String: Any]])?.count == 1)
    }

    @Test func freshAppSnapshotIsUsed() async throws {
        let st = try HistoryStore(path: tempDBURL(), readOnly: false)
        var s = sampleSnapshot(ts: Date())
        s.cpu.totalPct = 77
        try st.write(s)
        let snap = try json(try await call(handler(store: st), "get_snapshot").text)
        #expect((snap["cpu"] as? [String: Any])?["total_pct"] as? Double == 77)
        #expect((snap["source"] as? String)?.contains("MacMonitor app") == true)
    }

    @Test func noSerialsInHardwareHealth() async throws {
        let r = try await call(handler(), "get_hardware_health")
        #expect(!r.isError)
        #expect(!r.text.lowercased().contains("serial"))
        let body = try json(r.text)
        let battery = try #require(body["battery"] as? [String: Any])
        #expect(battery["system_settings_max_capacity_pct"] as? Int == 84)
        #expect(battery["raw_capacity_vs_design_pct"] as? Double == 81.6)
        #expect(battery["macos_battery_flag"] as? String == "Check Battery")
        #expect((body["ssd"] as? [String: Any])?["percent_used"] as? Int == 25)
        let snapText = try await call(handler(), "get_snapshot").text.lowercased()
        #expect(!snapText.contains("serial"))
    }

    @Test func listMetricsMatchesCatalog() async throws {
        let body = try json(try await call(handler(), "list_metrics").text)
        #expect((body["metrics"] as? [[String: Any]])?.count == MetricCatalog.all.count)
    }
}
