import AppKit
import SwiftUI
import WebKit

@main
struct GmailDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Gmail Desktop", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // mailto: links from other apps arrive as a "get URL" Apple Event.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Notifier.shared.start()
            AppModel.shared.start()
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme?.lowercased() == "mailto" else { return }
        MainActor.assumeIsolated { AppModel.shared.compose(mailto: url) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.compose() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Add Account") { model.addAccount() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Accounts") {
            Button("Next Account") { model.selectAdjacent(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Account") { model.selectAdjacent(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Sign Out of Current Account…") {
                if let id = model.selectedID { model.confirmSignOut(id) }
            }
            Button("Remove Current Account…") {
                if let id = model.selectedID { model.confirmRemove(id) }
            }
            Divider()
            // Every account is listed; the first nine also get ⌘1…⌘9.
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                if index < 9 {
                    Button(account.displayName) { model.select(index: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    Button(account.displayName) { model.select(index: index) }
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Reload") { model.selectedSession?.webView.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Back") { model.selectedSession?.webView.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.selectedSession?.webView.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Go to Inbox") { model.selectedSession?.load(GmailURL.inbox) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.composeInWindow) private var composeInWindow = true
    @AppStorage(Prefs.openLinksInChrome) private var openLinksInChrome = false
    @State private var defaultAppMessage: String?

    var body: some View {
        Form {
            Toggle("Open New Message and mailto: links in a separate window", isOn: $composeInWindow)
            Toggle("Open links from emails in Google Chrome (instead of the default browser)", isOn: $openLinksInChrome)
            LabeledContent("Email links") {
                VStack(alignment: .leading) {
                    Button("Make Gmail Desktop the Default Email App") { makeDefault() }
                    if let defaultAppMessage {
                        Text(defaultAppMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("For notifications with sender and subject, enable Desktop notifications in Gmail → Settings → General for each account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }

    private func makeDefault() {
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
                defaultAppMessage = "Done. mailto: links now open here."
            } catch {
                defaultAppMessage = error.localizedDescription
            }
        }
    }
}
