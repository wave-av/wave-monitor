/**
 * Route definitions for the wave-monitor control-plane HTTP API. Handlers are
 * pure functions of `(stateGetter, actions, body) → response` to keep them
 * trivially testable; the router wires them to live IncomingMessage /
 * ServerResponse.
 *
 * Pattern ported from wave-desktop's control-plane routes; the monitor
 * surface is status + start/stop + version (no OAuth, no cloud auth).
 */

import type { Route } from './router';
import { StartRequestSchema, type MonitorState } from '@shared/ipc';
import type { StatusResponse, VersionResponse } from './types';

export interface ControlPlaneState {
  /** wave-monitor semver. */
  version: string;
  /** Product name for the version endpoint. */
  name: string;
  /** Instant the server bound the socket. */
  bootAt: Date;
  /** Current monitor snapshot — called on every status request. */
  getMonitor: () => MonitorState;
}

export interface MonitorActions {
  /** Bind a feed URL (same validation as the IPC start channel). */
  start(feedUrl: string): MonitorState;
  /** Unbind the active feed. */
  stop(): MonitorState;
}

export function buildRoutes(getState: () => ControlPlaneState, actions: MonitorActions): Route[] {
  return [
    {
      method: 'GET',
      path: '/v1/status',
      handler: (): StatusResponse => {
        const s = getState();
        const m = s.getMonitor();
        const uptimeSec = Math.max(0, Math.floor((Date.now() - s.bootAt.getTime()) / 1000));
        return {
          ok: true,
          version: s.version,
          bootAt: s.bootAt.toISOString(),
          uptimeSec,
          connected: m.connected,
          feedUrl: m.feedUrl,
        };
      },
    },
    {
      method: 'GET',
      path: '/v1/version',
      handler: (): VersionResponse => {
        const s = getState();
        return { name: s.name, version: s.version };
      },
    },
    {
      method: 'POST',
      path: '/v1/monitor/start',
      bodySchema: StartRequestSchema,
      handler: (_req, _res, ctx): MonitorState => {
        const body = StartRequestSchema.parse(ctx.body);
        return actions.start(body.feedUrl);
      },
    },
    {
      method: 'POST',
      path: '/v1/monitor/stop',
      handler: (): MonitorState => actions.stop(),
    },
  ];
}
