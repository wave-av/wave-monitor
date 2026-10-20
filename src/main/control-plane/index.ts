/**
 * Control-plane orchestration entrypoint for wave-monitor.
 *
 * Glue between the lifecycle (api-key + server + routes) and the Electron
 * main process:
 *
 *   const cp = await initControlPlane({ getMonitor, actions });
 *   …
 *   await cp.stop();
 *
 * Orchestration pattern ported from wave-desktop's control-plane/index.ts
 * (serialized rotate(), persist-only-after-bind). The monitor plane has no
 * renderer bridge — start/stop act directly on the main-process monitor
 * state that the IPC layer also owns.
 */

import { generate, loadOrCreate, persist } from './api-key';
import { buildRoutes, type ControlPlaneState, type MonitorActions } from './routes';
import { start, type ServerHandle } from './server';
import type { MonitorState } from '@shared/ipc';

export interface InitOptions {
  /** App version string (from app.getVersion()). */
  version: string;
  /** Product name (from app.getName()). */
  name: string;
  /** Snapshot accessor — called on every status request, must be cheap. */
  getMonitor: () => MonitorState;
  /** Monitor actions shared with the IPC layer. */
  actions: MonitorActions;
  /** TCP port on 127.0.0.1; defaults to 7729. Pass 0 for ephemeral (tests). */
  port?: number;
}

export interface ControlPlaneHandle {
  /** Bound port (ephemeral when 0 was requested). */
  readonly port: number;
  /** Plaintext API key — never crosses IPC except via an explicit reveal. */
  readonly apiKey: string;
  /** Rotate the persisted key and return the new plaintext. */
  rotate(): Promise<string>;
  /** Stop the HTTP server; resolves when the listener has closed. */
  stop(): Promise<void>;
}

export const DEFAULT_PORT = 7729;

export function portFromEnv(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env['WAVE_MONITOR_PORT'];
  if (raw === undefined || raw === '') return DEFAULT_PORT;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 65535) {
    throw new Error(`WAVE_MONITOR_PORT must be an integer 0-65535 (got ${JSON.stringify(raw)})`);
  }
  return n;
}

export async function initControlPlane(opts: InitOptions): Promise<ControlPlaneHandle> {
  let currentKey = await loadOrCreate();
  const bootAt = new Date();

  const getState = (): ControlPlaneState => ({
    version: opts.version,
    name: opts.name,
    bootAt,
    getMonitor: opts.getMonitor,
  });

  const startServer = (key: string): Promise<ServerHandle> =>
    start({
      apiKey: key,
      port: opts.port ?? DEFAULT_PORT,
      routes: buildRoutes(getState, opts.actions),
    });

  let server = await startServer(currentKey);

  // Single-slot mutex for rotate(). Concurrent callers attach to the same
  // promise rather than racing the stop/start.
  let rotateInflight: Promise<string> | null = null;

  async function performRotate(): Promise<string> {
    // Generate in memory only — persist AFTER the new server binds, so the
    // on-disk key stays in sync with the live listener if start throws.
    const candidate = generate();

    await server.stop();

    try {
      server = await startServer(candidate);
    } catch (startErr) {
      // New server failed to bind — come back online with the OLD key so
      // the operator keeps a working plane. If that also fails, surface
      // the original error; the on-disk key is unchanged.
      try {
        server = await startServer(currentKey);
      } catch (rollbackErr) {
        console.error(
          '[control-plane] rotate restart failed AND old-key recovery failed',
          { startErr, rollbackErr },
        );
        throw startErr;
      }
      throw startErr;
    }

    try {
      await persist(candidate);
    } catch (persistErr) {
      // Persist failed AFTER the candidate bound: roll back to the old key
      // so the live listener matches the reported key (else every client
      // 401s). Mirrors the bind-failure rollback above.
      try {
        await server.stop();
        server = await startServer(currentKey);
      } catch (rollbackErr) {
        console.error(
          '[control-plane] rotate persist failed AND old-key recovery failed',
          { persistErr, rollbackErr },
        );
      }
      throw persistErr;
    }
    currentKey = candidate;
    return candidate;
  }

  return {
    get port(): number {
      return server.port;
    },
    get apiKey(): string {
      return currentKey;
    },
    async rotate(): Promise<string> {
      if (rotateInflight) return rotateInflight;
      rotateInflight = performRotate().finally(() => {
        rotateInflight = null;
      });
      return rotateInflight;
    },
    async stop(): Promise<void> {
      await server.stop();
    },
  };
}
