# wave-monitor on Buildkite (shadow mode)

This directory ports wave-monitor's two REQUIRED GitHub commit-status contexts to Buildkite. The
steps run on self-hosted `fpc-isolated` agents, each inside a disposable, isolated guest.

**The GH workflows stay untouched until Buildkite has been green for a soak period.** Nothing under
`.github/` changes in this port. The GH checks remain the required checks. Buildkite statuses are
informational until an operator swaps the required contexts, which is a separate, operator-gated
branch-protection change.

## Layout

| path | role |
|---|---|
| `pipeline.yml` | Two parallel command steps, `agents.queue: fpc-isolated` at the pipeline level. |
| `steps/<step>.sh` | One checked-in script per step. `command:` is only ever a script path, compatible with agent `no-command-eval`. |
| `lib/common.sh` | Strict mode, log groups, a job-local temp dir cleaned on exit, and the multi-gate runner/summary used by both step scripts. |

`lib/common.sh` is vendored from wave-av/wave-gateway's shadow port (draft PR #1928,
`feat/buildkite-ci`) by way of wave-av/wave-opencode's port (draft PR #222). wave-monitor is a
**public** repo and wave-foundation's "Buildkite template v0" (PR #1570, common.sh + npm-install.sh
+ pipeline.example.yml) lives in a **private** repo, so it is vendored here rather than referenced
cross-repo — the same way `.github/workflows/_checks.yml` is already a vendored copy in this repo
rather than a live `uses: wave-av/wave-foundation/...@master` reference. `lib/npm-install.sh` is
**not** vendored: neither step in this pipeline runs `npm install` or needs a credential.

## What is ported

| step key | script | shadows (GH workflow / job) | GitHub required context | needs secret |
|---|---|---|---|---|
| `gate-checks` | `checks.sh` | `_checks.yml` job `checks` | `gate / checks` | none |
| `secrets-content-policy` | `secrets-content-policy.sh` | `public-repo-guard.yml` job `guard` | `Secrets + content policy` | none |

Once a Buildkite pipeline is created for this repo with slug `<pipeline-slug>` (the operator names
it at creation; a natural choice is `wave-monitor`), these steps post GitHub commit statuses at:

- `buildkite/<pipeline-slug>/gate-checks`
- `buildkite/<pipeline-slug>/secrets-content-policy`

Those are new, additional statuses — informational only in shadow mode. They do not replace
`gate / checks` or `Secrets + content policy` until an operator explicitly edits branch protection.

### `gate-checks` (shadows `gate / checks`)

Byte-faithful copy of `_checks.yml`'s `checks` job body:
1. **Secret scan** — the same `grep -rIEn` regex, the same `--exclude-dir` set, the same
   `.github/.secret-allowlist` handling, and the same `# ... allowlist secret` line-level skip.
2. **File-size gate** — `git ls-files '*.ts' '*.tsx' '*.js' '*.py'` (excluding `.types.ts` /
   `.d.ts`), `wc -l` per file, fails any file over `MAX` (env `MAX_LINES`, default 800, matching the
   workflow's `inputs.max_lines` default), honoring `.github/.filesize-allowlist`.

This repo's `_checks.yml` also runs `skill-validate` and `verify-routes` jobs, but those are not
named as required GitHub contexts (only `gate / checks` is), so they are out of scope for this port.

### `secrets-content-policy` (shadows `Secrets + content policy`)

Byte-faithful copy of `public-repo-guard.yml`'s `guard` job:
1. **gitleaks 8.30.1**, installed from the same pinned release URL and verified against the same
   SHA-256 the workflow checks
   (`551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`), then run as
   `gitleaks detect --no-git --source . --config .gitleaks.toml --redact --no-banner --exit-code 1`.
2. **`bash scripts/public-repo-guard/content-policy.sh .`** (installs ripgrep if the guest image
   lacks it, matching the workflow's `apt-get install ripgrep` fallback).

`.gitleaks.toml` and `scripts/public-repo-guard/content-policy.sh` are already vendored into this
repo by the existing GitHub workflow — this port adds no new copy of either, only the Buildkite-side
install + invocation.

**`GUARD_PRIVATE_REPOS`**: the workflow reads this from the org/repo Actions variable
`vars.GUARD_PRIVATE_REPOS`. When unset there, GitHub still passes an *empty string* into the job
env, and `content-policy.sh`'s `[[ -n "${GUARD_PRIVATE_REPOS:-}" ]]` check then skips the
private-repo-name rule. `secrets-content-policy.sh` does not set or fabricate this variable — it
simply doesn't touch it, so whatever the Buildkite agent environment provides (or doesn't) flows
through to `content-policy.sh` unchanged. An operator who wants parity with the Actions variable
should export `GUARD_PRIVATE_REPOS` from the agent environment hook for this pipeline; absent that,
behavior matches the unset-Actions-variable case (rule skipped), which is also today's default on a
repo with no such variable configured.

## Differences from GH, on purpose

- **Two steps, not one job with two steps.** GitHub's `guard` job runs gitleaks and content-policy
  as sequential steps inside one job; here they are sequential *commands inside one script*
  (`secrets-content-policy.sh`), same as the workflow's ordering (gitleaks first, then ripgrep +
  content-policy), so a gitleaks failure is reported before content-policy runs, exactly as on GH.
- **gitleaks install target.** The workflow always has `sudo` (GitHub-hosted runner, `ubuntu-latest`).
  `secrets-content-policy.sh` installs to `/usr/local/bin` directly when already writable or running
  as root (the common case for a disposable fpc-isolated guest), falling back to `sudo` if present,
  and fails loudly if neither is available — never silently skips the install.
- **No `caps-lint` bootstrap step in this PR.** wave-opencode's port (#222) has the operator paste a
  host-provisioned caps-lint bootstrap step into the Buildkite UI before this pipeline can be
  uploaded. That is a Buildkite pipeline **setting**, not a file in this repo, so it is called out
  in "Operator steps" below rather than committed here.
- **Secret-scan hit reporting is redacted (CWE-532), unlike `_checks.yml`.** The GH Actions original
  prints the full matching line — which, for a true positive, is the credential itself — into the
  job log. `checks.sh` prints only `path:line` (via `cut -d: -f1,2`) plus a generic message, never
  the matched text, before failing with the same exit code. This is an intentional, narrow
  divergence from "byte-faithful": detection (regex, exclude-dirs, allowlist handling) is unchanged,
  only the report line differs. The GitHub Actions `_checks.yml` original carries the same exposure
  today; fixing that is a follow-up for wave-foundation's source `checks.yml`, not something changed
  by this PR.

## Guest-image prerequisites

- `bash`, `git`, `grep`, `wc` (POSIX toolchain — present on any Linux guest).
- `curl`, `sha256sum`, `tar` (gitleaks install).
- `ripgrep` (`rg`) — `secrets-content-policy.sh` installs it via `apt-get` if missing, same fallback
  as the workflow.
- **Egress:** `github.com` (to download the pinned gitleaks release tarball). Neither step needs
  `registry.npmjs.org`, Doppler, a model provider, or a production host.
- No sudo is required if the guest image already runs as root or `/usr/local/bin` is writable; a
  writable `/usr/local/bin` (or root) is otherwise a guest-image prerequisite.

## Credentials

Neither step needs a credential. `gate-checks` is a local grep/git scan. `secrets-content-policy`
downloads a public, pinned, checksum-verified release tarball over anonymous HTTPS and scans the
checked-out tree; it holds no token, no Doppler identity, and no Cloudflare credential.

## Run locally

From the repo root, with `rg` on `PATH` (gitleaks is downloaded by the script itself):

```sh
.buildkite/steps/checks.sh
.buildkite/steps/secrets-content-policy.sh
```

Both scripts are idempotent and safe to re-run; `secrets-content-policy.sh` re-downloads and
re-verifies gitleaks into a fresh job-local temp dir on every run rather than trusting a prior
install.

## Pipeline settings (Buildkite UI, not YAML) — operator steps still needed

1. **Create the Buildkite pipeline** for `wave-av/wave-monitor`, uploading `.buildkite/pipeline.yml`
   (directly, or via a bootstrap step, following the fleet's existing pattern).
2. **Connect the GitHub App** for this repository so Buildkite can post commit statuses and trigger
   on push / pull_request. Connecting the app by itself only establishes Buildkite's **pipeline-level**
   default status (`buildkite/<pipeline-slug>`) — it does **not** by itself produce the two per-step
   contexts this README documents. In the pipeline's **Settings → GitHub** page (or via the REST API's
   `provider_settings`, below), enable all three:
   - `publish_commit_status` (UI: **Update commit statuses**) — Buildkite publishes any GitHub status
     at all.
   - `publish_commit_status_per_step` (UI: **Create a status for each job**) — a separate status is
     published per job instead of one pipeline-level status.
   - `use_step_key_as_commit_status` — each job's context uses its `key:` (`gate-checks`,
     `secrets-content-policy`) instead of its emoji `label:`, producing exactly
     `buildkite/<pipeline-slug>/gate-checks` and `buildkite/<pipeline-slug>/secrets-content-policy` —
     the contexts named throughout this README.

   Copy-pasteable `provider_settings` block for the pipelines REST API
   (`POST/PATCH https://api.buildkite.com/v2/organizations/{org}/pipelines[/{pipeline}]`):

   ```json
   {
     "provider_settings": {
       "publish_commit_status": true,
       "publish_commit_status_per_step": true,
       "use_step_key_as_commit_status": true
     }
   }
   ```

   Source: Buildkite's GitHub source-control docs
   (<https://buildkite.com/docs/pipelines/source-control/github>, "Customizing commit statuses") and
   the pipelines REST API reference (<https://buildkite.com/docs/apis/rest-api/pipelines>,
   `provider_settings`).
3. **Provision an agent on queue `fpc-isolated`** matching the guest-image prerequisites above (or
   confirm an existing `fpc-isolated` agent already satisfies them).
4. **Observe a green build** on this branch/PR for both `gate-checks` and `secrets-content-policy`,
   posting `buildkite/<pipeline-slug>/gate-checks` and `buildkite/<pipeline-slug>/secrets-content-policy`.
5. After a green soak, **switch the required GitHub status checks** in branch protection from
   `gate / checks` / `Secrets + content policy` to the two `buildkite/...` contexts above. That edit
   is out of scope for this PR and must be done explicitly by an operator with repo admin access.

## Exit criterion for the soak

Buildkite `gate-checks` and `secrets-content-policy` run green alongside GH `_checks.yml` (`checks`
job) and `public-repo-guard.yml` (`guard` job) for a soak period on `main` and open PRs. After that,
the required-context swap is a separate, operator-gated branch-protection change.
