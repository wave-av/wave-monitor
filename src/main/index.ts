/**
 * Electron main process for wave-monitor.
 *
 * Single window. Sandboxed renderer. Tells the gateway to open a WebRTC
 * peer connection to a feed, ferries audio/video frames through a
 * preload-exposed surface, computes peak/RMS in an audio worklet (W2).
 */

import { app, BrowserWindow, shell } from 'electron';
import { electronApp, optimizer } from '@electron-toolkit/utils';
import { join } from 'node:path';
import { registerIpcHandlers } from './ipc';

const isDev = !app.isPackaged;

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

  // External links open in the OS browser, never in-app. Validate scheme so
  // a compromised renderer can't pop `javascript:` / `file:` / app-protocol
  // URLs through openExternal.
  win.webContents.setWindowOpenHandler(({ url }) => {
    try {
      const parsed = new URL(url);
      if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
        void shell.openExternal(url);
      }
    } catch {
      // unparseable URL — drop
    }
    return { action: 'deny' };
  });

  if (isDev && process.env['ELECTRON_RENDERER_URL']) {
    void win.loadURL(process.env['ELECTRON_RENDERER_URL']);
  } else {
    void win.loadFile(join(__dirname, '../renderer/index.html'));
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
