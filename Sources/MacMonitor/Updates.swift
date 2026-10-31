import AppKit
import SwiftUI
import MonitorCore

/// The update check and "Update now" for the views. All network and file work runs off the main thread.
@MainActor final class UpdateModel: ObservableObject {
    enum CheckState: Equatable { case idle, checking, upToDate, failed(String) }
    enum InstallState: Equatable {
        case idle
        case running(UpdateInstaller.Step)
        case failed(String)
        /// Verified but not installed in place: the new app is at this path, and why.
        case kept(URL, InstallPlace)
        case relaunching
        /// The new version is in place; only opening it again failed.
        case installedNeedsRestart
    }

    /// The newer release, or nil. This is what shows the sidebar badge.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var check: CheckState = .idle
    @Published private(set) var install: InstallState = .idle
    @Published var enabled: Bool {
        didSet { if enabled != oldValue { settings.enabled = enabled } }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private let settings: UpdateSettings
    /// False in render mode: no network call is ever made there.
    private let live: Bool
    private var loop: Task<Void, Never>?

    init(defaults: UserDefaults, live: Bool) {
        settings = UpdateSettings(defaults: defaults)
        enabled = settings.enabled
        lastCheck = settings.lastCheck
        self.live = live
    }

    private var checker: UpdateChecker { UpdateChecker(currentVersion: currentVersion, settings: settings) }

    /// Checks at launch, then wakes each hour and checks when 24 hours have passed. Off means no call at all.
    func start() {
        guard live, loop == nil else { return }
        loop = Task { [weak self] in
            var atLaunch = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.apply(self.checker.checkIfDue(atLaunch: atLaunch), manual: false)
                atLaunch = false
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    /// The Settings "Check now" button. The user asked, so it runs even with the automatic check off.
    func checkNow() {
        guard live, check != .checking else { return }
        check = .checking
        let c = checker
        Task { await apply(c.checkNow(), manual: true) }
    }

    private func apply(_ r: UpdateChecker.Result, manual: Bool) {
        lastCheck = settings.lastCheck
        switch r {
        case .skipped:
            if manual { check = .failed("This build has no version number, so it cannot check.") }
        case .upToDate:
            available = nil
            check = .upToDate
        case .available(let release):
            available = release
            check = .idle
        case .failed(let why):
            check = .failed(why)
        }
    }

    /// "Update now": runs the whole pipeline off the main thread, then relaunches the new copy.
    func installNow() {
        guard let release = available else { return }
        if case .running = install { return }
        install = .running(.downloading)
        let app = Bundle.main.bundleURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let step: @Sendable (UpdateInstaller.Step) -> Void = { s in Task { @MainActor in self?.install = .running(s) } }
            do {
                let outcome = try await UpdateInstaller().run(release, over: app, step: step)
                await self?.finish(outcome)
            } catch {
                let msg = (error as? UpdateError)?.message ?? error.localizedDescription
                await MainActor.run { self?.install = .failed(msg) }
            }
        }
    }

    private func finish(_ outcome: UpdateInstaller.Outcome) {
        switch outcome {
        case .installed(let url):
            install = .relaunching
            relaunch(url)
        case .downloadedOnly(let url, let place):
            install = .kept(url, place)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Starts a small shell that waits for this process to quit, then opens the new copy. Then quits.
    private func relaunch(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = UpdateInstaller.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, appPath: url.path)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            install = .installedNeedsRestart
            return
        }
        NSApp.terminate(nil)
    }

    func openReleasePage() { NSWorkspace.shared.open(available?.pageURL ?? UpdateFeed.releasesPage) }

    /// Render mode only: pretend GitHub has a newer release, for screenshots.
    func fakeAvailable(version: String, notes: String) {
        let json: [String: Any] = ["tag_name": "v\(version)", "name": "MacMonitor \(version)", "body": notes,
                                   "html_url": "https://github.com/primemindai/macmonitor/releases/tag/v\(version)"]
        available = (try? JSONSerialization.data(withJSONObject: json)).flatMap(UpdateFeed.parse)
        lastCheck = Date()
    }
}

/// Sidebar badge, shown only when a newer version exists.
struct UpdatePill: View {
    @ObservedObject var updates: UpdateModel
    var open: () -> Void

    var body: some View {
        if let r = updates.available {
            Button(action: open) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                    Text("Update available · v\(r.versionText)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.cpu)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cpu.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cpu.opacity(0.35), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The page the badge opens: release notes, Update now and Download.
struct UpdatesPage: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { UpdatesContent(updates: model.updates) }
}

private struct UpdatesContent: View {
    @ObservedObject var updates: UpdateModel
    @Environment(\.theme) private var theme

    var body: some View {
        PageScroll(title: "Updates", subtitle: "New versions of MacMonitor from GitHub") {
            if let r = updates.available {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(r.title) is available").font(.system(size: 15, weight: .semibold))
                        Text("You have \(updates.currentVersion ?? "an unknown version").").font(.system(size: 12)).foregroundStyle(theme.mut)
                        HStack(spacing: 10) {
                            PillButton(title: "Update now", symbol: "arrow.down.circle") { updates.installNow() }
                                .disabled(isBusy)
                            Button("Download") { updates.openReleasePage() }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cpu)
                            Spacer()
                        }
                        installStatus
                    }
                }
                RowGroup(title: "What's new") {
                    Card {
                        Text(verbatim: r.notes.isEmpty ? "No release notes." : r.notes)
                            .font(.system(size: 12)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Card {
                    Text("You have the newest version (\(updates.currentVersion ?? "unknown")).").font(.system(size: 13))
                }
            }
            Text("Update now downloads the release from GitHub and checks it before it replaces this copy. The checks catch a cut-off or damaged download, a file swapped only on the download server, the wrong app or version, and changes made after signing. They do not prove who made the release: anyone who can publish a release on the MacMonitor GitHub repo could ship an update.")
                .font(.system(size: 11)).foregroundStyle(theme.mut).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isBusy: Bool {
        switch updates.install {
        case .running, .relaunching, .installedNeedsRestart: return true
        default: return false
        }
    }

    @ViewBuilder private var installStatus: some View {
        switch updates.install {
        case .idle:
            EmptyView()
        case .running(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step.rawValue).font(.system(size: 12)).foregroundStyle(theme.mut)
            }
        case .relaunching:
            Text("Installed. Opening the new version...").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good)
        case .installedNeedsRestart:
            Label("The new version is installed. Quit MacMonitor and open it again to use it.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good).fixedSize(horizontal: false, vertical: true)
        case .failed(let why):
            Label(why + " Use Download to get it from GitHub.", systemImage: "xmark.octagon.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
        case .kept(let url, let place):
            VStack(alignment: .leading, spacing: 4) {
                Label("Downloaded and checked, but not installed here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.orange)
                Text(place.advice + " The new copy is in \(url.deletingLastPathComponent().lastPathComponent), shown in Finder.")
                    .font(.system(size: 12)).foregroundStyle(theme.mut).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings "Updates" section: the switch, this version, the last check and Check now.
struct UpdateSettingsCard: View {
    @ObservedObject var updates: UpdateModel
    var openUpdates: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $updates.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates").font(.system(size: 13))
                        Text("Asks GitHub about once a day if there is a new version. Sends nothing about your Mac.")
                            .font(.system(size: 11)).foregroundStyle(theme.mut)
                    }
                }
                .toggleStyle(SwitchStyle())
                Divider()
                KV("Current version", updates.currentVersion ?? "unknown")
                KV("Last checked", lastChecked)
                HStack(spacing: 12) {
                    PillButton(title: updates.check == .checking ? "Checking..." : "Check now", symbol: "arrow.clockwise") { updates.checkNow() }
                        .disabled(updates.check == .checking)
                    status
                    Spacer()
                }
            }
        }
    }

    private var lastChecked: String {
        guard let d = updates.lastCheck else { return "Never" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder private var status: some View {
        if let r = updates.available {
            Button("Version \(r.versionText) is available") { openUpdates() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cpu)
        } else {
            switch updates.check {
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good)
            case .failed(let why):
                Label(why, systemImage: "xmark.octagon.fill").font(.system(size: 12)).foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .checking:
                EmptyView()
            }
        }
    }
}
