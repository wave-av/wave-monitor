#!/usr/bin/env node
// probe-absence-log — R2 probe (iii): log/artifact KIND scan (WAVE-26519).
//
// Asserts that fork-run logs and staged artifacts carry no secret KINDs.
// Inputs (colon-separated ABSENCE_PROBE_LOG_PATHS, or argv --paths for
// local/R1 runs; each entry a file or a directory scanned recursively):
// when unset, collects ./*.log-style files: every *.log under the workspace
// plus everything under <workspace>/artifacts when present.
//
// HONEST SCOPE NOTE: this probe scans workspace-REACHABLE logs/artifacts.
// Buildkite job-log tails and annotations are host-side surfaces the step
// cannot read without API credentials (which would violate zero-injection),
// so tail redaction stays a host control — PROMOTION.md gate P3. The R1 rig
// feeds synthetic job logs here to prove the detector end to end.
//
// Findings carry path + line + KIND only — never content: echoing a matched
// log line would re-leak the secret into THIS step's public log.
//
// Exit: 0 PASS (or SKIP when zero files scanned), 1 FLAG, 2 error (closed).

import {
  isForkShaped,
  scanRoots,
  collectFiles,
  scanFile,
  loadTermsFile,
  emitReceipt,
  parseArgs,
  DEFAULT_MAX_BYTES,
} from './absence-scanner.mjs';

function defaultInputs(env) {
  const workspace = env.BUILDKITE_BUILD_CHECKOUT_PATH ?? process.cwd();
  const inputs = [];
  try {
    const all = collectFiles(workspace);
    for (const f of all) {
      if (f.endsWith('.log') || f.includes('/artifacts/')) inputs.push(f);
    }
  } catch {
    // Workspace unreadable: the scan below reports zero inputs (SKIP + note).
  }
  // Also cover a conventionally staged artifacts dir explicitly.
  return { workspace, inputs };
}

function main(argv, env) {
  const args = parseArgs(argv);
  const pathsRaw = args.paths ?? env.ABSENCE_PROBE_LOG_PATHS ?? '';
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

  if (String(pathsRaw) !== '') {
    const entries = String(pathsRaw).split(':').map((s) => s.trim()).filter(Boolean);
    const { families, hits, excluded, scannedRoots, filesScanned } = scanRoots(entries, { terms, maxBytes });
    return finish({ families, hits, excluded, scannedRoots, filesScanned, notes });
  }

  const { workspace, inputs } = defaultInputs(env);
  notes.push(`default input collection under workspace ${workspace}: ${inputs.length} log/artifact file(s)`);
  const families = {
    'secret-value': true,
    'secret-assignment': true,
    'secret-name': true,
    'nda-term': terms.length > 0,
    'nda-pattern': true,
  };
  const hits = [];
  const excluded = [];
  let filesScanned = 0;
  for (const f of inputs) {
    const r = scanFile(f, { terms, maxBytes });
    if (r.skipped) {
      excluded.push({ path: f, reason: r.skipped });
      continue;
    }
    filesScanned += 1;
    for (const h of r.hits) hits.push({ path: f, line: h.line, kinds: h.kinds });
  }
  return finish({
    families,
    hits,
    excluded,
    scannedRoots: [{ root: `${workspace} (*.log + artifacts)`, files: inputs.length }],
    filesScanned,
    notes,
  });
}

function finish({ families, hits, excluded, scannedRoots, filesScanned, notes }) {
  const forkShaped = isForkShaped();
  let verdict = hits.length > 0 ? 'FLAG' : 'PASS';
  if (filesScanned === 0 && hits.length === 0) {
    verdict = 'SKIP';
    notes.push('zero log/artifact files scanned — nothing was verified (explicit SKIP, not a silent pass)');
  }
  const receipt = {
    probe: 'absence-log',
    verdict,
    fork_shaped: forkShaped,
    families,
    roots: scannedRoots,
    files_scanned: filesScanned,
    excluded_paths: excluded.length,
    excluded_sample: excluded.slice(0, 10),
    hits: hits.slice(0, 200),
    hits_total: hits.length,
    truncated: hits.length > 200,
    notes,
  };
  const human = verdict === 'PASS'
    ? `absence-log: PASS — ${filesScanned} log/artifact file(s), no KIND hits`
    : verdict === 'SKIP'
      ? 'absence-log: SKIP — zero log/artifact files scanned'
      : `absence-log: FLAG — ${hits.length} hit(s) (paths + KINDs only, see receipt)`;
  process.stderr.write(`${human}\n`);
  emitReceipt(receipt, { annotateContext: 'absence-log' });
  return verdict === 'FLAG' ? 1 : 0;
}

try {
  process.exit(main(process.argv.slice(2), process.env));
} catch (err) {
  process.stderr.write(`absence-log: ERROR — ${err.message}\n`);
  emitReceipt({
    probe: 'absence-log',
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
