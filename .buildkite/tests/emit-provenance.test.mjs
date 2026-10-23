// emit-provenance.test.mjs — O1 provenance emitter fixtures (WAVE-26520, WAVE-27337).
//
// Run: `npx vitest run .buildkite/tests/emit-provenance.test.mjs` from the
// repo root (also runs under plain `npm test`).

import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, readFileSync, symlinkSync, writeFileSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(HERE, '..', 'provenance', 'bin', 'emit-provenance.mjs');
const SHA = 'a'.repeat(40);

function bkEnv() {
  return {
    ...process.env,
    BUILDKITE_PIPELINE_SLUG: 'fixture-pipe',
    BUILDKITE_BUILD_NUMBER: '7',
    BUILDKITE_BUILD_ID: 'fixture-uuid',
    BUILDKITE_BRANCH: 'main',
    BUILDKITE_COMMIT: SHA,
    BUILDKITE_REPO: 'git@github.com:wave-av/fixture.git',
  };
}

function writeManifests(dir, steps) {
  const stepsPath = join(dir, 'steps.json');
  const guardsPath = join(dir, 'guards.json');
  writeFileSync(stepsPath, JSON.stringify(steps));
  writeFileSync(guardsPath, JSON.stringify([{ key: 'g', verdict: 'pass' }]));
  return { stepsPath, guardsPath };
}

function runEmit(repoDir, steps) {
  const dir = mkdtempSync(join(tmpdir(), 'o1fix-'));
  const { stepsPath, guardsPath } = writeManifests(dir, steps);
  const out = join(dir, 'provenance.json');
  const res = spawnSync('node', [SCRIPT,
    '--repo-dir', repoDir, '--steps', stepsPath, '--guards', guardsPath,
    '--base-rev', SHA, '--out', out, '--no-upload',
  ], { env: bkEnv(), encoding: 'utf8' });
  return { res, out, dir };
}

describe('emit-provenance repoDir constraint (WAVE-27337)', () => {
  it('rejects ../ escape in step command with exit 2', () => {
    const root = mkdtempSync(join(tmpdir(), 'o1repo-'));
    const repoDir = join(root, 'checkout');
    mkdirSync(repoDir, { recursive: true });
    // Secret OUTSIDE the checkout that a hostile manifest must not hash.
    writeFileSync(join(root, 'outside.sh'), 'echo outside\n');
    const { res, dir } = runEmit(repoDir, [
      { key: 'evil', queue: 'q', command: '../outside.sh', exit: 0 },
    ]);
    try {
      expect(res.status).toBe(2);
      expect(res.stderr).toMatch(/outside|escape|repo/i);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('rejects an in-checkout symlink pointing outside with exit 2', () => {
    const root = mkdtempSync(join(tmpdir(), 'o1repo-'));
    const repoDir = join(root, 'checkout');
    mkdirSync(join(repoDir, 'scripts'), { recursive: true });
    writeFileSync(join(root, 'outside.sh'), 'echo outside\n');
    symlinkSync(join(root, 'outside.sh'), join(repoDir, 'scripts', 'link.sh'));
    const { res, dir } = runEmit(repoDir, [
      { key: 'evil', queue: 'q', command: 'scripts/link.sh', exit: 0 },
    ]);
    try {
      expect(res.status).toBe(2);
      expect(res.stderr).toMatch(/symlink|escape/i);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('still emits for an in-repo script path', () => {
    const root = mkdtempSync(join(tmpdir(), 'o1repo-'));
    const repoDir = join(root, 'checkout');
    mkdirSync(join(repoDir, 'scripts'), { recursive: true });
    writeFileSync(join(repoDir, 'scripts', 'ok.sh'), 'echo ok\n');
    const { res, out, dir } = runEmit(repoDir, [
      { key: 'good', queue: 'q', command: 'scripts/ok.sh', exit: 0 },
    ]);
    try {
      expect(res.status).toBe(0);
      expect(res.stdout).toMatch(/digest=/);
      const doc = JSON.parse(readFileSync(out, 'utf8'));
      expect(doc.digest).toMatch(/^sha256:[0-9a-f]{64}$/);
      expect(doc.steps[0].script_sha256).toBe(
        createHash('sha256').update('echo ok\n').digest('hex'));
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
