# Auditor output hygiene and privilege reduction (v1.1 hotfix)

**Date:** 2026-08-08
**Status:** Approved (design), pending implementation plan
**Scope:** the **current** Claude Code harness. No migration. See
[the Pi/benchmark spec](2026-08-08-pi-harness-and-model-benchmark-design.md) for v2.

## Why this is separate from the Pi migration

The original design folded the incident fix into a harness migration. Review established that the
incident fix does **not** require one: `claude -p --output-format stream-json` already emits typed
content blocks, so reasoning and tool framing can be excluded structurally on the harness we run
today. Verified empirically against Claude Code 2.1.226:

```
$ claude -p "Reply with exactly: OK" --output-format stream-json --verbose
{"t":"assistant","blocks":["text"]}
```

Production is currently posting corrupted public PR comments and carries two live security defects.
That work must not wait for a migration. Pi remains justified on separate grounds (provider-native
benchmark fairness, deleting the model-capabilities env-var apparatus) and ships as v2.

## Problems

### P1 — Tool-call framing leak destroys the verdict

PRs [#8](https://github.com/heysanil/invisible-string/pull/8) and
[#11](https://github.com/heysanil/invisible-string/pull/11) posted comments whose entire body was
`</｜DSML｜parameter> </｜DSML｜invoke> </｜DSML｜tool_calls>` — DeepSeek DSML special tokens
(`｜` = U+FF5C) that escaped OpenRouter's Anthropic-compat shim into the assistant's text. The real
verdict was lost, and the comment still rendered under **"no documentation drift detected"**.

### P2 — Reasoning leak buries the verdict

PRs [#9](https://github.com/heysanil/invisible-string/pull/9),
[#10](https://github.com/heysanil/invisible-string/pull/10),
[#12](https://github.com/heysanil/invisible-string/pull/12) posted full chain-of-thought with the
conclusion buried at the end.

Both enter at `audit.yml:340` (duplicated at `:598`), which treats `jq -r '.result'` — a
pre-flattened string — as a trusted structured field and pipes it into a public comment and a git
commit body.

### P3 — `Bash(git diff:*)` permits arbitrary file creation (live security defect)

`--allowed-tools` prefix-matching makes `git diff --output=<path>` reachable. Verified:

```
$ git diff --output=/tmp/gdtest.out HEAD~1 HEAD   →   19551 bytes written
```

This defeats the assumption `guardrail.sh:32` documents verbatim — "Write is disallowed, so there
are no untracked files to consider" — because the guardrail enumerates only tracked modifications
(`guardrail.sh:37`). The model can create files the guardrail never inspects.

### P4 — The model API token is written to a file the model can read (live security defect)

`audit.yml:296` (and `:558`) writes `ANTHROPIC_AUTH_TOKEN=$MODEL_KEY` into `$GITHUB_ENV`, an
on-disk file. The auditor is granted `Read`. Combined with P3 — which supplies a write primitive —
this is an exfiltration path in a job holding `contents: write`.

## Goals

- Reasoning and tool framing cannot reach the summary, enforced structurally.
- Unusable output is detected mechanically, retried once, and reported honestly.
- **An inconclusive audit is never rendered as a clean pass**, on any path, including no-edit runs.
- Execution failures never land edits.
- P3 and P4 closed.

## Non-goals

- No harness migration (v2).
- No benchmark (v2).
- No LLM judge anywhere.

## P3 / P4 fixes

**P3.** Remove `Bash(git diff:*)` from `--allowed-tools`, leaving `Read,Edit,Grep,Glob`. The full
unified diff is already in `.docs-sentinel-context.md`, so the grant was near-redundant. Remove the
sentence in `prompt-skeleton.md:15-16` offering `git diff`.

**P4.** Stop writing the credential to `$GITHUB_ENV`. The routing step continues to write non-secret
configuration there; the secret is injected in-process on the auditor step only:

```yaml
env:
  ANTHROPIC_AUTH_TOKEN: ${{ inputs.use-bearer-auth && secrets.MODEL_API_KEY || '' }}
  ANTHROPIC_API_KEY:    ${{ !inputs.use-bearer-auth && secrets.MODEL_API_KEY || '' }}
```

Note the negation on the second line. GitHub's `&&`/`||` return *operands*, and `''` is falsy, so
the intuitive `inputs.use-bearer-auth && '' || secrets.MODEL_API_KEY` resolves to the secret on the
bearer path — handing the key to both variables, the opposite of v1's deliberate blanking.

Additionally set `persist-credentials: false` on the `audit-main` checkout —
`create-pull-request` supplies its own token — so git push credentials are not on disk during the
model step.

## Architecture

```
gate → build-context.sh ─┐
                         ↓
   ┌──────────────── run-auditor.sh ───────────────────────────┐
   │  attempt: claude -p --output-format stream-json           │
   │        → classify-run  (execution OK?)                    │
   │        → extract-summary.sh  (typed text blocks + fence)  │
   │        → validate-summary.sh (shape + tree agreement)     │
   │     ↑── reset tree, regenerate context, retry once ───┘   │
   └───────────────────────┬───────────────────────────────────┘
                           ↓
        summary.md  |  degraded=<hygiene|execution>
                           ↓
   guardrail.sh → compose-message.sh → commit / PR
                           ↓
        status-comment  (always runs; owns ALL rendering)
```

## Components

| File | Status | Responsibility |
|---|---|---|
| `engine/run-auditor.sh` | **new** | Attempt loop: invoke, classify, extract, validate, reset, retry once, emit `degraded` |
| `engine/extract-summary.sh` | **new** | Typed-block extraction + fence selection |
| `engine/validate-summary.sh` | **new** | Shape + tree-agreement check; pure function of its inputs |
| `engine/guardrail.sh` | modified | Also fail on untracked files |
| `engine/compose-message.sh` | modified | Unchanged semantics; only reached on a clean run with edits |
| `engine/prompt-skeleton.md` | modified | Drop `git diff` offer; add fence contract |
| `.github/workflows/audit.yml` | modified | P3/P4; single always-run status step; timeout raised |

### Run classification (execution vs hygiene)

The terminal `result` event supplies the completion contract. Verified fields:
`subtype`, `is_error`, `stop_reason`, `terminal_reason`, `api_error_status`, `num_turns`,
`total_cost_usd`.

An attempt is **execution-OK** only when all hold: process exit 0; exactly one terminal `result`
event present; `is_error == false`; `subtype == "success"`; no `api_error_status`; and every JSONL
line parses. Anything else — crash, timeout, truncated stream, provider error, missing terminal
event — is an **execution failure**.

This distinction is load-bearing:

| Outcome | Edits | Rendering |
|---|---|---|
| Execution OK, summary valid | committed | normal |
| Execution OK, summary invalid ×2 | **kept** (guardrail validated them) | inconclusive — *summary unusable* |
| Execution failure ×2 | **discarded** (tree reset) | inconclusive — *audit did not complete* |

Never commit edits from an aborted, errored, or truncated run: the guardrail proves paths and churn
are legal, not that the edit set is coherent. A run killed mid-edit-loop leaves a half-updated but
fully allowlist-compliant document.

### `extract-summary.sh`

1. Parse defensively: `jq -R 'fromjson? // empty'` — a truncated tail line must not abort the parse.
2. Keep `.type == "assistant"` events; from each, `content[] | select(.type == "text")`, joined with
   a blank line. `thinking` and `tool_use` blocks are discarded by type.
3. Prefer **the last assistant message containing a complete
   `<docs-sentinel-summary>…</docs-sentinel-summary>` fence**; fall back to the last assistant
   message only if no fence appears anywhere.

Step 3's ordering matters. Models routinely close with a bare "Done." after a final check; selecting
the last message outright would extract "Done.", fail shape validation, and burn the retry on an
otherwise healthy run.

Require exactly one balanced fence pair in the selected message. Reject nested, duplicated, or
unbalanced fences rather than guessing.

### `validate-summary.sh`

Inputs: the extracted summary and `EDITED_COUNT` (from `git diff HEAD --name-only | wc -l`, computed
by `run-auditor.sh` — it does **not** depend on the guardrail having run).

Normalize line endings (strip CR) first. Full NFKC folding is not available in portable shell, so
the banned-token list instead enumerates both the fullwidth (U+FF5C) and ASCII-normalized (`<|`)
spellings of the DSML delimiter explicitly. Then reject when any hold:

- empty or whitespace-only;
- contains, case-insensitively, any of: U+FF5C, `<|`, `DSML`, `<invoke`, `<function_calls`,
  `<tool_calls`, `<tool_use`;
- exceeds the line cap (60) or byte cap (8 KiB);
- **state machine violation:**
  - `EDITED_COUNT == 0` → the only legal form is a line beginning `No documentation updates needed`;
  - `EDITED_COUNT > 0` → must begin `Subject: `, must contain at least one markdown bullet, and must
    **not** contain the no-update phrase.

The state machine is what actually prevents the P1 rendering class: today a summary can disagree with
the tree in either direction and still pass.

After the guardrail runs, revalidate the summary against the guardrail's canonical changed-file list.

**Named trade-off:** a repository whose documentation legitimately discusses LLM tool-calling can
trip the banned-token rules and degrade to inconclusive. This is accepted — the scan applies to the
model's own extracted summary prose, not to document content, so the exposure is small, and failing
toward "inconclusive" is the safe direction. (This very spec would trip it, which is the point.)

### Retry reset

`run-auditor.sh` records `BASE_SHA=$(git rev-parse HEAD)` before the first attempt. Between attempts:

```bash
git reset --hard "$BASE_SHA"
git clean -fd            # removes .docs-sentinel-context.md and any attempt-created files
bash "$ENGINE_DIR/build-context.sh"   # regenerate from trusted inputs
```

`git checkout -- .` is insufficient: `.docs-sentinel-context.md` is untracked, so attempt 1 could
edit it and attempt 2 would read self-authored input. The workflow currently builds it once
(`audit.yml:302`), so regeneration must be explicit.

**Behavior change to record:** a guardrail-violating edit in attempt 1 accompanied by an invalid
summary is now reverted by the reset and never surfaces as a guardrail failure. The guardrail's
fail-loud contract becomes fail-loud-on-the-final-attempt. `run-auditor.sh` emits telemetry for
discarded attempts so this is observable.

## Rendering — one owner, always runs

**This is the fix for P1's real damage, and the original design missed it.**

`audit.yml:391-394` substitutes *"No documentation updates needed"* under the heading *"no
documentation drift detected"* whenever the summary file is empty and there are no edits — which is
exactly the degraded state. Routing degraded output through `compose-message.sh` cannot fix it,
because that step only runs at `changed == 'true'` (`audit.yml:354, 362, 612, 620, 629`).

Therefore:

- `run-auditor.sh` emits `degraded` (`""` | `hygiene` | `execution`) and `degraded_reason` as step
  outputs.
- A **single** status-comment step owns all rendering and runs with `if: always()`, distinguishing:
  `fixed` · `clean` · `skipped` · `inconclusive (summary unusable)` ·
  `inconclusive (audit did not complete)` · `failed (infrastructure)`.
- The "no drift" heading is emitted **only** when the run was execution-OK, the summary validated,
  and `EDITED_COUNT == 0`.
- The infrastructure branch covers engine-fetch, npm-install, policy-validation, and
  build-context failures, which today produce a red job and no comment at all — contrary to the
  "never silence" contract in `README.md:23`.

**Default-branch path.** `audit-main` posts no comment; its only artifact is the sync PR, which is
skipped when `changed != true`. A degraded push run would surface nowhere. `run-auditor.sh` writes
the status to `$GITHUB_STEP_SUMMARY` on both paths so a degraded default-branch run is visible.

## Timeouts

`timeout-minutes: 15` (`audit.yml:194`, `:461`) was sized for one attempt. v1.1 adds a second
attempt. Raise the job timeout and give the auditor step its own tighter per-attempt timeout, so a
hung attempt fails into the degraded path rather than killing the job — a job-level timeout kill
bypasses every rendering guarantee above.

## Tests

Captured production failures become fixtures.

| Suite | Covers |
|---|---|
| `tests/extract-summary.bats` | text-only extraction; `thinking`/`tool_use` discarded; fence preferred over trailing "Done."; truncated tail line survives parse; unbalanced fence rejected |
| `tests/validate-summary.bats` | PR #8/#11 DSML body rejected; ASCII `<\|DSML\|` variant rejected; PR #12 reasoning flood rejected; state machine both directions; valid forms accepted |
| `tests/run-auditor.bats` | retry on hygiene failure; **tree + context file reset between attempts**; edits discarded on execution failure, kept on hygiene failure; secret absent from `argv`; stub `claude` on `PATH` |
| `tests/guardrail.bats` | untracked file causes revert and failure |
| `tests/status-comment` | **degraded never renders "no documentation drift detected"** — asserted where the string is actually emitted |

## Blast radius

Consumers keep their existing inputs; no input is removed in v1.1. Behavior changes: the auditor
loses `Bash`; degraded runs render as inconclusive rather than clean; execution failures no longer
commit edits. All three are strict improvements to correctness. `[skip docs-sentinel]` and the
allowlist/budget guardrail are unchanged apart from the additional untracked-file check.
