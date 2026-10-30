import SwiftUI
import MonitorCore

/// Where a row's history comes from.
enum RowHistory {
    /// A stored metric (MetricCatalog name): 15m, 1h, 24h and 30d.
    case metric(String)
    /// Not stored: the last 10 minutes from memory.
    case live((Snapshot) -> Double?)
    case none
}

/// A calm row with a bar. Clicking it slides open its history chart.
struct DetailRow: View {
    var title: String
    var value: String
    var numeric: Double = 0
    var fraction: Double?
    var color: Color = Theme.cpu
    var detail: String?
    var bestGuess = false
    var history: RowHistory = .none
    var unit: (Double) -> String = { Fmt.num($0) }
    var startOpen = false

    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode
    @State private var open: Bool?
    @State private var range: TimeRange = .h1
    @State private var points: [ChartPoint] = []

    private var isOpen: Bool { open ?? startOpen }
    private var canOpen: Bool { if case .none = history { return false }; return true }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if canOpen {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.mut)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.fg)
                if bestGuess { BestGuess() }
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(theme.mut).lineLimit(1) }
                Spacer(minLength: 8)
                AnimatedNumber(text: value, value: numeric, size: 13, weight: .semibold, rounded: false)
                    .foregroundStyle(theme.fg)
            }
            if let fraction { LevelBar(fraction: fraction, color: color) }
            if isOpen { expanded.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.tile))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpen else { return }
            withAnimation(.spring(duration: 0.4)) { open = !isOpen }
        }
    }

    @ViewBuilder private var expanded: some View {
        switch history {
        case .metric(let name):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caps("History")
                    Spacer()
                    Segmented(options: TimeRange.allCases.map { ($0, $0.label) }, selection: $range)
                }
                HistoryChart(points: renderMode ? renderPoints(name) : points, color: color, unit: unit)
            }
            .padding(.top, 4)
            .task(id: "\(name)-\(range.rawValue)-\(isOpen)") { await reload(name) }
        case .live(let f):
            VStack(alignment: .leading, spacing: 6) {
                Caps("Last 10 minutes, live (not stored)")
                Sparkline(values: model.series(AppModel.ringSize, f), range: nil, color: color, tick: model.tick)
                    .frame(height: 70)
            }
            .padding(.top, 4)
        case .none:
            EmptyView()
        }
    }

    private func renderPoints(_ name: String) -> [ChartPoint] {
        guard let store = model.store else { return [] }
        return AppModel.loadHistory(store: store, metric: name, range: range)
    }

    private func reload(_ name: String) async {
        guard !renderMode, isOpen else { return }
        while !Task.isCancelled {
            points = await model.historySeries(metric: name, range: range)
            // Short windows refresh so the chart keeps moving; long ones are mostly static.
            let wait: Double = range == .m15 ? 5 : range == .h1 ? 15 : 60
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}

/// A titled group of rows.
struct RowGroup<Content: View>: View {
    var title: String
    var note: String?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.fg)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(theme.mut) }
            }
            .padding(.leading, 2)
            content
        }
    }
}

/// Shown where a source is missing, never a fake zero.
struct NotAvailable: View {
    var text = "Not available on this Mac right now"
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.mut)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
