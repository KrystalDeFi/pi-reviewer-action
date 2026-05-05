#!/usr/bin/env bash
set -euo pipefail

: "${PI_PROMPT:?PI_PROMPT is required}"
: "${PI_MODEL:?PI_MODEL is required}"
: "${PI_PROVIDER:=openrouter}"
: "${PI_THINKING:=medium}"
: "${PI_APPEND_SYSTEM_PROMPT:=}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PI_TIMEOUT_MINUTES:=15}"
: "${PI_VERBOSE:=true}"

SESSION_DIR="${RUNNER_TEMP:-/tmp}/pi-reviewer-session"
mkdir -p "$SESSION_DIR"

# shellcheck disable=SC2054
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

if [[ "$PI_VERBOSE" == "true" ]]; then
  PI_ARGS+=(--verbose)
fi

echo "::group::pi invocation"
echo "model:    $PI_MODEL"
echo "provider: $PI_PROVIDER"
echo "thinking: $PI_THINKING"
echo "tools:    bash,read,grep,find,ls"
echo "::endgroup::"

set +e
printf '%s' "$PI_PROMPT" | timeout "${PI_TIMEOUT_MINUTES}m" pi "${PI_ARGS[@]}"
EXIT_CODE=$?
set -e

# shellcheck disable=SC2012
LATEST_SESSION="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "exit_code=$EXIT_CODE"
    echo "session_log=${LATEST_SESSION:-}"
  } >> "$GITHUB_OUTPUT"
fi

exit "$EXIT_CODE"
