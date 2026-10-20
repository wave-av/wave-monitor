/// <reference types="vite/client" />

import type { MonitorState, StartRequest, UpdateSnapshot } from '@shared/ipc';

interface WaveBridge {
  monitor: {
    state(): Promise<MonitorState>;
    start(req: StartRequest): Promise<MonitorState>;
    stop(): Promise<MonitorState>;
    mediaLive(): Promise<MonitorState>;
  };
  controlPlane: {
    revealKey(): Promise<string | null>;
    rotateKey(): Promise<string | null>;
  };
  updates: {
    status(): Promise<UpdateSnapshot>;
    check(): Promise<UpdateSnapshot>;
    install(): Promise<void>;
  };
}

declare global {
  interface Window {
    wave: WaveBridge;
  }
}
