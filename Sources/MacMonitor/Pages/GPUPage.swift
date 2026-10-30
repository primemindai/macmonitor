import SwiftUI
import MonitorCore

struct GPUPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let g = s?.gpu
        PageScroll(title: "GPU", subtitle: "20-core GPU. Busy % comes from the GPU driver; clock and power from IOReport.") {
            HStack(spacing: 12) {
                StatTile(title: "Device busy", text: Fmt.pct(g?.utilPct), value: g?.utilPct ?? 0,
                         values: model.series(120) { $0.gpu.utilPct }, range: 0...100, color: Theme.gpu, tick: model.tick)
                StatTile(title: "Clock", text: Fmt.int(g?.mhz), value: g?.mhz ?? 0, sub: "MHz",
                         values: model.series(120) { $0.gpu.mhz }, range: nil, color: Theme.cpu, tick: model.tick)
                StatTile(title: "GPU power", text: Fmt.watts(s?.power.breakdown?.gpuW), value: s?.power.breakdown?.gpuW ?? 0,
                         values: model.series(120) { $0.power.breakdown?.gpuW }, range: nil, color: Theme.power, tick: model.tick)
            }

            RowGroup(title: "Busy") {
                DetailRow(title: "Device", value: Fmt.pct(g?.utilPct), numeric: g?.utilPct ?? 0, fraction: (g?.utilPct ?? 0) / 100,
                          color: Theme.gpu, history: .metric("gpu.util_pct"), unit: { Fmt.pct($0) }, startOpen: renderMode)
                DetailRow(title: "Renderer", value: Fmt.pct(g?.rendererPct), numeric: g?.rendererPct ?? 0,
                          fraction: (g?.rendererPct ?? 0) / 100, color: Theme.gpu, history: .live { $0.gpu.rendererPct }, unit: { Fmt.pct($0) })
                DetailRow(title: "Tiler", value: Fmt.pct(g?.tilerPct), numeric: g?.tilerPct ?? 0, fraction: (g?.tilerPct ?? 0) / 100,
                          color: Theme.gpu, history: .live { $0.gpu.tilerPct }, unit: { Fmt.pct($0) })
                DetailRow(title: "Powered on (active residency)", value: Fmt.pct(g?.activePct), numeric: g?.activePct ?? 0,
                          fraction: (g?.activePct ?? 0) / 100, color: Theme.cpu, detail: "time the GPU was not powered off",
                          history: .metric("gpu.active_pct"), unit: { Fmt.pct($0) })
                DetailRow(title: "Clock while active", value: Fmt.mhz(g?.mhz), numeric: g?.mhz ?? 0, fraction: (g?.mhz ?? 0) / 1_600,
                          color: Theme.cpu, history: .metric("gpu.mhz"), unit: { Fmt.int($0) })
            }

            RowGroup(title: "Memory and power") {
                DetailRow(title: "GPU memory in use", value: Fmt.mem(g?.inUseBytes.map { Double($0) }), numeric: Double(g?.inUseBytes ?? 0),
                          fraction: g.flatMap { x in x.inUseBytes.flatMap { u in x.allocBytes.map { a in a > 0 ? Double(u) / Double(a) : 0 } } },
                          color: Theme.mem, detail: "of \(Fmt.mem(g?.allocBytes.map { Double($0) })) allocated",
                          history: .metric("gpu.mem_used_bytes"), unit: { Fmt.mem($0) })
                DetailRow(title: "GPU power", value: Fmt.watts(s?.power.breakdown?.gpuW), numeric: s?.power.breakdown?.gpuW ?? 0,
                          fraction: (s?.power.breakdown?.gpuW ?? 0) / 40, color: Theme.power,
                          detail: "IOReport \"GPU\" channel; the \"GPU Energy\" channel reads \(Fmt.watts(s?.power.breakdown?.gpuAltW))",
                          history: .metric("power.gpu_w"), unit: { Fmt.watts($0) })
                    .help("Two IOReport GPU channels disagree. MacMonitor shows the GPU (mJ) channel.")
                DetailRow(title: "GPU heat cap (CLTM)", value: g?.cltm.map { $0 == "NO_CLTM" ? "not capping" : "capping" } ?? Fmt.missing,
                          detail: g?.cltm)
                DetailRow(title: "GPU resets since boot", value: g?.resets.map(String.init) ?? Fmt.missing)
            }

            RowGroup(title: "GPU time per app", note: "includes WindowServer and other system apps") {
                Card {
                    VStack(spacing: 6) {
                        let top = Array(model.processes.filter { ($0.gpuPercent ?? 0) > 0 }.sorted { ($0.gpuPercent ?? 0) > ($1.gpuPercent ?? 0) }.prefix(10))
                        if top.isEmpty { Text("No app used the GPU in the last sample").font(.system(size: 12)).foregroundStyle(theme.mut) }
                        let mx = top.first?.gpuPercent ?? 1
                        ForEach(top, id: \.pid) { p in
                            HStack(spacing: 10) {
                                Text(p.name).font(.system(size: 12)).lineLimit(1).frame(width: 260, alignment: .leading)
                                LevelBar(fraction: (p.gpuPercent ?? 0) / max(mx, 0.01), color: Theme.gpu)
                                Text(Fmt.num(p.gpuPercent, digits: 1) + "%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}
