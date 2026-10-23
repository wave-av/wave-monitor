/**
 * updater — auto-update wiring for wave-monitor.
 *
 * TypeScript port of the create-wave-app electron template's updater.js.  # guard:allow electron template attribution
 *
 * Feed: generic provider at FEED_URL (package.json `publish` config is
 * baked into app-update.yml at dist time). electron-updater checks; nothing
 * downloads until rollout-guard.ts admits this machine to the cohort.
 * Downloads never auto-install: state flips to `ready` and the page (via
 * the preload bridge) tells the user to restart.
 */

import { app, ipcMain } from 'electron';
import { autoUpdater } from 'electron-updater';
import { IPC, type UpdateSnapshot } from '@shared/ipc';
import { defaultMachineId, rolloutAllows } from './rollout-guard';

export const FEED_URL = 'https://updates.wave.online/wave-monitor';

let status: UpdateSnapshot = { state: 'idle', version: null, error: null, feed: FEED_URL };

export function snapshot(): UpdateSnapshot {
  return { ...status };
}

function setStatus(next: Omit<UpdateSnapshot, 'feed'>): UpdateSnapshot {
  status = { ...next, feed: FEED_URL };
  return snapshot();
}

export async function check(): Promise<UpdateSnapshot> {
  const installed = app.getVersion();
  setStatus({ state: 'checking', version: installed, error: null });
  try {
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = false;
    const res = await autoUpdater.checkForUpdates();
    // electron-updater returns a non-null updateInfo even when nothing is
    // newer, so "up-to-date" needs both the flag AND a version comparison.
    const available = res?.updateInfo ? String(res.updateInfo.version) : '';
    const offersNewer = available !== '' && available !== installed && res?.isUpdateAvailable !== false;
    if (!offersNewer) {
      return setStatus({ state: 'up-to-date', version: installed, error: null });
    }
    const gate = await rolloutAllows({ feedUrl: FEED_URL, version: available, machineId: defaultMachineId() });
    if (!gate.allowed) {
      return setStatus({ state: 'deferred', version: available, error: gate.reason });
    }
    setStatus({ state: 'available', version: available, error: null });
    // Gate admission is the download trigger (autoDownload stays false so
    // nothing downloads pre-gate). Completion flips state to `ready` via
    // the update-downloaded listener in startBackgroundChecks().
    void autoUpdater.downloadUpdate().then(
      () => undefined,
      (err: unknown) => {
        setStatus({
          state: 'error',
          version: available,
          error: String((err as Error)?.message ?? err),
        });
      },
    );
    return snapshot();
  } catch (err) {
    return setStatus({
      state: 'error',
      version: installed,
      error: String((err as Error)?.message ?? err),
    });
  }
}

/**
 * User-confirmed install: quit and install the downloaded update. Only
 * meaningful in `ready` state; electron-updater no-ops otherwise.
 */
export function installAndRestart(): void {
  autoUpdater.quitAndInstall();
}

export function registerUpdateIpc(): void {
  ipcMain.handle(IPC.updateStatus, () => snapshot());
  ipcMain.handle(IPC.checkForUpdates, async () => check());
  ipcMain.handle(IPC.installUpdate, () => {
    installAndRestart();
  });
}

export function startBackgroundChecks(): void {
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = false;
  autoUpdater.on('update-downloaded', (info) => {
    setStatus({ state: 'ready', version: String(info?.version ?? status.version), error: null });
  });
  autoUpdater.on('error', (err) => {
    if (status.state === 'checking') {
      setStatus({ state: 'error', version: app.getVersion(), error: String((err as Error)?.message ?? err) });
    }
  });
  setTimeout(() => {
    void check().catch(() => {});
  }, 30_000);
}
