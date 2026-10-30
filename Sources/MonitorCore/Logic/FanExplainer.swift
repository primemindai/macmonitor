import Foundation

/// "Why is my fan on?" These are our rules built on the readings (research report and spec section 8),
/// not Apple's fan curve.
public enum FanExplainer {
    /// Window the heat source and causes are averaged over.
    public static let windowSeconds: TimeInterval = 60
    /// A target drop larger than this over 10 s counts as "ramping down".
    public static let fallingTrendRPM: Double = 20

    public static func state(actual: Double, target: Double, targetTrend10s: Double) -> FanState {
        if actual < 100 { return .off }
        if target - actual > 50 { return .rampingUp }
        if actual - target > 50 || targetTrend10s < -fallingTrendRPM { return .rampingDown }
        return .steady
    }

    /// Title of the fan card. It follows the fan state, so it never says "on" above "Fan at 0 RPM, off."
    public static func title(_ x: FanExplanation?) -> String {
        switch x?.state {
        case nil: return "What the fan is doing"
        case .off?: return "Fan is off"
        case .rampingUp?, .rampingDown?, .steady?: return "Why the fan is on"
        }
    }

    /// Change in the fan's target over the last 10 s of the window (0 when there is no older reading).
    public static func targetTrend10s(window: [Snapshot], fanIndex: Int) -> Double {
        guard let last = window.last, let now = last.fan(fanIndex)?.targetRPM else { return 0 }
        let cutoff = last.ts.addingTimeInterval(-10)
        guard let old = window.last(where: { $0.ts <= cutoff })?.fan(fanIndex)?.targetRPM else { return 0 }
        return now - old
    }

    public static func explain(window all: [Snapshot]) -> FanExplanation? {
        guard let last = all.last else { return nil }
        let window = all.filter { $0.ts >= last.ts.addingTimeInterval(-windowSeconds) && $0.ts <= last.ts }
        // The loudest fan speaks for the Mac.
        guard let fan = last.fans.filter({ $0.actualRPM != nil }).max(by: { $0.actualRPM! < $1.actualRPM! }),
              let actual = fan.actualRPM else { return nil }
        let target = fan.targetRPM ?? actual
        let trend = targetTrend10s(window: window, fanIndex: fan.index)
        let st = state(actual: actual, target: target, targetTrend10s: trend)

        // Heat source: average power per block over the window.
        func avg(_ f: (PowerBreakdown) -> Double?) -> Double? {
            let v = window.compactMap { $0.power.breakdown.flatMap(f) }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let blocks: [(String, Double?)] = [
            ("P cores", avg { b in [b.pCluster0W, b.pCluster1W].compactMap { $0 }.isEmpty ? nil : (b.pCluster0W ?? 0) + (b.pCluster1W ?? 0) }),
            ("E cores", avg { $0.eClusterW }),
            ("GPU", avg { $0.gpuW }),
            ("Neural Engine", avg { $0.aneW }),
            ("Memory", avg { b in [b.dramW, b.memSystemW].compactMap { $0 }.isEmpty ? nil : (b.dramW ?? 0) + (b.memSystemW ?? 0) }),
        ]
        let known = blocks.compactMap { n, w in w.map { (n, $0) } }
        let chip = known.reduce(0) { $0 + $1.1 }
        let top = known.max { $0.1 < $1.1 }
        let sourceBlock = top?.0 ?? "Unknown"
        let sourceW = top?.1 ?? 0
        let share = chip > 0 ? 100 * sourceW / chip : 0

        // Who: average each process over the process samples in the window.
        var sums: [Int32: (name: String, w: [Double], gpu: [Double], cpu: [Double])] = [:]
        var seen = Set<Date>()
        for s in window {
            guard let at = s.processesAt, seen.insert(at).inserted else { continue }
            for p in s.topProcesses {
                var e = sums[p.pid] ?? (p.name, [], [], [])
                if let w = p.energyW { e.w.append(w) }
                if let g = p.gpuPercent { e.gpu.append(g) }
                if let c = p.cpuPercent { e.cpu.append(c) }
                sums[p.pid] = e
            }
        }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        var causes: [Cause]
        if sourceBlock == "GPU" {
            causes = sums.values.compactMap { e in mean(e.gpu).flatMap { $0 >= 0.5 ? Cause(name: e.name, gpuPercent: $0) : nil } }
                .sorted { ($0.gpuPercent ?? 0) > ($1.gpuPercent ?? 0) }
        } else {
            causes = sums.values.compactMap { e in mean(e.w).flatMap { $0 >= 0.05 ? Cause(name: e.name, watts: $0) : nil } }
                .sorted { ($0.watts ?? 0) > ($1.watts ?? 0) }
            if causes.isEmpty {
                causes = sums.values.compactMap { e in mean(e.cpu).flatMap { $0 >= 5 ? Cause(name: e.name, cpuPercent: $0) : nil } }
                    .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
            }
        }
        causes = Array(causes.prefix(5))

        // Chip cool but fan on: look elsewhere.
        let cpuGpu = (avg { $0.cpuW } ?? ((known.first { $0.0 == "P cores" }?.1 ?? 0) + (known.first { $0.0 == "E cores" }?.1 ?? 0)))
            + (known.first { $0.0 == "GPU" }?.1 ?? 0)
        var fallback: String?
        if st != .off, cpuGpu < 5 {
            var why: [String] = []
            if last.battery?.isCharging == true || (last.battery?.chargingCurrentMA ?? 0) > 0 { why.append("the battery is charging") }
            if let ssd = last.thermal.ssdC, ssd >= 55 { why.append("the SSD is at \(Int(ssd.rounded())) C") }
            if let lid = last.lidAngle, lid < 10 { why.append("the lid is closed") }
            if let palm = last.thermal.palmRestC, palm >= 38 { why.append("the palm rest is at \(Int(palm.rounded())) C") }
            if let amb = last.thermal.ambientC, amb >= 32 { why.append("the room or case air is warm (\(Int(amb.rounded())) C)") }
            fallback = why.isEmpty
                ? "CPU and GPU power is low, so the fan is likely still cooling down from earlier work."
                : "CPU and GPU power is low, so other heat is likely: \(why.joined(separator: ", "))."
        }

        let words: String
        switch st {
        case .off: words = "off"
        case .rampingUp: words = "ramping up toward \(rpm(target))"
        case .rampingDown: words = "slowly falling"
        case .steady: words = "steady"
        }
        var headline = "Fan at \(rpm(actual)) RPM, \(words)."
        if chip > 0 {
            headline += " \(sourceBlock) used \(watts(sourceW)) W over the last minute (\(Int(share.rounded()))% of chip power)."
        }
        let named = causes.prefix(2).compactMap { c -> String? in
            if let w = c.watts { return "\(c.name) \(watts(w)) W" }
            if let g = c.gpuPercent { return "\(c.name) \(Int(g.rounded()))% GPU" }
            if let p = c.cpuPercent { return "\(c.name) \(Int(p.rounded()))% CPU" }
            return nil
        }
        if !named.isEmpty { headline += " Top: \(named.joined(separator: ", "))." }
        if let fallback { headline += " " + fallback }

        var readings: [String: Double] = [
            "fan.rpm": actual, "fan.target_rpm": target, "fan.target_trend_10s": trend,
            "power.chip_w_60s": chip, "source.share_pct": share, "window.seconds": window.count > 1
                ? window.last!.ts.timeIntervalSince(window.first!.ts) : 0,
        ]
        for (n, w) in known { readings["power.\(n.lowercased().replacingOccurrences(of: " ", with: "_"))_w_60s"] = w }
        if let t = last.thermal.hottestC { readings["temp.hottest_c"] = t }

        return FanExplanation(headline: headline, state: st, headingToRPM: target, sourceBlock: sourceBlock,
                              sourceShare: share, topCauses: causes, readings: readings, fallbackReason: fallback)
    }

    static func rpm(_ v: Double) -> String {
        let n = Int(v.rounded())
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func watts(_ w: Double) -> String { w >= 10 ? String(format: "%.0f", w) : String(format: "%.1f", w) }
}
