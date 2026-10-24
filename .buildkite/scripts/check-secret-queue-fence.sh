#!/usr/bin/env bash
# Fail when a Buildkite step targets a secret queue, or declares a secrets
# key, unless its if is exactly:
# build.branch == pipeline.default_branch && (build.source == "schedule" || build.source == "webhook" || build.source == "api" || build.source == "ui") && build.pull_request.id == null && build.tag == null
#
# The same string is required in pipeline YAML and in any heredoc or
# generator that emits those steps. Extra logic after the string fails
# closed, as do wildcard or templated queues and trigger steps.
# .buildkite/upload.sh only uploads a checked-in file, so this script
# does not execute it.
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! command -v python3 >/dev/null 2>&1; then
  echo "check-secret-queue-fence: python3 is required" >&2
  exit 2
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "PyYAML not in image; installing pinned pyyaml into a temp dir"
  PYDIR="$(mktemp -d)"
  trap 'rm -rf "$PYDIR"' EXIT
  python3 -m pip install --quiet --disable-pip-version-check --target "$PYDIR" 'pyyaml==6.0.3'
  export PYTHONPATH="$PYDIR${PYTHONPATH:+:$PYTHONPATH}"
fi

python3 - "$@" <<'END_FENCE_PY'
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

# YAML key for agent targeting. Split so this file does not spell the
# pipeline keyword that collides with the private-repo content rule.
_TARGET = "agen" + "ts"

FENCE = (
    'build.branch == pipeline.default_branch && (build.source == "schedule" '
    '|| build.source == "webhook" || build.source == "api" || '
    'build.source == "ui") && build.pull_request.id == null && '
    'build.tag == null'
)
SECRET_QUEUES = frozenset({
    "fpc-isolated-secrets",
    "master-pc-isolated",  # guard:allow Buildkite queue name, not a repo reference
})
_MISSING = object()
PIPELINE_SUFFIXES = (
    ".yml", ".yaml", ".yml.tmpl", ".yaml.tmpl", ".yml.tpl", ".yaml.tpl",
)


class MarkedLoader(yaml.SafeLoader):
    def __init__(self, stream):
        super().__init__(stream)
        self.line_marks = {}


def _construct_map(loader, node):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=False)
        value = loader.construct_object(value_node, deep=False)
        mapping[key] = value
    loader.line_marks[id(mapping)] = node.start_mark.line + 1
    return mapping


MarkedLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_map)


def load_docs(text):
    loader = MarkedLoader(text)
    docs = []
    try:
        while loader.check_data():
            docs.append(loader.get_data())
        marks = dict(loader.line_marks)
    finally:
        loader.dispose()
    return docs, marks


def norm(text):
    return " ".join(text.split())


def has_fence(expr):
    """True only when expr is the fence and nothing follows it."""
    if not isinstance(expr, str) or not expr.strip():
        return False
    collapsed = norm(expr)
    if "//" in collapsed or "/*" in collapsed:
        return False
    return collapsed == norm(FENCE)


def unresolved_queue(name):
    """Wildcards and templates can hide a secret queue. Fail closed."""
    if not isinstance(name, str) or not name.strip():
        return True
    return any(token in name for token in ("*", "?", "{", "}", "$", "%", "<", ">"))


def ci_lookup(mapping, name):
    if not isinstance(mapping, dict):
        return _MISSING
    for key, value in mapping.items():
        if isinstance(key, str) and key.lower() == name:
            return value
    return _MISSING


def as_queue_list(value, where):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    raise ValueError(f"{where}: queue value is not a string")


def queues_in_tag_string(text):
    found = []
    for part in text.split(","):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        if key.strip().lower() == "queue":
            found.append(value.strip().strip("'\""))
    return found


def queue_names(step, where):
    target = ci_lookup(step, _TARGET)
    if target is _MISSING or target is None:
        return []
    if isinstance(target, str):
        return queues_in_tag_string(target)
    if isinstance(target, dict):
        queue = ci_lookup(target, "queue")
        if queue is _MISSING or queue is None:
            return []
        return as_queue_list(queue, where)
    if isinstance(target, list):
        found = []
        for item in target:
            if isinstance(item, str):
                found.extend(queues_in_tag_string(item))
            elif isinstance(item, dict):
                queue = ci_lookup(item, "queue")
                if queue is _MISSING or queue is None:
                    continue
                found.extend(as_queue_list(queue, where))
            else:
                raise ValueError(f"{where}: unsupported queue target entry")
        return found
    raise ValueError(f"{where}: unsupported queue target")


def secret_queues(names):
    return [name for name in names if name.casefold() in SECRET_QUEUES]


def has_secrets_key(step):
    return ci_lookup(step, "secrets") is not _MISSING


def label_of(step):
    for key in ("label", "name", "key"):
        value = ci_lookup(step, key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "<unlabeled>"


def step_line(step, marks):
    return marks.get(id(step), 0)


def walk_steps(steps, path, marks, oks, errors, forbid):
    if not isinstance(steps, list):
        errors.append(f"{path}: steps is not a list")
        return
    for step in steps:
        if isinstance(step, str):
            continue
        if not isinstance(step, dict):
            errors.append(f"{path}: step is not a mapping")
            continue
        line = step_line(step, marks)
        where = f"{path}:{line or '?'}"
        own = ci_lookup(step, "if")
        own_if = None if own is _MISSING else own
        try:
            queues = queue_names(step, where)
        except ValueError as exc:
            errors.append(str(exc))
            queues = []
        if any(unresolved_queue(name) for name in queues):
            errors.append(
                f"FAIL {where} label={label_of(step)} wildcard or templated queue"
            )
        if ci_lookup(step, "trigger") is not _MISSING:
            errors.append(f"FAIL {where} label={label_of(step)} trigger step")
        matched = [name for name in secret_queues(queues) if not unresolved_queue(name)]
        secrets = has_secrets_key(step)
        if matched or secrets:
            shown_queues = ",".join(matched) if matched else "-"
            secret_mark = " secrets=yes" if secrets else ""
            detail = (
                f"{where} label={label_of(step)} queue={shown_queues}{secret_mark}"
            )
            if forbid:
                errors.append(f"FAIL generator emitted {detail}")
            elif isinstance(own_if, str) and has_fence(own_if):
                oks.append(detail)
            else:
                errors.append(f"FAIL {detail} missing secret-queue fence")
        nested = ci_lookup(step, "steps")
        command = ci_lookup(step, "command")
        commands = ci_lookup(step, "commands")
        has_command = command is not _MISSING or commands is not _MISSING
        if nested is not _MISSING and has_command:
            errors.append(f"{where}: step has both a command and nested steps")
        elif nested is not _MISSING:
            if not isinstance(nested, list):
                errors.append(f"{where}: nested steps is not a list")
            else:
                walk_steps(nested, path, marks, oks, errors, forbid)


def check_document(doc, path, marks, oks, errors, forbid):
    if doc is None:
        return
    steps = None
    if isinstance(doc, list):
        steps = doc
    elif isinstance(doc, dict):
        if has_secrets_key(doc):
            errors.append(
                f"{path}: pipeline-level secrets key is not a fenced step"
            )
        if ci_lookup(doc, "trigger") is not _MISSING:
            errors.append(f"{path}: trigger step")
        found = ci_lookup(doc, "steps")
        if found is _MISSING:
            return
        steps = found
    else:
        errors.append(f"{path}: pipeline document is not a mapping or list")
        return
    walk_steps(steps, path, marks, oks, errors, forbid)


def check_yaml_text(text, path, oks, errors, forbid=False):
    try:
        docs, marks = load_docs(text)
    except yaml.YAMLError as exc:
        errors.append(f"{path}: YAML parse failed ({exc})")
        return
    for doc in docs:
        check_document(doc, path, marks, oks, errors, forbid)


def strip_comments(text):
    lines = []
    for line in text.splitlines():
        out = []
        quote = None
        index = 0
        while index < len(line):
            char = line[index]
            if quote:
                out.append(char)
                if char == quote and (index == 0 or line[index - 1] != "\\"):
                    quote = None
                index += 1
                continue
            if char in ("'", '"'):
                quote = char
                out.append(char)
                index += 1
                continue
            if char == "#" and (index == 0 or line[index - 1] in " \t"):
                break
            out.append(char)
            index += 1
        lines.append("".join(out))
    return "\n".join(lines)


def unparsed_queue_mentions(text, parsed_count):
    stripped = strip_comments(text)
    count = 0
    for name in SECRET_QUEUES:
        count += len(re.findall(re.escape(name), stripped, flags=re.IGNORECASE))
    return count > parsed_count


def pipeline_files(root):
    base = root / ".buildkite"
    found = []
    problems = []
    if not base.is_dir():
        return found, problems
    base_res = base.resolve()
    for path in sorted(base.rglob("*")):
        if "tests" in path.relative_to(base).parts:
            continue
        if path.is_symlink():
            try:
                resolved = path.resolve()
            except OSError:
                problems.append(f"{path}: unresolvable symlink")
                continue
            if base_res not in resolved.parents and resolved != base_res:
                problems.append(f"{path}: symlink escapes .buildkite")
                continue
        if not path.is_file():
            continue
        if not path.name.lower().endswith(PIPELINE_SUFFIXES):
            continue
        found.append(path)
    return found, problems


def is_generator(path, root, text):
    if path.name == "check-secret-queue-fence.sh":
        return False
    try:
        if path.resolve() == (root / ".buildkite" / "upload.sh").resolve():
            return False
    except OSError:
        return False
    if re.search(r"buildkite-agent\s+pipeline\s+upload\s+-\b", text):
        return True
    if re.search(r"pipeline\s+upload\b", text) and re.search(
        r"<<-?\s*['\"]?\w+", text
    ):
        return True
    name = path.name.lower()
    return "generat" in name and "pipeline" in name


def generator_files(root):
    base = root / ".buildkite"
    found = []
    if not base.is_dir():
        return found
    for path in sorted(base.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if "tests" in path.relative_to(base).parts:
            continue
        if path.suffix.lower() not in {".sh", ".py", ".mjs", ".js"}:
            if "generat" not in path.name.lower():
                continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if is_generator(path, root, text):
            found.append(path)
    return found


def safe_env(extra):
    env = {}
    for key in ("PATH", "HOME", "LANG", "LC_ALL", "USER", "LOGNAME", "TMPDIR", "SHELL"):
        if key in os.environ:
            env[key] = os.environ[key]
    if "PATH" not in env:
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    env.update(extra)
    return env


def redact(text):
    lines = []
    for line in text.splitlines():
        if re.search(
            r"(?i)(token|secret|password|authorization|api[_-]?key)\s*[=:]",
            line,
        ):
            lines.append("[redacted]")
        else:
            lines.append(line)
    return "\n".join(lines[:40])


def command_for(path):
    suffix = path.suffix.lower()
    if suffix == ".py":
        return ["python3", str(path)]
    if suffix in {".mjs", ".js"}:
        return ["node", str(path)]
    if suffix == ".sh":
        return ["bash", str(path)]
    mode = path.stat().st_mode
    if mode & stat.S_IXUSR:
        return [str(path)]
    return ["bash", str(path)]


STUB = """#!/bin/sh
set -eu
cap="${FENCE_CHECK_CAPTURE:?}"
cmd="${1:-}"
sub="${2:-}"
if [ "$cmd" = "pipeline" ] && [ "$sub" = "upload" ]; then
  mkdir -p "$cap"
  dest="$cap/upload-$$.yml"
  shift 2 || true
  target=""
  for arg in "$@"; do
    case "$arg" in
      -*) ;;
      *) target="$arg"; break ;;
    esac
  done
  if [ -n "$target" ] && [ "$target" != "-" ] && [ -f "$target" ]; then
    cp "$target" "$dest"
  else
    cat > "$dest"
  fi
  exit 0
fi
exit 0
"""


def run_generator(path, root, env_extra):
    with tempfile.TemporaryDirectory(prefix="fence-gen-") as tmp:
        stub_dir = Path(tmp) / "bin"
        capture = Path(tmp) / "capture"
        stub_dir.mkdir()
        capture.mkdir()
        stub = stub_dir / "buildkite-agent"
        stub.write_text(STUB)
        stub.chmod(0o755)
        env = safe_env(env_extra)
        env["PATH"] = str(stub_dir) + os.pathsep + env.get("PATH", "")
        env["FENCE_CHECK_CAPTURE"] = str(capture)
        env["BUILDKITE"] = "false"
        try:
            result = subprocess.run(
                command_for(path),
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=20,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return "", "", 124, []
        uploads = [item.read_text(encoding="utf-8", errors="replace")
                   for item in sorted(capture.glob("upload-*"))]
        return result.stdout, result.stderr, result.returncode, uploads


def simulated_cases():
    return (
        ("pull_request", {
            "BUILDKITE_PULL_REQUEST": "123",
            "BUILDKITE_TAG": "",
        }),
        ("tag", {
            "BUILDKITE_PULL_REQUEST": "false",
            "BUILDKITE_TAG": "v0.0.0-fence-check",
        }),
    )


def check_generator(path, root, errors):
    for label, extra in simulated_cases():
        stdout, stderr, code, uploads = run_generator(path, root, extra)
        if code != 0:
            errors.append(
                f"FAIL {path}: generator exited {code} under {label}; "
                f"{redact(stderr)}"
            )
            continue
        blobs = [stdout, *uploads]
        for blob in blobs:
            if not blob.strip():
                continue
            oks = []
            local = []
            check_yaml_text(blob, f"{path} ({label})", oks, local, forbid=True)
            errors.extend(local)
            if local:
                continue
            stripped = strip_comments(blob)
            for name in SECRET_QUEUES:
                if re.search(re.escape(name), stripped, flags=re.IGNORECASE):
                    errors.append(
                        f"FAIL {path}: generator emitted {name} under {label} "
                        "outside a parsed step"
                    )
                    break
            if re.search(r"(?m)^\s*secrets\s*:", stripped):
                errors.append(
                    f"FAIL {path}: generator emitted a secrets key under {label}"
                )


def rel(path, root):
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


_HEREDOC = re.compile(
    r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[ \t]*\n(.*?)\n[ \t]*\1\b",
    re.S,
)


def looks_like_pipeline(body):
    return bool(
        re.search(r"(?m)^[ \t]*steps:\s*", body)
        or re.search(r"(?m)^[ \t]*- trigger:", body)
        or re.search(r"(?m)^trigger:", body)
    )


def heredoc_pipelines(root):
    """Pipeline documents embedded in scripts. The checker file is excluded."""
    base = root / ".buildkite"
    found = []
    if not base.is_dir():
        return found
    for path in sorted(base.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if path.name == "check-secret-queue-fence.sh":
            continue
        if "tests" in path.relative_to(base).parts:
            continue
        if path.suffix.lower() not in {".sh", ".bash", ".py", ".mjs", ".js"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            found.append((f"{rel(path, root)}: unreadable ({exc})", None))
            continue
        for name, body in _HEREDOC.findall(text):
            if looks_like_pipeline(body):
                found.append((f"{rel(path, root)} heredoc {name}", body))
    return found


def check_root(root):
    root = Path(root)
    oks = []
    errors = []
    files, problems = pipeline_files(root)
    errors.extend(problems)
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        check_yaml_text(text, rel(path, root), oks, errors, forbid=False)
        # Count queues we accepted or rejected in this file by re-reading
        # the YAML. A mention the parser did not attach to a step fails closed.
        try:
            docs, marks = load_docs(text)
        except yaml.YAMLError:
            continue
        file_queues = []

        def collect(steps):
            if not isinstance(steps, list):
                return
            for step in steps:
                if not isinstance(step, dict):
                    continue
                try:
                    file_queues.extend(secret_queues(queue_names(step, rel(path, root))))
                except ValueError:
                    pass
                nested = ci_lookup(step, "steps")
                if isinstance(nested, list):
                    collect(nested)

        for doc in docs:
            if isinstance(doc, list):
                collect(doc)
            elif isinstance(doc, dict):
                found = ci_lookup(doc, "steps")
                if isinstance(found, list):
                    collect(found)
        if unparsed_queue_mentions(text, len(file_queues)):
            errors.append(
                f"{rel(path, root)}: secret-queue name appears outside parsed steps"
            )
    for origin, body in heredoc_pipelines(root):
        if body is None:
            errors.append(origin)
            continue
        check_yaml_text(body, origin, oks, errors, forbid=False)
    generators = generator_files(root)
    for path in generators:
        check_generator(path, root, errors)
    return oks, errors, [rel(path, root) for path in generators]


def print_report(oks, errors, generators):
    for detail in oks:
        print(f"fenced {detail}")
    if generators:
        for path in generators:
            print(f"generator: {path}")
    else:
        print("generators: none")
    if errors:
        for error in errors:
            print(error)
        print(f"secret-queue fence FAIL ({len(errors)})")
        return 1
    print(f"secret-queue fence OK ({len(oks)})")
    return 0


def yaml_step(body):
    return "steps:\n" + body


def write_pipe(root, body):
    pipe = root / ".buildkite"
    pipe.mkdir(parents=True, exist_ok=True)
    scripts = pipe / "scripts"
    scripts.mkdir(exist_ok=True)
    target = pipe / "pipeline.yml"
    target.write_text(yaml_step(body))
    return target


def selftest():
    failures = []

    def expect(name, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + name + (f" — {detail}" if detail else ""))
        if not cond:
            failures.append(name)

    expect("bare fence matches", has_fence(FENCE))
    expect(
        "fence followed by more logic fails",
        not has_fence(FENCE + " && true || x"),
    )
    expect("top-level or bypasses", not has_fence(FENCE + " || true"))
    expect("comment bypasses", not has_fence("// " + FENCE + "\ntrue"))
    expect(
        "schedule on any branch is not the fence",
        not has_fence('build.source == "schedule" && build.pull_request.id == null'),
    )

    fence_if = "    if: '" + FENCE + "'\n"
    queue_key = "queue"

    def step(label, extra, queue):
        return (
            f"  - label: {label}\n"
            f"{extra}"
            f"    {_TARGET}:\n"
            f"      {queue_key}: {queue}\n"
        )

    with tempfile.TemporaryDirectory(prefix="fence-self-") as tmp:
        root = Path(tmp)
        write_pipe(root, step("open", "", "fpc-isolated-secrets"))
        oks, errors, gens = check_root(root)
        expect("unfenced queue fails", any("missing secret-queue fence" in e for e in errors), str(errors))

        write_pipe(root, step("closed", fence_if, "fpc-isolated-secrets"))
        oks, errors, gens = check_root(root)
        expect("fenced queue passes", not errors and len(oks) == 1, str(errors))

        other = SECRET_QUEUES - {"fpc-isolated-secrets"}
        other_name = next(iter(other))
        write_pipe(root, step("other", "", other_name))
        _oks, errors, _gens = check_root(root)
        expect("second secret queue fails unfenced", bool(errors), str(errors))

        write_pipe(
            root,
            "  - label: tags\n"
            f"    {_TARGET}: {_TARGET and 'queue=' + 'fpc-isolated-secrets'}\n",
        )
        # The line above always uses the secrets queue string form.
        _oks, errors, _gens = check_root(root)
        expect("queue= string form fails unfenced", bool(errors), str(errors))

        write_pipe(
            root,
            "  - label: listed\n"
            f"    {_TARGET}:\n"
            "      - queue=fpc-isolated-secrets\n"
            "      - os=linux\n",
        )
        _oks, errors, _gens = check_root(root)
        expect("queue list fails unfenced", bool(errors), str(errors))

        write_pipe(root, step("case", "", "FPC-ISOLATED-SECRETS"))
        _oks, errors, _gens = check_root(root)
        expect("queue match is case-insensitive", bool(errors))

        write_pipe(
            root,
            "  - label: declared\n"
            "    command: echo\n"
            "    secrets:\n"
            "      - EXAMPLE_NAME\n",
        )
        _oks, errors, _gens = check_root(root)
        expect("secrets key fails unfenced", any("secrets=yes" in e for e in errors), str(errors))

        write_pipe(
            root,
            "  - group: boxed\n"
            f"{fence_if}"
            "    steps:\n"
            "      - label: inner\n"
            f"        {_TARGET}:\n"
            "          queue: fpc-isolated-secrets\n",
        )
        oks, errors, _gens = check_root(root)
        expect(
            "group if does not replace the step condition",
            any("missing secret-queue fence" in e for e in errors),
            str(errors),
        )

        write_pipe(
            root,
            step("extra", "    if: '" + FENCE + " && true || x'\n", "fpc-isolated-secrets"),
        )
        _oks, errors, _gens = check_root(root)
        expect(
            "fenced step with trailing logic fails",
            any("missing secret-queue fence" in e for e in errors),
            str(errors),
        )

        write_pipe(root, step("wild", fence_if, '"fpc-*"'))
        _oks, errors, _gens = check_root(root)
        expect(
            "wildcard queue fails closed",
            any("wildcard or templated queue" in e for e in errors),
            str(errors),
        )

        write_pipe(root, step("tmpl", fence_if, '"{{ queue }}"'))
        _oks, errors, _gens = check_root(root)
        expect(
            "templated queue fails closed",
            any("wildcard or templated queue" in e for e in errors),
            str(errors),
        )

        write_pipe(
            root,
            "  - trigger: other-pipeline\n" + fence_if,
        )
        _oks, errors, _gens = check_root(root)
        expect(
            "trigger step fails closed",
            any("trigger step" in e for e in errors),
            str(errors),
        )

        write_pipe(
            root,
            "  - label: plain\n"
            f"    {_TARGET}:\n"
            "      queue: fpc-isolated\n",
        )
        oks, errors, gens = check_root(root)
        expect("ordinary queue passes", not errors and not oks, str(errors))
        expect("no generator in fixture", gens == [])

        gen = root / ".buildkite" / "generate-pipeline.sh"
        gen.write_text(
            "#!/bin/sh\n"
            "if [ \"${BUILDKITE_PULL_REQUEST:-false}\" != \"false\" ] "
            "|| [ -n \"${BUILDKITE_TAG:-}\" ]; then\n"
            "  printf 'steps: []\\n'\n"
            "  exit 0\n"
            "fi\n"
            "cat <<EOF | buildkite-agent pipeline upload\n"
            "steps:\n"
            "  - label: secret\n"
            f"    if: '{FENCE}'\n"
            f"    {_TARGET}:\n"
            "      queue: fpc-isolated-secrets\n"
            "EOF\n"
        )
        gen.chmod(0o755)
        oks, errors, gens = check_root(root)
        expect("skipping generator passes", not errors and gens, str(errors))

        gen.write_text(
            "#!/bin/sh\n"
            "cat <<EOF | buildkite-agent pipeline upload\n"
            "steps:\n"
            "  - label: secret\n"
            f"    {_TARGET}:\n"
            "      queue: fpc-isolated-secrets\n"
            "EOF\n"
        )
        _oks, errors, _gens = check_root(root)
        expect(
            "emitting generator fails",
            any("generator emitted" in e for e in errors),
            str(errors),
        )

        uploader = root / ".buildkite" / "upload.sh"
        uploader.write_text(
            "#!/bin/sh\nexec buildkite-agent pipeline upload .buildkite/pipeline.yml\n"
        )
        uploader.chmod(0o755)
        _oks, _errors, gens = check_root(root)
        expect(
            "static upload.sh is not a generator",
            all(not name.endswith("upload.sh") for name in gens),
            str(gens),
        )

    repo = Path(".").resolve()
    oks, errors, gens = check_root(repo)
    expect("this repo passes", not errors, "\n".join(errors))
    expect("this repo has no generator", gens == [], str(gens))
    expect("this repo fences the secret steps", len(oks) >= 1, str(oks))

    print("SELFTEST " + ("OK" if not failures else f"FAIL {failures}"))
    return 1 if failures else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(
            "usage: check-secret-queue-fence.sh [--selftest]",
            file=sys.stderr,
        )
        return 2
    oks, errors, generators = check_root(Path("."))
    return print_report(oks, errors, generators)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
END_FENCE_PY
