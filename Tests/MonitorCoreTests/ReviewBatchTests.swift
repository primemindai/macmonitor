import Testing
import Foundation
import SQLite3
@testable import MonitorCore

private let base = Date(timeIntervalSince1970: 1_800_000_000)

/// Review S2: a metric column missing from the file came back as rows of fake zeros.
@Suite struct MissingColumnTests {
    @Test func missingColumnIsNotZeros() throws {
        let url = tempDBURL()
        do {
            let w = try HistoryStore(path: url, readOnly: false)
            for i in 0..<20 {
                var s = Snapshot.empty(ts: base.addingTimeInterval(Double(i)))
                s.cpu.totalPct = 50
                s.thermal.hottestC = 70
                try w.write(s)
            }
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE samples DROP COLUMN \"temp.hottest_c\"", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let r = try HistoryStore(path: url, readOnly: true)
        #expect(throws: HistoryError.missingColumn("temp.hottest_c")) {
            try r.series(metric: "temp.hottest_c", from: base, to: base.addingTimeInterval(60))
        }
        // Other metrics still read normally.
        #expect(try r.series(metric: "cpu.total_pct", from: base, to: base.addingTimeInterval(60)).count == 20)
    }
}

/// Review S3: get_history labelled per-minute averages "1s" when asked for 1 s data over more than 24 hours.
@Suite struct HistoryResolutionTests {
    @Test func oneSecondOverADayIsReportedAsPerMinute() async throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        let h = MCPHandler(store: { store }, live: { Snapshot.empty(ts: Date()) })
        let req = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_history","arguments":{"metric":"cpu.total_pct","minutes":2000,"resolution":"1s"}}}"#
        let reply = try #require(await h.handle(line: req))
        #expect(reply.contains(#"\"resolution\" : \"1m\""#))
        #expect(!reply.contains(#"\"resolution\" : \"1s\""#))
        #expect(reply.contains("kept 24 hours"))
    }
}

/// Review S4: the first wake after boot (wake time nil before, a date now) was never logged.
@Suite struct FirstWakeTests {
    @Test func firstWakeAfterBootIsLogged() {
        let d = EventDetector(settings: AlertSettings())
        _ = d.ingest(Snapshot.empty(ts: base))
        var s = Snapshot.empty(ts: base.addingTimeInterval(1))
        s.wakeTime = base.addingTimeInterval(0.5)
        let r = d.ingest(s)
        #expect(r.filter { $0.event.kind == "wake" }.count == 1)
        #expect(!r.contains { $0.event.kind == "wake" && $0.notify })
    }
}

/// PM call: hold the last real P core reading for 30 s (age always shown), then nil.
@Suite struct PCoreHold30Tests {
    func reading(p: Double) -> [String: Double] {
        var v: [String: Double] = ["Tg05": 50, "Te05": 45]
        for k in SMCKeys.pCoreTemps { v[k] = p }
        return v
    }

    @Test func heldAt20Seconds() {
        var hold = PCoreHold()
        _ = hold.apply(reading(p: 82), now: base)
        let b = hold.apply(reading(p: 40), now: base.addingTimeInterval(20))
        #expect(b.heldSeconds == 20)
        var s = Snapshot.empty(ts: base)
        SampleEngine.fillSMC(&s, b.values, slow: [:], pHeldSeconds: b.heldSeconds)
        #expect(s.thermal.cpuPC == 82)
        #expect(hold.lastRealAt == base)
    }

    @Test func nilAfter30Seconds() {
        var hold = PCoreHold()
        _ = hold.apply(reading(p: 82), now: base)
        let b = hold.apply(reading(p: 0), now: base.addingTimeInterval(31))
        #expect(b.heldSeconds == nil)
        #expect(hold.lastRealAt == base)   // the age of the last real reading is still known
    }
}

/// R2-N1: a held P core value that is also the hottest carries its age.
@Suite struct HottestAgeTests {
    @Test func heldHottestHasAge() {
        var v: [String: Double] = ["Tg05": 50]
        for k in SMCKeys.pCoreTemps { v[k] = 80 }
        var s = Snapshot.empty(ts: base)
        SampleEngine.fillSMC(&s, v, slow: [:], pHeldSeconds: 3)
        #expect(SMCKeys.pCoreTemps.contains(s.thermal.hottestKey ?? ""))
        #expect(s.thermal.hottestHeldSeconds == 3)
        #expect(s.thermal.cpuPHeldSeconds == 3)
        let thermal = Report.snapshot(s, source: "test")["thermal"] as? [String: Any]
        #expect(thermal?["hottest_reading_age_s"] as? Double == 3)
    }

    @Test func gpuHottestHasNoAge() {
        var v: [String: Double] = ["Tg05": 90]
        for k in SMCKeys.pCoreTemps { v[k] = 60 }
        var s = Snapshot.empty(ts: base)
        SampleEngine.fillSMC(&s, v, slow: [:], pHeldSeconds: 3)
        #expect(s.thermal.hottestKey == "Tg05")
        #expect(s.thermal.hottestHeldSeconds == nil)
    }
}

/// R3-S1 and R2-N3: the full sensor list.
@Suite struct AllSensorsTests {
    @Test func allPlaceholderPCoresReportAGap() {
        let r = SampleEngine.buildAllSensors(keys: ["Tp01", "Tp05", "Te05"], raw: ["Tp01": 40, "Tp05": 0, "Te05": 55], hid: [])
        #expect(r.sensors.map(\.key) == ["Te05"])
        #expect(r.gaps.map(\.group) == ["P cores"])
        #expect(r.gaps.first?.reason.isEmpty == false)
    }

    @Test func realPCoresHaveNoGap() {
        let r = SampleEngine.buildAllSensors(keys: ["Tp01", "Tp05"], raw: ["Tp01": 40, "Tp05": 71], hid: [])
        #expect(r.sensors.map(\.key) == ["Tp05"])
        #expect(r.gaps.isEmpty)
    }

    @Test func hidUnder10CIsDropped() {
        let hid = [HIDTemp(name: "PMU tdie1", celsius: 3), HIDTemp(name: "NAND CH0 temp", celsius: 38)]
        let r = SampleEngine.buildAllSensors(keys: [], raw: [:], hid: hid)
        #expect(r.sensors.map(\.key) == ["NAND CH0 temp"])
    }

    @Test func getSensorsKeepsTheMissingGroup() {
        var s = Snapshot.empty(ts: base)
        s.thermal.allSensors = [SensorReading(key: "Te05", celsius: 55, group: "E cores", proven: false, source: "SMC")]
        s.thermal.notReporting = [SensorGap(group: "P cores", reason: "placeholder only")]
        s.thermal.cpuPLastRealAt = base.addingTimeInterval(-42)
        let body = MCPHandler.sensorsBody(s, source: "test", group: "p cores")
        #expect(body["count"] as? Int == 0)
        let gaps = body["not_reporting"] as? [[String: Any]]
        #expect(gaps?.count == 1)
        #expect(gaps?.first?["group"] as? String == "P cores")
        #expect(gaps?.first?["reason"] as? String == "placeholder only")
        #expect(gaps?.first?["last_real_s_ago"] as? Double == 42)
        #expect((body["groups"] as? [String])?.contains("P cores") == true)
        // A filter for another group does not carry the P cores note.
        let e = MCPHandler.sensorsBody(s, source: "test", group: "e cores")
        #expect((e["not_reporting"] as? [[String: Any]])?.isEmpty == true)
    }
}

/// PM call: the 10 default P core keys can give only placeholders for minutes while other Tp keys read real.
/// After each full read, the per-second set switches to Tp keys that gave a real reading.
@Suite struct AdaptivePCoreKeysTests {
    /// One full read through a fresh picker (no memory, no seed).
    func pickOnce(_ raw: [String: Double]) -> [String] {
        var p = PCoreKeys.Picker()
        return p.update(raw, now: base)
    }

    /// Default keys all placeholders; 12 other Tp keys real, split over Tp0* and Tp1*.
    func fullRead() -> [String: Double] {
        var raw: [String: Double] = ["Te05": 55, "Tg05": 50]
        for (i, k) in SMCKeys.pCoreTemps.enumerated() { raw[k] = i % 2 == 0 ? 40 : 0 }
        for (i, k) in ["Tp0a", "Tp0b", "Tp0d", "Tp0f", "Tp0g", "Tp0h"].enumerated() { raw[k] = 80 - Double(i) }
        for (i, k) in ["Tp1i", "Tp1j", "Tp1k", "Tp1l", "Tp1m", "Tp1n"].enumerated() { raw[k] = 70 - Double(i) }
        raw["Tp1z"] = 5        // tiny junk is not real
        return raw
    }

    @Test func switchesToRealKeys() {
        let keys = pickOnce(fullRead())
        #expect(keys.count == PCoreKeys.maxKeys)
        #expect(Set(keys).isDisjoint(with: SMCKeys.pCoreTemps))
        #expect(!keys.contains("Tp1z"))
        let fast = SMCKeys.fastSet(pKeys: keys)
        #expect(keys.allSatisfy { fast.contains($0) })
        #expect(SMCKeys.pCoreTemps.allSatisfy { !fast.contains($0) })
        #expect(fast.contains("FNum") && fast.contains("Te06") && fast.contains("TCMz"))
    }

    @Test func spreadsAcrossBothGroupsHottestFirst() {
        let keys = pickOnce(fullRead())
        #expect(keys.filter { $0.hasPrefix("Tp0") }.count == 5)
        #expect(keys.filter { $0.hasPrefix("Tp1") }.count == 5)
        #expect(keys.contains("Tp0a") && keys.contains("Tp1i"))     // hottest of each group kept
        #expect(!keys.contains("Tp0h") && !keys.contains("Tp1n"))   // coolest of each group dropped
    }

    @Test func noRealKeysKeepsTheDefaultSet() {
        var raw: [String: Double] = ["Te05": 55]
        for k in SMCKeys.pCoreTemps + ["Tp1i", "Tp1j"] { raw[k] = 40 }
        #expect(pickOnce(raw) == SMCKeys.pCoreTemps)
        #expect(pickOnce([:]) == SMCKeys.pCoreTemps)
    }

    @Test func perSecondValuesFromPickedKeys() {
        let keys = pickOnce(fullRead())
        var v: [String: Double] = ["Tg05": 50, "Te06": 45]
        for k in keys { v[k] = 66 }
        v["Tp1i"] = 74
        var hold = PCoreHold()
        let out = hold.apply(v, now: base)
        var s = Snapshot.empty(ts: base)
        SampleEngine.fillSMC(&s, out.values, slow: [:], pHeldSeconds: out.heldSeconds)
        #expect(s.thermal.cpuPC == 74)
        #expect(s.thermal.hottestKey == "Tp1i")
        // A placeholder tick on the picked keys is held with its age, like the default keys.
        var ph = v; for k in keys { ph[k] = 40 }
        let held = hold.apply(ph, now: base.addingTimeInterval(5))
        #expect(held.heldSeconds == 5)
        var s2 = Snapshot.empty(ts: base)
        SampleEngine.fillSMC(&s2, held.values, slow: [:], pHeldSeconds: held.heldSeconds)
        #expect(s2.thermal.cpuPC == 74)
        #expect(s2.thermal.hottestHeldSeconds == 5)
    }
}

/// Live finding (22:15): the Tp keys come in two banks of about 51 that take turns reading real every few seconds.
/// A pick from one full read only covers the bank that was on; the picker also keeps the bank seen on recent reads.
@Suite struct PCoreBankTests {
    let bankA = ["Tp1i", "Tp1j", "Tp1k", "Tp1o", "Tp1x", "Tp23", "Tp29", "Tp2G", "Tpx9", "TpxD"]
    let bankB = SMCKeys.pCoreTemps + ["Tpx1", "Tpx5"]

    func read(on: [String], off: [String]) -> [String: Double] {
        var raw: [String: Double] = ["Te05": 55]
        for (i, k) in on.enumerated() { raw[k] = 75 - Double(i) / 2 }
        for k in off { raw[k] = 40 }
        return raw
    }

    @Test func keepsBothBanks() {
        var p = PCoreKeys.Picker()
        _ = p.update(read(on: bankB, off: bankA), now: base)
        let keys = p.update(read(on: bankA, off: bankB), now: base.addingTimeInterval(60))
        #expect(keys.count == PCoreKeys.maxKeys)
        #expect(keys.filter { bankA.contains($0) }.count == 5)
        #expect(keys.filter { bankB.contains($0) }.count == 5)

        // Per second, whichever bank is on, the P core value is read directly (no hold needed).
        for on in [bankA, bankB] {
            var v: [String: Double] = ["Tg05": 50]
            for k in keys { v[k] = on.contains(k) ? 70 : 40 }
            var hold = PCoreHold()
            let out = hold.apply(v, now: base)
            #expect(out.heldSeconds == nil)
            var s = Snapshot.empty(ts: base)
            SampleEngine.fillSMC(&s, out.values, slow: [:], pHeldSeconds: out.heldSeconds)
            #expect(s.thermal.cpuPC == 70)
        }
    }

    @Test func forgetsAnOldBank() {
        var p = PCoreKeys.Picker()
        _ = p.update(read(on: bankB, off: bankA), now: base)
        let keys = p.update(read(on: bankA, off: bankB), now: base.addingTimeInterval(PCoreKeys.Picker.memory + 60))
        #expect(keys.allSatisfy { bankA.contains($0) })
    }

    @Test func bothOffUsesTheRememberedKeys() {
        var p = PCoreKeys.Picker()
        _ = p.update(read(on: bankA, off: bankB), now: base)
        let keys = p.update(read(on: [], off: bankA + bankB), now: base.addingTimeInterval(60))
        #expect(keys.allSatisfy { bankA.contains($0) })
        #expect(keys.count == PCoreKeys.maxKeys)
    }
}
