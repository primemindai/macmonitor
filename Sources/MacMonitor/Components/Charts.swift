import SwiftUI
import Charts
import MonitorCore

/// One block of chip power for the stacked chart.
struct PowerPart: Identifiable, Sendable {
    var name: String
    var color: Color
    var extract: @Sendable (Snapshot) -> Double?
    var id: String { name }

    static let all: [PowerPart] = [
        PowerPart(name: "P cores", color: Theme.pCore) { s in
            let b = s.power.breakdown
            let v = [b?.pCluster0W, b?.pCluster1W].compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +)
        },
        PowerPart(name: "E cores", color: Theme.eCore) { $0.power.breakdown?.eClusterW },
        PowerPart(name: "GPU", color: Theme.gpu) { $0.power.breakdown?.gpuW },
        PowerPart(name: "Neural Engine", color: Theme.ane) { $0.power.breakdown?.aneW },
        PowerPart(name: "Memory", color: Theme.mem) { s in
            let b = s.power.breakdown
            let v = [b?.dramW, b?.memSystemW].compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +)
        },
    ]
}

private struct StackPoint: Identifiable {
    var t: Int
    var part: String
    var w: Double
    var id: String { "\(t)-\(part)" }
}

/// Stacked watts by part over the last few minutes (Swift Charts AreaMark).
struct StackedPowerChart: View {
    var history: [Snapshot]
    var seconds: Int = 180
    @Environment(\.theme) private var theme

    var body: some View {
        let snaps = Array(history.suffix(seconds))
        let offset = seconds - snaps.count
        var pts: [StackPoint] = []
        pts.reserveCapacity(snaps.count * PowerPart.all.count)
        for (i, s) in snaps.enumerated() {
            for p in PowerPart.all { pts.append(StackPoint(t: i + offset - seconds, part: p.name, w: p.extract(s) ?? 0)) }
        }
        return Chart(pts) { p in
            AreaMark(x: .value("Seconds ago", p.t), y: .value("Watts", p.w), stacking: .standard)
                .foregroundStyle(by: .value("Part", p.part))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: PowerPart.all.map(\.name), range: PowerPart.all.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: -seconds...0)
        .chartXAxis {
            AxisMarks(values: [-seconds, -seconds * 2 / 3, -seconds / 3, 0]) { v in
                AxisGridLine().foregroundStyle(theme.line)
                AxisValueLabel {
                    if let x = v.as(Int.self) { Text(x == 0 ? "now" : "\(-x / 60 > 0 ? "\(-x / 60)m" : "\(-x)s")") }
                }
                .foregroundStyle(theme.mut)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(theme.line)
                AxisValueLabel { if let w = v.as(Double.self) { Text("\(Int(w)) W") } }.foregroundStyle(theme.mut)
            }
        }
    }
}

/// History chart for a detail row: line, plus a min to max band for 30 days.
struct HistoryChart: View {
    var points: [ChartPoint]
    var color: Color
    var unit: (Double) -> String
    @Environment(\.theme) private var theme

    var body: some View {
        if points.compactMap(\.value).isEmpty {
            Text("No history for this range yet. MacMonitor keeps 24 hours at full detail and 30 days of per-minute summaries.")
                .font(.system(size: 11)).foregroundStyle(theme.mut)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(points) { p in
                if let lo = p.min, let hi = p.max {
                    AreaMark(x: .value("Time", p.ts), yStart: .value("Min", lo), yEnd: .value("Max", hi))
                        .foregroundStyle(color.opacity(0.18))
                }
                if let v = p.value {
                    AreaMark(x: .value("Time", p.ts), y: .value("Value", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.ts), y: .value("Value", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(theme.line)
                    AxisValueLabel().foregroundStyle(theme.mut)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(theme.line)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(unit(d)) } }.foregroundStyle(theme.mut)
                }
            }
            .frame(height: 120)
        }
    }
}
