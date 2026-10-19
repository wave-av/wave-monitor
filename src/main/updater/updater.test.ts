/**
 * Unit tests for the auto-update state machine. electron + electron-updater
 * + the rollout gate are mocked — the gate's own logic is covered by
 * rollout-guard.test.ts against a loopback stub.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';

const { handles, listeners, mockCheckForUpdates, mockRolloutAllows } = vi.hoisted(() => ({
  handles: {} as Record<string, () => unknown>,
  listeners: {} as Record<string, (arg: unknown) => void>,
  mockCheckForUpdates: vi.fn(),
  mockRolloutAllows: vi.fn(),
}));

vi.mock('electron', () => ({
  app: { getVersion: () => '0.1.0' },
  ipcMain: { handle: vi.fn((channel: string, fn: () => unknown) => { handles[channel] = fn; }) },
}));

vi.mock('electron-updater', () => ({
  autoUpdater: {
    autoDownload: true,
    autoInstallOnAppQuit: true,
    checkForUpdates: mockCheckForUpdates,
    on: vi.fn((event: string, fn: (arg: unknown) => void) => { listeners[event] = fn; }),
  },
}));

vi.mock('./rollout-guard', () => ({
  defaultMachineId: () => 'machine-1',
  rolloutAllows: mockRolloutAllows,
}));

import { check, registerUpdateIpc, snapshot, startBackgroundChecks, FEED_URL } from './updater';
import { IPC } from '@shared/ipc';

beforeEach(() => {
  vi.clearAllMocks();
  for (const k of Object.keys(handles)) delete handles[k];
  for (const k of Object.keys(listeners)) delete listeners[k];
});

describe('updater', () => {
  it('points at the wave-monitor feed', () => {
    expect(FEED_URL).toBe('https://updates.wave.online/wave-monitor');
  });

  it('starts idle', () => {
    expect(snapshot()).toMatchObject({ state: 'idle', feed: FEED_URL });
  });

  it('registers the update IPC channels', () => {
    registerUpdateIpc();
    expect(Object.keys(handles).sort()).toEqual(
      [IPC.updateStatus, IPC.checkForUpdates].sort(),
    );
  });

  it('reports up-to-date when the feed has nothing newer', async () => {
    mockCheckForUpdates.mockResolvedValueOnce({ updateInfo: null });
    const s = await check();
    expect(s).toMatchObject({ state: 'up-to-date', version: '0.1.0', error: null });
    expect(mockRolloutAllows).not.toHaveBeenCalled();
  });

  it('reports available when the rollout gate admits this machine', async () => {
    mockCheckForUpdates.mockResolvedValueOnce({ updateInfo: { version: '0.2.0' } });
    mockRolloutAllows.mockResolvedValueOnce({ allowed: true, reason: 'in-rollout-cohort' });
    const s = await check();
    expect(s).toMatchObject({ state: 'available', version: '0.2.0', error: null });
    expect(mockRolloutAllows).toHaveBeenCalledWith(
      expect.objectContaining({ feedUrl: FEED_URL, version: '0.2.0' }),
    );
  });

  it('reports deferred (with reason) when the gate holds this machine back', async () => {
    mockCheckForUpdates.mockResolvedValueOnce({ updateInfo: { version: '0.2.0' } });
    mockRolloutAllows.mockResolvedValueOnce({ allowed: false, reason: 'deferred-by-rollout' });
    const s = await check();
    expect(s).toMatchObject({ state: 'deferred', version: '0.2.0', error: 'deferred-by-rollout' });
  });

  it('reports error when the feed check throws (never throws itself)', async () => {
    mockCheckForUpdates.mockRejectedValueOnce(new Error('socket hangup'));
    const s = await check();
    expect(s.state).toBe('error');
    expect(s.error).toMatch(/socket hangup/);
  });

  it('flips to ready on update-downloaded; never auto-downloads/installs', async () => {
    const { autoUpdater } = await import('electron-updater');
    startBackgroundChecks();
    expect(autoUpdater.autoDownload).toBe(false);
    expect(autoUpdater.autoInstallOnAppQuit).toBe(false);
    listeners['update-downloaded']!({ version: '0.2.0' });
    expect(snapshot()).toMatchObject({ state: 'ready', version: '0.2.0' });
  });
});
