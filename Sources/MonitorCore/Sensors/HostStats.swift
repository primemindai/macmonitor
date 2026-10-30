import Foundation
import Darwin
import notify

public struct CPUTicks: Equatable, Sendable {
    public var user, system, idle, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public enum CoreKind: String, Codable, Sendable { case efficiency, performance }

public enum CPUMath {
    /// Busy percent between two tick readings. nil if any counter went backwards or no time passed.
    public static func percent(prev: CPUTicks, cur: CPUTicks) -> Double? {
        guard cur.user >= prev.user, cur.system >= prev.system, cur.idle >= prev.idle, cur.nice >= prev.nice else { return nil }
        let busy = Double((cur.user - prev.user) + (cur.system - prev.system) + (cur.nice - prev.nice))
        let total = busy + Double(cur.idle - prev.idle)
        guard total > 0 else { return nil }
        return 100 * busy / total
    }
}

public enum Counter {
    /// Per-second rate. nil for a reset (cur < prev), no time, or a gap over 30 s (sleep), so the
    /// first sample after wake is never a giant spike.
    public static func rate(prev: UInt64, cur: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, seconds <= 30, cur >= prev else { return nil }
        return Double(cur - prev) / seconds
    }
}

public struct MemoryInfo: Codable, Equatable, Sendable {
    public var totalBytes: UInt64?
    /// App + wired + compressed, like Activity Monitor's "Memory Used".
    public var usedBytes: UInt64?
    public var appBytes: UInt64?
    public var wiredBytes: UInt64?
    /// Space the compressor takes in RAM.
    public var compressedBytes: UInt64?
    /// How much memory that compressed space holds.
    public var compressedHoldsBytes: UInt64?
    public var cachedBytes: UInt64?
    public var freeBytes: UInt64?
    public var swapUsed: UInt64?
    public var swapTotal: UInt64?
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
    public var pressureLevel: Int?
    /// kern.memorystatus_level: percent of memory free, as the kernel sees it.
    public var memorystatusPercent: Int?
    /// Lifetime counters (pages). Rates are computed by the sampler.
    public var pageins: UInt64?
    public var swapins: UInt64?
    public var swapouts: UInt64?
    public init() {}
}

public enum HostStats {
    static func sysctlInt(_ name: String) -> Int64? {
        var v: Int64 = 0
        var s = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &s, nil, 0) == 0 else { return nil }
        return s == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
    }

    public static func coreTicks() -> [CPUTicks] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let st = Int(CPU_STATE_MAX)
        return (0..<Int(n)).map { i in
            func t(_ k: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[i * st + Int(k)])) }
            return CPUTicks(user: t(CPU_STATE_USER), system: t(CPU_STATE_SYSTEM), idle: t(CPU_STATE_IDLE), nice: t(CPU_STATE_NICE))
        }
    }

    /// On this chip the first hw.perflevel1.logicalcpu CPUs are E cores, the rest P cores.
    public static func coreKinds() -> [CoreKind] {
        let total = Int(sysctlInt("hw.logicalcpu") ?? 0)
        let e = Int(sysctlInt("hw.perflevel1.logicalcpu") ?? 0)
        return (0..<total).map { $0 < e ? .efficiency : .performance }
    }

    public static func loadAverage() -> [Double] {
        var la = [Double](repeating: 0, count: 3)
        return getloadavg(&la, 3) == 3 ? la : []
    }

    public static func memory() -> MemoryInfo {
        var m = MemoryInfo()
        m.totalBytes = sysctlInt("hw.memsize").map { UInt64($0) }
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        if kr == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let pg = UInt64(pageSize)
            let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            let app = (anon > purgeable ? anon - purgeable : 0) * pg
            let wired = UInt64(vm.wire_count) * pg
            let comp = UInt64(vm.compressor_page_count) * pg
            m.appBytes = app
            m.wiredBytes = wired
            m.compressedBytes = comp
            m.compressedHoldsBytes = UInt64(vm.total_uncompressed_pages_in_compressor) * pg
            m.cachedBytes = (UInt64(vm.external_page_count) + purgeable) * pg
            m.freeBytes = UInt64(vm.free_count) * pg
            m.usedBytes = app + wired + comp
            m.pageins = UInt64(vm.pageins)
            m.swapins = UInt64(vm.swapins)
            m.swapouts = UInt64(vm.swapouts)
        }
        var sw = xsw_usage()
        var sws = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sws, nil, 0) == 0 {
            m.swapUsed = sw.xsu_used
            m.swapTotal = sw.xsu_total
        }
        m.pressureLevel = sysctlInt("kern.memorystatus_vm_pressure_level").map { Int($0) }
        m.memorystatusPercent = sysctlInt("kern.memorystatus_level").map { Int($0) }
        return m
    }

    nonisolated(unsafe) private static var pressureToken: Int32 = -1
    private static let lock = NSLock()

    /// state: ProcessInfo.thermalState (0 nominal ... 3 critical).
    /// pressure: com.apple.system.thermalpressurelevel (0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping).
    public static func thermal() -> (state: Int, pressure: Int) {
        lock.lock(); defer { lock.unlock() }
        if pressureToken < 0 {
            var t: Int32 = 0
            if notify_register_check("com.apple.system.thermalpressurelevel", &t) == UInt32(NOTIFY_STATUS_OK) { pressureToken = t }
        }
        var st: UInt64 = 0
        if pressureToken >= 0 { notify_get_state(pressureToken, &st) }
        return (ProcessInfo.processInfo.thermalState.rawValue, Int(st))
    }

    private static func timeval(_ name: String) -> Date? {
        var tv = Darwin.timeval()
        var s = MemoryLayout<Darwin.timeval>.size
        guard sysctlbyname(name, &tv, &s, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// Last wake from sleep (kern.waketime).
    public static func wakeTime() -> Date? { timeval("kern.waketime") }
    public static func bootTime() -> Date? { timeval("kern.boottime") }
}
