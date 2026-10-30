import Testing
import Foundation
@testable import MonitorCore

@Suite struct HostStatsTests {
    @Test func cpuPercent() {
        let prev = CPUTicks(user: 10, system: 10, idle: 80, nice: 0)
        let cur = CPUTicks(user: 30, system: 20, idle: 110, nice: 0)
        #expect(CPUMath.percent(prev: prev, cur: cur) == 50.0)
    }

    @Test func cpuTicksWentBackwardsIsNil() {
        let prev = CPUTicks(user: 30, system: 20, idle: 110, nice: 0)
        let cur = CPUTicks(user: 10, system: 25, idle: 120, nice: 0)
        #expect(CPUMath.percent(prev: prev, cur: cur) == nil)
        #expect(CPUMath.percent(prev: prev, cur: prev) == nil) // no time passed
    }

    @Test func counterRateNormal() {
        #expect(Counter.rate(prev: 1_000, cur: 3_000, seconds: 2) == 1_000)
    }

    @Test func counterResetIsNil() {
        #expect(Counter.rate(prev: 3_000, cur: 1_000, seconds: 1) == nil)
        #expect(Counter.rate(prev: 1_000, cur: 3_000, seconds: 0) == nil)
        #expect(Counter.rate(prev: 1_000, cur: 3_000, seconds: -1) == nil)
    }

    @Test func longGapIsNil() {
        #expect(Counter.rate(prev: 1_000, cur: 3_000, seconds: 30.5) == nil)
        #expect(Counter.rate(prev: 1_000, cur: 3_000, seconds: 30) == 2_000.0 / 30)
    }

    @Test(.tags(.live)) func coreKindsMatchThisMac() {
        let k = HostStats.coreKinds()
        #expect(k.count == 14)
        #expect(Array(k.prefix(4)) == Array(repeating: CoreKind.efficiency, count: 4))
        #expect(Array(k.suffix(10)) == Array(repeating: CoreKind.performance, count: 10))
        #expect(HostStats.coreTicks().count == 14)
    }

    @Test(.tags(.live)) func memoryAddsUp() throws {
        let m = HostStats.memory()
        let used = try #require(m.usedBytes), total = try #require(m.totalBytes)
        #expect(used > 0 && used <= total)
        let su = try #require(m.swapUsed), st = try #require(m.swapTotal)
        #expect(su <= st)
        #expect(m.pressureLevel != nil)
        // kern.waketime is 0 until the Mac sleeps once after boot, so nil is valid then (review S1).
        // A real wake time must be after boot and not in the future.
        if let wake = HostStats.wakeTime() {
            let boot = try #require(HostStats.bootTime())
            #expect(wake >= boot)
            #expect(wake <= Date())
        }
        let th = HostStats.thermal()
        #expect((0...4).contains(th.pressure))
    }

    @Test(.tags(.live)) func liveNetDiskReaders() {
        let t0 = Date()
        let ifs = NetDisk.interfaces()
        let blk = NetDisk.blockStats()
        let vols = NetDisk.volumes()
        let wifi = NetDisk.wifi()
        print(String(format: "net+disk cost %.1f ms", Date().timeIntervalSince(t0) * 1000))
        print("ifaces:", ifs.keys.sorted(), "disks:", blk.keys.sorted(), "vols:", vols.map(\.name), "wifi:", wifi as Any)
        #expect(ifs["lo0"] != nil)
        #expect(!blk.isEmpty)
        #expect(vols.contains { $0.path == "/" })
    }
}
