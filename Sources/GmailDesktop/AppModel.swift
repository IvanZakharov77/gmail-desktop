import AppKit
import SwiftUI
import WebKit

struct Account: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// Filled in automatically from the Gmail page title once signed in.
    var email: String?

    var displayName: String { email ?? name }
}

/// Owns the accounts, their web sessions and unread counts.
///
/// Only the few most recently used accounts keep Gmail loaded (each one costs
/// 0.5–1.5 GB). The others are checked for new mail through Gmail's Atom feed.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var accounts: [Account] = []
    @Published var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: Keys.lastAccount)
            if started, let selectedID { didSelect(selectedID) }
        }
    }
    /// How many accounts keep Gmail loaded in memory.
    static let liveLimit = 3
    /// Most recently selected first.
    private var recent: [UUID] = []
    private var feedTimer: Timer?
    /// Web views are created only after launch; AppModel.shared must exist first.
    private var started = false
    /// Kept outside AppModel so Gmail's frequent title changes don't re-render the
    /// whole window and rebuild the menu bar on every section switch.
    let unreadCounts = UnreadCounts()
    private var unread: [UUID: Int] {
        get { unreadCounts.values }
        set { if unreadCounts.values != newValue { unreadCounts.values = newValue } }
    }

    private(set) var sessions: [UUID: WebSession] = [:]
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private var lastPageNotification: [UUID: Date] = [:]

    private enum Keys {
        static let accounts = "accounts"
        static let lastAccount = "lastAccountID"
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.accounts),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        if accounts.isEmpty {
            accounts = [Account(id: UUID(), name: "Account 1")]
            save()
        }
        let last = UserDefaults.standard.string(forKey: Keys.lastAccount).flatMap(UUID.init)
        selectedID = accounts.first(where: { $0.id == last })?.id ?? accounts.first?.id
    }

    func start() {
        started = true
        if let selectedID { didSelect(selectedID) }
        feedTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pollFeeds() }
        }
        feedTimer?.tolerance = 10
        Task {
            try? await Task.sleep(for: .seconds(3))
            pollFeeds()
        }
    }

    private func didSelect(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        _ = session(for: id)
        unloadIdleSessions()
    }

    /// Frees the memory of accounts outside the most recent few; the feed keeps their counts.
    private func unloadIdleSessions() {
        let keep = Set(recent.prefix(Self.liveLimit))
        for id in sessions.keys where !keep.contains(id) {
            sessions[id]?.tearDown()
            sessions[id] = nil
        }
    }

    /// Checks unread mail for accounts that aren't loaded.
    func pollFeeds() {
        for account in accounts where sessions[account.id] == nil {
            let id = account.id
            let store = dataStore(for: id)
            Task {
                guard let result = await GmailFeed.fetch(store: store), self.account(id) != nil,
                      sessions[id] == nil else { return }
                let detail = result.latestTitle.map { title in
                    [result.latestAuthor, title].compactMap { $0 }.joined(separator: ": ")
                }
                applyUnread(result.count, for: id, latest: detail)
            }
        }
    }

    var selectedSession: WebSession? { selectedID.flatMap { session(for: $0) } }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func dataStore(for id: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    func session(for id: UUID) -> WebSession? {
        guard account(id) != nil else { return nil }
        if let session = sessions[id] { return session }
        let session = WebSession(accountID: id, role: .main)
        session.load(GmailURL.inbox)
        sessions[id] = session
        return session
    }

    // MARK: Account management

    func addAccount() {
        let account = Account(id: UUID(), name: "Account \(accounts.count + 1)")
        accounts.append(account)
        save()
        selectedID = account.id
    }

    func select(index: Int) {
        guard accounts.indices.contains(index) else { return }
        selectedID = accounts[index].id
    }

    func selectAdjacent(_ offset: Int) {
        guard !accounts.isEmpty else { return }
        let current = accounts.firstIndex { $0.id == selectedID } ?? 0
        select(index: (current + offset + accounts.count) % accounts.count)
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].name = trimmed.isEmpty ? accounts[i].name : trimmed
        accounts[i].email = nil // a custom name wins over the detected address
        save()
    }

    /// Whether Google has a signed-in session in this account's store.
    func isSignedIn(_ id: UUID) async -> Bool {
        await dataStore(for: id).httpCookieStore.allCookies().contains { cookie in
            cookie.name == "SID" && cookie.domain.lowercased().hasSuffix("google.com")
        }
    }

    func confirmSignOut(_ id: UUID) {
        guard let account = account(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of \(account.displayName)?"
        alert.informativeText = "Only this account is signed out. Your other accounts stay signed in, and it stays in the list so you can sign in again."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        signOut(id)
    }

    /// Deletes this account's cookies and data and shows Google's sign-in page in its place.
    func signOut(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        sessions[id]?.tearDown()
        sessions[id] = nil
        unread[id] = nil
        updateDockBadge()
        if accounts[i].email != nil {
            accounts[i].email = nil
            save()
        }
        let store = dataStore(for: id)
        Task {
            await store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            if selectedID == id {
                _ = session(for: id)
                objectWillChange.send()
            }
        }
    }

    func confirmRemove(_ id: UUID) {
        guard let account = account(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.displayName)?"
        alert.informativeText = "This removes it from the list and deletes its cookies and cached data from this app. Your Google account itself is not affected."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remove(id)
    }

    private var explainedOneAccount = false

    func explainOneAccountPerTab() {
        guard !explainedOneAccount else { return }
        explainedOneAccount = true
        let alert = NSAlert()
        alert.messageText = "One Google account per entry"
        alert.informativeText = "To keep sign-outs separate, each account in the switcher holds one Google account. Use Add another account in the switcher at the top right."
        alert.runModal()
    }

    /// Removes the account and deletes its cookies, cache and local storage.
    func remove(_ id: UUID) {
        sessions[id]?.tearDown()
        sessions[id] = nil
        dataStores[id] = nil
        unread[id] = nil
        recent.removeAll { $0 == id }
        accounts.removeAll { $0.id == id }
        if accounts.isEmpty { accounts = [Account(id: UUID(), name: "Account 1")] }
        save()
        if selectedID == id || selectedID == nil { selectedID = accounts.first?.id }
        updateDockBadge()
        Task {
            // The store can only be removed once no web view uses it any more.
            try? await Task.sleep(for: .seconds(1))
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Keys.accounts)
        }
    }

    // MARK: Page title → unread count, email

    func titleChanged(_ title: String, for id: UUID) {
        guard let parsed = GmailTitle(title) else { return }

        if let email = parsed.email, let i = accounts.firstIndex(where: { $0.id == id }),
           accounts[i].email == nil, accounts[i].name.hasPrefix("Account ") {
            accounts[i].email = email
            save()
        }

        applyUnread(parsed.unread, for: id, latest: nil)
    }

    private func applyUnread(_ count: Int, for id: UUID, latest: String?) {
        let previous = unread[id]
        guard previous != count else { return }
        unread[id] = count
        updateDockBadge()

        // Fallback notification when Gmail's own desktop notifications are off.
        // The first count after launch only sets the baseline.
        if let previous, count > previous {
            let added = count - previous
            Task {
                try? await Task.sleep(for: .seconds(4))
                if let last = lastPageNotification[id], Date().timeIntervalSince(last) < 20 { return }
                let name = account(id)?.displayName ?? "Gmail"
                Notifier.shared.post(
                    title: added == 1 ? (latest ?? "New message") : "\(added) new messages",
                    body: name,
                    accountID: id
                )
            }
        }
    }

    func pageNotification(title: String, body: String, accountID: UUID) {
        lastPageNotification[accountID] = Date()
        Notifier.shared.post(title: title, body: body, accountID: accountID)
    }

    private func updateDockBadge() {
        let total = unread.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    // MARK: Compose / mailto

    func compose(mailto: URL? = nil) {
        guard let id = selectedID else { return }
        let url = GmailURL.compose(mailto: mailto)
        if UserDefaults.standard.object(forKey: Prefs.composeInWindow) as? Bool ?? true {
            ComposeWindows.open(url: url, accountID: id)
        } else {
            session(for: id)?.load(url)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class UnreadCounts: ObservableObject {
    @Published var values: [UUID: Int] = [:]
}

enum Prefs {
    static let composeInWindow = "composeInSeparateWindow"
    static let openLinksInChrome = "openLinksInChrome"
}

/// Parses titles like "Inbox (12) - name@gmail.com - Gmail".
struct GmailTitle {
    let unread: Int
    let email: String?

    init?(_ title: String) {
        guard title.contains("Gmail") || title.contains("@") else { return nil }
        let parts = title.components(separatedBy: " - ")
        email = parts.first { $0.contains("@") && !$0.contains(" ") }
        let first = parts.first ?? title
        if let open = first.lastIndex(of: "("), let close = first.lastIndex(of: ")"), open < close {
            let digits = first[first.index(after: open)..<close].filter(\.isNumber)
            unread = Int(digits) ?? 0
        } else {
            unread = 0
        }
    }
}

enum GmailURL {
    static let inbox = URL(string: "https://mail.google.com/mail/u/0/")!

    /// Gmail's full-page compose, optionally pre-filled from a mailto: URL.
    static func compose(mailto: URL?) -> URL {
        var items = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "tf", value: "1"),
        ]
        if let mailto, let parts = URLComponents(url: mailto, resolvingAgainstBaseURL: false) {
            var to = [parts.path.removingPercentEncoding ?? parts.path].filter { !$0.isEmpty }
            for item in parts.queryItems ?? [] {
                guard let value = item.value, !value.isEmpty else { continue }
                switch item.name.lowercased() {
                case "to": to.append(value)
                case "cc": items.append(URLQueryItem(name: "cc", value: value))
                case "bcc": items.append(URLQueryItem(name: "bcc", value: value))
                case "subject": items.append(URLQueryItem(name: "su", value: value))
                case "body": items.append(URLQueryItem(name: "body", value: value))
                default: break
                }
            }
            if !to.isEmpty { items.append(URLQueryItem(name: "to", value: to.joined(separator: ","))) }
        }
        var components = URLComponents(url: inbox, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }
}
