import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

public struct GPUStats: Codable, Equatable, Sendable {
    public var deviceUtil: Double?
    public var rendererUtil: Double?
    public var tilerUtil: Double?
    public var inUseBytes: UInt64?
    public var allocBytes: UInt64?
    /// GPU resets ("recoveryCount").
    public var resets: Int?

    public static func parse(_ p: [String: Any]) -> GPUStats {
        GPUStats(deviceUtil: num(p["Device Utilization %"]),
                 rendererUtil: num(p["Renderer Utilization %"]),
                 tilerUtil: num(p["Tiler Utilization %"]),
                 inUseBytes: num(p["In use system memory"]).map { UInt64(max(0, $0)) },
                 allocBytes: num(p["Alloc system memory"]).map { UInt64(max(0, $0)) },
                 resets: int(p["recoveryCount"]))
    }
}

public struct PDOption: Codable, Equatable, Sendable {
    public var voltageMV: Int
    public var maxCurrentMA: Int
}

/// Battery and power adapter. There is deliberately no serial number field.
/// Health is shown three ways because the sources disagree on this Mac (spec section 14).
public struct BatteryInfo: Codable, Equatable, Sendable {
    public var percent: Int?
    public var isCharging: Bool?
    public var externalConnected: Bool?
    public var cycleCount: Int?
    public var designCycles: Int?
    public var designCapacity: Int?
    public var rawMaxCapacity: Int?
    public var nominalCapacity: Int?
    /// NominalChargeCapacity / DesignCapacity, what System Settings shows as Maximum Capacity.
    public var appleMaxCapacityPercent: Int?
    /// AppleRawMaxCapacity / DesignCapacity.
    public var rawHealthPercent: Double?
    /// The macOS power-source flag (for example "Check Battery").
    public var iopsHealth: String?
    public var voltageMV: Int?
    public var amperageMA: Int?
    public var chargingCurrentMA: Int?
    public var cellVoltagesMV: [Int]
    public var temperatureC: Double?
    public var lifetimeMaxTempC: Int?
    public var lifetimeMaxChargeMA: Int?
    public var lifetimeMaxDischargeMA: Int?
    public var cellResistance: [Int]
    public var wallPowerW: Double?
    public var adapterLossW: Double?
    public var adapterName: String?
    public var adapterWatts: Int?
    public var pdMenu: [PDOption]

    public static func parse(ioreg b: [String: Any], iops: [String: Any]) -> BatteryInfo {
        let bd = b["BatteryData"] as? [String: Any] ?? [:]
        let life = bd["LifetimeData"] as? [String: Any] ?? [:]
        let tele = b["PowerTelemetryData"] as? [String: Any] ?? [:]
        let ad = b["AdapterDetails"] as? [String: Any] ?? [:]
        let charger = b["ChargerData"] as? [String: Any] ?? [:]
        func i64(_ v: Any?) -> Int? { (v as? NSNumber).map { Int($0.int64Value) } }
        let design = int(b["DesignCapacity"])
        let raw = int(b["AppleRawMaxCapacity"])
        let nominal = int(b["NominalChargeCapacity"])
        var out = BatteryInfo(cellVoltagesMV: [], cellResistance: [], pdMenu: [])
        out.percent = int(b["CurrentCapacity"])
        out.isCharging = b["IsCharging"] as? Bool
        out.externalConnected = b["ExternalConnected"] as? Bool
        out.cycleCount = int(b["CycleCount"])
        out.designCycles = int(iops["DesignCycleCount"]) ?? int(b["DesignCycleCount9C"])
        out.designCapacity = design
        out.rawMaxCapacity = raw
        out.nominalCapacity = nominal
        if let d = design, d > 0 {
            if let n = nominal { out.appleMaxCapacityPercent = Int((Double(n) / Double(d) * 100).rounded()) }
            if let r = raw { out.rawHealthPercent = (Double(r) / Double(d) * 1000).rounded() / 10 }
        }
        out.iopsHealth = iops["BatteryHealth"] as? String
        out.voltageMV = int(b["Voltage"])
        out.amperageMA = i64(b["InstantAmperage"])
        out.chargingCurrentMA = int(charger["ChargingCurrent"])
        out.cellVoltagesMV = (bd["CellVoltage"] as? [Any])?.compactMap(int) ?? []
        out.temperatureC = num(b["Temperature"]).map { $0 / 100 }
        out.lifetimeMaxTempC = int(life["MaximumTemperature"])
        out.lifetimeMaxChargeMA = i64(life["MaximumChargeCurrent"])
        out.lifetimeMaxDischargeMA = i64(life["MaximumDischargeCurrent"])
        out.cellResistance = (bd["WeightedRa"] as? [Any])?.compactMap(int) ?? []
        out.wallPowerW = num(tele["SystemPowerIn"]).map { $0 / 1000 }
        out.adapterLossW = num(tele["AdapterEfficiencyLoss"]).map { $0 / 1000 }
        out.adapterName = ad["Name"] as? String
        out.adapterWatts = int(ad["Watts"])
        out.pdMenu = (ad["UsbHvcMenu"] as? [[String: Any]] ?? []).compactMap { m in
            guard let v = int(m["MaxVoltage"]), let c = int(m["MaxCurrent"]) else { return nil }
            return PDOption(voltageMV: v, maxCurrentMA: c)
        }
        return out
    }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var nits: Double?
    public var brightness: Double?
    public var refreshHz: Double?
}

/// In-process IORegistry readers (never shells out to ioreg).
public enum Registry {
    private static func property(_ svc: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func services(_ cls: String) -> [io_service_t] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_service_t] = []
        while case let s = IOIteratorNext(it), s != 0 { out.append(s) }
        return out
    }

    public static func gpuStats() -> GPUStats? {
        let svcs = services("IOAccelerator")
        defer { svcs.forEach { IOObjectRelease($0) } }
        for s in svcs {
            if let p = property(s, "PerformanceStatistics") as? [String: Any] { return GPUStats.parse(p) }
        }
        return nil
    }

    /// "pid 396, WindowServer" -> (396, "WindowServer").
    public static func parseCreator(_ s: String) -> (pid: Int32, name: String)? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ",") else { return nil }
        guard let pid = Int32(s[s.index(s.startIndex, offsetBy: 4)..<comma].trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (pid, name)
    }

    /// Lifetime GPU time in ns per process (works for root processes too), from AGXDeviceUserClient AppUsage.
    public static func gpuTimeByPID() -> [Int32: UInt64] {
        // User clients are not matchable services, so walk the children of the GPU accelerator.
        var clients: [io_registry_entry_t] = []
        let accels = services("IOAccelerator")
        defer { (accels + clients).forEach { IOObjectRelease($0) } }
        for a in accels {
            var it: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(a, kIOServicePlane, &it) == KERN_SUCCESS else { continue }
            while case let c = IOIteratorNext(it), c != 0 {
                if IOObjectConformsTo(c, "AGXDeviceUserClient") != 0 { clients.append(c) } else { IOObjectRelease(c) }
            }
            IOObjectRelease(it)
        }
        var out: [Int32: UInt64] = [:]
        for s in clients {
            guard let c = property(s, "IOUserClientCreator") as? String, let who = parseCreator(c),
                  let usage = property(s, "AppUsage") as? [[String: Any]] else { continue }
            let ns = usage.reduce(UInt64(0)) { $0 &+ UInt64(max(0, num($1["accumulatedGPUTime"]) ?? 0)) }
            out[who.pid, default: 0] &+= ns
        }
        return out
    }

    public static func battery() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryInfo.parse(ioreg: dict, iops: iopsBattery())
    }

    static func iopsBattery() -> [String: Any] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }
        for s in list {
            if let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return d
            }
        }
        return [:]
    }

    nonisolated(unsafe) private static var backlight: IOReportSampler?
    nonisolated(unsafe) private static var backlightTried = false
    private static let lock = NSLock()

    public static func display() -> DisplayInfo? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        guard let builtin = ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var info = DisplayInfo()
        if let m = CGDisplayCopyDisplayMode(builtin), m.refreshRate > 0 { info.refreshHz = m.refreshRate }
        info.brightness = displayServicesBrightness(builtin)
        lock.lock()
        if !backlightTried { backlightTried = true; backlight = IOReportSampler(groups: [("backlight report", "brightness report")]) }
        let b = backlight
        lock.unlock()
        if let v = b?.sampleAbsolute()?.first(where: { $0.name == "MilliNits value" })?.value, v > 0 {
            info.nits = Double(v) / 1000
        }
        return info
    }

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    nonisolated(unsafe) private static let getBrightness: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let f = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(f, to: GetBrightness.self)
    }()

    private static func displayServicesBrightness(_ d: CGDirectDisplayID) -> Double? {
        var b: Float = -1
        guard let f = getBrightness, f(d, &b) == 0, b >= 0 else { return nil }
        return Double(b)
    }
}
