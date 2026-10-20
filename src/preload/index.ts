/**
 * Preload bridge for wave-monitor. Single-purpose: monitor a feed.
 */

import { contextBridge, ipcRenderer } from 'electron';
import { IPC } from '@shared/channels';
import type { MonitorState, StartRequest, UpdateSnapshot } from '@shared/ipc';

const wave = {
  monitor: {
    state: (): Promise<MonitorState> => ipcRenderer.invoke(IPC.monitorState),
    start: (req: StartRequest): Promise<MonitorState> =>
      ipcRenderer.invoke(IPC.monitorStart, req),
    stop: (): Promise<MonitorState> => ipcRenderer.invoke(IPC.monitorStop),
    mediaLive: (): Promise<MonitorState> => ipcRenderer.invoke(IPC.monitorMediaLive),
  },
  controlPlane: {
    revealKey: (): Promise<string | null> => ipcRenderer.invoke(IPC.revealApiKey),
    rotateKey: (): Promise<string | null> => ipcRenderer.invoke(IPC.rotateApiKey),
  },
  updates: {
    status: (): Promise<UpdateSnapshot> => ipcRenderer.invoke(IPC.updateStatus),
    check: (): Promise<UpdateSnapshot> => ipcRenderer.invoke(IPC.checkForUpdates),
    install: (): Promise<void> => ipcRenderer.invoke(IPC.installUpdate),
  },
} as const;

contextBridge.exposeInMainWorld('wave', wave);

export type WaveBridge = typeof wave;

declare global {
  interface Window {
    wave: WaveBridge;
  }
}
