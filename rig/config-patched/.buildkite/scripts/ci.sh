#!/usr/bin/env bash
# wave-monitor CI gate (Buildkite, fpc-isolated): typecheck + lint + unit tests.
# Checked-in script because the fpc-isolated agents run with no-command-eval.
set -euo pipefail
cd "$(dirname "$0")/../.."
npm ci --no-audit --no-fund
npm run type-check
npm run lint
npm test
