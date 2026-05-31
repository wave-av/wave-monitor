/**
 * Preload bridge for wave-monitor. Single-purpose: monitor a feed.
 */

import { contextBridge, ipcRenderer } from 'electron';
import {
  IPC,
  type MonitorState,
  type StartRequest,
} from '@shared/ipc';

const wave = {
  monitor: {
    state: (): Promise<MonitorState> => ipcRenderer.invoke(IPC.monitorState),
    start: (req: StartRequest): Promise<MonitorState> =>
      ipcRenderer.invoke(IPC.monitorStart, req),
    stop: (): Promise<MonitorState> => ipcRenderer.invoke(IPC.monitorStop),
  },
} as const;

contextBridge.exposeInMainWorld('wave', wave);

export type WaveBridge = typeof wave;

declare global {
  interface Window {
    wave: WaveBridge;
  }
}
