/**
 * Unit tests for the staged-rollout gate. Vitest port of the template's
 * rollout-guard.test.mjs: cohort math is pure; fetch paths run against a
 * loopback stub server (never the real feed).
 */

import { describe, it, expect } from 'vitest';
import { createServer, type Server } from 'node:http';
import { AddressInfo } from 'node:net';
import { BUCKETS, cohort, defaultMachineId, inRollout, rolloutAllows } from './rollout-guard';

describe('cohort', () => {
  it('is stable: same machine+version always lands in the same bucket', () => {
    const a = cohort('machine-1', '1.2.3');
    expect(cohort('machine-1', '1.2.3')).toBe(a);
    expect(a).toBeGreaterThanOrEqual(0);
    expect(a).toBeLessThan(BUCKETS);
  });

  it('differs across versions for the same machine (most of the time)', () => {
    // A rollout pin change must reshuffle; assert at least one of several
    // versions lands elsewhere (hash collision on all five is ~1e-15).
    const buckets = new Set(['1.0.0', '1.0.1', '1.1.0', '2.0.0', '2.0.1'].map((v) => cohort('m', v)));
    expect(buckets.size).toBeGreaterThan(1);
  });
});

describe('inRollout', () => {
  it('honors the fraction boundaries', () => {
    expect(inRollout('m', '1.0.0', 0)).toBe(false);
    expect(inRollout('m', '1.0.0', -1)).toBe(false);
    expect(inRollout('m', '1.0.0', Number.NaN)).toBe(false);
    expect(inRollout('m', '1.0.0', 1)).toBe(true);
    expect(inRollout('m', '1.0.0', 2)).toBe(true);
  });

  it('admits roughly the fraction over many machines', () => {
    let hits = 0;
    const N = 4000;
    for (let i = 0; i < N; i++) if (inRollout(`machine-${i}`, '9.9.9', 0.25)) hits++;
    const rate = hits / N;
    expect(rate).toBeGreaterThan(0.2);
    expect(rate).toBeLessThan(0.3);
  });
});

describe('defaultMachineId', () => {
  it('returns a stable 32-hex id', () => {
    expect(defaultMachineId()).toMatch(/^[0-9a-f]{32}$/);
    expect(defaultMachineId()).toBe(defaultMachineId());
  });
});

function stubServer(manifest: unknown, status = 200): Promise<{ server: Server; url: string }> {
  const server = createServer((_req, res) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(typeof manifest === 'string' ? manifest : JSON.stringify(manifest));
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const port = (server.address() as AddressInfo).port;
      resolve({ server, url: `http://127.0.0.1:${port}` });
    });
  });
}

describe('rolloutAllows', () => {
  it('admits cohort members when the manifest pins their version', async () => {
    const { server, url } = await stubServer({ version: '1.2.3', rollout: 1 });
    try {
      const r = await rolloutAllows({ feedUrl: url, version: '1.2.3', machineId: 'any' });
      expect(r.allowed).toBe(true);
      expect(r.reason).toBe('in-rollout-cohort');
    } finally {
      server.close();
    }
  });

  it('defers non-cohort members (fail-closed)', async () => {
    const { server, url } = await stubServer({ version: '1.2.3', rollout: 0 });
    try {
      const r = await rolloutAllows({ feedUrl: url, version: '1.2.3', machineId: 'any' });
      expect(r.allowed).toBe(false);
      expect(r.reason).toBe('deferred-by-rollout');
    } finally {
      server.close();
    }
  });

  it('refuses versions the manifest does not pin', async () => {
    const { server, url } = await stubServer({ version: '1.2.3', rollout: 1 });
    try {
      const r = await rolloutAllows({ feedUrl: url, version: '9.9.9', machineId: 'any' });
      expect(r.allowed).toBe(false);
      expect(r.reason).toMatch(/version-not-in-rollout/);
    } finally {
      server.close();
    }
  });

  it('fails closed when the feed is unreachable', async () => {
    const r = await rolloutAllows({
      feedUrl: 'http://127.0.0.1:1/',
      version: '1.2.3',
      machineId: 'any',
    });
    expect(r.allowed).toBe(false);
    expect(r.reason).toMatch(/no-rollout-manifest/);
  });

  it('fails closed on manifest HTTP errors', async () => {
    const { server, url } = await stubServer({ error: true }, 500);
    try {
      const r = await rolloutAllows({ feedUrl: url, version: '1.2.3', machineId: 'any' });
      expect(r.allowed).toBe(false);
      expect(r.reason).toMatch(/no-rollout-manifest/);
    } finally {
      server.close();
    }
  });

  it('fails closed on a manifest with no version', async () => {
    const { server, url } = await stubServer({ rollout: 1 });
    try {
      const r = await rolloutAllows({ feedUrl: url, version: '1.2.3', machineId: 'any' });
      expect(r.allowed).toBe(false);
      expect(r.reason).toBe('rollout-manifest-missing-version');
    } finally {
      server.close();
    }
  });
});
