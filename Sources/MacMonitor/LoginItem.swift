import Foundation
import ServiceManagement
import MonitorCore

/// Start at login. Tries SMAppService first; an ad-hoc signed app can fail there, so it falls back to a
/// user LaunchAgent in ~/Library/LaunchAgents. No admin rights either way.
enum LoginItem {
    struct Status: Equatable {
        var enabled: Bool
        /// "SMAppService", "LaunchAgent" or "none".
        var method: String
        var note: String?
    }

    static var agentURL: URL { LaunchAgentPlist.url(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// Only the installed copy registers itself, so a test build never becomes the login item.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasSuffix(".app") && (path.hasPrefix(home + "/Applications/") || path.hasPrefix("/Applications/"))
    }

    static func status() -> Status {
        let sm = SMAppService.mainApp.status
        if sm == .enabled { return Status(enabled: true, method: "SMAppService", note: nil) }
        if sm == .requiresApproval {
            return Status(enabled: true, method: "SMAppService", note: "Needs approval in System Settings, General, Login Items")
        }
        if FileManager.default.fileExists(atPath: agentURL.path) { return Status(enabled: true, method: "LaunchAgent", note: nil) }
        return Status(enabled: false, method: "none", note: isInstalledCopy ? nil : "Only the copy in Applications can start at login")
    }

    @discardableResult
    static func enable() -> Status {
        guard isInstalledCopy else { return status() }
        do {
            try SMAppService.mainApp.register()
            let s = SMAppService.mainApp.status
            if s == .enabled || s == .requiresApproval {
                removeAgent()
                return status()
            }
        } catch {
            NSLog("MacMonitor: SMAppService register failed: \(error.localizedDescription). Using a LaunchAgent.")
        }
        installAgent()
        return status()
    }

    @discardableResult
    static func disable() -> Status {
        try? SMAppService.mainApp.unregister()
        removeAgent()
        return status()
    }

    private static func installAgent() {
        guard let exe = Bundle.main.executablePath, let data = try? LaunchAgentPlist.data(executable: exe) else { return }
        try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: agentURL)
        // launchd loads it at every login. Bootstrapping now also starts a second copy, which sees this one and quits.
        launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
    }

    private static func removeAgent() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(LaunchAgentPlist.label)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
