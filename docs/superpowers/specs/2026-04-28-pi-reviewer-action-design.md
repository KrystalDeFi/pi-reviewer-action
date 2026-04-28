# pi-reviewer-action — Design

**Status:** Draft
**Date:** 2026-04-28
**Author:** Krystal eng
**Reference:** [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) (architectural inspiration only — we do not match its feature set)

---

## 1. Goal

Build a reusable GitHub Action — `KrystalDeFi/pi-reviewer-action` — that runs the [`pi-coding-agent`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) CLI against a pull request to perform code review. The action is consumed from any caller workflow with the shape:

```yaml
- name: Pi reviewer
  id: review
  uses: KrystalDeFi/pi-reviewer-action@v1
  env:
    OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_REVIEWER_API_KEY }}
  with:
    prompt: |
      REPO: ${{ github.repository }}
      PR NUMBER: ${{ github.event.pull_request.number }}
      Please review this pull request ...
    model: xiaomi/mimo-v2.5-pro
```

The agent itself fetches the diff (via `gh pr diff`) and posts review comments (via `gh pr review` / `gh api`). The action is a thin shell around `pi --print`; it does not pre-fetch context or post-process model output.

## 2. Non-goals (v1)

The following claude-code-action features are explicitly out of scope:

- Sticky tracking comment / progress checkboxes
- Inline-comment classification (real review vs. test/probe buffering)
- Mode auto-detection (PR vs. issue vs. dispatch)
- First-party MCP servers wrapping the GitHub API
- Commit signing / SSH signing
- GitHub App authentication (only `${{ github.token }}` / PAT)
- Plugin or skill installation
- Subprocess sandboxing (bubblewrap) for untrusted input
- Auto-fix / branch creation / PR opening

If any of these become necessary, they are follow-on work.

## 3. Architecture

**Composite GitHub Action.** No Docker, no bundled JS, no TypeScript. Just `action.yml` plus a small bash script. Pi is installed at runtime via `npm install -g`.

### 3.1 Repository layout

```
pi-reviewer-action/
├── action.yml                  # composite action manifest, ~80 lines
├── README.md                   # how to use, examples, permissions matrix
├── LICENSE                     # MIT
├── .github/
│   └── workflows/
│       ├── self-test.yml       # exercises the action on its own PRs
│       └── release.yml         # tags v1, v1.x, latest pointers
├── examples/
│   ├── pr-review.yml           # the canonical example
│   └── path-filtered.yml       # only review when src/** changes
└── scripts/
    └── run-pi.sh               # the actual pi invocation
```

Total LoC target: ~150 lines (action.yml + bash script).

### 3.2 Why composite (not Docker, not bundled-JS)

| Approach | Verdict | Reason |
|---|---|---|
| Composite + npm install pi | **chosen** | Pi is an npm package; `setup-node` caches; transparent; ~20–40s cold start, faster cached. |
| Docker container action | rejected | Linux-only; image build/push pipeline overhead; pi already installs cleanly via npm. |
| JS Node20 action with bundled `dist/` | rejected | Pi has 30+ deps and binary assets (photon-node wasm); bundling is fragile and obscures behavior. |

claude-code-action itself is a composite action (using Bun + raw TypeScript); we follow the same shape with Node + bash.

## 4. action.yml shape

```yaml
name: 'Pi Reviewer'
description: 'Run a pi-mono coding agent against a PR for review'
branding:
  icon: 'message-circle'
  color: 'purple'

inputs:
  prompt:               { required: true }
  model:                { required: true }
  provider:             { default: 'openrouter' }
  thinking:             { default: 'medium' }
  pi_version:           { default: '0.70.5' }
  github_token:         { default: '${{ github.token }}' }
  working_directory:    { default: '${{ github.workspace }}' }
  timeout_minutes:      { default: '15' }
  append_system_prompt: { default: '' }

outputs:
  exit_code:    { value: '${{ steps.run.outputs.exit_code }}' }
  session_log:  { value: '${{ steps.run.outputs.session_log }}' }

runs:
  using: composite
  steps:
    - name: Setup Node
      uses: actions/setup-node@v4
      with: { node-version: '20', cache: 'npm' }

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
      timeout-minutes: ${{ fromJSON(inputs.timeout_minutes) }}
      env:
        GH_TOKEN: ${{ inputs.github_token }}
        PI_PROMPT: ${{ inputs.prompt }}
        PI_MODEL: ${{ inputs.model }}
        PI_PROVIDER: ${{ inputs.provider }}
        PI_THINKING: ${{ inputs.thinking }}
        PI_APPEND_SYSTEM_PROMPT: ${{ inputs.append_system_prompt }}
      run: ${{ github.action_path }}/scripts/run-pi.sh

    - name: Upload session log
      if: always() && steps.run.outputs.session_log != ''
      uses: actions/upload-artifact@v4
      with:
        name: pi-reviewer-session-${{ github.run_id }}-${{ github.run_attempt }}
        path: ${{ steps.run.outputs.session_log }}
        if-no-files-found: ignore
```

### 4.1 Notes on the manifest

- **`*_API_KEY` envs are inherited from the caller** (e.g. `OPENROUTER_API_KEY`) — composite actions inherit parent `env:` unless shadowed. We do not declare them here.
- **`GH_TOKEN`** is set explicitly so `gh` works inside pi's bash tool without `gh auth login`.
- **`fromJSON(inputs.timeout_minutes)`** coerces the string input to a number for the `timeout-minutes` field, which requires a number.
- **Session log artifact** uses `if: always()` so it uploads on success, failure, and timeout. `if-no-files-found: ignore` makes it a no-op if pi crashed before writing anything.

## 5. scripts/run-pi.sh

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

{
  echo "exit_code=$EXIT_CODE"
  echo "session_log=${LATEST_SESSION:-}"
} >> "$GITHUB_OUTPUT"

exit "$EXIT_CODE"
```

### 5.1 Notes on the script

- **Prompt piped on stdin**, not passed as argv. Pi's `--print` mode merges piped stdin into the initial prompt. This sidesteps shell-quoting issues for prompts containing `$`, backticks, or newlines.
- **`set +e` around the pi call** so we can capture `$?`, write outputs, and still propagate the original exit code. Without this, a non-zero pi exit would skip the `$GITHUB_OUTPUT` writes.
- **`--session-dir` points at runner temp**, isolated from the repo checkout.
- **Hardcoded flags** (`--no-extensions`, `--no-skills`, `--no-prompt-templates`, `--no-themes`, `--no-context-files`) keep CI deterministic; user-side `.pi/` configs do not influence the run.
- **`--tools bash,read,grep,find,ls`** omits the mutating `write` and `edit` tools. `bash` is still allowed (required for `gh`), so the surface is "read-only-by-default" rather than strictly read-only — the model could theoretically mutate via shell. We rely on prompt intent + the runner's ephemeral checkout to keep this safe; a stricter sandbox is out of scope for v1.

## 6. Data flow

```
┌────────────────────────────────────────────────────────┐
│ Caller workflow                                         │
│   on: pull_request                                      │
│   permissions: { contents: read, pull-requests: write } │
│   env: { OPENROUTER_API_KEY: ${{ secrets.OPENROUTER }} }│
│   uses: KrystalDeFi/pi-reviewer-action@v1               │
└──────────────────────┬─────────────────────────────────┘
                       │ inputs + env inherited
                       ▼
┌────────────────────────────────────────────────────────┐
│ action.yml (composite)                                  │
│   1. setup-node@v4 (cached)                             │
│   2. npm install -g pi-coding-agent@<pinned>            │
│   3. gh --version                                       │
│   4. scripts/run-pi.sh   ← env: GH_TOKEN, PI_*          │
│   5. upload-artifact (session log)                      │
└──────────────────────┬─────────────────────────────────┘
                       │ stdin = prompt; argv = pi flags
                       ▼
┌────────────────────────────────────────────────────────┐
│ pi --print --tools bash,read,grep,find,ls               │
│   • model fetches diff via:  bash → gh pr diff          │
│   • model reads files via:   read / grep / find / ls    │
│   • model posts comments via: bash → gh pr review /     │
│                                gh api ...               │
│   • streams turns to stdout (action log)                │
│   • writes JSONL to $RUNNER_TEMP/pi-reviewer-session/   │
└──────────────────────┬─────────────────────────────────┘
                       │ exit code + session log path
                       ▼
            $GITHUB_OUTPUT  →  action outputs
                              session log → workflow artifact
```

### 6.1 Auth chain

- `OPENROUTER_API_KEY` (caller `env:`) → inherited by composite step → pi reads from `process.env`
- `${{ github.token }}` → `inputs.github_token` → `GH_TOKEN` env var → `gh` CLI inside pi's bash tool

### 6.2 Caller workflow prerequisites

The caller workflow is responsible for:

- Running `actions/checkout` before invoking the action (so `working_directory` contains the PR's source).
- Setting the appropriate `*_API_KEY` env at the job or step level.
- Declaring permissions per the matrix below.

#### Permissions matrix

| Permission | Why |
|---|---|
| `contents: read` | Checkout, `gh pr diff`, `gh pr view` |
| `pull-requests: write` | `gh pr review`, `gh pr comment`, `gh api ... /reviews` |
| `issues: write` | Only if the caller wants pi to comment on linked issues (out of scope for v1) |

The README documents this matrix.

### 6.3 What the action does NOT do (the model does, via prompt)

- Fetch the PR diff
- Decide what to comment on
- Format inline comments
- Avoid duplicate comments (the prompt instructs the model)

## 7. Inputs and outputs

### 7.1 Inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `prompt` | yes | — | Instructions for the model |
| `model` | yes | — | Model ID (e.g. `xiaomi/mimo-v2.5-pro`); supports `provider/id` syntax |
| `provider` | no | `openrouter` | Pi provider name |
| `thinking` | no | `medium` | `off`/`minimal`/`low`/`medium`/`high`/`xhigh` |
| `pi_version` | no | `0.70.5` (pinned) | npm version of `@mariozechner/pi-coding-agent` |
| `github_token` | no | `${{ github.token }}` | Token used for `gh` CLI |
| `working_directory` | no | `${{ github.workspace }}` | Where pi runs |
| `timeout_minutes` | no | `15` | Hard cap on the pi step |
| `append_system_prompt` | no | `""` | Extra system instructions (e.g. team review rubric) |

### 7.2 Outputs

| Output | Purpose |
|---|---|
| `exit_code` | Pi's exit code (callers can branch on it) |
| `session_log` | Path to pi's session JSONL (also uploaded as artifact) |

### 7.3 Env (forwarded to pi)

- `OPENROUTER_API_KEY` (and any other `*_API_KEY` the caller workflow sets — pi auto-discovers from env)
- `GH_TOKEN` = `inputs.github_token` — so `gh` works without manual login

## 8. Error handling

| Failure | Where caught | Behavior |
|---|---|---|
| `OPENROUTER_API_KEY` missing | Pi's provider init | Pi exits non-zero with provider error in stdout. Step fails. |
| `GH_TOKEN` missing | `run-pi.sh` env guard | Script exits 1 before invoking pi. |
| `pi_version` doesn't exist on npm | `npm install -g` step | Step fails immediately. |
| Network flake during install | `npm install -g` | Fails. setup-node's npm cache reduces blast radius. No retry inside the action. |
| Model error / rate limit | Pi's provider client | Pi exits non-zero. Stdout shows provider error. |
| `gh pr review` fails (permissions) | Pi's bash tool surfaces stderr | Model sees failure and may retry or give up. Step exit reflects pi's final state. |
| Step exceeds `timeout_minutes` | GHA `timeout-minutes` | Step is killed. Session log artifact still uploaded by `if: always()` upload step. |
| Pi crashes mid-session | `run-pi.sh` exit-code capture | `exit_code` and `session_log` outputs still written; artifact still uploaded. |

**Principle:** the action does not swallow errors or retry. Workflow authors compose retry / notification logic in their workflow, not inside the action.

## 9. Testing

Three layers:

1. **Local script test** — run `./scripts/run-pi.sh` with env vars set and a mocked `GITHUB_OUTPUT=/tmp/out.txt` against a real OpenRouter key. Trivial prompt ("say hi"). Verify exit 0 and outputs written. No CI infra needed.
2. **Action self-test workflow** (`.github/workflows/self-test.yml`) — `on: pull_request` against the action's own repo. Step uses `./` (the action itself), instructs pi to post one summary comment, then asserts the comment exists via `gh pr view --json comments`.
3. **Consumer smoke test** — the canonical example workflow in `examples/pr-review.yml` is copy-pasted into a downstream test repo before promoting `@v1` → `@latest`.

Out of scope: unit tests for the bash script (~30 lines, mostly env wiring), pi mocks, TypeScript test infra.

## 10. Release / versioning

- Action versioned as `v1`, `v1.x.y`. `@v1` is a moving major-tag pointing at the latest `v1.x.y`.
- `pi_version` input is bumped per action release with a vetted pi upgrade. Callers can override.
- Release workflow (`.github/workflows/release.yml`) is invoked manually; bumps the major-tag and creates a GitHub Release.

## 11. Open questions for implementation

None blocking. Items to confirm during implementation:

- The exact `--session-dir` flag name and whether pi's session JSONL filename is predictable (need to verify by reading pi source or running locally).
- Whether `gh` is preinstalled on all GitHub-hosted runner images we care about (it is on `ubuntu-latest`, `windows-latest`, `macos-latest` per GitHub docs — confirm before release).
- Concrete `pi_version` to pin for the v1 release (depends on whichever pi version is current and stable when we cut v1).
