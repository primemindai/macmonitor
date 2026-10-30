import SwiftUI
import MonitorCore

struct PowerPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        let s = model.latest
        let p = s?.power
        let b = s?.battery
        PageScroll(title: "Power & battery", subtitle: "Power from the SMC and battery telemetry. Serial numbers are never shown.") {
            HStack(spacing: 12) {
                StatTile(title: "System", text: Fmt.watts(p?.systemW), value: p?.systemW ?? 0, sub: "SMC PSTR",
                         values: model.series(120) { $0.power.systemW }, range: nil, color: Theme.power, tick: model.tick)
                StatTile(title: "From adapter", text: Fmt.watts(p?.adapterInW), value: p?.adapterInW ?? 0, sub: "SMC PDTR",
                         values: model.series(120) { $0.power.adapterInW }, range: nil, color: Theme.warn, tick: model.tick)
                StatTile(title: "Battery", text: Fmt.watts(p?.batteryW), value: p?.batteryW ?? 0, sub: "SMC PPBR",
                         values: model.series(120) { $0.power.batteryW }, range: nil, color: Theme.good, tick: model.tick)
            }

            RowGroup(title: "Power flow") {
                DetailRow(title: "System power", value: Fmt.watts(p?.systemW), numeric: p?.systemW ?? 0, fraction: (p?.systemW ?? 0) / 100,
                          color: Theme.power, detail: "SMC PSTR", history: .metric("power.system_w"), unit: { Fmt.watts($0) },
                          startOpen: renderMode)
                DetailRow(title: "Adapter power in", value: Fmt.watts(p?.adapterInW), numeric: p?.adapterInW ?? 0,
                          fraction: (p?.adapterInW ?? 0) / Double(max(1, b?.adapterWatts ?? 100)), color: Theme.warn, detail: "SMC PDTR",
                          history: .metric("power.adapter_w"), unit: { Fmt.watts($0) })
                DetailRow(title: "Battery power", value: Fmt.watts(p?.batteryW), numeric: p?.batteryW ?? 0, fraction: (p?.batteryW ?? 0) / 100,
                          color: Theme.good, detail: "SMC PPBR", history: .metric("power.battery_w"), unit: { Fmt.watts($0) })
                DetailRow(title: "Wall power in", value: Fmt.watts(p?.wallW), numeric: p?.wallW ?? 0,
                          fraction: p?.wallW.map { $0 / Double(max(1, b?.adapterWatts ?? 100)) }, color: Theme.warn,
                          detail: p?.wallW == nil ? "only while plugged in" : "PowerTelemetryData, once a minute",
                          history: .metric("power.wall_w"), unit: { Fmt.watts($0) })
                DetailRow(title: "Adapter efficiency loss", value: Fmt.watts(b?.adapterLossW), numeric: b?.adapterLossW ?? 0,
                          detail: "heat lost in the adapter and cable")
                if let d = s?.power.breakdown?.displayW {
                    DetailRow(title: "Display", value: Fmt.watts(d), numeric: d, fraction: d / 10, color: Theme.ane, detail: "IOReport DISP")
                }
            }

            RowGroup(title: "Battery") {
                if let b {
                    DetailRow(title: "Charge", value: b.percent.map { "\($0)%" } ?? Fmt.missing, numeric: Double(b.percent ?? 0),
                              fraction: Double(b.percent ?? 0) / 100, color: Theme.good,
                              detail: b.isCharging == true ? "charging" : (b.externalConnected == true ? "plugged in, not charging" : "on battery"),
                              history: .metric("battery.pct"), unit: { Fmt.pct($0) })
                    DetailRow(title: "Cycles", value: "\(b.cycleCount.map(String.init) ?? Fmt.missing) of \(b.designCycles.map { Fmt.int(Double($0)) } ?? "1,000")",
                              numeric: Double(b.cycleCount ?? 0), fraction: Double(b.cycleCount ?? 0) / Double(max(1, b.designCycles ?? 1_000)),
                              color: Theme.cpu, detail: "design cycle count")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Battery health, three views").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text("these sources disagree on this Mac").font(.system(size: 11)).foregroundStyle(theme.mut)
                            }
                            healthRow("System Settings capacity", b.appleMaxCapacityPercent.map { "\($0)%" },
                                      Double(b.appleMaxCapacityPercent ?? 0) / 100,
                                      "Apple's Maximum Capacity, as System Settings shows it (nominal vs design)")
                            healthRow("Raw capacity vs design", b.rawHealthPercent.map { String(format: "%.1f%%", $0) },
                                      (b.rawHealthPercent ?? 0) / 100,
                                      "\(b.rawMaxCapacity.map(String.init) ?? Fmt.missing) of \(b.designCapacity.map(String.init) ?? Fmt.missing) mAh")
                            HStack {
                                Text("macOS battery flag").font(.system(size: 12, weight: .medium))
                                Text("IOPS BatteryHealth").font(.system(size: 11)).foregroundStyle(theme.mut)
                                Spacer()
                                Chip(text: b.iopsHealth ?? Fmt.missing, color: b.iopsHealth == "Good" ? Theme.good : Theme.warn)
                            }
                        }
                    }
                    Card {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                            KV("Temperature", Fmt.temp(b.temperatureC))
                            KV("Lifetime max temperature", b.lifetimeMaxTempC.map { "\($0)°" } ?? Fmt.missing)
                            KV("Voltage", b.voltageMV.map { String(format: "%.2f V", Double($0) / 1000) } ?? Fmt.missing)
                            KV("Current", b.amperageMA.map { "\($0) mA" } ?? Fmt.missing)
                            KV("Cell voltages", b.cellVoltagesMV.isEmpty ? Fmt.missing : b.cellVoltagesMV.map { "\($0)" }.joined(separator: ", ") + " mV")
                            KV("Cell resistance", b.cellResistance.isEmpty ? Fmt.missing : b.cellResistance.map(String.init).joined(separator: ", "),
                               note: "raw units")
                            KV("Lifetime max charge", b.lifetimeMaxChargeMA.map { "\($0) mA" } ?? Fmt.missing)
                            KV("Lifetime max discharge", b.lifetimeMaxDischargeMA.map { "\($0) mA" } ?? Fmt.missing)
                            KV("Full charge capacity", b.nominalCapacity.map { "\($0) mAh" } ?? Fmt.missing)
                            KV("Charging current", b.chargingCurrentMA.map { "\($0) mA" } ?? Fmt.missing)
                        }
                    }
                } else {
                    NotAvailable(text: "Battery details arrive with the first slow sample (once a minute)")
                }
            }

            RowGroup(title: "Adapter") {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        KV("Adapter", b?.adapterName ?? (b?.externalConnected == false ? "not connected" : Fmt.missing))
                        KV("Rated", b?.adapterWatts.map { "\($0) W" } ?? Fmt.missing)
                        if let menu = b?.pdMenu, !menu.isEmpty {
                            Caps("USB-PD offers").padding(.top, 4)
                            HStack(spacing: 8) {
                                ForEach(menu, id: \.voltageMV) { o in
                                    Chip(text: String(format: "%.0f V  %.2f A", Double(o.voltageMV) / 1000, Double(o.maxCurrentMA) / 1000), color: Theme.warn)
                                }
                            }
                        }
                    }
                }
            }

            RowGroup(title: "Display and lid") {
                DetailRow(title: "Brightness", value: s?.display?.nits.map { "\(Fmt.int($0)) nits" } ?? Fmt.missing,
                          numeric: s?.display?.nits ?? 0, fraction: s?.display?.brightness, color: Theme.warn,
                          detail: s?.display?.brightness.map { "slider at \(Fmt.pct($0 * 100))" })
                DetailRow(title: "Refresh rate", value: s?.display?.refreshHz.map { "\(Fmt.int($0)) Hz" } ?? Fmt.missing)
                DetailRow(title: "Lid angle", value: s?.lidAngle.map { "\(Fmt.int($0))°" } ?? Fmt.missing, numeric: s?.lidAngle ?? 0,
                          fraction: s?.lidAngle.map { min(1, $0 / 135) }, color: Theme.cpu)
            }
        }
    }

    private func healthRow(_ title: String, _ value: String?, _ f: Double, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(note).font(.system(size: 11)).foregroundStyle(theme.mut).lineLimit(1)
                Spacer()
                Text(value ?? Fmt.missing).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            LevelBar(fraction: f, color: f > 0.8 ? Theme.good : Theme.warn, height: 5)
        }
    }
}
