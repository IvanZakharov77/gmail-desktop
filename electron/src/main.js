'use strict';

const {
  app, BrowserWindow, WebContentsView, Menu, Notification, dialog, ipcMain, session, shell,
} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');

const BAR_HEIGHT = 44;
const INBOX = 'https://mail.google.com/mail/u/0/';
const GMAIL_PRELOAD = path.join(__dirname, 'preload-gmail.js');
const BAR_PRELOAD = path.join(__dirname, 'preload-bar.js');

// Every renderer runs in Chromium's OS sandbox.
app.enableSandbox();

// Google refuses sign-in from user agents that mention Electron, so present as plain Chrome.
app.userAgentFallback = app.userAgentFallback
  .replace(/\sElectron\/\S+/, '')
  .replace(/\s(gmail-desktop|Gmail Desktop)\/\S+/i, '');

// ---------------------------------------------------------------------------
// Persistent state (accounts, last account, preferences)

const statePath = () => path.join(app.getPath('userData'), 'state.json');

function loadState() {
  let saved = {};
  try { saved = JSON.parse(fs.readFileSync(statePath(), 'utf8')); } catch { /* first launch */ }
  const s = {
    accounts: Array.isArray(saved.accounts) ? saved.accounts.filter((a) => a && isUUID(a.id)) : [],
    lastAccountID: saved.lastAccountID,
    composeInWindow: saved.composeInWindow !== false,
    openLinksInChrome: saved.openLinksInChrome === true,
  };
  if (s.accounts.length === 0) s.accounts.push(newAccount(1));
  return s;
}

function saveState() {
  fs.mkdirSync(path.dirname(statePath()), { recursive: true });
  fs.writeFileSync(statePath(), JSON.stringify(state, null, 2), { mode: 0o600 });
}

function isUUID(value) {
  return typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value);
}

function newAccount(n) {
  return { id: crypto.randomUUID(), name: `Account ${n}`, email: null };
}

const label = (account) => account.email || account.name;

let state;
let mainWindow;
let quitting = false;
let pendingMailto = null;
const views = new Map(); // account id -> WebContentsView
const unread = new Map(); // account id -> count
const lastPageNotification = new Map(); // account id -> timestamp
const configuredSessions = new Set();

// ---------------------------------------------------------------------------
// Link and navigation rules

function isWebURL(url) {
  try { return ['http:', 'https:'].includes(new URL(url).protocol); } catch { return false; }
}

/** Pages that belong inside the app: Gmail, Google sign-in and attachment hosts. */
function isGoogleInternal(url) {
  let u;
  try { u = new URL(url); } catch { return false; }
  const host = u.hostname.toLowerCase();
  const exact = new Set([
    'mail.google.com', 'accounts.google.com', 'accounts.youtube.com',
    'ogs.google.com', 'contacts.google.com', 'myaccount.google.com',
  ]);
  if (exact.has(host)) return true;
  if (host.endsWith('.gstatic.com') || host.endsWith('.googleusercontent.com')) return true;
  if (host === 'www.google.com' || host === 'google.com') {
    return /^\/(accounts|a\/|signin)/.test(u.pathname);
  }
  return false;
}

function isGmailOrigin(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && u.hostname === 'mail.google.com';
  } catch { return false; }
}

const SAFE_EXTERNAL_SCHEMES = new Set(['tel:', 'sms:', 'facetime:', 'facetime-audio:', 'maps:']);

/** Opens a link in the browser, unwrapping Google's redirect links. */
function openExternally(url) {
  let target = url;
  try {
    const u = new URL(url);
    if (u.hostname.endsWith('google.com') && u.pathname === '/url') {
      const q = u.searchParams.get('q') || u.searchParams.get('url');
      if (q && isWebURL(q)) target = q;
    }
  } catch { return; }
  if (!isWebURL(target)) {
    const scheme = new URL(target).protocol;
    if (SAFE_EXTERNAL_SCHEMES.has(scheme)) shell.openExternal(target);
    return;
  }
  if (state.openLinksInChrome) {
    require('node:child_process').execFile('/usr/bin/open', ['-b', 'com.google.Chrome', target], (err) => {
      if (err) shell.openExternal(target);
    });
  } else {
    shell.openExternal(target);
  }
}

// ---------------------------------------------------------------------------
// Sessions (one per account) and security policy

const ALLOWED_PERMISSIONS = new Set(['notifications', 'clipboard-sanitized-write', 'fullscreen']);

function sessionFor(accountID) {
  const ses = session.fromPartition(`persist:${accountID}`);
  if (configuredSessions.has(accountID)) return ses;
  configuredSessions.add(accountID);

  ses.setUserAgent(app.userAgentFallback);
  ses.setSpellCheckerLanguages(['en-US', 'ru']);

  // Gmail may only notify, copy and go full screen. Camera, microphone, location,
  // USB, MIDI etc. are always denied, and other sites get nothing.
  ses.setPermissionRequestHandler((wc, permission, callback, details) => {
    callback(ALLOWED_PERMISSIONS.has(permission) && isGmailOrigin(details.requestingUrl || wc.getURL()));
  });
  ses.setPermissionCheckHandler((wc, permission, origin) => (
    ALLOWED_PERMISSIONS.has(permission) && isGmailOrigin(origin)
  ));
  ses.setDevicePermissionHandler(() => false);

  ses.on('will-download', (_event, item) => {
    item.setSavePath(uniqueDownloadPath(item.getFilename()));
    item.once('done', (_e, result) => {
      if (result === 'completed') shell.showItemInFolder(item.getSavePath());
    });
  });
  return ses;
}

function uniqueDownloadPath(filename) {
  const dir = app.getPath('downloads');
  const name = path.basename(filename) || 'download';
  const ext = path.extname(name);
  const base = name.slice(0, name.length - ext.length);
  let candidate = path.join(dir, name);
  for (let n = 1; fs.existsSync(candidate); n += 1) {
    candidate = path.join(dir, `${base} (${n})${ext}`);
  }
  return candidate;
}

function gmailWebPreferences(accountID) {
  return {
    session: sessionFor(accountID),
    preload: GMAIL_PRELOAD,
    sandbox: true,
    contextIsolation: true,
    nodeIntegration: false,
    webSecurity: true,
    allowRunningInsecureContent: false,
    safeDialogs: true,
    spellcheck: true,
    devTools: !app.isPackaged,
  };
}

/** Applies link rules, popups, context menu and crash recovery to a Gmail page. */
function wire(wc, accountID, role) {
  wc.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('mailto:')) { compose(url); return { action: 'deny' }; }
    if (isWebURL(url) && !isGoogleInternal(url)) { openExternally(url); return { action: 'deny' }; }
    if (url && url !== 'about:blank' && !isWebURL(url)) { openExternally(url); return { action: 'deny' }; }
    // Gmail popups (pop-out messages, print) open in their own window, hidden until
    // we know they stay inside Gmail.
    return {
      action: 'allow',
      overrideBrowserWindowOptions: {
        width: 900, height: 700, show: false, webPreferences: gmailWebPreferences(accountID),
      },
    };
  });
  wc.on('did-create-window', (win) => {
    wire(win.webContents, accountID, 'popup');
    win.webContents.once('did-navigate', (_e, url) => { if (isGoogleInternal(url)) win.show(); });
  });

  wc.on('will-navigate', (event, url) => {
    if (url.startsWith('mailto:')) { event.preventDefault(); compose(url); return; }
    if (!isWebURL(url)) { event.preventDefault(); return; }
    if (isGoogleInternal(url)) return;
    // Leaving Gmail for another site is a clicked link: send it to the browser. During
    // sign-in (not yet on Gmail) redirects to an organisation's login page are allowed.
    const current = wc.getURL();
    if (isGmailOrigin(current) || role === 'popup' && (!current || current === 'about:blank')) {
      event.preventDefault();
      openExternally(url);
      if (role === 'popup' && !BrowserWindow.fromWebContents(wc)?.isVisible()) {
        BrowserWindow.fromWebContents(wc)?.close();
      }
    }
  });

  if (role === 'main') {
    wc.on('page-title-updated', (_e, title) => titleChanged(accountID, title));
  }
  wc.on('context-menu', (_e, params) => showContextMenu(wc, params));
  wc.on('render-process-gone', (_e, details) => {
    if (details.reason !== 'clean-exit') setTimeout(() => wc.isDestroyed() || wc.reload(), 1000);
  });
}

function showContextMenu(wc, params) {
  const items = [];
  for (const suggestion of params.dictionarySuggestions.slice(0, 5)) {
    items.push({ label: suggestion, click: () => wc.replaceMisspelling(suggestion) });
  }
  if (params.misspelledWord) {
    items.push({
      label: 'Add to Dictionary',
      click: () => wc.session.addWordToSpellCheckerDictionary(params.misspelledWord),
    });
    items.push({ type: 'separator' });
  }
  if (params.linkURL && isWebURL(params.linkURL)) {
    items.push({ label: 'Open Link in Browser', click: () => openExternally(params.linkURL) });
    items.push({ label: 'Copy Link', click: () => require('electron').clipboard.writeText(params.linkURL) });
    items.push({ type: 'separator' });
  }
  if (params.isEditable) {
    items.push({ role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'pasteAndMatchStyle' });
  } else if (params.selectionText) {
    items.push({ role: 'copy' });
  }
  items.push({ role: 'selectAll' });
  Menu.buildFromTemplate(items).popup({ window: BrowserWindow.fromWebContents(wc) || mainWindow });
}

// ---------------------------------------------------------------------------
// Main window: account bar on top, the selected account's Gmail below

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 800,
    minHeight: 500,
    title: 'Gmail Desktop',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 14, y: 15 },
    backgroundColor: '#ffffff',
    show: false,
    webPreferences: {
      preload: BAR_PRELOAD,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      devTools: !app.isPackaged,
    },
  });
  mainWindow.loadFile(path.join(__dirname, 'bar.html'));
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (e) => e.preventDefault());
  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.on('resize', layoutSelectedView);
  // Closing the window hides it so accounts stay signed in and keep counting mail.
  mainWindow.on('close', (event) => {
    if (!quitting) { event.preventDefault(); mainWindow.hide(); }
  });
}

function ensureView(accountID) {
  let view = views.get(accountID);
  if (view) return view;
  view = new WebContentsView({ webPreferences: gmailWebPreferences(accountID) });
  wire(view.webContents, accountID, 'main');
  view.webContents.loadURL(INBOX);
  views.set(accountID, view);
  return view;
}

function layoutSelectedView() {
  const view = views.get(state.lastAccountID);
  if (!view || !mainWindow) return;
  const [width, height] = mainWindow.getContentSize();
  view.setBounds({ x: 0, y: BAR_HEIGHT, width, height: Math.max(0, height - BAR_HEIGHT) });
}

function selectAccount(accountID) {
  if (!state.accounts.some((a) => a.id === accountID)) return;
  const previous = views.get(state.lastAccountID);
  const view = ensureView(accountID);
  state.lastAccountID = accountID;
  if (previous && previous !== view) mainWindow.contentView.removeChildView(previous);
  mainWindow.contentView.addChildView(view);
  layoutSelectedView();
  view.webContents.focus();
  saveState();
  sendBarState();
}

function selectAdjacent(offset) {
  const i = state.accounts.findIndex((a) => a.id === state.lastAccountID);
  const n = state.accounts.length;
  selectAccount(state.accounts[(Math.max(i, 0) + offset + n) % n].id);
}

function selectedWebContents() {
  return views.get(state.lastAccountID)?.webContents;
}

function addAccount() {
  const account = newAccount(state.accounts.length + 1);
  state.accounts.push(account);
  saveState();
  selectAccount(account.id);
  buildMenu();
}

function renameAccount(accountID, name) {
  const account = state.accounts.find((a) => a.id === accountID);
  const trimmed = String(name || '').trim().slice(0, 60);
  if (!account || !trimmed) return;
  account.name = trimmed;
  account.email = null; // a custom name wins over the detected address
  saveState();
  sendBarState();
  buildMenu();
}

async function removeAccount(accountID) {
  const account = state.accounts.find((a) => a.id === accountID);
  if (!account) return;
  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    message: `Remove ${label(account)}?`,
    detail: "This deletes the account's cookies and cached data from this app. Your Google account itself is not affected.",
    buttons: ['Remove and Sign Out', 'Cancel'],
    defaultId: 1,
    cancelId: 1,
  });
  if (response !== 0) return;

  const view = views.get(accountID);
  if (view) {
    mainWindow.contentView.removeChildView(view);
    view.webContents.close();
    views.delete(accountID);
  }
  const ses = session.fromPartition(`persist:${accountID}`);
  await ses.clearStorageData();
  await ses.clearCache();
  configuredSessions.delete(accountID);
  unread.delete(accountID);
  state.accounts = state.accounts.filter((a) => a.id !== accountID);
  if (state.accounts.length === 0) state.accounts.push(newAccount(1));
  saveState();
  selectAccount(state.accounts.some((a) => a.id === state.lastAccountID)
    ? state.lastAccountID : state.accounts[0].id);
  updateBadge();
  buildMenu();
}

function sendBarState() {
  if (!mainWindow || mainWindow.webContents.isLoading()) return;
  mainWindow.webContents.send('state', {
    selectedID: state.lastAccountID,
    accounts: state.accounts.map((a, i) => ({
      id: a.id, label: label(a), unread: unread.get(a.id) || 0, shortcut: i < 9 ? `⌘${i + 1}` : '',
    })),
  });
}

// ---------------------------------------------------------------------------
// Unread counts, dock badge, notifications

/** Titles look like "Inbox (12) - name@gmail.com - Gmail". */
function titleChanged(accountID, title) {
  const account = state.accounts.find((a) => a.id === accountID);
  if (!account || !/Gmail|@/.test(title)) return;

  const email = title.split(' - ').find((part) => part.includes('@') && !part.includes(' '));
  if (email && !account.email && /^Account \d+$/.test(account.name)) {
    account.email = email;
    saveState();
    buildMenu();
    sendBarState();
  }

  const match = title.split(' - ')[0].match(/\(([\d.,\s]+)\)\s*$/);
  const count = match ? parseInt(match[1].replace(/\D/g, ''), 10) || 0 : 0;
  const previous = unread.get(accountID);
  if (previous === count) return;
  unread.set(accountID, count);
  updateBadge();
  sendBarState();

  // Fallback when Gmail's own desktop notifications are off. The first count only sets a baseline.
  if (previous !== undefined && count > previous) {
    const added = count - previous;
    setTimeout(() => {
      if (Date.now() - (lastPageNotification.get(accountID) || 0) < 20000) return;
      notify(added === 1 ? 'New message' : `${added} new messages`, label(account), accountID);
    }, 4000);
  }
}

function updateBadge() {
  const total = [...unread.values()].reduce((a, b) => a + b, 0);
  app.dock?.setBadge(total > 0 ? String(total) : '');
}

function notify(title, body, accountID) {
  if (!Notification.isSupported()) return;
  const n = new Notification({ title, body, silent: false });
  n.on('click', () => {
    mainWindow.show();
    app.focus({ steal: true });
    selectAccount(accountID);
  });
  n.show();
}

const notifyTimes = new Map();
ipcMain.on('gmail:notify', (event, payload) => {
  // Only Gmail's own page in one of our account views may raise notifications.
  if (!isGmailOrigin(event.senderFrame?.url || '') || event.senderFrame !== event.sender.mainFrame) return;
  const accountID = [...views].find(([, v]) => v.webContents === event.sender)?.[0]
    || accountForPopup(event.sender);
  if (!accountID) return;
  const now = Date.now();
  const recent = (notifyTimes.get(accountID) || []).filter((t) => now - t < 10000);
  if (recent.length >= 5) return; // rate limit
  notifyTimes.set(accountID, [...recent, now]);
  lastPageNotification.set(accountID, now);
  const title = String(payload?.title || 'Gmail').slice(0, 200);
  const body = String(payload?.body || '').slice(0, 500);
  notify(title, body, accountID);
});

function accountForPopup(wc) {
  const partition = wc.session && [...configuredSessions].find((id) => session.fromPartition(`persist:${id}`) === wc.session);
  return partition || null;
}

// ---------------------------------------------------------------------------
// Compose and mailto:

function composeURL(mailto) {
  const params = new URLSearchParams({ view: 'cm', fs: '1', tf: '1' });
  if (mailto) {
    try {
      const u = new URL(mailto);
      const to = [decodeURIComponent(u.pathname)].filter(Boolean);
      for (const [key, value] of u.searchParams) {
        if (!value) continue;
        switch (key.toLowerCase()) {
          case 'to': to.push(value); break;
          case 'cc': params.set('cc', value); break;
          case 'bcc': params.set('bcc', value); break;
          case 'subject': params.set('su', value); break;
          case 'body': params.set('body', value); break;
          default: break;
        }
      }
      if (to.length) params.set('to', to.join(','));
    } catch { /* ignore malformed mailto */ }
  }
  return `${INBOX}?${params}`;
}

function compose(mailto) {
  const accountID = state.lastAccountID;
  const url = composeURL(mailto);
  if (!state.composeInWindow) {
    selectedWebContents()?.loadURL(url);
    mainWindow.show();
    return;
  }
  const win = new BrowserWindow({
    width: 760, height: 640, title: 'New Message', webPreferences: gmailWebPreferences(accountID),
  });
  wire(win.webContents, accountID, 'compose');
  win.loadURL(url);
}

app.on('will-finish-launching', () => {
  app.on('open-url', (event, url) => {
    event.preventDefault();
    if (!url.toLowerCase().startsWith('mailto:')) return;
    if (app.isReady() && mainWindow) compose(url); else pendingMailto = url;
  });
});

// ---------------------------------------------------------------------------
// Menu

function buildMenu() {
  const prefs = [
    {
      label: 'Open New Message in Separate Window',
      type: 'checkbox',
      checked: state.composeInWindow,
      click: (item) => { state.composeInWindow = item.checked; saveState(); },
    },
    {
      label: 'Open Links in Google Chrome',
      type: 'checkbox',
      checked: state.openLinksInChrome,
      click: (item) => { state.openLinksInChrome = item.checked; saveState(); },
    },
    {
      label: 'Make Gmail Desktop the Default Email App',
      click: () => {
        const ok = app.setAsDefaultProtocolClient('mailto');
        dialog.showMessageBox(mainWindow, {
          message: ok ? 'mailto: links now open in Gmail Desktop.' : 'macOS did not allow the change.',
        });
      },
    },
  ];

  const accountItems = state.accounts.map((account, i) => ({
    label: label(account),
    type: 'radio',
    checked: account.id === state.lastAccountID,
    accelerator: i < 9 ? `CmdOrCtrl+${i + 1}` : undefined,
    click: () => selectAccount(account.id),
  }));

  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      role: 'appMenu',
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { label: 'Settings', submenu: prefs },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'File',
      submenu: [
        { label: 'New Message', accelerator: 'CmdOrCtrl+N', click: () => compose() },
        { label: 'Add Account', accelerator: 'CmdOrCtrl+Shift+N', click: addAccount },
        { type: 'separator' },
        { role: 'close' },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { label: 'Reload', accelerator: 'CmdOrCtrl+R', click: () => selectedWebContents()?.reload() },
        {
          label: 'Back',
          accelerator: 'CmdOrCtrl+[',
          click: () => selectedWebContents()?.navigationHistory.goBack(),
        },
        {
          label: 'Forward',
          accelerator: 'CmdOrCtrl+]',
          click: () => selectedWebContents()?.navigationHistory.goForward(),
        },
        { label: 'Go to Inbox', accelerator: 'CmdOrCtrl+Shift+I', click: () => selectedWebContents()?.loadURL(INBOX) },
        { type: 'separator' },
        { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Accounts',
      submenu: [
        { label: 'Next Account', accelerator: 'Ctrl+Tab', click: () => selectAdjacent(1) },
        { label: 'Previous Account', accelerator: 'Ctrl+Shift+Tab', click: () => selectAdjacent(-1) },
        { type: 'separator' },
        ...accountItems,
      ],
    },
    { role: 'windowMenu' },
  ]));
}

// ---------------------------------------------------------------------------
// Account bar IPC (only from our own bar page)

function fromBar(event) {
  return mainWindow && event.sender === mainWindow.webContents
    && event.senderFrame?.url.startsWith('file://');
}

ipcMain.on('bar:ready', (e) => { if (fromBar(e)) sendBarState(); });
ipcMain.on('bar:select', (e, id) => { if (fromBar(e)) selectAccount(id); });
ipcMain.on('bar:add', (e) => { if (fromBar(e)) addAccount(); });
ipcMain.on('bar:compose', (e) => { if (fromBar(e)) compose(); });
ipcMain.on('bar:rename', (e, id, name) => { if (fromBar(e)) renameAccount(id, name); });
ipcMain.on('bar:context', (e, id) => {
  if (!fromBar(e)) return;
  Menu.buildFromTemplate([
    { label: 'Rename…', click: () => mainWindow.webContents.send('start-rename', id) },
    { label: 'Reload', click: () => views.get(id)?.webContents.reload() },
    { type: 'separator' },
    { label: 'Remove Account…', click: () => removeAccount(id) },
  ]).popup({ window: mainWindow });
});

// ---------------------------------------------------------------------------
// App lifecycle

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { mainWindow?.show(); mainWindow?.focus(); });

  // Never let any page attach a <webview> or open devtools-like extra contents.
  app.on('web-contents-created', (_e, contents) => {
    contents.on('will-attach-webview', (event) => event.preventDefault());
  });

  app.whenReady().then(() => {
    state = loadState();
    if (!state.accounts.some((a) => a.id === state.lastAccountID)) state.lastAccountID = state.accounts[0].id;
    saveState();
    createMainWindow();
    buildMenu();
    // Load every account so badges and notifications work for all of them.
    for (const account of state.accounts) ensureView(account.id);
    selectAccount(state.lastAccountID);
    mainWindow.webContents.on('did-finish-load', sendBarState);
    if (pendingMailto) { compose(pendingMailto); pendingMailto = null; }
  });

  app.on('activate', () => mainWindow?.show());
  app.on('before-quit', () => { quitting = true; });
}
