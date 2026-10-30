import SwiftUI
import MonitorCore

/// M4 Pro die schematic. Blocks glow blue (40 C) to red (100 C) by live temperature.
struct ChipMapPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        let s = model.latest
        let slots = CoreMap.slots(kinds: s?.cpu.coreKinds ?? [])
        PageScroll(title: "Chip map", subtitle: "Your M4 Pro, live. Colors run from blue at 40° to red at 100°.") {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    DieView(s: s, slots: slots)
                        .frame(height: 380)
                    HStack {
                        Text("Schematic, not to scale. Block temps are the hottest SMC sensor in each group (best guess labels).")
                            .font(.system(size: 10)).foregroundStyle(theme.mut)
                        Spacer()
                        HeatLegend()
                    }
                }
            }

            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Caps("Load per core")
                        Spacer()
                        Text("Hover a bar for its watts and clock").font(.system(size: 10)).foregroundStyle(theme.mut)
                    }
                    CoreBars(s: s, slots: slots)
                        .frame(height: 150)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Caps("Cluster clock (runs at)")
                        KV("P cluster 1", Fmt.mhz(s?.cpu.clocks?.pCluster0MHz), note: "PCPM")
                        KV("P cluster 2", Fmt.mhz(s?.cpu.clocks?.pCluster1MHz), note: "PCPM")
                        KV("E cluster", Fmt.mhz(s?.cpu.clocks?.eClusterMHz), note: "ECPM")
                        KV("GPU", Fmt.mhz(s?.gpu.mhz), note: "while active")
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Caps("Core clock (asked for)")
                        Text("Each core asks for a clock; the cluster runs at one shared clock. Idle cores have none.")
                            .font(.system(size: 10)).foregroundStyle(theme.mut)
                        let asked = slots.compactMap { sl in s?.cpu.clocks?.perCoreMHz[sl.mhzKey].map { (sl.label, $0) } }
                        if asked.isEmpty { Text("No active cores in the last second").font(.system(size: 12)).foregroundStyle(theme.mut) }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), alignment: .leading, spacing: 4) {
                            ForEach(asked, id: \.0) { KV($0.0, Fmt.mhz($0.1)) }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Caps("Power by block")
                        KV("P cluster 1", Fmt.watts(s?.power.breakdown?.pCluster0W))
                        KV("P cluster 2", Fmt.watts(s?.power.breakdown?.pCluster1W))
                        KV("E cluster", Fmt.watts(s?.power.breakdown?.eClusterW))
                        KV("GPU", Fmt.watts(s?.power.breakdown?.gpuW))
                        KV("Neural Engine", Fmt.watts(s?.power.breakdown?.aneW))
                        KV("DRAM", Fmt.watts(s?.power.breakdown?.dramW))
                        KV("Memory system", Fmt.watts(s?.power.breakdown?.memSystemW), note: "AMCC + DCS")
                    }
                }
            }
        }
    }
}

struct HeatLegend: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Text("40°").font(.system(size: 10)).foregroundStyle(theme.mut)
            LinearGradient(colors: stride(from: 40.0, through: 100, by: 10).map { Theme.heat($0) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 7).clipShape(Capsule())
            Text("100°").font(.system(size: 10)).foregroundStyle(theme.mut)
        }
    }
}

/// The die drawing.
private struct DieView: View {
    var s: Snapshot?
    var slots: [CoreSlot]
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let r = { (x: Double, y: Double, w: Double, h: Double) -> CGRect in CGRect(x: x * W, y: y * H, width: w * W, height: h * H) }
            let b = s?.power.breakdown
            let pSlots = slots.filter { $0.kind == .performance }
            let eSlots = slots.filter { $0.kind == .efficiency }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(theme.isDark ? Color.black.opacity(0.35) : Color(hex: 0xE9E9EE))
                RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line, lineWidth: 1)
                pinRow(W: W, H: H)

                Block(title: "P cores, cluster 1", temp: s?.thermal.cpuPC, heldS: s?.thermal.cpuPHeldSeconds, watts: b?.pCluster0W,
                      mhz: s?.cpu.clocks?.pCluster0MHz, cores: pSlots.filter { $0.cluster == 0 }, s: s, columns: 5)
                    .frame(width: r(0, 0, 0.31, 0).width, height: r(0, 0, 0, 0.29).height)
                    .offset(x: r(0.025, 0, 0, 0).minX, y: r(0, 0.05, 0, 0).minY)
                Block(title: "P cores, cluster 2", temp: s?.thermal.cpuPC, heldS: s?.thermal.cpuPHeldSeconds, watts: b?.pCluster1W,
                      mhz: s?.cpu.clocks?.pCluster1MHz, cores: pSlots.filter { $0.cluster == 1 }, s: s, columns: 5)
                    .frame(width: r(0, 0, 0.31, 0).width, height: r(0, 0, 0, 0.29).height)
                    .offset(x: r(0.025, 0, 0, 0).minX, y: r(0, 0.37, 0, 0).minY)
                Block(title: "E cores", temp: s?.thermal.cpuEC, watts: b?.eClusterW,
                      mhz: s?.cpu.clocks?.eClusterMHz, cores: eSlots, s: s, columns: 2)
                    .frame(width: r(0, 0, 0.14, 0).width, height: r(0, 0, 0, 0.61).height)
                    .offset(x: r(0.35, 0, 0, 0).minX, y: r(0, 0.05, 0, 0).minY)
                GPUBlock(temp: s?.thermal.gpuC, watts: b?.gpuW, mhz: s?.gpu.mhz, active: s?.gpu.activePct, util: s?.gpu.utilPct)
                    .frame(width: r(0, 0, 0.465, 0).width, height: r(0, 0, 0, 0.61).height)
                    .offset(x: r(0.51, 0, 0, 0).minX, y: r(0, 0.05, 0, 0).minY)
                GlowBlock(title: "Neural Engine", line: Fmt.watts(b?.aneW), sub: "glow = power", level: (b?.aneW ?? 0) / 4,
                          color: Theme.ane)
                    .frame(width: r(0, 0, 0.22, 0).width, height: r(0, 0, 0, 0.25).height)
                    .offset(x: r(0.025, 0, 0, 0).minX, y: r(0, 0.70, 0, 0).minY)
                GlowBlock(title: "Memory and fabric", line: Fmt.watts([b?.dramW, b?.memSystemW].compactMap { $0 }.reduce(0, +)),
                          sub: "DRAM \(Fmt.watts(b?.dramW))  ·  AMCC + DCS \(Fmt.watts(b?.memSystemW))",
                          level: ([b?.dramW, b?.memSystemW].compactMap { $0 }.reduce(0, +)) / 8, color: Theme.mem)
                    .frame(width: r(0, 0, 0.475, 0).width, height: r(0, 0, 0, 0.25).height)
                    .offset(x: r(0.26, 0, 0, 0).minX, y: r(0, 0.70, 0, 0).minY)
                GlowBlock(title: "Media engines", line: "no sensor", sub: "video encode and decode", level: 0, color: .gray)
                    .frame(width: r(0, 0, 0.225, 0).width, height: r(0, 0, 0, 0.25).height)
                    .offset(x: r(0.75, 0, 0, 0).minX, y: r(0, 0.70, 0, 0).minY)
            }
        }
    }

    /// Decorative pads along the edge so it reads as a chip.
    private func pinRow(W: CGFloat, H: CGFloat) -> some View {
        Canvas { ctx, size in
            let c = theme.line.opacity(0.9)
            for i in stride(from: 18.0, to: Double(size.width) - 12, by: 14) {
                ctx.fill(Path(CGRect(x: i, y: 4, width: 6, height: 3)), with: .color(c))
                ctx.fill(Path(CGRect(x: i, y: Double(size.height) - 7, width: 6, height: 3)), with: .color(c))
            }
        }
        .frame(width: W, height: H)
        .allowsHitTesting(false)
    }
}

/// A CPU cluster block: heat color, glow, and one cell per core lit by its load.
private struct Block: View {
    var title: String
    var temp: Double?
    /// Seconds since the sensor last gave a real reading, when `temp` is a held value.
    var heldS: Double? = nil
    var watts: Double?
    var mhz: Double?
    var cores: [CoreSlot]
    var s: Snapshot?
    var columns: Int

    var body: some View {
        let c = Theme.heat(temp)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .bold))
                Spacer()
                AnimatedNumber(text: Fmt.temp(temp), value: temp ?? 0, size: 15, weight: .bold, rounded: true, color: Color.black.opacity(0.82))
            }
            Text(temp == nil ? "\(Fmt.watts(watts))  ·  \(Fmt.mhz(mhz))  ·  no temp reading"
                 : heldS.map { "\(Fmt.watts(watts))  ·  \(Fmt.mhz(mhz))  ·  temp from \(Int($0.rounded())) s ago" }
                 ?? "\(Fmt.watts(watts))  ·  \(Fmt.mhz(mhz))")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().opacity(0.85).lineLimit(1)
            let rows = stride(from: 0, to: cores.count, by: columns).map { Array(cores[$0..<min($0 + columns, cores.count)]) }
            VStack(spacing: 5) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 5) {
                        ForEach(rows[r], id: \.index) { sl in coreCell(sl) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(Color.black.opacity(0.82))
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(c.gradient))
        .shadow(color: c.opacity(0.55), radius: 10)
    }

    private func coreCell(_ sl: CoreSlot) -> some View {
        let load = (s?.cpu.perCorePct.indices.contains(sl.index) == true ? s?.cpu.perCorePct[sl.index] : nil) ?? nil
        let w = s?.power.breakdown?.perCoreW[sl.wattKey]
        return ZStack(alignment: .bottom) {
            // The cell fills from the bottom with its load.
            LevelBar(fraction: max(0.04, (load ?? 0) / 100), color: Color.white.opacity(0.6), vertical: true,
                     track: Color.black.opacity(0.10), radius: 5)
            VStack(spacing: 1) {
                Text(sl.label).font(.system(size: 10, weight: .bold))
                Text(Fmt.pct(load)).font(.system(size: 9, weight: .medium)).monospacedDigit().opacity(0.8)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("\(sl.label): \(Fmt.pct(load)) busy, \(Fmt.watts(w)), asked for \(Fmt.mhz(s?.cpu.clocks?.perCoreMHz[sl.mhzKey]))")
    }
}

private struct GPUBlock: View {
    var temp: Double?
    var watts: Double?
    var mhz: Double?
    var active: Double?
    var util: Double?

    var body: some View {
        let c = Theme.heat(temp)
        let lit = Int(((util ?? 0) / 100 * 20).rounded())
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU, 20 cores").font(.system(size: 11, weight: .bold))
                Spacer()
                AnimatedNumber(text: Fmt.temp(temp), value: temp ?? 0, size: 15, weight: .bold, rounded: true, color: Color.black.opacity(0.82))
            }
            Text("\(Fmt.watts(watts))  ·  \(Fmt.mhz(mhz))  ·  busy \(Fmt.pct(util))  ·  powered \(Fmt.pct(active))")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().opacity(0.85)
            VStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 5) {
                        ForEach(0..<5, id: \.self) { c in
                            let i = r * 5 + c
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(i < lit ? 0.6 : 0.14))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.08)))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text("Cells light up with GPU busy %, not per-core data.").font(.system(size: 9)).opacity(0.7)
        }
        .foregroundStyle(Color.black.opacity(0.82))
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(c.gradient))
        .shadow(color: c.opacity(0.55), radius: 10)
    }
}

/// A block with no temperature sensor: it glows by power instead.
private struct GlowBlock: View {
    var title: String
    var line: String
    var sub: String
    var level: Double
    var color: Color
    @Environment(\.theme) private var theme

    var body: some View {
        let l = max(0, min(1, level))
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .bold))
            Text(line).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
            Text(sub).font(.system(size: 9)).opacity(0.75).lineLimit(1)
        }
        .foregroundStyle(theme.fg)
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12 + 0.5 * l)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.5), lineWidth: 1))
        .shadow(color: color.opacity(0.6 * l), radius: 12)
    }
}

/// One vertical bar per core (E cores, then P cores).
struct CoreBars: View {
    var s: Snapshot?
    var slots: [CoreSlot]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(slots, id: \.index) { sl in
                let load = (s?.cpu.perCorePct.indices.contains(sl.index) == true ? s?.cpu.perCorePct[sl.index] : nil) ?? nil
                let w = s?.power.breakdown?.perCoreW[sl.wattKey]
                let color = sl.kind == .performance ? Theme.pCore : Theme.eCore
                VStack(spacing: 4) {
                    Text(Fmt.pct(load)).font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(theme.mut)
                    LevelBar(fraction: (load ?? 0) / 100, color: color, vertical: true)
                    Text(sl.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.fg)
                    Text(w.map { String(format: "%.1fW", $0) } ?? "--").font(.system(size: 9)).monospacedDigit().foregroundStyle(theme.mut)
                }
                .help("\(sl.label): \(Fmt.pct(load)) busy, \(Fmt.watts(w)), asked for \(Fmt.mhz(s?.cpu.clocks?.perCoreMHz[sl.mhzKey]))")
                if sl.kind == .efficiency, sl.index + 1 < slots.count, slots[sl.index + 1].kind == .performance {
                    Rectangle().fill(theme.line).frame(width: 1).padding(.horizontal, 4)
                } else if sl.kind == .performance, sl.cluster == 0, sl.index + 1 < slots.count, slots[sl.index + 1].cluster == 1 {
                    Rectangle().fill(theme.line).frame(width: 1).padding(.horizontal, 2)
                }
            }
        }
    }
}
