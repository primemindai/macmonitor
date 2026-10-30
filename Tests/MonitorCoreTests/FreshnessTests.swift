import Testing
import Foundation
@testable import MonitorCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Review B1: one `top` run was reused forever.
@Suite struct TopFreshnessTests {
    @Test func freshTopIsUsed() {
        let r = TopReading(at: t0, procs: [0: (cpu: 60, power: 0), 395: (cpu: 40, power: 41)])
        let k = SampleEngine.kernelTask(from: r, now: t0.addingTimeInterval(10))
        #expect(k.pct == 60)
        #expect(k.at == t0)
        #expect(r.fresh(now: t0.addingTimeInterval(10))?[395]?.cpu == 40)
    }

    @Test func staleTopGivesNil() {
        let r = TopReading(at: t0, procs: [0: (cpu: 60, power: 0), 395: (cpu: 40, power: 41)])
        let k = SampleEngine.kernelTask(from: r, now: t0.addingTimeInterval(21))
        #expect(k.pct == nil)
        #expect(k.at == nil)
        // Root processes then keep their ps CPU: the sampler gets no top table.
        #expect(r.fresh(now: t0.addingTimeInterval(21)) == nil)
    }

    @Test func staleTopLeavesRootProcessesOnPS() {
        let sampler = ProcessSampler(reader: { [] }, clock: { 0 })
        let r = TopReading(at: t0, procs: [395: (cpu: 99, power: 99)])
        let ps: [Int32: (cpu: Double, rssBytes: UInt64, name: String)] = [395: (cpu: 12, rssBytes: 1_000, name: "WindowServer")]
        let out = sampler.sample(gpuNs: [:], top: r.fresh(now: t0.addingTimeInterval(60)), ps: ps)
        #expect(out.first { $0.pid == 395 }?.cpuPercent == 12)
    }
}

/// Review B1: the 30 s throttle window counted ticks, not fresh readings.
@Suite struct ThrottleFreshnessTests {
    private func snap(_ t: Double, pct: Double?, at: Double?) -> Snapshot {
        var s = Snapshot.empty(ts: t0.addingTimeInterval(t))
        s.cpu.kernelTaskPct = pct
        s.cpu.kernelTaskAt = at.map { t0.addingTimeInterval($0) }
        return s
    }
    private func fired(_ r: [(event: MonitorEvent, notify: Bool)]) -> Bool { r.contains { $0.event.kind == "throttle" } }

    @Test func oneReadingRepeatedNeverFires() {
        let d = EventDetector(settings: AlertSettings())
        for i in 0...40 { #expect(!fired(d.ingest(snap(Double(i), pct: 80, at: 0))), "tick \(i)") }
    }

    @Test func freshReadingsSpanning30sFire() {
        let d = EventDetector(settings: AlertSettings())
        var any = false
        for i in 0...30 {
            let at = Double(i / 15 * 15)    // a new top reading every 15 s
            let f = fired(d.ingest(snap(Double(i), pct: 80, at: at)))
            if i < 30 { #expect(!f, "tick \(i)") } else { any = f }
        }
        #expect(any)
    }

    @Test func readingsTooFarApartDoNotCount() {
        let d = EventDetector(settings: AlertSettings())
        #expect(!fired(d.ingest(snap(0, pct: 80, at: 0))))
        #expect(!fired(d.ingest(snap(120, pct: 80, at: 120))))
    }
}

/// Review B2: SMC P core placeholders (exactly 0 or exactly 40.000 on every Tp key) stored as temperatures.
@Suite struct PCorePlaceholderTests {
    private func reading(p: Double, te: Double = 64) -> [String: Double] {
        var v: [String: Double] = [:]
        for k in SMCKeys.pCoreTemps { v[k] = p }
        v["Te06"] = te
        return v
    }

    @Test func allFortyIsNoReading() {
        var hold = PCoreHold()
        let out = hold.apply(reading(p: 40), now: t0)
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, out.values, slow: [:])
        #expect(s.thermal.cpuPC == nil)
        #expect(s.thermal.hottestC == 64)
        #expect(!s.thermal.fastSensors.contains { $0.celsius == 40 })
    }

    @Test func allZeroIsNoReading() {
        var hold = PCoreHold()
        let out = hold.apply(reading(p: 0), now: t0)
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, out.values, slow: [:])
        #expect(s.thermal.cpuPC == nil)
        #expect(out.heldSeconds == nil)
    }

    @Test func holdsLastRealValueWithItsAge() {
        var hold = PCoreHold()
        var real = reading(p: 80); real["Tp06"] = 86
        let a = hold.apply(real, now: t0)
        #expect(a.heldSeconds == nil)
        let b = hold.apply(reading(p: 40), now: t0.addingTimeInterval(3))
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, b.values, slow: [:])
        #expect(s.thermal.cpuPC == 86)
        #expect(s.thermal.hottestC == 86)   // hottest does not drop on a placeholder flip
        #expect(b.heldSeconds == 3)
    }

    @Test func holdExpires() {
        var hold = PCoreHold()
        _ = hold.apply(reading(p: 85), now: t0)
        let b = hold.apply(reading(p: 0), now: t0.addingTimeInterval(PCoreHold.maxHold + 1))
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, b.values, slow: [:])
        #expect(s.thermal.cpuPC == nil)
        #expect(b.heldSeconds == nil)
    }

    @Test func tinyJunkIsNotATemperature() {
        #expect(!SensorRules.isReal(2))
        #expect(!SensorRules.isReal(5))
        #expect(!SensorRules.isReal(0))
        #expect(SensorRules.isReal(31))
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, ["Te06": 2, "Tg05": 57], slow: [:])
        #expect(s.thermal.cpuEC == nil)
        #expect(!s.thermal.fastSensors.contains { $0.key == "Te06" })
    }
}

/// Review round 2 (R2-B1): live reads are often mixed, some Tp keys at exactly 40.000 next to real ones.
@Suite struct MixedPlaceholderTests {
    @Test func mixedFastReadDropsEachPlaceholderKey() {
        var hold = PCoreHold()
        var v: [String: Double] = ["Te06": 64]
        for k in SMCKeys.pCoreTemps { v[k] = 40 }
        v["Tp06"] = 86
        v["Tp0E"] = 0
        let out = hold.apply(v, now: t0)
        #expect(out.heldSeconds == nil)            // a real P core key remains, so nothing is held
        #expect(out.values["Tp06"] == 86)
        #expect(!SMCKeys.pCoreTemps.contains { out.values[$0] == 40 || out.values[$0] == 0 })
        var s = Snapshot.empty(ts: t0)
        SampleEngine.fillSMC(&s, out.values, slow: [:])
        #expect(s.thermal.cpuPC == 86)
        #expect(!s.thermal.fastSensors.contains { $0.key.hasPrefix("Tp") && $0.celsius == 40 })
    }

    @Test func mixedSlowListDropsEachPlaceholderKey() {
        let raw: [String: Double] = ["Tp01": 40, "Tp05": 75.5, "Tp09": 40, "Tp1h": 0, "Tp2W": 81, "Te06": 64, "TB0T": 31]
        let out = PCoreHold.dropPlaceholders(raw) { $0.hasPrefix("Tp") }
        #expect(out.keys.sorted() == ["TB0T", "Te06", "Tp05", "Tp2W"])
    }

    @Test func fortyOnNonPCoreKeysIsKept() {
        // The rule is only for Tp keys; another sensor at exactly 40.0 stays.
        let out = PCoreHold.dropPlaceholders(["Tp05": 75, "TB0T": 40]) { $0.hasPrefix("Tp") }
        #expect(out["TB0T"] == 40)
    }
}
