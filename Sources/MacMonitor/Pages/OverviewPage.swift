import SwiftUI
import MonitorCore

struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        let s = model.latest
        let n = 120
        let fanRPM = s?.fans.compactMap(\.actualRPM).max()
        PageScroll(title: "Overview", subtitle: "Live, updated every second. Lines show the last 2 minutes.") {
            FanHeadline(explanation: s?.fanExplanation, rpm: fanRPM)

            HStack(spacing: 12) {
                StatTile(title: "CPU", text: Fmt.pct(s?.cpu.totalPct), value: s?.cpu.totalPct ?? 0,
                         sub: s.map { "P \(Fmt.pct($0.cpu.pPct))  E \(Fmt.pct($0.cpu.ePct))" },
                         values: model.series(n) { $0.cpu.totalPct }, range: 0...100, color: Theme.cpu, tick: model.tick)
                StatTile(title: "GPU", text: Fmt.pct(s?.gpu.utilPct), value: s?.gpu.utilPct ?? 0,
                         sub: s?.gpu.mhz.map { "\(Fmt.int($0)) MHz" },
                         values: model.series(n) { $0.gpu.utilPct }, range: 0...100, color: Theme.gpu, tick: model.tick)
                StatTile(title: "Hottest", text: Fmt.temp(s?.thermal.hottestC), value: s?.thermal.hottestC ?? 0,
                         sub: s?.thermal.hottestKey.map { "\($0), best guess label" },
                         values: model.series(n) { $0.thermal.hottestC }, range: 30...115, color: Theme.temp, tick: model.tick)
                StatTile(title: "Fan", text: Fmt.rpm(fanRPM), value: fanRPM ?? 0, sub: "RPM",
                         values: model.series(n) { $0.fans.compactMap(\.actualRPM).max() }, range: 0...8_000,
                         color: Theme.fan, tick: model.tick) {
                    FanIcon(rpm: fanRPM, size: 13)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Caps("Power by part")
                        ForEach(PowerPart.all) { p in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 9, height: 9)
                                Text(p.name).font(.system(size: 11)).foregroundStyle(theme.mut)
                                Text(Fmt.watts(s.flatMap(p.extract))).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                        }
                        Spacer()
                    }
                    StackedPowerChart(history: model.history, seconds: 180)
                        .frame(height: 170)
                    HStack(spacing: 22) {
                        bigNumber("System power", s?.power.systemW, note: "SMC PSTR")
                        bigNumber("Chip parts", s?.power.breakdown?.chipTotalW, note: "sum of the chart")
                        bigNumber("Wall power in", s?.power.wallW, note: s?.power.wallW == nil ? "on battery or not read yet" : "battery telemetry, each minute")
                        Spacer()
                        pressureChip(s?.thermal.pressure)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Caps("Top apps by energy")
                        Spacer()
                        Text("own apps only; root apps have no watts").font(.system(size: 10)).foregroundStyle(theme.mut)
                    }
                    let top = Array(model.processes.filter { ($0.energyW ?? 0) > 0 }.sorted { ($0.energyW ?? 0) > ($1.energyW ?? 0) }.prefix(3))
                    let maxW = top.first?.energyW ?? 1
                    if top.isEmpty {
                        Text("Waiting for the first process sample (every 5 seconds).").font(.system(size: 12)).foregroundStyle(theme.mut)
                    }
                    ForEach(top, id: \.pid) { p in
                        HStack(spacing: 10) {
                            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 260, alignment: .leading)
                            LevelBar(fraction: (p.energyW ?? 0) / max(maxW, 0.01), color: Theme.power)
                            Text(Fmt.watts(p.energyW)).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 64, alignment: .trailing)
                            Text("CPU \(Fmt.pct(p.cpuPercent))").font(.system(size: 11)).foregroundStyle(theme.mut).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func bigNumber(_ title: String, _ w: Double?, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Caps(title)
            AnimatedNumber(text: Fmt.watts(w), value: w ?? 0, size: 20, weight: .semibold, rounded: true)
            Text(note).font(.system(size: 10)).foregroundStyle(theme.mut)
        }
    }

    private func pressureChip(_ p: Int?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Caps("Thermal pressure")
            Chip(text: ThermalText.pressure(p), color: ThermalText.color(p))
                .scaleEffect(1.15, anchor: .trailing)
        }
    }
}

enum ThermalText {
    static func pressure(_ p: Int?) -> String {
        guard let p else { return "not available" }
        return ["nominal", "moderate", "heavy", "trapping", "sleeping"].indices.contains(p)
            ? ["nominal", "moderate", "heavy", "trapping", "sleeping"][p] : "level \(p)"
    }
    static func color(_ p: Int?) -> Color {
        switch p {
        case 0: return Theme.good
        case 1: return Theme.warn
        case .some: return Theme.bad
        case nil: return .gray
        }
    }
    static func memPressure(_ l: Int?) -> String {
        switch l { case 1: return "normal"; case 2: return "warn"; case 4: return "critical"; case nil: return "not available"; default: return "level \(l!)" }
    }
    static func memColor(_ l: Int?) -> Color {
        switch l { case 1: return Theme.good; case 2: return Theme.warn; case 4: return Theme.bad; default: return .gray }
    }
}
