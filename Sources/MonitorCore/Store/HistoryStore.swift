import Foundation
import SQLite3

public enum HistoryError: Error, Equatable, CustomStringConvertible {
    /// The database file does not exist (MacMonitor has not run yet).
    case noHistory
    /// The file is from another schema version and this connection is read only.
    case oldSchema
    case unknownMetric(String)
    /// The metric is known but this history file has no column for it (written by another MacMonitor version).
    case missingColumn(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .noHistory: return "No history yet. Is MacMonitor running?"
        case .oldSchema: return "The history file is from an older MacMonitor. Open the app once to upgrade it."
        case .unknownMetric(let m): return "Unknown metric \(m). Call list_metrics for the names."
        case .missingColumn(let m): return "No history for \(m) yet. This history file was written by another MacMonitor version; it fills in once the app runs."
        case .sqlite(let m): return "History database error: \(m)"
        }
    }
}

/// SQLite history. Layout (schema 1):
/// - samples: one wide row per second, one REAL column per MetricCatalog metric, kept 24 h.
/// - samples_1m: one wide row per minute with avg, min and max per metric, kept 30 days.
///   (Wide rows, not one row per metric, keep 30 days well under the 150 MB budget.)
/// - procs: top processes every 5 s (top 10 by CPU, energy and GPU), kept 24 h.
/// - procs_1m: per-minute top 5 by CPU and by energy, kept 30 days.
/// - events: kept 30 days. latest: the newest snapshot as JSON (heavy sensor list removed).
public final class HistoryStore: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let fullDetailSeconds: TimeInterval = 24 * 3600
    public static let rollupSeconds: TimeInterval = 30 * 86_400

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMonitor/history.sqlite")
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let readOnly: Bool
    private let path: URL
    private var lastProcsTs: Date?
    private var lastPrune: Date?
    private static let metrics = MetricCatalog.all

    public init(path: URL, readOnly: Bool) throws {
        self.path = path
        self.readOnly = readOnly
        if readOnly {
            guard FileManager.default.fileExists(atPath: path.path) else { throw HistoryError.noHistory }
            guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(db); db = nil
                throw HistoryError.sqlite(msg)
            }
            sqlite3_busy_timeout(db, 2000)
            guard (try? scalarInt("SELECT value FROM meta WHERE key='schema_version'")) == Self.schemaVersion else {
                sqlite3_close(db); db = nil
                throw HistoryError.oldSchema
            }
        } else {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(db); db = nil
                throw HistoryError.sqlite(msg)
            }
            sqlite3_busy_timeout(db, 2000)
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try migrate()
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: schema

    private static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func migrate() throws {
        let version = try? scalarInt("SELECT value FROM meta WHERE key='schema_version'")
        if version != Self.schemaVersion {
            // Unknown or older layout: start over (history is a cache, not a record).
            for t in ["samples", "samples_1m", "procs", "procs_1m", "events", "latest", "meta"] {
                try exec("DROP TABLE IF EXISTS \(t)")
            }
        }
        let raw = Self.metrics.map { "\(Self.q($0.name)) REAL" }.joined(separator: ", ")
        let roll = Self.metrics.map { m in ["avg", "min", "max"].map { "\(Self.q(m.name + "." + $0)) REAL" }.joined(separator: ", ") }
            .joined(separator: ", ")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS samples(ts INTEGER PRIMARY KEY, \(raw));
            CREATE TABLE IF NOT EXISTS samples_1m(ts INTEGER PRIMARY KEY, \(roll));
            CREATE TABLE IF NOT EXISTS procs(ts INTEGER, pid INTEGER, name TEXT, cpu REAL, mem REAL, energy REAL, gpu REAL, disk REAL, own INTEGER);
            CREATE INDEX IF NOT EXISTS procs_ts ON procs(ts);
            CREATE TABLE IF NOT EXISTS procs_1m(ts INTEGER, pid INTEGER, name TEXT, cpu REAL, mem REAL, energy REAL, gpu REAL);
            CREATE INDEX IF NOT EXISTS procs_1m_ts ON procs_1m(ts);
            CREATE TABLE IF NOT EXISTS events(ts INTEGER, kind TEXT, title TEXT, body TEXT);
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            CREATE TABLE IF NOT EXISTS latest(id INTEGER PRIMARY KEY CHECK (id = 1), ts INTEGER, json TEXT);
            INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '\(Self.schemaVersion)');
            """)
        // A metric added to the catalog later gets its columns without a rebuild.
        let have = Set(try strings("SELECT name FROM pragma_table_info('samples')"))
        for m in Self.metrics where !have.contains(m.name) {
            try exec("ALTER TABLE samples ADD COLUMN \(Self.q(m.name)) REAL")
            for s in ["avg", "min", "max"] { try exec("ALTER TABLE samples_1m ADD COLUMN \(Self.q(m.name + "." + s)) REAL") }
        }
    }

    // MARK: writing

    /// Writes one snapshot: a samples row, the latest JSON, and the process rows when they are new.
    public func write(_ s: Snapshot) throws {
        guard !readOnly else { throw HistoryError.sqlite("read-only store") }
        lock.lock(); defer { lock.unlock() }
        let ts = Int64(s.ts.timeIntervalSince1970.rounded(.down))
        let cols = Self.metrics.map { Self.q($0.name) }.joined(separator: ", ")
        let marks = Array(repeating: "?", count: Self.metrics.count).joined(separator: ", ")
        try run("INSERT OR REPLACE INTO samples(ts, \(cols)) VALUES(?, \(marks))",
                [ts] + Self.metrics.map { m -> Any? in m.extract(s).flatMap { $0.isFinite ? $0 : nil } })
        var light = s
        light.thermal.allSensors = []
        let json = String(decoding: try JSONEncoder().encode(light), as: UTF8.self)
        try run("INSERT OR REPLACE INTO latest(id, ts, json) VALUES(1, ?, ?)", [ts, json])
        if let pa = s.processesAt, pa != lastProcsTs {
            lastProcsTs = pa
            let pts = Int64(pa.timeIntervalSince1970.rounded(.down))
            for p in Self.storedProcesses(s.topProcesses) {
                try run("INSERT INTO procs(ts, pid, name, cpu, mem, energy, gpu, disk, own) VALUES(?,?,?,?,?,?,?,?,?)",
                        [pts, Int64(p.pid), p.name, p.cpuPercent, p.memBytes.map { Double($0) }, p.energyW, p.gpuPercent,
                         (p.diskReadBps ?? 0) + (p.diskWriteBps ?? 0), Int64(p.isOwn ? 1 : 0)])
            }
        }
    }

    /// Top 10 by CPU, energy and GPU (spec section 6).
    static func storedProcesses(_ all: [ProcSample]) -> [ProcSample] {
        var picked: [Int32: ProcSample] = [:]
        for k in [\ProcSample.cpuPercent, \ProcSample.energyW, \ProcSample.gpuPercent] {
            for p in all.filter({ ($0[keyPath: k] ?? 0) > 0 }).sorted(by: { ($0[keyPath: k] ?? 0) > ($1[keyPath: k] ?? 0) }).prefix(10) {
                picked[p.pid] = p
            }
        }
        return Array(picked.values)
    }

    public func writeEvent(_ e: MonitorEvent) throws {
        guard !readOnly else { throw HistoryError.sqlite("read-only store") }
        lock.lock(); defer { lock.unlock() }
        try run("INSERT INTO events(ts, kind, title, body) VALUES(?,?,?,?)",
                [Int64(e.ts.timeIntervalSince1970.rounded(.down)), e.kind, e.title, e.body])
    }

    /// Rolls every finished minute that has not been rolled yet. Minutes with no rows make no row.
    public func rollup(now: Date) throws {
        guard !readOnly else { return }
        lock.lock(); defer { lock.unlock() }
        let end = Int64(now.timeIntervalSince1970 / 60) * 60  // only finished minutes
        let rolled = (try? scalarInt64("SELECT value FROM meta WHERE key='rolled_until'")) ?? nil
        let start: Int64
        if let rolled { start = rolled } else {
            guard let first = try scalarInt64("SELECT min(ts) FROM samples") else { return }
            start = first / 60 * 60
        }
        guard end > start else { return }
        let sel = Self.metrics.map { m in
            "avg(\(Self.q(m.name))), min(\(Self.q(m.name))), max(\(Self.q(m.name)))"
        }.joined(separator: ", ")
        let cols = Self.metrics.map { m in ["avg", "min", "max"].map { Self.q(m.name + "." + $0) }.joined(separator: ", ") }
            .joined(separator: ", ")
        try exec("BEGIN")
        do {
            try run("INSERT OR REPLACE INTO samples_1m(ts, \(cols)) SELECT (ts / 60) * 60 AS m, \(sel) FROM samples WHERE ts >= ? AND ts < ? GROUP BY m",
                    [start, end])
            try run("""
                INSERT INTO procs_1m(ts, pid, name, cpu, mem, energy, gpu)
                SELECT m, pid, name, c, me, e, g FROM (
                  SELECT (ts / 60) * 60 AS m, pid, name, avg(cpu) AS c, avg(mem) AS me, avg(energy) AS e, avg(gpu) AS g,
                         row_number() OVER (PARTITION BY (ts / 60) ORDER BY avg(cpu) DESC) AS rc,
                         row_number() OVER (PARTITION BY (ts / 60) ORDER BY coalesce(avg(energy), -1) DESC) AS re
                  FROM procs WHERE ts >= ? AND ts < ? GROUP BY m, pid, name)
                WHERE rc <= 5 OR (re <= 5 AND e IS NOT NULL)
                """, [start, end])
            try run("INSERT OR REPLACE INTO meta(key, value) VALUES('rolled_until', ?)", [String(end)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes 1 Hz rows older than 24 h and rollups and events older than 30 days.
    public func prune(now: Date) throws {
        guard !readOnly else { return }
        lock.lock(); defer { lock.unlock() }
        let t = Int64(now.timeIntervalSince1970)
        let day = t - Int64(Self.fullDetailSeconds), month = t - Int64(Self.rollupSeconds)
        try run("DELETE FROM samples WHERE ts < ?", [day])
        try run("DELETE FROM procs WHERE ts < ?", [day])
        try run("DELETE FROM samples_1m WHERE ts < ?", [month])
        try run("DELETE FROM procs_1m WHERE ts < ?", [month])
        try run("DELETE FROM events WHERE ts < ?", [month])
    }

    /// Rollup then prune, at most once a minute. The app calls this after each write.
    public func maintainIfDue(now: Date) throws {
        if let l = lastPrune, now.timeIntervalSince(l) < 60 { return }
        lastPrune = now
        try rollup(now: now)
        try prune(now: now)
    }

    public func checkpoint() throws { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    /// Runs many writes in one transaction (bulk inserts).
    public func inTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    /// Deletes all history (Settings "clear history").
    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        for t in ["samples", "samples_1m", "procs", "procs_1m", "events", "latest"] { try exec("DELETE FROM \(t)") }
        try exec("DELETE FROM meta WHERE key='rolled_until'")
        try exec("VACUUM")
    }

    // MARK: reading

    public func latest() throws -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let json = try strings("SELECT json FROM latest WHERE id = 1").first else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    /// Points for one metric. Windows up to 24 h wide read the 1 Hz rows; wider windows read per-minute averages.
    public func series(metric: String, from: Date, to: Date) throws -> [(Date, Double)] {
        guard MetricCatalog.metric(named: metric) != nil else { throw HistoryError.unknownMetric(metric) }
        if to.timeIntervalSince(from) > Self.fullDetailSeconds {
            return try seriesMinute(metric: metric, from: from, to: to).compactMap { r in r.avg.map { (r.ts, $0) } }
        }
        lock.lock(); defer { lock.unlock() }
        try requireColumn("samples", metric, metric: metric)
        return try rows("SELECT ts, \(Self.q(metric)) FROM samples WHERE ts >= ? AND ts <= ? AND \(Self.q(metric)) IS NOT NULL ORDER BY ts",
                        [Int64(from.timeIntervalSince1970.rounded(.down)), Int64(to.timeIntervalSince1970.rounded(.down))]) { st in
            (Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 0))), sqlite3_column_double(st, 1))
        }
    }

    public struct MinuteRow: Equatable, Sendable {
        public var ts: Date
        public var avg: Double?
        public var min: Double?
        public var max: Double?
    }

    public func seriesMinute(metric: String, from: Date, to: Date) throws -> [MinuteRow] {
        guard MetricCatalog.metric(named: metric) != nil else { throw HistoryError.unknownMetric(metric) }
        lock.lock(); defer { lock.unlock() }
        try requireColumn("samples_1m", metric + ".avg", metric: metric)
        let a = Self.q(metric + ".avg"), mi = Self.q(metric + ".min"), ma = Self.q(metric + ".max")
        return try rows("SELECT ts, \(a), \(mi), \(ma) FROM samples_1m WHERE ts >= ? AND ts <= ? AND \(a) IS NOT NULL ORDER BY ts",
                        [Int64(from.timeIntervalSince1970.rounded(.down)), Int64(to.timeIntervalSince1970.rounded(.down))]) { st in
            func d(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
            return MinuteRow(ts: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 0))), avg: d(1), min: d(2), max: d(3))
        }
    }

    public func events(since: Date, kind: String?) throws -> [MonitorEvent] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT ts, kind, title, body FROM events WHERE ts >= ?"
        var args: [Any?] = [Int64(since.timeIntervalSince1970.rounded(.down))]
        if let kind { sql += " AND kind = ?"; args.append(kind) }
        sql += " ORDER BY ts DESC"
        return try rows(sql, args) { st in
            MonitorEvent(ts: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 0))),
                         kind: Self.text(st, 1), title: Self.text(st, 2), body: Self.text(st, 3))
        }
    }

    /// The process rows at the newest sample at or before `at` (or the newest overall).
    public func topProcesses(at: Date?) throws -> [ProcSample] {
        lock.lock(); defer { lock.unlock() }
        let limit = at.map { Int64($0.timeIntervalSince1970.rounded(.down)) } ?? Int64.max
        guard let ts = try scalarInt64("SELECT max(ts) FROM procs WHERE ts <= \(limit)") else { return [] }
        return try rows("SELECT pid, name, cpu, mem, energy, gpu, own FROM procs WHERE ts = ? ORDER BY cpu DESC", [ts]) { st in
            func d(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
            return ProcSample(pid: sqlite3_column_int(st, 0), name: Self.text(st, 1), cpuPercent: d(2),
                              memBytes: d(3).map { UInt64(max(0, $0)) }, energyW: d(4), gpuPercent: d(5),
                              isOwn: sqlite3_column_int(st, 6) == 1)
        }
    }

    /// Database plus WAL and shared-memory files.
    public func fileSizeBytes() -> Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let p = path.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)??.int64Value ?? 0
            return sum + size
        }
    }

    /// Bytes used by one table and its indexes (dbstat).
    public func tableBytes(_ table: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt64("SELECT sum(pgsize) FROM dbstat WHERE name = '\(table)' OR name IN (SELECT name FROM sqlite_master WHERE tbl_name = '\(table)' AND type = 'index')") ?? 0
    }

    // MARK: sqlite helpers

    /// SQLite reads a double-quoted name that is not a column as a text literal, which then reads back as 0.
    /// So check the column exists first (a file written by another MacMonitor version can lack it).
    private func requireColumn(_ table: String, _ column: String, metric: String) throws {
        let have = try rows("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", [table, column]) { _ in true }
        guard !have.isEmpty else { throw HistoryError.missingColumn(metric) }
    }

    private static func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private func err() -> HistoryError { .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed") }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw err() }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, Self.transient)
            case let v as Double?: if let v { sqlite3_bind_double(st, idx, v) } else { sqlite3_bind_null(st, idx) }
            default: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw err() }
    }

    private func rows<T>(_ sql: String, _ args: [Any?], _ map: (OpaquePointer?) -> T) throws -> [T] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(map(st)) } else if rc == SQLITE_DONE { break } else { throw err() }
        }
        return out
    }

    private func strings(_ sql: String) throws -> [String] { try rows(sql, []) { Self.text($0, 0) } }

    private func scalarInt64(_ sql: String) throws -> Int64? {
        try rows(sql, []) { st -> Int64? in sqlite3_column_type(st, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(st, 0) }.first ?? nil
    }

    private func scalarInt(_ sql: String) throws -> Int? { try scalarInt64(sql).map { Int($0) } }
}
