import Foundation
import Darwin

public struct ProcSample: Codable, Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double?
    public var memBytes: UInt64?
    /// Watts from ri_energy_nj. Only our own processes have it.
    public var energyW: Double?
    /// Share of CPU time spent on P cores.
    public var pCorePercent: Double?
    public var gpuPercent: Double?
    public var wakeupsPerSec: Double?
    public var diskReadBps: Double?
    public var diskWriteBps: Double?
    /// top's POWER column: Apple's unitless energy impact score, not watts. Root processes too.
    public var energyImpact: Double?
    /// true when proc_pid_rusage worked (our own processes). Root processes only have ps / top / GPU data.
    public var isOwn: Bool

    public init(pid: Int32, name: String, cpuPercent: Double? = nil, memBytes: UInt64? = nil, energyW: Double? = nil,
                pCorePercent: Double? = nil, gpuPercent: Double? = nil, wakeupsPerSec: Double? = nil,
                diskReadBps: Double? = nil, diskWriteBps: Double? = nil, energyImpact: Double? = nil, isOwn: Bool) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.memBytes = memBytes; self.energyW = energyW
        self.pCorePercent = pCorePercent; self.gpuPercent = gpuPercent; self.wakeupsPerSec = wakeupsPerSec
        self.diskReadBps = diskReadBps; self.diskWriteBps = diskWriteBps; self.energyImpact = energyImpact; self.isOwn = isOwn
    }
}

/// One proc_pid_rusage reading, times already in ns.
public struct RawProc: Sendable {
    public var pid: Int32
    /// Process start time; a different value for the same pid means the pid was reused.
    public var startAbs: UInt64
    public var name: String
    public var cpuNs: UInt64
    public var pCoreNs: UInt64
    public var energyNJ: UInt64
    public var wakeups: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var footprintBytes: UInt64
}

/// Parses `ps -Aeo pid=,pcpu=,rss=,comm=`. The command is the rest of the line (it can hold spaces);
/// the name is its last path part.
public enum PSParser {
    public static func parse(_ text: String) -> [Int32: (cpu: Double, rssBytes: UInt64, name: String)] {
        var out: [Int32: (cpu: Double, rssBytes: UInt64, name: String)] = [:]
        for line in text.split(separator: "\n") {
            var rest = Substring(line)
            func field() -> Substring? {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
                defer { rest = rest[end...] }
                return rest[..<end]
            }
            guard let p = field(), let pid = Int32(p), let c = field(), let cpu = Double(c),
                  let r = field(), let rss = UInt64(r) else { continue }
            let comm = rest.trimmingCharacters(in: .whitespaces)
            guard !comm.isEmpty else { continue }
            let name = comm.hasPrefix("/") ? (comm as NSString).lastPathComponent : comm
            out[pid] = (cpu, rss * 1024, name)
        }
        return out
    }
}

/// Parses `/usr/bin/top -l 2 -s 1 -n 40 -stats pid,cpu,power,command`, using only the second
/// sample (top's first sample has no CPU deltas).
public enum TopParser {
    public static func parse(_ text: String) -> [Int32: (cpu: Double, power: Double)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [:] }
        var out: [Int32: (cpu: Double, power: Double)] = [:]
        for line in lines[(header + 1)...] {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let cpu = Double(f[1]), let power = Double(f[2]) else { continue }
            out[pid] = (cpu, power)
        }
        return out
    }
}

/// Runs a system tool off the calling thread with a timeout. Returns stdout, or nil on failure.
public enum ProcessRunner {
    public static func run(_ path: String, _ args: [String], timeout: Double = 5) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let ok = p.terminationReason == .exit && p.terminationStatus == 0
                cont.resume(returning: ok ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}

/// Per-process rates from proc_pid_rusage V6 deltas (own processes), merged with ps / top (root
/// processes) and GPU time (all processes). Keyed by pid plus start time, so a reused pid is new.
public final class ProcessSampler: @unchecked Sendable {
    private let reader: () -> [RawProc]
    private let clock: () -> Double
    private var prev: [Int32: RawProc] = [:]
    private var prevGPU: [Int32: UInt64] = [:]
    private var prevTime: Double?
    private let lock = NSLock()

    public init(reader: @escaping () -> [RawProc] = ProcessSampler.readOwn,
                clock: @escaping () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }) {
        self.reader = reader
        self.clock = clock
    }

    public func sample(gpuNs: [Int32: UInt64], top: [Int32: (cpu: Double, power: Double)]?,
                       ps: [Int32: (cpu: Double, rssBytes: UInt64, name: String)]? = nil) -> [ProcSample] {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let cur = reader()
        let secs = prevTime.map { now - $0 } ?? 0
        var out: [Int32: ProcSample] = [:]

        for c in cur {
            var s = ProcSample(pid: c.pid, name: ps?[c.pid]?.name ?? c.name, memBytes: c.footprintBytes, isOwn: true)
            if let p = prev[c.pid], p.startAbs == c.startAbs {
                let cpuNs = Counter.rate(prev: p.cpuNs, cur: c.cpuNs, seconds: secs)
                s.cpuPercent = cpuNs.map { $0 / 1e9 * 100 }
                s.energyW = Counter.rate(prev: p.energyNJ, cur: c.energyNJ, seconds: secs).map { $0 / 1e9 }
                if let all = cpuNs, all > 0, let pNs = Counter.rate(prev: p.pCoreNs, cur: c.pCoreNs, seconds: secs) {
                    s.pCorePercent = min(100, 100 * pNs / all)
                }
                s.wakeupsPerSec = Counter.rate(prev: p.wakeups, cur: c.wakeups, seconds: secs)
                s.diskReadBps = Counter.rate(prev: p.diskReadBytes, cur: c.diskReadBytes, seconds: secs)
                s.diskWriteBps = Counter.rate(prev: p.diskWriteBytes, cur: c.diskWriteBytes, seconds: secs)
            }
            out[c.pid] = s
        }
        for (pid, p) in ps ?? [:] where out[pid] == nil {
            out[pid] = ProcSample(pid: pid, name: p.name, cpuPercent: p.cpu, memBytes: p.rssBytes > 0 ? p.rssBytes : nil, isOwn: false)
        }
        for (pid, t) in top ?? [:] {
            if out[pid] == nil { out[pid] = ProcSample(pid: pid, name: pid == 0 ? "kernel_task" : "pid \(pid)", isOwn: false) }
            if out[pid]?.isOwn == false { out[pid]?.cpuPercent = t.cpu }
            out[pid]?.energyImpact = t.power
        }
        for (pid, ns) in gpuNs {
            guard let p = prevGPU[pid], let r = Counter.rate(prev: p, cur: ns, seconds: secs) else { continue }
            if out[pid] == nil { out[pid] = ProcSample(pid: pid, name: ps?[pid]?.name ?? "pid \(pid)", isOwn: false) }
            out[pid]?.gpuPercent = min(100, r / 1e9 * 100)
        }

        prev = Dictionary(cur.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        prevGPU = gpuNs
        prevTime = now
        return out.values.sorted { $0.pid < $1.pid }
    }

    /// proc_pid_rusage V6 for every process we may read (our own; root and other users are denied).
    public static func readOwn() -> [RawProc] {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let toNs = Double(tb.numer) / Double(tb.denom)
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var out: [RawProc] = []
        out.reserveCapacity(got)
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(max(0, got)) where pid > 0 {
            var ri = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { continue }
            nameBuf[0] = 0
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            out.append(RawProc(
                pid: pid, startAbs: ri.ri_proc_start_abstime, name: cstr(nameBuf),
                cpuNs: UInt64(Double(ri.ri_user_time + ri.ri_system_time) * toNs),
                pCoreNs: UInt64(Double(ri.ri_user_ptime + ri.ri_system_ptime) * toNs),
                energyNJ: ri.ri_energy_nj,
                wakeups: ri.ri_interrupt_wkups + ri.ri_pkg_idle_wkups,
                diskReadBytes: ri.ri_diskio_bytesread, diskWriteBytes: ri.ri_diskio_byteswritten,
                footprintBytes: ri.ri_phys_footprint))
        }
        return out
    }
}
