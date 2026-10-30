import SwiftUI
import MonitorCore

struct MemoryPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let m = s?.memory
        let total = Double(m?.totalBytes ?? 0)
        let frac = { (b: UInt64?) -> Double? in
            guard let b, total > 0 else { return nil }
            return Double(b) / total
        }
        PageScroll(title: "Memory", subtitle: "\(Fmt.mem(total > 0 ? total : nil)) of unified memory, shared by CPU and GPU.") {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Caps("Where the memory is")
                        Spacer()
                        Chip(text: "pressure \(ThermalText.memPressure(m?.pressureLevel))", color: ThermalText.memColor(m?.pressureLevel))
                    }
                    MemoryStack(parts: [
                        ("App", m?.appBytes, Theme.cpu), ("Wired", m?.wiredBytes, Theme.ane),
                        ("Compressed", m?.compressedBytes, Theme.gpu), ("Cached", m?.cachedBytes, Theme.eCore.opacity(0.6)),
                    ], total: total)
                    .frame(height: 22)
                    if let c = m?.compressedBytes, let h = m?.compressedHoldsBytes {
                        Text("\(Fmt.mem(Double(h))) squeezed into \(Fmt.mem(Double(c))) by the memory compressor")
                            .font(.system(size: 12)).foregroundStyle(theme.mut)
                    }
                }
            }

            RowGroup(title: "Use") {
                DetailRow(title: "Used", value: Fmt.mem(m?.usedBytes.map { Double($0) }), numeric: Double(m?.usedBytes ?? 0),
                          fraction: frac(m?.usedBytes), color: Theme.mem, detail: "app + wired + compressed",
                          history: .metric("mem.used_bytes"), unit: { Fmt.mem($0) }, startOpen: renderMode)
                DetailRow(title: "App", value: Fmt.mem(m?.appBytes.map { Double($0) }), numeric: Double(m?.appBytes ?? 0),
                          fraction: frac(m?.appBytes), color: Theme.cpu, history: .live { $0.memory.appBytes.map { Double($0) } }, unit: { Fmt.mem($0) })
                DetailRow(title: "Wired", value: Fmt.mem(m?.wiredBytes.map { Double($0) }), numeric: Double(m?.wiredBytes ?? 0),
                          fraction: frac(m?.wiredBytes), color: Theme.ane, detail: "kept in RAM for the system",
                          history: .live { $0.memory.wiredBytes.map { Double($0) } }, unit: { Fmt.mem($0) })
                DetailRow(title: "Compressed", value: Fmt.mem(m?.compressedBytes.map { Double($0) }), numeric: Double(m?.compressedBytes ?? 0),
                          fraction: frac(m?.compressedBytes), color: Theme.gpu,
                          detail: m?.compressedHoldsBytes.map { "holds \(Fmt.mem(Double($0)))" },
                          history: .metric("mem.compressed_bytes"), unit: { Fmt.mem($0) })
                DetailRow(title: "Cached files", value: Fmt.mem(m?.cachedBytes.map { Double($0) }), numeric: Double(m?.cachedBytes ?? 0),
                          fraction: frac(m?.cachedBytes), color: Theme.eCore, detail: "freed when apps need it",
                          history: .live { $0.memory.cachedBytes.map { Double($0) } }, unit: { Fmt.mem($0) })
                DetailRow(title: "Free", value: Fmt.mem(m?.freeBytes.map { Double($0) }), numeric: Double(m?.freeBytes ?? 0),
                          fraction: frac(m?.freeBytes), color: Theme.good, history: .live { $0.memory.freeBytes.map { Double($0) } },
                          unit: { Fmt.mem($0) })
            }

            RowGroup(title: "Pressure and swap") {
                DetailRow(title: "Memory pressure", value: ThermalText.memPressure(m?.pressureLevel), numeric: Double(m?.pressureLevel ?? 0),
                          fraction: m?.pressureLevel.map { Double($0) / 4 }, color: ThermalText.memColor(m?.pressureLevel),
                          detail: m?.memorystatusPercent.map { "memorystatus says \($0)% free" },
                          history: .metric("mem.pressure"), unit: { Fmt.num($0, digits: 0) })
                let swapFrac: Double? = {
                    guard let u = m?.swapUsed, let t = m?.swapTotal, t > 0 else { return nil }
                    return Double(u) / Double(t)
                }()
                DetailRow(title: "Swap used", value: Fmt.mem(m?.swapUsed.map { Double($0) }), numeric: Double(m?.swapUsed ?? 0),
                          fraction: swapFrac, color: (swapFrac ?? 0) > 0.9 ? Theme.bad : Theme.warn,
                          detail: "of \(Fmt.mem(m?.swapTotal.map { Double($0) }))", history: .metric("mem.swap_used_bytes"), unit: { Fmt.mem($0) })
                rateRow("Page-ins", s?.memoryRates.pageinsPerSec, history: .live { $0.memoryRates.pageinsPerSec })
                rateRow("Swap-ins", s?.memoryRates.swapinsPerSec, history: .live { $0.memoryRates.swapinsPerSec })
                rateRow("Swap-outs", s?.memoryRates.swapoutsPerSec, history: .metric("mem.swapouts_per_s"))
            }
        }
    }

    private func rateRow(_ title: String, _ v: Double?, history: RowHistory) -> some View {
        DetailRow(title: title, value: v.map { "\(Fmt.int($0)) pages/s" } ?? Fmt.missing, numeric: v ?? 0,
                  fraction: v.map { min(1, log10(1 + $0) / 5) }, color: Theme.disk, history: history, unit: { Fmt.int($0) })
    }
}

/// One horizontal bar split by memory kind, with a legend.
struct MemoryStack: View {
    var parts: [(String, UInt64?, Color)]
    var total: Double
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        let f = total > 0 ? Double(p.1 ?? 0) / total : 0
                        RoundedRectangle(cornerRadius: 3).fill(p.2).frame(width: max(0, g.size.width * f - 2))
                    }
                    Spacer(minLength: 0)
                }
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.line))
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 9, height: 9)
                        Text("\(p.0) \(Fmt.mem(p.1.map { Double($0) }))").font(.system(size: 11)).foregroundStyle(theme.mut).monospacedDigit()
                    }
                }
            }
        }
    }
}
