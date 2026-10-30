import SwiftUI
import MonitorCore

/// Rounded panel used everywhere.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.tile))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
    }
}

/// Small uppercase label.
struct Caps: View {
    var text: String
    @Environment(\.theme) private var theme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(theme.mut)
    }
}

/// A colored pill, for example "best guess" or "heavy".
struct Chip: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

/// "best guess" tag for sensor labels that are not proven (spec anti-goal: made-up facts).
struct BestGuess: View {
    var body: some View { Chip(text: "best guess", color: Theme.warn) }
}

/// Overview tile: label, big number, live sparkline.
struct StatTile<Accessory: View>: View {
    var title: String
    var text: String
    var value: Double
    var sub: String?
    var values: [Double?]
    var range: ClosedRange<Double>?
    var color: Color
    var tick: Int
    @ViewBuilder var accessory: Accessory
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Caps(title)
                    Spacer(minLength: 0)
                    accessory
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AnimatedNumber(text: text, value: value, size: 28, weight: .semibold, rounded: true)
                        .foregroundStyle(theme.fg)
                    if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(theme.mut).lineLimit(1) }
                }
                Sparkline(values: values, range: range, color: color, tick: tick)
                    .frame(height: 46)
                    .padding(.top, 2)
            }
        }
    }
}

extension StatTile where Accessory == EmptyView {
    init(title: String, text: String, value: Double, sub: String? = nil, values: [Double?], range: ClosedRange<Double>?,
         color: Color, tick: Int) {
        self.init(title: title, text: text, value: value, sub: sub, values: values, range: range, color: color, tick: tick) { EmptyView() }
    }
}

/// A label and value side by side, for dense facts.
struct KV: View {
    var key: String
    var value: String
    var note: String?
    @Environment(\.theme) private var theme
    init(_ key: String, _ value: String, note: String? = nil) { self.key = key; self.value = value; self.note = note }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(theme.mut)
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(theme.mut.opacity(0.8)) }
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(theme.fg)
        }
        .font(.system(size: 12))
    }
}

/// Custom on/off switch (draws itself, so it also shows in screenshots).
struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.good : Color.gray.opacity(0.35)).frame(width: 34, height: 20)
                    Circle().fill(.white).shadow(radius: 1).frame(width: 16, height: 16).padding(2)
                }
                .animation(.spring(duration: 0.25), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Segmented picker that draws itself.
struct Segmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Environment(\.theme) private var theme
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { opt in
                Button { withAnimation(.snappy(duration: 0.25)) { selection = opt.0 } } label: {
                    Text(opt.1)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(selection == opt.0 ? theme.fg : theme.mut)
                        .background {
                            if selection == opt.0 {
                                RoundedRectangle(cornerRadius: 6).fill(theme.isDark ? Color.white.opacity(0.12) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.line.opacity(0.7)))
    }
}

/// Small push button that draws itself.
struct PillButton: View {
    var title: String
    var symbol: String?
    var tint: Color = Theme.cpu
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
