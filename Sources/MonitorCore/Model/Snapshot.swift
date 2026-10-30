import Foundation

public enum FanState: String, Codable, Sendable { case off, rampingUp, rampingDown, steady }

/// One process behind the heat. Own processes have watts; root ones only CPU or GPU percent.
public struct Cause: Codable, Equatable, Sendable {
    public var name: String
    public var watts: Double?
    public var gpuPercent: Double?
    public var cpuPercent: Double?
    public init(name: String, watts: Double? = nil, gpuPercent: Double? = nil, cpuPercent: Double? = nil) {
        self.name = name; self.watts = watts; self.gpuPercent = gpuPercent; self.cpuPercent = cpuPercent
    }
}

/// The "why is my fan on" answer, with the readings it used.
public struct FanExplanation: Codable, Equatable, Sendable {
    public var headline: String
    public var state: FanState
    public var headingToRPM: Double?
    /// The block that used the most power over the last minute, for example "P cores".
    public var sourceBlock: String
    /// Its share of chip power, 0 to 100.
    public var sourceShare: Double
    public var topCauses: [Cause]
    public var readings: [String: Double]
    /// Set when the chip is cool but the fan is on, naming other likely heat (charging, SSD...).
    public var fallbackReason: String?
    public init(headline: String, state: FanState, headingToRPM: Double?, sourceBlock: String, sourceShare: Double,
                topCauses: [Cause], readings: [String: Double], fallbackReason: String?) {
        self.headline = headline; self.state = state; self.headingToRPM = headingToRPM; self.sourceBlock = sourceBlock
        self.sourceShare = sourceShare; self.topCauses = topCauses; self.readings = readings; self.fallbackReason = fallbackReason
    }
}

public struct CPUInfo: Codable, Equatable, Sendable {
    public var totalPct: Double?
    public var pPct: Double?
    public var ePct: Double?
    /// One entry per logical CPU, in CPU order (E cores first on this chip). nil = no reading yet.
    public var perCorePct: [Double?] = []
    public var coreKinds: [CoreKind] = []
    /// Per-core "asked for" MHz and per-cluster "runs at" MHz (PCPM / ECPM), labeled separately.
    public var clocks: ClockInfo?
    public var loadAvg: [Double] = []
    /// kernel_task CPU from top (a throttle sign when high). Only set when top ran.
    public var kernelTaskPct: Double?
    /// When the `top` reading behind kernelTaskPct was taken. nil when there is no fresh reading.
    public var kernelTaskAt: Date?
    public init() {}
}

public struct GPUInfo: Codable, Equatable, Sendable {
    public var utilPct: Double?
    public var rendererPct: Double?
    public var tilerPct: Double?
    public var inUseBytes: UInt64?
    public var allocBytes: UInt64?
    public var resets: Int?
    public var mhz: Double?
    public var activePct: Double?
    /// GPU heat cap state; "NO_CLTM" means heat is not capping the GPU.
    public var cltm: String?
    public init() {}
}

public struct PowerInfo: Codable, Equatable, Sendable {
    public var breakdown: PowerBreakdown?
    /// SMC PSTR: whole system power.
    public var systemW: Double?
    /// SMC PDTR: power coming in from the adapter.
    public var adapterInW: Double?
    /// SMC PPBR: battery power.
    public var batteryW: Double?
    /// AppleSmartBattery PowerTelemetryData SystemPowerIn (read once a minute).
    public var wallW: Double?
    public init() {}
}

public struct SensorReading: Codable, Equatable, Sendable {
    public var key: String
    public var celsius: Double
    public var group: String
    /// false = label is a best guess.
    public var proven: Bool
    public var source: String
    public init(key: String, celsius: Double, group: String, proven: Bool, source: String) {
        self.key = key; self.celsius = celsius; self.group = group; self.proven = proven; self.source = source
    }
}

/// A sensor group that exists on this Mac but gave no real reading on the last full read.
public struct SensorGap: Codable, Equatable, Sendable {
    public var group: String
    public var reason: String
    public init(group: String, reason: String) { self.group = group; self.reason = reason }
}

public struct ThermalInfo: Codable, Equatable, Sendable {
    /// ProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var state: Int?
    /// Thermal pressure: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
    public var pressure: Int?
    public var hottestC: Double?
    public var hottestKey: String?
    public var cpuPC: Double?
    /// Seconds since the P core sensors last gave a real reading, when cpuPC is a held value. nil = read this second.
    public var cpuPHeldSeconds: Double?
    /// When the P core sensors last gave a real reading. nil = never since the app started.
    public var cpuPLastRealAt: Date?
    /// Seconds old, when hottestC is a held P core value. nil = read this second.
    public var hottestHeldSeconds: Double?
    public var cpuEC: Double?
    public var gpuC: Double?
    /// NVMe SMART temperature (once a minute), else the HID "NAND CH0 temp" sensor.
    public var ssdC: Double?
    public var batteryC: Double?
    public var palmRestC: Double?
    public var ambientC: Double?
    /// The 1 s SMC temperature set.
    public var fastSensors: [SensorReading] = []
    /// Every SMC temperature key plus HID sensors, refreshed once a minute.
    public var allSensors: [SensorReading] = []
    /// When allSensors was read.
    public var allSensorsAt: Date?
    /// Groups that exist but gave no real reading on that read (optional so older saved snapshots still decode).
    public var notReporting: [SensorGap]?
    /// SMC keys that look like temperature limits (not proven), shown raw.
    public var limitKeys: [String: Double] = [:]
    public init() {}
}

public struct FanInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    /// 0 to 1.
    public var duty: Double?
    /// nil until the fan explainer has enough readings.
    public var state: FanState?
    public init(index: Int, actualRPM: Double?, targetRPM: Double?, minRPM: Double?, maxRPM: Double?, duty: Double?, state: FanState?) {
        self.index = index; self.actualRPM = actualRPM; self.targetRPM = targetRPM; self.minRPM = minRPM
        self.maxRPM = maxRPM; self.duty = duty; self.state = state
    }
}

public struct DiskInfo: Codable, Equatable, Sendable {
    public var volumes: [VolumeInfo] = []
    public var readBps: Double?
    public var writeBps: Double?
    public var readOpsPerSec: Double?
    public var writeOpsPerSec: Double?
    public var readLatencyMs: Double?
    public var writeLatencyMs: Double?
    public var bytesReadSinceBoot: UInt64?
    public var bytesWrittenSinceBoot: UInt64?
    public var smart: SMARTInfo?
    public init() {}
}

public struct NetInfo: Codable, Equatable, Sendable {
    public var name: String
    public var rxBps: Double?
    public var txBps: Double?
    public var baud: UInt64?
    public var rxTotal: UInt64?
    public var txTotal: UInt64?
    public init(name: String, rxBps: Double? = nil, txBps: Double? = nil, baud: UInt64? = nil, rxTotal: UInt64? = nil, txTotal: UInt64? = nil) {
        self.name = name; self.rxBps = rxBps; self.txBps = txBps; self.baud = baud; self.rxTotal = rxTotal; self.txTotal = txTotal
    }
}

public struct MemoryRates: Codable, Equatable, Sendable {
    public var pageinsPerSec: Double?
    public var swapinsPerSec: Double?
    public var swapoutsPerSec: Double?
    public init() {}
}

/// Everything we know at one moment. Missing sources are nil, never a fake 0.
public struct Snapshot: Codable, Equatable, Sendable {
    public var ts: Date
    public var cpu: CPUInfo
    public var gpu: GPUInfo
    public var memory: MemoryInfo
    public var memoryRates: MemoryRates
    public var power: PowerInfo
    public var thermal: ThermalInfo
    public var fans: [FanInfo]
    public var disks: DiskInfo
    public var network: [NetInfo]
    public var wifi: WiFiInfo?
    public var battery: BatteryInfo?
    public var display: DisplayInfo?
    public var lidAngle: Double?
    public var wakeTime: Date?
    /// Union of the top 10 by CPU, energy, GPU, memory and disk.
    public var topProcesses: [ProcSample]
    /// When topProcesses was sampled (every 5 s).
    public var processesAt: Date?
    public var fanExplanation: FanExplanation?

    public static func empty(ts: Date) -> Snapshot {
        Snapshot(ts: ts, cpu: CPUInfo(), gpu: GPUInfo(), memory: MemoryInfo(), memoryRates: MemoryRates(), power: PowerInfo(),
                 thermal: ThermalInfo(), fans: [], disks: DiskInfo(), network: [], wifi: nil, battery: nil, display: nil,
                 lidAngle: nil, wakeTime: nil, topProcesses: [], processesAt: nil, fanExplanation: nil)
    }

    public func fan(_ i: Int) -> FanInfo? { fans.first { $0.index == i } }
}
