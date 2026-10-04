'use strict';

// Runs in Gmail's pages. It exposes exactly one function and does not read the page,
// forms or cookies: it only forwards Gmail's own desktop notifications (title and body)
// so they appear as macOS notifications that select the right account when clicked.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('__gmailDesktop', {
  notify: (title, body) => ipcRenderer.send('gmail:notify', { title: String(title), body: String(body) }),
});

contextBridge.executeInMainWorld({
  func: () => {
    if (location.hostname !== 'mail.google.com') return;
    const bridge = window.__gmailDesktop;
    class GDNotification extends EventTarget {
      constructor(title, options = {}) {
        super();
        this.title = String(title || '');
        this.body = String(options.body || '');
        this.tag = String(options.tag || '');
        this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
        bridge.notify(this.title, this.body);
      }
      close() {}
      static get permission() { return 'granted'; }
      static requestPermission(callback) {
        if (callback) callback('granted');
        return Promise.resolve('granted');
      }
    }
    window.Notification = GDNotification;
  },
});
