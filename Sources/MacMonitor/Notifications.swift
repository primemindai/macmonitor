import Foundation
@preconcurrency import UserNotifications
import MonitorCore

/// Mac notifications. Asked once on first launch; if denied, the Events log still records everything.
/// Only works inside the .app bundle (UserNotifications needs a bundle id).
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let center: UNUserNotificationCenter?

    init(model: AppModel) {
        self.model = model
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    func askOnceIfNeeded() {
        guard let center, let model else { return }
        if !model.prefs.notificationsAsked {
            model.prefs.notificationsAsked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor [weak self] in self?.refreshStatus() }
            }
        }
        refreshStatus()
    }

    func refreshStatus() {
        guard let center else { model?.notificationStatus = "Not available outside the app bundle"; return }
        center.getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "On"
            case .denied: text = "Notifications are off in System Settings"
            case .notDetermined: text = "Waiting for your answer (Allow or Don't Allow)"
            @unknown default: text = "Unknown"
            }
            let raw = settings.authorizationStatus.rawValue
            Task { @MainActor [weak self] in
                self?.model?.notificationStatus = text
                self?.lastRawStatus = raw
            }
        }
    }

    private(set) var lastRawStatus: Int = -1

    func post(_ e: MonitorEvent) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "\(e.kind)-\(Int(e.ts.timeIntervalSince1970))", content: content, trigger: nil)
        center.add(req) { err in
            if let err { NSLog("MacMonitor notification failed: \(err.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
