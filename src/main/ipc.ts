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
  // Wave 2: open RTCPeerConnection against gateway, attach audio track
  // to an AudioWorkletProcessor that emits peak/RMS at 20Hz.
  state = { ...state, feedUrl, connected: true };
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
}
