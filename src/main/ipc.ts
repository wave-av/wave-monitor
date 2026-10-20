/**
 * Main-side IPC handlers for wave-monitor. Today the meter values are
 * stubbed at silence (-Infinity / 0); Wave 2 wires the WebRTC peer
 * connection + an audio worklet that computes peak/RMS per 50ms window
 * and ferries them back via webContents.send.
 */

import { ipcMain, type IpcMainInvokeEvent } from 'electron';
import {
  IPC,
  type MonitorState,
  StartRequestSchema,
} from '@shared/ipc';

let state: MonitorState = {
  feedUrl: null,
  connected: false,
  peakL: -Infinity,
  peakR: -Infinity,
  rmsL: -Infinity,
  rmsR: -Infinity,
};

/**
 * Snapshot accessor shared by the IPC layer and the loopback control plane
 * — both read and write the same module state, so the HTTP API and the
 * renderer can never disagree about what is bound.
 */
export function getMonitorState(): MonitorState {
  return state;
}

export function startMonitoring(feedUrl: string): MonitorState {
  // Bind the URL but stay unconnected: `connected` flips only when the
  // renderer reports the media lifecycle live (see markMediaLive). Wave 2
  // moves the RTCPeerConnection here; until then main never claims media
  // it hasn't seen.
  state = { ...state, feedUrl, connected: false };
  return state;
}

/**
 * Flip `connected` once the renderer has a live peer + meter. No-op when
 * nothing is bound — a stray live signal must not invent a feed.
 */
export function markMediaLive(): MonitorState {
  if (state.feedUrl === null) return state;
  state = { ...state, connected: true };
  return state;
}

export function stopMonitoring(): MonitorState {
  state = { feedUrl: null, connected: false, peakL: -Infinity, peakR: -Infinity, rmsL: -Infinity, rmsR: -Infinity };
  return state;
}

export function registerIpcHandlers(): void {
  ipcMain.handle(IPC.monitorState, (): MonitorState => getMonitorState());

  ipcMain.handle(IPC.monitorStart, (_e: IpcMainInvokeEvent, raw: unknown): MonitorState => {
    const req = StartRequestSchema.parse(raw);
    return startMonitoring(req.feedUrl);
  });

  ipcMain.handle(IPC.monitorStop, (): MonitorState => stopMonitoring());

  ipcMain.handle(IPC.monitorMediaLive, (): MonitorState => markMediaLive());
}

/**
 * Control-plane key handlers, registered after initControlPlane resolves
 * (the plane may fail to bind; then both calls resolve null instead of
 * throwing "no handler"). The renderer exposes these only behind explicit
 * settings-panel buttons — reveal-then-copy for Companion config, rotate
 * on operator demand — so the key never crosses IPC unasked.
 */
export function registerControlPlaneKeyHandlers(deps: {
  getApiKey: () => string | null;
  rotateApiKey: () => Promise<string | null>;
}): void {
  ipcMain.handle(IPC.revealApiKey, () => deps.getApiKey());
  ipcMain.handle(IPC.rotateApiKey, () => deps.rotateApiKey());
}
