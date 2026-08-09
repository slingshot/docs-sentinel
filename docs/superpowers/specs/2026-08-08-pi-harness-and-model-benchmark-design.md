# Pi harness migration, auditor output hygiene, and a model benchmark

**Date:** 2026-08-08
**Status:** Approved (design), pending implementation plan

## Problem

Since defaulting both model tiers to DeepSeek V4 Flash via OpenRouter (`3cec283`, `c29e296`), the
auditor's final summary — which becomes a **public PR comment** and a **git commit body** — has been
contaminated in two distinct ways. Both are observed in production on `heysanil/invisible-string`:

**1. Tool-call framing leak (verdict destroyed).** PRs
[#8](https://github.com/heysanil/invisible-string/pull/8) and
[#11](https://github.com/heysanil/invisible-string/pull/11) posted a comment whose entire body was:

```
</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>
```

`｜` is U+FF5C (fullwidth vertical line) — DeepSeek's native DSML tool-call special tokens. Orphaned
closing tags landed in the assistant's *text* content and the real verdict never made it out. The
comment still rendered under the heading **"no documentation drift detected"**, so a destroyed audit
is indistinguishable from a clean pass. This is a silent quality regression, and it is the more
dangerous of the two bugs.

**2. Reasoning leak (verdict buried).** PRs
[#9](https://github.com/heysanil/invisible-string/pull/9),
[#10](https://github.com/heysanil/invisible-string/pull/10) and
[#12](https://github.com/heysanil/invisible-string/pull/12) posted the model's full chain of thought
— "Let me do one more sanity check", "Should I edit `docs/screenshots/README.md`? Two issues:", an
explicit self-debate about whether to edit — with the actual conclusion buried at the very end.

### Root cause

Two layers, one architectural and one infrastructural.

**Architectural.** `.github/workflows/audit.yml:340` (and its duplicate at `:598`) does:

```bash
jq -r '.result // ""' "$RUNNER_TEMP/auditor.json" > "$RUNNER_TEMP/auditor-summary.md"
```

This treats free-form LLM prose as a **trusted structured field** and pipes it directly into a git
commit body and a public PR comment. `claude -p --output-format json` returns `.result` as a single
**pre-flattened string**: once anything upstream mis-parses, reasoning, tool framing, and prose all
land in the same bucket with no way to tell them apart.

The repo already knows `.result` is hostile input — `engine/compose-message.sh:126` generates a
random heredoc delimiter precisely because summary text could otherwise terminate a `GITHUB_OUTPUT`
block early (output injection). That suspicion is simply applied inconsistently: the subject line is
validated (length, single-line, static fallback) and the body is not validated at all.

The contrast with `engine/guardrail.sh` is instructive. The guardrail never asks the model to
behave; it mechanically verifies and reverts. The summary path asks the model to behave and hopes.

**Infrastructural.** The current request path is:

```
claude CLI → Anthropic Messages API → OpenRouter Anthropic-compat shim → DeepSeek native
```

The DSML tokens are almost certainly born in that translation hop, not in DeepSeek itself. A
corollary that matters for the second half of this spec: **the current setup cannot fairly benchmark
models.** Every non-Anthropic model is measured through a shim that Anthropic models bypass, so any
comparison scores translation fidelity and calls it model quality.

## Goals

- The auditor's summary can no longer contain reasoning or tool-call framing, enforced
  **structurally** rather than by prompt convention.
- Unusable auditor output is **detected mechanically**, retried once, and — if still unusable —
  reported honestly instead of masquerading as "no drift detected".
- Model and provider become a **flag**, not a shim configuration, so models can be swapped and
  compared without changing the request topology.
- A reproducible benchmark that ranks candidate models on real documentation-drift cases.
- No regression to the two load-bearing safety mechanisms: the `[skip docs-sentinel]` loop-breaker
  and the doc-edit guardrail.

## Non-goals

- **No LLM judge in the benchmark.** Scoring stays mechanical (file-set precision/recall plus
  hygiene metrics). An LLM judge adds cost, nondeterminism, and a second model that itself needs
  validating. Revisit only if file-set scoring proves too coarse to separate candidates.
- **No absolute correctness claim from the benchmark.** See "Ground-truth noise" under Limitations.
- **No sandbox.** Pi ships none by design, and the existing gate already blocks fork PRs.
- **No v1 breakage.** Callers pinned to `@v1` keep the Claude Code path unchanged.

## Decisions taken

| Question | Decision |
|---|---|
| Scope | Both halves, output hygiene first |
| Unusable output | Retry once, then degrade (job stays green, `::warning::`) |
| Production harness | Switch to Pi |
| Benchmark fixtures | Replay real merged PRs |
| `git diff` access | Drop `bash` entirely |
| Scoring | File-set precision/recall + hygiene metrics |

## Why Pi

[`@earendil-works/pi-coding-agent`](https://github.com/earendil-works/pi) (MIT, ~85k stars, actively
maintained) is a provider-native agent harness supporting 30+ providers with **no compatibility
shim**.

The decisive property is its message type, `packages/ai/src/types.ts:417`:

```typescript
export interface AssistantMessage {
    content: (TextContent | ThinkingContent | ToolCall)[];
}
```

Assistant content is a **typed discriminated union**. Reasoning is `{type: "thinking"}`, tool calls
are `{type: "toolCall"}` (parsed objects, not raw text), prose is `{type: "text"}`. Summary
extraction becomes `select(.type == "text")` — leakage stops being a convention the model must
honor and becomes a shape it cannot violate.

Talking to DeepSeek (or OpenRouter's own native API) directly also removes the Anthropic-compat hop
where the DSML tokens are most likely born.

**Honest limit:** if a provider emits DSML tokens *labelled as text*, Pi will faithfully place them
in a `TextContent` block. Pi's structural typing fixes bug #2 outright; it only *probably* fixes bug
#1. This is why the validator remains mandatory, and why leak rate must be measured **per
(provider, model) pair** rather than per model.

### Pi constraints that shape the design

- **No permission system.** Pi "intentionally does not include ... permission popups"; tools simply
  run. `--permission-mode acceptEdits` has no analogue and needs none.
- **`--tools` is tool-level, not argument-level.** There is no way to express Claude Code's
  `Bash(git diff:*)`. Granting unrestricted `bash` in a job holding `MODEL_API_KEY` and
  `contents: write` would be a genuine security regression, so `bash` is dropped entirely. The full
  unified diff is already in `.docs-sentinel-context.md`, making it near-redundant; the one line in
  `prompt-skeleton.md` offering `git diff` is removed.
- **`write` must stay excluded, and this is load-bearing.** `guardrail.sh:37` inspects only
  `git diff HEAD --name-only` — tracked files. Its own comment (line 32) states the safety rests on
  "Write is disallowed, so there are no untracked files to consider". Granting `write` would let new
  files bypass the guardrail entirely.
- **Non-interactive project trust.** `-p` / `--mode json` never prompt; `defaultProjectTrust` of
  `ask`/`never` ignores project-local `.pi/` resources. We pass `--no-approve` explicitly so an
  audited repo cannot alter auditor behavior via a committed `.pi/settings.json`.

## Ownership model

Unchanged in spirit from the existing design: **the shell keeps every safety-critical guarantee; the
model only produces prose.** This work extends that principle to the summary, which is currently the
one place it is not applied.

| Guarantee | Owner |
|---|---|
| Which files may be edited, and churn budget | `guardrail.sh` (shell) |
| No untracked files created | `guardrail.sh` (shell) — **new** |
| Reasoning / tool framing excluded from summary | Pi type system (structural) + `extract-summary.sh` |
| Summary is usable at all | `validate-summary.sh` (shell) — **new** |
| `[skip docs-sentinel]` loop-breaker | `compose-message.sh` (shell) |
| Commit subject shape | `compose-message.sh` (shell) |
| Summary prose | Model |

## Architecture

Current:

```
gate → build-context.sh → claude -p --output-format json
                        → jq -r '.result'                  ← trusted blindly
                        → guardrail.sh → compose-message.sh → commit / PR / comment
```

Proposed:

```
gate → build-context.sh ─┐
                         ↓
        ┌──────── run-auditor.sh ────────────────────────┐
        │  pi --mode json  →  extract-summary.sh         │
        │                  →  validate-summary.sh        │
        │        ↑── retry once ──┘        │ fail ×2     │
        └─────────────────────────────────┼─────────────┘
                                          ↓
                              summary.md | DEGRADED flag
                                          ↓
              guardrail.sh → compose-message.sh → commit / PR / comment
```

## Engine components

| File | Status | Responsibility |
|---|---|---|
| `engine/run-auditor.sh` | **new** | Owns the auditor call end to end: invoke `pi`, extract, validate, retry once, emit degraded flag |
| `engine/extract-summary.sh` | **new** | `jq` pipeline: last `message_end` → `content[] | select(.type=="text")` → delimiter fence |
| `engine/validate-summary.sh` | **new** | Mechanical shape check; exit 0 usable / 1 unusable. Pure function of a file |
| `engine/prompt-skeleton.md` | modified | Remove the `git diff` offer; add the delimiter contract |
| `engine/guardrail.sh` | modified | Additionally fail on untracked files |
| `engine/compose-message.sh` | modified | Degraded-mode branch |
| `.github/workflows/audit.yml` | modified | Pi install and flags; inline auditor block collapses into `run-auditor.sh` |

### `extract-summary.sh`

Input: the JSONL event stream. Output: candidate summary text.

1. Select the final `message_end` event carrying an assistant message.
2. Keep `content[]` entries where `.type == "text"`; concatenate in order.
3. If a `<docs-sentinel-summary>…</docs-sentinel-summary>` fence is present, emit only its contents;
   otherwise emit the concatenation unchanged and let the validator judge it.

Step 3 is deliberately lenient: the fence is a second line of defense, not a hard requirement, so a
model that omits it can still pass on shape alone.

### `validate-summary.sh`

Fails (exit 1) when any of the following hold:

- The summary is empty or whitespace-only.
- It contains U+FF5C, `<invoke`, `<function_calls`, `<tool_calls`, or `<tool_use`.
- The first non-blank line matches neither `^Subject: ` nor `^No documentation updates needed`.
- It exceeds a line cap (default 60) — a proxy for a reasoning flood.
- The working tree has edits but the summary contains no markdown bullet.

The last rule needs an edited-file count, **not** the guardrail's verdict. The validator reads
`EDITED_COUNT`, which `run-auditor.sh` computes with a plain `git diff HEAD --name-only | wc -l`
before validating. This keeps `validate-summary.sh` a pure function of its inputs and preserves the
pipeline order in the architecture diagram — validation stays inside `run-auditor.sh`, ahead of
`guardrail.sh`.

### Retry and degrade

`run-auditor.sh` invokes Pi, extracts, and validates. On failure it retries the identical prompt
once. On a second failure it writes no summary and sets `degraded=true`.

**The tree must be reset between attempts.** A first attempt that edited docs before producing an
unusable summary leaves those edits in the working tree; a naive retry would run the auditor against
a repo already containing its own prior output, producing compounded or self-referential edits. Before
retrying, `run-auditor.sh` runs `git checkout -- .` to restore tracked files to `HEAD`
(`.docs-sentinel-context.md` is regenerated by `build-context.sh` and is removed by the guardrail, so
it is unaffected). The retry therefore starts from exactly the same state as the first attempt.

Degraded behavior:

- Doc edits, if any, **still land** — the guardrail validated them independently of the prose.
- The commit body falls back to the static subject plus the `Files updated:` list, with a line
  noting the summary was unavailable.
- The PR comment states plainly that the auditor ran but its summary was unusable and the audit is
  **inconclusive**, with a link to the run. It must never render as "no documentation drift
  detected" — that exact false-negative is bug #1's real damage.
- A `::warning::` annotation is emitted; the job stays green.

## Workflow input surface — this is a v2

Pi's provider-native design removes a whole category of inputs.

| v1 input | v2 |
|---|---|
| `claude-code-version` | → `pi-version` |
| `anthropic-base-url` | **removed** — `--provider` handles routing |
| `use-bearer-auth` | **removed** — no compat shim, no auth-header ambiguity; superseded by `api-key-env` (see Credential mapping) |
| `model-capabilities` | **removed** — no model-ID pattern-matching to defeat |
| `model` + `small-model` | → `provider` + `model` (Pi has no tier system) |
| `effort` | → `thinking` (`off\|minimal\|low\|medium\|high\|xhigh`) |

Install and invocation:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
PI_OFFLINE=1 pi -p "$(cat prompt.md)" --mode json \
  --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" \
  --tools read,edit,grep,find,ls --no-approve
```

`--ignore-scripts` is safe and recommended by Pi's own quickstart (unlike `@anthropic-ai/claude-code`,
Pi needs no postinstall). `PI_OFFLINE=1` suppresses update checks and telemetry for CI determinism.

### Credential mapping

v1 routed the single `MODEL_API_KEY` secret into either `ANTHROPIC_AUTH_TOKEN` or
`ANTHROPIC_API_KEY` via the `use-bearer-auth` boolean. Pi instead reads a **per-provider** environment
variable (`DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, …).

`run-auditor.sh` therefore exports `MODEL_API_KEY` under the variable name the selected provider
expects, derived as `<PROVIDER>_API_KEY` uppercased, with a new optional `api-key-env` input to
override the derivation for providers that do not follow that pattern (for example cloud providers
using SDK-native credentials).

Pi's `--api-key` flag is deliberately **not** used: it would place the secret in `argv`, visible in
the process list to anything else on the runner. The secret stays in the environment.

Existing callers pinned to `@v1` continue to run the Claude Code path unchanged. The migration is
published as `@v2`.

## Benchmark harness

```
bench/
  models.json          # matrix of (provider, model, thinking) candidates
  harvest.sh           # PR list → frozen fixtures
  fixtures/<case-id>/  # repo bundle @ base SHA, code.diff, policy.md, expected.json
  run.sh               # fixture × config → invokes the REAL run-auditor.sh + guardrail.sh
  score.sh             # precision/recall/F1 + hygiene metrics → JSON and markdown
```

### Ground truth by doc-diff holdout

For each merged PR that changed **both** code and documentation:

1. Split the PR diff into a code half and a docs half using the allowlist regex.
2. Materialize the repo at the base SHA and apply **only the code half**.
3. Run the auditor.
4. Ground truth = the set of doc files the human actually edited in that same PR.

This yields realistic labelled data automatically, with no hand-annotation, from PRs that already
exist. `invisible-string` alone supplies a dozen or more.

### Metrics

| Metric | Needs ground truth |
|---|---|
| File-set precision / recall / F1 | yes |
| Leak rate (validator rejections per run) | no |
| Format compliance (fence present, shape valid) | no |
| Retry rate, degrade rate | no |
| Cost per run, wall-clock latency | no |

The hygiene metrics need no answer key at all, so they are trustworthy in absolute terms and
directly answer the question that prompted this work.

`run.sh` invokes the production `run-auditor.sh` and `guardrail.sh` rather than reimplementing the
pipeline — otherwise the benchmark measures the benchmark. Fixtures are frozen bundles committed to
the repo, so runs are deterministic, offline, rate-limit-free, and reproducible indefinitely.

## Tests

`bats`, matching the three existing suites. The captured production failures become the fixtures:

| Suite | Covers |
|---|---|
| `tests/extract-summary.bats` | text-only extraction; thinking and toolCall blocks discarded; fence honored; fence absent; multiple text blocks concatenated |
| `tests/validate-summary.bats` | PR #8/#11 DSML-only body rejected; PR #12 reasoning flood rejected; valid `Subject:` accepted; valid no-edit line accepted; empty rejected |
| `tests/run-auditor.bats` | retry fires once on invalid output; degrade after two failures; success on first attempt skips retry; **tree is reset between attempts**; secret never appears in `argv` — with a stub `pi` on `PATH` |
| `tests/guardrail.bats` | extended: untracked file causes revert and failure |
| `tests/compose-message.bats` | extended: degraded mode never emits "no drift detected" |

## Limitations

1. **Ground-truth noise.** The doc-diff holdout mislabels in both directions: humans miss docs (the
   auditor is penalized for correctly catching them) and make unrelated doc edits in the same PR
   (penalized for correctly ignoring them). The metric is valid for **ranking models against
   identical fixtures**, not as an absolute correctness score. Harvested fixtures should be
   spot-checked by hand before being committed.
2. **Pi's JSON event shape is verified from source, not from a live run.** The type union is
   unambiguous, but the first task of the implementation plan must be a real `pi --mode json`
   invocation confirming the event sequence and content-block shapes before anything is wired.
3. **DSML tokens may survive the harness swap** if OpenRouter labels them as text. The validator,
   not Pi, is what covers this case.
4. **Harness migration is a large change** to a workflow other repositories pin. Mitigated by
   shipping as `v2` and leaving `v1` intact.

## Blast radius

- `v1` consumers: none. The Claude Code path is untouched.
- `v2` consumers: must set `provider`/`model` instead of the four removed inputs. Documented in the
  migration section of `README.md`.
- The `[skip docs-sentinel]` loop-breaker and the doc allowlist/budget guardrail are unchanged in
  behavior; the guardrail only gains a strictly-additional untracked-file check.
