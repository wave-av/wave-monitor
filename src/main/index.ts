/**
 * Electron main process for wave-monitor.
 *
 * Single window. Sandboxed renderer. Tells the gateway to open a WebRTC
 * peer connection to a feed, ferries audio/video frames through a
 * preload-exposed surface, computes peak/RMS in an audio worklet (W2).
 */

import { app, BrowserWindow, shell } from 'electron';
import { electronApp, optimizer } from '@electron-toolkit/utils';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { registerIpcHandlers } from './ipc';

const isDev = !app.isPackaged;
const RENDERER_ENTRY_FILE = join(__dirname, '../renderer/index.html');
const RENDERER_ENTRY_URL = pathToFileURL(RENDERER_ENTRY_FILE).href;

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 960,
    height: 640,
    minWidth: 640,
    minHeight: 420,
    title: 'WAVE Monitor',
    backgroundColor: '#0a0a0b',
    show: false,
    autoHideMenuBar: true,
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });

  win.on('ready-to-show', () => win.show());

  /*
   * Navigation hardening — three handlers cover the three escape routes:
   *
   *   1. setWindowOpenHandler  → window.open() / target="_blank" / form target=_blank
   *   2. will-navigate         → top-level <a> click + JS location.href assignments
   *   3. will-redirect         → HTTP 3xx pointing somewhere unexpected
   *
   * In all three cases the policy is identical: if it's an http(s) URL going
   * somewhere other than the dev renderer + the bundled index.html, hand it to
   * the OS browser via shell.openExternal and prevent the in-window navigation.
   * Anything else (`javascript:`, `file:`, app-protocols, malformed) is dropped.
   *
   * cubic-dev-ai PR #1 review caught that the previous handler only covered
   * window.open. Same-window navigation must be locked down too.
   */
  const allowedInternalOrigins = new Set<string>();
  if (isDev && process.env['ELECTRON_RENDERER_URL']) {
    try {
      allowedInternalOrigins.add(new URL(process.env['ELECTRON_RENDERER_URL']).origin);
    } catch {
      /* misconfigured dev URL — ignore */
    }
  }
  /*
   * `file:` URLs have no origin; allowlist exactly the bundled renderer entry.
   *
   * cubic-dev-ai PR #1 follow-up review caught that the previous `protocol === 'file:'`
   * check was too broad — a renderer XSS could navigate to any local file URL. Restrict
   * to the exact packaged entry; anything else under `file:` is treated as external.
   */
  const isAllowedInternal = (url: string): boolean => {
    try {
      const parsed = new URL(url);
      if (parsed.protocol === 'file:') return url === RENDERER_ENTRY_URL;
      return allowedInternalOrigins.has(parsed.origin);
    } catch {
      return false;
    }
  };

  const handleExternal = (url: string): void => {
    try {
      const parsed = new URL(url);
      if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
        void shell.openExternal(url);
      }
    } catch {
      /* unparseable URL — drop */
    }
  };

  win.webContents.setWindowOpenHandler(({ url }) => {
    handleExternal(url);
    return { action: 'deny' };
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (!isAllowedInternal(url)) {
      event.preventDefault();
      handleExternal(url);
    }
  });

  win.webContents.on('will-redirect', (event, url) => {
    if (!isAllowedInternal(url)) {
      event.preventDefault();
      handleExternal(url);
    }
  });

  if (isDev && process.env['ELECTRON_RENDERER_URL']) {
    void win.loadURL(process.env['ELECTRON_RENDERER_URL']);
  } else {
    void win.loadFile(RENDERER_ENTRY_FILE);
  }
  return win;
}

void app.whenReady().then(() => {
  electronApp.setAppUserModelId('online.wave.monitor');
  app.on('browser-window-created', (_e, w) => optimizer.watchWindowShortcuts(w));
  registerIpcHandlers();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
