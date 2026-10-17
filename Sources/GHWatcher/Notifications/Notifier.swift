import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the process is not running from an app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func activate() {
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("[GHWatcher] Notification authorization error:", error) }
            if !granted { print("[GHWatcher] Notifications not granted") }
        }
    }

    func post(_ event: WatchEvent, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = event.kind.title
        content.subtitle = event.repo
        content.body = event.subtitle.isEmpty ? event.title : "\(event.title)\n\(event.subtitle)"
        content.threadIdentifier = event.repo
        if sound { content.sound = .default }
        if let url = event.url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    func postTest() {
        post(WatchEvent(kind: .workflowFailed, repo: "octocat/hello-world", title: "CI on main", subtitle: "This is what a notification looks like.", url: URL(string: "https://github.com")), sound: true)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
