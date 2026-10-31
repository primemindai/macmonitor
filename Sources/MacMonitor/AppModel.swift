import SwiftUI
import Combine
import MonitorCore

/// Sidebar pages.
enum Page: String, CaseIterable, Identifiable, Sendable {
    case overview, chipMap, heat, cpu, gpu, memory, power, disks, network, apps, events, settings, connectAI, updates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .chipMap: return "Chip map"
        case .heat: return "Heat & fans"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .power: return "Power & battery"
        case .disks: return "Disks"
        case .network: return "Network"
        case .apps: return "Apps"
        case .events: return "Events"
        case .settings: return "Settings"
        case .connectAI: return "Connect AI"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .chipMap: return "cpu.fill"
        case .heat: return "thermometer.medium"
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .power: return "battery.100percent.bolt"
        case .disks: return "internaldrive"
        case .network: return "network"
        case .apps: return "app.badge"
        case .events: return "bell.badge"
        case .settings: return "gearshape"
        case .connectAI: return "point.3.connected.trianglepath.dotted"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// The app's single source of truth. Samples on the engine's clocks, keeps 10 minutes in memory for live charts,
/// writes history off the main thread, runs the event detector and fires notifications.
@MainActor final class AppModel: ObservableObject {
    static let ringSize = 600

    let sampler = Sampler()
    @Published private(set) var latest: Snapshot?
    @Published private(set) var processes: [ProcSample] = []
    /// Bumps once per snapshot; charts use it to start their scroll animation.
    @Published private(set) var tick = 0
    @Published var page: Page = .overview
    @Published private(set) var recentEvents: [MonitorEvent] = []
    @Published private(set) var historyBytes: Int64 = 0
    @Published var notificationStatus = "Not asked yet"
    @Published var loginItem = LoginItem.Status(enabled: false, method: "none", note: nil)
    @Published var prefs: AppPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefsStore.save(prefs)
            detector.settings = prefs.alerts
            applyMode()
        }
    }

    private(set) var ring = RingBuffer<Snapshot>(capacity: ringSize)
    let store: HistoryStore?
    let writesHistory: Bool
    let storeError: String?
    private let detector: EventDetector
    private let prefsStore: PrefsStore
    private let writeQueue = DispatchQueue(label: "macmonitor.history", qos: .utility)
    private(set) var windowOpen = false
    var notifier: Notifier?
    /// The update check and "Update now". Live only when this copy writes history (not in render mode).
    let updates: UpdateModel
    private var cpuLogPath: String?
    private var lastCPULog = Date.distantPast
    private var lastTickCost: TickCost?

    /// `writesHistory` false (render mode) opens the history read only and never writes it.
    init(writesHistory: Bool, defaults: UserDefaults = .standard) {
        self.writesHistory = writesHistory
        updates = UpdateModel(defaults: defaults, live: writesHistory)
        prefsStore = PrefsStore(defaults: defaults)
        let p = prefsStore.load()
        prefs = p
        detector = EventDetector(settings: p.alerts)
        var err: String?
        if writesHistory {
            do {
                try FileManager.default.createDirectory(at: HistoryStore.defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                store = try HistoryStore(path: HistoryStore.defaultURL, readOnly: false)
            } catch { store = nil; err = "\(error)" }
        } else {
            store = try? HistoryStore(path: HistoryStore.defaultURL, readOnly: true)
        }
        storeError = err
        cpuLogPath = defaults.string(forKey: "cpuLogPath")
        historyBytes = store?.fileSizeBytes() ?? 0
        if let store { recentEvents = (try? store.events(since: Date().addingTimeInterval(-30 * 86_400), kind: nil)) ?? [] }
        sampler.onSnapshot = { [weak self] s in self?.ingest(s) }
        // Pick up `defaults write com.macmonitor.app prefs ...` made while the app runs (KVO sees other processes).
        defaultsObserver = PrefsObserver(defaults: defaults) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let fresh = self.prefsStore.load()
                if fresh != self.prefs { self.prefs = fresh }
            }
        }
    }
    private var defaultsObserver: PrefsObserver?

    func start() { sampler.start(mode: WindowPolicy.sampleMode(windowOpen: windowOpen, eco: prefs.eco)) }

    func setWindowOpen(_ open: Bool) {
        windowOpen = open
        applyMode()
    }

    private func applyMode() {
        let mode = WindowPolicy.sampleMode(windowOpen: windowOpen, eco: prefs.eco)
        if sampler.mode != mode {
            sampler.stop()
            sampler.start(mode: mode)
        }
    }

    private func ingest(_ s: Snapshot) {
        let prevProcsAt = latest?.processesAt
        ring.append(s)
        latest = s
        if s.processesAt != prevProcsAt { processes = sampler.processes }
        tick &+= 1

        for (event, notify) in detector.ingest(s) {
            recentEvents.insert(event, at: 0)
            if let store, writesHistory { writeQueue.async { try? store.writeEvent(event) } }
            if notify { notifier?.post(event) }
        }
        if recentEvents.count > 2_000 { recentEvents.removeLast(recentEvents.count - 2_000) }

        if let store, writesHistory {
            writeQueue.async { [weak self] in
                let t0 = DispatchTime.now().uptimeNanoseconds
                try? store.write(s)
                try? store.maintainIfDue(now: s.ts)
                WriteTimer.shared.add(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                if s.ts.timeIntervalSince1970.truncatingRemainder(dividingBy: 30) < 1 {
                    let size = store.fileSizeBytes()
                    Task { @MainActor in self?.historyBytes = size }
                }
            }
        }
        logCPUIfAsked()
    }

    /// When `defaults write com.macmonitor.app cpuLogPath <file>` is set, appends
    /// "epoch own_cpu_s children_cpu_s" every 5 s so scripts/measure-cpu.sh can count ps and top too.
    private func logCPUIfAsked() {
        guard let path = cpuLogPath, Date().timeIntervalSince(lastCPULog) >= 5 else { return }
        lastCPULog = Date()
        let u = CPUUsage.seconds()
        let c = lastTickCost
        let line = String(format: "%.3f %.3f %.3f tick_ms %.2f smc %.2f ior %.2f other %.2f procs %.2f write_ms %.2f\n",
                          Date().timeIntervalSince1970, u.own, u.children, c?.totalMs ?? 0, c?.smcMs ?? 0, c?.ioreportMs ?? 0,
                          c?.otherMs ?? 0, c?.processMs ?? 0, WriteTimer.shared.takeAverage())
        let e = sampler.engine
        Task { @MainActor [weak self] in self?.lastTickCost = await e.lastTickCost }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    // MARK: data for views

    var history: [Snapshot] { ring.elements }

    /// The newest `n` values of one reading, padded at the front with nil so charts keep a fixed width.
    func series(_ n: Int, _ f: (Snapshot) -> Double?) -> [Double?] {
        let v = ring.suffix(n).map(f)
        return Array(repeating: nil, count: max(0, n - v.count)) + v
    }

    func historySeries(metric: String, range: TimeRange) async -> [ChartPoint] {
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.loadHistory(store: store, metric: metric, range: range)
        }.value
    }

    nonisolated static func loadHistory(store: HistoryStore, metric: String, range: TimeRange) -> [ChartPoint] {
        let to = Date(), from = to.addingTimeInterval(-range.seconds)
        if range.usesMinuteRollups {
            let rows = (try? store.seriesMinute(metric: metric, from: from, to: to)) ?? []
            let step = max(1, rows.count / 360)
            return stride(from: 0, to: rows.count, by: step).map { i in
                let chunk = rows[i..<min(i + step, rows.count)]
                let avgs = chunk.compactMap(\.avg)
                return ChartPoint(ts: chunk.first!.ts, value: avgs.isEmpty ? nil : avgs.reduce(0, +) / Double(avgs.count),
                                  min: chunk.compactMap(\.min).min(), max: chunk.compactMap(\.max).max())
            }
        }
        let pts = (try? store.series(metric: metric, from: from, to: to)) ?? []
        return Downsample.average(pts, maxPoints: 360).map { ChartPoint(ts: $0.0, value: $0.1, min: nil, max: nil) }
    }

    func clearHistory() {
        guard let store, writesHistory else { return }
        writeQueue.async { [weak self] in
            try? store.clearAll()
            let size = store.fileSizeBytes()
            Task { @MainActor in
                self?.historyBytes = size
                self?.recentEvents = []
            }
        }
    }

    func setAlert(_ kind: String, on: Bool) { prefs.alerts.enabled[kind] = on }
}

struct ChartPoint: Identifiable, Sendable {
    var ts: Date
    var value: Double?
    var min: Double?
    var max: Double?
    var id: Date { ts }
}

/// Average time of history writes, for the CPU log only.
final class WriteTimer: @unchecked Sendable {
    static let shared = WriteTimer()
    private let lock = NSLock()
    private var sum = 0.0, n = 0
    func add(_ ms: Double) { lock.lock(); sum += ms; n += 1; lock.unlock() }
    func takeAverage() -> Double {
        lock.lock(); defer { sum = 0; n = 0; lock.unlock() }
        return n == 0 ? 0 : sum / Double(n)
    }
}

/// KVO on the prefs key of UserDefaults. Fires for changes from this app and from `defaults write`.
final class PrefsObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let onChange: @Sendable () -> Void
    init(defaults: UserDefaults, onChange: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: PrefsStore.key, options: [.new], context: nil)
    }
    deinit { defaults.removeObserver(self, forKeyPath: PrefsStore.key) }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        onChange()
    }
}
