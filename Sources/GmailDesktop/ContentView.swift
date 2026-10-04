import AppKit
import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WebViewHost(session: model.selectedSession)
            .navigationTitle(model.selectedID.flatMap { model.account($0)?.displayName } ?? "Gmail Desktop")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.compose()
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .help("New Message (⌘N)")
                    AccountSwitcherButton(unread: model.unreadCounts)
                }
            }
    }
}

/// Gmail-style account picker at the top right: current account's avatar opens a
/// list of all accounts with unread counts, plus add, sign out and remove.
struct AccountSwitcherButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var unread: UnreadCounts
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            if let account = model.selectedID.flatMap(model.account) {
                AccountAvatar(account: account, size: 26)
                    .overlay(alignment: .topTrailing) {
                        if otherUnread > 0 {
                            Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: 2, y: -2)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .help("Switch Account")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AccountSwitcher(unread: unread) { showing = false }
                .environmentObject(model)
        }
    }

    /// New mail in accounts other than the one on screen.
    private var otherUnread: Int {
        unread.values.filter { $0.key != model.selectedID }.map(\.value).reduce(0, +)
    }
}

struct AccountSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var unread: UnreadCounts
    let dismiss: () -> Void
    @State private var renaming: Account?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current = model.selectedID.flatMap(model.account) {
                VStack(spacing: 6) {
                    AccountAvatar(account: current, size: 56)
                    Text(current.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Rename…") { newName = current.displayName; renaming = current }
                        Button("Sign Out…") { dismiss(); model.confirmSignOut(current.id) }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                Divider()
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        row(account, index: index)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                action("Add another account", systemImage: "person.badge.plus", shortcut: "⇧⌘N") {
                    dismiss(); model.addAccount()
                }
                if let id = model.selectedID {
                    action("Remove this account…", systemImage: "trash") {
                        dismiss(); model.confirmRemove(id)
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 320)
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ account: Account, index: Int) -> some View {
        let selected = account.id == model.selectedID
        let count = unread.values[account.id] ?? 0
        return Button {
            model.selectedID = account.id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                AccountAvatar(account: account, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName).lineLimit(1).truncationMode(.middle)
                    if account.email != nil, account.name != account.displayName,
                       !account.name.hasPrefix("Account ") {
                        Text(account.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if count > 0 {
                    Text(count > 9999 ? "9999+" : "\(count)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }
                if index < 9 {
                    Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(
        _ title: String, systemImage: String, shortcut: String? = nil, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack {
                Image(systemName: systemImage).frame(width: 30)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A colored circle with the account's first letter, like Gmail's default avatar.
struct AccountAvatar: View {
    let account: Account
    let size: CGFloat

    private static let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown, .red, .cyan,
    ]

    var body: some View {
        let name = account.displayName
        let letter = name.first.map { String($0).uppercased() } ?? "?"
        Circle()
            .fill(Self.colors[stableIndex])
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel(name)
    }

    /// UUID.hashValue changes per launch, so derive the color from the UUID bytes instead.
    private var stableIndex: Int {
        let bytes = withUnsafeBytes(of: account.id.uuid) { Array($0) }
        return Int(bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) % Self.colors.count
    }
}

/// Shows the selected account's long-lived WKWebView; other accounts keep running in the background.
struct WebViewHost: NSViewRepresentable {
    let session: WebSession?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView = session?.webView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.window?.makeFirstResponder(webView)
    }
}
