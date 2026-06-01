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

export function registerIpcHandlers(): void {
  ipcMain.handle(IPC.monitorState, (): MonitorState => state);

  ipcMain.handle(IPC.monitorStart, (_e: IpcMainInvokeEvent, raw: unknown): MonitorState => {
    const req = StartRequestSchema.parse(raw);
    // Wave 2: open RTCPeerConnection against gateway, attach audio track
    // to an AudioWorkletProcessor that emits peak/RMS at 20Hz.
    state = { ...state, feedUrl: req.feedUrl, connected: true };
    return state;
  });

  ipcMain.handle(IPC.monitorStop, (): MonitorState => {
    state = { feedUrl: null, connected: false, peakL: -Infinity, peakR: -Infinity, rmsL: -Infinity, rmsR: -Infinity };
    return state;
  });
}
