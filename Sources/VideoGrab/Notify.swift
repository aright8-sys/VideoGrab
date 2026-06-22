import Foundation
import AppKit
import UserNotifications

// 完成通知。点按通知会在访达里打开保存目录。
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()
    private var lastDir: URL?
    private var ready = false

    static func bootstrap() {
        shared.requestAuth()
    }

    static func send(title: String, body: String, fileDir: URL?) {
        shared.post(title: title, body: body, fileDir: fileDir)
    }

    private func requestAuth() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.ready = granted
        }
    }

    private func post(title: String, body: String, fileDir: URL?) {
        lastDir = fileDir
        // 没有通知权限（或非打包运行）时，退化为不打扰，避免崩溃
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // 前台也展示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 点按通知 → 打开保存目录
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let dir = lastDir {
            NSWorkspace.shared.open(dir)
        }
        completionHandler()
    }
}
