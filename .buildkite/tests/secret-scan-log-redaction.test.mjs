// secret-scan-log-redaction.test.mjs — the public GitHub Actions secret
// scan must not reprint match bodies (file:line is enough; the value is
// the thing the gate exists to keep out of world-readable logs).
//
// Run: `npx vitest run .buildkite/tests/secret-scan-log-redaction.test.mjs`

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CHECKS = join(ROOT, '.github', 'workflows', '_checks.yml');
const BK_SCAN = join(ROOT, '.buildkite', 'scripts', 'foundation-secret-scan.sh');

describe('secret-scan log redaction', () => {
  it('GitHub Actions secret-scan step does not echo grep match bodies', () => {
    const yaml = readFileSync(CHECKS, 'utf8');
    // Strip comments so a warning like "do not print the capture" cannot
    // satisfy or trip the assertion. The capture is traditionally
    // HITS=...; echoing it reprints the credential onto the public
    // Actions log. File:line (or a generic failure) is the allowed
    // failure output.
    const commands = yaml
      .split('\n')
      .filter((line) => !line.trim().startsWith('#'))
      .join('\n');
    expect(commands).not.toMatch(/echo\s+"\$HITS"/);
    expect(commands).not.toMatch(/echo\s+\$HITS\b/);
    expect(commands).not.toMatch(/echo\s+"\$\{HITS\}"/);
  });

  it('Buildkite foundation-secret-scan does not print the match file', () => {
    const sh = readFileSync(BK_SCAN, 'utf8');
    expect(sh).toMatch(/match CONTENT is never printed/);
    expect(sh).not.toMatch(/echo\s+"\$\(cat\s+"\$SCAN_TMP"/);
    expect(sh).not.toMatch(/cat\s+"\$SCAN_TMP"/);
  });
});
