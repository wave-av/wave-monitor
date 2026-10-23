#!/usr/bin/env node
// probe-absence-fs — R2 probe (ii): filesystem post-step scan (WAVE-26519).
//
// Scans workspace + tmp + npm caches with the vendored inspector families
// (secret-value, secret-assignment, secret-name, nda-term, nda-pattern) and
// FLAGs on any hit. Findings carry path + line + KIND only — never content.
//
// Default roots (colon-separated ABSENCE_PROBE_ROOTS overrides; argv
// --roots ... wins for local/R1 runs):
//   1. BUILDKITE_BUILD_CHECKOUT_PATH, else the current directory (workspace)
//   2. the OS tmp dir (TMPDIR/TMPDIR-equivalent)
//   3. the npm cache (`npm config get cache`, best-effort; ~/.npm fallback)
//
// nda-term needs ABSENCE_PROBE_TERMS_FILE (or --terms-file); without one the
// family reports unscanned. In report mode that is a note; enforcing mode
// fails closed on it (PROMOTION.md gate P2).
//
// HONEST SCOPE NOTE: as a pipeline step this probe scans its OWN checkout and
// agent-local tmp/caches — a second opinion with different detectors from
// gitleaks/content-policy, plus agent-image contamination. Literal post-step
// observation (same agent, after the observed step) is host wiring (post-
// command hook) per PROMOTION.md; the R1 rig wires it literally in-container.
//
// Exit: 0 PASS (or SKIP when zero files scanned), 1 FLAG, 2 error (closed).

import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  isForkShaped,
  scanRoots,
  loadTermsFile,
  emitReceipt,
  parseArgs,
  DEFAULT_MAX_BYTES,
} from './absence-scanner.mjs';

function npmCacheDir() {
  try {
    const r = spawnSync('npm', ['config', 'get', 'cache'], {
      encoding: 'utf8',
      timeout: 10000,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const out = String(r.stdout ?? '').trim();
    if (r.status === 0 && out !== '') return out;
  } catch {
    // Fall through to the conventional default below.
  }
  return join(homedir(), '.npm');
}

function defaultRoots(env) {
  const roots = [];
  roots.push(env.BUILDKITE_BUILD_CHECKOUT_PATH ?? process.cwd());
  roots.push(tmpdir());
  roots.push(npmCacheDir());
  // Dedupe while keeping order (tmpdir may equal a cache parent, etc.).
  return [...new Set(roots)];
}

function main(argv, env) {
  const args = parseArgs(argv);
  const rootsRaw = args.roots ?? env.ABSENCE_PROBE_ROOTS ?? '';
  const roots = String(rootsRaw) === ''
    ? defaultRoots(env)
    : String(rootsRaw).split(':').map((s) => s.trim()).filter(Boolean);
  if (roots.length === 0) throw new Error('no scan roots configured');

  const termsPath = args.terms_file ?? env.ABSENCE_PROBE_TERMS_FILE ?? '';
  const maxBytes = Number(args.max_bytes ?? env.ABSENCE_PROBE_MAX_BYTES ?? DEFAULT_MAX_BYTES);
  if (!Number.isFinite(maxBytes) || maxBytes <= 0) throw new Error('bad max-bytes cap');

  const notes = [];
  let terms = [];
  if (String(termsPath) !== '') {
    terms = loadTermsFile(String(termsPath));
    notes.push(`nda-term active from terms file (${terms.length} effective terms; file never echoed)`);
  } else {
    notes.push('no terms file: nda-term family unscanned (report-mode note; enforcing-mode FAIL per PROMOTION.md P2)');
  }

  const forkShaped = isForkShaped(env);
  const { families, hits, excluded, scannedRoots, filesScanned } = scanRoots(roots, { terms, maxBytes });
  const excludedDirs = excluded.filter((e) => e.reason === 'excluded-dir').length;

  let verdict = hits.length > 0 ? 'FLAG' : 'PASS';
  if (filesScanned === 0 && hits.length === 0) {
    verdict = 'SKIP';
    notes.push('zero files scanned — nothing was verified (explicit SKIP, not a silent pass)');
  }
  if (excluded.length > 0) {
    notes.push(`${excluded.length} path(s) excluded/unscanned (see excluded_sample) — coverage is partial, not silent`);
  }
  const receipt = {
    probe: 'absence-fs',
    verdict,
    fork_shaped: forkShaped,
    families,
    roots: scannedRoots,
    files_scanned: filesScanned,
    excluded_paths: excluded.length,
    excluded_dirs: excludedDirs,
    excluded_sample: excluded.slice(0, 10),
    max_bytes: maxBytes,
    hits: hits.slice(0, 200),
    hits_total: hits.length,
    truncated: hits.length > 200,
    notes,
  };
  const human = verdict === 'PASS'
    ? `absence-fs: PASS — ${filesScanned} file(s) across ${roots.length} root(s), no KIND hits`
    : verdict === 'SKIP'
      ? 'absence-fs: SKIP — zero files scanned'
      : `absence-fs: FLAG — ${hits.length} hit(s) across ${filesScanned} file(s) (paths + KINDs only, see receipt)`;
  process.stderr.write(`${human}\n`);
  emitReceipt(receipt, { annotateContext: 'absence-fs' });
  return verdict === 'FLAG' ? 1 : 0;
}

try {
  process.exit(main(process.argv.slice(2), process.env));
} catch (err) {
  process.stderr.write(`absence-fs: ERROR — ${err.message}\n`);
  emitReceipt({
    probe: 'absence-fs',
    verdict: 'ERROR',
    fork_shaped: isForkShaped(),
    families: {
      'secret-value': false,
      'secret-assignment': false,
      'secret-name': false,
      'nda-term': false,
      'nda-pattern': false,
    },
    hits: [],
    notes: [`internal error: ${err.message}`],
  });
  process.exit(2);
}
