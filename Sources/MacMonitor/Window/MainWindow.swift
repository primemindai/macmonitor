import SwiftUI
import MonitorCore

/// Sidebar on the left with live numbers, the selected page on the right.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 228)
            Rectangle().fill(theme.line).frame(width: 1)
            PageHost(page: model.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.bg)
        .foregroundStyle(theme.fg)
    }
}

struct PageHost: View {
    var page: Page
    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .chipMap: ChipMapPage()
            case .heat: HeatPage()
            case .cpu: CPUPage()
            case .gpu: GPUPage()
            case .memory: MemoryPage()
            case .power: PowerPage()
            case .disks: DisksPage()
            case .network: NetworkPage()
            case .apps: AppsPage()
            case .events: EventsPage()
            case .settings: SettingsPage()
            }
        }
        .id(page)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// Page frame: title, subtitle, scrolling content. Screenshots render it unscrolled at full height.
struct PageScroll<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.fg)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.mut) }
            }
            .padding(.bottom, 2)
            content
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)

        if renderMode { inner } else { ScrollView { inner } }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                FanIcon(rpm: model.latest?.fans.compactMap(\.actualRPM).max(), size: 16, color: Theme.cpu)
                Text("MacMonitor").font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.top, 36).padding(.bottom, 12)

            item(.overview)
            item(.chipMap)
            Caps("Details").padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 3)
            ForEach([Page.heat, .cpu, .gpu, .memory, .power, .disks, .network, .apps], id: \.self) { item($0) }
            Caps("History").padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 3)
            item(.events)
            Spacer(minLength: 8)
            item(.settings)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.side)
    }

    private func item(_ p: Page) -> some View {
        let on = model.page == p
        let live = liveValue(p)
        return Button {
            withAnimation(.snappy(duration: 0.28)) { model.page = p }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: p.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(on ? Theme.cpu : theme.mut)
                Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if let live {
                    AnimatedNumber(text: live.text, value: live.value, size: 11, weight: .medium, rounded: false,
                                   color: live.color ?? theme.mut)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.sel)
                        .matchedGeometryEffect(id: "sel", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Live { var text: String; var value: Double; var color: Color? }

    private func liveValue(_ p: Page) -> Live? {
        guard let s = model.latest else { return nil }
        switch p {
        case .overview:
            return s.power.systemW.map { Live(text: Fmt.watts($0), value: $0, color: nil) }
        case .chipMap:
            return s.thermal.hottestC.map { Live(text: Fmt.temp($0), value: $0, color: Theme.heat($0)) }
        case .heat:
            let r = s.fans.compactMap(\.actualRPM).max()
            return r.map { Live(text: Fmt.rpmShort($0), value: $0, color: nil) }
        case .cpu:
            return s.cpu.totalPct.map { Live(text: Fmt.pct($0), value: $0, color: nil) }
        case .gpu:
            return s.gpu.utilPct.map { Live(text: Fmt.pct($0), value: $0, color: nil) }
        case .memory:
            guard let u = s.memory.usedBytes, let t = s.memory.totalBytes, t > 0 else { return nil }
            let f = 100 * Double(u) / Double(t)
            return Live(text: Fmt.pct(f), value: f, color: nil)
        case .power:
            if let b = s.battery?.percent { return Live(text: "\(b)%", value: Double(b), color: nil) }
            return nil
        case .disks:
            guard let root = s.disks.volumes.first(where: { $0.path == "/" }) else { return nil }
            let gb = Double(root.importantFree) / 1e9
            return Live(text: "\(Int(gb)) GB", value: gb, color: gb < 10 ? Theme.bad : nil)
        case .network:
            let rx = s.network.compactMap(\.rxBps).reduce(0, +)
            return Live(text: "↓" + Fmt.bytes(rx).replacingOccurrences(of: " ", with: ""), value: rx, color: nil)
        case .apps:
            let n = model.processes.count
            return n > 0 ? Live(text: "\(n)", value: Double(n), color: nil) : nil
        case .events:
            let day = Date().addingTimeInterval(-86_400)
            let n = model.recentEvents.filter { $0.ts > day }.count
            return Live(text: "\(n)", value: Double(n), color: nil)
        case .settings:
            return nil
        }
    }
}
