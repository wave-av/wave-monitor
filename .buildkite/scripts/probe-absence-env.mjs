#!/usr/bin/env node
// probe-absence-env — R2 probe (i): env-dump allowlist assertion (WAVE-26519).
//
// Asserts that this step received ZERO secret injection: every enumerated
// environment NAME (never values) must either be non-secret-shaped or on the
// operational allowlist. Two checks:
//
//   A. FORBIDDEN-ALWAYS: the pipeline's host-injected secret names
//      (GH_PACKAGES_READ_TOKEN, GUARD_PRIVATE_REPOS — see README runbook)
//      must be ABSENT. The host maps injections by (pipeline, step key) and
//      maps nothing to probe keys, so presence here is a host misconfiguration
//      — on a fork-shaped build it is exactly the path-1 hole (injection not
//      withheld) that S1/S2 close by other means.
//   B. UNEXPECTED-SECRET-NAME: any other secret-NAMED var (vendored
//      SECRET_KEY_RE composition) not on the operational allowlist flags.
//      Seed allowlist: BUILDKITE_AGENT_ACCESS_TOKEN (agent's own credential,
//      present on every job). Extend per step via ABSENCE_PROBE_ENV_ALLOW
//      (space-separated, set in the pipeline step env block — steps take no
//      command arguments under no-command-eval).
//
// The probe step runs on queue fpc-isolated-secrets with NO injection mapped:
// the secrets queue (not fpc-isolated) is what makes check A non-vacuous —
// a host that injects broadly would trip it. Report-mode wiring soft-fails
// the step; see absence-probes-PROMOTION.md.
//
// Exit: 0 PASS, 1 FLAG (finding), 2 internal error (fail closed).

import { isForkShaped, isSecretName, emitReceipt, parseArgs } from './absence-scanner.mjs';

const FORBIDDEN_ALWAYS = ['GH_PACKAGES_READ_TOKEN', 'GUARD_PRIVATE_REPOS'];
const OPERATIONAL_ALLOW = new Set(['BUILDKITE_AGENT_ACCESS_TOKEN']);

function main(argv, env) {
  const args = parseArgs(argv);
  const extraAllow = String(args.allow ?? env.ABSENCE_PROBE_ENV_ALLOW ?? '')
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean);

  const forkShaped = isForkShaped(env);
  const notes = [];
  // A fork PR can set ABSENCE_PROBE_ENV_ALLOW via pipeline.yml env, so on a
  // fork-shaped build any extension is itself a FLAG and the extension is
  // ignored — otherwise the watched party could mute its watcher (review
  // finding, PR #124). Trusted and local runs keep the extension.
  const forkExtension = forkShaped && extraAllow.length > 0;
  if (!forkExtension) {
    for (const name of extraAllow) OPERATIONAL_ALLOW.add(name);
  } else {
    notes.push(`allowlist extension ignored on fork-shaped build (${extraAllow.length} name(s)) — treated as FLAG`);
  }
  if (!env.BUILDKITE_PULL_REQUEST_REPO && !env.BUILDKITE_REPO) {
    notes.push('no BUILDKITE repo vars: not a Buildkite job env (local/R1 run)');
  } else if (!env.BUILDKITE_PULL_REQUEST_REPO) {
    notes.push('non-PR build: fork-shape not determinable from URL check; residual tracked on epic');
  }

  const names = Object.keys(env).sort();
  const hits = [];
  for (const name of names) {
    if (FORBIDDEN_ALWAYS.includes(name)) {
      hits.push({
        path: '(env)',
        line: 0,
        kinds: ['injected-secret-name'],
        name,
        why: forkShaped
          ? 'pipeline secret name present on a fork-shaped build — host did not withhold injection'
          : 'pipeline secret name present on a zero-injection probe step — host mapped secrets to a probe key',
      });
    } else if (isSecretName(name) && !OPERATIONAL_ALLOW.has(name)) {
      hits.push({
        path: '(env)',
        line: 0,
        kinds: ['unexpected-secret-name'],
        name,
        why: 'secret-named env var outside the operational allowlist; extend ABSENCE_PROBE_ENV_ALLOW if legitimate',
      });
    }
  }

  if (forkExtension) {
    hits.push({
      path: '(env)',
      line: 0,
      kinds: ['fork-allowlist-extension'],
      name: '(withheld)',
      why: 'nonempty ABSENCE_PROBE_ENV_ALLOW on a fork-shaped build — extension ignored and flagged; the watched party must not mute its watcher',
    });
  }

  const verdict = hits.length > 0 ? 'FLAG' : 'PASS';
  const receipt = {
    probe: 'absence-env',
    verdict,
    fork_shaped: forkShaped,
    // Env population: NAME families only; value shapes live in files/logs.
    families: {
      'secret-value': false,
      'secret-assignment': false,
      'secret-name': true,
      'nda-term': false,
      'nda-pattern': false,
    },
    env_names: names,
    allowlist: [...OPERATIONAL_ALLOW].sort(),
    forbidden: [...FORBIDDEN_ALWAYS],
    hits,
    notes,
  };
  const human = verdict === 'PASS'
    ? `absence-env: PASS — ${names.length} env name(s) enumerated, zero injection confirmed${forkShaped ? ' (fork-shaped build)' : ''}`
    : `absence-env: FLAG — ${hits.length} unexpected secret env name(s) (names only, see receipt)`;
  process.stderr.write(`${human}\n`);
  emitReceipt(receipt, { annotateContext: 'absence-env' });
  return verdict === 'PASS' ? 0 : 1;
}

try {
  process.exit(main(process.argv.slice(2), process.env));
} catch (err) {
  process.stderr.write(`absence-env: ERROR — ${err.message}\n`);
  emitReceipt({
    probe: 'absence-env',
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
