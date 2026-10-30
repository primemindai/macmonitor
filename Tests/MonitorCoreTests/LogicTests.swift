import Testing
import Foundation
@testable import MonitorCore

func fanSnap(_ t: Double, actual: Double = 4_600, target: Double = 4_600, p0: Double = 12, p1: Double = 11, e: Double = 1,
             gpu: Double = 2, dram: Double = 1, procs: [ProcSample] = []) -> Snapshot {
    var s = Snapshot.empty(ts: Date(timeIntervalSince1970: t))
    s.fans = [FanInfo(index: 0, actualRPM: actual, targetRPM: target, minRPM: 2_317, maxRPM: 7_826, duty: nil, state: nil)]
    s.power.breakdown = PowerBreakdown(pCluster0W: p0, pCluster1W: p1, eClusterW: e, gpuW: gpu, aneW: 0, dramW: dram, memSystemW: 0,
                                       cpuW: p0 + p1 + e)
    s.topProcesses = procs
    s.processesAt = procs.isEmpty ? nil : s.ts
    return s
}

@Suite struct FanExplainerTests {
    @Test func fanOffBelow100() {
        #expect(FanExplainer.state(actual: 99, target: 0, targetTrend10s: 0) == .off)
        #expect(FanExplainer.state(actual: 0, target: 2_000, targetTrend10s: 0) == .off)
    }

    @Test func rampBand() {
        #expect(FanExplainer.state(actual: 3_000, target: 3_051, targetTrend10s: 0) == .rampingUp)
        #expect(FanExplainer.state(actual: 3_000, target: 3_050, targetTrend10s: 0) == .steady)
        #expect(FanExplainer.state(actual: 3_051, target: 3_000, targetTrend10s: 0) == .rampingDown)
    }

    @Test func fallingTargetTrendIsRampingDown() {
        // Research: target fell about 9 RPM per second while actual tracked it within the band.
        #expect(FanExplainer.state(actual: 4_625, target: 4_590, targetTrend10s: -90) == .rampingDown)
        #expect(FanExplainer.state(actual: 4_625, target: 4_590, targetTrend10s: -5) == .steady)
    }

    @Test func headlineNamesBiggestBlock() throws {
        let py = ProcSample(pid: 1, name: "Python", cpuPercent: 40, energyW: 1.5, isOwn: true)
        let vm = ProcSample(pid: 2, name: "Virtualization", cpuPercent: 60, energyW: 1.6, isOwn: true)
        let window = (0..<60).map { i in fanSnap(1_000 + Double(i), actual: 4_600, target: 4_600 - Double(i) * 9, procs: [py, vm]) }
        let x = try #require(FanExplainer.explain(window: window))
        #expect(x.sourceBlock == "P cores")
        #expect(x.sourceShare.rounded() == 85)
        #expect(x.state == .rampingDown)
        #expect(x.topCauses.map(\.name) == ["Virtualization", "Python"])
        #expect(x.headline == "Fan at 4,600 RPM, slowly falling. P cores used 23 W over the last minute (85% of chip power). Top: Virtualization 1.6 W, Python 1.5 W.")
        #expect(x.readings["power.chip_w_60s"] == 27)
        #expect(x.fallbackReason == nil)
        #expect(!x.headline.contains("\u{2014}"))
    }

    @Test func headlineRampingUpNamesTarget() throws {
        let x = try #require(FanExplainer.explain(window: [fanSnap(1, actual: 3_000, target: 4_200)]))
        #expect(x.headline.hasPrefix("Fan at 3,000 RPM, ramping up toward 4,200."))
        #expect(x.headingToRPM == 4_200)
    }

    @Test func headlineFallbackWhenChipCool() throws {
        var s = fanSnap(1, actual: 3_000, target: 3_000, p0: 0.5, p1: 0.5, e: 0.3, gpu: 0.4, dram: 0.5)
        var b = BatteryInfo(cellVoltagesMV: [], cellResistance: [], pdMenu: [])
        b.isCharging = true
        s.battery = b
        s.thermal.ssdC = 64
        let x = try #require(FanExplainer.explain(window: [s]))
        let r = try #require(x.fallbackReason)
        #expect(r.contains("charging") || r.contains("SSD"))
        #expect(x.headline.contains(r))
    }

    @Test func noFansNoExplanation() {
        #expect(FanExplainer.explain(window: [Snapshot.empty(ts: Date())]) == nil)
        #expect(FanExplainer.explain(window: []) == nil)
    }
}

func evSnap(_ t: Double, target: Double = 2_000, pressure: Int = 0) -> Snapshot {
    var s = Snapshot.empty(ts: Date(timeIntervalSince1970: t))
    s.fans = [FanInfo(index: 0, actualRPM: target, targetRPM: target, minRPM: nil, maxRPM: nil, duty: nil, state: nil)]
    s.thermal.pressure = pressure
    return s
}

@Suite struct EventDetectorTests {
    func notified(_ r: [(event: MonitorEvent, notify: Bool)], _ kind: String) -> Bool { r.contains { $0.event.kind == kind && $0.notify } }
    func logged(_ r: [(event: MonitorEvent, notify: Bool)], _ kind: String) -> Bool { r.contains { $0.event.kind == kind } }

    @Test func fanAlertNeedsQuietPeriod() {
        let short = EventDetector(settings: AlertSettings())
        _ = short.ingest(evSnap(0, target: 2_000))
        let a = short.ingest(evSnap(599, target: 5_200))  // quiet 9 min 59 s
        #expect(!notified(a, "fan_ramp"))

        let long = EventDetector(settings: AlertSettings())
        _ = long.ingest(evSnap(0, target: 2_000))
        let b = long.ingest(evSnap(600, target: 5_200))   // quiet 10 min
        #expect(notified(b, "fan_ramp"))
    }

    @Test func fanAlertNoRefireWhileLoud() {
        let d = EventDetector(settings: AlertSettings())
        _ = d.ingest(evSnap(0, target: 2_000))
        #expect(notified(d.ingest(evSnap(700, target: 5_200)), "fan_ramp"))
        for i in 1...120 {
            let r = d.ingest(evSnap(700 + Double(i) * 10, target: 5_000 + Double(i % 3) * 100))
            #expect(!logged(r, "fan_ramp"))
        }
    }

    @Test func cooldown15Min() {
        let a = EventDetector(settings: AlertSettings())
        _ = a.ingest(evSnap(0, pressure: 0))
        #expect(notified(a.ingest(evSnap(1, pressure: 2)), "thermal_pressure"))
        _ = a.ingest(evSnap(2, pressure: 1))
        let early = a.ingest(evSnap(1 + 899, pressure: 2))
        #expect(logged(early, "thermal_pressure"))
        #expect(!notified(early, "thermal_pressure"))

        let b = EventDetector(settings: AlertSettings())
        _ = b.ingest(evSnap(0, pressure: 0))
        _ = b.ingest(evSnap(1, pressure: 2))
        _ = b.ingest(evSnap(2, pressure: 1))
        #expect(notified(b.ingest(evSnap(1 + 900, pressure: 2)), "thermal_pressure"))
    }

    @Test func disabledKindStillLogsEvent() {
        var s = AlertSettings()
        s.enabled["thermal_pressure"] = false
        let d = EventDetector(settings: s)
        _ = d.ingest(evSnap(0, pressure: 0))
        let r = d.ingest(evSnap(1, pressure: 3))
        #expect(logged(r, "thermal_pressure"))
        #expect(!notified(r, "thermal_pressure"))
    }

    @Test func thermalPressureHeavyAlerts() {
        let d = EventDetector(settings: AlertSettings())
        _ = d.ingest(evSnap(0, pressure: 0))
        let moderate = d.ingest(evSnap(1, pressure: 1))
        #expect(logged(moderate, "thermal_pressure"))
        #expect(!notified(moderate, "thermal_pressure"))
        let heavy = d.ingest(evSnap(2, pressure: 2))
        #expect(notified(heavy, "thermal_pressure"))
        #expect(heavy.first { $0.event.kind == "thermal_pressure" }?.event.title == "Thermal pressure is heavy")
    }

    @Test func otherKinds() {
        let d = EventDetector(settings: AlertSettings())
        var s = evSnap(0)
        s.wakeTime = Date(timeIntervalSince1970: 100)
        s.memory.swapUsed = 50; s.memory.swapTotal = 100
        s.gpu.cltm = "NO_CLTM"
        var b = BatteryInfo(cellVoltagesMV: [], cellResistance: [], pdMenu: [])
        b.iopsHealth = "Good"
        s.battery = b
        s.thermal.ssdC = 50
        s.disks.volumes = [VolumeInfo(name: "Macintosh HD", path: "/", total: 1_000_000_000_000, free: 20_000_000_000,
                                      importantFree: 25_000_000_000, purgeable: 5_000_000_000)]
        #expect(d.ingest(s).isEmpty) // first look: nothing to compare against

        var n = s
        n.ts = Date(timeIntervalSince1970: 10)
        n.wakeTime = Date(timeIntervalSince1970: 5)
        n.memory.swapUsed = 95
        n.gpu.cltm = "CLTM_2"
        n.battery?.iopsHealth = "Check Battery"
        n.thermal.ssdC = 72
        n.disks.volumes[0].importantFree = 8_000_000_000
        let r = d.ingest(n)
        for k in ["wake", "swap_high", "throttle", "battery_flag", "ssd_hot", "disk_low"] { #expect(logged(r, k), "missing \(k)") }
        #expect(!notified(r, "wake"))  // wake never notifies
        #expect(notified(r, "ssd_hot"))
        for e in r { #expect(!e.event.title.contains("\u{2014}") && !e.event.body.contains("\u{2014}")) }
    }

    @Test func kernelTaskThrottleNeeds30s() {
        let d = EventDetector(settings: AlertSettings())
        for i in 0...29 {
            var s = evSnap(Double(i)); s.cpu.kernelTaskPct = 60
            #expect(!logged(d.ingest(s), "throttle"))
        }
        var s = evSnap(30); s.cpu.kernelTaskPct = 60
        #expect(logged(d.ingest(s), "throttle"))
    }

    @Test func settingsRoundTrip() throws {
        var s = AlertSettings()
        s.fanLoudRPM = 4_800
        s.enabled["wake"] = false
        let back = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(AlertSettings().cooldownMinutes == 15)
        #expect(AlertSettings.kinds.count == 9)
    }
}
