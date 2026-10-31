import AppKit
import SwiftUI
import MonitorCore

/// `MacMonitor --render-screenshots <dir> [--wait seconds]`: samples live for `wait` seconds, then renders every
/// page in dark and light to PNG at 2x with SwiftUI's ImageRenderer. Needs no Screen Recording permission.
/// History is opened read only; this mode never writes it.
@MainActor final class ScreenshotRenderer {
    let dir: URL
    let wait: Double
    let model = AppModel(writesHistory: false)
    private var notifier: Notifier?

    init(dir: URL, wait: Double) { self.dir = dir; self.wait = wait }

    func start() {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model.setWindowOpen(true)
            model.start()
            // Real status for the Settings screenshot (no requests are made here).
            model.loginItem = LoginItem.status()
            // `--fake-update <version>`: show the update badge and page as if GitHub had that release. No network.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--fake-update"), args.indices.contains(i + 1) {
                model.updates.fakeAvailable(version: args[i + 1], notes: "Sample release notes for the screenshot.\n\n- Update badge in the sidebar\n- One-click Update now")
            }
            let n = Notifier(model: model)
            n.refreshStatus()
            notifier = n
            FileHandle.standardError.write(Data("Sampling for \(Int(wait)) s...\n".utf8))
            try? await Task.sleep(for: .seconds(wait))
            print("login item:", model.loginItem.enabled ? "on" : "off", "via", model.loginItem.method, model.loginItem.note ?? "")
            print("notifications:", model.notificationStatus, "(raw status \(notifier?.lastRawStatus ?? -1))")
            renderAll()
            if CommandLine.arguments.contains("--layer-check") { layerCheck() }
            exit(0)
        }
    }

    private func renderAll() {
        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            for page in Page.allCases {
                model.page = page
                let view = MainWindow()
                    .environmentObject(model)
                    .themed()
                    .environment(\.renderMode, true)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 1220)
                    .frame(minHeight: 820)
                save(view, name: "\(String(format: "%02d", Page.allCases.firstIndex(of: page)! + 1))-\(page.rawValue)-\(tag)")
            }
            let pop = MenuBarPopover(openWindow: {}, quit: {})
                .environmentObject(model)
                .themed()
                .environment(\.renderMode, true)
                .environment(\.colorScheme, scheme)
            save(pop, name: "13-menubar-popover-\(tag)")
            save(MenuBarStrip(model: model, dark: scheme == .dark).environment(\.colorScheme, scheme), name: "14-menubar-item-\(tag)")
        }
    }

    /// Draws the live Core Animation pieces (sparkline, ticker, bars, fan) in an offscreen window, through
    /// CALayer.render(in:), to check they are the right way up. Dev check only; ImageRenderer cannot show them.
    private func layerCheck() {
        let v = VStack(alignment: .leading, spacing: 10) {
            AnimatedNumber(text: "3,942 RPM", value: 3942, size: 28)
            Sparkline(values: model.series(60) { $0.cpu.totalPct }, range: 0...100, color: Theme.cpu, tick: model.tick)
                .frame(width: 300, height: 50)
            LevelBar(fraction: 0.62, color: Theme.fan).frame(width: 300)
            HStack(alignment: .bottom, spacing: 8) {
                LevelBar(fraction: 0.8, color: Theme.pCore, vertical: true).frame(width: 18, height: 60)
                LevelBar(fraction: 0.3, color: Theme.eCore, vertical: true).frame(width: 18, height: 60)
                FanIcon(rpm: 4_000, size: 24)
            }
        }
        .padding(16)
        .environmentObject(model)
        .themed()
        .environment(\.colorScheme, .dark)
        .background(Theme.dark.bg)
        let host = NSHostingView(rootView: v)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let layer = host.layer, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        // The hosting view is flipped; flip the bitmap context so the check image reads the right way up.
        ctx.cgContext.translateBy(x: 0, y: host.bounds.height)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        layer.render(in: ctx.cgContext)
        if let png = rep.representation(using: .png, properties: [:]) {
            let url = dir.appendingPathComponent("zz-layer-check.png")
            try? png.write(to: url)
            print(url.path)
        }
        w.orderOut(nil)
    }

    private func save<V: View>(_ view: V, name: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else {
            FileHandle.standardError.write(Data("render failed: \(name)\n".utf8)); return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        print(url.path, "\(cg.width)x\(cg.height)")
    }
}

/// The menu bar item as it looks in the bar, for the screenshot set.
private struct MenuBarStrip: View {
    let model: AppModel
    let dark: Bool
    var body: some View {
        let img = MenuBarLabel.sparkline(model.series(30) { $0.cpu.totalPct })
        HStack(spacing: 4) {
            Image(nsImage: img).renderingMode(.template)
            Text(MenuBarText.make(model.latest)).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xE8E8EC))
    }
}
