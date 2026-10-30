import Foundation

/// One headline number we keep history for.
public struct Metric: Sendable {
    public let name: String
    public let unit: String
    public let description: String
    public let extract: @Sendable (Snapshot) -> Double?
}

public enum MetricCatalog {
    private static func m(_ name: String, _ unit: String, _ desc: String, _ f: @escaping @Sendable (Snapshot) -> Double?) -> Metric {
        Metric(name: name, unit: unit, description: desc, extract: f)
    }
    private static func sum(_ xs: [Double?]) -> Double? {
        let v = xs.compactMap { $0 }
        return v.isEmpty ? nil : v.reduce(0, +)
    }
    private static func mean(_ xs: [Double?]) -> Double? {
        let v = xs.compactMap { $0 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    public static let all: [Metric] = [
        m("cpu.total_pct", "%", "CPU busy, all cores", { $0.cpu.totalPct }),
        m("cpu.p_pct", "%", "CPU busy, P cores", { $0.cpu.pPct }),
        m("cpu.e_pct", "%", "CPU busy, E cores", { $0.cpu.ePct }),
        m("cpu.p_mhz", "MHz", "P clusters: clock they ran at (PCPM, average of both clusters)",
          { mean([$0.cpu.clocks?.pCluster0MHz, $0.cpu.clocks?.pCluster1MHz]) }),
        m("cpu.e_mhz", "MHz", "E cluster: clock it ran at (ECPM)", { $0.cpu.clocks?.eClusterMHz }),
        m("cpu.load1", "load", "1 minute load average", { $0.cpu.loadAvg.first }),
        m("cpu.kernel_task_pct", "%", "kernel_task CPU from top (high = throttle sign)", { $0.cpu.kernelTaskPct }),
        m("gpu.util_pct", "%", "GPU device utilization", { $0.gpu.utilPct }),
        m("gpu.mhz", "MHz", "GPU clock while active", { $0.gpu.mhz }),
        m("gpu.active_pct", "%", "GPU time not powered off", { $0.gpu.activePct }),
        m("gpu.mem_used_bytes", "bytes", "GPU memory in use", { $0.gpu.inUseBytes.map { Double($0) } }),
        m("power.system_w", "W", "Whole system power (SMC PSTR)", { $0.power.systemW }),
        m("power.adapter_w", "W", "Power in from the adapter (SMC PDTR)", { $0.power.adapterInW }),
        m("power.battery_w", "W", "Battery power (SMC PPBR)", { $0.power.batteryW }),
        m("power.wall_w", "W", "Wall power in (battery telemetry, once a minute)", { $0.power.wallW }),
        m("power.cpu_w", "W", "CPU power (IOReport)", { $0.power.breakdown?.cpuW }),
        m("power.p_cluster_w", "W", "Both P clusters (IOReport)", { sum([$0.power.breakdown?.pCluster0W, $0.power.breakdown?.pCluster1W]) }),
        m("power.e_cluster_w", "W", "E cluster (IOReport)", { $0.power.breakdown?.eClusterW }),
        m("power.gpu_w", "W", "GPU (IOReport GPU channel)", { $0.power.breakdown?.gpuW }),
        m("power.ane_w", "W", "Neural Engine (IOReport)", { $0.power.breakdown?.aneW }),
        m("power.dram_w", "W", "DRAM (IOReport)", { $0.power.breakdown?.dramW }),
        m("power.mem_system_w", "W", "Memory controller and fabric, AMCC + DCS (IOReport)", { $0.power.breakdown?.memSystemW }),
        m("temp.hottest_c", "C", "Hottest CPU or GPU SMC sensor. When the hottest is a P core sensor, it can repeat a held value for up to 30 s while the P core sensors give no reading", { $0.thermal.hottestC }),
        m("temp.cpu_p_c", "C", "Hottest P core area sensor (best guess label). Can repeat a held value for up to 30 s while the P core sensors give no reading", { $0.thermal.cpuPC }),
        m("temp.cpu_e_c", "C", "Hottest E core area sensor (best guess label)", { $0.thermal.cpuEC }),
        m("temp.gpu_c", "C", "Hottest GPU area sensor (best guess label)", { $0.thermal.gpuC }),
        m("temp.ssd_c", "C", "SSD temperature (NVMe SMART)", { $0.thermal.ssdC }),
        m("temp.battery_c", "C", "Battery temperature (SMC TB0T, proven)", { $0.thermal.batteryC }),
        m("fan0.rpm", "RPM", "Fan 1 actual speed", { $0.fan(0)?.actualRPM }),
        m("fan0.target_rpm", "RPM", "Fan 1 target speed", { $0.fan(0)?.targetRPM }),
        m("fan1.rpm", "RPM", "Fan 2 actual speed", { $0.fan(1)?.actualRPM }),
        m("fan1.target_rpm", "RPM", "Fan 2 target speed", { $0.fan(1)?.targetRPM }),
        m("mem.used_bytes", "bytes", "Memory used (app + wired + compressed)", { $0.memory.usedBytes.map { Double($0) } }),
        m("mem.compressed_bytes", "bytes", "Compressed memory size in RAM", { $0.memory.compressedBytes.map { Double($0) } }),
        m("mem.swap_used_bytes", "bytes", "Swap used", { $0.memory.swapUsed.map { Double($0) } }),
        m("mem.pressure", "level", "Memory pressure: 1 normal, 2 warn, 4 critical", { $0.memory.pressureLevel.map { Double($0) } }),
        m("mem.swapouts_per_s", "pages/s", "Pages swapped out to the SSD per second", { $0.memoryRates.swapoutsPerSec }),
        m("net.rx_bps", "bytes/s", "Network download, all real interfaces", { sum($0.network.map(\.rxBps)) }),
        m("net.tx_bps", "bytes/s", "Network upload, all real interfaces", { sum($0.network.map(\.txBps)) }),
        m("disk.read_bps", "bytes/s", "Disk read speed", { $0.disks.readBps }),
        m("disk.write_bps", "bytes/s", "Disk write speed", { $0.disks.writeBps }),
        m("thermal.pressure", "level", "Thermal pressure: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping",
          { $0.thermal.pressure.map { Double($0) } }),
        m("thermal.state", "level", "macOS thermal state: 0 nominal, 1 fair, 2 serious, 3 critical", { $0.thermal.state.map { Double($0) } }),
        m("battery.pct", "%", "Battery charge", { $0.battery?.percent.map { Double($0) } }),
    ]

    private static let byName: [String: Metric] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    public static func metric(named n: String) -> Metric? { byName[n] }
}
