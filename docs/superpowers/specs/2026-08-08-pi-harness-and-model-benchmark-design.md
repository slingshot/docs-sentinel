# Pi harness migration and model benchmark (v2)

**Date:** 2026-08-08
**Status:** Approved (design), pending implementation plan
**Depends on:** [Auditor output hygiene v1.1](2026-08-08-auditor-output-hygiene-v1.1-design.md),
which must ship first.

## What changed after review

This spec originally bundled the DeepSeek output-leak incident fix into a harness migration. Review
established that the incident fix does not require one — `claude -p --output-format stream-json`
already emits typed content blocks on the harness we run today (verified against Claude Code
2.1.226). The urgent work was therefore split into **v1.1**, which ships on the current harness.

What remains here is the work Pi is *actually* justified by. Two things:

1. **Benchmark fairness.** Today every non-Anthropic model is reached through OpenRouter's
   Anthropic-compat shim while Anthropic models bypass it. Any comparison run on that topology
   scores translation fidelity and calls it model quality. Pi speaks 30+ providers natively.
2. **Deleting the capabilities apparatus.** `audit.yml:254-300` (duplicated at `:516-562`) sets five
   model-tier env vars plus a `model-capabilities` string that exists solely to defeat Claude Code's
   model-ID pattern-matching. Pi has no tier system and no such gate.

**Explicitly not a justification:** Pi's typed content union. That property is real
(`packages/ai/src/types.ts:415-417`) but v1.1 obtains the same guarantee from `stream-json`, and Pi
cannot fix shim-born tokens that arrive already labelled as text — the same honest limit applies to
both harnesses.

## Goals

- Model and provider become a flag, not a shim configuration.
- Remove the five-env-var tier mapping and `model-capabilities`.
- A benchmark that ranks candidate models on real drift cases without a shim confound.

## Non-goals

- Output hygiene, validator, retry/degrade, rendering — all owned by v1.1.
- LLM-judge scoring.
- Absolute correctness claims from the benchmark (see Limitations).

## Pi constraints that shape the design

All verified against the installed `@earendil-works/pi-coding-agent` 0.84.1 build.

- **No permission system.** Pi "intentionally does not include ... permission popups"; tools run
  directly. `--permission-mode acceptEdits` has no analogue and needs none.
- **`--tools` is tool-level, not argument-level.** There is no way to express `Bash(git diff:*)`.
  This is fine, because v1.1 already removes that grant — and removing it was itself a security fix,
  since `git diff --output=<path>` writes files (verified: 19551 bytes) and defeated the guardrail.
- **`grep`, `find`, `ls` are off by default** (`pi --help:174-177`). `--tools read,edit,grep,find,ls`
  is therefore what *enables* search, not merely what restricts it. A denylist formulation
  (`--exclude-tools bash,write`) would silently leave the auditor unable to search.
- **Pi's `edit` cannot create files** — it is read-then-write (`core/tools/edit.ts:339→351`). With
  `write` excluded, the untracked-file guardrail is defense-in-depth here rather than load-bearing.
  (It *is* load-bearing on v1, which is why v1.1 adds it.)
- **`--no-approve` does not cover context files.** Pi loads `AGENTS.md`, `AGENTS.override.md`, and
  `CLAUDE.md` regardless of project trust. Those files are in docs-sentinel's own edit allowlist, so
  without mitigation the auditor treats the artifacts it audits as instructions, and a PR editing
  `CLAUDE.md` could steer the auditor judging that same PR. **`--no-context-files` is mandatory and
  not caller-configurable.**
- **Built-in tools are not path-confined.** No sandbox; `read`/`edit` run with process permissions.
  Not a regression — Claude Code's `Read`/`Edit` under `acceptEdits` have identical reach — but v1.1's
  credential fixes (secret out of `$GITHUB_ENV`, `persist-credentials: false`) are what actually
  reduce the blast radius, and they carry forward.
- **No turn or step cap.** No `--max-turns` equivalent; the ceiling is the step timeout.
- **`--thinking` accepts `max`** (`pi --help:40`), which the published docs omit. Validation must not
  reject it. v1's `effort: auto` has no analogue — map `auto` to omitting the flag.
- **`--model` accepts `provider/id` and an optional `:<thinking>` suffix** (`pi --help:18`), so one
  string can encode the whole configuration — convenient for the benchmark matrix.
- **Default provider is `google`** (`pi --help:17`). Provider and model must always be explicit.

### Mandatory invocation

```bash
npm install -g --ignore-scripts --prefix "$RUNNER_TEMP/pi-cli" \
  "@earendil-works/pi-coding-agent@$PI_VERSION"

PI_OFFLINE=1 pi -p "$(cat prompt.md)" --mode json \
  --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" \
  --tools read,edit,grep,find,ls \
  --no-context-files --no-approve --no-extensions --no-skills \
  --no-prompt-templates --no-themes --no-session
```

The isolated `--prefix` and the version pin mirror v1's install discipline (`audit.yml:316`). The
hardening flags are fixed, not caller-configurable.

### Run completion contract

Pi's JSON mode does **not** map failure to exit status. `print-mode.js:167` sets `exitCode = 1` only
for `stopReason === "error" || "aborted"` — a `length`-truncated generation exits **0**. `StopReason`
is `"stop" | "length" | "toolUse"` plus `"aborted"` and `"error"`.

So the v1.1 classifier must be reimplemented, not reused verbatim: an attempt is execution-OK only
when the stream parses completely, terminates with `agent_end`, and the final assistant message has
`stopReason == "stop"`. This is strictly *less* informative than the Claude Code path, whose terminal
`result` event carries `subtype`, `is_error`, `stop_reason`, `terminal_reason`, `api_error_status`,
`num_turns`, and `total_cost_usd`. Losing `total_cost_usd` means Pi runs need cost derived from
`usage` and a price table.

## Workflow input surface

| v1 input | v2 |
|---|---|
| `claude-code-version` | → `pi-version` |
| `anthropic-base-url` | **removed** |
| `use-bearer-auth` | **removed** |
| `model-capabilities` | **removed** |
| `model` + `small-model` | → `provider` + `model` |
| `effort` | → `thinking` (`off\|minimal\|low\|medium\|high\|xhigh\|max`; `auto` → omit) |
| — | **new** `api-key-env` (escape hatch, see below) |

Callers pinned to `@v1` are unaffected.

### Credential mapping

v1 routed one `MODEL_API_KEY` into `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`. Pi reads a
per-provider variable, and **the name is not derivable**. From upstream
`packages/ai/src/env-api-keys.ts`:

| provider | variable |
|---|---|
| `deepseek` | `DEEPSEEK_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |
| `google` | **`GEMINI_API_KEY`** |
| `google-vertex` | **`GOOGLE_CLOUD_API_KEY`** |
| `huggingface` | **`HF_TOKEN`** |
| `moonshotai` | **`MOONSHOT_API_KEY`** |

A `<PROVIDER>_API_KEY` derivation is wrong for hyphenated providers (invalid shell identifiers) *and*
for several unhyphenated ones. Ship an explicit allowlisted map mirroring upstream; **fail fast** on
an unlisted provider, naming `api-key-env` as the override. Validate any override against
`^[A-Za-z_][A-Za-z0-9_]*$` before indirect export. Cloud providers needing multiple credentials are
out of scope and documented as such.

`--api-key` is deliberately unused: it would place the secret in `argv`.

## Benchmark

```
bench/
  models.json          # candidates: pinned dated slugs, never floating aliases
  harvest.sh           # PR list → frozen fixtures
  fixtures/<case-id>/  # repo bundle @ base SHA, code.diff, policy.md, allowlist.txt, expected.json
  run.sh               # fixture × config → invokes the production auditor path
  score.sh             # metrics → JSON + markdown
```

### Ground truth by doc-diff holdout

For each merged PR touching both code and docs: split by the allowlist regex, apply only the code
half to the base tree, run the auditor, and compare against the doc files the human edited.

Three corrections review established as mandatory:

1. **Exclude human-*created* doc files from `expected.json`.** The auditor is forbidden to create
   files (`prompt-skeleton.md:30-32`, enforced by the untracked-file guardrail). Leaving created
   paths in the answer key caps recall below 1.0 identically for every model — systematic bias that
   compresses precisely the differences being measured. Either drop those paths, or count a
   `NEEDS HUMAN` mention as the hit.
2. **Capture the allowlist regex per fixture.** It is a caller-workflow *input*, not part of
   `policy.md`, so it is not recoverable from the fixture repo. `harvest.sh` must record it.
3. **Pin dated model slugs.** The current default is a floating `~…-latest` alias
   (`audit.yml:74`), which silently changes what is being measured between runs.

### Metrics

| Metric | Needs ground truth |
|---|---|
| File-set precision / recall / F1 | yes |
| Leak rate (validator rejections) | no |
| Format compliance, retry rate, degrade rate | no |
| Cost per run, wall-clock latency | no |

Hygiene metrics need no answer key and directly answer the incident question. **Ship the
hygiene-only benchmark first**; add file-set scoring once fixtures are hand-curated.

`run.sh` invokes the production auditor path rather than reimplementing it. Record per run: harness
and version, provider, model ID *and* the model the provider reports serving, request parameters,
raw event stream, timestamps, and repeated trials — sampling is not deterministic.

## Limitations

1. **Ground-truth noise.** The holdout mislabels in both directions: humans miss docs (the auditor is
   penalized for catching them) and make unrelated doc edits (penalized for ignoring them). Valid for
   ranking models against identical fixtures; not an absolute correctness score. Fixtures must be
   hand-curated before being committed.
2. **Fixtures are reproducible; runs are not.** Frozen bundles remove GitHub variability, but every
   run calls a live sampling API whose routing, pricing, and availability drift. The earlier claim
   that runs are "offline, rate-limit-free, and reproducible indefinitely" was false and is withdrawn.
   Add a replay-only scorer over recorded streams for the genuinely offline part.
3. **Small n.** ~12 fixtures from one repository puts F1 deltas inside noise. Report per-fixture
   win/loss; do not let a 0.03 aggregate gap select a model.
4. **Pi is pinned by version, not reviewed forever.** Cite immutable commit URLs and test the exact
   published npm artifact; `main` moves.
5. **`prompt-skeleton.md` names Claude Code tools** — "Read/Grep/Glob" (`:16`), "glob for the files"
   (`:39`). Pi's are `read`/`grep`/`find`/`ls`. The prompt needs a harness-appropriate tool
   vocabulary, or a model told to "Glob" will waste turns.

## Blast radius

- `@v1` consumers: unaffected.
- `@v2` consumers: set `provider`/`model` in place of four removed inputs.
- The `[skip docs-sentinel]` loop-breaker and the allowlist/budget guardrail are unchanged.
