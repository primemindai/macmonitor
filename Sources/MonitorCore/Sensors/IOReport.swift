import Foundation
import IOKit
import CSensors

/// One IOReport channel from a delta sample. `value` is set for simple channels,
/// `states` for state (residency) channels.
public struct IOReportChannel: Sendable {
    public var group: String
    public var subgroup: String
    public var name: String
    public var unit: String
    public var value: Int64?
    public var states: [(name: String, residency: Int64)]

    public init(group: String, subgroup: String, name: String, unit: String, value: Int64?, states: [(name: String, residency: Int64)]) {
        self.group = group; self.subgroup = subgroup; self.name = name; self.unit = unit
        self.value = value; self.states = states
    }
}

/// Read-only IOReport subscription. Each `sample()` returns the change since the last call.
public final class IOReportSampler: @unchecked Sendable {
    /// The small 1 s set from the plan: power, CPU clocks, GPU clocks and the GPU heat cap. Nothing else.
    public static let fastGroups: [(group: String, subgroup: String?)] = [
        ("Energy Model", nil),
        ("CPU Stats", "CPU Core Performance States"),
        ("CPU Stats", "CPU Complex Performance States"),
        ("GPU Stats", "GPU Performance States"),
        ("GPU Stats", "CLTM-induced GPU Performance States"),
    ]

    private let sub: OpaquePointer
    private let lock = NSLock()
    /// Seconds between the last two samples.
    /// Awake seconds covered by the last sample (mach_absolute_time, which stops during sleep).
    public private(set) var lastIntervalSeconds: Double = 0
    /// The same interval in wall seconds including sleep (mach_continuous_time).
    public private(set) var lastContinuousSeconds: Double = 0

    public init?(groups: [(group: String, subgroup: String?)]) {
        var gPtrs: [UnsafeMutablePointer<CChar>?] = groups.map { strdup($0.group) }
        var sPtrs: [UnsafeMutablePointer<CChar>?] = groups.map { $0.subgroup.map { strdup($0) } ?? nil }
        defer { (gPtrs + sPtrs).forEach { free($0) } }
        let s: OpaquePointer? = gPtrs.withUnsafeMutableBufferPointer { g in
            sPtrs.withUnsafeMutableBufferPointer { sg in
                g.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: groups.count) { gp in
                    sg.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: groups.count) { sp in
                        ior_create(gp, sp, Int32(groups.count))
                    }
                }
            }
        }
        guard let s else { return nil }
        sub = s
    }

    deinit { ior_destroy(sub) }

    public func sample() -> [IOReportChannel]? {
        lock.lock(); defer { lock.unlock() }
        var secs = 0.0, cont = 0.0
        guard ior_sample(sub, &secs, &cont) == 0 else { return nil }
        lastIntervalSeconds = secs
        lastContinuousSeconds = cont
        return readChannels()
    }

    /// Raw current values instead of a delta (for gauges like display nits).
    public func sampleAbsolute() -> [IOReportChannel]? {
        lock.lock(); defer { lock.unlock() }
        guard ior_sample_absolute(sub) == 0 else { return nil }
        return readChannels()
    }

    private func readChannels() -> [IOReportChannel] {
        let n = ior_count(sub)
        var out: [IOReportChannel] = []
        out.reserveCapacity(n)
        var g = [CChar](repeating: 0, count: 128), sg = g, nm = g
        var u = [CChar](repeating: 0, count: 64), st = u
        for i in 0..<n {
            var fmt: Int32 = 0
            guard ior_channel(sub, i, &g, &sg, &nm, &u, &fmt) == 0 else { continue }
            var c = IOReportChannel(group: cstr(g), subgroup: cstr(sg), name: cstr(nm),
                                    unit: cstr(u), value: nil, states: [])
            if fmt == 1 {
                c.value = ior_simple_value(sub, i)
            } else if fmt == 2 {
                let k = ior_state_count(sub, i)
                for j in 0..<max(0, k) {
                    let r = ior_state(sub, i, j, &st)
                    c.states.append((cstr(st), r))
                }
            } else {
                continue
            }
            out.append(c)
        }
        return out
    }
}

/// Watts by part of the chip, from IOReport "Energy Model". A missing channel stays nil, never 0.
public struct PowerBreakdown: Codable, Equatable, Sendable {
    public var pCluster0W: Double?
    public var pCluster1W: Double?
    public var eClusterW: Double?
    /// The "GPU" mJ channel (spec section 14). The "GPU Energy" nJ channel disagrees; it is kept in gpuAltW.
    public var gpuW: Double?
    public var gpuAltW: Double?
    public var aneW: Double?
    public var dramW: Double?
    /// AMCC + DCS (memory controller and fabric).
    public var memSystemW: Double?
    /// "CPU Energy" total.
    public var cpuW: Double?
    public var displayW: Double?
    /// Per core, keyed by channel name (PACC0_CPU0, EACC_CPU3, ...).
    public var perCoreW: [String: Double]

    public init(pCluster0W: Double? = nil, pCluster1W: Double? = nil, eClusterW: Double? = nil, gpuW: Double? = nil,
                gpuAltW: Double? = nil, aneW: Double? = nil, dramW: Double? = nil, memSystemW: Double? = nil,
                cpuW: Double? = nil, displayW: Double? = nil, perCoreW: [String: Double] = [:]) {
        self.pCluster0W = pCluster0W; self.pCluster1W = pCluster1W; self.eClusterW = eClusterW; self.gpuW = gpuW
        self.gpuAltW = gpuAltW; self.aneW = aneW; self.dramW = dramW; self.memSystemW = memSystemW
        self.cpuW = cpuW; self.displayW = displayW; self.perCoreW = perCoreW
    }

    /// Sum of the blocks the fan explainer weighs (P0 + P1 + E + GPU + ANE + DRAM + memory system).
    public var chipTotalW: Double? {
        let parts = [pCluster0W, pCluster1W, eClusterW, gpuW, aneW, dramW, memSystemW].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

public enum EnergyModel {
    /// Longest interval read as a current value (ticks are 1 or 2 s; a longer one means the app stalled).
    public static let maxIntervalSeconds: Double = 10

    /// True when an IOReport interval can be turned into a current reading.
    public static func usableInterval(_ seconds: Double) -> Bool { seconds > 0 && seconds <= maxIntervalSeconds }

    /// Same check with the interval also measured on the clock that keeps counting during sleep. The IOReport
    /// interval is awake time only, so a wake shows up as a normal 1 s tick; a gap of over 1 s between the two
    /// clocks means the Mac slept inside this interval, and the delta is not a current reading.
    public static func usableInterval(_ seconds: Double, continuous: Double?) -> Bool {
        guard usableInterval(seconds) else { return false }
        guard let continuous else { return true }
        return continuous <= maxIntervalSeconds && continuous - seconds <= 1
    }

    /// Power by part for one interval, or nil when the interval cannot be read as a current value.
    public static func breakdown(_ ch: [IOReportChannel], seconds: Double, continuous: Double?) -> PowerBreakdown? {
        usableInterval(seconds, continuous: continuous) ? parse(ch, seconds: seconds) : nil
    }

    /// Energy delta to watts. nil for a non-energy unit, a bad or too long interval, or a counter that went backwards.
    public static func watts(value: Int64, unit: String, seconds: Double) -> Double? {
        guard usableInterval(seconds), value >= 0 else { return nil }
        let joules: Double
        switch unit {
        case "mJ": joules = Double(value) / 1e3
        case "uJ": joules = Double(value) / 1e6
        case "nJ": joules = Double(value) / 1e9
        default: return nil
        }
        return joules / seconds
    }

    public static func parse(_ ch: [IOReportChannel], seconds: Double) -> PowerBreakdown {
        var w: [String: Double] = [:]
        for c in ch where c.group == "Energy Model" {
            if let v = c.value, let x = watts(value: v, unit: c.unit, seconds: seconds) { w[c.name] = x }
        }
        var p = PowerBreakdown()
        p.pCluster0W = w["PACC0_CPU"]
        p.pCluster1W = w["PACC1_CPU"]
        p.eClusterW = w["EACC_CPU"]
        p.gpuW = w["GPU"]
        p.gpuAltW = w["GPU Energy"]
        p.aneW = w["ANE"]
        p.dramW = w["DRAM"]
        let mem = [w["AMCC"], w["DCS"]].compactMap { $0 }
        p.memSystemW = mem.isEmpty ? nil : mem.reduce(0, +)
        p.cpuW = w["CPU Energy"]
        p.displayW = w["DISP"]
        for (k, v) in w where (k.hasPrefix("PACC") || k.hasPrefix("EACC")) && k.range(of: #"_CPU\d+$"#, options: .regularExpression) != nil {
            p.perCoreW[k] = v
        }
        return p
    }
}

public enum Residency {
    static let idleNames: Set<String> = ["IDLE", "OFF", "DOWN"]

    /// "V12P6" -> 12, "P1" -> 1, "IDLE" -> nil.
    public static func stateIndex(_ name: String) -> Int? {
        if name.hasPrefix("V") {
            let digits = name.dropFirst().prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        if name.hasPrefix("P") {
            let rest = name.dropFirst()
            return !rest.isEmpty && rest.allSatisfy(\.isNumber) ? Int(rest) : nil
        }
        return nil
    }

    /// Residency-weighted MHz over the non-idle states. nil when there was no active time.
    public static func mhz(states: [(name: String, residency: Int64)], tableMHz: [Double]) -> Double? {
        var num = 0.0, den = 0.0
        for s in states where s.residency > 0 && !idleNames.contains(s.name) {
            guard let i = stateIndex(s.name), i >= 0, i < tableMHz.count else { continue }
            num += Double(s.residency) * tableMHz[i]
            den += Double(s.residency)
        }
        return den > 0 ? num / den : nil
    }

    /// Percent of time not idle. nil when the window had no residency at all.
    public static func activePercent(states: [(name: String, residency: Int64)]) -> Double? {
        let total = states.reduce(Int64(0)) { $0 + max(0, $1.residency) }
        guard total > 0 else { return nil }
        let idle = states.filter { idleNames.contains($0.name) }.reduce(Int64(0)) { $0 + max(0, $1.residency) }
        return 100.0 * Double(total - idle) / Double(total)
    }
}

/// Frequency tables from the pmgr device tree node. CPU tables are in kHz, the GPU table in Hz.
public enum DVFSTables {
    nonisolated(unsafe) private static var cached: (eMHz: [Double], pMHz: [Double], gpuMHz: [Double])?
    private static let lock = NSLock()

    public static func load() -> (eMHz: [Double], pMHz: [Double], gpuMHz: [Double]) {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        defer { if svc != 0 { IOObjectRelease(svc) } }
        func table(_ key: String) -> [Double] {
            guard svc != 0,
                  let d = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }
            var out: [Double] = []
            var off = 0
            while off + 8 <= d.count {
                let f = d.subdata(in: off..<off + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let v = Double(UInt32(littleEndian: f))
                out.append(v > 1e7 ? v / 1e6 : v / 1e3)
                off += 8
            }
            return out
        }
        let r = (table("voltage-states1-sram"), table("voltage-states5-sram"), table("voltage-states9-sram"))
        if !r.0.isEmpty { cached = r }
        return r
    }
}

/// Clock speeds from IOReport residency. Per-core numbers are what each core asked for;
/// the PCPM / ECPM cluster numbers are what the cluster ran at (spec section 14: show both, labeled).
public struct ClockInfo: Codable, Equatable, Sendable {
    /// Only cores that were active in the window (an idle core has no clock to show).
    public var perCoreMHz: [String: Double] = [:]
    public var perCoreActivePct: [String: Double] = [:]
    public var eClusterMHz: Double?
    public var pCluster0MHz: Double?
    public var pCluster1MHz: Double?
    public var gpuMHz: Double?
    public var gpuActivePct: Double?
    /// Main state of the GPU heat cap, "NO_CLTM" when heat is not capping the GPU.
    public var gpuCLTM: String?
    public init() {}
}

public enum ClockModel {
    public static func parse(_ ch: [IOReportChannel], tables: (eMHz: [Double], pMHz: [Double], gpuMHz: [Double])) -> ClockInfo {
        var c = ClockInfo()
        for x in ch {
            switch x.subgroup {
            case "CPU Core Performance States":
                let t = x.name.hasPrefix("E") ? tables.eMHz : tables.pMHz
                if let m = Residency.mhz(states: x.states, tableMHz: t) { c.perCoreMHz[x.name] = m }
                if let a = Residency.activePercent(states: x.states) { c.perCoreActivePct[x.name] = a }
            case "CPU Complex Performance States":
                switch x.name {
                case "ECPM": c.eClusterMHz = Residency.mhz(states: x.states, tableMHz: tables.eMHz)
                case "PCPM": c.pCluster0MHz = Residency.mhz(states: x.states, tableMHz: tables.pMHz)
                case "PCPM1": c.pCluster1MHz = Residency.mhz(states: x.states, tableMHz: tables.pMHz)
                default: break
                }
            case "GPU Performance States" where x.name == "GPUPH":
                c.gpuMHz = Residency.mhz(states: x.states, tableMHz: tables.gpuMHz)
                c.gpuActivePct = Residency.activePercent(states: x.states)
            case "CLTM-induced GPU Performance States":
                c.gpuCLTM = x.states.filter { $0.residency > 0 }.max { $0.residency < $1.residency }?.name
            default: break
            }
        }
        return c
    }
}
