#!/usr/bin/env bash
set -euo pipefail

: "${PI_PROMPT:?PI_PROMPT is required}"
: "${PI_MODEL:?PI_MODEL is required}"
: "${PI_PROVIDER:=openrouter}"
: "${PI_THINKING:=medium}"
: "${PI_APPEND_SYSTEM_PROMPT:=}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PI_TIMEOUT_MINUTES:=15}"
: "${PI_VERBOSE:=false}"

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

PI_MAX_RETRIES="${PI_MAX_RETRIES:-2}"
ATTEMPT=0
EXIT_CODE=1

# Extract the last error from the most recent session JSONL and print it as a
# GitHub Actions warning so the failure reason is visible in the runner log
# without downloading the artifact.
_dump_session_error() {
  local latest
  latest="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"
  [[ -z "$latest" ]] && return

  local err
  err="$(grep '"stopReason":"error"' "$latest" | tail -1 | \
    sed -n 's/.*"errorMessage":"\([^"]*\)".*/\1/p')"
  if [[ -n "$err" ]]; then
    echo "::warning::pi error: $err"
  fi
}

while [[ $ATTEMPT -le $PI_MAX_RETRIES ]]; do
  if [[ $ATTEMPT -gt 0 ]]; then
    DELAY=$(( 5 * ATTEMPT ))
    echo "::warning::pi exited $EXIT_CODE on attempt $ATTEMPT — retrying in ${DELAY}s ($(( PI_MAX_RETRIES - ATTEMPT + 1 )) left)"
    sleep "$DELAY"
  fi
  ATTEMPT=$(( ATTEMPT + 1 ))

  # Tail the session JSONL in the background so the runner log shows live
  # progress instead of being silent for minutes. Wait for pi to create a
  # NEW file (not one from a previous attempt), then tail -f into a single
  # node process that formats each event.
  PREV_SESSION="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"
  {
    for _ in $(seq 1 30); do
      SESSION_FILE="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"
      [[ -n "$SESSION_FILE" && "$SESSION_FILE" != "$PREV_SESSION" ]] && break
      sleep 1
    done
    [[ -n "$SESSION_FILE" && "$SESSION_FILE" != "$PREV_SESSION" ]] && \
      tail -n +1 -f "$SESSION_FILE" 2>/dev/null
  } | node -e '
    const rl = require("readline").createInterface({ input: process.stdin });
    rl.on("line", (line) => {
      try {
        const e = JSON.parse(line);
        if (e.type !== "message") return;
        const m = e.message;
        if (m.role === "assistant") {
          for (const c of m.content || []) {
            if (c.type === "text" && c.text) console.log("[pi]", c.text.slice(0, 200));
            if (c.type === "toolCall") console.log("[pi] >", c.name, JSON.stringify(c.arguments).slice(0, 150));
          }
          if (m.stopReason === "error") console.log("[pi] ERROR:", m.errorMessage || "unknown error");
        } else if (m.role === "toolResult") {
          const s = m.isError ? "ERR" : "ok";
          console.log("[pi] <", m.toolName, "[" + s + "]");
        }
      } catch {}
    });
  ' &
  TAIL_PID=$!

  set +e
  printf '%s' "$PI_PROMPT" | timeout "${PI_TIMEOUT_MINUTES}m" pi "${PI_ARGS[@]}"
  EXIT_CODE=$?
  set -e

  kill "$TAIL_PID" 2>/dev/null; wait "$TAIL_PID" 2>/dev/null || true

  if [[ $EXIT_CODE -eq 0 ]]; then
    break
  fi

  _dump_session_error
done

# shellcheck disable=SC2012
LATEST_SESSION="$(ls -1t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "exit_code=$EXIT_CODE"
    echo "session_log=${LATEST_SESSION:-}"
  } >> "$GITHUB_OUTPUT"
fi

exit "$EXIT_CODE"
