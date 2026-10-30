import SwiftUI
import MonitorCore

struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var confirmClear = false

    var body: some View {
        PageScroll(title: "Settings") {
            RowGroup(title: "Alerts", note: "Mac notifications. Every alert is also written to Events.") {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Notifications").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(model.notificationStatus).font(.system(size: 12)).foregroundStyle(theme.mut)
                        }
                        Divider()
                        ForEach(AlertSettings.kinds.filter { $0.kind != "wake" }, id: \.kind) { k in
                            Toggle(isOn: Binding(get: { model.prefs.alerts.isEnabled(k.kind) },
                                                 set: { model.setAlert(k.kind, on: $0) })) {
                                Text(k.label).font(.system(size: 13))
                            }
                            .toggleStyle(SwitchStyle())
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Caps("Thresholds")
                        stepper("Fans count as loud at", value: \.fanLoudRPM, step: 250, range: 1_000...8_000, unit: "RPM")
                        stepper("after being quiet under", value: \.fanQuietRPM, step: 250, range: 1_000...8_000, unit: "RPM")
                        stepper("for at least", value: \.quietMinutes, step: 1, range: 0...60, unit: "min")
                        stepper("SSD hot above", value: \.ssdHotC, step: 1, range: 40...90, unit: "°C")
                        stepper("Startup disk low under", value: \.diskLowGB, step: 1, range: 1...100, unit: "GB")
                        stepper("Swap almost full at", value: \.swapPct, step: 5, range: 50...100, unit: "%")
                        stepper("kernel_task busy above", value: \.kernelTaskPct, step: 5, range: 10...200, unit: "%")
                        Text("kernel_task is checked every 15 s while the window is open, and in short bursts when the Mac heats up.")
                            .font(.system(size: 11)).foregroundStyle(theme.mut)
                        stepper("Quiet time between alerts of one kind", value: \.cooldownMinutes, step: 5, range: 0...240, unit: "min")
                        HStack {
                            Spacer()
                            Button("Restore defaults") {
                                var a = AlertSettings()
                                a.enabled = model.prefs.alerts.enabled
                                model.prefs.alerts = a
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.cpu)
                        }
                    }
                }
            }

            RowGroup(title: "App") {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(get: { model.loginItem.enabled }, set: { on in
                            model.loginItem = on ? LoginItem.enable() : LoginItem.disable()
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start at login").font(.system(size: 13))
                                Text(loginNote).font(.system(size: 11)).foregroundStyle(theme.mut)
                            }
                        }
                        .toggleStyle(SwitchStyle())
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sample rate").font(.system(size: 13))
                                Text("Eco samples every 2 seconds while only the menu bar is showing.").font(.system(size: 11)).foregroundStyle(theme.mut)
                            }
                            Spacer()
                            Segmented(options: [(false, "Normal"), (true, "Eco")], selection: Binding(get: { model.prefs.eco }, set: { model.prefs.eco = $0 }))
                        }
                    }
                }
            }

            RowGroup(title: "History") {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("History on disk").font(.system(size: 13))
                                Text("24 hours at full detail, then per-minute summaries for 30 days. Capped well under 150 MB.")
                                    .font(.system(size: 11)).foregroundStyle(theme.mut)
                            }
                            Spacer()
                            AnimatedNumber(text: String(format: "%.1f MB", Double(model.historyBytes) / 1e6), value: Double(model.historyBytes),
                                           size: 16, weight: .semibold)
                        }
                        LevelBar(fraction: Double(model.historyBytes) / 150e6, color: Theme.cpu)
                        HStack {
                            Text(HistoryStore.defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.mut)
                            Spacer()
                            PillButton(title: confirmClear ? "Click again to delete all history" : "Clear history", symbol: "trash",
                                       tint: confirmClear ? Theme.bad : Color.gray) {
                                if confirmClear { model.clearHistory(); confirmClear = false } else { confirmClear = true }
                            }
                        }
                        if let e = model.storeError {
                            Text("History is not being saved: \(e)").font(.system(size: 11)).foregroundStyle(Theme.bad)
                        }
                    }
                }
            }

            RowGroup(title: "About") {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacMonitor reads hardware sensors read only. It never writes to the SMC, never needs a password, and never sends data anywhere. Claude can read the same data through the macmonitor-mcp tool inside the app.")
                            .font(.system(size: 12)).foregroundStyle(theme.mut).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var loginNote: String {
        let s = model.loginItem
        if let n = s.note { return n }
        return s.enabled ? "On, using \(s.method)" : "Off"
    }

    private func stepper(_ title: String, value: WritableKeyPath<AlertSettings, Double>, step: Double,
                         range: ClosedRange<Double>, unit: String) -> some View {
        let v = model.prefs.alerts[keyPath: value]
        return HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            HStack(spacing: 0) {
                stepButton("minus") { model.prefs.alerts[keyPath: value] = max(range.lowerBound, v - step) }
                Text("\(Fmt.int(v)) \(unit)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 90)
                stepButton("plus") { model.prefs.alerts[keyPath: value] = min(range.upperBound, v + step) }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.line.opacity(0.6)))
        }
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
