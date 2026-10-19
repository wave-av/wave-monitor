/**
 * Orchestration tests for initControlPlane(). Exercise the lifecycle
 * end-to-end except api-key persistence (Electron safeStorage is mocked —
 * we don't boot Electron in unit tests).
 *
 * Mirrors wave-desktop's index.test.ts, adapted to the monitor surface
 * (start/stop act on main-process state; no renderer bridge).
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// Mock api-key before importing — initControlPlane immediately calls
// loadOrCreate(), so the mock must be installed first.
let mockKey = 'a'.repeat(64);
let regenerateCount = 0;
let persistedKey: string | null = null;
vi.mock('./api-key', () => ({
  loadOrCreate: vi.fn(async () => mockKey),
  generate: vi.fn(() => {
    regenerateCount += 1;
    return String.fromCharCode(98 + regenerateCount).repeat(64); // 'bbb…', 'ccc…', …
  }),
  persist: vi.fn(async (key: string) => {
    persistedKey = key;
    mockKey = key;
  }),
  regenerate: vi.fn(async () => {
    regenerateCount += 1;
    mockKey = String.fromCharCode(98 + regenerateCount).repeat(64);
    persistedKey = mockKey;
    return mockKey;
  }),
  safeEqual: (a: string, b: string) => a === b,
}));

import { initControlPlane, portFromEnv, type ControlPlaneHandle } from './index';
import type { MonitorState } from '@shared/ipc';

const SILENCE: MonitorState = {
  feedUrl: null,
  connected: false,
  peakL: -Infinity,
  peakR: -Infinity,
  rmsL: -Infinity,
  rmsR: -Infinity,
};

async function fetchStatus(port: number, key: string): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/v1/status`, {
    headers: { Authorization: `Bearer ${key}` },
  });
}

describe('initControlPlane', () => {
  let cp: ControlPlaneHandle;
  let monitor: MonitorState;

  beforeEach(async () => {
    mockKey = 'a'.repeat(64);
    regenerateCount = 0;
    persistedKey = null;
    monitor = { ...SILENCE };
    cp = await initControlPlane({
      version: '0.1.0',
      name: 'WAVE Monitor',
      getMonitor: () => monitor,
      actions: {
        start: (feedUrl: string) => {
          monitor = { ...monitor, feedUrl, connected: true };
          return monitor;
        },
        stop: () => {
          monitor = { ...SILENCE };
          return monitor;
        },
      },
      port: 0, // ephemeral so parallel tests don't collide
    });
  });

  afterEach(async () => {
    await cp.stop();
  });

  it('binds an ephemeral port and serves /v1/status with the minted key', async () => {
    expect(cp.port).toBeGreaterThan(0);
    expect(cp.apiKey).toMatch(/^[0-9a-f]{64}$/);
    const res = await fetchStatus(cp.port, cp.apiKey);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ ok: true, version: '0.1.0', connected: false, feedUrl: null });
  });

  it('rejects the previous key after rotate (atomic: persisted == live)', async () => {
    const oldKey = cp.apiKey;
    await cp.rotate();
    expect(cp.apiKey).not.toBe(oldKey);
    expect(persistedKey).toBe(cp.apiKey);

    const oldKeyRes = await fetchStatus(cp.port, oldKey);
    expect(oldKeyRes.status).toBe(401);

    const newKeyRes = await fetchStatus(cp.port, cp.apiKey);
    expect(newKeyRes.status).toBe(200);
  });

  it('serializes concurrent rotate() calls (no race condition)', async () => {
    const [keyA, keyB] = await Promise.all([cp.rotate(), cp.rotate()]);
    expect(keyA).toBe(keyB);
    expect(cp.apiKey).toBe(keyA);
    const ok = await fetchStatus(cp.port, cp.apiKey);
    expect(ok.status).toBe(200);
  });

  it('start/stop round-trip through the wire acts on shared state', async () => {
    const startRes = await fetch(`http://127.0.0.1:${cp.port}/v1/monitor/start`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${cp.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ feedUrl: 'https://relay.example/live/main' }),
    });
    expect(startRes.status).toBe(200);
    expect(((await startRes.json()) as MonitorState).connected).toBe(true);

    const status = (await (await fetchStatus(cp.port, cp.apiKey)).json()) as Record<string, unknown>;
    expect(status).toMatchObject({ connected: true, feedUrl: 'https://relay.example/live/main' });

    const stopRes = await fetch(`http://127.0.0.1:${cp.port}/v1/monitor/stop`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${cp.apiKey}` },
    });
    expect(stopRes.status).toBe(200);
    expect(((await stopRes.json()) as MonitorState).connected).toBe(false);
  });

  it('rejects a start with an invalid feedUrl (400, state untouched)', async () => {
    const res = await fetch(`http://127.0.0.1:${cp.port}/v1/monitor/start`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${cp.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ feedUrl: 'not-a-url' }),
    });
    expect(res.status).toBe(400);
    expect(monitor.connected).toBe(false);
  });

  it('serves /v1/version with the product identity', async () => {
    const res = await fetch(`http://127.0.0.1:${cp.port}/v1/version`, {
      headers: { Authorization: `Bearer ${cp.apiKey}` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ name: 'WAVE Monitor', version: '0.1.0' });
  });

  it('stop() closes the listener (subsequent fetch is refused)', async () => {
    const port = cp.port;
    await cp.stop();
    cp = { port, apiKey: '', rotate: async () => '', stop: async () => {} };
    await expect(
      fetch(`http://127.0.0.1:${port}/v1/status`, {
        headers: { Authorization: `Bearer ${'a'.repeat(64)}` },
      }),
    ).rejects.toThrow();
  });
});

describe('portFromEnv', () => {
  it('defaults to 7729', () => {
    expect(portFromEnv({})).toBe(7729);
    expect(portFromEnv({ WAVE_MONITOR_PORT: '' })).toBe(7729);
  });

  it('honors WAVE_MONITOR_PORT incl. 0 (ephemeral)', () => {
    expect(portFromEnv({ WAVE_MONITOR_PORT: '8080' })).toBe(8080);
    expect(portFromEnv({ WAVE_MONITOR_PORT: '0' })).toBe(0);
  });

  it('rejects garbage', () => {
    expect(() => portFromEnv({ WAVE_MONITOR_PORT: 'banana' })).toThrow();
    expect(() => portFromEnv({ WAVE_MONITOR_PORT: '-1' })).toThrow();
    expect(() => portFromEnv({ WAVE_MONITOR_PORT: '99999' })).toThrow();
  });
});
