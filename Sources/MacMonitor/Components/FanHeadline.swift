import SwiftUI
import MonitorCore

/// The orange "why the fan is on" bar, with the readings behind it in an info popover.
struct FanHeadline: View {
    var explanation: FanExplanation?
    var rpm: Double?
    var compact = false
    @Environment(\.theme) private var theme
    @State private var showInfo = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FanIcon(rpm: rpm, size: compact ? 15 : 18, color: Theme.orange)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("Why the fan is on")
                    .font(.system(size: compact ? 11 : 12, weight: .bold))
                    .foregroundStyle(Theme.orange)
                Text(explanation?.headline ?? "Gathering a minute of readings to explain the fan.")
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let fb = explanation?.fallbackReason, !compact {
                    Text(fb).font(.system(size: 11)).foregroundStyle(theme.mut)
                }
            }
            Spacer(minLength: 4)
            if !compact {
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(Theme.orange)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { info.themed() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Theme.orange.opacity(theme.isDark ? 0.20 : 0.16), Theme.orange.opacity(0.03)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.orange.opacity(0.5), lineWidth: 1))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this is worked out").font(.headline)
            Text("These are MacMonitor's rules built on the readings, not Apple's fan curve. Fan state comes from target vs actual speed (50 RPM band) and the 10 second target trend. The heat source is the block that used the most power over the last minute. Apps are ranked by energy over the same minute.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let r = explanation?.readings, !r.isEmpty {
                Divider()
                Text("Readings used").font(.system(size: 12, weight: .semibold))
                ForEach(r.keys.sorted(), id: \.self) { k in KV(k, Fmt.num(r[k], digits: 2)) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
