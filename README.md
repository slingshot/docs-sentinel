<div align="center">

# 🛰️ Docs Sentinel

**CI that keeps your docs telling the truth.**

*An AI documentation auditor wrapped in a mechanical guardrail it cannot talk its way past —*
*shipped as a single reusable GitHub Actions workflow.*

[![CI](https://github.com/slingshot/docs-sentinel/actions/workflows/ci.yml/badge.svg)](https://github.com/slingshot/docs-sentinel/actions/workflows/ci.yml)
[![Version](https://img.shields.io/github/v/tag/slingshot/docs-sentinel?label=version&sort=semver&color=6f42c1)](https://github.com/slingshot/docs-sentinel/tags)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Quickstart](#quickstart) · [Inputs](#inputs) · [How it works](#how-it-works) · [Degradation modes](#degradation-modes) · [FAQ](#faq)

</div>

---

On every pull request and push to your default branch, an AI auditor reads the code diff, finds
any documentation the change made inaccurate, and fixes it — surgically.

- 🔧 **On a PR** — doc fixes are committed straight to the PR branch, and one sticky status comment
  reports the result: drift found and fixed, or "no drift" (never silence, never comment spam).
- 🔁 **On a push to your default branch** — it maintains a single rolling draft **docs-sync PR**
  (dependabot-style: one fixed branch, always rebased, accumulates un-merged fixes).
- 🚦 **A gate runs first** — you never pay for model calls on docs-only, test-only, or
  lockfile-only changes.
- 🛡️ **A guardrail runs after** — the auditor's edits must stay inside YOUR doc allowlist and under
  a churn budget (default 15 files / 800 lines), or every edit is reverted and the job fails.
- 🧾 **Receipts included** — commit messages and PR bodies are built from the auditor's own summary
  plus the actual doc diff, so you always see exactly what changed and why.
- ✍️ **Convention-aware commits** — the auditor detects your commit rules (commitlint config, commit
  templates, commitizen/cocogitto/gitlint) and shapes the sync commit's subject and body to match;
  `commit-body-line-length` (default 100) is the fallback wrap for repos with no convention.

## Quickstart

> **🤖 Setting up with an AI agent?** Paste this into Claude Code, Cursor, or any coding agent
> with access to your repo, and skip straight to [step 3 (secrets)](#3-add-secrets):
>
> ```text
> Set up docs-sentinel (an AI docs-drift auditor that runs in GitHub Actions CI) in this
> repository. Fetch https://raw.githubusercontent.com/slingshot/docs-sentinel/v1/AGENT_SETUP.md
> and follow it exactly: survey this repo's documentation layout, create the caller workflow
> and policy file tailored to it, then tell me which secrets to add and how to verify the
> first run.
> ```
>
> The full agent-facing guide lives at [`AGENT_SETUP.md`](AGENT_SETUP.md) — it always matches
> the workflow version served by the `v1` tag.

### 1. Add the caller workflow

Copy [`examples/caller-workflow.yml`](examples/caller-workflow.yml) to
`.github/workflows/docs-sentinel.yml`:

```yaml
name: Docs Sentinel
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    branches: [main]
  push:
    branches: [main]
permissions:          # a called workflow can only downgrade these — you must grant them
  contents: write
  pull-requests: write
jobs:
  docs-sentinel:
    uses: slingshot/docs-sentinel/.github/workflows/audit.yml@v1
    secrets:
      MODEL_API_KEY: ${{ secrets.MODEL_API_KEY }}
      SYNC_PR_TOKEN: ${{ secrets.SYNC_PR_TOKEN }}
    with:
      allowlist-regex: '^(README\.md|docs/.*)$'
```

### 2. Write your policy file

Create `.github/docs-sentinel/policy.md` — the repo-specific half of the auditor's prompt: the
documentation rule you enforce, the exact docs in scope, and what to cross-check. Start from
[`examples/policy.md`](examples/policy.md).

### 3. Add secrets

| Secret | Required | What it is |
|---|---|---|
| `MODEL_API_KEY` | Yes* | API key for the model gateway (an [OpenRouter](https://openrouter.ai) key by default). *Until set, the workflow no-ops gracefully — safe to merge the caller first. |
| `SYNC_PR_TOKEN` | Recommended | A PAT or GitHub App token used to open the rolling docs-sync PR so your CI runs on it. Without it, the PR opens via `GITHUB_TOKEN` and its checks won't auto-trigger. |

That's it. Open a PR that changes code a doc describes, and watch the sticky comment appear.

## Inputs

All inputs are optional.

| Input | Default | Purpose |
|---|---|---|
| `policy-file` | `.github/docs-sentinel/policy.md` | Repo-specific auditor policy (the job fails with a clear error if the file is missing) |
| `allowlist-regex` | `^(AGENTS\.md\|CLAUDE\.md\|README\.md\|docs/.*\|.*/CLAUDE\.md\|.*/AGENTS\.md\|.*/README\.md\|\.claude/skills/.*)$` | Anchored ERE — the ONLY paths the auditor may edit |
| `denylist-regex` | `(^\|/)CHANGELOG\.md$` | Forbidden even if allowlisted |
| `file-budget` | `15` | Max files the auditor may change |
| `line-budget` | `800` | Max total changed lines |
| `commit-body-line-length` | `100` | Fallback max chars per commit-body line when the repo has no detectable commit convention (the auditor matches the repo's own `body-max-line-length` when it finds one) |
| `skip-if-only-regex` | docs/tests + common lockfiles | Gate skips (no model call) when EVERY changed file matches |
| `diff-exclude` | common lockfiles | File patterns excluded from the diff text shown to the auditor |
| `sync-branch` | `docs/sync` | Fixed branch for the rolling docs-sync PR |
| `runner` | `ubuntu-latest` | Runner label for all jobs |
| `claude-code-version` | `2.1.223` | Pinned `@anthropic-ai/claude-code` npm version |
| `anthropic-base-url` | `https://openrouter.ai/api` | Model gateway base URL |
| `model` | `~deepseek/deepseek-v4-flash-latest` | Main auditor model |
| `small-model` | `~deepseek/deepseek-v4-flash-latest` | Background/summarization model |
| `use-bearer-auth` | `true` | `true`: OpenRouter-style bearer auth. `false`: Anthropic-native `ANTHROPIC_API_KEY` |

The leading `~` is OpenRouter's marker for a *floating* alias: `~deepseek/deepseek-v4-flash-latest`
follows DeepSeek's current Flash build, so the auditor stays current without a bump here. Pass a
dated slug (e.g. `deepseek/deepseek-v4-flash-0731`) if you'd rather pin it.

## Using Anthropic directly (instead of OpenRouter)

```yaml
    secrets:
      MODEL_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    with:
      use-bearer-auth: false
      anthropic-base-url: ''     # clear the gateway -> Anthropic's endpoint
      model: ''                  # clear the slugs -> Claude Code's default models
      small-model: ''
```

Any Anthropic-compatible gateway works the same way: point `anthropic-base-url` at it and set
`model` / `small-model` to its slugs.

## How it works

```
                    ┌─────────────────────────────────────────────┐
 PR / push ───────▶ │ gate: skip forks, drafts, [skip docs-       │
                    │ sentinel] commits, docs/tests/lockfile-only │
                    │ diffs; compute the diff range               │
                    └───────────────┬─────────────────────────────┘
                                    │ run=true
              ┌─────────────────────┴──────────────────────┐
              ▼ (pull_request)                             ▼ (push)
   ┌────────────────────────┐                  ┌────────────────────────┐
   │ audit-pr               │                  │ audit-main             │
   │ diff context → auditor │                  │ same audit …           │
   │ → guardrail → commit   │                  │ → rolling draft        │
   │ to PR branch + sticky  │                  │ docs-sync PR (one      │
   │ status comment         │                  │ branch, always rebased)│
   └────────────────────────┘                  └────────────────────────┘
```

The auditor is the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI run
non-interactively with a locked-down tool set (`Read`, `Edit`, `Grep`, `Glob`, read-only
`git diff`) — it cannot run builds, create files, or touch the network. The prompt is a generic
skeleton ([`engine/prompt-skeleton.md`](engine/prompt-skeleton.md)) concatenated with your policy
file. After it runs, [`engine/guardrail.sh`](engine/guardrail.sh) mechanically enforces your
allowlist and churn budgets — a misbehaving model gets its edits reverted, not merged.

## Degradation modes

- **No `MODEL_API_KEY`:** the gate no-ops with a log line. Merge the caller first, add the key later.
- **No `SYNC_PR_TOKEN`:** the docs-sync PR opens via `GITHUB_TOKEN` with a warning; its CI checks
  won't auto-trigger until you provide a PAT/App token.
- **Missing policy file:** the audit job fails fast, naming the expected path.
- **Guardrail violation:** all auditor edits are reverted and the job fails loudly.
- **Fork PRs and drafts:** skipped at the gate.

## FAQ

**Why does the sync PR need a PAT?** GitHub suppresses `workflow` events for pushes made with the
default `GITHUB_TOKEN` (to prevent recursive workflows), so a sync PR opened with it never runs
your CI. A fine-grained PAT (contents + pull-requests: write) or a GitHub App token fixes that.

**Will it loop on its own commits?** No — its commits carry `[skip docs-sentinel]`, and the gate
also skips any diff that touches no source files.

**What if the same fact lives in five docs?** That's the point: the policy tells the auditor to
update every place a fact appears, and the sticky comment/PR body lists each file with the reason.

## License

[MIT](LICENSE)
