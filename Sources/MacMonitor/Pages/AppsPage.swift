import SwiftUI
import MonitorCore

enum AppSort: String, CaseIterable {
    case name, cpu, memory, energy, pShare, gpu, wakeups, disk

    var title: String {
        switch self {
        case .name: return "App"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        case .pShare: return "P / E"
        case .gpu: return "GPU"
        case .wakeups: return "Wakeups/s"
        case .disk: return "Disk R / W"
        }
    }

    func key(_ p: ProcSample) -> Double {
        switch self {
        case .name: return 0
        case .cpu: return p.cpuPercent ?? -1
        case .memory: return Double(p.memBytes ?? 0)
        case .energy: return p.energyW ?? -1
        case .pShare: return p.pCorePercent ?? -1
        case .gpu: return p.gpuPercent ?? -1
        case .wakeups: return p.wakeupsPerSec ?? -1
        case .disk: return (p.diskReadBps ?? 0) + (p.diskWriteBps ?? 0)
        }
    }
}

struct AppsPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode
    @State private var sort: AppSort = .cpu
    @State private var ascending = false
    @State private var filter = ""

    private let widths: [AppSort: CGFloat] = [.cpu: 62, .memory: 82, .energy: 72, .pShare: 90, .gpu: 58, .wakeups: 78, .disk: 130]

    var body: some View {
        let rows = sorted()
        PageScroll(title: "Apps", subtitle: "Every process, every 5 seconds. Click a column to sort.") {
            HStack(spacing: 10) {
                if !renderMode {
                    TextField("Filter by name", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                Text("\(rows.count) processes").font(.system(size: 12)).foregroundStyle(theme.mut)
                Spacer()
                HStack(spacing: 5) {
                    Chip(text: "system", color: theme.mut)
                    Text("= owned by root or another user: only ps, top and GPU data, no watts")
                        .font(.system(size: 11)).foregroundStyle(theme.mut)
                }
            }

            Card(padding: 0) {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(theme.line).frame(height: 1)
                    LazyVStack(spacing: 0) {
                        ForEach(Array((renderMode ? Array(rows.prefix(24)) : rows).enumerated()), id: \.element.pid) { i, p in
                            row(p).background(i % 2 == 1 ? theme.line.opacity(0.25) : .clear)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            headerCell(.name).frame(maxWidth: .infinity, alignment: .leading)
            ForEach([AppSort.cpu, .memory, .energy, .pShare, .gpu, .wakeups, .disk], id: \.self) { s in
                headerCell(s).frame(width: widths[s], alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func headerCell(_ s: AppSort) -> some View {
        Button {
            withAnimation(.snappy) {
                if sort == s { ascending.toggle() } else { sort = s; ascending = s == .name }
            }
        } label: {
            HStack(spacing: 3) {
                Text(s.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(sort == s ? theme.fg : theme.mut)
                if sort == s { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ p: ProcSample) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(p.name).font(.system(size: 12)).lineLimit(1)
                if !p.isOwn { Chip(text: "system", color: theme.mut) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(Fmt.num(p.cpuPercent, digits: 1), .cpu)
            cell(Fmt.mem(p.memBytes.map { Double($0) }), .memory)
            cell(p.energyW.map { Fmt.watts($0) } ?? (p.energyImpact.map { "\(Fmt.num($0, digits: 1)) EI" } ?? Fmt.missing), .energy)
            Group {
                if let pc = p.pCorePercent {
                    HStack(spacing: 4) {
                        PESplit(p: pc / 100).frame(width: 46)
                        Text(Fmt.pct(pc)).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.mut)
                    }
                } else { Text(Fmt.missing).font(.system(size: 12)).foregroundStyle(theme.mut) }
            }
            .frame(width: widths[.pShare], alignment: .trailing)
            cell(p.gpuPercent.map { Fmt.num($0, digits: 1) } ?? Fmt.missing, .gpu)
            cell(p.wakeupsPerSec.map { Fmt.int($0) } ?? Fmt.missing, .wakeups)
            cell(p.diskReadBps == nil && p.diskWriteBps == nil ? Fmt.missing :
                    "\(Fmt.bytes(p.diskReadBps ?? 0)) / \(Fmt.bytes(p.diskWriteBps ?? 0))", .disk)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func cell(_ text: String, _ s: AppSort) -> some View {
        Text(text).font(.system(size: 12)).monospacedDigit().lineLimit(1)
            .foregroundStyle(text == Fmt.missing ? theme.mut : theme.fg)
            .frame(width: widths[s], alignment: .trailing)
    }

    private func sorted() -> [ProcSample] {
        var r = model.processes
        if !filter.isEmpty { r = r.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        if sort == .name {
            r.sort { ascending ? $0.name.localizedCompare($1.name) == .orderedAscending : $0.name.localizedCompare($1.name) == .orderedDescending }
        } else {
            r.sort { ascending ? sort.key($0) < sort.key($1) : sort.key($0) > sort.key($1) }
        }
        return r
    }
}
