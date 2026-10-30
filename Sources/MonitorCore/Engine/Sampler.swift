import Foundation
import Combine

public enum SampleMode: String, Codable, Sendable {
    /// Menu bar only: 1 s fast set.
    case normal
    /// Lower cost: fast set every 2 s.
    case eco
    /// Main window open: 1 s, plus `top` every 15 s.
    case windowOpen
}

/// Time spent in one tick, for the CPU budget.
public struct TickCost: Sendable, CustomStringConvertible {
    public var smcMs = 0.0
    public var ioreportMs = 0.0
    public var otherMs = 0.0
    public var slowMs = 0.0
    public var processMs = 0.0
    public var totalMs = 0.0
    public var description: String {
        String(format: "total %.2f ms (SMC %.2f, IOReport %.2f, other %.2f, slow %.2f, processes %.2f)",
               totalMs, smcMs, ioreportMs, otherMs, slowMs, processMs)
    }
}

/// Owns every reader and the previous counters. All sampling happens here, off the main thread.
public actor SampleEngine {
    private let smc = SMC()
    private let ior = IOReportSampler(groups: IOReportSampler.fastGroups)
    private let tables = DVFSTables.load()
    private let procSampler = ProcessSampler()
    private let kinds = HostStats.coreKinds()

    private var prevTime: Double?
    private var prevTicks: [CPUTicks] = []
    private var prevNet: [String: (rx: UInt64, tx: UInt64, baud: UInt64)] = [:]
    private var prevBlock: [String: BlockStats] = [:]
    private var prevMem: MemoryInfo?

    // Slow (60 s) cache.
    private var battery: BatteryInfo?
    private var display: DisplayInfo?
    private var lid: Double?
    private var smart: SMARTInfo?
    private var hid: [HIDTemp] = []
    private var volumes: [VolumeInfo] = []
    private var wifi: WiFiInfo?
    private var slowSMC: [String: Double] = [:]
    private var allTempKeys: [String]?
    private var allSensors: [SensorReading] = []
    private var sensorGaps: [SensorGap] = []
    private var allSensorsAt: Date?

    // Process (5 s) cache.
    public private(set) var processes: [ProcSample] = []
    private var processesAt: Date?
    private var top: TopReading?
    private var pHold = PCoreHold()
    /// The Tp keys read every second (picked after each full read; the default set until then).
    private var pKeys = SMCKeys.pCoreTemps
    private var pPicker = PCoreKeys.Picker(seed: SMCKeys.pCoreTemps)
    private var startMono: Double?
    private var lastColdRead: Double?
    private var topRunning = false

    public private(set) var lastTickCost = TickCost()
    /// The last 61 s of snapshots, for fan state trends and the fan headline.
    private var recent: [Snapshot] = []

    public init() {}

    private static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
    private static func ms(since t: Double) -> Double { (monotonic() - t) * 1000 }

    /// Runs `top` (setuid, about 1 s of wall time) for root process CPU and energy impact.
    public func refreshTop() async {
        guard !topRunning else { return }
        topRunning = true
        let text = await ProcessRunner.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "40", "-stats", "pid,cpu,power,command"])
        topRunning = false
        if let text { top = TopReading(at: Date(), procs: TopParser.parse(text)) }
    }

    /// One sample. `slow` adds the 60 s readers, `processes` the 5 s process table.
    public func tick(slow: Bool, processes doProcs: Bool) async -> Snapshot {
        let t0 = Self.monotonic()
        var cost = TickCost()
        let now = Date()
        let mono = Self.monotonic()
        let secs = prevTime.map { mono - $0 } ?? 0
        var s = Snapshot.empty(ts: now)

        // SMC fast set.
        var t = Self.monotonic()
        var smcv: [String: Double] = [:]
        if let smc { for k in SMCKeys.fastSet(pKeys: pKeys) { if let v = smc.read(k) { smcv[k] = v } } }
        // Cold start: read only the Tp keys every 5 s until both banks have read real once.
        let elapsed = mono - (startMono ?? mono)
        if startMono == nil { startMono = mono }
        if let smc, let all = allTempKeys,
           PCoreKeys.coldStartRead(elapsed: elapsed, lastRead: lastColdRead, bothBanksSeen: pPicker.bothBanksSeen) {
            var raw: [String: Double] = [:]
            for k in all where PCoreKeys.isPCore(k) { if let c = smc.read(k) { raw[k] = c } }
            pKeys = pPicker.update(raw, now: now)
            lastColdRead = elapsed
        }
        cost.smcMs = Self.ms(since: t)

        // IOReport.
        t = Self.monotonic()
        // No power or clock reading for a tick whose interval holds a sleep (the continuous clock ran ahead of the
        // awake-only IOReport clock) or a stall of over 10 s.
        if let ch = ior?.sample(), let ior,
           let b = EnergyModel.breakdown(ch, seconds: ior.lastIntervalSeconds, continuous: ior.lastContinuousSeconds) {
            s.power.breakdown = b
            let clocks = ClockModel.parse(ch, tables: tables)
            s.cpu.clocks = clocks
            s.gpu.mhz = clocks.gpuMHz
            s.gpu.activePct = clocks.gpuActivePct
            s.gpu.cltm = clocks.gpuCLTM
        }
        cost.ioreportMs = Self.ms(since: t)

        // Everything else in the 1 s set.
        t = Self.monotonic()
        let ticks = HostStats.coreTicks()
        if ticks.count == prevTicks.count {
            let per = zip(prevTicks, ticks).map { CPUMath.percent(prev: $0, cur: $1) }
            s.cpu.perCorePct = per
            func avg(_ k: CoreKind?) -> Double? {
                let v = per.enumerated().filter { k == nil || (kinds.indices.contains($0.offset) && kinds[$0.offset] == k) }.compactMap(\.element)
                return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
            }
            s.cpu.totalPct = avg(nil)
            s.cpu.pPct = avg(.performance)
            s.cpu.ePct = avg(.efficiency)
        } else {
            s.cpu.perCorePct = Array(repeating: nil, count: ticks.count)
        }
        prevTicks = ticks
        s.cpu.coreKinds = kinds
        s.cpu.loadAvg = HostStats.loadAverage()

        s.memory = HostStats.memory()
        if let p = prevMem {
            func r(_ a: UInt64?, _ b: UInt64?) -> Double? { guard let a, let b else { return nil }; return Counter.rate(prev: a, cur: b, seconds: secs) }
            s.memoryRates.pageinsPerSec = r(p.pageins, s.memory.pageins)
            s.memoryRates.swapinsPerSec = r(p.swapins, s.memory.swapins)
            s.memoryRates.swapoutsPerSec = r(p.swapouts, s.memory.swapouts)
        }
        prevMem = s.memory

        if let g = Registry.gpuStats() {
            s.gpu.utilPct = g.deviceUtil; s.gpu.rendererPct = g.rendererUtil; s.gpu.tilerPct = g.tilerUtil
            s.gpu.inUseBytes = g.inUseBytes; s.gpu.allocBytes = g.allocBytes; s.gpu.resets = g.resets
        }

        let th = HostStats.thermal()
        s.thermal.state = th.state
        s.thermal.pressure = th.pressure

        let net = NetDisk.interfaces()
        s.network = net.filter { Self.isRealInterface($0.key) && ($0.value.rx > 0 || $0.value.tx > 0) }
            .sorted { $0.key < $1.key }
            .map { name, v in
                let p = prevNet[name]
                return NetInfo(name: name,
                               rxBps: p.flatMap { Counter.rate(prev: $0.rx, cur: v.rx, seconds: secs) },
                               txBps: p.flatMap { Counter.rate(prev: $0.tx, cur: v.tx, seconds: secs) },
                               baud: v.baud > 0 ? v.baud : nil, rxTotal: v.rx, txTotal: v.tx)
            }
        prevNet = net

        let blk = NetDisk.blockStats()
        if !prevBlock.isEmpty {
            var rb = 0.0, wb = 0.0, ro = 0.0, wo = 0.0, rns = 0.0, wns = 0.0, ok = true
            for (k, c) in blk {
                guard let p = prevBlock[k],
                      let a = Counter.rate(prev: p.readBytes, cur: c.readBytes, seconds: secs),
                      let b = Counter.rate(prev: p.writeBytes, cur: c.writeBytes, seconds: secs),
                      let c1 = Counter.rate(prev: p.readOps, cur: c.readOps, seconds: secs),
                      let d = Counter.rate(prev: p.writeOps, cur: c.writeOps, seconds: secs),
                      let e = Counter.rate(prev: p.readNs, cur: c.readNs, seconds: secs),
                      let f = Counter.rate(prev: p.writeNs, cur: c.writeNs, seconds: secs) else { ok = false; continue }
                rb += a; wb += b; ro += c1; wo += d; rns += e; wns += f
            }
            if ok {
                s.disks.readBps = rb; s.disks.writeBps = wb; s.disks.readOpsPerSec = ro; s.disks.writeOpsPerSec = wo
                // Latency only when the drive reports time (this SSD reports 0, so it stays nil).
                if ro > 0, rns > 0 { s.disks.readLatencyMs = rns / ro / 1e6 }
                if wo > 0, wns > 0 { s.disks.writeLatencyMs = wns / wo / 1e6 }
            }
        }
        s.disks.bytesReadSinceBoot = blk.isEmpty ? nil : blk.values.reduce(0) { $0 + $1.readBytes }
        s.disks.bytesWrittenSinceBoot = blk.isEmpty ? nil : blk.values.reduce(0) { $0 + $1.writeBytes }
        prevBlock = blk
        s.wakeTime = HostStats.wakeTime()
        cost.otherMs = Self.ms(since: t)

        // 60 s readers.
        if slow {
            t = Self.monotonic()
            readSlow()
            cost.slowMs = Self.ms(since: t)
        }

        // 5 s process table.
        if doProcs {
            t = Self.monotonic()
            let psText = await ProcessRunner.run("/bin/ps", ["-Aeo", "pid=,pcpu=,rss=,comm="])
            // A stale top table is dropped, so root processes keep their current ps CPU.
            processes = procSampler.sample(gpuNs: Registry.gpuTimeByPID(), top: top?.fresh(now: now), ps: psText.map(PSParser.parse))
            processesAt = now
            cost.processMs = Self.ms(since: t)
        }

        let held = pHold.apply(smcv, now: now)
        Self.fillSMC(&s, held.values, slow: slowSMC, pHeldSeconds: held.heldSeconds)
        s.thermal.cpuPLastRealAt = pHold.lastRealAt
        s.battery = battery
        s.display = display
        s.lidAngle = lid
        s.wifi = wifi
        s.disks.volumes = volumes
        s.disks.smart = smart
        s.power.wallW = battery?.externalConnected == true ? battery?.wallPowerW : nil
        s.thermal.ssdC = smart?.tempC.map { Double($0) } ?? hid.first { $0.name.hasPrefix("NAND") }?.celsius
        s.thermal.allSensors = allSensors
        s.thermal.allSensorsAt = allSensorsAt
        s.thermal.notReporting = sensorGaps.isEmpty ? nil : sensorGaps
        s.thermal.limitKeys = slowSMC.filter { ["mlT0", "mlT1", "mxT0", "mlMH"].contains($0.key) }
        s.topProcesses = Self.topUnion(processes)
        s.processesAt = processesAt
        let kt = Self.kernelTask(from: top, now: now)
        s.cpu.kernelTaskPct = kt.pct
        s.cpu.kernelTaskAt = kt.at

        // Fan state and "why is the fan on" over the last minute.
        recent.append(s)
        recent.removeAll { $0.ts < now.addingTimeInterval(-(FanExplainer.windowSeconds + 1)) }
        for i in s.fans.indices {
            if let a = s.fans[i].actualRPM {
                let trend = FanExplainer.targetTrend10s(window: recent, fanIndex: s.fans[i].index)
                s.fans[i].state = FanExplainer.state(actual: a, target: s.fans[i].targetRPM ?? a, targetTrend10s: trend)
            }
        }
        s.fanExplanation = FanExplainer.explain(window: recent)
        recent[recent.count - 1] = s

        prevTime = mono
        cost.totalMs = Self.ms(since: t0)
        lastTickCost = cost
        return s
    }

    /// kernel_task CPU from the last `top` reading (pid 0).
    public static func kernelTask(from r: TopReading?, now: Date) -> (pct: Double?, at: Date?) {
        guard let r, let pct = r.fresh(now: now)?[0]?.cpu else { return (nil, nil) }
        return (pct, r.at)
    }

    static func fillSMC(_ s: inout Snapshot, _ v: [String: Double], slow slowV: [String: Double], pHeldSeconds: Double? = nil) {
        s.power.systemW = v["PSTR"]
        s.power.adapterInW = v["PDTR"]
        s.power.batteryW = v["PPBR"]
        let count = Int(v["FNum"] ?? 0)
        s.fans = (0..<max(0, min(count, 4))).map { i in
            func k(_ suffix: String) -> Double? { v["F\(i)\(suffix)"] ?? slowV["F\(i)\(suffix)"] }
            return FanInfo(index: i, actualRPM: k("Ac"), targetRPM: k("Tg"), minRPM: k("Mn"), maxRPM: k("Mx"), duty: k("Dc"), state: nil)
        }
        let pKeys = v.keys.filter(PCoreKeys.isPCore).sorted()
        let temps = pKeys + SMCKeys.eCoreTemps + SMCKeys.gpuTemps + SMCKeys.otherTemps
        s.thermal.fastSensors = temps.compactMap { key in
            guard let c = v[key], SensorRules.isReal(c) else { return nil }
            let g = SMCGroup.group(for: key)
            return SensorReading(key: key, celsius: c, group: g.name, proven: g.proven, source: "SMC")
        }
        func maxOf(_ keys: [String]) -> Double? { keys.compactMap { v[$0] }.filter(SensorRules.isReal).max() }
        s.thermal.cpuPC = maxOf(pKeys)
        s.thermal.cpuEC = maxOf(SMCKeys.eCoreTemps)
        s.thermal.gpuC = maxOf(SMCKeys.gpuTemps)
        let hot = s.thermal.fastSensors.filter { ["P cores", "E cores", "GPU", "CPU max"].contains($0.group) }.max { $0.celsius < $1.celsius }
        s.thermal.hottestC = hot?.celsius
        s.thermal.hottestKey = hot?.key
        s.thermal.cpuPHeldSeconds = pHeldSeconds
        if let k = hot?.key, PCoreKeys.isPCore(k) { s.thermal.hottestHeldSeconds = pHeldSeconds }
        s.thermal.batteryC = v["TB0T"]
        s.thermal.palmRestC = maxOf(["Ts0P", "Ts1P"])
        s.thermal.ambientC = v["TVA0"]
    }

    private func readSlow() {
        battery = Registry.battery()
        display = Registry.display()
        lid = HIDSensors.lidAngle()
        smart = NVMe.read()
        hid = HIDSensors.temperatures()
        volumes = NetDisk.volumes()
        wifi = NetDisk.wifi()
        if let smc {
            for k in SMCKeys.slowSet { slowSMC[k] = smc.read(k) }
            if allTempKeys == nil { allTempKeys = smc.allKeys().filter { $0.hasPrefix("T") } }
            var raw: [String: Double] = [:]
            for k in allTempKeys ?? [] { if let c = smc.read(k) { raw[k] = c } }
            // The per-second P core keys follow whichever Tp keys gave real readings on this full read.
            pKeys = pPicker.update(raw, now: Date())
            let list = Self.buildAllSensors(keys: allTempKeys ?? [], raw: raw, hid: hid)
            allSensors = list.sensors
            sensorGaps = list.gaps
            allSensorsAt = Date()
        }
    }

    /// The once-a-minute list of every temperature sensor, plus groups that gave no real reading.
    static func buildAllSensors(keys: [String], raw rawIn: [String: Double], hid: [HIDTemp]) -> (sensors: [SensorReading], gaps: [SensorGap]) {
        // Same placeholder rule as the fast path for every Tp key.
        let raw = PCoreHold.dropPlaceholders(rawIn) { $0.hasPrefix("Tp") }
        var readings: [SensorReading] = []
        for k in keys {
            guard let c = raw[k], SensorRules.isReal(c) else { continue }
            let g = SMCGroup.group(for: k)
            readings.append(SensorReading(key: k, celsius: c, group: g.name, proven: g.proven, source: "SMC"))
        }
        // Same 10 C floor as SMC keys: nothing inside a running Mac is colder.
        for h in hid where SensorRules.isReal(h.celsius) {
            readings.append(SensorReading(key: h.name, celsius: h.celsius, group: Self.hidGroup(h.name), proven: true, source: "HID"))
        }
        var gaps: [SensorGap] = []
        if keys.contains(where: { $0.hasPrefix("Tp") }) && !readings.contains(where: { $0.key.hasPrefix("Tp") }) {
            gaps.append(SensorGap(group: "P cores", reason: "Every P core sensor gave a placeholder (exactly 0 or 40.000 C) on the last full read, so there is no real reading. These sensors often do this for a few seconds at a time."))
        }
        return (readings, gaps)
    }

    static func hidGroup(_ name: String) -> String {
        if name.hasPrefix("PMU tdie") { return "PMU die" }
        if name.hasPrefix("PMU tcal") { return "PMU calibration" }
        if name.hasPrefix("NAND") { return "SSD (NAND)" }
        if name.contains("battery") { return "Battery" }
        return "HID other"
    }

    static func isRealInterface(_ n: String) -> Bool {
        !["lo", "utun", "awdl", "llw", "anpi", "gif", "stf", "ap", "bridge"].contains { n.hasPrefix($0) }
    }

    /// Union of the top 10 by CPU, energy, GPU, memory and disk.
    public static func topUnion(_ all: [ProcSample], n: Int = 10) -> [ProcSample] {
        let keys: [(ProcSample) -> Double?] = [
            { $0.cpuPercent }, { $0.energyW }, { $0.gpuPercent }, { $0.memBytes.map { Double($0) } },
            { ($0.diskReadBps ?? 0) + ($0.diskWriteBps ?? 0) },
        ]
        var picked: [Int32: ProcSample] = [:]
        for k in keys {
            for p in all.filter({ (k($0) ?? 0) > 0 }).sorted(by: { (k($0) ?? 0) > (k($1) ?? 0) }).prefix(n) { picked[p.pid] = p }
        }
        return picked.values.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
    }

    /// A fresh snapshot without the app running: prime, wait `window`, sample again.
    /// `withTop` also runs top (about 2 s more) for kernel_task and root process CPU.
    public static func oneShot(window: Duration = .seconds(1), withTop: Bool = false) async -> Snapshot {
        let e = SampleEngine()
        _ = await e.tick(slow: true, processes: true)
        if withTop {
            async let topDone: Void = e.refreshTop()
            try? await Task.sleep(for: window)
            await topDone
        } else {
            try? await Task.sleep(for: window)
        }
        return await e.tick(slow: false, processes: true)
    }
}

/// Main-actor face of the engine for the app. Samples on fixed clocks (spec section 6) and publishes.
@MainActor public final class Sampler: ObservableObject {
    @Published public private(set) var latest: Snapshot?
    /// The full process table (every 5 s), for the Apps page.
    @Published public private(set) var processes: [ProcSample] = []
    public let engine = SampleEngine()
    public private(set) var mode: SampleMode = .normal
    /// Called on the main actor after each snapshot (the app writes history from here).
    public var onSnapshot: ((Snapshot) -> Void)?
    private var loop: Task<Void, Never>?
    private var topSchedule = TopSchedule()

    public init() {}

    public func start(mode: SampleMode) {
        self.mode = mode
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.mode == .eco ? 2 : 1
                let started = ContinuousClock.now
                let slow = n % max(1, 60 / interval) == 0
                let procs = n % max(1, 5 / interval) == 0
                if topSchedule.shouldRun(now: Date(), mode: self.mode, heating: TopSchedule.heating(self.latest)) {
                    let e = self.engine
                    Task.detached(priority: .utility) { await e.refreshTop() }
                }
                let snap = await self.engine.tick(slow: slow, processes: procs)
                self.latest = snap
                if procs { self.processes = await self.engine.processes }
                self.onSnapshot?(snap)
                n += 1
                let next = started.advanced(by: .seconds(interval))
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}

/// When to run `top` (root process CPU and energy impact, kernel_task). It costs about 0.7 s of CPU per run.
/// Window open: every 15 s. Menu bar only: nothing while the Mac is cool; when it heats up (thermal pressure above
/// nominal, or the fans speeding up) a burst of 3 runs 16 s apart, so the fresh readings span 32 s, enough for the
/// 30 s kernel_task alert. Then no new burst for 15 minutes, so a hot Mac costs at most 3 runs per 15 minutes
/// (about 2.2 s of CPU, 0.24% of one core averaged over that time).
public struct TopSchedule: Sendable {
    public static let every: TimeInterval = 15
    public static let burstEvery: TimeInterval = 16
    public static let burstRuns = 3
    /// Seconds between the start of one menu bar burst and the next.
    public static let burstCooldown = 900
    private var lastRun: Date?
    private var burstStart: Date?
    private var runsLeft = 0
    public init() {}

    public mutating func shouldRun(now: Date, mode: SampleMode, heating: Bool) -> Bool {
        // Half a second of slack, since the sampler's ticks drift a little.
        func due(_ every: TimeInterval) -> Bool { lastRun.map { now.timeIntervalSince($0) >= every - 0.5 } ?? true }
        if mode == .windowOpen {
            runsLeft = 0
            let run = due(Self.every)
            if run { lastRun = now }
            return run
        }
        if runsLeft == 0, heating, burstStart.map({ now.timeIntervalSince($0) >= Double(Self.burstCooldown) - 0.5 }) ?? true {
            runsLeft = Self.burstRuns
            burstStart = now
        }
        guard runsLeft > 0, due(Self.burstEvery) else { return false }
        runsLeft -= 1
        lastRun = now
        return true
    }

    /// Heating up: thermal pressure above nominal, or a fan more than 50 rpm below its target (speeding up).
    public static func heating(_ s: Snapshot?) -> Bool {
        guard let s else { return false }
        if (s.thermal.pressure ?? 0) > 0 { return true }
        return s.fans.contains { f in
            guard let a = f.actualRPM, let t = f.targetRPM else { return false }
            return t - a > 50
        }
    }
}

/// One `top` run: when it ran and what it saw (root process CPU and energy impact).
public struct TopReading: @unchecked Sendable {
    public var at: Date
    public var procs: [Int32: (cpu: Double, power: Double)]
    /// A reading older than this is stale (top runs every 15 s while the window is open).
    public static let maxAge: TimeInterval = 20
    public init(at: Date, procs: [Int32: (cpu: Double, power: Double)]) { self.at = at; self.procs = procs }
    /// The reading, or nil once it is stale.
    public func fresh(now: Date) -> [Int32: (cpu: Double, power: Double)]? {
        now.timeIntervalSince(at) <= Self.maxAge ? procs : nil
    }
}

/// Real temperatures only: SMC keys return 0 or a few degrees when a sensor has nothing to say.
public enum SensorRules {
    /// 10 C is colder than any part of a running Mac; SMC keys report 0 to 5 C when they have nothing to say.
    public static func isReal(_ c: Double) -> Bool { (10...150).contains(c) }
}

/// The P core SMC keys (Tp*) flip between real values and placeholders (exactly 0 or exactly 40.000) from one
/// second to the next on this M4 Pro, all at once or mixed. Each placeholder key is dropped; a tick with no real
/// P core key left is no reading. The last real set is held for
/// up to `maxHold` seconds, with its age, so the hottest temperature does not jump; after that it is nil.
public struct PCoreHold: Sendable {
    public static let maxHold: TimeInterval = 30
    public init() {}
    private var last: [String: Double] = [:]
    private var lastAt: Date?
    /// When the P core keys last gave a real reading.
    public var lastRealAt: Date? { lastAt }

    /// Removes every P core key that reads exactly 0 or exactly 40.000 on its own. Live reads are often mixed
    /// (some Tp keys at the placeholder next to real ones), so the rule works key by key. Other sensors are untouched.
    public static func dropPlaceholders(_ v: [String: Double], isPCore: (String) -> Bool) -> [String: Double] {
        v.filter { !(isPCore($0.key) && ($0.value == 0 || $0.value == 40)) }
    }

    public mutating func apply(_ v: [String: Double], now: Date) -> (values: [String: Double], heldSeconds: Double?) {
        let cleaned = Self.dropPlaceholders(v, isPCore: PCoreKeys.isPCore)
        let p = cleaned.filter { PCoreKeys.isPCore($0.key) }
        if !p.isEmpty {
            last = p
            lastAt = now
            return (cleaned, nil)
        }
        var out = cleaned.filter { !PCoreKeys.isPCore($0.key) }
        if let at = lastAt, now.timeIntervalSince(at) <= Self.maxHold {
            out.merge(last) { a, _ in a }
            return (out, now.timeIntervalSince(at))
        }
        return (out, nil)
    }
}
