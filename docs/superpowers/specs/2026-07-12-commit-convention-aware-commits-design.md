# Commit-convention awareness for the docs-sync commit/PR

**Date:** 2026-07-12
**Status:** Approved (design), pending implementation plan

## Problem

docs-sentinel opens a commit (and, on the default-branch path, a PR) to sync documentation with a
code change. Today the commit **subject** is a hardcoded string
(`docs: sync documentation with code changes [skip docs-sentinel]`, `engine/compose-message.sh`)
and the PR **title** is a hardcoded string (`.github/workflows/audit.yml`). Only the commit/PR
**body** comes from the auditor — as free-form markdown prose with no line-length discipline.

Two consequences in repos that lint their commit history (commitlint, gitlint, cocogitto, …):

1. **Body line length.** `@commitlint/config-conventional` enforces `body-max-line-length: 100`
   at error level. The auditor's prose can exceed that, so the sync commit can fail the calling
   repo's own commit lint.
2. **Subject shape.** A repo whose commitlint `type-enum` omits `docs`, or that requires a scope
   (`scope-empty: never`), or enforces a non-default `subject-case`, will reject our hardcoded
   `docs:` subject. A prompt directive alone cannot fix a subject the model never authors.

`docs` *is* in config-conventional's default `type-enum`
(`build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test`) and `100` matches its
default body/header line limits — so the standard preset is already safe; only customized or
non-conventional repos break. This work makes the commit/PR adapt to those repos.

## Goals

- The auditor detects the calling repo's commit-message convention and shapes its commit **subject**
  and **body** to match.
- A sensible, tunable default body line width (100) for repos with no detectable convention.
- Zero regression to the load-bearing loop-breaker (`[skip docs-sentinel]`) and the doc-edit
  guardrail.

## Non-goals

- **No mechanical body re-wrap in the shell.** A bash reflow (`fmt`) mangles markdown bullets,
  inline code, and URLs — worse than an occasional lint *warning*. Body wrapping is best-effort via
  the prompt directive; most doc-sync bullets are short one-liners, and a human reviews every sync
  PR. Only the **subject** gets a hard shell backstop (length cap + fallback).
- No support for authoring the *entire* commit message in the model (rejected: makes the structural
  guarantees depend on the LLM). See "Ownership model".
- No per-rule emulation of a commitlint config in the shell. The agent reads the config and applies
  judgment; the shell only validates the subject it gets back.

## Ownership model

The shell keeps every safety-critical guarantee; the agent only shapes prose.

| Concern | Owner | Guarantee |
|---|---|---|
| `[skip docs-sentinel]` loop-breaker | shell (`compose-message.sh`) | Always appended, **as a footer trailer line** (moved off the subject) so it can never violate a header-length rule or a lint-checked subject. The gate greps the whole message (`grep -qF`), so footer placement is behaviorally identical for the loop guard. |
| Files-updated list | shell | Unchanged. |
| Commit **subject** phrasing | agent proposes, shell validates | Agent emits a `Subject:` line; shell uses it only if non-empty and ≤ 100 chars on one line, else falls back to `docs: sync documentation with code changes`. |
| Body prose + line wrap | agent (best-effort) | Prompt-directed; no mechanical backstop. |

### Why footer relocation is safe

The repo has two independent loop-breakers: (a) the `[skip docs-sentinel]` marker grep over
`github.event.head_commit.message`, and (b) the gate's "only docs/tests/lockfiles changed → skip".
(b) is what actually catches a *merged* sync PR (its push touches only docs); (a) guards the
same-run / direct-push case. Because the gate greps the entire message (subject **and** body),
moving the marker from the subject to a footer line changes nothing for either guard. Tests must
lock this in.

## The agent ↔ shell channel

The auditor runs with `--allowed-tools "Read,Edit,Grep,Glob,Bash(git diff:*)"` — no `Write`, so it
cannot drop a separate subject file. The subject travels through the existing `.result` text
channel (captured to `auditor-summary.md`).

New contract, applied **only to the "edited docs" output shape**: the final message begins with a
single `Subject: <one-line subject>` line, a blank line, then the existing markdown bullet list.

```
Subject: docs(readme): sync dev port in the quick-start

- `README.md` — updated the dev port from 3400 to 3500 to match the server config change.
- `docs/setup.md` — same port change in the quick-start.
```

The "no edits" and "NEEDS HUMAN" shapes are unchanged (no `Subject:` line). This keeps the sticky
no-drift PR-comment path (which reads the raw summary when `changed=false`) untouched.

## Detection directive (prompt)

A new `## Matching the repo's commit convention` section in `engine/prompt-skeleton.md` instructs
the agent to detect the convention **cheaply** (glob first, read only files that exist, never run
build/install), checking:

- **commitlint** — `commitlint.config.{js,cjs,mjs,ts}`, `.commitlintrc`,
  `.commitlintrc.{json,yaml,yml,js,cjs,mjs,ts}`, or a `commitlint` key in `package.json`.
  Note `type-enum`, scope requirement (`scope-empty`), `subject-case`, `body-max-line-length`.
- **Commit templates** — `.gitmessage*`, `CONTRIBUTING*.md`, `.github/COMMIT_CONVENTION.md`.
- **Conventional-Commits-implying tools** — commitizen (`.czrc`, `config.commitizen` in
  `package.json`), cocogitto (`cog.toml`), gitlint (`.gitlint`).

Then shape output:

- **`Subject:`** — prefer `docs: sync documentation with code changes`; add a scope if the repo
  requires one (e.g. `docs(readme):`); if `type-enum` lacks `docs`, use the closest allowed type
  (usually `chore`); respect subject case and header length. **Never** add the
  `[skip docs-sentinel]` marker — the workflow adds it.
- **Body** — wrap every line to the repo's detected `body-max-line-length`, else to
  `{{COMMIT_BODY_LINE_LENGTH}}` characters. Keep each file's bullet on its own line; wrap long
  bullets at word boundaries with the continuation indented two spaces so the markdown list still
  renders. (This one representation is a valid ≤N plain-text commit body **and** a correctly
  continued markdown list item — satisfying both the git-commit-body and PR-description consumers.)

**Precedence: detected repo value > workflow default.**

## The workflow input

```yaml
commit-body-line-length:
  description: Fallback max chars per commit-body line when the repo has no detectable
    commit convention (the auditor honors the repo's own body-max-line-length when found)
  type: string
  default: '100'
```

- Validated as a positive integer before use (fail-closed, mirroring `guardrail.sh`'s budget check).
- Injected into the prompt by substituting the `{{COMMIT_BODY_LINE_LENGTH}}` placeholder after the
  `cat "$ENGINE_DIR/prompt-skeleton.md" "$POLICY_FILE" > prompt.md` step, in **both** `audit-pr`
  and `audit-main`. Substitution uses `sed 'expr' file > tmp && mv tmp file` (portable; the value is
  integer-validated so it carries no sed-special characters).

## `compose-message.sh` changes

1. **Extract subject.** With awk (BSD-safe), peel a leading `^Subject: ` line off the summary; the
   remainder (minus one blank separator line) becomes the body summary. No `Subject:` line → whole
   summary is the body, subject stays empty.
2. **Validate subject.** Fall back to `docs: sync documentation with code changes` when the extracted
   subject is empty or its byte length exceeds a 100-char cap (matches config-conventional
   `header-max-length`; the marker is no longer in the subject, so the whole budget is the agent's).
3. **Commit message shape:**
   ```
   <subject>

   <body summary>

   Files updated:
     - <file>
     ...

   [skip docs-sentinel]
   ```
   The marker is its own final paragraph (footer trailer).
4. **PR body** uses the body summary (subject line stripped) for "What changed and why".
5. **New step output `pr_title`** = the validated subject (marker-free) for the create-pull-request
   `title:`.

## `audit.yml` changes

- Add the `commit-body-line-length` input.
- In `audit-pr` and `audit-main` "Run docs auditor" steps: validate the input is a positive integer,
  build `prompt.md`, then substitute `{{COMMIT_BODY_LINE_LENGTH}}`.
- In `audit-main` "Open / update the rolling docs-sync PR": change
  `title: "docs: sync documentation with code changes"` to
  `title: ${{ steps.compose.outputs.pr_title }}`.

## Tests (`tests/compose-message.bats`)

New cases:
- Summary beginning `Subject: docs(readme): …` → commit subject and `pr_title` equal that subject;
  commit body excludes the `Subject:` line.
- `[skip docs-sentinel]` appears in the composed commit message (as a footer line) and is **absent**
  from the subject line and from `pr_title`.
- No `Subject:` line → subject falls back to the default; marker still in footer.
- Empty or > 100-char subject → falls back to the default.

Also review `tests/*.bats` for any assertion that the marker sits in the subject and update it.

## Docs

- `README.md` — add `commit-body-line-length` to the inputs table; one line on the convention-match
  behavior.
- `AGENT_SETUP.md` — mention the new input where inputs are described.

Because docs-sentinel audits **itself**, a missed README update to the inputs table would be caught
by its own sentinel — a built-in forcing function to keep these in sync.

## Blast radius

- `engine/prompt-skeleton.md`
- `engine/compose-message.sh`
- `.github/workflows/audit.yml`
- `tests/compose-message.bats` (and a scan of the other `.bats` files)
- `README.md`, `AGENT_SETUP.md`
