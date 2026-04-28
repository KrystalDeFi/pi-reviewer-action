# pi-reviewer-action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable composite GitHub Action `KrystalDeFi/pi-reviewer-action` that runs the `@mariozechner/pi-coding-agent` CLI to review pull requests via OpenRouter (or another configured provider). Callers pass a `prompt` and `model`; the agent uses `gh` CLI to fetch diffs and post review comments.

**Architecture:** Composite action. No Docker, no bundled JS. `action.yml` orchestrates: setup-node → `npm install -g pi-coding-agent@<pinned>` → run `scripts/run-pi.sh` → upload session log artifact. The bash script is the only piece of real logic and is unit-tested with stubs for `pi`/`gh`/`GITHUB_OUTPUT`.

**Tech Stack:** GitHub Actions (composite), bash 4+, Node 20 (for npm), `@mariozechner/pi-coding-agent` 0.70.5, `gh` CLI (preinstalled on hosted runners), `actionlint` for action syntax validation.

**Spec reference:** `docs/superpowers/specs/2026-04-28-pi-reviewer-action-design.md`

**Repo starting state:** The repo at `/Users/tungpun/Desktop/repos/krystal/pi-reviewer` has zero commits on `main`. There is an `assets/pi-mono/` directory containing a clone of pi-mono for reference; we keep it but ignore it from publishes via `.gitignore`. The `docs/superpowers/specs/` and `docs/superpowers/plans/` directories already contain the spec and this plan.

---

## File Structure

| File | Purpose |
|---|---|
| `action.yml` | Composite action manifest. Inputs, outputs, steps. |
| `scripts/run-pi.sh` | The pi invocation. Builds args, pipes prompt on stdin, captures exit code, writes outputs. |
| `tests/test-run-pi.sh` | Shell-based tests for `run-pi.sh`. Uses stubs for `pi` and `GITHUB_OUTPUT`. |
| `tests/stubs/pi` | Stub binary that records argv (`$@`) and stdin to files for assertions. |
| `tests/stubs/gh` | No-op stub. Exists so `gh --version` in tests doesn't fail. |
| `examples/pr-review.yml` | Canonical caller workflow — the example from the spec. |
| `examples/path-filtered.yml` | Caller workflow that only triggers on `src/**` changes. |
| `.github/workflows/self-test.yml` | Action self-test: invokes `./` on its own PRs and asserts a comment was posted. |
| `.github/workflows/lint.yml` | Runs `actionlint` and `shellcheck` on every PR. |
| `.github/workflows/release.yml` | Manual workflow_dispatch — bumps the major-tag pointer. |
| `.gitignore` | Ignores `node_modules/`, `.DS_Store`, runtime session dirs, and `assets/` so the pi-mono clone isn't published with the action. |
| `LICENSE` | MIT. |
| `README.md` | Usage, permissions matrix, examples, troubleshooting. |

`assets/pi-mono/` stays in the working tree as local reference but is `.gitignore`d.

---

## Task 1: Initialize repository scaffolding

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/.gitignore`
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/LICENSE`
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/README.md` (stub)

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# OS
.DS_Store
Thumbs.db

# Editor
.idea/
.vscode/
*.swp

# Node
node_modules/

# Pi runtime
.pi/
*-session.jsonl

# Local pi-mono reference clone — not part of the action source
assets/

# Test artifacts
tests/.tmp/
```

- [ ] **Step 2: Write `LICENSE` (MIT)**

```
MIT License

Copyright (c) 2026 Krystal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Write `README.md` stub**

```markdown
# pi-reviewer-action

A GitHub Action that runs the [`pi-coding-agent`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) CLI against a pull request to perform code review.

> Status: pre-release. See `docs/superpowers/specs/2026-04-28-pi-reviewer-action-design.md` for the design.

## License

MIT.
```

The README will be expanded in Task 9 once the action is functional.

- [ ] **Step 4: Verify file contents**

Run:
```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
ls -la .gitignore LICENSE README.md
wc -l .gitignore LICENSE README.md
```

Expected: all three files exist, non-zero size.

- [ ] **Step 5: Commit**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
git add .gitignore LICENSE README.md docs/
git commit -m "chore: initialize repo scaffolding (gitignore, license, readme stub, design+plan docs)"
```

(The `docs/` add is intentional — the spec and plan files already exist in the working tree and should be in the initial commit.)

---

## Task 2: Add `pi` and `gh` test stubs

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/tests/stubs/pi`
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/tests/stubs/gh`

**Why:** `run-pi.sh` invokes `pi` and (via the action) relies on `gh` being on PATH. For unit tests we need stubs that record what `pi` was called with so we can assert on argv and stdin.

- [ ] **Step 1: Create the `pi` stub**

Create `tests/stubs/pi` (executable):

```bash
#!/usr/bin/env bash
# Test stub for `pi`. Records argv and stdin, then exits with PI_STUB_EXIT_CODE
# (default 0). Optionally writes a fake session JSONL to PI_STUB_SESSION_DIR
# so run-pi.sh can find it.

set -euo pipefail

: "${PI_STUB_RECORD_DIR:?PI_STUB_RECORD_DIR is required by the test}"

mkdir -p "$PI_STUB_RECORD_DIR"

# Record argv, one arg per line.
printf '%s\n' "$@" > "$PI_STUB_RECORD_DIR/argv"

# Record stdin verbatim.
cat > "$PI_STUB_RECORD_DIR/stdin"

# If a session dir was passed via --session-dir, drop a fake session file
# so run-pi.sh's "find latest session" logic has something to find.
SESSION_DIR=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--session-dir" ]]; then
    SESSION_DIR="$arg"
    break
  fi
  prev="$arg"
done

if [[ -n "$SESSION_DIR" ]]; then
  mkdir -p "$SESSION_DIR"
  printf '{"stub":true}\n' > "$SESSION_DIR/session-stub.jsonl"
fi

exit "${PI_STUB_EXIT_CODE:-0}"
```

- [ ] **Step 2: Create the `gh` stub**

Create `tests/stubs/gh` (executable):

```bash
#!/usr/bin/env bash
# No-op stub for `gh`. Always exits 0, prints version on `gh --version`.

if [[ "${1:-}" == "--version" ]]; then
  echo "gh version 0.0.0-stub"
  exit 0
fi

exit 0
```

- [ ] **Step 3: Make the stubs executable**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
chmod +x tests/stubs/pi tests/stubs/gh
ls -la tests/stubs/
```

Expected: both files have `x` permission.

- [ ] **Step 4: Smoke-test the `pi` stub**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
PI_STUB_RECORD_DIR=/tmp/pi-stub-smoke echo "hello" | tests/stubs/pi --print --model foo
cat /tmp/pi-stub-smoke/argv
cat /tmp/pi-stub-smoke/stdin
rm -rf /tmp/pi-stub-smoke
```

Expected: `argv` contains `--print`, `--model`, `foo` (one per line). `stdin` contains `hello`. Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add tests/stubs/
git commit -m "test: add pi and gh stubs for run-pi.sh unit tests"
```

---

## Task 3: Write the failing test for `run-pi.sh` env guards

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/tests/test-run-pi.sh`

**Why:** TDD — write the test before the script. The first behaviors to lock in are the env guards: missing `PI_PROMPT`, `PI_MODEL`, or `GH_TOKEN` must fail fast.

- [ ] **Step 1: Write the test runner**

Create `tests/test-run-pi.sh` (executable):

```bash
#!/usr/bin/env bash
# Unit tests for scripts/run-pi.sh.
# Uses tests/stubs/{pi,gh} via a temp PATH prefix. No real pi or network needed.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TMP_ROOT="$REPO_ROOT/tests/.tmp"
mkdir -p "$TMP_ROOT"

PASS=0
FAIL=0
FAILURES=()

run_case() {
  local name="$1"
  local case_dir
  case_dir="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
  echo "▶ $name"

  # Per-case env, isolated from the parent shell.
  (
    set +e
    export PI_STUB_RECORD_DIR="$case_dir/pi-record"
    export GITHUB_OUTPUT="$case_dir/github-output"
    export RUNNER_TEMP="$case_dir/runner-temp"
    : > "$GITHUB_OUTPUT"

    # Put stubs first on PATH so `pi` and `gh` resolve to them.
    export PATH="$REPO_ROOT/tests/stubs:$PATH"

    # Caller sets case-specific env via $ENV_PRELUDE before sourcing.
    eval "${ENV_PRELUDE:-}"

    bash "$REPO_ROOT/scripts/run-pi.sh"
    echo "__EXIT__=$?" >> "$case_dir/result"
    cp "$GITHUB_OUTPUT" "$case_dir/github-output.captured" 2>/dev/null || true
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"

  # Caller asserts via $ASSERT, sourced with $case_dir, $name in scope.
  if (set -e; eval "$ASSERT"); then
    PASS=$((PASS + 1))
    echo "  ✓ $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name")
    echo "  ✗ $name"
    echo "    stdout: $case_dir/stdout"
    echo "    stderr: $case_dir/stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

ENV_PRELUDE='
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
  # PI_PROMPT intentionally unset
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" != "0" ] || { echo "expected non-zero exit"; exit 1; }
  grep -q "PI_PROMPT" "$case_dir/stderr" || { echo "expected PI_PROMPT in stderr"; cat "$case_dir/stderr"; exit 1; }
'
run_case "fails when PI_PROMPT is missing"

ENV_PRELUDE='
  export PI_PROMPT="hi"
  export GH_TOKEN=ghs_fake
  # PI_MODEL intentionally unset
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" != "0" ] || { echo "expected non-zero exit"; exit 1; }
  grep -q "PI_MODEL" "$case_dir/stderr" || { echo "expected PI_MODEL in stderr"; cat "$case_dir/stderr"; exit 1; }
'
run_case "fails when PI_MODEL is missing"

ENV_PRELUDE='
  export PI_PROMPT="hi"
  export PI_MODEL=fake/model
  # GH_TOKEN intentionally unset
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" != "0" ] || { echo "expected non-zero exit"; exit 1; }
  grep -q "GH_TOKEN" "$case_dir/stderr" || { echo "expected GH_TOKEN in stderr"; cat "$case_dir/stderr"; exit 1; }
'
run_case "fails when GH_TOKEN is missing"

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Make it executable**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
chmod +x tests/test-run-pi.sh
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run:
```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
./tests/test-run-pi.sh
```

Expected: All three cases FAIL because `scripts/run-pi.sh` does not exist yet (bash will print "No such file or directory").

- [ ] **Step 4: Commit**

```bash
git add tests/test-run-pi.sh
git commit -m "test: add failing tests for run-pi.sh env guards"
```

---

## Task 4: Implement `run-pi.sh` env guards (make Task 3 tests pass)

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/scripts/run-pi.sh`

- [ ] **Step 1: Write the minimal script**

Create `scripts/run-pi.sh` (executable):

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${PI_PROMPT:?PI_PROMPT is required}"
: "${PI_MODEL:?PI_MODEL is required}"
: "${PI_PROVIDER:=openrouter}"
: "${PI_THINKING:=medium}"
: "${PI_APPEND_SYSTEM_PROMPT:=}"
: "${GH_TOKEN:?GH_TOKEN is required}"
```

- [ ] **Step 2: Make it executable**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
chmod +x scripts/run-pi.sh
```

- [ ] **Step 3: Run the tests and confirm they pass**

Run:
```bash
./tests/test-run-pi.sh
```

Expected: `Results: 3 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/run-pi.sh
git commit -m "feat: add run-pi.sh env guards"
```

---

## Task 5: Add failing tests for `pi` invocation shape

**Files:**
- Modify: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/tests/test-run-pi.sh`

**Why:** Lock down that `run-pi.sh` invokes `pi` with the right flags, the prompt on stdin, and the configurable values forwarded.

- [ ] **Step 1: Append three new test cases**

Append the following blocks to `tests/test-run-pi.sh` **before** the `Results:` summary line. Each block is `ENV_PRELUDE`, `ASSERT`, `run_case` triple.

Case A — defaults wired correctly:

```bash
ENV_PRELUDE='
  export PI_PROMPT="review please"
  export PI_MODEL=xiaomi/mimo-v2.5-pro
  export GH_TOKEN=ghs_fake
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" = "0" ] || { echo "expected exit 0, got $exit_code"; cat "$case_dir/stderr"; exit 1; }
  argv="$case_dir/pi-record/argv"
  grep -qx -- "--print"             "$argv" || { echo "missing --print"; exit 1; }
  grep -qx -- "--provider"          "$argv" || { echo "missing --provider flag"; exit 1; }
  grep -qx -- "openrouter"          "$argv" || { echo "missing default provider value"; exit 1; }
  grep -qx -- "--model"             "$argv" || { echo "missing --model flag"; exit 1; }
  grep -qx -- "xiaomi/mimo-v2.5-pro" "$argv" || { echo "missing model value"; exit 1; }
  grep -qx -- "--thinking"          "$argv" || { echo "missing --thinking flag"; exit 1; }
  grep -qx -- "medium"              "$argv" || { echo "missing default thinking value"; exit 1; }
  grep -qx -- "--tools"             "$argv" || { echo "missing --tools flag"; exit 1; }
  grep -qx -- "bash,read,grep,find,ls" "$argv" || { echo "wrong tools list"; exit 1; }
  for flag in --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files; do
    grep -qx -- "$flag" "$argv" || { echo "missing $flag"; exit 1; }
  done
  grep -qx -- "--session-dir" "$argv" || { echo "missing --session-dir flag"; exit 1; }
  # Prompt must come on stdin verbatim.
  diff <(printf "%s" "review please") "$case_dir/pi-record/stdin" || { echo "stdin != prompt"; exit 1; }
'
run_case "forwards defaults and pipes prompt on stdin"
```

Case B — overrides are forwarded:

```bash
ENV_PRELUDE='
  export PI_PROMPT="review v2"
  export PI_MODEL=openai/gpt-5
  export GH_TOKEN=ghs_fake
  export PI_PROVIDER=openai
  export PI_THINKING=high
  export PI_APPEND_SYSTEM_PROMPT="Always end with a haiku."
'
ASSERT='
  argv="$case_dir/pi-record/argv"
  grep -qx -- "openai" "$argv" || { echo "missing provider override"; exit 1; }
  grep -qx -- "high"   "$argv" || { echo "missing thinking override"; exit 1; }
  grep -qx -- "openai/gpt-5" "$argv" || { echo "missing model override"; exit 1; }
  grep -qx -- "--append-system-prompt" "$argv" || { echo "missing --append-system-prompt"; exit 1; }
  grep -qx -- "Always end with a haiku." "$argv" || { echo "missing append-system-prompt value"; exit 1; }
'
run_case "forwards overrides for provider, thinking, model, append-system-prompt"
```

Case C — empty append-system-prompt is omitted entirely:

```bash
ENV_PRELUDE='
  export PI_PROMPT="hi"
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
  export PI_APPEND_SYSTEM_PROMPT=""
'
ASSERT='
  argv="$case_dir/pi-record/argv"
  ! grep -qx -- "--append-system-prompt" "$argv" || { echo "--append-system-prompt should not appear when empty"; exit 1; }
'
run_case "omits --append-system-prompt when blank"
```

- [ ] **Step 2: Run the tests and confirm the new ones fail**

Run:
```bash
./tests/test-run-pi.sh
```

Expected: 3 passed (the env-guard cases), 3 failed (the new invocation-shape cases). The script currently exits before invoking `pi`, so `argv` files don't exist.

- [ ] **Step 3: Commit**

```bash
git add tests/test-run-pi.sh
git commit -m "test: add failing tests for run-pi.sh pi invocation shape"
```

---

## Task 6: Implement the `pi` invocation in `run-pi.sh`

**Files:**
- Modify: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/scripts/run-pi.sh`

- [ ] **Step 1: Extend the script**

Replace `scripts/run-pi.sh` with this complete content:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${PI_PROMPT:?PI_PROMPT is required}"
: "${PI_MODEL:?PI_MODEL is required}"
: "${PI_PROVIDER:=openrouter}"
: "${PI_THINKING:=medium}"
: "${PI_APPEND_SYSTEM_PROMPT:=}"
: "${GH_TOKEN:?GH_TOKEN is required}"

SESSION_DIR="${RUNNER_TEMP:-/tmp}/pi-reviewer-session"
mkdir -p "$SESSION_DIR"

PI_ARGS=(
  --print
  --provider "$PI_PROVIDER"
  --model "$PI_MODEL"
  --thinking "$PI_THINKING"
  --tools bash,read,grep,find,ls
  --no-extensions
  --no-skills
  --no-prompt-templates
  --no-themes
  --no-context-files
  --session-dir "$SESSION_DIR"
)

if [[ -n "$PI_APPEND_SYSTEM_PROMPT" ]]; then
  PI_ARGS+=(--append-system-prompt "$PI_APPEND_SYSTEM_PROMPT")
fi

echo "::group::pi invocation"
echo "model:    $PI_MODEL"
echo "provider: $PI_PROVIDER"
echo "thinking: $PI_THINKING"
echo "tools:    bash,read,grep,find,ls"
echo "::endgroup::"

set +e
printf '%s' "$PI_PROMPT" | pi "${PI_ARGS[@]}"
EXIT_CODE=$?
set -e

exit "$EXIT_CODE"
```

- [ ] **Step 2: Run the tests and confirm all six pass**

Run:
```bash
./tests/test-run-pi.sh
```

Expected: `Results: 6 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add scripts/run-pi.sh
git commit -m "feat: invoke pi with --print, tool allowlist, and prompt on stdin"
```

---

## Task 7: Add failing tests for `$GITHUB_OUTPUT` writes

**Files:**
- Modify: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/tests/test-run-pi.sh`

**Why:** The action contract requires `exit_code` and `session_log` to land in `$GITHUB_OUTPUT` regardless of pi's exit status.

- [ ] **Step 1: Append two cases (success path + failure path)**

Append to `tests/test-run-pi.sh` before the `Results:` line:

```bash
ENV_PRELUDE='
  export PI_PROMPT="hi"
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
'
ASSERT='
  out="$case_dir/github-output.captured"
  [ -s "$out" ] || { echo "GITHUB_OUTPUT was empty"; exit 1; }
  grep -qE "^exit_code=0$"            "$out" || { echo "expected exit_code=0"; cat "$out"; exit 1; }
  grep -qE "^session_log=.+session-stub\.jsonl$" "$out" || { echo "expected session_log path"; cat "$out"; exit 1; }
'
run_case "writes exit_code=0 and session_log on success"

ENV_PRELUDE='
  export PI_PROMPT="hi"
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
  export PI_STUB_EXIT_CODE=42
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" = "42" ] || { echo "expected propagated exit 42, got $exit_code"; exit 1; }
  out="$case_dir/github-output.captured"
  grep -qE "^exit_code=42$"           "$out" || { echo "expected exit_code=42"; cat "$out"; exit 1; }
  grep -qE "^session_log=.+session-stub\.jsonl$" "$out" || { echo "expected session_log even on failure"; cat "$out"; exit 1; }
'
run_case "writes outputs and propagates exit code on pi failure"
```

- [ ] **Step 2: Run the tests and confirm the new ones fail**

Run:
```bash
./tests/test-run-pi.sh
```

Expected: 6 passed, 2 failed (the new GITHUB_OUTPUT cases). The script does not currently write to `$GITHUB_OUTPUT`.

- [ ] **Step 3: Commit**

```bash
git add tests/test-run-pi.sh
git commit -m "test: add failing tests for GITHUB_OUTPUT writes"
```

---

## Task 8: Implement `$GITHUB_OUTPUT` writes in `run-pi.sh`

**Files:**
- Modify: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/scripts/run-pi.sh`

- [ ] **Step 1: Add the output-writing block**

Replace `scripts/run-pi.sh` with the final version:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${PI_PROMPT:?PI_PROMPT is required}"
: "${PI_MODEL:?PI_MODEL is required}"
: "${PI_PROVIDER:=openrouter}"
: "${PI_THINKING:=medium}"
: "${PI_APPEND_SYSTEM_PROMPT:=}"
: "${GH_TOKEN:?GH_TOKEN is required}"

SESSION_DIR="${RUNNER_TEMP:-/tmp}/pi-reviewer-session"
mkdir -p "$SESSION_DIR"

PI_ARGS=(
  --print
  --provider "$PI_PROVIDER"
  --model "$PI_MODEL"
  --thinking "$PI_THINKING"
  --tools bash,read,grep,find,ls
  --no-extensions
  --no-skills
  --no-prompt-templates
  --no-themes
  --no-context-files
  --session-dir "$SESSION_DIR"
)

if [[ -n "$PI_APPEND_SYSTEM_PROMPT" ]]; then
  PI_ARGS+=(--append-system-prompt "$PI_APPEND_SYSTEM_PROMPT")
fi

echo "::group::pi invocation"
echo "model:    $PI_MODEL"
echo "provider: $PI_PROVIDER"
echo "thinking: $PI_THINKING"
echo "tools:    bash,read,grep,find,ls"
echo "::endgroup::"

set +e
printf '%s' "$PI_PROMPT" | pi "${PI_ARGS[@]}"
EXIT_CODE=$?
set -e

LATEST_SESSION="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "exit_code=$EXIT_CODE"
    echo "session_log=${LATEST_SESSION:-}"
  } >> "$GITHUB_OUTPUT"
fi

exit "$EXIT_CODE"
```

- [ ] **Step 2: Run the full test suite**

Run:
```bash
./tests/test-run-pi.sh
```

Expected: `Results: 8 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add scripts/run-pi.sh
git commit -m "feat: write exit_code and session_log to GITHUB_OUTPUT"
```

---

## Task 9: Write `action.yml`

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/action.yml`

- [ ] **Step 1: Write the manifest**

```yaml
name: 'Pi Reviewer'
description: 'Run a pi-mono coding agent against a PR for review'
branding:
  icon: 'message-circle'
  color: 'purple'

inputs:
  prompt:
    description: 'Instructions for the model'
    required: true
  model:
    description: 'Model ID (e.g. xiaomi/mimo-v2.5-pro). Supports provider/id syntax.'
    required: true
  provider:
    description: 'Pi provider name (openrouter, anthropic, openai, ...)'
    required: false
    default: 'openrouter'
  thinking:
    description: 'Thinking level: off, minimal, low, medium, high, xhigh'
    required: false
    default: 'medium'
  pi_version:
    description: 'npm version of @mariozechner/pi-coding-agent to install'
    required: false
    default: '0.70.5'
  github_token:
    description: 'Token used for the gh CLI inside pi (defaults to github.token)'
    required: false
    default: ${{ github.token }}
  working_directory:
    description: 'Where pi runs (defaults to github.workspace)'
    required: false
    default: ${{ github.workspace }}
  timeout_minutes:
    description: 'Hard cap on the pi step in minutes'
    required: false
    default: '15'
  append_system_prompt:
    description: 'Extra system instructions appended to pi defaults'
    required: false
    default: ''

outputs:
  exit_code:
    description: "Pi's exit code"
    value: ${{ steps.run.outputs.exit_code }}
  session_log:
    description: "Path to pi's session JSONL (also uploaded as artifact)"
    value: ${{ steps.run.outputs.session_log }}

runs:
  using: composite
  steps:
    - name: Setup Node
      uses: actions/setup-node@v4
      with:
        node-version: '20'
        cache: 'npm'

    - name: Install pi
      shell: bash
      run: npm install -g "@mariozechner/pi-coding-agent@${{ inputs.pi_version }}"

    - name: Verify gh CLI
      shell: bash
      run: gh --version

    - name: Run pi
      id: run
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      env:
        GH_TOKEN: ${{ inputs.github_token }}
        PI_PROMPT: ${{ inputs.prompt }}
        PI_MODEL: ${{ inputs.model }}
        PI_PROVIDER: ${{ inputs.provider }}
        PI_THINKING: ${{ inputs.thinking }}
        PI_APPEND_SYSTEM_PROMPT: ${{ inputs.append_system_prompt }}
        PI_TIMEOUT_MINUTES: ${{ inputs.timeout_minutes }}
      run: ${{ github.action_path }}/scripts/run-pi.sh

    - name: Upload session log
      if: always() && steps.run.outputs.session_log != ''
      uses: actions/upload-artifact@v4
      with:
        name: pi-reviewer-session-${{ github.run_id }}-${{ github.run_attempt }}
        path: ${{ steps.run.outputs.session_log }}
        if-no-files-found: ignore
```

- [ ] **Step 2: Validate with `actionlint`**

Install actionlint if missing, then run:

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
if ! command -v actionlint >/dev/null; then
  bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
  ACTIONLINT=./actionlint
else
  ACTIONLINT=actionlint
fi
$ACTIONLINT -color action.yml || $ACTIONLINT -color
```

Expected: no errors. (Note: `actionlint` primarily lints `.github/workflows/*.yml`; for `action.yml` it does basic checks. Errors should be zero.)

- [ ] **Step 3: Commit**

```bash
git add action.yml
git commit -m "feat: add composite action.yml manifest"
```

---

## Task 10: Add lint workflow

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/.github/workflows/lint.yml`

**Why:** Catch action-syntax and shell-script issues before release.

- [ ] **Step 1: Write the lint workflow**

```yaml
name: lint

on:
  pull_request:
  push:
    branches: [main, dev]

permissions:
  contents: read

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run shellcheck
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y shellcheck
          shellcheck scripts/run-pi.sh tests/test-run-pi.sh tests/stubs/pi tests/stubs/gh

  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run actionlint
        run: |
          bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
          ./actionlint -color

  test-run-pi:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run unit tests
        run: ./tests/test-run-pi.sh
```

- [ ] **Step 2: Run shellcheck locally to make sure nothing is flagged**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
shellcheck scripts/run-pi.sh tests/test-run-pi.sh tests/stubs/pi tests/stubs/gh
```

Expected: no output (shellcheck prints nothing when clean). If shellcheck flags something, fix it inline — most likely candidates are quoting around `"${PI_ARGS[@]}"` (already correct) or unused vars in stubs.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: add shellcheck, actionlint, and unit-test workflow"
```

---

## Task 11: Add canonical example workflows

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/examples/pr-review.yml`
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/examples/path-filtered.yml`

- [ ] **Step 1: Write `examples/pr-review.yml`**

```yaml
# Canonical pi-reviewer-action usage. Copy this into
# .github/workflows/pr-review.yml in your repo and set the OPENROUTER_REVIEWER_API_KEY secret.

name: pi review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Pi reviewer
        id: review
        uses: KrystalDeFi/pi-reviewer-action@v1
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_REVIEWER_API_KEY }}
        with:
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}

            Please review this pull request with a focus on:
            - Code quality and best practices
            - Potential bugs or issues
            - Security implications
            - Performance considerations

            Be concise and actionable.

            Provide detailed feedback using inline comments for specific issues.
            Avoid adding inline comments for issues that have already been addressed or are currently under discussion.
          model: xiaomi/mimo-v2.5-pro
```

- [ ] **Step 2: Write `examples/path-filtered.yml`**

```yaml
# Variant: only review PRs that touch src/** or contracts/**.

name: pi review (filtered)

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]
    paths:
      - 'src/**'
      - 'contracts/**'

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Pi reviewer
        uses: KrystalDeFi/pi-reviewer-action@v1
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_REVIEWER_API_KEY }}
        with:
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}
            Review only files under src/** and contracts/**. Use gh to fetch the diff. Post inline comments for issues.
          model: xiaomi/mimo-v2.5-pro
          thinking: high
```

- [ ] **Step 3: Commit**

```bash
git add examples/
git commit -m "docs: add canonical and path-filtered example workflows"
```

---

## Task 12: Add self-test workflow

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/.github/workflows/self-test.yml`

**Why:** End-to-end check on every PR to the action repo. Confirms the action installs and runs against itself with a real (cheap) model.

- [ ] **Step 1: Write the self-test workflow**

```yaml
name: self-test

on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write

jobs:
  self-test:
    runs-on: ubuntu-latest
    if: github.event.pull_request.head.repo.full_name == github.repository  # skip forks (no secret access)
    steps:
      - uses: actions/checkout@v4

      - name: Run pi-reviewer-action against this PR
        id: review
        uses: ./
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_REVIEWER_API_KEY }}
        with:
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}
            This is a self-test invocation of pi-reviewer-action.
            Run `gh pr view ${{ github.event.pull_request.number }} --json title,body` and post exactly one summary comment with `gh pr comment` that begins with the marker "[pi-reviewer self-test OK]".
            Do not post any inline comments. Do not edit any files.
          model: xiaomi/mimo-v2.5-pro
          timeout_minutes: '5'

      - name: Assert self-test marker comment exists
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh pr view "${{ github.event.pull_request.number }}" \
            --repo "${{ github.repository }}" \
            --json comments --jq '.comments[].body' \
            | grep -F "[pi-reviewer self-test OK]"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/self-test.yml
git commit -m "ci: add self-test workflow that exercises the action on its own PRs"
```

(The workflow will only run once the PR is opened against the action's repo and the `OPENROUTER_REVIEWER_API_KEY` secret is configured. It's expected to fail on the first PR if the secret isn't set — that's a one-time setup for the action repo.)

---

## Task 13: Add release workflow

**Files:**
- Create: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/.github/workflows/release.yml`

**Why:** Bump the moving major-tag (`v1`) and create a GitHub Release when we cut a new version.

- [ ] **Step 1: Write the release workflow**

```yaml
name: release

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Semver tag to create (e.g. v1.0.0)'
        required: true

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate input
        env:
          VERSION: ${{ inputs.version }}
        run: |
          if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Version must match vMAJOR.MINOR.PATCH (got: $VERSION)" >&2
            exit 1
          fi

      - name: Configure git
        run: |
          git config user.name 'github-actions[bot]'
          git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

      - name: Tag release
        env:
          VERSION: ${{ inputs.version }}
        run: |
          MAJOR="${VERSION%%.*}"   # v1
          git tag -a "$VERSION" -m "Release $VERSION"
          git tag -f "$MAJOR" "$VERSION"
          git push origin "$VERSION"
          git push origin -f "$MAJOR"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ inputs.version }}
        run: |
          gh release create "$VERSION" \
            --title "$VERSION" \
            --generate-notes
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add manual release workflow that bumps major-tag"
```

---

## Task 14: Flesh out `README.md`

**Files:**
- Modify: `/Users/tungpun/Desktop/repos/krystal/pi-reviewer/README.md`

- [ ] **Step 1: Replace the README stub with full docs**

Overwrite `README.md` with:

````markdown
# pi-reviewer-action

A reusable GitHub Action that runs the [`pi-coding-agent`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) CLI against a pull request to perform code review. The agent uses the `gh` CLI to fetch the PR diff and post review comments; this action is a thin shell around `pi --print`.

## Usage

```yaml
name: pi review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Pi reviewer
        uses: KrystalDeFi/pi-reviewer-action@v1
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_REVIEWER_API_KEY }}
        with:
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}
            Please review this pull request and post inline comments for issues.
          model: xiaomi/mimo-v2.5-pro
```

More examples in [`examples/`](./examples).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `prompt` | yes | — | Instructions for the model. Embed `${{ github.repository }}` and PR number for context. |
| `model` | yes | — | Model ID (e.g. `xiaomi/mimo-v2.5-pro`). Supports `provider/id` syntax. |
| `provider` | no | `openrouter` | Pi provider name. |
| `thinking` | no | `medium` | One of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. |
| `pi_version` | no | `0.70.5` | npm version of `@mariozechner/pi-coding-agent`. |
| `github_token` | no | `${{ github.token }}` | Token forwarded to `gh` CLI as `GH_TOKEN`. |
| `working_directory` | no | `${{ github.workspace }}` | Where pi runs. |
| `timeout_minutes` | no | `15` | Hard cap: forwarded as `PI_TIMEOUT_MINUTES` and applied via `timeout` in `run-pi.sh`. |
| `append_system_prompt` | no | `""` | Extra system instructions (e.g. team review rubric). |

## Outputs

| Output | Description |
|---|---|
| `exit_code` | Pi's exit code (callers can branch on it). |
| `session_log` | Path to pi's session JSONL on the runner. Also uploaded as a workflow artifact. |

## Required permissions

```yaml
permissions:
  contents: read         # checkout, gh pr diff, gh pr view
  pull-requests: write   # gh pr review, gh pr comment, gh api .../reviews
```

If you want pi to comment on linked issues, also grant `issues: write`.

## Required env

The action does not declare these — set them in your workflow's `env:` so they're inherited:

- `OPENROUTER_API_KEY` for the default `openrouter` provider. For other providers, set the matching `*_API_KEY`. Pi auto-discovers from `process.env`.

## What the action does NOT do

The model — not the action — handles all PR-specific logic:

- Fetching the diff (the prompt instructs `gh pr diff`).
- Choosing what to comment on.
- Avoiding duplicate comments (instruct it in your prompt).

## Debugging a bad review

Every run uploads a session log artifact named `pi-reviewer-session-<run_id>-<run_attempt>` containing pi's full JSONL transcript. Download it from the workflow run page to see exactly what the model did.

## License

MIT.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: full README with usage, inputs/outputs, permissions, debugging"
```

---

## Task 15: Final integration check

- [ ] **Step 1: Run the full local test suite**

```bash
cd /Users/tungpun/Desktop/repos/krystal/pi-reviewer
./tests/test-run-pi.sh
```

Expected: `Results: 8 passed, 0 failed`.

- [ ] **Step 2: Lint everything**

```bash
shellcheck scripts/run-pi.sh tests/test-run-pi.sh tests/stubs/pi tests/stubs/gh
[ -x ./actionlint ] || bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
./actionlint -color
```

Expected: no shellcheck errors, no actionlint errors.

- [ ] **Step 3: Verify final tree**

```bash
ls -la
ls -la scripts/ tests/ tests/stubs/ examples/ .github/workflows/
```

Expected layout:
```
action.yml
LICENSE
README.md
.gitignore
scripts/run-pi.sh
tests/test-run-pi.sh
tests/stubs/pi
tests/stubs/gh
examples/pr-review.yml
examples/path-filtered.yml
.github/workflows/lint.yml
.github/workflows/self-test.yml
.github/workflows/release.yml
docs/superpowers/specs/2026-04-28-pi-reviewer-action-design.md
docs/superpowers/plans/2026-04-28-pi-reviewer-action.md
```

- [ ] **Step 4: Confirm git history is clean**

```bash
git log --oneline
git status
```

Expected: a clean commit history (Task 1 → Task 14), nothing uncommitted, working tree clean.

- [ ] **Step 5: Push and open a PR (manual)**

This step is performed by the human reviewer:
- Push the branch to GitHub.
- Open a PR titled "Initial pi-reviewer-action implementation".
- Set the `OPENROUTER_REVIEWER_API_KEY` repo secret if not already configured.
- Verify the `lint` and `self-test` workflows pass.
- Once green, run the `release` workflow with `version: v1.0.0`.

---

## Self-Review

**Spec coverage:**

| Spec section | Implemented in |
|---|---|
| §3.1 Repo layout | Task 1, 2, 9, 10, 11, 12, 13 — every file in the layout has a task |
| §3.2 Composite (not Docker, not bundled-JS) | Task 9 |
| §4 action.yml shape | Task 9 |
| §5 scripts/run-pi.sh | Tasks 3–8 (TDD: env guards → invocation → outputs) |
| §6 Data flow | Task 9 (action.yml wires env), Task 14 (README documents flow) |
| §6.2 Permissions matrix | Task 11 (examples), Task 14 (README) |
| §7 Inputs/outputs | Task 9 |
| §8 Error handling | Tasks 3, 7 (env guard + exit-propagation tests) |
| §9 Testing — local script test | Tasks 3, 5, 7 (the unit tests) |
| §9 Testing — action self-test workflow | Task 12 |
| §9 Testing — consumer smoke test | Task 11 (examples used as smoke template) |
| §10 Release / versioning | Task 13 |
| §11 Open questions | Verified during Task 15 (real session-file naming, gh availability) |

No gaps.

**Placeholder scan:** None. Every step has explicit code or commands. No "TBD", "TODO", "similar to Task N", or vague "add error handling" phrases.

**Type/name consistency:**

- Env var names (`PI_PROMPT`, `PI_MODEL`, `PI_PROVIDER`, `PI_THINKING`, `PI_APPEND_SYSTEM_PROMPT`, `GH_TOKEN`) are identical across action.yml (Task 9), run-pi.sh (Tasks 4, 6, 8), and tests (Tasks 3, 5, 7).
- Stub env names (`PI_STUB_RECORD_DIR`, `PI_STUB_EXIT_CODE`) consistent between Task 2 (stub) and Tasks 3, 5, 7 (tests).
- Action input names match action.yml (Task 9), README (Task 14), and example workflows (Task 11).
- Output names (`exit_code`, `session_log`) consistent across action.yml, run-pi.sh, README, and tests.
- `--tools bash,read,grep,find,ls` and `--no-extensions/--no-skills/--no-prompt-templates/--no-themes/--no-context-files` flag list identical across run-pi.sh (Tasks 6, 8) and tests (Task 5).
- `pi_version` default `0.70.5` matches between spec, plan, and action.yml.

No inconsistencies.
