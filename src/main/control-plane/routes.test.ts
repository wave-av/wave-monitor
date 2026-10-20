/**
 * Pure handler tests for buildRoutes(). Handlers are functions of
 * (stateGetter, actions, body) — no sockets — so these run sub-ms.
 */

import { describe, it, expect } from 'vitest';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { buildRoutes, type ControlPlaneState, type MonitorActions } from './routes';
import type { MonitorState } from '@shared/ipc';

const SILENCE: MonitorState = {
  feedUrl: null,
  connected: false,
  peakL: -100,
  peakR: -100,
  rmsL: -100,
  rmsR: -100,
};

function harness(monitor: MonitorState = SILENCE) {
  let current = monitor;
  const state: ControlPlaneState = {
    version: '0.1.0',
    name: 'WAVE Monitor',
    bootAt: new Date('2026-10-19T00:00:00.000Z'),
    getMonitor: () => current,
  };
  const actions: MonitorActions = {
    start: (feedUrl: string) => {
      current = { ...current, feedUrl, connected: true };
      return current;
    },
    stop: () => {
      current = { ...SILENCE };
      return current;
    },
  };
  const routes = buildRoutes(() => state, actions);
  const by = (method: string, path: string) => routes.find((r) => r.method === method && r.path === path)!;
  return { by, getCurrent: () => current };
}

const dummyReq = {} as IncomingMessage;
const dummyRes = {} as ServerResponse;

describe('buildRoutes', () => {
  it('GET /v1/status reports version + monitor snapshot', async () => {
    const { by } = harness({ ...SILENCE, feedUrl: 'https://x/live', connected: true });
    const out = (await by('GET', '/v1/status').handler(dummyReq, dummyRes, {})) as Record<string, unknown>;
    expect(out).toMatchObject({
      ok: true,
      version: '0.1.0',
      bootAt: '2026-10-19T00:00:00.000Z',
      connected: true,
      feedUrl: 'https://x/live',
    });
    expect(out['uptimeSec']).toEqual(expect.any(Number));
  });

  it('GET /v1/version reports the product identity', async () => {
    const { by } = harness();
    const out = await by('GET', '/v1/version').handler(dummyReq, dummyRes, {});
    expect(out).toEqual({ name: 'WAVE Monitor', version: '0.1.0' });
  });

  it('POST /v1/monitor/start validates + binds through actions', async () => {
    const { by, getCurrent } = harness();
    const out = (await by('POST', '/v1/monitor/start').handler(dummyReq, dummyRes, {
      body: { feedUrl: 'https://relay.example/live' },
    })) as MonitorState;
    expect(out.connected).toBe(true);
    expect(getCurrent().feedUrl).toBe('https://relay.example/live');
  });

  it('POST /v1/monitor/start rejects a bad URL (throws → router 400/500, state untouched)', () => {
    const { by, getCurrent } = harness();
    expect(() =>
      by('POST', '/v1/monitor/start').handler(dummyReq, dummyRes, { body: { feedUrl: 'nope' } }),
    ).toThrow();
    expect(getCurrent().connected).toBe(false);
  });

  it('POST /v1/monitor/stop unbinds', async () => {
    const { by, getCurrent } = harness({ ...SILENCE, feedUrl: 'https://x', connected: true });
    const out = (await by('POST', '/v1/monitor/stop').handler(dummyReq, dummyRes, {})) as MonitorState;
    expect(out).toMatchObject({ connected: false, feedUrl: null });
    expect(getCurrent().connected).toBe(false);
  });
});
