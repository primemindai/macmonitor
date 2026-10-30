import SwiftUI
import MonitorCore

struct HeatPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        PageScroll(title: "Heat & fans", subtitle: "Click a row to open its history.") {
            FanHeadline(explanation: s?.fanExplanation, rpm: s?.fans.compactMap(\.actualRPM).max())

            RowGroup(title: "Fans", note: "read only, MacMonitor never controls the fans") {
                if let fans = s?.fans, !fans.isEmpty {
                    ForEach(fans, id: \.index) { f in fanRow(f) }
                } else { NotAvailable(text: "No fan readings") }
            }

            RowGroup(title: "Hottest now") {
                let hot = (s?.thermal.fastSensors ?? []).sorted { $0.celsius > $1.celsius }.prefix(5)
                ForEach(Array(hot.enumerated()), id: \.element.key) { i, r in
                    DetailRow(title: r.key, value: Fmt.temp(r.celsius), numeric: r.celsius, fraction: HeatScale.fraction(r.celsius),
                              color: Theme.heat(r.celsius), detail: hottestDetail(r), bestGuess: !r.proven,
                              history: i == 0 ? .metric("temp.hottest_c") : .live({ snap in snap.thermal.fastSensors.first { $0.key == r.key }?.celsius }),
                              unit: { Fmt.temp($0) })
                }
            }

            RowGroup(title: "Main areas") {
                tempRow("P cores (hottest)", s?.thermal.cpuPC, metric: "temp.cpu_p_c", guess: true,
                        detail: s?.thermal.cpuPHeldSeconds.map { "from \(Int($0.rounded())) s ago, sensors gave no reading since" }, open: true,
                        missing: secondsAgo(s?.thermal.cpuPLastRealAt).map { "P cores: no reading (last real reading \($0) s ago)" }
                            ?? "P cores: no reading yet (the sensors have only given placeholders since the app started)")
                tempRow("E cores (hottest)", s?.thermal.cpuEC, metric: "temp.cpu_e_c", guess: true)
                tempRow("GPU (hottest)", s?.thermal.gpuC, metric: "temp.gpu_c", guess: true)
                tempRow("SSD", s?.thermal.ssdC, metric: "temp.ssd_c", guess: false, detail: "NVMe SMART")
                tempRow("Battery", s?.thermal.batteryC, metric: "temp.battery_c", guess: false, detail: "SMC TB0T")
                tempRow("Palm rest", s?.thermal.palmRestC, metric: nil, guess: true)
                tempRow("Ambient", s?.thermal.ambientC, metric: nil, guess: true)
            }

            RowGroup(title: "Throttle signs") {
                DetailRow(title: "Thermal pressure", value: ThermalText.pressure(s?.thermal.pressure), numeric: Double(s?.thermal.pressure ?? 0),
                          fraction: Double(s?.thermal.pressure ?? 0) / 4, color: ThermalText.color(s?.thermal.pressure),
                          detail: "0 nominal to 4 sleeping", history: .metric("thermal.pressure"), unit: { Fmt.num($0, digits: 0) })
                DetailRow(title: "macOS thermal state", value: thermalState(s?.thermal.state), numeric: Double(s?.thermal.state ?? 0),
                          fraction: Double(s?.thermal.state ?? 0) / 3, color: ThermalText.color(s?.thermal.state),
                          history: .metric("thermal.state"), unit: { Fmt.num($0, digits: 0) })
                DetailRow(title: "GPU heat cap (CLTM)", value: s?.gpu.cltm.map { $0 == "NO_CLTM" ? "not capping" : $0 } ?? Fmt.missing,
                          detail: s?.gpu.cltm)
                DetailRow(title: "kernel_task CPU", value: Fmt.pct(s?.cpu.kernelTaskPct), numeric: s?.cpu.kernelTaskPct ?? 0,
                          fraction: s?.cpu.kernelTaskPct.map { min(1, $0 / 100) }, color: Theme.warn,
                          detail: s?.cpu.kernelTaskPct == nil ? "from top: every 15 s with the window open, in short bursts when the Mac heats up" : "high = macOS slowing the Mac",
                          history: .metric("cpu.kernel_task_pct"), unit: { Fmt.pct($0) })
            }

            RowGroup(title: "All temperature sensors",
                     note: "SMC keys and HID sensors, refreshed once a minute" + (secondsAgo(s?.thermal.allSensorsAt).map { ", read \($0) s ago" } ?? "")) {
                let groups = Dictionary(grouping: s?.thermal.allSensors ?? [], by: \.group)
                if groups.isEmpty { NotAvailable(text: "Sensor list arrives with the first slow sample") }
                ForEach(s?.thermal.notReporting ?? [], id: \.group) { g in
                    NotAvailable(text: "\(g.group): no reading" + (g.group == "P cores" ? secondsAgo(s?.thermal.cpuPLastRealAt).map { " (last real reading \($0) s ago)" } ?? "" : "") + ". \(g.reason)")
                }
                ForEach(Self.groupOrder(groups.keys), id: \.self) { g in
                    let rows = groups[g]!.sorted { $0.celsius > $1.celsius }
                    SensorGroupCard(name: g, rows: rows)
                }
            }

            RowGroup(title: "Temperature limit keys", note: "raw SMC keys, meaning not proven") {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        let keys = (s?.thermal.limitKeys ?? [:]).sorted { $0.key < $1.key }
                        if keys.isEmpty { Text("Not available").foregroundStyle(theme.mut).font(.system(size: 12)) }
                        ForEach(keys, id: \.key) { KV($0.key, Fmt.num($0.value, digits: 1)) }
                    }
                }
            }
        }
    }

    static func groupOrder(_ keys: Dictionary<String, [SensorReading]>.Keys) -> [String] {
        let order = ["P cores", "E cores", "CPU max", "GPU", "PMU die", "Battery", "SSD (NAND)", "SSD area", "Palm rest",
                     "Air flow", "Wi-Fi", "Ambient", "PMU calibration", "HID other", "Unknown"]
        return keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
    }

    private func thermalState(_ v: Int?) -> String {
        guard let v else { return Fmt.missing }
        return ["nominal", "fair", "serious", "critical"].indices.contains(v) ? ["nominal", "fair", "serious", "critical"][v] : "\(v)"
    }

    /// Whole seconds from `d` to this snapshot.
    private func secondsAgo(_ d: Date?) -> Int? {
        guard let d, let ts = model.latest?.ts else { return nil }
        return max(0, Int(ts.timeIntervalSince(d).rounded()))
    }

    /// A held P core value in "Hottest now" says how old it is.
    private func hottestDetail(_ r: SensorReading) -> String {
        guard PCoreKeys.isPCore(r.key), let h = model.latest?.thermal.cpuPHeldSeconds else { return r.group }
        return "\(r.group), from \(Int(h.rounded())) s ago"
    }

    private func tempRow(_ title: String, _ c: Double?, metric: String?, guess: Bool, detail: String? = nil, open: Bool = false,
                         missing: String? = nil) -> some View {
        Group {
            if let c {
                DetailRow(title: title, value: Fmt.temp(c), numeric: c, fraction: HeatScale.fraction(c), color: Theme.heat(c),
                          detail: detail, bestGuess: guess, history: metric.map { .metric($0) } ?? .none, unit: { Fmt.temp($0) },
                          startOpen: open && renderMode)
            } else {
                NotAvailable(text: missing ?? "\(title): not available")
            }
        }
    }

    private func fanRow(_ f: FanInfo) -> some View {
        let state: String = {
            switch f.state {
            case .off: return "off"
            case .rampingUp: return "ramping up"
            case .rampingDown: return "ramping down"
            case .steady: return "steady"
            case nil: return "reading"
            }
        }()
        let frac = (f.actualRPM ?? 0) / max(1, f.maxRPM ?? 8_000)
        return VStack(spacing: 6) {
            DetailRow(title: "Fan \(f.index + 1)", value: "\(Fmt.rpm(f.actualRPM)) RPM", numeric: f.actualRPM ?? 0, fraction: frac,
                      color: Theme.fan, detail: state, history: .metric("fan\(f.index).rpm"), unit: { Fmt.rpmShort($0) },
                      startOpen: renderMode && f.index == 0)
            HStack(spacing: 18) {
                FanIcon(rpm: f.actualRPM, size: 22)
                KV("Target", Fmt.rpm(f.targetRPM))
                KV("Min", Fmt.rpm(f.minRPM))
                KV("Max", Fmt.rpm(f.maxRPM))
                KV("Duty", f.duty.map { Fmt.pct($0 * 100) } ?? Fmt.missing)
                if let t = f.targetRPM, let a = f.actualRPM, abs(t - a) > 50 {
                    Chip(text: "heading to \(Fmt.rpm(t)) RPM", color: Theme.orange)
                } else {
                    Chip(text: state, color: Theme.fan)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 4)
        }
    }
}

/// One sensor group with best guess tags.
struct SensorGroupCard: View {
    var name: String
    var rows: [SensorReading]
    @Environment(\.theme) private var theme
    @State private var showAll = false
    private static let fold = 24

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text("\(rows.count) sensor\(rows.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(theme.mut)
                    if rows.contains(where: { !$0.proven }) { BestGuess() }
                    Spacer()
                    Text(rows.first?.source ?? "").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.mut)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), alignment: .leading, spacing: 5) {
                    ForEach(showAll ? rows : Array(rows.prefix(Self.fold)), id: \.key) { r in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.heat(r.celsius)).frame(width: 4, height: 14)
                            Text(r.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.mut).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(Fmt.temp(r.celsius)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
                if rows.count > Self.fold {
                    Button { withAnimation(.snappy) { showAll.toggle() } } label: {
                        Text(showAll ? "Show fewer" : "Show all \(rows.count) (hottest \(Self.fold) shown)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.cpu)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
