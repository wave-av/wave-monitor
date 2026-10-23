// absence-scanner.mjs — self-contained secret-KIND scanner for the R2 fork-build
// absence probes (WAVE-26519, epic WAVE-26503).
//
// VENDORED, zero dependencies, no cross-repo imports: probes execute from
// base-pinned code on CI agents where only this checkout exists, so the
// detector tables are copied IN from:
//   - hookcli/lib/board-redact.mjs (SECRET_RE name table, SECRET_VALUE_RES)
//   - governance/lib/rl-corpus-detectors.mjs (assignment/key composition)
//   - governance/lib/rl-corpus-write.mjs (the 5 inspector families)
//   - hooks/data/public-write-denylist.json static_patterns (shape-only subset)
//   - scripts/public-repo-guard/content-policy.sh (WAVE KIND shapes, same repo)
// Sync date 2026-10-20. On upstream change: re-vendor + re-run the self-scan
// test. Never import across repos at probe runtime.
//
// DELIBERATE OMISSIONS (documented, reversible):
// - nda-term needs a runtime terms file; without one the family reports
//   unscanned (fail-closed in enforcing mode; see the probe CLIs).
// - Prose-phrasing static patterns (NDA phrasing, partner framing, briefing
//   references, internal-only markers) are NOT vendored: they are tuned for
//   the corpus-record population and false-positive on repo trees that
//   document their own confidentiality machinery. Shapes only here.
// - Static patterns embedding private identifiers (repo names, hostnames, user
//   names) are NOT vendored: this repo is public and must not carry them. A
//   host-provided terms file covers them at runtime (see PROMOTION.md).
//
// OUTPUT DISCIPLINE: violations carry path + line + KIND only. Never the
// matched text, never a substring, never a length. The colocated test
// self-scans these probe files to prove the committed tree stays clean.

import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, basename, relative, resolve } from 'node:path';

// --- Family 1-3 tables (vendored from board-redact.mjs + rl-corpus-detectors.mjs)

const SECRET_NAME_ALTS =
  '(_KEY|_TOKEN|_SECRET|_PASSWORD|PRIVATE_KEY|ACCESS_KEY|_DSN|PASSWD|' +
  'SERVICE_ROLE|TOKEN|SECRET|PASSWORD|APIKEY|CREDENTIAL|CREDS)';

// Live credential VALUE shapes. Unanchored/anchored exactly as upstream; the
// comments there explain each choice. Order is the upstream order.
const SECRET_VALUE_RES = [
  /(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}/,
  /github_pat_[A-Za-z0-9_]{60,}/,
  /(^|[^A-Za-z0-9])sk-(ant-|proj-)?[A-Za-z0-9_-]{24,}/,
  /xox[baprs]-[A-Za-z0-9-]{10,}/,
  /AKIA[0-9A-Z]{16}/,
  /(^|[^A-Za-z0-9])re_[A-Za-z0-9]{20,}/,
  /dp\.(pt|st|sa)\.[A-Za-z0-9]{20,}/,
  /AIza[0-9A-Za-z_-]{35}/,
  /(sk|rk)_live_[A-Za-z0-9]{20,}/,
  /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]*(service_role)[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{10,}/,
  /npm_[A-Za-z0-9]{36}/,
];

// Secret-named variable ASSIGNED a credential-looking value. Ported from
// rl-corpus-detectors.mjs: same three-branch value discriminator (= and quoted
// values use the full discriminator; unquoted colon-prose only the long
// separator-free run; pure numbers read as numbers).
const SECRET_ALTS_INNER = SECRET_NAME_ALTS.replace(/^\(/, '').replace(/\)$/, '');
const NOT_PURE_NUMBER = '(?!\\d+(?![^\\s"\']))';
const VALUE_DIGIT = `${NOT_PURE_NUMBER}[^\\s"']*[0-9][^\\s"']*`;
const VALUE_LONG_RUN = "[^\\s\"']{20,}";
const VALUE_BARE_WORD = "[^\\s\"'_-]{8,}(?![^\\s\"'])";
const VALUE_ASSIGNED = `(?:${VALUE_DIGIT}|${VALUE_LONG_RUN}|${VALUE_BARE_WORD})`;
const VALUE_UNQUOTED_COLON = "[^\\s\"':/\\\\._-]{20,}";
const SECRET_ASSIGNMENT_RE = new RegExp(
  `(${SECRET_ALTS_INNER})["'\\s]*(?:=\\s*["']?${VALUE_ASSIGNED}|:\\s*(?:["']${VALUE_ASSIGNED}|${VALUE_UNQUOTED_COLON}))`,
  'i',
);

// Secret-NAMED key: same composition as upstream — end-anchored, with the
// TOKEN family strict (counting-sense exemption) and a bounded holding
// qualifier for every other designator, plus the TOKEN-holder plural split.
const HOLDING_QUALIFIER =
  '(?:S|_ID|_IDS|_HASH|_DIGEST|_REF|_ARN|_LAST4|_FINGERPRINT|_EXPIRES(?:_AT)?)?';
const TOKEN_HOLDER_PREFIX = '(?:API|ACCESS|REFRESH|AUTH|OAUTH|SESSION|BEARER)';
const KEY_ALTS = SECRET_ALTS_INNER.split('|')
  .map((alt) =>
    /TOKEN/i.test(alt)
      ? `(?:${TOKEN_HOLDER_PREFIX}${alt}S|${alt})`
      : `${alt}${HOLDING_QUALIFIER}`,
  )
  .join('|');
const SECRET_KEY_RE = new RegExp(`(?:${KEY_ALTS})$`, 'i');

// --- Family 5: nda-pattern (shape-precise subset; see header for omissions)
//
// WAVE shapes mirror scripts/public-repo-guard/content-policy.sh rule for
// rule (same-repo lockstep; L1 lint cross-checks). The credential-shape entry
// is the static "Credential-shaped token" alternation. Personal-email keeps
// the provider-shape alternative only (no identifiers vendored).

const NDA_PATTERNS = [
  ['stripe-account', /acct_[A-Za-z0-9]{16,}/],
  ['stripe-live-key', /(sk|rk)_live_[A-Za-z0-9]{16,}/],
  ['stripe-object', /(cus|sub|price|prod)_[A-Za-z0-9]{14,}/],
  ['cf-account-id', /account_id\s*[:=]\s*["']?[0-9a-f]{32}/],
  ['internal-ip', /100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}/],
  ['abs-user-path', /\/(Users|home)\/(?!runner\/)[a-z][a-z0-9._-]+\//],
  ['anthropic-key', /sk-ant-(api|admin)[0-9]{2}-[A-Za-z0-9_-]{20,}/],
  ['github-pat', /github_pat_[A-Za-z0-9_]{30,}/],
  ['supabase-pat', /sbp_[a-f0-9]{40}/],
  ['aws-akid', /AKIA[0-9A-Z]{16}/],
  ['private-key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['personal-email-provider',
    /[\w.+-]{1,64}@(?:gmail|googlemail|icloud|hotmail|outlook|live|yahoo|proton|protonmail|pm)\.(?:com|me|ch)\b/],
  ['credential-shape',
    /(?:\b(?:sk|pk|rk)_(?:live|test|prod)_[A-Za-z0-9]{16,}|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}|\bdp\.(?:st|pt|ct|sa)\.[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b|\bxox[abprs]-[A-Za-z0-9-]{20,}|\bsbp_[a-f0-9]{30,}|\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)/],
];

// Assignment left-hand side: `NAME=`, `export NAME=`, `NAME: value` in data
// files. Tested against SECRET_KEY_RE for the secret-name family.
const ASSIGNMENT_LHS_RE =
  /^\s*(?:export\s+|const\s+|let\s+|var\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[=:]/;

export function normalizeTerms(terms) {
  return (Array.isArray(terms) ? terms : [])
    .map((t) => String(t ?? '').trim().toLowerCase())
    .filter(Boolean);
}

// Fork-shaped per the governance-enforce.sh:28-33 rule: the PR head repo
// differs from the pipeline repo. Absent PR vars (non-PR build) read as
// not-fork-shaped; the probes note that residual explicitly.
export function isForkShaped(env = process.env) {
  const head = env.BUILDKITE_PULL_REQUEST_REPO ?? '';
  const pipe = env.BUILDKITE_REPO ?? '';
  return head !== '' && pipe !== '' && head !== pipe;
}

// Classify one identifier (env var name, assignment LHS) for the
// secret-name family. Pure; used by probe-env and the file walker.
export function isSecretName(name) {
  return SECRET_KEY_RE.test(String(name ?? ''));
}

// Scan one text line. Returns the sorted KIND list (no excerpts, ever).
// `terms` must already be normalized; empty terms disable nda-term.
//
// POPULATION SCOPING (measured on this repo 2026-10-20, not reasoned):
// secret-assignment and secret-name are tuned for flat namespaces (env vars,
// record keys). On file trees they flag ordinary code — `apiKey: key`,
// `NODE_AUTH_TOKEN: ${{ secrets.X }}`, `const token = ...` — every one a
// false positive. A boundary that flags ordinary code is one somebody
// switches off, so file scans run the VALUE-shape families only
// (secret-value, nda-term, nda-pattern) while probe-env keeps the NAME
// families where they belong. fileMode selects the file population.
export function scanLine(line, { terms = [], fileMode = false } = {}) {
  const kinds = new Set();
  const text = String(line ?? '');
  if (text === '') return [];
  if (SECRET_VALUE_RES.some((re) => re.test(text))) kinds.add('secret-value');
  if (!fileMode && SECRET_ASSIGNMENT_RE.test(text)) kinds.add('secret-assignment');
  if (!fileMode) {
    const lhs = text.match(ASSIGNMENT_LHS_RE);
    if (lhs && isSecretName(lhs[1])) kinds.add('secret-name');
  }
  if (terms.length > 0) {
    const lower = text.toLowerCase();
    if (terms.some((t) => lower.includes(t))) kinds.add('nda-term');
  }
  for (const [sub, re] of NDA_PATTERNS) {
    if (re.test(text)) kinds.add(`nda-pattern/${sub}`);
  }
  return [...kinds].sort();
}

// Basename rule mirroring content-policy.sh committed-dotenv: real dotenv
// files (not templates) are a finding by NAME, never by content.
export function isCommittedDotenv(filePath) {
  const base = basename(String(filePath ?? ''));
  if (base !== '.env' && !base.startsWith('.env.')) return false;
  return !/\.(example|sample|template|dist)$/.test(base);
}

export const DEFAULT_SKIP_DIRS = new Set(['.git', 'node_modules']);
// Basenames skipped as FILES too: a worktree `.git` is a file (gitlink),
// and the guard's own scripts necessarily document leak shapes —
// content-policy.sh applies the same exclusion to itself.
export const DEFAULT_SKIP_FILES = new Set(['.git']);
// Root-relative exact detector-docs paths (committed, review-conspicuous).
// Narrow by construction: a fork hiding files here must touch guard-owned
// paths (visible in review + CODEOWNERS); base-pinned execution (PROMOTION
// P1) removes even that residual by scanning the trusted tree.
export const DEFAULT_SKIP_PATH_DIRS = new Set([
  'scripts/public-repo-guard',
  'rig/config-current/scripts/public-repo-guard',
  'rig/config-patched/scripts/public-repo-guard',
]);
export const DEFAULT_MAX_BYTES = 1024 * 1024;

// Recursively collect files under root. Skips DEFAULT_SKIP_DIRS (+ extra),
// counts skips by reason. Throws on an unreadable ROOT (fail closed); an
// unreadable child is recorded and rethrown at the end so one bad entry
// cannot silently narrow the scan.
export function collectFiles(root, { skipDirs = DEFAULT_SKIP_DIRS, onSkip = null } = {}) {
  const files = [];
  const errors = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      errors.push({ path: dir, reason: `unreadable directory: ${err.code ?? 'error'}` });
      return;
    }
    for (const ent of entries) {
      const full = join(dir, ent.name);
      // Detector-docs exclusion is ROOT-RELATIVE EXACT (review finding, PR
      // #124): a bare segment match at any depth would let a fork hide files
      // under an unrelated */public-repo-guard/ directory.
      const rel = relative(root, full).split('\\').join('/');
      if ([...DEFAULT_SKIP_PATH_DIRS].some((p) => rel === p || rel.startsWith(`${p}/`))) {
        onSkip?.({ path: full, reason: 'detector-docs-excluded' });
        continue;
      }
      if (ent.isDirectory()) {
        if (skipDirs.has(ent.name)) {
          onSkip?.({ path: full, reason: 'excluded-dir' });
          continue;
        }
        walk(full);
      } else if (ent.isFile()) {
        // .git FILE skip is root-level only (worktree gitlink). A nested .git
        // file is scanned — fail closed rather than trust the basename.
        if (DEFAULT_SKIP_FILES.has(ent.name) && dir === root) {
          onSkip?.({ path: full, reason: 'excluded-file' });
          continue;
        }
        files.push(full);
      } else {
        onSkip?.({ path: full, reason: 'not-a-regular-file' });
      }
    }
  };
  let st;
  try {
    st = statSync(root);
  } catch (err) {
    throw new Error(`scan root unreadable: ${root} (${err.code ?? 'error'})`);
  }
  if (!st.isDirectory()) return [root];
  walk(root);
  if (errors.length > 0) {
    const err = new Error(
      `scan incomplete under ${root}: ${errors.length} unreadable director(ies)`,
    );
    err.incomplete = errors;
    throw err;
  }
  return files;
}

// Scan one file. Returns { path, hits, skipped }. Binary-safe: NUL bytes do
// not break the scan. Files over maxBytes are SKIPPED and counted (a counted,
// documented exclusion — see PROMOTION.md residual), never silently passed.
export function scanFile(path, { terms = [], maxBytes = DEFAULT_MAX_BYTES, fileMode = true } = {}) {
  let st;
  try {
    st = statSync(path);
  } catch (err) {
    return { path, hits: [], skipped: `unreadable (${err.code ?? 'error'})` };
  }
  if (!st.isFile()) return { path, hits: [], skipped: 'not-a-regular-file' };
  if (st.size > maxBytes) return { path, hits: [], skipped: `over-size-cap (${st.size} bytes)` };
  let content;
  try {
    content = readFileSync(path, 'utf8');
  } catch (err) {
    return { path, hits: [], skipped: `unreadable (${err.code ?? 'error'})` };
  }
  const hits = [];
  if (isCommittedDotenv(path)) hits.push({ line: 0, kinds: ['nda-pattern/committed-dotenv'] });
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const kinds = scanLine(lines[i], { terms, fileMode });
    if (kinds.length > 0) hits.push({ line: i + 1, kinds });
  }
  return { path, hits, skipped: null };
}

// Scan roots. Returns the shared receipt-body fragment: families report,
// per-file hits (path + line + KIND only), and counted exclusions.
export function scanRoots(roots, { terms = [], maxBytes = DEFAULT_MAX_BYTES } = {}) {
  const normTerms = normalizeTerms(terms);
  // File population: value-shape families only (see scanLine scoping note).
  // The NAME families read false here and are covered by probe-env instead.
  const families = {
    'secret-value': true,
    'secret-assignment': false,
    'secret-name': false,
    'nda-term': normTerms.length > 0,
    'nda-pattern': true,
  };
  const hits = [];
  const excluded = [];
  const scannedRoots = [];
  let filesScanned = 0;
  for (const root of roots) {
    let files;
    try {
      files = collectFiles(root, { onSkip: (s) => excluded.push(s) });
    } catch (err) {
      throw new Error(`scan failed for root ${root}: ${err.message}`);
    }
    scannedRoots.push({ root, files: files.length });
    for (const f of files) {
      const r = scanFile(f, { terms: normTerms, maxBytes });
      if (r.skipped) {
        excluded.push({ path: f, reason: r.skipped });
        continue;
      }
      filesScanned += 1;
      for (const h of r.hits) hits.push({ path: f, line: h.line, kinds: h.kinds });
    }
  }
  return { families, hits, excluded, scannedRoots, filesScanned };
}

// Fork-build input guard (review finding, PR #124): explicit scan roots come
// from env/CLI, which a fork PR can set via pipeline.yml env. On fork-shaped
// builds every root must resolve inside one of the probe's own default roots
// (checkout / tmp / npm-cache); anything else is a configuration ERROR, never
// a silent scan of host paths. Trusted and local runs are unconstrained.
export function assertRootsAllowed(roots, allowedRoots) {
  const allowed = allowedRoots.map((r) => `${resolve(r)}/`);
  for (const root of roots) {
    const resolved = resolve(root);
    if (!allowed.some((a) => resolved === a.slice(0, -1) || resolved.startsWith(a))) {
      throw new Error(`scan root outside allowed roots on fork-shaped build: ${root}`);
    }
  }
}

// Load a terms file (one term per line). Fail-closed: missing/unreadable/
// empty reads as an ERROR at the call site, never as "no terms matched".
// The returned terms are normalized; the raw file is never echoed.
export function loadTermsFile(path) {
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (err) {
    throw new Error(`terms file unreadable at ${path} (${err.code ?? 'error'})`);
  }
  const terms = normalizeTerms(raw.split('\n'));
  if (terms.length === 0) {
    throw new Error(`terms file at ${path} holds zero effective terms — refusing to scan uncovered`);
  }
  return terms;
}

// Emit the machine receipt: one JSON document to stdout (and optionally to
// ABSENCE_PROBE_JSON path). Best-effort Buildkite annotation when the agent
// binary is present; annotation failures never change the verdict.
export function emitReceipt(receipt, { annotateContext = null } = {}) {
  const doc = JSON.stringify({ version: 1, ...receipt }, null, 2);
  process.stdout.write(`${doc}\n`);
  const jsonPath = process.env.ABSENCE_PROBE_JSON ?? '';
  if (jsonPath !== '') {
    try {
      writeFileSync(jsonPath, `${doc}\n`);
    } catch {
      // Receipt-file write is auxiliary; stdout already carries the receipt.
    }
  }
  if (annotateContext) tryAnnotate(annotateContext, receipt);
}

function tryAnnotate(context, receipt) {
  try {
    const lines = [
      `### absence probe ${receipt.probe}: ${receipt.verdict}`,
      '',
      `- fork-shaped: ${receipt.fork_shaped}`,
      `- hits: ${receipt.hits?.length ?? 0} (paths + KINDs only, see job log)`,
    ];
    for (const h of (receipt.hits ?? []).slice(0, 20)) {
      lines.push(`- \`${h.path}:${h.line}\` [${h.kinds.join(', ')}]`);
    }
    if ((receipt.hits ?? []).length > 20) lines.push('- …(truncated to 20)');
    spawnSync('buildkite-agent', ['annotate', '--style', receipt.verdict === 'PASS' ? 'success' : 'warning', '--context', context], {
      input: `${lines.join('\n')}\n`,
      stdio: ['pipe', 'ignore', 'ignore'],
      timeout: 10000,
    });
  } catch {
    // Annotations are auxiliary; the receipt on stdout is authoritative.
  }
}

// Minimal argv parser shared by the probes: --key value and --flag. CI steps
// pass NO arguments (no-command-eval), so every option also has an env var;
// argv wins when given (local runs, R1 rig).
export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2).replace(/-/g, '_');
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}
