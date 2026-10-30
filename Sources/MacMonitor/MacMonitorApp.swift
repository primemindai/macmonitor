import AppKit
import SwiftUI
import Combine
import MonitorCore

/// Entry point. AppKit owns the menu bar item and the window; SwiftUI draws everything inside them.
/// `--render-screenshots <dir>` renders every page to PNG instead (no window, no history writes).
@main
enum MacMonitorMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if let i = args.firstIndex(of: "--render-screenshots") {
            let dir = args.indices.contains(i + 1) ? args[i + 1] : "docs/screenshots"
            let wait = args.firstIndex(of: "--wait").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 45
            app.setActivationPolicy(.accessory)
            let r = ScreenshotRenderer(dir: URL(fileURLWithPath: dir), wait: wait)
            withExtendedLifetime(r) {
                r.start()
                app.run()
            }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    static let showNotice = Notification.Name("com.macmonitor.app.show")

    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var window: NSWindow?
    private var notifier: Notifier?
    private var subs: Set<AnyCancellable> = []
    private var launchedByUser = true
    private var instanceLock: InstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A login launch (LaunchAgent exec, or a login item) stays in the menu bar; a double click opens the window.
        // The open event is only current here, not in applicationWillFinishLaunching.
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        launchedByUser = LaunchWindow.showAtLaunch(arguments: CommandLine.arguments, hasOpenEvent: ev != nil, isLoginItem: loginItem)
        // One copy only: the running copy holds the instance lock (render mode never takes it).
        instanceLock = InstanceLock.acquire()
        if instanceLock == nil {
            // Ask the running one to show its window, then quit.
            if launchedByUser { DistributedNotificationCenter.default().postNotificationName(Self.showNotice, object: nil, userInfo: nil, deliverImmediately: true) }
            NSApp.terminate(nil)
            return
        }

        model = AppModel(writesHistory: true)
        notifier = Notifier(model: model)
        model.notifier = notifier

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(togglePopover(_:))
            b.toolTip = "MacMonitor"
        }
        updateStatusItem()
        model.$latest.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &subs)

        DistributedNotificationCenter.default().addObserver(forName: Self.showNotice, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWindow() }
        }

        model.start()
        notifier?.askOnceIfNeeded()
        if !model.prefs.loginItemConfigured, LoginItem.isInstalledCopy {
            model.loginItem = LoginItem.enable()
            model.prefs.loginItemConfigured = true
        } else {
            model.loginItem = LoginItem.status()
        }
        if launchedByUser { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        b.image = MenuBarLabel.sparkline(model.series(30) { $0.cpu.totalPct })
        b.attributedTitle = MenuBarLabel.title(model.latest)
    }

    // MARK: popover

    @objc private func togglePopover(_ sender: Any?) {
        if let p = popover, p.isShown { p.performClose(sender); return }
        guard let b = statusItem.button else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let host = NSHostingController(rootView:
            MenuBarPopover(openWindow: { [weak self] in self?.popover?.performClose(nil); self?.showWindow() },
                           quit: { NSApp.terminate(nil) },
                           maxHeight: popoverMaxHeight(under: b))
                .environmentObject(model)
                .themed())
        // Size the popover from the SwiftUI content before it is placed. Without this NSPopover places a 320 pt
        // window, Auto Layout then grows it upward to the content height, and the top slides under the menu bar.
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        popover = p
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    /// Space between the bottom of the menu bar item and the bottom of the visible screen (above the Dock).
    private func popoverMaxHeight(under b: NSStatusBarButton) -> CGFloat {
        guard let w = b.window, let screen = w.screen ?? NSScreen.main else { return 600 }
        let anchor = w.convertToScreen(b.convert(b.bounds, to: nil))
        return CGFloat(PopoverFit.maxContentHeight(anchorMinY: anchor.minY, visibleMinY: screen.visibleFrame.minY))
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree so nothing redraws while the popover is closed.
        popover?.contentViewController = nil
        popover = nil
    }

    // MARK: window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "MacMonitor"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 1000, height: 640)
            w.delegate = self
            w.setFrameAutosaveName("MacMonitorMain")
            if !w.setFrameUsingName("MacMonitorMain") { w.center() }
            window = w
        }
        guard let w = window else { return }
        if w.contentView == nil || !(w.contentView is NSHostingView<AnyView>) {
            w.contentView = NSHostingView(rootView: AnyView(MainWindow().environmentObject(model).themed()))
        }
        apply(WindowPolicy.activation(mainWindowVisible: true))
        model.setWindowOpen(true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model.setWindowOpen(false)
        apply(WindowPolicy.activation(mainWindowVisible: false))
        // Release the SwiftUI tree; it is rebuilt when the window opens again.
        DispatchQueue.main.async { [weak self] in self?.window?.contentView = nil }
    }

    private func apply(_ a: AppActivation) {
        _ = NSApp.setActivationPolicy(a == .regular ? .regular : .accessory)
    }
}
