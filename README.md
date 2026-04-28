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
| `timeout_minutes` | no | `15` | Hard cap on the pi step. |
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
