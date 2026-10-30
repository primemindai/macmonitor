import Foundation

// Small pure helpers the app uses. They live here so the test target can reach them.

/// Plain number formatting. A missing value is always "--", never a fake 0.
public enum Fmt {
    public static let missing = "--"

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    public static func int(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return grouped.string(from: NSNumber(value: v.rounded())) ?? missing
    }

    /// 2,310 -> "2.3k"; under 1,000 stays whole.
    public static func rpmShort(_ rpm: Double?) -> String {
        guard let rpm, rpm.isFinite else { return missing }
        if rpm < 1_000 { return String(Int(rpm.rounded())) }
        return String(format: "%.1fk", rpm / 1_000)
    }

    public static func rpm(_ rpm: Double?) -> String { int(rpm) }

    public static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return "\(Int(v.rounded()))%"
    }

    public static func temp(_ c: Double?) -> String {
        guard let c, c.isFinite else { return missing }
        return "\(Int(c.rounded()))°"
    }

    public static func watts(_ w: Double?) -> String {
        guard let w, w.isFinite else { return missing }
        if abs(w) >= 100 { return "\(Int(w.rounded())) W" }
        if abs(w) < 0.1, w != 0 { return String(format: "%.2f W", w) }
        return String(format: "%.1f W", w)
    }

    /// Decimal units (1 GB = 1e9 bytes), like Finder.
    public static func bytes(_ b: Double?) -> String {
        guard let b, b.isFinite else { return missing }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        while abs(v) >= 1_000, i < units.count - 1 { v /= 1_000; i += 1 }
        if i == 0 { return "\(Int(v.rounded())) B" }
        if abs(v) >= 100 { return "\(Int(v.rounded())) \(units[i])" }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func bytesU(_ b: UInt64?) -> String { bytes(b.map { Double($0) }) }
    public static func bytesI(_ b: Int64?) -> String { bytes(b.map { Double($0) }) }

    /// Memory in binary units with the labels Activity Monitor uses (48 GB of RAM, not 51.5).
    public static func mem(_ b: Double?) -> String {
        guard let b, b.isFinite else { return missing }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while abs(v) >= 1_024, i < units.count - 1 { v /= 1_024; i += 1 }
        if i == 0 { return "\(Int(v.rounded())) B" }
        if abs(v) >= 100 { return "\(Int(v.rounded())) \(units[i])" }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func rate(_ bps: Double?) -> String {
        guard let bps, bps.isFinite else { return missing }
        return bytes(bps) + "/s"
    }

    public static func mhz(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return "\(int(v)) MHz"
    }

    public static func num(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return missing }
        return String(format: "%.\(digits)f", v)
    }
}

/// The menu bar text, for example "CPU 42% · 71° · 2.3k" (CPU, hottest temp, loudest fan).
public enum MenuBarText {
    public static func make(_ s: Snapshot?) -> String {
        let fan = s?.fans.compactMap(\.actualRPM).max()
        return "CPU \(Fmt.pct(s?.cpu.totalPct)) · \(Fmt.temp(s?.thermal.hottestC)) · \(Fmt.rpmShort(fan))"
    }
}

/// Blue at 40 C, red at 100 C (spec section 5, Chip map).
public enum HeatScale {
    public static let cool = 40.0
    public static let hot = 100.0

    public static func fraction(_ c: Double) -> Double {
        guard c.isFinite else { return 0 }
        return min(1, max(0, (c - cool) / (hot - cool)))
    }

    /// Hue from 0 to 1 (220 degrees blue down to 0 red).
    public static func hue(_ c: Double) -> Double { (1 - fraction(c)) * 220.0 / 360.0 }
}

/// Fixed size buffer that keeps the newest values in order.
public struct RingBuffer<T> {
    public let capacity: Int
    private var storage: [T] = []
    private var head = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ x: T) {
        if storage.count < capacity { storage.append(x); return }
        storage[head] = x
        head = (head + 1) % capacity
    }

    public var elements: [T] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
    public var last: T? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    /// The newest `n` values, oldest first.
    public func suffix(_ n: Int) -> [T] { Array(elements.suffix(n)) }
}

/// Shrinks long series for charts (a 24 h window has 86,400 points).
public enum Downsample {
    public static func average(_ pts: [(Date, Double)], maxPoints: Int) -> [(Date, Double)] {
        guard maxPoints > 0, pts.count > maxPoints else { return pts }
        let per = Int((Double(pts.count) / Double(maxPoints)).rounded(.up))
        var out: [(Date, Double)] = []
        out.reserveCapacity(maxPoints)
        var i = 0
        while i < pts.count {
            let chunk = pts[i..<min(i + per, pts.count)]
            let t = chunk.reduce(0.0) { $0 + $1.0.timeIntervalSince1970 } / Double(chunk.count)
            let v = chunk.reduce(0.0) { $0 + $1.1 } / Double(chunk.count)
            out.append((Date(timeIntervalSince1970: t), v))
            i += per
        }
        return out
    }
}

/// Everything the app remembers between launches. Stored in UserDefaults as one JSON blob.
public struct AppPrefs: Codable, Equatable, Sendable {
    public var alerts = AlertSettings()
    /// Sample-rate preset: eco samples every 2 s while only the menu bar runs.
    public var eco = false
    /// True once the app has set up the login item the first time (so a user "off" sticks).
    public var loginItemConfigured = false
    /// True once the app asked for notification permission.
    public var notificationsAsked = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alerts = (try? c.decode(AlertSettings.self, forKey: .alerts)) ?? AlertSettings()
        eco = (try? c.decode(Bool.self, forKey: .eco)) ?? false
        loginItemConfigured = (try? c.decode(Bool.self, forKey: .loginItemConfigured)) ?? false
        notificationsAsked = (try? c.decode(Bool.self, forKey: .notificationsAsked)) ?? false
    }
}

public final class PrefsStore: @unchecked Sendable {
    public static let key = "prefs"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> AppPrefs {
        guard let d = defaults.data(forKey: Self.key), let p = try? JSONDecoder().decode(AppPrefs.self, from: d) else { return AppPrefs() }
        return p
    }

    public func save(_ p: AppPrefs) {
        if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: Self.key) }
    }
}

public enum AppActivation: Sendable { case regular, accessory }

/// The app lives in the menu bar; it shows in the Dock and Cmd-Tab only while its window is open.
public enum WindowPolicy {
    public static func activation(mainWindowVisible: Bool) -> AppActivation { mainWindowVisible ? .regular : .accessory }

    public static func sampleMode(windowOpen: Bool, eco: Bool) -> SampleMode {
        if windowOpen { return .windowOpen }
        return eco ? .eco : .normal
    }
}

/// Height of the menu bar popover. NSPopover places its window for its starting size; when the SwiftUI content
/// then turns out taller, the window grows up from a fixed bottom and its top goes under the menu bar. So the app
/// sizes the popover up front and never taller than the space under the menu bar item; taller content scrolls.
/// The fit-or-scroll choice itself is made by SwiftUI (ViewThatFits in MenuBarPopover) against this height.
public enum PopoverFit {
    /// Popover border and arrow around the content (measured: the window is 26 pt taller than its content).
    public static let chrome = 26.0
    /// Gap kept above the Dock or the bottom of the screen.
    public static let margin = 8.0
    /// Floor so a tiny screen never gets a zero or negative height.
    public static let minHeight = 160.0

    /// Tallest content that fits between the bottom of the menu bar item and the bottom of the visible screen.
    public static func maxContentHeight(anchorMinY: Double, visibleMinY: Double) -> Double {
        max(minHeight, anchorMinY - visibleMinY - chrome - margin)
    }
}

/// Whether the window opens at launch. A login launch (`--background`, or a login item) stays in the menu bar.
public enum LaunchWindow {
    public static let backgroundFlag = "--background"
    public static func showAtLaunch(arguments: [String], hasOpenEvent: Bool, isLoginItem: Bool) -> Bool {
        hasOpenEvent && !isLoginItem && !arguments.contains(backgroundFlag)
    }
}

/// Fallback login item when SMAppService cannot register an ad-hoc signed app.
public enum LaunchAgentPlist {
    public static let label = "com.macmonitor.app"

    public static func data(executable: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, LaunchWindow.backgroundFlag],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public static func url(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}

/// How fast the fan icon turns. Real fans spin far too fast to draw, so this is a calm visual scale.
public enum FanSpin {
    public static let maxTurnsPerSecond = 3.0
    public static func turnsPerSecond(rpm: Double?) -> Double {
        guard let rpm, rpm.isFinite, rpm >= 100 else { return 0 }
        return min(maxTurnsPerSecond, rpm / 2_000)
    }
}

/// History chart windows on detail rows.
public enum TimeRange: String, CaseIterable, Sendable {
    case m15, h1, h24, d30
    public var seconds: TimeInterval {
        switch self {
        case .m15: return 900
        case .h1: return 3_600
        case .h24: return 86_400
        case .d30: return 30 * 86_400
        }
    }
    public var label: String {
        switch self {
        case .m15: return "15m"
        case .h1: return "1h"
        case .h24: return "24h"
        case .d30: return "30d"
        }
    }
    /// 30 days reads the per-minute rollups (with min and max); shorter windows read 1 Hz rows.
    public var usesMinuteRollups: Bool { self == .d30 }
}

/// One logical CPU with the IOReport channel names for its watts and clock.
public struct CoreSlot: Equatable, Sendable {
    public var index: Int
    public var kind: CoreKind
    public var label: String
    public var cluster: Int
    public var wattKey: String
    public var mhzKey: String
}

/// Maps logical CPUs (E cores first on Apple silicon) to IOReport channel names.
/// P cores split evenly into two clusters when there are more than 6 (M4 Pro: 2 x 5).
public enum CoreMap {
    public static func slots(kinds: [CoreKind]) -> [CoreSlot] {
        let pCount = kinds.filter { $0 == .performance }.count
        let pPerCluster = pCount > 6 ? Int((Double(pCount) / 2).rounded(.up)) : max(1, pCount)
        var e = 0, p = 0
        return kinds.enumerated().map { i, k in
            switch k {
            case .efficiency:
                defer { e += 1 }
                return CoreSlot(index: i, kind: k, label: "E\(e + 1)", cluster: 0, wattKey: "EACC_CPU\(e)", mhzKey: "ECPU0\(e)0")
            case .performance:
                defer { p += 1 }
                let c = p / pPerCluster, n = p % pPerCluster
                return CoreSlot(index: i, kind: k, label: "P\(p + 1)", cluster: c, wattKey: "PACC\(c)_CPU\(n)", mhzKey: "PCPU\(c)\(n)0")
            }
        }
    }
}

/// CPU seconds used by this process and by the child processes it has waited for (ps, top).
public enum CPUUsage {
    public static func seconds() -> (own: Double, children: Double) {
        func s(_ who: Int32) -> Double {
            var r = rusage()
            getrusage(who, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        return (s(RUSAGE_SELF), s(RUSAGE_CHILDREN))
    }
}

/// One running copy of the app. The menu bar app holds an exclusive lock on a file while it runs; a second copy
/// that cannot get the lock quits. Render mode never takes it, so a render copy can never make the app quit.
public final class InstanceLock {
    public static let defaultPath = NSHomeDirectory() + "/Library/Application Support/MacMonitor/instance.lock"
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }

    /// The lock, or nil when another copy holds it. The kernel drops the lock when the process ends, even on a crash.
    public static func acquire(path: String = defaultPath) -> InstanceLock? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        // A lock file that cannot be opened must not stop the app from starting: run without the lock.
        guard fd >= 0 else { return InstanceLock(fd: -1) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return InstanceLock(fd: fd)
    }

    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
