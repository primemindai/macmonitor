import Foundation

/// Alert switches and thresholds (spec section 9). Stored by the app in UserDefaults as JSON.
public struct AlertSettings: Codable, Equatable, Sendable {
    /// Per kind. A missing kind counts as on.
    public var enabled: [String: Bool] = [:]
    public var fanLoudRPM: Double = 5_000
    public var fanQuietRPM: Double = 3_500
    public var quietMinutes: Double = 10
    public var cooldownMinutes: Double = 15
    public var ssdHotC: Double = 70
    public var diskLowGB: Double = 10
    public var swapPct: Double = 90
    public var kernelTaskPct: Double = 50

    public init() {}

    public func isEnabled(_ kind: String) -> Bool { enabled[kind] ?? true }

    /// Every event kind with a plain label, in Settings order. "wake" is logged but never notifies.
    public static let kinds: [(kind: String, label: String)] = [
        ("fan_ramp", "Fans ramp up"),
        ("thermal_pressure", "Thermal pressure heavy or worse"),
        ("throttle", "Throttle signs"),
        ("memory_pressure", "Memory pressure warn or critical"),
        ("swap_high", "Swap almost full"),
        ("disk_low", "Startup disk low"),
        ("ssd_hot", "SSD hot"),
        ("battery_flag", "Battery health flag changes"),
        ("wake", "Mac woke from sleep (log only)"),
    ]
}

/// Turns a stream of snapshots into Events rows and notification decisions.
/// Every event is returned (so the Events log is complete); `notify` says whether to show a Mac notification.
public final class EventDetector: @unchecked Sendable {
    public var settings: AlertSettings
    private var prev: Snapshot?
    private var lastNotify: [String: Date] = [:]

    // fan_ramp
    private var quietStart: Date?
    private var armed = false
    private var loud = false
    // latches with hysteresis
    private var throttleCLTM = false
    private var kernelHighSince: Date?
    private var kernelLatched = false
    private var lastKernelAt: Date?
    private var swapHigh = false
    private var diskLow = false
    private var ssdHot = false

    public init(settings: AlertSettings) { self.settings = settings }

    public func ingest(_ s: Snapshot) -> [(event: MonitorEvent, notify: Bool)] {
        var out: [(event: MonitorEvent, notify: Bool)] = []
        func emit(_ kind: String, _ title: String, _ body: String, wantNotify: Bool = true) {
            var notify = false
            if wantNotify, kind != "wake", settings.isEnabled(kind) {
                let cd = settings.cooldownMinutes * 60
                if let l = lastNotify[kind], s.ts.timeIntervalSince(l) < cd { notify = false } else {
                    notify = true
                    lastNotify[kind] = s.ts
                }
            }
            out.append((MonitorEvent(ts: s.ts, kind: kind, title: title, body: body), notify))
        }

        fanRamp(s, emit)

        // Throttle sign: kernel_task busy for 30 s, counted over distinct fresh `top` readings (needs no previous
        // snapshot). The same reading repeated on many ticks counts once; readings more than 40 s apart restart the count.
        if let k = s.cpu.kernelTaskPct {
            let at = s.cpu.kernelTaskAt ?? s.ts
            if at != lastKernelAt {
                let continuous = lastKernelAt.map { at.timeIntervalSince($0) <= 40 } ?? true
                lastKernelAt = at
                if k > settings.kernelTaskPct {
                    if kernelHighSince == nil || !continuous { kernelHighSince = at; kernelLatched = false }
                    if !kernelLatched, let since = kernelHighSince, at.timeIntervalSince(since) >= 30 {
                        kernelLatched = true
                        emit("throttle", "Throttle sign: kernel_task at \(Int(k.rounded()))% CPU",
                             "kernel_task has been over \(Int(settings.kernelTaskPct))% CPU for 30 seconds. macOS uses it to slow the Mac when it is hot.")
                    }
                } else {
                    kernelHighSince = nil
                    kernelLatched = false
                }
            }
        }


        let p = prev
        prev = s
        guard let p else { primeLatches(s); return out }

        // Thermal pressure: log every change, notify at heavy (2) or worse when it rises.
        if let now = s.thermal.pressure, let was = p.thermal.pressure, now != was {
            emit("thermal_pressure", "Thermal pressure is \(Self.pressureName(now))",
                 "It was \(Self.pressureName(was)). macOS slows the Mac down to cool it at heavy or worse.",
                 wantNotify: now >= 2 && now > was)
        }

        // Throttle: GPU heat cap, or kernel_task busy for 30 s.
        let capped = s.gpu.cltm.map { $0 != "NO_CLTM" } ?? false
        if capped && !throttleCLTM {
            emit("throttle", "Throttle sign: heat is capping the GPU", "The GPU heat cap state is \(s.gpu.cltm ?? "unknown").")
        }
        throttleCLTM = capped
        // Memory pressure: 1 normal, 2 warn, 4 critical.
        if let now = s.memory.pressureLevel, let was = p.memory.pressureLevel, now != was {
            emit("memory_pressure", "Memory pressure is \(Self.memName(now))", "It was \(Self.memName(was)).",
                 wantNotify: now >= 2 && now > was)
        }

        // Swap almost full.
        if let used = s.memory.swapUsed, let total = s.memory.swapTotal, total > 0 {
            let pct = 100 * Double(used) / Double(total)
            if pct > settings.swapPct && !swapHigh {
                swapHigh = true
                emit("swap_high", "Swap is \(Int(pct.rounded()))% full",
                     String(format: "%.1f of %.1f GB swap used. Swap writes go to the SSD.", Double(used) / 1e9, Double(total) / 1e9))
            } else if pct < settings.swapPct - 5 { swapHigh = false }
        }

        // Startup disk low.
        if let root = s.disks.volumes.first(where: { $0.path == "/" }) {
            let gb = Double(root.importantFree) / 1e9
            if gb < settings.diskLowGB && !diskLow {
                diskLow = true
                emit("disk_low", String(format: "Startup disk has %.1f GB free", gb), "\(root.name) is almost full.")
            } else if gb > settings.diskLowGB + 2 { diskLow = false }
        }

        // SSD hot.
        if let t = s.thermal.ssdC {
            if t > settings.ssdHotC && !ssdHot {
                ssdHot = true
                emit("ssd_hot", "SSD is at \(Int(t.rounded())) C", "The SSD reports more than \(Int(settings.ssdHotC)) C.")
            } else if t < settings.ssdHotC - 5 { ssdHot = false }
        }

        // Battery health flag changes.
        if let now = s.battery?.iopsHealth, let was = p.battery?.iopsHealth, now != was {
            emit("battery_flag", "Battery flag changed to \(now)", "It was \(was). This is the macOS battery health flag.")
        }

        // Wake (log only).
        // The first wake after boot goes from no wake time (kern.waketime is 0 before any sleep) to a date.
        if let w = s.wakeTime, w != p.wakeTime {
            emit("wake", "Mac woke from sleep", "Wake time \(ISO8601DateFormatter().string(from: w)).", wantNotify: false)
        }
        return out
    }

    /// The first snapshot sets the latches, so starting the app on a full disk does not count as "became full".
    private func primeLatches(_ s: Snapshot) {
        throttleCLTM = s.gpu.cltm.map { $0 != "NO_CLTM" } ?? false
        if let used = s.memory.swapUsed, let total = s.memory.swapTotal, total > 0 {
            swapHigh = 100 * Double(used) / Double(total) > settings.swapPct
        }
        if let root = s.disks.volumes.first(where: { $0.path == "/" }) { diskLow = Double(root.importantFree) / 1e9 < settings.diskLowGB }
        if let t = s.thermal.ssdC { ssdHot = t > settings.ssdHotC }
    }

    /// Fan ramp: target crosses into loud after a quiet run of at least `quietMinutes`. Staying loud never re-fires.
    private func fanRamp(_ s: Snapshot, _ emit: (String, String, String, Bool) -> Void) {
        guard let t = s.fans.compactMap({ $0.targetRPM ?? $0.actualRPM }).max() else { return }
        if t < settings.fanQuietRPM {
            if quietStart == nil { quietStart = s.ts }
        } else if let q = quietStart {
            armed = s.ts.timeIntervalSince(q) >= settings.quietMinutes * 60
            quietStart = nil
        }
        if t >= settings.fanLoudRPM && !loud {
            loud = true
            let body = s.fanExplanation?.headline ?? "Fan target is \(FanExplainer.rpm(t)) RPM."
            emit("fan_ramp", "Fans ramped up to \(FanExplainer.rpm(t)) RPM", body, armed)
            armed = false
        } else if t < settings.fanLoudRPM - 500 {
            loud = false
        }
    }

    static func pressureName(_ l: Int) -> String {
        ["nominal", "moderate", "heavy", "trapping", "sleeping"].indices.contains(l) ? ["nominal", "moderate", "heavy", "trapping", "sleeping"][l] : "level \(l)"
    }

    static func memName(_ l: Int) -> String {
        switch l { case 1: return "normal"; case 2: return "warn"; case 4: return "critical"; default: return "level \(l)" }
    }
}
