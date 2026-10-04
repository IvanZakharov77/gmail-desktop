import AppKit
import WebKit

/// One WKWebView plus all its delegates. Used for the main account view,
/// compose windows and popups opened by Gmail (pop-out messages, etc.).
@MainActor
final class WebSession: NSObject {
    enum Role { case main, compose, popup }

    /// Google sign-in rejects WKWebView's default user agent, so present as Safari.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let accountID: UUID
    let role: Role
    let webView: WKWebView
    /// Set for compose and popup sessions, which own their window.
    var window: NSWindow?

    private var titleObservation: NSKeyValueObservation?
    private let messageProxy = MessageProxy()
    /// Popups share their opener's configuration and must not unregister its handler.
    private let ownsConfiguration: Bool

    init(accountID: UUID, role: Role, configuration: WKWebViewConfiguration? = nil) {
        self.accountID = accountID
        self.role = role
        ownsConfiguration = configuration == nil
        let config = configuration ?? WebSession.makeConfiguration(for: accountID)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        if ownsConfiguration {
            messageProxy.target = self
            config.userContentController.add(messageProxy, name: "gmailDesktopNotify")
        }
        webView.customUserAgent = WebSession.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false // no Web Inspector access to signed-in pages
        webView.navigationDelegate = self
        webView.uiDelegate = self

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            let title = webView.title ?? ""
            Task { @MainActor in self?.titleChanged(title) }
        }
    }

    static func makeConfiguration(for accountID: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = AppModel.shared.dataStore(for: accountID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        // Hidden accounts keep running (for unread counts) but at low priority,
        // so they don't compete with the account on screen.
        config.preferences.inactiveSchedulingPolicy = .throttle
        config.userContentController.addUserScript(
            WKUserScript(source: Scripts.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        return config
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func tearDown() {
        titleObservation = nil
        if ownsConfiguration {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "gmailDesktopNotify")
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window?.close()
    }

    private func titleChanged(_ title: String) {
        switch role {
        case .main: AppModel.shared.titleChanged(title, for: accountID)
        case .compose, .popup: if !title.isEmpty { window?.title = title }
        }
    }

    fileprivate func handleNotification(_ body: Any, from frame: WKFrameInfo) {
        // Only Gmail itself may raise notifications; ignore any other page.
        guard frame.isMainFrame, frame.securityOrigin.protocol == "https",
              frame.securityOrigin.host == "mail.google.com" else { return }
        guard let dict = body as? [String: Any] else { return }
        let title = dict["title"] as? String ?? "Gmail"
        let text = dict["body"] as? String ?? ""
        AppModel.shared.pageNotification(title: title, body: text, accountID: accountID)
    }

    /// Popups start hidden so a blank window never flashes for links that go to the browser.
    private func showPopupWindowIfNeeded() {
        guard role == .popup, let window, !window.isVisible else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - One Google account per app account

extension WebSession {
    /// Each app account holds exactly one Google account in its own data store, so signing
    /// out never touches the others. Google's "Add another account" becomes a new app
    /// account; switching to a second Google account inside one store is refused. Returns true when the navigation was handled here.
    func handleSecondAccount(_ url: URL) async -> Bool {
        switch LinkRouter.secondAccountIntent(url) {
        case nil:
            return false
        case .add:
            // When nobody is signed in yet, Google uses the same page for a normal sign-in.
            guard await AppModel.shared.isSignedIn(accountID) else { return false }
            AppModel.shared.addAccount()
            return true
        case .switchTo:
            if role == .main { load(GmailURL.inbox) }
            AppModel.shared.explainOneAccountPerTab()
            return true
        }
    }
}

// MARK: - Navigation

extension WebSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if navigationAction.shouldPerformDownload { return .download }

        if url.scheme == "mailto" {
            AppModel.shared.compose(mailto: url)
            return .cancel
        }
        if !LinkRouter.isWebScheme(url) {
            if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
            // Other schemes (tel:, facetime:, …) open another app, but only on a real click
            // and never for local files, so a message can't launch things on its own.
            if navigationAction.navigationType == .linkActivated, url.scheme != "file" {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame else { return .allow }

        if await handleSecondAccount(url) { return .cancel }

        // A popup whose first real page is outside Gmail is just a link: hand it to the browser.
        if role == .popup, window?.isVisible == false, !LinkRouter.isGoogleInternal(url) {
            LinkRouter.openExternally(url)
            window?.close()
            return .cancel
        }
        // Clicked links leave the app; redirects and form posts (sign-in, SSO) stay inside.
        if navigationAction.navigationType == .linkActivated, !LinkRouter.isGoogleInternal(url) {
            LinkRouter.openExternally(url)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        showPopupWindowIfNeeded()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - UI (new windows, file picker, JS dialogs)

extension WebSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, LinkRouter.secondAccountIntent(url) != nil {
            Task { _ = await handleSecondAccount(url) }
            return nil
        }
        if let url = navigationAction.request.url, LinkRouter.isWebScheme(url),
           !LinkRouter.isGoogleInternal(url) {
            LinkRouter.openExternally(url)
            return nil
        }
        // Gmail opens about:blank first and navigates it later, so keep the
        // popup hidden until we know where it is going.
        let popup = WebSession(accountID: accountID, role: .popup, configuration: configuration)
        let window = ComposeWindows.makeWindow(for: popup, title: "Gmail")
        popup.window = window
        ComposeWindows.retain(popup)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if role != .main { window?.close() }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Breaks the retain cycle between WKUserContentController and the session.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebSession?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let frame = message.frameInfo
        MainActor.assumeIsolated { target?.handleNotification(body, from: frame) }
    }
}

enum LinkRouter {
    enum SecondAccount { case add, switchTo }

    static func secondAccountIntent(_ url: URL) -> SecondAccount? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "accounts.google.com", url.path.lowercased().contains("addsession") {
            return .add
        }
        // /mail/u/0 is this store's own account; /mail/u/1 and up would be a second one.
        if host == "mail.google.com",
           url.path.range(of: #"^/mail/u/[1-9]"#, options: .regularExpression) != nil {
            return .switchTo
        }
        return nil
    }

    static func isWebScheme(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// Pages that belong inside the app: Gmail itself, Google sign-in and attachment hosts.
    static func isGoogleInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        let exact: Set<String> = [
            "mail.google.com", "accounts.google.com", "accounts.youtube.com",
            "ogs.google.com", "contacts.google.com", "myaccount.google.com",
        ]
        if exact.contains(host) { return true }
        if host.hasSuffix(".gstatic.com") || host.hasSuffix(".googleusercontent.com") { return true }
        if host == "www.google.com" || host == "google.com" {
            let path = url.path
            return path.hasPrefix("/accounts") || path.hasPrefix("/a/") || path.hasPrefix("/signin")
        }
        return false
    }

    /// Opens in the default browser, unwrapping Google's redirect links.
    static func openExternally(_ url: URL) {
        var target = url
        if let host = url.host, host.hasSuffix("google.com"), url.path == "/url",
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
           let unwrapped = URL(string: q) {
            target = unwrapped
        }
        if UserDefaults.standard.bool(forKey: Prefs.openLinksInChrome),
           let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([target], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

enum Scripts {
    /// Replaces the web Notification API so Gmail's own desktop notifications
    /// (Settings → General → Desktop notifications) become macOS notifications.
    static let notificationShim = """
    (function () {
      if (window.__gmailDesktopNotification) return;
      window.__gmailDesktopNotification = true;
      class GDNotification extends EventTarget {
        constructor(title, options) {
          super();
          options = options || {};
          this.title = String(title || '');
          this.body = String(options.body || '');
          this.tag = String(options.tag || '');
          this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
          try {
            window.webkit.messageHandlers.gmailDesktopNotify.postMessage({ title: this.title, body: this.body, tag: this.tag });
          } catch (e) {}
        }
        close() {}
        static get permission() { return 'granted'; }
        static requestPermission(callback) {
          if (callback) callback('granted');
          return Promise.resolve('granted');
        }
      }
      window.Notification = GDNotification;
    })();
    """
}
