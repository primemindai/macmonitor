import SwiftUI
import MonitorCore

struct EventsPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var kind: String = "all"

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, h:mm:ss a"
        return f
    }()

    var body: some View {
        let all = model.recentEvents
        let shown = kind == "all" ? all : all.filter { $0.kind == kind }
        PageScroll(title: "Events", subtitle: "Fan ramps, heat, throttle signs, memory, disk and wake. Kept 30 days.") {
            HStack(spacing: 6) {
                filterChip("all", "All (\(all.count))")
                ForEach(AlertSettings.kinds, id: \.kind) { k in
                    let n = all.filter { $0.kind == k.kind }.count
                    if n > 0 { filterChip(k.kind, "\(Self.shortName(k.kind)) (\(n))") }
                }
                Spacer()
            }

            if shown.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing has happened yet").font(.system(size: 14, weight: .semibold))
                        Text("Events show up here as they happen, for example when the fans ramp up after a quiet stretch or thermal pressure changes.")
                            .font(.system(size: 12)).foregroundStyle(theme.mut)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.prefix(300).enumerated()), id: \.offset) { i, e in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(Self.color(e.kind)).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(theme.bg, lineWidth: 2))
                            if i < min(shown.count, 300) - 1 { Rectangle().fill(theme.line).frame(width: 2).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(e.title).font(.system(size: 13, weight: .semibold))
                                Chip(text: Self.shortName(e.kind), color: Self.color(e.kind))
                                Spacer()
                                Text(Self.time.string(from: e.ts)).font(.system(size: 11)).foregroundStyle(theme.mut).monospacedDigit()
                            }
                            Text(e.body).font(.system(size: 12)).foregroundStyle(theme.mut).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private func filterChip(_ k: String, _ label: String) -> some View {
        Button { withAnimation(.snappy) { kind = k } } label: {
            Text(label).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(kind == k ? .white : theme.fg)
                .background(Capsule().fill(kind == k ? Theme.cpu : theme.tile))
                .overlay(Capsule().strokeBorder(theme.line))
        }
        .buttonStyle(.plain)
    }

    static func shortName(_ kind: String) -> String {
        switch kind {
        case "fan_ramp": return "fan"
        case "thermal_pressure": return "heat"
        case "throttle": return "throttle"
        case "memory_pressure": return "memory"
        case "swap_high": return "swap"
        case "disk_low": return "disk"
        case "ssd_hot": return "SSD"
        case "battery_flag": return "battery"
        case "wake": return "wake"
        default: return kind
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "fan_ramp": return Theme.orange
        case "thermal_pressure", "throttle", "ssd_hot": return Theme.bad
        case "memory_pressure", "swap_high": return Theme.gpu
        case "disk_low": return Theme.disk
        case "battery_flag": return Theme.good
        default: return Theme.cpu
        }
    }
}
