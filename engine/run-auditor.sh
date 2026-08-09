#!/usr/bin/env bash
# Own the auditor call end to end: invoke, classify, extract, validate, reset, retry once.
#
# Two failure classes, deliberately kept apart:
#   hygiene   — the run COMPLETED but its prose is unusable. Edits are kept: the guardrail validated
#               them and the run is coherent.
#   execution — the run did NOT complete (crash, truncated stream, provider error). Edits are
#               DISCARDED: the guardrail proves paths and churn are legal, not that a half-finished
#               edit set makes sense.
#
# Env contract:
#   ENGINE_DIR    (required)  directory holding the sibling engine scripts
#   PROMPT_PATH   (required)  assembled prompt file
#   RANGE         (required)  diff range, forwarded to build-context.sh on retry
#   GITHUB_OUTPUT (required)  step-output file
#   CLAUDE_BIN    (optional)  default `claude` — overridden in tests
#   ALLOWED_TOOLS (optional)  default `Read,Edit,Grep,Glob`. No Bash: `git diff --output=<path>`
#                             is a file-write primitive that would defeat the guardrail.
#   MAX_ATTEMPTS  (optional)  default 2
#   DIFF_EXCLUDE, RUNNER_TEMP, GITHUB_STEP_SUMMARY (optional)
#
# Emits step outputs: degraded (''|hygiene|execution), degraded_reason, summary_path.
set -euo pipefail

: "${ENGINE_DIR:?ENGINE_DIR not set}"
: "${PROMPT_PATH:?PROMPT_PATH not set}"
: "${RANGE:?RANGE not set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Read,Edit,Grep,Glob}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
TMP="${RUNNER_TEMP:-/tmp}"
SUMMARY_OUT="$TMP/auditor-summary.md"

BASE_SHA=$(git rev-parse HEAD)

reset_tree() {
  git reset -q --hard "$BASE_SHA"
  # -fd (not -x): drop attempt-created files including the untracked context file, but leave
  # gitignored build inputs alone.
  git clean -qfd
}

degraded=""
degraded_reason=""
attempt=1

while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  STREAM="$TMP/auditor-stream-$attempt.jsonl"
  ERRLOG="$TMP/auditor-stderr-$attempt.log"
  class=""
  reason=""

  echo "--- Auditor attempt $attempt/$MAX_ATTEMPTS ---"
  set +e
  "$CLAUDE_BIN" -p "$(cat "$PROMPT_PATH")" \
    --allowed-tools "$ALLOWED_TOOLS" \
    --permission-mode acceptEdits \
    --output-format stream-json \
    --verbose > "$STREAM" 2> "$ERRLOG"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    class="execution"; reason="claude exited with status $rc"
  elif ! detail=$(STREAM_PATH="$STREAM" bash "$ENGINE_DIR/classify-run.sh"); then
    class="execution"; reason="$detail"
  elif ! summary=$(STREAM_PATH="$STREAM" bash "$ENGINE_DIR/extract-summary.sh" 2>&1); then
    class="hygiene"; reason="$summary"
  else
    printf '%s\n' "$summary" > "$SUMMARY_OUT"
    edited=$(git diff HEAD --name-only | grep -c '' || true)
    if ! detail=$(SUMMARY_PATH="$SUMMARY_OUT" EDITED_COUNT="$edited" \
                  RUNNER_TEMP="$TMP" bash "$ENGINE_DIR/validate-summary.sh"); then
      class="hygiene"; reason="$detail"
    fi
  fi

  if [ -z "$class" ]; then
    degraded=""; degraded_reason=""
    echo "Attempt $attempt succeeded."
    break
  fi

  echo "::warning::Auditor attempt $attempt failed ($class): $reason"
  degraded="$class"
  degraded_reason="$reason"

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    # Restore the EXACT starting state. `git checkout -- .` is not enough: the context file is
    # untracked, so attempt 2 would otherwise read input attempt 1 may have written.
    reset_tree
    RANGE="$RANGE" DIFF_EXCLUDE="${DIFF_EXCLUDE:-}" bash "$ENGINE_DIR/build-context.sh"
  fi

  attempt=$((attempt + 1))
done

# An incomplete run must never leave edits behind to be committed.
if [ "$degraded" = "execution" ]; then
  echo "Discarding all edits from the failed run."
  reset_tree
fi

if [ -n "$degraded" ]; then
  : > "$SUMMARY_OUT"
fi

# GITHUB_OUTPUT is line-oriented; a multi-line reason would corrupt it.
degraded_reason=$(printf '%s' "$degraded_reason" | tr '\n\r' '  ' | cut -c1-300)

{
  echo "degraded=$degraded"
  echo "degraded_reason=$degraded_reason"
  echo "summary_path=$SUMMARY_OUT"
} >> "$GITHUB_OUTPUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### docs-sentinel"
    if [ -z "$degraded" ]; then
      echo "Audit completed."
    else
      echo "**Audit inconclusive** (\`$degraded\`): $degraded_reason"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
