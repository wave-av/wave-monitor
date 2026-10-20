// absence-scanner.test.mjs — R2 probe suite (WAVE-26519).
//
// Run: `npx vitest run .buildkite/tests/absence-scanner.test.mjs` from the
// repo root (also runs under plain `npm test`, which ci.sh invokes — this
// suite is wired into the repo's own gate).
//
// SHAPE HYGIENE: simulants are assembled at RUNTIME (string concatenation)
// so this file never contains a literal matchable shape. The self-scan tests
// below prove it: the scanner run over its own sources must report zero hits,
// and receipts must never contain a simulant value (KINDs only, enforced).

import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import {
  scanLine,
  scanFile,
  scanRoots,
  normalizeTerms,
  isForkShaped,
  isSecretName,
  isCommittedDotenv,
  loadTermsFile,
} from '../scripts/absence-scanner.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROBE_SCRIPTS = join(HERE, '..', 'scripts');
const REPO_ROOT = join(HERE, '..', '..');

// --- Runtime-assembled simulants (never literal in this file) ---------------

const simulantAkid = () => 'AKIA' + '0'.repeat(16);
const simulantGhPat = () => 'github_pat_' + 'Q'.repeat(61);
const simulantSkAnt = () => 'sk-ant-' + 'api07-' + 'z'.repeat(20);
const simulantStripeLive = () => 'sk_live_' + '1'.repeat(20);
const simulantStripeAcct = () => 'acct_' + '2'.repeat(16);
const simulantPem = () => '-----BEGIN ' + 'PRIVATE KEY-----';
const simulantIp = () => '100.' + '64.10.20';
const simulantHomePath = () => '/Users/' + 'someone' + '/Documents/x';
const simulantEmail = () => 'someone' + '@' + 'gmail.com';
const simulantCfId = () => 'account_id' + ' = ' + 'f'.repeat(32);
const simulantSupabase = () => 'sbp_' + 'a'.repeat(40);
const simulantAwsSecretAssignment = () => 'export ' + 'GH_TOKEN' + '=' + 'x'.repeat(30);
const TERM = 'r2-simulant-term-omega';

function withTmpDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'absence-test-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('scanLine record population (all families)', () => {
  it('passes clean prose', () => {
    expect(scanLine('hello world')).toEqual([]);
    expect(scanLine('migrate secrets to Doppler')).toEqual([]);
  });

  it('names secret-shaped keys without misreading their prose values', () => {
    // secret-name fires by design (schema detector, value-independent); the
    // no-false-positive property is that secret-assignment stays quiet on
    // colon-prose — the measured 4.3% class upstream.
    for (const line of [
      'token: quarterly-rotation policy',
      'password: forgotten-flow rewrite',
      'access_token: undefined in the refresh response',
    ]) {
      const kinds = scanLine(line);
      expect(kinds).toContain('secret-name');
      expect(kinds).not.toContain('secret-assignment');
      expect(kinds).not.toContain('secret-value');
    }
  });

  it('flags live value shapes', () => {
    expect(scanLine(`leaked ${simulantAkid()} here`)).toContain('secret-value');
    expect(scanLine(`leaked ${simulantGhPat()} here`)).toContain('secret-value');
    expect(scanLine(`leaked ${simulantSkAnt()} here`)).toContain('secret-value');
    expect(scanLine(`leaked ${simulantStripeLive()} here`)).toContain('secret-value');
  });

  it('flags secret-named assignments and names', () => {
    const kinds = scanLine(simulantAwsSecretAssignment());
    expect(kinds).toContain('secret-assignment');
    expect(kinds).toContain('secret-name');
    expect(scanLine('api_token: short')).toContain('secret-name');
  });

  it('flags nda-term hits case-insensitively', () => {
    expect(scanLine(`contains ${TERM} here`, { terms: [TERM] })).toContain('nda-term');
    expect(scanLine(`contains ${TERM.toUpperCase()} here`, { terms: [TERM] })).toContain('nda-term');
    expect(scanLine(`contains ${TERM} here`, { terms: [] })).not.toContain('nda-term');
  });

  it('flags nda-pattern sub-kinds', () => {
    expect(scanLine(simulantStripeAcct())).toContain('nda-pattern/stripe-account');
    expect(scanLine(simulantStripeLive())).toContain('nda-pattern/stripe-live-key');
    expect(scanLine(simulantCfId())).toContain('nda-pattern/cf-account-id');
    expect(scanLine(`ip ${simulantIp()} x`)).toContain('nda-pattern/internal-ip');
    expect(scanLine(`path ${simulantHomePath()} x`)).toContain('nda-pattern/abs-user-path');
    expect(scanLine(simulantSkAnt())).toContain('nda-pattern/anthropic-key');
    expect(scanLine(simulantGhPat())).toContain('nda-pattern/github-pat');
    expect(scanLine(simulantSupabase())).toContain('nda-pattern/supabase-pat');
    expect(scanLine(simulantAkid())).toContain('nda-pattern/aws-akid');
    expect(scanLine(simulantPem())).toContain('nda-pattern/private-key');
    expect(scanLine(`mail ${simulantEmail()} x`)).toContain('nda-pattern/personal-email-provider');
  });
});

describe('scanLine file population (value shapes only)', () => {
  it('keeps value families active', () => {
    expect(scanLine(`v=${simulantAkid()}`, { fileMode: true })).toContain('secret-value');
    expect(scanLine(simulantIp(), { fileMode: true })).toContain('nda-pattern/internal-ip');
    expect(scanLine(`has ${TERM}`, { fileMode: true, terms: [TERM] })).toContain('nda-term');
  });

  it('disables name families on ordinary code (measured FPs)', () => {
    expect(scanLine('  apiKey: key,', { fileMode: true })).toEqual([]);
    expect(scanLine('NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}', { fileMode: true })).toEqual([]);
    expect(scanLine('const token = trimmed.slice(1);', { fileMode: true })).toEqual([]);
    expect(scanLine('secrets: []', { fileMode: true })).toEqual([]);
    expect(scanLine(simulantAwsSecretAssignment(), { fileMode: true })).not.toContain('secret-assignment');
    expect(scanLine(simulantAwsSecretAssignment(), { fileMode: true })).not.toContain('secret-name');
  });
});

describe('classifiers', () => {
  it('isForkShaped follows the governance-enforce rule', () => {
    expect(isForkShaped({ BUILDKITE_PULL_REQUEST_REPO: 'a', BUILDKITE_REPO: 'b' })).toBe(true);
    expect(isForkShaped({ BUILDKITE_PULL_REQUEST_REPO: 'a', BUILDKITE_REPO: 'a' })).toBe(false);
    expect(isForkShaped({ BUILDKITE_REPO: 'a' })).toBe(false);
    expect(isForkShaped({})).toBe(false);
  });

  it('isSecretName matches holders, exempts counters', () => {
    expect(isSecretName('GH_PACKAGES_READ_TOKEN')).toBe(true);
    expect(isSecretName('GUARD_PRIVATE_REPOS')).toBe(false);
    expect(isSecretName('BUILDKITE_AGENT_ACCESS_TOKEN')).toBe(true);
    expect(isSecretName('api_tokens')).toBe(true);
    expect(isSecretName('prompt_tokens')).toBe(false);
    expect(isSecretName('PATH')).toBe(false);
  });

  it('normalizeTerms lowercases and drops empties', () => {
    expect(normalizeTerms(['  AbC ', '', null, 'x'])).toEqual(['abc', 'x']);
  });

  it('isCommittedDotenv names real dotenv files only', () => {
    expect(isCommittedDotenv('/r/.env')).toBe(true);
    expect(isCommittedDotenv('/r/.env.local')).toBe(true);
    expect(isCommittedDotenv('/r/.env.example')).toBe(false);
    expect(isCommittedDotenv('/r/.env.sample')).toBe(false);
    expect(isCommittedDotenv('/r/.env.template')).toBe(false);
    expect(isCommittedDotenv('/r/.env.dist')).toBe(false);
    expect(isCommittedDotenv('/r/env.txt')).toBe(false);
  });
});

describe('walker', () => {
  it('finds hits with path + line + KIND, never content', () => {
    withTmpDir((dir) => {
      const target = join(dir, 'note.txt');
      writeFileSync(target, `clean line\nleaked ${simulantAkid()} here\n`);
      const r = scanFile(target);
      expect(r.skipped).toBeNull();
      expect(r.hits).toHaveLength(1);
      expect(r.hits[0].line).toBe(2);
      expect(r.hits[0].kinds).toContain('secret-value');
      // KIND-only proof: the finding carries no simulant substring.
      expect(JSON.stringify(r)).not.toContain(simulantAkid());
    });
  });

  it('flags committed dotenv by name', () => {
    withTmpDir((dir) => {
      const target = join(dir, '.env');
      writeFileSync(target, 'harmless=1\n');
      const r = scanFile(target);
      expect(r.hits.some((h) => h.kinds.includes('nda-pattern/committed-dotenv'))).toBe(true);
    });
  });

  it('skips excluded dirs and counts them', () => {
    withTmpDir((dir) => {
      mkdirSync(join(dir, 'node_modules', 'pkg'), { recursive: true });
      writeFileSync(join(dir, 'node_modules', 'pkg', 'i.js'), simulantAkid());
      mkdirSync(join(dir, '.git', 'objects'), { recursive: true });
      writeFileSync(join(dir, '.git', 'objects', 'x'), simulantAkid());
      writeFileSync(join(dir, 'ok.txt'), 'clean\n');
      const { hits, excluded, filesScanned } = scanRoots([dir]);
      expect(hits).toEqual([]);
      expect(filesScanned).toBe(1);
      expect(excluded.length).toBe(2);
    });
  });

  it('skips worktree gitlink files', () => {
    withTmpDir((dir) => {
      writeFileSync(join(dir, '.git'), `gitdir: ${simulantHomePath()}/r.git\n`);
      writeFileSync(join(dir, 'ok.txt'), 'clean\n');
      const { hits, excluded, filesScanned } = scanRoots([dir]);
      expect(hits).toEqual([]);
      expect(filesScanned).toBe(1);
      expect(excluded).toHaveLength(1);
      expect(excluded[0].reason).toBe('excluded-file');
    });
  });

  it('counts over-cap files instead of silently passing them', () => {
    withTmpDir((dir) => {
      writeFileSync(join(dir, 'big.bin'), 'z'.repeat(100));
      const { excluded, filesScanned } = scanRoots([dir], { maxBytes: 10 });
      expect(filesScanned).toBe(0);
      expect(excluded).toHaveLength(1);
      expect(excluded[0].reason).toMatch(/over-size-cap/);
    });
  });

  it('fails closed on unreadable roots', () => {
    expect(() => scanRoots([join(tmpdir(), 'absence-no-such-dir-xyz')])).toThrow(/unreadable/);
  });

  it('loadTermsFile fails closed on missing/empty', () => {
    expect(() => loadTermsFile(join(tmpdir(), 'absence-no-such-terms-xyz'))).toThrow(/unreadable/);
    withTmpDir((dir) => {
      const p = join(dir, 'terms.txt');
      writeFileSync(p, '  \n\n');
      expect(() => loadTermsFile(p)).toThrow(/zero effective terms/);
      writeFileSync(p, `  ${TERM}  \n`);
      expect(loadTermsFile(p)).toEqual([TERM]);
    });
  });
});

describe('self-scan (committed tree proves its own cleanliness)', () => {
  it('probe sources + probe tests scan clean', () => {
    const { hits, filesScanned } = scanRoots([PROBE_SCRIPTS, HERE]);
    expect(filesScanned).toBeGreaterThan(0);
    expect(hits).toEqual([]);
  });

  it('whole repo tree scans clean', () => {
    const { hits, filesScanned } = scanRoots([REPO_ROOT]);
    expect(filesScanned).toBeGreaterThan(0);
    expect(hits).toEqual([]);
  });
});

describe('probe CLIs end to end', () => {
  const CLEAN_ENV = { PATH: process.env.PATH ?? '/usr/bin:/bin' };

  function runProbe(script, args, env) {
    const r = spawnSync('node', [join(PROBE_SCRIPTS, script), ...args], {
      env,
      encoding: 'utf8',
      timeout: 60000,
    });
    const out = String(r.stdout ?? '');
    const receipt = JSON.parse(out.slice(out.indexOf('{')));
    return { status: r.status, receipt, out };
  }

  it('probe-env PASSes a clean room, FLAGs injected names on fork builds', () => {
    const clean = runProbe('probe-absence-env.mjs', [], CLEAN_ENV);
    expect(clean.status).toBe(0);
    expect(clean.receipt.verdict).toBe('PASS');

    const forkValue = `fork-simulant-${'v'.repeat(8)}`;
    const flagged = runProbe('probe-absence-env.mjs', [], {
      ...CLEAN_ENV,
      BUILDKITE_PULL_REQUEST_REPO: 'https://example.invalid/fork',
      BUILDKITE_REPO: 'https://example.invalid/upstream',
      GUARD_PRIVATE_REPOS: forkValue,
    });
    expect(flagged.status).toBe(1);
    expect(flagged.receipt.verdict).toBe('FLAG');
    expect(flagged.receipt.fork_shaped).toBe(true);
    expect(flagged.receipt.hits.some((h) => h.name === 'GUARD_PRIVATE_REPOS')).toBe(true);
    // KINDs only: the injected VALUE appears nowhere in the output.
    expect(flagged.out).not.toContain(forkValue);
  });

  it('probe-env honors the operational allowlist extension', () => {
    const allowed = runProbe('probe-absence-env.mjs', [], {
      ...CLEAN_ENV,
      MY_DEPLOY_TOKEN: 'placeholder',
      ABSENCE_PROBE_ENV_ALLOW: 'MY_DEPLOY_TOKEN',
    });
    expect(allowed.receipt.verdict).toBe('PASS');
    const denied = runProbe('probe-absence-env.mjs', [], {
      ...CLEAN_ENV,
      MY_DEPLOY_TOKEN: 'placeholder',
    });
    expect(denied.status).toBe(1);
    expect(denied.receipt.hits.some((h) => h.name === 'MY_DEPLOY_TOKEN')).toBe(true);
  });

  it('probe-fs FLAGs planted material, PASSes clean dirs', () => {
    withTmpDir((dir) => {
      writeFileSync(join(dir, 'drop.txt'), `planted ${simulantGhPat()}\n`);
      const flagged = runProbe('probe-absence-fs.mjs', ['--roots', dir], CLEAN_ENV);
      expect(flagged.status).toBe(1);
      expect(flagged.receipt.verdict).toBe('FLAG');
      expect(flagged.out).not.toContain(simulantGhPat());
    });
    withTmpDir((dir) => {
      writeFileSync(join(dir, 'ok.txt'), 'nothing here\n');
      const clean = runProbe('probe-absence-fs.mjs', ['--roots', dir], CLEAN_ENV);
      expect(clean.status).toBe(0);
      expect(clean.receipt.verdict).toBe('PASS');
    });
  });

  it('probe-log FLAGs log hits, SKIPs empty inputs', () => {
    withTmpDir((dir) => {
      writeFileSync(join(dir, 'job.log'), `output line\ntoken=${simulantStripeLive()}\n`);
      const flagged = runProbe('probe-absence-log.mjs', ['--paths', dir], CLEAN_ENV);
      expect(flagged.status).toBe(1);
      expect(flagged.receipt.verdict).toBe('FLAG');
      expect(flagged.out).not.toContain(simulantStripeLive());
    });
    withTmpDir((dir) => {
      const skipped = runProbe('probe-absence-log.mjs', ['--paths', dir], CLEAN_ENV);
      expect(skipped.status).toBe(0);
      expect(skipped.receipt.verdict).toBe('SKIP');
    });
  });
});
