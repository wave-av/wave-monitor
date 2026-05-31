/// <reference types="vite/client" />

import type { MonitorState, StartRequest } from '@shared/ipc';

interface WaveBridge {
  monitor: {
    state(): Promise<MonitorState>;
    start(req: StartRequest): Promise<MonitorState>;
    stop(): Promise<MonitorState>;
  };
}

declare global {
  interface Window {
    wave: WaveBridge;
  }
}
