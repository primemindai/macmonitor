import Foundation

/// The MacMonitor MCP protocol handler: newline-delimited JSON-RPC 2.0 over stdio, eight read-only tools.
/// It never writes files and never touches the network. History is read from the app's database read only.
public final class MCPHandler: @unchecked Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let noHistory = "No history yet. Is MacMonitor running?"
    /// The app's latest row is used when it is younger than this; otherwise we sample live.
    public static let freshSeconds: TimeInterval = 3

    private let store: () -> HistoryStore?
    private let live: () async -> Snapshot

    public init(store: @escaping () -> HistoryStore?, live: @escaping () async -> Snapshot) {
        self.store = store
        self.live = live
    }

    /// Handles one line. Returns the response line, or nil for notifications and blank lines.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return JSONRPC.error(id: NSNull(), code: JSONRPC.parseError, "Parse error: the line is not valid JSON.")
        }
        guard let req = obj as? [String: Any], let method = req["method"] as? String else {
            let id = (obj as? [String: Any])?["id"] ?? NSNull()
            return JSONRPC.error(id: id, code: JSONRPC.invalidRequest, "Invalid request: expected an object with a method.")
        }
        guard let id = req["id"], !(id is NSNull) else { return nil }  // a notification gets no reply
        let params = req["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return JSONRPC.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "macmonitor", "version": "1.0.0"],
                "instructions": "Read-only view of this Mac's hardware: heat, fans, power, memory, disks, battery and apps. Start with get_snapshot or why_fan.",
            ])
        case "ping":
            return JSONRPC.result(id: id, [:])
        case "tools/list":
            return JSONRPC.result(id: id, ["tools": MCPTools.list])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return JSONRPC.error(id: id, code: JSONRPC.invalidParams, "tools/call needs a tool name.")
            }
            guard MCPTools.names.contains(name) else {
                return JSONRPC.error(id: id, code: JSONRPC.invalidParams, "Unknown tool: \(name). Call tools/list for the tools.")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let out = await runTool(name, args)
            return JSONRPC.result(id: id, ["content": [["type": "text", "text": out.text]], "isError": out.isError])
        default:
            return JSONRPC.error(id: id, code: JSONRPC.methodNotFound, "Method not found: \(method)")
        }
    }

    // MARK: tools

    private func intArg(_ a: [String: Any], _ k: String, default d: Int, range: ClosedRange<Int>) -> Int {
        let raw: Int
        if let n = a[k] as? NSNumber { raw = n.doubleValue.isFinite ? Int(max(-1e9, min(1e9, n.doubleValue))) : d }
        else if let s = a[k] as? String, let n = Int(s) { raw = n }
        else { raw = d }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private func openStore() -> HistoryStore? { store() }

    /// The app's latest snapshot if fresh, otherwise a live sample.
    private func current() async -> (Snapshot, String) {
        if let st = openStore(), let l = try? st.latest() {
            let age = Date().timeIntervalSince(l.ts)
            if age >= -1 && age < Self.freshSeconds {
                return (l, String(format: "MacMonitor app, %.1f s old", max(0, age)))
            }
        }
        return (await live(), "live sample (the MacMonitor app is not writing fresh data)")
    }

    private func runTool(_ name: String, _ a: [String: Any]) async -> (text: String, isError: Bool) {
        switch name {
        case "get_snapshot":
            let (s, src) = await current()
            return (JSONRPC.pretty(Report.snapshot(s, source: src)), false)

        case "list_metrics":
            return (JSONRPC.pretty(["metrics": MetricCatalog.all.map { ["name": $0.name, "unit": $0.unit, "description": $0.description] }]), false)

        case "get_history":
            guard let metric = a["metric"] as? String, !metric.isEmpty else {
                return ("get_history needs a metric name. Call list_metrics for the names.", true)
            }
            guard let m = MetricCatalog.metric(named: metric) else {
                return ("Unknown metric \(metric). Call list_metrics for the names.", true)
            }
            let minutes = intArg(a, "minutes", default: 60, range: 1...43_200)
            var resolution = (a["resolution"] as? String) ?? "auto"
            guard ["auto", "1s", "1m"].contains(resolution) else {
                return ("resolution must be auto, 1s or 1m.", true)
            }
            // 1 s rows are kept 24 hours; a wider window can only come from per-minute averages, and the reply says so.
            var resolutionNote: String?
            if resolution == "1s" && minutes > 1_440 {
                resolutionNote = "1s history is kept 24 hours, so this window returns per-minute averages."
                resolution = "1m"
            }
            if resolution == "auto" { resolution = minutes <= 1_440 ? "1s" : "1m" }
            guard let st = openStore() else { return (Self.noHistory, false) }
            let to = Date(), from = to.addingTimeInterval(-Double(minutes) * 60)
            var pts: [(Date, Double)]
            do {
                if resolution == "1s" {
                    pts = try st.series(metric: metric, from: from, to: to)
                } else {
                    pts = try st.seriesMinute(metric: metric, from: from, to: to).compactMap { r in r.avg.map { (r.ts, $0) } }
                }
            } catch {
                return ("\(error)", true)
            }
            let total = pts.count
            let down = total > 2_000
            if down { pts = Self.downsample(pts, to: 2_000) }
            var body: [String: Any] = [
                "metric": metric, "unit": m.unit, "description": m.description, "resolution": resolution,
                "minutes": minutes, "from": Report.iso(from), "to": Report.iso(to), "count": pts.count,
                "points_unix_s_value": pts.map { [Int($0.0.timeIntervalSince1970), Report.v($0.1)] },
                "downsampled_from": down ? total : NSNull(),
            ]
            if let resolutionNote { body["resolution_note"] = resolutionNote }
            if pts.isEmpty { body["note"] = "No history in that window yet. Is MacMonitor running?" }
            return (JSONRPC.pretty(body), false)

        case "top_processes":
            let sortBy = (a["sort_by"] as? String) ?? "cpu"
            let keys: [String: (ProcSample) -> Double?] = [
                "cpu": { $0.cpuPercent }, "memory": { $0.memBytes.map { Double($0) } }, "energy": { $0.energyW },
                "gpu": { $0.gpuPercent }, "disk": { p in
                    p.diskReadBps == nil && p.diskWriteBps == nil ? nil : (p.diskReadBps ?? 0) + (p.diskWriteBps ?? 0)
                },
            ]
            guard let key = keys[sortBy] else { return ("sort_by must be one of cpu, memory, energy, gpu, disk.", true) }
            let limit = intArg(a, "limit", default: 10, range: 1...50)
            let (s, src) = await current()
            let rows = s.topProcesses.filter { key($0) != nil }.sorted { key($0)! > key($1)! }.prefix(limit)
            var body: [String: Any] = ["sort_by": sortBy, "limit": limit, "source": src, "processes": rows.map(Report.process)]
            if sortBy == "energy" {
                body["note"] = "Watts come from macOS energy counters and exist only for your own processes. Root processes show energy_impact_score from top (no unit) when top has run."
            }
            return (JSONRPC.pretty(body), false)

        case "why_fan":
            let (s, src) = await current()
            guard let x = s.fanExplanation else {
                return ("No fan reading is available on this Mac right now (SMC fans not found).", false)
            }
            var body = Report.why(x)
            body["source"] = src
            if src.hasPrefix("live") {
                body["window_note"] = "Live sample covers about one second. The app's headline uses a full minute."
            }
            return (JSONRPC.pretty(body), false)

        case "get_events":
            let hours = intArg(a, "hours", default: 24, range: 1...720)
            let kind = a["kind"] as? String
            guard let st = openStore() else { return (Self.noHistory, false) }
            do {
                let ev = try st.events(since: Date().addingTimeInterval(-Double(hours) * 3600), kind: kind)
                return (JSONRPC.pretty([
                    "hours": hours, "kind": kind ?? NSNull(), "count": ev.count,
                    "events": ev.prefix(500).map { ["time": Report.iso($0.ts), "kind": $0.kind, "title": $0.title, "body": $0.body] },
                ]), false)
            } catch {
                return ("\(error)", true)
            }

        case "get_sensors":
            var (s, src) = await current()
            if s.thermal.allSensors.isEmpty {
                s = await live()
                src = "live sample"
            }
            return (JSONRPC.pretty(Self.sensorsBody(s, source: src, group: a["group"] as? String)), false)

        case "get_hardware_health":
            let (s, src) = await current()
            return (JSONRPC.pretty([
                "source": src,
                "ssd": s.disks.smart.map(Report.smart) ?? NSNull(),
                "battery": s.battery.map(Report.battery) ?? NSNull(),
                "display": s.display.map { d in ["nits": Report.v(d.nits), "brightness_0_to_1": Report.v(d.brightness), "refresh_hz": Report.v(d.refreshHz)] as [String: Any] } ?? NSNull(),
                "lid_angle_deg": Report.v(s.lidAngle),
                "privacy_note": "MacMonitor does not keep or show hardware ID numbers.",
            ]), false)

        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// The get_sensors reply for one snapshot.
    static func sensorsBody(_ s: Snapshot, source src: String, group groupArg: String?) -> [String: Any] {
        let group = groupArg?.lowercased()
        let rows = s.thermal.allSensors.filter { group == nil || $0.group.lowercased().contains(group!) }
        let gaps = (s.thermal.notReporting ?? []).filter { group == nil || $0.group.lowercased().contains(group!) }
        let groups = Array(Set(s.thermal.allSensors.map(\.group) + (s.thermal.notReporting ?? []).map(\.group))).sorted()
        let lastReal = s.thermal.cpuPLastRealAt.map { max(0, s.ts.timeIntervalSince($0)) }
        return [
            "source": src, "count": rows.count, "groups": groups,
            "read_s_ago": Report.v(s.thermal.allSensorsAt.map { max(0, s.ts.timeIntervalSince($0)) }, 10),
            "not_reporting": gaps.map { ["group": $0.group, "reason": $0.reason,
                                         "last_real_s_ago": $0.group == "P cores" ? Report.v(lastReal, 10) : NSNull()] as [String: Any] },
            "label_note": "label_proven false means the label is a best guess from the SMC key name.",
            "sensors": rows.map { ["source": $0.source, "key": $0.key, "label": $0.group, "label_proven": $0.proven,
                               "celsius": Report.v($0.celsius, 100)] as [String: Any] },
            "limit_keys_raw": s.thermal.limitKeys.mapValues { Report.v($0) },
        ]
    }

    /// Averages points into `n` equal time buckets.
    static func downsample(_ pts: [(Date, Double)], to n: Int) -> [(Date, Double)] {
        guard pts.count > n, n > 0 else { return pts }
        let size = Double(pts.count) / Double(n)
        return (0..<n).compactMap { i in
            let lo = Int(Double(i) * size), hi = min(pts.count, Int(Double(i + 1) * size))
            guard hi > lo else { return nil }
            let slice = pts[lo..<hi]
            return (slice[slice.startIndex].0, slice.reduce(0) { $0 + $1.1 } / Double(slice.count))
        }
    }
}

enum MCPTools {
    static let names: Set<String> = Set(list.compactMap { $0["name"] as? String })

    nonisolated(unsafe) static let list: [[String: Any]] = [
        tool("get_snapshot", "Everything MacMonitor reads right now, grouped by area (cpu, gpu, memory, power, thermal, fans, disks, network, battery, display, top processes, fan explanation). Units are in the key names.", [:]),
        tool("get_history", "History of one metric. Call list_metrics for names. Up to 24 hours at 1 second detail, up to 30 days at 1 minute averages.", [
            "metric": ["type": "string", "description": "Metric name, for example temp.hottest_c"],
            "minutes": ["type": "integer", "description": "How far back, 1 to 43200 (30 days). Default 60.", "minimum": 1, "maximum": 43_200],
            "resolution": ["type": "string", "enum": ["auto", "1s", "1m"], "description": "auto picks 1s up to 24 hours, else 1m."],
        ], required: ["metric"]),
        tool("list_metrics", "Names, units and descriptions of the metrics get_history accepts.", [:]),
        tool("top_processes", "Top processes right now. Energy in watts exists only for your own processes.", [
            "sort_by": ["type": "string", "enum": ["cpu", "memory", "energy", "gpu", "disk"], "description": "Default cpu."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "1 to 50. Default 10."],
        ]),
        tool("why_fan", "Why the fan is on: a one-line headline plus the readings behind it (fan state, hottest block, top processes).", [:]),
        tool("get_events", "Events log: fan ramps, thermal pressure, throttle signs, memory pressure, swap, disk, SSD heat, battery flag, wake.", [
            "hours": ["type": "integer", "minimum": 1, "maximum": 720, "description": "How far back, 1 to 720. Default 24."],
            "kind": ["type": "string", "description": "Optional: fan_ramp, thermal_pressure, throttle, memory_pressure, swap_high, disk_low, ssd_hot, battery_flag, wake"],
        ]),
        tool("get_sensors", "All temperature sensors with source (SMC or HID), key, label and whether the label is proven.", [
            "group": ["type": "string", "description": "Optional filter on the label, for example battery, gpu, p cores."],
        ]),
        tool("get_hardware_health", "SSD wear (NVMe SMART), battery health in three labeled views, power adapter, display. No hardware ID numbers.", [:]),
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema,
                "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }
}
