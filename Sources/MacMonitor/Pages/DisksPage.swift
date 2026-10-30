import SwiftUI
import MonitorCore

struct DisksPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let d = s?.disks
        PageScroll(title: "Disks", subtitle: "Internal SSD. Speeds update every second; SMART health once a minute.") {
            HStack(spacing: 12) {
                StatTile(title: "Read", text: Fmt.rate(d?.readBps), value: d?.readBps ?? 0,
                         values: model.series(120) { $0.disks.readBps }, range: nil, color: Theme.net, tick: model.tick)
                StatTile(title: "Write", text: Fmt.rate(d?.writeBps), value: d?.writeBps ?? 0,
                         values: model.series(120) { $0.disks.writeBps }, range: nil, color: Theme.disk, tick: model.tick)
            }

            if let so = s?.memoryRates.swapoutsPerSec, so > 50 {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.warn)
                    Text("Swap is writing to your SSD right now (\(Fmt.int(so)) pages a second). SSD writes often rise with swap-outs. This is a correlation we can see, not a proven cause.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warn.opacity(0.4)))
            }

            RowGroup(title: "Volumes") {
                if let vols = d?.volumes, !vols.isEmpty {
                    ForEach(vols, id: \.path) { v in
                        let used = Double(v.total - v.free)
                        Card {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: "internaldrive").foregroundStyle(Theme.disk)
                                    Text(v.name).font(.system(size: 13, weight: .semibold))
                                    Text(v.path).font(.system(size: 11)).foregroundStyle(theme.mut)
                                    Spacer()
                                    Text("\(Fmt.bytes(used)) used of \(Fmt.bytes(Double(v.total)))").font(.system(size: 12)).monospacedDigit()
                                }
                                LevelBar(fraction: v.total > 0 ? used / Double(v.total) : 0,
                                         color: Double(v.importantFree) < 10e9 ? Theme.bad : Theme.disk, height: 8)
                                HStack(spacing: 20) {
                                    KV("Free", Fmt.bytes(Double(v.free)))
                                    KV("Available for important use", Fmt.bytes(Double(v.importantFree)))
                                    KV("Purgeable", Fmt.bytes(Double(v.purgeable)), note: "estimate")
                                }
                            }
                        }
                    }
                } else { NotAvailable() }
            }

            RowGroup(title: "Activity") {
                DetailRow(title: "Read speed", value: Fmt.rate(d?.readBps), numeric: d?.readBps ?? 0,
                          fraction: d?.readBps.map { min(1, log10(1 + $0) / 9.5) }, color: Theme.net,
                          history: .metric("disk.read_bps"), unit: { Fmt.rate($0) }, startOpen: renderMode)
                DetailRow(title: "Write speed", value: Fmt.rate(d?.writeBps), numeric: d?.writeBps ?? 0,
                          fraction: d?.writeBps.map { min(1, log10(1 + $0) / 9.5) }, color: Theme.disk,
                          history: .metric("disk.write_bps"), unit: { Fmt.rate($0) })
                DetailRow(title: "Operations", value: "\(Fmt.int(d?.readOpsPerSec)) read  ·  \(Fmt.int(d?.writeOpsPerSec)) write",
                          numeric: (d?.readOpsPerSec ?? 0) + (d?.writeOpsPerSec ?? 0), detail: "per second (IOPS)",
                          history: .live { ($0.disks.readOpsPerSec ?? 0) + ($0.disks.writeOpsPerSec ?? 0) }, unit: { Fmt.int($0) })
                DetailRow(title: "Average latency",
                          value: d?.readLatencyMs == nil && d?.writeLatencyMs == nil ? "not reported" :
                            "\(Self.latency(d?.readLatencyMs)) read  ·  \(Self.latency(d?.writeLatencyMs)) write",
                          detail: "only when the SSD reports busy time")
                DetailRow(title: "Since boot", value: "\(Fmt.bytes(d?.bytesReadSinceBoot.map { Double($0) })) read  ·  \(Fmt.bytes(d?.bytesWrittenSinceBoot.map { Double($0) })) written")
            }

            RowGroup(title: "SSD health (NVMe SMART)") {
                if let sm = d?.smart {
                    DetailRow(title: "Temperature", value: Fmt.temp(sm.tempC.map { Double($0) }), numeric: Double(sm.tempC ?? 0),
                              fraction: sm.tempC.map { HeatScale.fraction(Double($0)) }, color: Theme.heat(sm.tempC.map { Double($0) }),
                              history: .metric("temp.ssd_c"), unit: { Fmt.temp($0) })
                    DetailRow(title: "Wear (percent used)", value: sm.percentUsed.map { "\($0)%" } ?? Fmt.missing,
                              numeric: Double(sm.percentUsed ?? 0), fraction: Double(sm.percentUsed ?? 0) / 100, color: Theme.warn,
                              detail: "100% = rated life used")
                    DetailRow(title: "Spare", value: sm.spare.map { "\($0)%" } ?? Fmt.missing, numeric: Double(sm.spare ?? 0),
                              fraction: Double(sm.spare ?? 0) / 100, color: Theme.good,
                              detail: sm.spareThreshold.map { "warning below \($0)%" })
                    Card {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                            KV("Written", sm.tbWritten.map { String(format: "%.1f TB", $0) } ?? Fmt.missing)
                            KV("Read", sm.tbRead.map { String(format: "%.1f TB", $0) } ?? Fmt.missing)
                            KV("Power-on hours", sm.powerOnHours.map { Fmt.int(Double($0)) } ?? Fmt.missing)
                            KV("Power cycles", sm.powerCycles.map { Fmt.int(Double($0)) } ?? Fmt.missing)
                            KV("Unsafe shutdowns", sm.unsafeShutdowns.map { Fmt.int(Double($0)) } ?? Fmt.missing)
                            KV("Media errors", sm.mediaErrors.map(String.init) ?? Fmt.missing)
                            KV("Critical warning", sm.criticalWarning.map { $0 == 0 ? "none" : "flag \($0)" } ?? Fmt.missing)
                        }
                    }
                } else {
                    NotAvailable(text: "SMART data arrives with the first slow sample, or the NVMe plug-in is not available")
                }
            }
        }
    }

    static func latency(_ ms: Double?) -> String { ms.map { String(format: "%.2f ms", $0) } ?? "not reported" }
}
