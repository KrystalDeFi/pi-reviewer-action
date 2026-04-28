#!/usr/bin/env bash
# shellcheck disable=SC2016
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
# Env guard tests
# ---------------------------------------------------------------------------

ENV_PRELUDE='
  unset PI_PROMPT 2>/dev/null || true
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" != "0" ] || { echo "expected non-zero exit"; exit 1; }
  grep -q "PI_PROMPT" "$case_dir/stderr" || { echo "expected PI_PROMPT in stderr"; cat "$case_dir/stderr"; exit 1; }
'
run_case "fails when PI_PROMPT is missing"

ENV_PRELUDE='
  export PI_PROMPT="hi"
  unset PI_MODEL 2>/dev/null || true
  export GH_TOKEN=ghs_fake
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
  unset GH_TOKEN 2>/dev/null || true
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" != "0" ] || { echo "expected non-zero exit"; exit 1; }
  grep -q "GH_TOKEN" "$case_dir/stderr" || { echo "expected GH_TOKEN in stderr"; cat "$case_dir/stderr"; exit 1; }
'
run_case "fails when GH_TOKEN is missing"

# ---------------------------------------------------------------------------
# Pi invocation shape tests (added in Task 5)
# ---------------------------------------------------------------------------

ENV_PRELUDE='
  export PI_PROMPT="review please"
  export PI_MODEL=xiaomi/mimo-v2.5-pro
  export GH_TOKEN=ghs_fake
'
ASSERT='
  exit_code=$(grep -oE "__EXIT__=[0-9]+" "$case_dir/result" | tail -n1 | cut -d= -f2)
  [ "$exit_code" = "0" ] || { echo "expected exit 0, got $exit_code"; cat "$case_dir/stderr"; exit 1; }
  argv="$case_dir/pi-record/argv"
  grep -qx -- "--print"                    "$argv" || { echo "missing --print"; exit 1; }
  grep -qx -- "--provider"                 "$argv" || { echo "missing --provider flag"; exit 1; }
  grep -qx -- "openrouter"                 "$argv" || { echo "missing default provider value"; exit 1; }
  grep -qx -- "--model"                    "$argv" || { echo "missing --model flag"; exit 1; }
  grep -qx -- "xiaomi/mimo-v2.5-pro"       "$argv" || { echo "missing model value"; exit 1; }
  grep -qx -- "--thinking"                 "$argv" || { echo "missing --thinking flag"; exit 1; }
  grep -qx -- "medium"                     "$argv" || { echo "missing default thinking value"; exit 1; }
  grep -qx -- "--tools"                    "$argv" || { echo "missing --tools flag"; exit 1; }
  grep -qx -- "bash,read,grep,find,ls"     "$argv" || { echo "wrong tools list"; exit 1; }
  for flag in --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files; do
    grep -qx -- "$flag" "$argv" || { echo "missing $flag"; exit 1; }
  done
  grep -qx -- "--session-dir" "$argv" || { echo "missing --session-dir flag"; exit 1; }
  diff <(printf "%s" "review please") "$case_dir/pi-record/stdin" || { echo "stdin != prompt"; exit 1; }
'
run_case "forwards defaults and pipes prompt on stdin"

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
  grep -qx -- "openai"            "$argv" || { echo "missing provider override"; exit 1; }
  grep -qx -- "high"              "$argv" || { echo "missing thinking override"; exit 1; }
  grep -qx -- "openai/gpt-5"      "$argv" || { echo "missing model override"; exit 1; }
  grep -qx -- "--append-system-prompt"        "$argv" || { echo "missing --append-system-prompt"; exit 1; }
  grep -qx -- "Always end with a haiku."      "$argv" || { echo "missing append-system-prompt value"; exit 1; }
'
run_case "forwards overrides for provider, thinking, model, append-system-prompt"

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

# ---------------------------------------------------------------------------
# GITHUB_OUTPUT write tests (added in Task 7)
# ---------------------------------------------------------------------------

ENV_PRELUDE='
  export PI_PROMPT="hi"
  export PI_MODEL=fake/model
  export GH_TOKEN=ghs_fake
'
ASSERT='
  out="$case_dir/github-output.captured"
  [ -s "$out" ] || { echo "GITHUB_OUTPUT was empty"; exit 1; }
  grep -qE "^exit_code=0$"                          "$out" || { echo "expected exit_code=0"; cat "$out"; exit 1; }
  grep -qE "^session_log=.+session-stub\.jsonl$"    "$out" || { echo "expected session_log path"; cat "$out"; exit 1; }
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
  grep -qE "^exit_code=42$"                         "$out" || { echo "expected exit_code=42"; cat "$out"; exit 1; }
  grep -qE "^session_log=.+session-stub\.jsonl$"    "$out" || { echo "expected session_log even on failure"; cat "$out"; exit 1; }
'
run_case "writes outputs and propagates exit code on pi failure"

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
