#!/usr/bin/env bash
# Decide OUTCOME/KIND/EDITS_LANDED/REASON for the sticky status comment. Extracted from an inline
# if/elif ladder in audit.yml so the one load-bearing rung has test coverage: guardrail.sh exits 1
# on a violation WITHOUT ever writing `changed=`, so on that path CHANGED is empty — without the
# GUARD_RESULT rung ahead of the CHANGED checks, the ladder falls through to `clean` and posts a
# clean pass for the exact attack the guardrail exists to catch. See tests/decide-outcome.bats for
# the regression test that proves this.
#
# Env contract — all optional and default to empty string. `steps.<id>.outcome` in GitHub Actions
# is never truly unset once referenced (it is "" for a step that never ran, e.g. under
# `if: ${{ !cancelled() }}` when the job was cancelled before reaching it), so AUDIT_RESULT and
# GUARD_RESULT are treated the same as every other input here: empty is a legitimate "not
# success" value that must route to `infra`/`inconclusive`, not an error.
#   AUDIT_RESULT    steps.audit.outcome                  success | failure | '' | ...
#   GUARD_RESULT    steps.guard.outcome                  success | failure | '' | ...
#   DEGRADED        steps.audit.outputs.degraded         '' | hygiene | execution
#   DEGRADED_REASON steps.audit.outputs.degraded_reason
#   CHANGED         steps.guard.outputs.changed          '' | true | false
#   COMMIT_RESULT   steps.commit.outcome                 '' | success | failure | ...
#   SUMMARY_PATH    auditor summary file, read only when OUTCOME resolves to `clean`
#
# Stdout, exactly three `KEY=value` lines followed by raw REASON content (REASON may itself span
# multiple lines — it is everything after the third line, not a fourth `REASON=` key):
#   OUTCOME=<fixed|clean|inconclusive|infra>
#   KIND=<''|hygiene|execution|guardrail|push>
#   EDITS_LANDED=<true|false>
#   <REASON, zero or more raw lines>
set -euo pipefail

AUDIT_RESULT="${AUDIT_RESULT:-}"
GUARD_RESULT="${GUARD_RESULT:-}"
DEGRADED="${DEGRADED:-}"
DEGRADED_REASON="${DEGRADED_REASON:-}"
CHANGED="${CHANGED:-}"
COMMIT_RESULT="${COMMIT_RESULT:-}"
SUMMARY_PATH="${SUMMARY_PATH:-}"

# The no-drift heading is reachable ONLY from the final else: audit succeeded, not degraded,
# guardrail passed, and nothing changed.
KIND=""; EDITS_LANDED=false; REASON=""
if [ "$AUDIT_RESULT" != "success" ]; then
  OUTCOME=infra
elif [ -n "$DEGRADED" ]; then
  OUTCOME=inconclusive
  KIND="$DEGRADED"
  REASON="$DEGRADED_REASON"
  # A hygiene failure keeps its edits; they are committed if the guardrail passed.
  if [ "$DEGRADED" = "hygiene" ] && [ "$COMMIT_RESULT" = "success" ]; then
    EDITS_LANDED=true
  fi
elif [ "$GUARD_RESULT" != "success" ]; then
  OUTCOME=inconclusive
  KIND=guardrail
  REASON="guardrail rejected the auditor's edits; all edits were reverted"
elif [ "$CHANGED" = "true" ] && [ "$COMMIT_RESULT" != "success" ]; then
  OUTCOME=inconclusive
  KIND=push
  REASON="doc fixes were produced but could not be committed"
elif [ "$CHANGED" = "true" ]; then
  OUTCOME=fixed
else
  OUTCOME=clean
  REASON="$(cat "$SUMMARY_PATH" 2>/dev/null || true)"
fi

echo "OUTCOME=$OUTCOME"
echo "KIND=$KIND"
echo "EDITS_LANDED=$EDITS_LANDED"
printf '%s\n' "$REASON"
