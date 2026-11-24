import Foundation
import UIKit
import UserNotifications
import BackgroundTasks
import WidgetKit

/// Reads the sideload signing expiry from embedded.mobileprovision and reminds you before it runs out.
final class ExpiryWatcher: ObservableObject {
    static let shared = ExpiryWatcher()
    @Published private(set) var expires: Date?
    @Published private(set) var message: String?

    func start() {
        expires = ExpiryWatcher.readExpiry()
        refreshMessage()
        scheduleReminder()
    }

    static func readExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let plist = String(text[start.lowerBound..<end.upperBound])
        guard let pd = plist.data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: pd, options: [], format: nil) as? [String: Any] else { return nil }
        return obj["ExpirationDate"] as? Date
    }

    func refreshMessage() {
        guard let e = expires else { message = nil; return }
        let hours = e.timeIntervalSinceNow / 3600
        if hours < 0 { message = "Lumora's signature has expired — reinstall it with Sideloadly." }
        else if hours < 48 {
            let f = RelativeDateTimeFormatter()
            message = "Lumora expires \(f.localizedString(for: e, relativeTo: Date())). Re-install with Sideloadly (same Apple ID) to keep going."
        } else { message = nil }
    }

    private func scheduleReminder() {
        guard let e = expires else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: ["expiry-1", "expiry-2"])
            for (id, before, text) in [("expiry-1", 24.0 * 3600, "Lumora expires tomorrow"), ("expiry-2", 3.0 * 3600, "Lumora expires in 3 hours")] {
                let fire = e.addingTimeInterval(-before)
                guard fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = text
                content.body = "Open Sideloadly on your PC and reinstall Lumora with the same Apple ID — your photos stay."
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }
}

/// Keeps smart sorting going after you leave the app (a short grace period, plus a background task iOS may run later).
enum BackgroundWork {
    static let taskID = "com.balasinoss.lumora.sort"
    private static var bgTask: UIBackgroundTaskIdentifier = .invalid

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            let pending = LibraryStore.shared.items.filter { $0.analysis == nil }
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            DispatchQueue.main.async {
                SmartSort.shared.enqueue(pending)
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { task.setTaskCompleted(success: true) }
            }
        }
    }

    /// Call when the app goes to the background.
    static func didEnterBackground() {
        WidgetBridge.publish()
        if SmartSort.shared.isBusy || LibraryStore.shared.items.contains(where: { $0.analysis == nil }) {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "smart-sort") {
                UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
            }
            let req = BGProcessingTaskRequest(identifier: taskID)
            req.requiresExternalPower = false
            req.requiresNetworkConnectivity = false
            try? BGTaskScheduler.shared.submit(req)
        }
    }
}

/// Shares the latest picks with the home-screen widget through the app group.
enum WidgetBridge {
    static let group = "group.com.balasinoss.lumora"

    static func publish() {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let store = LibraryStore.shared
        let picks = store.items.filter(\.flagged)
        let source = (picks.isEmpty ? store.items : picks).prefix(4)
        var names: [String] = []
        for (i, it) in source.enumerated() {
            guard let img = store.thumbnail(it), let d = img.jpegData(compressionQuality: 0.8) else { continue }
            let name = "pick\(i).jpg"
            try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        let info: [String: Any] = ["images": names, "picks": picks.count, "total": store.items.count, "updated": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: info) { try? d.write(to: dir.appendingPathComponent("widget.json"), options: .atomic) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
