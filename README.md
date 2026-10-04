# Gmail Desktop

A Mac app that wraps mail.google.com, with one isolated session per Google account.

There are two versions in this folder:

- **`electron/` (main, Chrome engine).** Same engine as Chrome, so Gmail feels as smooth
  as in the browser. About 500 MB on disk (it runs on both Apple silicon and Intel).
- **`Sources/` (lightweight, Safari engine).** Native SwiftUI + WKWebView, about 1 MB.
  Gmail feels slightly less smooth than in Chrome.

## Chrome-engine version (electron/)

```sh
cd ~/Desktop/GmailDesktop/electron
npm install                   # once
npm start                     # run from source
npm run build                 # build the app and Gmail Desktop (Chrome).zip
npm run build -- --install    # also install as /Applications/Gmail Desktop (Chrome).app
```

The app is built in `~/Library/Caches/gmail-desktop-build` (the iCloud Desktop adds file
attributes that break code signing) and zipped to `~/Desktop/GmailDesktop/Gmail Desktop (Chrome).zip`.

Its features match the list below, plus a right-click menu with spelling suggestions.
Settings live in **Gmail Desktop → Settings** in the menu bar.

Security (in addition to the points below):
- every page runs in Chromium's sandbox with context isolation and no Node.js access;
- Gmail may only use notifications, clipboard copy and full screen; camera, microphone,
  location and devices are always denied, and other sites get no permissions;
- cookies are encrypted with a key kept in your macOS Keychain ("Gmail Desktop Safe Storage");
- Electron's debug and "run as Node" switches are turned off in the binary (fuses), and the
  app refuses to load modified code (asar integrity);
- the only script added to Gmail forwards notification titles to macOS. It doesn't read
  the page or forms, and the app accepts it only from mail.google.com.
- Data lives in `~/Library/Application Support/Gmail Desktop/`.

After a rebuild macOS may ask once to let the app use its Keychain item; choose Always Allow.

## Safari-engine version (Sources/)

### Build and run

Requirements: macOS 14 or newer, Xcode (or the Swift toolchain).

```sh
cd ~/Desktop/GmailDesktop
./build-app.sh            # builds build/Gmail Desktop.app and Gmail Desktop.zip
open "build/Gmail Desktop.app"
./build-app.sh --install  # also copies it to /Applications
```

`swift build` alone compiles the code, but notifications, the `mailto:` handler and the
sandbox need the `.app` bundle that `build-app.sh` assembles. To work in Xcode, open
`Package.swift`.

## Features

- **Accounts:** the avatar button at the top right opens a Gmail-style account switcher
  with unread counts, *Add another account* (⇧⌘N), rename, sign out and remove. A red dot
  on the avatar means new mail in another account. There is no limit on the number of
  accounts. ⌘1…⌘9 select the first nine, ⌃Tab / ⌃⇧Tab cycle through all, and every
  account is also in the **Accounts** menu. The last selected account is remembered.
- **One Google account per app account:** *Sign Out* clears only that account's cookies and data and shows
  Google's sign-in page, so other accounts stay signed in. Google's "Add another account"
  adds a new app account instead of a second account in the same session, and switching to a
  second account inside one app account (`/mail/u/1`) is refused.
- **Separate sessions:** each account has its own `WKWebsiteDataStore(forIdentifier:)`,
  so cookies and storage never mix. Removing an account deletes its store.
- **Memory:** only the 3 most recently used accounts keep Gmail loaded. The others are
  unloaded and checked for new mail once a minute via Gmail's Atom feed
  (`https://mail.google.com/mail/u/0/feed/atom`), so badges and notifications keep
  working. Switching to an unloaded account takes a second or two while Gmail opens.
- **Dock badge:** total unread across all accounts, from Gmail's page title (loaded
  accounts) or the Atom feed (unloaded ones).
- **Notifications:** turn on *Gmail → Settings → General → Desktop notifications* in each
  account for sender/subject banners. If that's off, the app still notifies when an
  account's unread count goes up.
- **mailto:** Settings (⌘,) → *Make Gmail Desktop the Default Email App*. Links open a
  pre-filled Gmail compose for the selected account.
- **Compose:** ⌘N opens Gmail compose in its own window (switch it off in Settings to
  compose in the main window).
- **Attachments:** upload with the file picker or by dragging files into a message;
  downloads go to ~/Downloads.
- **Links:** links in emails open in your default browser, or in Chrome if you turn that on in Settings; Google sign-in stays in the app.
- ⌘R reload, ⌘[ / ⌘] back/forward, ⇧⌘I inbox.

## Security and privacy

- Apart from WebKit, the app makes one kind of request itself: the unread-count check for
  unloaded accounts. It goes only to `https://mail.google.com`, carries only that account's
  mail.google.com cookies (the ones WebKit already sends), never follows redirects and
  caches nothing. Clicked links leave for your default browser.
- The only injected script replaces the web Notification API. It does not read pages or
  form fields, and the app accepts its messages only from `https://mail.google.com`.
- Nothing is logged. Passwords are typed into Google's own page and never pass through
  the app's code.
- The app runs in the macOS App Sandbox (network client, user-selected files read-only,
  Downloads). Sessions are stored in
  `~/Library/Containers/com.ivanzakharov.GmailDesktop/Data/Library/WebKit/`, readable only
  by your macOS user, and encrypted at rest when FileVault is on.
- Web Inspector is disabled and Safari's fraudulent-website warning is on.

## Known limitations

- **Passwords AutoFill:** macOS only offers Passwords/iCloud Keychain AutoFill inside
  Safari and apps that own the website's domain, so it does not appear in this app.
  Copy the password from the Passwords app (or use Google's phone prompt) once per account;
  the session then stays signed in.
- **Passkeys** in WKWebView are limited for non-browser apps; use password + 2-step
  verification or the phone prompt.
- Google may block sign-in in embedded web views. The app sends a Safari user agent to
  avoid this; if Google still says the browser isn't secure, report it.
- Each loaded account is a full Gmail page (roughly 0.5–1.5 GB of memory). The Atom feed
  counts unread mail in the Inbox only.
- The app is signed ad hoc (no Developer ID), so it runs on this Mac but would need
  proper signing to share.
