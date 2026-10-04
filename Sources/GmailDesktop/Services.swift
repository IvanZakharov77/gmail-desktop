import AppKit
import UserNotifications
import WebKit

// MARK: - Compose and popup windows

@MainActor
enum ComposeWindows {
    private static var open: [ObjectIdentifier: (WebSession, NSObjectProtocol)] = [:]

    static func open(url: URL, accountID: UUID) {
        let session = WebSession(accountID: accountID, role: .compose)
        let window = makeWindow(for: session, title: "New Message")
        session.window = window
        retain(session)
        session.load(url)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func makeWindow(for session: WebSession, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.setFrameAutosaveName("ComposeWindow")
        return window
    }

    /// Keeps the session alive until its window closes.
    static func retain(_ session: WebSession) {
        guard let window = session.window else { return }
        let key = ObjectIdentifier(session)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let (session, token) = open.removeValue(forKey: key) else { return }
                NotificationCenter.default.removeObserver(token)
                session.window = nil
                session.tearDown()
            }
        }
        open[key] = (session, token)
    }
}

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, accountID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["accountID": accountID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = (response.notification.request.content.userInfo["accountID"] as? String).flatMap(UUID.init)
        await MainActor.run {
            if let id, AppModel.shared.account(id) != nil { AppModel.shared.selectedID = id }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Downloads (attachments)

@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            n += 1
        }
        destinations[ObjectIdentifier(download)] = candidate
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        NSAlert(error: error).runModal()
    }

    private var destinations: [ObjectIdentifier: URL] = [:]
}
