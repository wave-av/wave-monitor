/**
 * Electron main process for wave-monitor.
 *
 * Single window. Sandboxed renderer. Tells the gateway to open a WebRTC
 * peer connection to a feed, ferries audio/video frames through a
 * preload-exposed surface, computes peak/RMS in an audio worklet (W2).
 */

import { app, BrowserWindow, Menu, shell } from 'electron';
import { electronApp, optimizer } from '@electron-toolkit/utils';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import {
  getMonitorState,
  registerControlPlaneKeyHandlers,
  registerIpcHandlers,
  startMonitoring,
  stopMonitoring,
} from './ipc';
import { initControlPlane, portFromEnv, type ControlPlaneHandle } from './control-plane/index';
import { registerUpdateIpc, startBackgroundChecks } from './updater/updater';

const isDev = !app.isPackaged;
const RENDERER_ENTRY_FILE = join(__dirname, '../renderer/index.html');
const RENDERER_ENTRY_URL = pathToFileURL(RENDERER_ENTRY_FILE).href;
// --smoke-test: gate-proof mode. After first paint, print one SMOKE_OK JSON
// line (control-plane port + document title + bridge checks), then quit.
// Nonzero exit on timeout or load failure. See scripts/smoke.sh and
// scripts/cold-boot.sh. Pattern from the Wave Desk / template shell.
const SMOKE = process.argv.includes('--smoke-test');

let controlPlane: ControlPlaneHandle | null = null;
// Set once the initial window exists; gates `activate` so a macOS launch
// can't open a second window while startup is still awaiting the plane.
let startupDone = false;

// Single instance: concurrent first launches would mint divergent
// control-plane keys (live listener ≠ persisted key), so the second
// instance quits before any init runs.
if (!app.requestSingleInstanceLock()) {
  app.quit();
}
app.on('second-instance', () => {
  const [win] = BrowserWindow.getAllWindows();
  if (win) {
    if (win.isMinimized()) win.restore();
    win.focus();
  }
});

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
    // Frameless (productization): no Apple traffic lights — window drag
    // comes from the header's .wave-drag region and window ops from the
    // menu + shortcuts (Cmd+W/M/Q). Same pattern as Wave Desk.
    frame: false,
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

  if (SMOKE) {
    const fail = (reason: string): void => {
      console.error(JSON.stringify({ event: 'SMOKE_FAIL', reason }));
      app.exit(1);
    };
    const timer = setTimeout(() => fail('timeout waiting for first paint'), 45_000);
    win.webContents.on('did-fail-load', (_e, code, desc) => fail(`did-fail-load ${code} ${desc}`));
    win.webContents.on('did-finish-load', () => {
      void (async () => {
        try {
          const title = (await win.webContents.executeJavaScript('document.title', true)) as string;
          const api = (await win.webContents.executeJavaScript(
            "({ hasWave: typeof window.wave !== 'undefined', nodeLeak: typeof window.require !== 'undefined' || typeof window.process !== 'undefined' })",
            true,
          )) as { hasWave: boolean; nodeLeak: boolean };
          // The control plane is the loopback proof: it must answer on the
          // bound port (scratch in gates, never live :7729) with the live key.
          let cpOk = false;
          if (controlPlane) {
            try {
              const res = await fetch(`http://127.0.0.1:${controlPlane.port}/v1/status`, {
                headers: { Authorization: `Bearer ${controlPlane.apiKey}` },
              });
              cpOk = res.ok;
            } catch {
              cpOk = false;
            }
          }
          clearTimeout(timer);
          console.log(
            JSON.stringify({
              event: 'SMOKE_OK',
              port: controlPlane?.port ?? -1,
              title,
              hasBridge: api.hasWave,
              nodeLeak: api.nodeLeak,
              controlPlane: cpOk,
            }),
          );
          app.exit(api.hasWave && !api.nodeLeak && cpOk ? 0 : 1);
        } catch (err) {
          fail(String((err as Error)?.message ?? err));
        }
      })();
    });
  }

  if (isDev && process.env['ELECTRON_RENDERER_URL']) {
    void win.loadURL(process.env['ELECTRON_RENDERER_URL']);
  } else {
    void win.loadFile(RENDERER_ENTRY_FILE);
  }
  return win;
}

function buildMenu(): void {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      { role: 'appMenu' },
      { role: 'editMenu' },
      {
        label: 'Window',
        submenu: [
          { role: 'minimize' },
          { role: 'zoom' },
          { role: 'close' },
          { type: 'separator' },
          { role: 'front' },
        ],
      },
    ]),
  );
}

void app.whenReady().then(() => {
  electronApp.setAppUserModelId('online.wave.monitor');
  app.on('browser-window-created', (_e, w) => optimizer.watchWindowShortcuts(w));
  registerIpcHandlers();
  registerUpdateIpc();
  buildMenu();
  void (async () => {
    try {
      controlPlane = await initControlPlane({
        version: app.getVersion(),
        name: 'WAVE Monitor',
        getMonitor: getMonitorState,
        actions: { start: startMonitoring, stop: stopMonitoring },
        port: portFromEnv(),
      });
    } catch (err) {
      // A control-plane bind failure must not take down the window: the
      // monitor is usable standalone, and SMOKE mode fails via cpOk=false.
      console.error('[control-plane] failed to start', err);
      controlPlane = null;
    }
    // Key reveal/rotate for the settings panel (explicit operator gesture;
    // resolves null when the plane failed to bind).
    registerControlPlaneKeyHandlers({
      getApiKey: () => controlPlane?.apiKey ?? null,
      rotateApiKey: async () => (controlPlane ? controlPlane.rotate() : null),
    });
    if (!SMOKE) startBackgroundChecks();
    createWindow();
    startupDone = true;
  })();

  app.on('activate', () => {
    if (startupDone && BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', () => {
  if (controlPlane) void controlPlane.stop();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
