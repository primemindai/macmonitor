import SwiftUI
import MonitorCore

struct NetworkPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let rx = s.map { $0.network.compactMap(\.rxBps).reduce(0, +) }
        let tx = s.map { $0.network.compactMap(\.txBps).reduce(0, +) }
        PageScroll(title: "Network", subtitle: "Every real interface, from 64-bit counters. MacMonitor itself sends nothing over the network.") {
            HStack(spacing: 12) {
                StatTile(title: "Download", text: Fmt.rate(rx), value: rx ?? 0,
                         values: model.series(120) { $0.network.compactMap(\.rxBps).reduce(0, +) }, range: nil, color: Theme.net, tick: model.tick)
                StatTile(title: "Upload", text: Fmt.rate(tx), value: tx ?? 0,
                         values: model.series(120) { $0.network.compactMap(\.txBps).reduce(0, +) }, range: nil, color: Theme.disk, tick: model.tick)
            }

            RowGroup(title: "All interfaces") {
                DetailRow(title: "Download", value: Fmt.rate(rx), numeric: rx ?? 0, fraction: rx.map { min(1, log10(1 + $0) / 9) },
                          color: Theme.net, history: .metric("net.rx_bps"), unit: { Fmt.rate($0) }, startOpen: renderMode)
                DetailRow(title: "Upload", value: Fmt.rate(tx), numeric: tx ?? 0, fraction: tx.map { min(1, log10(1 + $0) / 9) },
                          color: Theme.disk, history: .metric("net.tx_bps"), unit: { Fmt.rate($0) })
            }

            RowGroup(title: "Per interface") {
                if let nets = s?.network, !nets.isEmpty {
                    ForEach(nets, id: \.name) { n in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(n.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    Text(Self.kind(n.name)).font(.system(size: 11)).foregroundStyle(theme.mut)
                                    Spacer()
                                    Text("↓ \(Fmt.rate(n.rxBps))   ↑ \(Fmt.rate(n.txBps))").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                }
                                HStack(spacing: 20) {
                                    KV("Link speed", n.baud.map { Self.link(Double($0)) } ?? "not reported")
                                    KV("Received", Fmt.bytes(n.rxTotal.map { Double($0) }))
                                    KV("Sent", Fmt.bytes(n.txTotal.map { Double($0) }))
                                }
                            }
                        }
                    }
                } else { NotAvailable(text: "No active interfaces") }
            }

            RowGroup(title: "Wi-Fi", note: "network name not shown; it needs Location access, which MacMonitor does not ask for") {
                if let w = s?.wifi {
                    DetailRow(title: "Signal (RSSI)", value: w.rssi.map { "\($0) dBm" } ?? Fmt.missing, numeric: Double(w.rssi ?? 0),
                              fraction: w.rssi.map { max(0, min(1, (Double($0) + 90) / 60)) }, color: Theme.good,
                              detail: w.noise.map { "noise \($0) dBm" })
                    DetailRow(title: "Transmit rate", value: w.txRateMbps.map { "\(Fmt.int($0)) Mbps" } ?? Fmt.missing)
                    DetailRow(title: "Channel", value: w.channel.map(String.init) ?? Fmt.missing)
                } else {
                    NotAvailable(text: "Wi-Fi is off or not available")
                }
                let wifiTemps = (s?.thermal.allSensors ?? []).filter { $0.group == "Wi-Fi" }
                if !wifiTemps.isEmpty {
                    SensorGroupCard(name: "Wi-Fi area temperature", rows: wifiTemps)
                }
            }
        }
    }

    static func kind(_ n: String) -> String {
        if n.hasPrefix("en0") { return "built-in (usually Wi-Fi)" }
        if n.hasPrefix("en") { return "Ethernet, Thunderbolt or USB" }
        if n.hasPrefix("bridge") { return "bridge" }
        return ""
    }

    static func link(_ bps: Double) -> String {
        if bps >= 1e9 { return String(format: "%.0f Gbit/s", bps / 1e9) }
        return String(format: "%.0f Mbit/s", bps / 1e6)
    }
}
