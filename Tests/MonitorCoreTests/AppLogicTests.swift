import Testing
import Foundation
@testable import MonitorCore

@Suite struct FormatTests {
    @Test func rpmShort() {
        #expect(Fmt.rpmShort(2_310) == "2.3k")
        #expect(Fmt.rpmShort(5_000) == "5.0k")
        #expect(Fmt.rpmShort(950) == "950")
        #expect(Fmt.rpmShort(0) == "0")
        #expect(Fmt.rpmShort(nil) == "--")
    }

    @Test func rpmFull() {
        #expect(Fmt.rpm(2_310.4) == "2,310")
        #expect(Fmt.rpm(nil) == "--")
    }

    @Test func percentsTempsWatts() {
        #expect(Fmt.pct(41.6) == "42%")
        #expect(Fmt.pct(nil) == "--")
        #expect(Fmt.temp(70.6) == "71°")
        #expect(Fmt.temp(nil) == "--")
        #expect(Fmt.watts(14.23) == "14.2 W")
        #expect(Fmt.watts(0.046) == "0.05 W")
        #expect(Fmt.watts(123.4) == "123 W")
        #expect(Fmt.watts(nil) == "--")
    }

    @Test func bytesAndRates() {
        #expect(Fmt.bytes(1_400_000_000) == "1.4 GB")
        #expect(Fmt.bytes(512_000) == "512 KB")
        #expect(Fmt.bytes(2_500_000_000_000) == "2.5 TB")
        #expect(Fmt.bytes(nil) == "--")
        #expect(Fmt.rate(1_200_000) == "1.2 MB/s")
        #expect(Fmt.rate(0) == "0 B/s")
        #expect(Fmt.rate(nil) == "--")
    }

    @Test func memoryUsesBinaryUnitsLikeActivityMonitor() {
        #expect(Fmt.mem(51_539_607_552) == "48.0 GB")
        #expect(Fmt.mem(104_611_840) == "99.8 MB")
        #expect(Fmt.mem(512) == "512 B")
        #expect(Fmt.mem(nil) == "--")
    }

    @Test func menuBarText() {
        var s = Snapshot.empty(ts: Date())
        s.cpu.totalPct = 41.7
        s.thermal.hottestC = 70.6
        s.fans = [FanInfo(index: 0, actualRPM: 2_100, targetRPM: nil, minRPM: nil, maxRPM: nil, duty: nil, state: nil),
                  FanInfo(index: 1, actualRPM: 2_310, targetRPM: nil, minRPM: nil, maxRPM: nil, duty: nil, state: nil)]
        #expect(MenuBarText.make(s) == "CPU 42% · 71° · 2.3k")
        // Missing sources show "--", never a fake 0.
        #expect(MenuBarText.make(Snapshot.empty(ts: Date())) == "CPU -- · -- · --")
        #expect(MenuBarText.make(nil) == "CPU -- · -- · --")
    }
}

@Suite struct HeatScaleTests {
    @Test func blueAtFortyRedAtHundred() {
        #expect(HeatScale.fraction(40) == 0)
        #expect(HeatScale.fraction(100) == 1)
        #expect(abs(HeatScale.fraction(70) - 0.5) < 1e-9)
        #expect(HeatScale.fraction(10) == 0)
        #expect(HeatScale.fraction(130) == 1)
        #expect(abs(HeatScale.hue(40) - 220.0 / 360) < 1e-9)
        #expect(HeatScale.hue(100) == 0)
    }
}

@Suite struct RingBufferTests {
    @Test func keepsNewestInOrder() {
        var r = RingBuffer<Int>(capacity: 3)
        #expect(r.elements.isEmpty)
        for i in 1...5 { r.append(i) }
        #expect(r.elements == [3, 4, 5])
        #expect(r.count == 3)
        #expect(r.last == 5)
    }
}

@Suite struct DownsampleTests {
    @Test func shortSeriesUnchanged() {
        let pts = (0..<10).map { (Date(timeIntervalSince1970: Double($0)), Double($0)) }
        let out = Downsample.average(pts, maxPoints: 50)
        #expect(out.map(\.1) == pts.map(\.1))
    }

    @Test func longSeriesAveragedIntoBuckets() {
        let pts = (0..<1_000).map { (Date(timeIntervalSince1970: Double($0)), Double($0 % 2 == 0 ? 0 : 10)) }
        let out = Downsample.average(pts, maxPoints: 100)
        #expect(out.count <= 100)
        #expect(out.count >= 90)
        #expect(out.allSatisfy { abs($0.1 - 5) < 1e-9 })
        #expect(out.first!.0 >= pts.first!.0)
        #expect(out.last!.0 <= pts.last!.0)
    }

    @Test func emptyStaysEmpty() {
        #expect(Downsample.average([], maxPoints: 10).isEmpty)
    }
}

@Suite struct PrefsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "macmonitor.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func missingGivesDefaults() {
        let s = PrefsStore(defaults: freshDefaults())
        #expect(s.load() == AppPrefs())
        #expect(s.load().alerts.fanLoudRPM == 5_000)
    }

    @Test func roundTrip() {
        let d = freshDefaults()
        var p = AppPrefs()
        p.alerts.fanLoudRPM = 3_000
        p.alerts.enabled["ssd_hot"] = false
        p.eco = true
        p.loginItemConfigured = true
        PrefsStore(defaults: d).save(p)
        let back = PrefsStore(defaults: d).load()
        #expect(back == p)
        #expect(back.alerts.isEnabled("ssd_hot") == false)
    }

    @Test func garbageGivesDefaults() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: PrefsStore.key)
        #expect(PrefsStore(defaults: d).load() == AppPrefs())
    }

    @Test func alertSettingsWrittenAsJSONForDefaultsWrite() throws {
        // `defaults write com.macmonitor.app prefs` users and the notification proof read this as JSON.
        let d = freshDefaults()
        PrefsStore(defaults: d).save(AppPrefs())
        let data = try #require(d.data(forKey: PrefsStore.key))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["alerts"] != nil)
    }
}

@Suite struct WindowPolicyTests {
    @Test func dockOnlyWhileWindowOpen() {
        #expect(WindowPolicy.activation(mainWindowVisible: true) == .regular)
        #expect(WindowPolicy.activation(mainWindowVisible: false) == .accessory)
    }

    @Test func sampleModes() {
        #expect(WindowPolicy.sampleMode(windowOpen: true, eco: false) == .windowOpen)
        #expect(WindowPolicy.sampleMode(windowOpen: true, eco: true) == .windowOpen)
        #expect(WindowPolicy.sampleMode(windowOpen: false, eco: false) == .normal)
        #expect(WindowPolicy.sampleMode(windowOpen: false, eco: true) == .eco)
    }
}

@Suite struct LaunchAgentTests {
    @Test func plistStartsAppAtLoginOnly() throws {
        let data = try LaunchAgentPlist.data(executable: "/Users/x/Applications/MacMonitor.app/Contents/MacOS/MacMonitor")
        let obj = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(obj["Label"] as? String == "com.macmonitor.app")
        // --background: a login launch stays in the menu bar and opens no window.
        #expect(obj["ProgramArguments"] as? [String] == ["/Users/x/Applications/MacMonitor.app/Contents/MacOS/MacMonitor", "--background"])
        #expect(obj["RunAtLoad"] as? Bool == true)
        #expect(obj["KeepAlive"] == nil)
        #expect(obj["LimitLoadToSessionType"] as? String == "Aqua")
    }

    @Test func plistPath() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(LaunchAgentPlist.url(home: home).path == "/Users/x/Library/LaunchAgents/com.macmonitor.app.plist")
    }
}

@Suite struct LaunchWindowTests {
    @Test func windowOnlyForAUserLaunch() {
        #expect(LaunchWindow.showAtLaunch(arguments: ["MacMonitor"], hasOpenEvent: true, isLoginItem: false))
        #expect(!LaunchWindow.showAtLaunch(arguments: ["MacMonitor", "--background"], hasOpenEvent: true, isLoginItem: false))
        #expect(!LaunchWindow.showAtLaunch(arguments: ["MacMonitor"], hasOpenEvent: true, isLoginItem: true))
        #expect(!LaunchWindow.showAtLaunch(arguments: ["MacMonitor"], hasOpenEvent: false, isLoginItem: false))
    }
}

@Suite struct FanSpinTests {
    @Test func spinFollowsRPM() {
        #expect(FanSpin.turnsPerSecond(rpm: nil) == 0)
        #expect(FanSpin.turnsPerSecond(rpm: 50) == 0)
        let slow = FanSpin.turnsPerSecond(rpm: 2_300)
        let fast = FanSpin.turnsPerSecond(rpm: 5_000)
        #expect(slow > 0)
        #expect(fast > slow)
        #expect(FanSpin.turnsPerSecond(rpm: 20_000) == FanSpin.maxTurnsPerSecond)
    }
}

@Suite struct TimeRangeTests {
    @Test func rangesAndSources() {
        #expect(TimeRange.m15.seconds == 900)
        #expect(TimeRange.h24.seconds == 86_400)
        #expect(TimeRange.d30.seconds == 30 * 86_400)
        #expect(TimeRange.d30.usesMinuteRollups)
        #expect(!TimeRange.h24.usesMinuteRollups)
        #expect(TimeRange.allCases.map(\.label) == ["15m", "1h", "24h", "30d"])
    }
}

@Suite struct CoreMapTests {
    @Test func m4ProLayout() {
        let kinds: [CoreKind] = Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 10)
        let slots = CoreMap.slots(kinds: kinds)
        #expect(slots.count == 14)
        #expect(slots[0].label == "E1")
        #expect(slots[0].wattKey == "EACC_CPU0")
        #expect(slots[0].mhzKey == "ECPU000")
        #expect(slots[3].wattKey == "EACC_CPU3")
        #expect(slots[4].label == "P1")
        #expect(slots[4].cluster == 0)
        #expect(slots[4].wattKey == "PACC0_CPU0")
        #expect(slots[4].mhzKey == "PCPU000")
        #expect(slots[9].wattKey == "PACC1_CPU0")
        #expect(slots[9].mhzKey == "PCPU100")
        #expect(slots[13].label == "P10")
        #expect(slots[13].wattKey == "PACC1_CPU4")
        #expect(slots[13].mhzKey == "PCPU140")
    }

    @Test func emptyKindsGiveNoSlots() {
        #expect(CoreMap.slots(kinds: []).isEmpty)
    }
}

@Suite struct TopScheduleTests {
    // top costs about 0.7 s of CPU per run (measured), so the menu bar only mode runs it only in short bursts.
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Seconds (from base) at which `top` runs, ticking every `step` seconds.
    func runs(_ seconds: Int, step: Int = 1, mode: SampleMode, heating: (Int) -> Bool) -> [Int] {
        var sched = TopSchedule()
        return stride(from: 0, to: seconds, by: step).filter { t in
            sched.shouldRun(now: base.addingTimeInterval(Double(t)), mode: mode, heating: heating(t))
        }
    }

    @Test func windowOpenEvery15Seconds() {
        #expect(runs(61, mode: .windowOpen) { _ in false } == [0, 15, 30, 45, 60])
    }

    @Test func menuBarRunsAShortBurstWhenHeating() {
        #expect(runs(120, mode: .normal) { _ in true } == [0, 16, 32])
    }

    @Test func burstWaitsForTheCooldown() {
        let r = runs(TopSchedule.burstCooldown + 61, mode: .normal) { _ in true }
        #expect(r == [0, 16, 32] + [0, 16, 32].map { $0 + TopSchedule.burstCooldown })
    }

    @Test func ecoTicksStillSpanThirtySeconds() {
        let r = runs(120, step: 2, mode: .eco) { _ in true }
        #expect(r.count == 3)
        #expect((r.last ?? 0) - (r.first ?? 0) >= 30)
        #expect(zip(r, r.dropFirst()).allSatisfy { $1 - $0 >= 15 })
    }

    @Test func menuBarNeverRunsWhenCool() {
        #expect(runs(2000, mode: .normal) { _ in false }.isEmpty)
    }

    @Test func burstStartsWhenHeatingStarts() {
        #expect(runs(200, mode: .normal) { $0 >= 100 } == [100, 116, 132])
    }

    @Test func heatingMeansPressureOrFansSpeedingUp() {
        var s = Snapshot.empty(ts: base)
        #expect(!TopSchedule.heating(s))
        s.thermal.pressure = 1
        #expect(TopSchedule.heating(s))
        s.thermal.pressure = 0
        s.fans = [FanInfo(index: 0, actualRPM: 2000, targetRPM: 3000, minRPM: nil, maxRPM: nil, duty: nil, state: nil)]
        #expect(TopSchedule.heating(s))
        s.fans = [FanInfo(index: 0, actualRPM: 3000, targetRPM: 2000, minRPM: nil, maxRPM: nil, duty: nil, state: nil)]
        #expect(!TopSchedule.heating(s))    // slowing down is not heating
    }

    /// Review R2-S1: with only the menu bar running, a hot Mac must still be able to raise the kernel_task alert.
    @Test func kernelTaskAlertCanFireInMenuBarMode() {
        var sched = TopSchedule()
        let d = EventDetector(settings: AlertSettings())
        var lastTop: Date?
        var fired = false
        for t in 0..<120 {
            let now = base.addingTimeInterval(Double(t))
            if sched.shouldRun(now: now, mode: .normal, heating: true) { lastTop = now }
            var s = Snapshot.empty(ts: now)
            let r = TopReading(at: lastTop ?? .distantPast, procs: [0: (cpu: 90, power: 0)])
            let k = SampleEngine.kernelTask(from: lastTop == nil ? nil : r, now: now)
            s.cpu.kernelTaskPct = k.pct
            s.cpu.kernelTaskAt = k.at
            if d.ingest(s).contains(where: { $0.event.kind == "throttle" }) { fired = true }
        }
        #expect(fired)
    }

    /// Review R2-N2: the note must not claim top never ran when its reading is only stale.
    @Test func reportNoteDoesNotSayTopNeverRan() {
        let notes = Report.snapshot(Snapshot.empty(ts: base), source: "test")["not_available"] as? [String] ?? []
        let k = notes.first { $0.hasPrefix("kernel_task cpu") } ?? ""
        #expect(!k.contains("has not run"))
        #expect(k.contains("short bursts"))
    }
}
