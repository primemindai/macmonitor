import SwiftUI
import MonitorCore

struct CPUPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let slots = CoreMap.slots(kinds: s?.cpu.coreKinds ?? [])
        PageScroll(title: "CPU", subtitle: "10 performance cores in two clusters, 4 efficiency cores.") {
            HStack(spacing: 12) {
                StatTile(title: "All cores", text: Fmt.pct(s?.cpu.totalPct), value: s?.cpu.totalPct ?? 0,
                         values: model.series(120) { $0.cpu.totalPct }, range: 0...100, color: Theme.cpu, tick: model.tick)
                StatTile(title: "P cores", text: Fmt.pct(s?.cpu.pPct), value: s?.cpu.pPct ?? 0,
                         values: model.series(120) { $0.cpu.pPct }, range: 0...100, color: Theme.pCore, tick: model.tick)
                StatTile(title: "E cores", text: Fmt.pct(s?.cpu.ePct), value: s?.cpu.ePct ?? 0,
                         values: model.series(120) { $0.cpu.ePct }, range: 0...100, color: Theme.eCore, tick: model.tick)
                StatTile(title: "CPU power", text: Fmt.watts(s?.power.breakdown?.cpuW), value: s?.power.breakdown?.cpuW ?? 0,
                         values: model.series(120) { $0.power.breakdown?.cpuW }, range: nil, color: Theme.power, tick: model.tick)
            }

            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Caps("Load per core")
                    CoreBars(s: s, slots: slots).frame(height: 140)
                }
            }

            RowGroup(title: "Busy") {
                DetailRow(title: "All cores", value: Fmt.pct(s?.cpu.totalPct), numeric: s?.cpu.totalPct ?? 0,
                          fraction: (s?.cpu.totalPct ?? 0) / 100, color: Theme.cpu, history: .metric("cpu.total_pct"),
                          unit: { Fmt.pct($0) }, startOpen: renderMode)
                DetailRow(title: "P cores", value: Fmt.pct(s?.cpu.pPct), numeric: s?.cpu.pPct ?? 0, fraction: (s?.cpu.pPct ?? 0) / 100,
                          color: Theme.pCore, history: .metric("cpu.p_pct"), unit: { Fmt.pct($0) })
                DetailRow(title: "E cores", value: Fmt.pct(s?.cpu.ePct), numeric: s?.cpu.ePct ?? 0, fraction: (s?.cpu.ePct ?? 0) / 100,
                          color: Theme.eCore, history: .metric("cpu.e_pct"), unit: { Fmt.pct($0) })
                let la = s?.cpu.loadAvg ?? []
                DetailRow(title: "Load average", value: la.isEmpty ? Fmt.missing : la.map { Fmt.num($0, digits: 2) }.joined(separator: "  "),
                          numeric: la.first ?? 0, fraction: la.first.map { min(1, $0 / 14) }, color: Theme.cpu,
                          detail: "1, 5 and 15 minutes; 14 = every core busy", history: .metric("cpu.load1"), unit: { Fmt.num($0) })
                DetailRow(title: "kernel_task", value: Fmt.pct(s?.cpu.kernelTaskPct), numeric: s?.cpu.kernelTaskPct ?? 0,
                          fraction: s?.cpu.kernelTaskPct.map { min(1, $0 / 100) }, color: Theme.warn,
                          detail: "high = throttle sign; read by top every 15 s while this window is open",
                          history: .metric("cpu.kernel_task_pct"), unit: { Fmt.pct($0) })
            }

            RowGroup(title: "Clocks", note: "\"runs at\" is the cluster clock; \"asked for\" is what each core requested") {
                DetailRow(title: "P clusters run at", value: Fmt.mhz(avg(s?.cpu.clocks?.pCluster0MHz, s?.cpu.clocks?.pCluster1MHz)),
                          numeric: avg(s?.cpu.clocks?.pCluster0MHz, s?.cpu.clocks?.pCluster1MHz) ?? 0,
                          fraction: (avg(s?.cpu.clocks?.pCluster0MHz, s?.cpu.clocks?.pCluster1MHz) ?? 0) / 4_600, color: Theme.pCore,
                          detail: "PCPM: \(Fmt.mhz(s?.cpu.clocks?.pCluster0MHz)) and \(Fmt.mhz(s?.cpu.clocks?.pCluster1MHz))",
                          history: .metric("cpu.p_mhz"), unit: { Fmt.int($0) })
                DetailRow(title: "E cluster runs at", value: Fmt.mhz(s?.cpu.clocks?.eClusterMHz), numeric: s?.cpu.clocks?.eClusterMHz ?? 0,
                          fraction: (s?.cpu.clocks?.eClusterMHz ?? 0) / 2_900, color: Theme.eCore, detail: "ECPM",
                          history: .metric("cpu.e_mhz"), unit: { Fmt.int($0) })
                Card {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(slots, id: \.index) { sl in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sl.label).font(.system(size: 11, weight: .semibold))
                                Text("asked for \(Fmt.mhz(s?.cpu.clocks?.perCoreMHz[sl.mhzKey]))").font(.system(size: 10)).monospacedDigit()
                                    .foregroundStyle(theme.mut)
                                Text("\(Fmt.watts(s?.power.breakdown?.perCoreW[sl.wattKey]))  ·  \(Fmt.pct(load(s, sl.index))) busy")
                                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.mut)
                            }
                        }
                    }
                }
            }

            RowGroup(title: "Power") {
                DetailRow(title: "CPU", value: Fmt.watts(s?.power.breakdown?.cpuW), numeric: s?.power.breakdown?.cpuW ?? 0,
                          fraction: (s?.power.breakdown?.cpuW ?? 0) / 40, color: Theme.power, history: .metric("power.cpu_w"), unit: { Fmt.watts($0) })
                DetailRow(title: "P clusters", value: Fmt.watts(sum(s?.power.breakdown?.pCluster0W, s?.power.breakdown?.pCluster1W)),
                          numeric: sum(s?.power.breakdown?.pCluster0W, s?.power.breakdown?.pCluster1W) ?? 0,
                          fraction: (sum(s?.power.breakdown?.pCluster0W, s?.power.breakdown?.pCluster1W) ?? 0) / 40, color: Theme.pCore,
                          history: .metric("power.p_cluster_w"), unit: { Fmt.watts($0) })
                DetailRow(title: "E cluster", value: Fmt.watts(s?.power.breakdown?.eClusterW), numeric: s?.power.breakdown?.eClusterW ?? 0,
                          fraction: (s?.power.breakdown?.eClusterW ?? 0) / 4, color: Theme.eCore,
                          history: .metric("power.e_cluster_w"), unit: { Fmt.watts($0) })
            }

            RowGroup(title: "P vs E time for top apps", note: "share of each app's CPU time spent on P cores") {
                Card {
                    VStack(spacing: 6) {
                        let top = Array(model.processes.filter { $0.pCorePercent != nil && ($0.cpuPercent ?? 0) > 0.5 }
                            .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(8))
                        if top.isEmpty { Text("Waiting for process samples").font(.system(size: 12)).foregroundStyle(theme.mut) }
                        ForEach(top, id: \.pid) { p in
                            HStack(spacing: 10) {
                                Text(p.name).font(.system(size: 12)).lineLimit(1).frame(width: 240, alignment: .leading)
                                Text(Fmt.pct(p.cpuPercent)).font(.system(size: 11)).monospacedDigit().frame(width: 50, alignment: .trailing)
                                PESplit(p: (p.pCorePercent ?? 0) / 100)
                                Text("P \(Fmt.pct(p.pCorePercent))").font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.mut)
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private func load(_ s: Snapshot?, _ i: Int) -> Double? {
        guard let s, s.cpu.perCorePct.indices.contains(i) else { return nil }
        return s.cpu.perCorePct[i]
    }
    private func avg(_ a: Double?, _ b: Double?) -> Double? {
        let v = [a, b].compactMap { $0 }; return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    private func sum(_ a: Double?, _ b: Double?) -> Double? {
        let v = [a, b].compactMap { $0 }; return v.isEmpty ? nil : v.reduce(0, +)
    }
}

/// Two-tone bar: P share in blue, E share in green.
struct PESplit: View {
    var p: Double
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                Rectangle().fill(Theme.pCore).frame(width: g.size.width * max(0, min(1, p)))
                Rectangle().fill(Theme.eCore)
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}
