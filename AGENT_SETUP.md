# Agent setup guide

Instructions for an AI coding agent installing **docs-sentinel** — a CI workflow that audits every
code change for documentation drift and fixes the affected docs — into the repository you are
currently working in. Follow the steps in order. Everything you need is in this file; the
human-facing reference (inputs table, FAQ, degradation modes) is the
[README](https://github.com/slingshot/docs-sentinel#readme).

**Ground rules:**
- You will create exactly two files: a caller workflow and a policy file. Do not modify any other
  file, do not create documentation files that don't exist yet, and never write secret values into
  any file.
- Where this guide says *survey the repo*, actually look — the value of the setup is that the
  allowlist and policy describe THIS repository's real documentation, not a generic template.
- If the repository already has `.github/workflows/docs-sentinel.yml` or
  `.github/docs-sentinel/policy.md`, stop and ask the human before overwriting.

## Step 1 — Survey the repository's documentation

Identify:

1. **The default branch** (`git symbolic-ref refs/remotes/origin/HEAD` or ask the human). The
   workflow below assumes `main` — adjust both `branches:` filters if it differs.
2. **Every "living" doc that states facts about the code** — files that claim what a command,
   port, env var, schema, API route, or convention *is*. Typical candidates: root `README.md`,
   `docs/**`, `AGENTS.md` / `CLAUDE.md` / `.cursorrules`-style agent guides (root and nested),
   package-level READMEs, `.claude/skills/**`.
3. **Docs that must never be auto-edited** — generated changelogs, dated ADRs/specs/postmortems,
   vendored docs, license files.
4. **The facts most likely to drift** — where do commands/ports/env vars/schemas live in the
   source? (e.g. `package.json` scripts, a CLI directory, `src/db/schema/`). These become the
   policy's "triggers" and "how to verify facts" sections.

## Step 2 — Create the caller workflow

Write `.github/workflows/docs-sentinel.yml`. Template — replace the `allowlist-regex` (and
`denylist-regex` if needed) with an **anchored POSIX ERE** built from your Step 1 survey; keep it
as narrow as the repo's real doc surface:

```yaml
name: Docs Sentinel

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    branches: [main]
  push:
    branches: [main]

# A called workflow can only DOWNGRADE these — the caller must grant them.
permissions:
  contents: write
  pull-requests: write

jobs:
  docs-sentinel:
    uses: slingshot/docs-sentinel/.github/workflows/audit.yml@v1
    secrets:
      MODEL_API_KEY: ${{ secrets.MODEL_API_KEY }}
      SYNC_PR_TOKEN: ${{ secrets.SYNC_PR_TOKEN }}
    with:
      allowlist-regex: '^(README\.md|docs/.*|.*/README\.md)$'
      # denylist-regex: '(^|/)CHANGELOG\.md$'   # default; extend if Step 1 found more no-touch docs
```

Notes:
- The defaults (budgets 15 files / 800 lines, lockfile skip list, `docs/sync` branch, GLM-5.2 via
  OpenRouter) are sensible — only add `with:` keys the survey justifies. Full inputs table:
  [README → Inputs](https://github.com/slingshot/docs-sentinel#inputs).
- If the repo pays for Anthropic directly instead of OpenRouter, use the
  [Anthropic-native recipe](https://github.com/slingshot/docs-sentinel#using-anthropic-directly-instead-of-openrouter).
- The sync commit auto-matches your repo's commit convention (commitlint, commit templates,
  commitizen/cocogitto/gitlint); `commit-body-line-length` (default 100) tunes the fallback body
  wrap for repos with no detectable convention.

## Step 3 — Write the policy file

Write `.github/docs-sentinel/policy.md`. This is the repo-specific half of the auditor's prompt —
it is appended to a generic skeleton that already covers *how* to edit (minimal diffs, no new
files, output format), so cover only *what*:

```markdown
## The rule you are enforcing

> Documentation must stay current with every change: whenever a change alters a command, port,
> env var, schema, API route, or convention that an in-scope doc describes, the affected doc must
> be updated in the same change.

## Documentation in scope (the ONLY files you may edit)

- **`README.md`** (root) — <what facts it states, from your survey>
- **`docs/**`** — <same>
<!-- one bullet per doc family found in Step 1; name concrete paths -->

## Out of scope — never touch

- <the no-touch docs from Step 1, e.g. any `CHANGELOG.md` (generated)>

## Triggers worth checking specifically

Cross-reference the diff against the docs when it touches any of: <the drift-prone fact
locations from Step 1, e.g. `package.json` scripts; dev/server ports; env vars; DB schema;
API route prefixes; project layout>.

## How to verify facts

Read the source directly — e.g. <where commands/ports/schemas actually live> — with
Read/Grep/Glob. Never run build, install, or dev commands.
```

Fill every `<placeholder>` from the survey. The in-scope list and the `allowlist-regex` must
agree: every path the policy names should match the regex, and vice versa.

## Step 4 — Tell the human about secrets (do not create them yourself)

The workflow no-ops gracefully until secrets exist, so the files are safe to merge first. Tell
the human to run:

```bash
gh secret set MODEL_API_KEY --repo <owner>/<repo>   # an OpenRouter API key (openrouter.ai)
gh secret set SYNC_PR_TOKEN --repo <owner>/<repo>   # optional but recommended: a fine-grained PAT
                                                    # (contents + pull-requests: write) so the
                                                    # docs-sync PR triggers their CI
```

## Step 5 — Verify

1. Commit both files on a branch (conventional message, e.g.
   `ci: add docs-sentinel documentation audit`), push, open a PR.
2. On the PR, expect a `Docs Sentinel / Gate` check. Before secrets are set it logs
   `MODEL_API_KEY is not configured` and skips — that's the graceful degradation working.
3. After `MODEL_API_KEY` is set, push any source-touching commit: the audit job runs and exactly
   one sticky status comment (marker `<!-- docs-sentinel-status -->`) appears — either "no
   documentation drift detected" or a doc-fix commit pushed to the branch with the changed files
   and diff in the comment.
4. Report to the human: which files you created, the allowlist you derived (and from what), which
   secrets they still need to add, and what the first run showed.
