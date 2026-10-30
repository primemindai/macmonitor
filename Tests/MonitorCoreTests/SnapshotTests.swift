import Testing
import Foundation
@testable import MonitorCore

/// A filled-in snapshot for tests.
func sampleSnapshot(ts: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> Snapshot {
    var s = Snapshot.empty(ts: ts)
    s.cpu.totalPct = 42
    s.cpu.pPct = 55
    s.cpu.ePct = 10
    s.cpu.perCorePct = [10, 12, nil, 8, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69]
    s.gpu.utilPct = 41
    s.gpu.mhz = 338
    var m = MemoryInfo()
    m.usedBytes = 30_000_000_000
    m.totalBytes = 48 * 1_073_741_824
    m.swapUsed = 1
    m.swapTotal = 2
    m.pressureLevel = 1
    s.memory = m
    s.power.breakdown = PowerBreakdown(pCluster0W: 11.7, pCluster1W: 11.4, eClusterW: 0.5, gpuW: 1.7, aneW: 0, dramW: 2.2, memSystemW: 5.5, cpuW: 23.7)
    s.power.systemW = 60.2
    s.thermal.pressure = 1
    s.thermal.hottestC = 101.8
    s.fans = [FanInfo(index: 0, actualRPM: 4_970, targetRPM: 4_951, minRPM: 2_317, maxRPM: 7_826, duty: 0.386, state: .steady)]
    s.network = [NetInfo(name: "en8", rxBps: 1_000, txBps: 500, baud: 1_000_000_000)]
    s.topProcesses = [ProcSample(pid: 10, name: "Python", cpuPercent: 39.4, energyW: 1.46, isOwn: true)]
    s.fanExplanation = FanExplanation(headline: "Fan at 4,970 RPM, steady.", state: .steady, headingToRPM: 4_951,
                                      sourceBlock: "P cores", sourceShare: 85, topCauses: [Cause(name: "Python", watts: 1.46)],
                                      readings: ["fan0.rpm": 4_970], fallbackReason: nil)
    return s
}

@Suite struct SnapshotTests {
    @Test func catalogNamesUniqueAndDotted() {
        let names = MetricCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count >= 35)
        for n in names {
            #expect(n.range(of: #"^[a-z0-9_]+\.[a-z0-9_]+$"#, options: .regularExpression) != nil, "bad name \(n)")
        }
        for m in MetricCatalog.all { #expect(!m.unit.isEmpty && !m.description.isEmpty) }
        for required in ["cpu.total_pct", "gpu.util_pct", "power.system_w", "temp.hottest_c", "fan0.rpm", "mem.used_bytes",
                         "net.rx_bps", "disk.write_bps", "thermal.pressure", "battery.pct"] {
            #expect(MetricCatalog.metric(named: required) != nil, "missing \(required)")
        }
    }

    @Test func snapshotRoundTrips() throws {
        let s = sampleSnapshot()
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(back == s)
    }

    @Test func extractReturnsNilForMissingSource() throws {
        let empty = Snapshot.empty(ts: Date())
        let gpu = try #require(MetricCatalog.metric(named: "gpu.util_pct"))
        #expect(gpu.extract(empty) == nil)
        #expect(try #require(MetricCatalog.metric(named: "fan1.rpm")).extract(empty) == nil)
        #expect(try #require(MetricCatalog.metric(named: "power.gpu_w")).extract(empty) == nil)
        let full = sampleSnapshot()
        #expect(gpu.extract(full) == 41)
        #expect(try #require(MetricCatalog.metric(named: "power.p_cluster_w")).extract(full)! - 23.1 < 1e-9)
        #expect(try #require(MetricCatalog.metric(named: "fan0.rpm")).extract(full) == 4_970)
    }

    @MainActor @Test(.tags(.live)) func samplerProducesSnapshot() async throws {
        let s = Sampler()
        s.start(mode: .normal)
        defer { s.stop() }
        var got: Snapshot?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let l = s.latest, l.cpu.totalPct != nil, l.memory.usedBytes != nil { got = l; break }
        }
        let snap = try #require(got)
        #expect(snap.fans.count == 2)
        #expect(snap.power.breakdown?.cpuW != nil)
        #expect(snap.thermal.hottestC != nil)
        // Task 8 wiring: every fan has a state and the headline is filled.
        #expect(snap.fans.allSatisfy { $0.state != nil })
        let why = try #require(snap.fanExplanation)
        print("fan headline:", why.headline)
        #expect(why.headline.hasPrefix("Fan at "))
        let cost = await s.engine.lastTickCost
        print("tick cost:", cost)
    }

    @Test(.tags(.live)) func tickCostMeasured() async throws {
        let e = SampleEngine()
        _ = await e.tick(slow: true, processes: true)   // first tick primes counters and pays one-time costs
        var costs: [TickCost] = []
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(1000))
            _ = await e.tick(slow: false, processes: false)
            costs.append(await e.lastTickCost)
        }
        func avg(_ k: KeyPath<TickCost, Double>) -> Double { costs.map { $0[keyPath: k] }.reduce(0, +) / Double(costs.count) }
        print(String(format: "1 s tick average over 5: total %.2f ms (SMC %.2f, IOReport %.2f, other %.2f)",
                     avg(\.totalMs), avg(\.smcMs), avg(\.ioreportMs), avg(\.otherMs)))
        #expect(avg(\.totalMs) < 100)
    }
}
