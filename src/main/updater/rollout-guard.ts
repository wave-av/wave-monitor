/**
 * rollout-guard — staged-rollout gate for wave-monitor auto-updates.
 *
 * TypeScript port of the create-wave-app electron template's
 * rollout-guard.js (proven on the Wave Desk / Lighthouse path). Pure logic,
 * zero Electron imports, so it unit-tests without booting the app.
 *
 * Flow: updater.ts finds version V on the feed, then calls rolloutAllows().
 * The feed serves rollout.json {version, rollout} next to latest-mac.yml:
 * version pins which release is rolling out, rollout is the fraction
 * (0..1) of machines that may take it. Cohort membership is a stable hash
 * of (machineId, version), so a machine in the cohort stays in until the
 * rollout version changes. Any failure (no manifest, wrong version, fetch
 * error) fails CLOSED: no update.
 */

import { createHash } from 'node:crypto';
import { hostname, homedir } from 'node:os';

export const BUCKETS = 1000;

export function cohort(machineId: string, version: string): number {
  const hex = createHash('sha256').update(`${machineId}@${version}`).digest('hex').slice(0, 8);
  return parseInt(hex, 16) % BUCKETS;
}

export function inRollout(machineId: string, version: string, fraction: number): boolean {
  const f = Number(fraction);
  if (!Number.isFinite(f) || f <= 0) return false;
  if (f >= 1) return true;
  return cohort(machineId, version) < Math.floor(f * BUCKETS);
}

export function defaultMachineId(): string {
  return createHash('sha256').update(`${hostname()}@${homedir()}`).digest('hex').slice(0, 32);
}

export interface RolloutManifest {
  version: string;
  rollout: number;
}

type FetchImpl = (url: string, init?: { redirect?: 'follow' | 'error' | 'manual' }) => Promise<Response>;

export async function fetchRollout(feedUrl: string, fetchImpl: FetchImpl = fetch): Promise<RolloutManifest> {
  const base = String(feedUrl).replace(/\/+$/, '');
  const res = await fetchImpl(`${base}/rollout.json`, { redirect: 'follow' });
  if (!res.ok) throw new Error(`rollout manifest HTTP ${res.status}`);
  const body = (await res.json()) as { version?: unknown; rollout?: unknown };
  return { version: String(body.version ?? ''), rollout: Number(body.rollout) };
}

export interface RolloutVerdict {
  allowed: boolean;
  reason: string;
  version?: string;
  rollout?: number;
}

export interface RolloutQuery {
  feedUrl: string;
  version: string;
  machineId?: string;
  fetchImpl?: FetchImpl;
}

/**
 * Returns the rollout verdict. Never throws for feed problems — those
 * become allowed:false with a reason (fail closed).
 */
export async function rolloutAllows(query: RolloutQuery): Promise<RolloutVerdict> {
  const machineId = query.machineId ?? defaultMachineId();
  const fetchImpl = query.fetchImpl ?? fetch;
  let manifest: RolloutManifest;
  try {
    manifest = await fetchRollout(query.feedUrl, fetchImpl);
  } catch (err) {
    return { allowed: false, reason: `no-rollout-manifest: ${(err as Error).message}` };
  }
  if (!manifest.version) return { allowed: false, reason: 'rollout-manifest-missing-version' };
  if (manifest.version !== String(query.version)) {
    return { allowed: false, reason: `version-not-in-rollout (manifest pins ${manifest.version})` };
  }
  if (!inRollout(machineId, manifest.version, manifest.rollout)) {
    return {
      allowed: false,
      reason: 'deferred-by-rollout',
      version: manifest.version,
      rollout: manifest.rollout,
    };
  }
  return { allowed: true, reason: 'in-rollout-cohort', version: manifest.version, rollout: manifest.rollout };
}
