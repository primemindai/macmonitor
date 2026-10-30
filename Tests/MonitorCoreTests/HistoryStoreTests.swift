import Testing
import Foundation
import SQLite3
@testable import MonitorCore

func tempDBURL() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.sqlite")
}

func snap(_ t: Double, cpu: Double?) -> Snapshot {
    var s = Snapshot.empty(ts: Date(timeIntervalSince1970: t))
    s.cpu.totalPct = cpu
    return s
}

@Suite struct HistoryStoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000) // a whole minute

    @Test func writeThenSeries() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        for i in 0..<10 { try store.write(snap(now.timeIntervalSince1970 + Double(i), cpu: Double(i))) }
        let pts = try store.series(metric: "cpu.total_pct", from: now, to: now.addingTimeInterval(9))
        #expect(pts.count == 10)
        #expect(pts.first?.1 == 0)
        #expect(pts.last?.1 == 9)
        #expect(try store.latest()?.cpu.totalPct == 9)
        #expect(throws: HistoryError.self) { try store.series(metric: "nope.metric", from: now, to: now) }
    }

    @Test func pruneKeeps24hBoundary() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        let t = now.timeIntervalSince1970
        try store.write(snap(t - 86_400 - 1, cpu: 1))
        try store.write(snap(t - 86_400 + 1, cpu: 2))
        try store.prune(now: now)
        let pts = try store.series(metric: "cpu.total_pct", from: now.addingTimeInterval(-90_000), to: now.addingTimeInterval(-80_000))
        #expect(pts.map(\.1) == [2])
    }

    @Test func pruneKeeps30dRollups() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        let t = now.timeIntervalSince1970
        let old = (t - 30 * 86_400 - 60), keep = (t - 30 * 86_400 + 60)
        try store.write(snap(old, cpu: 1))
        try store.write(snap(keep, cpu: 2))
        try store.rollup(now: Date(timeIntervalSince1970: keep + 120))
        try store.prune(now: now)
        let rows = try store.seriesMinute(metric: "cpu.total_pct", from: now.addingTimeInterval(-40 * 86_400), to: now)
        #expect(rows.map(\.avg) == [2])
    }

    @Test func rollupAvgMinMax() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        let t = now.timeIntervalSince1970
        for (i, v) in [1.0, 2, 3, 10].enumerated() { try store.write(snap(t + Double(i) * 10, cpu: v)) }
        try store.rollup(now: now.addingTimeInterval(120))
        let rows = try store.seriesMinute(metric: "cpu.total_pct", from: now, to: now.addingTimeInterval(60))
        #expect(rows.count == 1)
        #expect(rows.first?.avg == 4)
        #expect(rows.first?.min == 1)
        #expect(rows.first?.max == 10)
        // Over 24 h wide, series() reads the per-minute averages.
        let pts = try store.series(metric: "cpu.total_pct", from: now.addingTimeInterval(-86_400 * 2), to: now.addingTimeInterval(60))
        #expect(pts.map(\.1) == [4])
    }

    @Test func rollupSkipsGaps() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        let t = now.timeIntervalSince1970
        try store.write(snap(t, cpu: 5))            // minute 0
        try store.write(snap(t + 3 * 60, cpu: 7))   // minute 3 (Mac slept for minutes 1 and 2)
        try store.rollup(now: now.addingTimeInterval(5 * 60))
        let rows = try store.seriesMinute(metric: "cpu.total_pct", from: now, to: now.addingTimeInterval(5 * 60))
        #expect(rows.map(\.ts) == [now, now.addingTimeInterval(180)])
        #expect(rows.map(\.avg) == [5, 7])
        // A second rollup does not duplicate or change rows.
        try store.rollup(now: now.addingTimeInterval(6 * 60))
        #expect(try store.seriesMinute(metric: "cpu.total_pct", from: now, to: now.addingTimeInterval(5 * 60)).count == 2)
    }

    @Test func readerWhileWriterWorks() throws {
        let url = tempDBURL()
        let writer = try HistoryStore(path: url, readOnly: false)
        try writer.write(snap(now.timeIntervalSince1970, cpu: 1))
        let reader = try HistoryStore(path: url, readOnly: true)
        for i in 1..<20 {
            try writer.write(snap(now.timeIntervalSince1970 + Double(i), cpu: Double(i)))
            #expect(try reader.latest()?.cpu.totalPct == Double(i))
        }
        #expect(throws: (any Error).self) { try reader.write(snap(0, cpu: 0)) }
    }

    @Test func readerAfterWriterClosedWorks() throws {
        let url = tempDBURL()
        do {
            let writer = try HistoryStore(path: url, readOnly: false)
            try writer.write(snap(now.timeIntervalSince1970, cpu: 3))
        }
        let reader = try HistoryStore(path: url, readOnly: true)
        #expect(try reader.latest()?.cpu.totalPct == 3)
    }

    @Test func missingDBThrowsNoHistory() {
        let url = tempDBURL()
        #expect(throws: HistoryError.noHistory) { try HistoryStore(path: url, readOnly: true) }
    }

    @Test func oldSchemaIsRebuilt() throws {
        let url = tempDBURL()
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES('schema_version','0'); CREATE TABLE samples(ts INTEGER PRIMARY KEY, junk REAL);", nil, nil, nil)
        sqlite3_close(db)
        // A reader on the old schema says so instead of crashing.
        #expect(throws: HistoryError.self) { try HistoryStore(path: url, readOnly: true) }
        let store = try HistoryStore(path: url, readOnly: false)
        try store.write(snap(now.timeIntervalSince1970, cpu: 8))
        #expect(try store.series(metric: "cpu.total_pct", from: now, to: now).map(\.1) == [8])
    }

    @Test func eventsAndProcesses() throws {
        let store = try HistoryStore(path: tempDBURL(), readOnly: false)
        try store.writeEvent(MonitorEvent(ts: now, kind: "thermal_pressure", title: "Thermal pressure heavy", body: "b"))
        try store.writeEvent(MonitorEvent(ts: now.addingTimeInterval(10), kind: "wake", title: "Mac woke", body: ""))
        #expect(try store.events(since: now.addingTimeInterval(-1), kind: nil).count == 2)
        #expect(try store.events(since: now.addingTimeInterval(-1), kind: "wake").map(\.title) == ["Mac woke"])
        var s = snap(now.timeIntervalSince1970, cpu: 1)
        s.topProcesses = [ProcSample(pid: 5, name: "Python", cpuPercent: 40, memBytes: 100, energyW: 1.5, gpuPercent: 2, isOwn: true)]
        s.processesAt = now
        try store.write(s)
        let p = try store.topProcesses(at: nil)
        #expect(p.map(\.name) == ["Python"])
        #expect(p.first?.energyW == 1.5)
    }

    @Test func sizeEstimate() throws {
        let url = tempDBURL()
        let store = try HistoryStore(path: url, readOnly: false)
        let t0 = now.timeIntervalSince1970
        var s = sampleSnapshot()
        s.topProcesses = (0..<20).map { ProcSample(pid: Int32($0), name: "process \($0)", cpuPercent: Double($0) * 1.37,
                                                    memBytes: UInt64($0) * 12_345_678, energyW: 0.123 * Double($0),
                                                    gpuPercent: 0.5, isOwn: true) }
        try store.inTransaction {
            for i in 0..<3_600 {
                s.ts = Date(timeIntervalSince1970: t0 + Double(i))
                s.cpu.totalPct = Double(i % 97) + 0.123
                s.power.systemW = 40 + Double(i % 13) * 1.7
                if i % 5 == 0 { s.processesAt = s.ts }
                try store.write(s)
            }
        }
        try store.rollup(now: Date(timeIntervalSince1970: t0 + 3_600))
        try store.checkpoint()
        let hourBytes = store.fileSizeBytes()
        let dayMB = Double(hourBytes) * 24 / 1_048_576
        // 30 days of per-minute rollups: one hour holds 60 of them; scale to 43,200.
        let rollupBytes = try store.tableBytes("samples_1m") + store.tableBytes("procs_1m")
        let thirtyDayRollupMB = Double(rollupBytes) * 24 * 30 / 1_048_576
        print(String(format: "DB size estimate: 1 h = %.2f MB, 24 h full detail = %.1f MB, 30 d rollups = %.1f MB, total about %.1f MB",
                     Double(hourBytes) / 1_048_576, dayMB, thirtyDayRollupMB, dayMB + thirtyDayRollupMB))
        #expect(dayMB < 60)
        #expect(dayMB + thirtyDayRollupMB < 150)
    }
}
