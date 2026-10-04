'use strict';

// The account bar's only bridge to the app: a fixed set of commands, no Node access.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bar', {
  ready: () => ipcRenderer.send('bar:ready'),
  select: (id) => ipcRenderer.send('bar:select', String(id)),
  add: () => ipcRenderer.send('bar:add'),
  compose: () => ipcRenderer.send('bar:compose'),
  rename: (id, name) => ipcRenderer.send('bar:rename', String(id), String(name)),
  context: (id) => ipcRenderer.send('bar:context', String(id)),
  onState: (callback) => ipcRenderer.on('state', (_e, state) => callback(state)),
  onStartRename: (callback) => ipcRenderer.on('start-rename', (_e, id) => callback(id)),
});
