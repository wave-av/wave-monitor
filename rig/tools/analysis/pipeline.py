#!/usr/bin/env python3
"""RIG analysis: minimal Buildkite pipeline.yml parser + scheduler simulator.

Parses the subset this fleet uses (steps list with label/key/command/if/
agents.queue/depends_on, `wait` steps, retry blocks skipped as opaque).
Anything outside the subset -> PipelineError (fail closed: the rig reports
ERROR, never a false DENY).
"""
import json
import re
import sys

SECRET_QUEUE_SUBSTR = "secrets"


class PipelineError(Exception):
    pass


def _strip_comment(line):
    # Cut trailing ' #' comments (not inside quotes — good enough for our files;
    # fail closed via shape checks below if a value looks truncated).
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "#" and i > 0 and line[i - 1] in (" ", "\t"):
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def parse(pipeline_path):
    """Return {'steps': [...], 'order': [...]}.

    steps: list of dicts {key,label,command,queue,cond,depends_on(list),index}.
    order: list of ('step', key) or ('wait', None) in file order.
    """
    with open(pipeline_path) as f:
        raw = f.read().splitlines()
    steps, order = [], []
    cur, in_steps, parent4 = None, False, None
    pending = {}  # order position -> step index, for keyless head lines
    for ln, line in enumerate(raw, 1):
        s = _strip_comment(line)
        if not s.strip():
            continue
        ind = len(s) - len(s.lstrip(" "))
        if "\t" in s[:ind]:
            raise PipelineError(f"{pipeline_path}:{ln}: tab indent")
        txt = s.strip()
        if ind == 0:
            if txt.startswith("steps:"):
                in_steps = True
                continue
            if txt and not txt.startswith("#"):
                raise PipelineError(f"{pipeline_path}:{ln}: top-level key "
                                    f"outside subset: {txt[:40]}")
            continue
        if not in_steps:
            continue
        if ind == 2 and txt.startswith("- "):
            rest = txt[2:].strip()
            if rest == "wait" or rest.startswith("wait:") or rest.startswith("wait "):
                order.append(("wait", None))
                cur = None
                continue
            if rest.startswith("trigger:") or rest.startswith("block:") \
                    or rest.startswith("input:") or rest.startswith("group:"):
                raise PipelineError(f"{pipeline_path}:{ln}: gating-adjacent "
                                    f"step type outside subset: {rest[:20]}")
            m = re.match(r"(label|key|command)\s*:\s*(.+)$", rest)
            if not m:
                raise PipelineError(f"{pipeline_path}:{ln}: step head outside "
                                    f"subset: {rest[:40]}")
            cur = {"key": None, "label": None, "command": None, "queue": None,
                   "cond": None, "depends_on": [], "index": len(steps)}
            cur[m.group(1)] = m.group(2).strip().strip("'\"")
            steps.append(cur)
            if cur["key"]:
                order.append(("step", cur["key"]))
            else:
                # Positional placeholder (not a matchable string): a genuine
                # step key can never collide with it.
                pending[len(order)] = cur["index"]
                order.append(("step", None))
            parent4 = None
            continue
        if ind == 2 and txt == "-":
            raise PipelineError(f"{pipeline_path}:{ln}: bare list item")
        if cur is None:
            # Continuation lines of a wait step (e.g. `- wait: ~` has none, but
            # `depends_on` etc. under wait) — waits take no gating fields we
            # model; any sub-key is either benign or an error. Only allow
            # nothing: a 4-space key after wait with no current step is a shape
            # violation.
            raise PipelineError(f"{pipeline_path}:{ln}: orphan line: {txt[:40]}")
        if ind == 4 and txt.startswith("- "):
            raise PipelineError(f"{pipeline_path}:{ln}: unexpected list item")
        if ind == 4 and ":" in txt:
            k, v = txt.split(":", 1)
            k, v = k.strip(), v.strip().strip("'\"")
            parent4 = k
            if k == "agents":
                if v:
                    raise PipelineError(f"{pipeline_path}:{ln}: inline agents "
                                        f"mapping outside subset: {v[:40]}")
                continue
            if k in ("label", "key", "command"):
                cur[k] = v
                if k == "key":
                    # current step's order entry is always last here: only
                    # this step's own sub-keys can appear between its head
                    # line and this line.
                    order[-1] = ("step", v)
                continue
            if k == "if":
                cur["cond"] = v
                continue
            if k == "depends_on":
                if any(c in v for c in "{}:"):
                    # Inline/block dependency MAPS ({step: x}) carry gating
                    # meaning the string-list model cannot represent — fail
                    # closed rather than silently dropping the edge.
                    raise PipelineError(f"{pipeline_path}:{ln}: depends_on map "
                                        f"outside subset: {v[:40]}")
                if v.startswith("["):
                    cur["depends_on"] = [x.strip().strip("'\"")
                                         for x in v.strip("[]").split(",")
                                         if x.strip()]
                elif v:
                    cur["depends_on"] = [v]
                else:
                    cur["depends_on"] = []  # block list follows at indent 6
                continue
            if k in ("retry", "timeout_in_minutes", "agents"):
                continue  # opaque to gating
            raise PipelineError(f"{pipeline_path}:{ln}: step key outside "
                                f"subset: {k}")
        elif ind == 6:
            if parent4 == "agents" and ":" in txt:
                k = txt.split(":", 1)[0].strip()
                if k == "queue":
                    cur["queue"] = txt.split(":", 1)[1].strip().strip("'\"")
                    continue
                continue  # other agent targeting: opaque, non-gating
            if parent4 == "depends_on" and txt.startswith("- "):
                raise PipelineError(f"{pipeline_path}:{ln}: block-list "
                                    f"depends_on must be inline ([a, b])")
            continue  # retry/automatic/manual sub-trees: opaque
        elif ind > 6:
            continue  # deeper opaque sub-trees
        else:
            raise PipelineError(f"{pipeline_path}:{ln}: shape outside subset: "
                                f"{txt[:40]}")
    # resolve order placeholders for steps whose key came after the head line
    fixed = []
    for pos, (typ, ref) in enumerate(order):
        if pos in pending:
            fixed.append((typ, steps[pending[pos]]["key"]))
        else:
            fixed.append((typ, ref))
    for st in steps:
        if not st["key"]:
            raise PipelineError(f"{pipeline_path}: step {st['index']} has no key")
    return {"steps": steps, "order": fixed}


def secret_steps(parsed):
    return [s for s in parsed["steps"]
            if s["queue"] and SECRET_QUEUE_SUBSTR in s["queue"]]


def guard_steps(parsed):
    return [s for s in parsed["steps"] if s["key"].startswith("guard-")]


def _cond_excludes(cond, env_kind):
    """True if a Buildkite `if:` excludes this env. Minimal: only the
    pull_request null-check pattern is modeled; anything else fails closed."""
    if cond is None:
        return False
    # e.g. `if: build.pull_request.id != null` — false on non-PR builds.
    if re.fullmatch(r"\s*build\.pull_request\.id\s*!=\s*null\s*", cond):
        return env_kind == "nonpr"
    raise PipelineError(f"unmodeled condition: {cond}")


def schedule(parsed, failed_keys, env_kind="pr"):
    """Start-set under Buildkite semantics: steps start in order unless a
    preceding `wait` (with any earlier failure) or a failed `depends_on`
    blocks them. Returns (started_keys, blocked_keys, edges)."""
    started, blocked, edges = [], [], []
    by_key = {s["key"]: s for s in parsed["steps"]}
    seen_failure = False
    seen_failed = set()
    # Steps that never passed (failed OR blocked): a depends_on target in
    # this set blocks its dependents transitively, matching Buildkite
    # (a step whose dep never runs never runs). if-excluded steps stay OUT:
    # BK treats skipped deps as satisfied, not blocking.
    unpassed = set(failed_keys)
    for typ, ref in parsed["order"]:
        if typ == "wait":
            # A wait blocks downstream only when a step BEFORE it failed —
            # a later failure must not rewrite steps that already started.
            if seen_failed:
                seen_failure = True
            continue
        st = by_key[ref]
        try:
            excluded = _cond_excludes(st["cond"], env_kind)
        except PipelineError as e:
            raise PipelineError(f"step {ref}: {e}")
        if excluded:
            blocked.append(ref)
            edges.append((ref, "excluded-by-if"))
            continue
        if ref in failed_keys:
            seen_failed.add(ref)
        dep_failed = [d for d in st["depends_on"] if d in unpassed]
        if dep_failed:
            blocked.append(ref)
            edges.append((ref, f"depends_on-failed:{','.join(dep_failed)}"))
            unpassed.add(ref)
        elif seen_failure:
            blocked.append(ref)
            edges.append((ref, "wait-after-failure"))
            unpassed.add(ref)
        else:
            started.append(ref)
    return started, blocked, edges


def diff_pipelines(base_path, other_path):
    """Diff steps by key: removed/added/changed(command,queue,cond)."""
    b = {s["key"]: s for s in parse(base_path)["steps"]}
    o = {s["key"]: s for s in parse(other_path)["steps"]}
    removed = sorted(set(b) - set(o))
    added = sorted(set(o) - set(b))
    changed = {}
    for k in sorted(set(b) & set(o)):
        d = {}
        for f in ("command", "queue", "cond"):
            if b[k][f] != o[k][f]:
                d[f] = [b[k][f], o[k][f]]
        if d:
            changed[k] = d
    return {"removed": removed, "added": added, "changed": changed,
            "base_keys": sorted(b), "other_keys": sorted(o)}


def main(argv):
    if len(argv) < 3:
        print("usage: pipeline.py <schedule|diff|dump> ...", file=sys.stderr)
        return 2
    try:
        if argv[1] == "schedule":
            # schedule <pipeline> <failed,key,csv> <env_kind>
            p = parse(argv[2])
            failed = set(argv[3].split(",")) if argv[3] else set()
            started, blocked, edges = schedule(p, failed, argv[4])
            print(json.dumps({"started": started, "blocked": blocked,
                              "edges": edges,
                              "secret": [s["key"] for s in secret_steps(p)],
                              "guards": [s["key"] for s in guard_steps(p)]}))
        elif argv[1] == "diff":
            print(json.dumps(diff_pipelines(argv[2], argv[3])))
        elif argv[1] == "dump":
            print(json.dumps(parse(argv[2]), indent=1))
        else:
            return 2
    except PipelineError as e:
        print(json.dumps({"error": str(e)}))
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
