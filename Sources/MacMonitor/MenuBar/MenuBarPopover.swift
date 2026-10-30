import SwiftUI
import MonitorCore

/// The popover under the menu bar item: key numbers, the fan headline, open and quit.
struct MenuBarPopover: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    var openWindow: () -> Void
    var quit: () -> Void

    var body: some View {
        let s = model.latest
        let fan = s?.fans.compactMap(\.actualRPM).max()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FanIcon(rpm: fan, size: 16, color: Theme.cpu)
                Text("MacMonitor").font(.system(size: 14, weight: .bold))
                Spacer()
                Chip(text: "thermal \(ThermalText.pressure(s?.thermal.pressure))", color: ThermalText.color(s?.thermal.pressure))
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    mini("CPU", Fmt.pct(s?.cpu.totalPct), s?.cpu.totalPct ?? 0, model.series(60) { $0.cpu.totalPct }, 0...100, Theme.cpu)
                    mini("GPU", Fmt.pct(s?.gpu.utilPct), s?.gpu.utilPct ?? 0, model.series(60) { $0.gpu.utilPct }, 0...100, Theme.gpu)
                }
                GridRow {
                    mini("Hottest", Fmt.temp(s?.thermal.hottestC), s?.thermal.hottestC ?? 0, model.series(60) { $0.thermal.hottestC }, 30...115, Theme.temp)
                    mini("Fan RPM", Fmt.rpm(fan), fan ?? 0, model.series(60) { $0.fans.compactMap(\.actualRPM).max() }, 0...8_000, Theme.fan)
                }
                GridRow {
                    mini("System power", Fmt.watts(s?.power.systemW), s?.power.systemW ?? 0, model.series(60) { $0.power.systemW }, nil, Theme.power)
                    mini("Memory used", memText(s), Double(s?.memory.usedBytes ?? 0), model.series(60) { $0.memory.usedBytes.map { Double($0) } }, nil, Theme.mem)
                }
            }
            FanHeadline(explanation: s?.fanExplanation, rpm: fan, compact: true)
            HStack {
                PillButton(title: "Open MacMonitor", symbol: "macwindow", action: openWindow)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.mut)
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.bg)
        .foregroundStyle(theme.fg)
    }

    private func memText(_ s: Snapshot?) -> String {
        guard let u = s?.memory.usedBytes, let t = s?.memory.totalBytes else { return Fmt.missing }
        return "\(Fmt.mem(Double(u)).replacingOccurrences(of: " GB", with: "")) / \(Fmt.mem(Double(t)))"
    }

    private func mini(_ title: String, _ text: String, _ v: Double, _ vals: [Double?], _ range: ClosedRange<Double>?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Caps(title)
            AnimatedNumber(text: text, value: v, size: 17, weight: .semibold, rounded: true)
            Sparkline(values: vals, range: range, color: color, tick: model.tick, lineWidth: 1.3)
                .frame(height: 24)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.tile))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line))
    }
}
