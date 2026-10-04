'use strict';

const tabs = document.getElementById('tabs');
let current = { accounts: [], selectedID: null };
let renamingID = null;

function render() {
  tabs.replaceChildren();
  for (const account of current.accounts) {
    const tab = document.createElement('div');
    tab.className = 'tab' + (account.id === current.selectedID ? ' selected' : '');
    tab.title = account.shortcut ? `${account.label} (${account.shortcut})` : account.label;

    if (account.id === renamingID) {
      const input = document.createElement('input');
      input.value = account.label;
      const finish = (commit) => {
        if (renamingID !== account.id) return;
        renamingID = null;
        if (commit) window.bar.rename(account.id, input.value);
        render();
      };
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') finish(true);
        if (e.key === 'Escape') finish(false);
      });
      input.addEventListener('blur', () => finish(true));
      tab.append(input);
      setTimeout(() => { input.focus(); input.select(); });
    } else {
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = account.label; // textContent: never parsed as HTML
      tab.append(name);
      if (account.unread > 0) {
        const count = document.createElement('span');
        count.className = 'count';
        count.textContent = String(account.unread);
        tab.append(count);
      }
      tab.addEventListener('click', () => window.bar.select(account.id));
      tab.addEventListener('dblclick', () => { renamingID = account.id; render(); });
      tab.addEventListener('contextmenu', (e) => { e.preventDefault(); window.bar.context(account.id); });
    }
    tabs.append(tab);
  }
  tabs.querySelector('.selected')?.scrollIntoView({ inline: 'nearest' });
}

window.bar.onState((state) => { current = state; render(); });
window.bar.onStartRename((id) => { renamingID = id; render(); });
document.getElementById('add').addEventListener('click', () => window.bar.add());
document.getElementById('compose').addEventListener('click', () => window.bar.compose());
window.bar.ready();
