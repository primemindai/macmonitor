import Foundation
import CSensors

/// Turns raw SMC bytes into a number. Integers are little-endian on Apple Silicon
/// (proven in the research: B0AV reads 12,844 mV only when read little-endian).
public enum SMCDecode {
    public static func value(type: String, bytes: [UInt8]) -> Double? {
        func le<T: FixedWidthInteger>(_: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard bytes.count >= n else { return nil }
            var v: T = 0
            for i in 0..<n { v |= T(truncatingIfNeeded: bytes[i]) << (8 * i) }
            return v
        }
        switch type {
        case "flt ":
            guard let raw = le(UInt32.self) else { return nil }
            let f = Double(Float(bitPattern: raw))
            return f.isFinite ? f : nil
        case "ui8 ", "flag": return bytes.first.map { Double($0) }
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "ui16": return le(UInt16.self).map { Double($0) }
        case "si16": return le(Int16.self).map { Double($0) }
        case "ui32": return le(UInt32.self).map { Double($0) }
        case "si32": return le(Int32.self).map { Double($0) }
        case "ui64": return le(UInt64.self).map { Double($0) }
        case "si64": return le(Int64.self).map { Double($0) }
        case "ioft": return le(UInt64.self).map { Double($0) / 65536.0 }
        default: return nil
        }
    }

    static func code(_ key: String) -> UInt32? {
        let u = Array(key.utf8)
        guard u.count == 4 else { return nil }
        return u.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let b = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }
}

/// Read-only AppleSMC reader. Key info is cached per key so each later read is one call.
/// It only ever uses the read, key-info and key-by-index commands. It never writes a key.
public final class SMC: @unchecked Sendable {
    private let conn: UInt32
    private let lock = NSLock()
    private var info: [UInt32: (size: UInt32, type: String)?] = [:]

    public init?() {
        var c: UInt32 = 0
        guard smc_open(&c) == 0 else { return nil }
        conn = c
    }

    deinit { smc_close(conn) }

    private func keyInfo(_ code: UInt32) -> (size: UInt32, type: String)? {
        if let cached = info[code] { return cached }
        var size: UInt32 = 0, type: UInt32 = 0
        let r: (size: UInt32, type: String)? =
            smc_key_info(conn, code, &size, &type) == 0 ? (size, SMCDecode.string(type)) : nil
        info[code] = r
        return r
    }

    /// Raw type and bytes, or nil when the key is missing or locked.
    public func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let code = SMCDecode.code(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let ki = keyInfo(code), ki.size > 0, ki.size <= 32 else { return nil }
        var buf = [UInt8](repeating: 0, count: 32)
        guard smc_read_raw(conn, code, ki.size, &buf) == 0 else { return nil }
        return (ki.type, Array(buf.prefix(Int(ki.size))))
    }

    public func read(_ key: String) -> Double? {
        guard let r = readRaw(key) else { return nil }
        return SMCDecode.value(type: r.type, bytes: r.bytes)
    }

    public func readString(_ key: String) -> String? {
        guard let r = readRaw(key), r.type == "ch8*" else { return nil }
        let printable = r.bytes.prefix { $0 != 0 }.filter { $0 >= 32 && $0 < 127 }
        return String(decoding: printable, as: UTF8.self)
    }

    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let n = smc_key_count(conn)
        var out: [String] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            var k: UInt32 = 0
            if smc_key_at(conn, i, &k) == 0 { out.append(SMCDecode.string(k)) }
        }
        return out
    }
}

/// Keys read every second. Kept to 40 keys for the CPU budget (spec section 4).
public enum SMCKeys {
    public static let fans = ["FNum", "F0Ac", "F0Tg", "F1Ac", "F1Tg", "F0Mn", "F0Mx", "F0Dc", "F1Dc"]
    public static let power = ["PSTR", "PDTR", "PPBR"]
    /// The hottest key of each Tp triplet in the research dump (one per P core is a guess, not proven).
    public static let pCoreTemps = ["Tp02", "Tp06", "Tp0A", "Tp0E", "Tp0I", "Tp0M", "Tp0Q", "Tp0U", "Tp0Y", "Tp0c"]
    public static let eCoreTemps = ["Te06", "Te0T", "Tex1", "Tex3"]
    public static let gpuTemps = ["Tg05", "Tg0k", "Tg1V", "Tg1l"]
    public static let otherTemps = ["TCMz", "TCMb", "TB0T", "TH0a", "Ts0P", "Ts1P", "TW0P", "TVA0", "TaLP", "TaRF"]
    /// The per-second set for a given list of P core keys.
    public static func fastSet(pKeys: [String]) -> [String] { fans + power + pKeys + eCoreTemps + gpuTemps + otherTemps }
    /// Read once a minute (they do not change while running).
    public static let slowSet = ["F1Mn", "F1Mx", "F0Md", "F1Md", "Ftst", "MSLD", "mlT0", "mlT1", "mxT0", "mlMH"]
}

/// Which Tp* keys the per-second read uses for P core temperatures.
public enum PCoreKeys {
    public static let maxKeys = 10
    /// Every Tp* key is labeled P cores (SMCGroup), so any of them can stand in for the default set.
    public static func isPCore(_ key: String) -> Bool { key.hasPrefix("Tp") }

    /// Picks the P core keys to read every second from full reads of every Tp key: up to 10 keys that gave a real
    /// reading (not exactly 0 or 40.000, and 10 C or more), hottest first. Keys are grouped by the character after
    /// "Tp" (Tp0*, Tp1*), which may follow the two P clusters (a guess from the key names, not proven), and taken in
    /// turn from each group. Nothing real and nothing remembered: the default set.
    /// It also remembers which Tp keys read real on recent full reads. Live, the Tp keys come in two banks of about 51
    /// that take turns reading real every few seconds (sometimes one bank stays off for minutes). So the 10 keys
    /// are split: half from the keys real on this read, half from keys real on a read in the last 10 minutes but
    /// off on this one (the other bank). Whichever bank is on, some of the 10 per-second keys read real.
    public struct Picker: Sendable {
        public static let memory: TimeInterval = 600
        private var seen: [String: (c: Double, at: Date)] = [:]
        /// True once one read had real keys while other remembered keys were off.
        public private(set) var bothBanksSeen = false
        /// Keys used as the other bank, at the lowest priority, until both banks have read real once.
        private let seed: [String]
        public init(seed: [String] = []) { self.seed = seed }

        public mutating func update(_ raw: [String: Double], now: Date) -> [String] {
            let real = PCoreKeys.real(raw)
            for (k, c) in real { seen[k] = (c, now) }
            seen = seen.filter { now.timeIntervalSince($0.value.at) <= Self.memory }
            var other = seen.filter { real[$0.key] == nil }.mapValues(\.c)
            if !real.isEmpty && !other.isEmpty { bothBanksSeen = true }
            if !bothBanksSeen {
                for k in seed where real[k] == nil && other[k] == nil { other[k] = -1 }
            }
            if real.isEmpty && other.isEmpty { return SMCKeys.pCoreTemps }
            let nOther = min(other.count, max(maxKeys / 2, maxKeys - real.count))
            let nReal = min(real.count, maxKeys - nOther)
            return PCoreKeys.spread(real, nReal) + PCoreKeys.spread(other, nOther)
        }
    }

    public static let coldStartSeconds: Double = 180
    public static let coldStartEvery: Double = 5

    /// Until both banks have read real once (at most 3 minutes after launch), the app reads only the Tp keys every
    /// 5 s, so the per-second set learns the other bank without waiting for the once-a-minute full read.
    public static func coldStartRead(elapsed: Double, lastRead: Double?, bothBanksSeen: Bool) -> Bool {
        guard !bothBanksSeen, elapsed < coldStartSeconds else { return false }
        return lastRead.map { elapsed - $0 >= coldStartEvery - 0.5 } ?? true
    }

    /// Tp keys with a real reading: not exactly 0 or 40.000, and 10 C or more.
    static func real(_ raw: [String: Double]) -> [String: Double] {
        raw.filter { isPCore($0.key) && $0.value != 0 && $0.value != 40 && SensorRules.isReal($0.value) }
    }

    /// Up to `n` keys, hottest first, taken in turn from each Tp0*/Tp1*/... group.
    static func spread(_ keys: [String: Double], _ n: Int) -> [String] {
        let groups = Dictionary(grouping: keys, by: { String($0.key.dropFirst(2).prefix(1)) })
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key) }
        var out: [String] = []
        var i = 0
        while out.count < n, groups.contains(where: { $0.count > i }) {
            for g in groups where g.count > i && out.count < n { out.append(g[i]) }
            i += 1
        }
        return out
    }

}

/// Labels for SMC temperature keys. `proven` is true only where the research matched
/// another source exactly. Everything else is a best guess and the UI must say so.
public enum SMCGroup {
    static let battery: Set<String> = ["TB0T", "TB1T", "TB2T", "TG0B", "TG0C", "TG0H", "TG0V", "TG1B", "TG2B"]
    static let air: Set<String> = ["TaLP", "TaRF", "TaLT", "TaRT", "TaLW", "TaRW", "TaTP"]

    public static func group(for key: String) -> (name: String, proven: Bool) {
        if battery.contains(key) { return ("Battery", true) }
        if key == "TR0Z" { return ("PMU calibration", true) }
        if key == "TCMz" || key == "TCMb" { return ("CPU max", false) }
        if key.hasPrefix("Tp") { return ("P cores", false) }
        if key.hasPrefix("Te") { return ("E cores", false) }
        if key.hasPrefix("Tg") { return ("GPU", false) }
        if key.hasPrefix("TH0") { return ("SSD area", false) }
        if key == "Ts0P" || key == "Ts1P" { return ("Palm rest", false) }
        if air.contains(key) { return ("Air flow", false) }
        if key.hasPrefix("TW") { return ("Wi-Fi", false) }
        if key == "TVA0" || key == "mxA0" { return ("Ambient", false) }
        return ("Unknown", false)
    }
}
