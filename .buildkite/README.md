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

`lib/common.sh` is vendored from a sibling repo's shadow port (draft PR,
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
| `secrets-content-policy` | `secrets-content-policy.sh` | `public-repo-guard.yml` job `guard` | `Secrets + content policy` | `GUARD_PRIVATE_REPOS` |

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
private-repo-name rule. On Buildkite, the `secrets-content-policy` step declares
`secrets: [GUARD_PRIVATE_REPOS]` in `pipeline.yml`, which exports the Buildkite cluster secret of
that name into the step's job env (Buildkite redacts it from build logs if it is ever printed).
`secrets-content-policy.sh` does not set or fabricate this variable — it simply doesn't touch it, so
whatever the cluster secret's value is flows through to `content-policy.sh` unchanged.

**This requires the cluster secret to exist, not merely be unset.** The Buildkite agent fetches every
key named in a step's `secrets:` list before the step's command runs at all; a key that does not
exist in the cluster fails that fetch and the job never starts (`secrets-content-policy.sh` never
runs, so its own "unset → skip the rule" fallback never gets a chance to apply). That differs from
the GH Actions variable, which really can be left undefined. To get the GH-equivalent behavior on
Buildkite ("rule skipped"), the cluster secret must exist with an **empty string** value — not be
absent. See "Operator steps needed" below.

**Same-repo PR builds receive this secret.** This pipeline builds pushes and same-repo (non-fork)
pull requests; fork PRs never get a Buildkite agent at all (see "Fork-PR gap" below), so only
contributors who can push a branch in `wave-av/wave-monitor` can trigger a build that sees
`GUARD_PRIVATE_REPOS`. That is the same trust boundary every other step on this queue already
operates under — this secret does not widen it. It is also a low-sensitivity value: GitHub itself
stores the equivalent as a plain, unmasked Actions **variable**, not a secret, so step-scoped
injection plus automatic log redaction here is already stricter than the GH baseline. Restricting
the secret to protected-branch-only builds was considered and rejected: this step's job is to scan
each PR's own content for policy violations, including a PR that edits the step itself — running it
only from a trusted ref would defeat that purpose.

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
3. **Provision an agent on queue `fpc-isolated` running Buildkite Agent v3.106.0 or later** — the
   minimum version that supports the pipeline-YAML `secrets:` attribute `secrets-content-policy` now
   declares (<https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets>) — matching the
   guest-image prerequisites above, or confirm an existing `fpc-isolated` agent satisfies both.
4. **Create a Buildkite cluster secret named `GUARD_PRIVATE_REPOS`** (org `wave`, cluster
   "WAVE self-hosted CI") holding the same comma- or space-separated value as GitHub
   `vars.GUARD_PRIVATE_REPOS`. The `secrets-content-policy` step's `secrets: [GUARD_PRIVATE_REPOS]`
   attribute in `pipeline.yml` exports that cluster secret as the `GUARD_PRIVATE_REPOS` env var for
   that step only. **The secret must exist** — Buildkite fails the job at startup if a declared
   `secrets:` key is missing, before `secrets-content-policy.sh` ever runs. Set its value to an empty
   string only when the GitHub variable is empty; a deleted/never-created key is not the same thing
   and will break the step, not silently skip the private-repo-name rule. Never set this via a literal
   value in `pipeline.yml` or a committed script — baking the list into a public repo's tree would
   itself be exactly the leak `content-policy.sh` exists to catch.
5. **Observe a green build** on this branch/PR for both `gate-checks` and `secrets-content-policy`,
   posting `buildkite/<pipeline-slug>/gate-checks` and `buildkite/<pipeline-slug>/secrets-content-policy`.
6. After a green soak, **switch the required GitHub status checks** in branch protection from
   `gate / checks` / `Secrets + content policy` to the two `buildkite/...` contexts above. That edit
   is out of scope for this PR and must be done explicitly by an operator with repo admin access.

   **Fork-PR gap this swap opens.** This port does not enable "Build pull requests from forks" on the
   Buildkite pipeline, so an external fork PR never gets a Buildkite agent (secrets/agent safety beats
   convenience here — a fork PR's branch content is attacker-controlled) and never posts
   `buildkite/<pipeline-slug>/gate-checks` or `buildkite/<pipeline-slug>/secrets-content-policy`. Once
   step 6 makes those contexts required, a fork PR has no automatic producer for them and sits
   permanently un-mergeable, even though the shadowed GH Actions checks (which do run on fork PRs)
   would have passed. GitHub branch protection requires every listed context, so there is no
   required-status "OR" — leaving a GH check required alongside the Buildkite ones does not give forks
   a way through. A fork PR only gets real coverage once a maintainer re-pushes its branch/commit into
   `wave-av/wave-monitor` (e.g. `git push` to a same-repo branch, or `gh pr checkout` + repush) or
   triggers a Buildkite build for that commit manually. An operator making this swap must accept that
   gap or keep it in mind for fork-originated contributions. (Same gap independently documented on the
   sibling `wave-av/sdk` shadow port, PR #152.)

## Exit criterion for the soak

Buildkite `gate-checks` and `secrets-content-policy` run green alongside GH `_checks.yml` (`checks`
job) and `public-repo-guard.yml` (`guard` job) for a soak period on `main` and open PRs. After that,
the required-context swap is a separate, operator-gated branch-protection change.
