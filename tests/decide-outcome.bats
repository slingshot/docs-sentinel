#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/decide-outcome.sh"

decide() {
  run env AUDIT_RESULT="${1:-}" DEGRADED="${2:-}" DEGRADED_REASON="${3:-}" \
      GUARD_RESULT="${4:-}" CHANGED="${5:-}" COMMIT_RESULT="${6:-}" \
      SUMMARY_PATH="${7:-/dev/null}" bash "$SCRIPT"
}

@test "audit step failed outright -> infra" {
  decide failure "" "" skipped "" skipped
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "OUTCOME=infra" ] || return 1
}

@test "audit step never ran (empty outcome) -> infra" {
  decide "" "" "" skipped "" skipped
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "OUTCOME=infra" ] || return 1
}

@test "execution failure -> inconclusive/execution" {
  decide success execution "claude exited with status 3" skipped "" skipped
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[1]}" = "KIND=execution" ] || return 1
  [ "${lines[2]}" = "EDITS_LANDED=false" ] || return 1
}

@test "hygiene failure with committed edits -> inconclusive/hygiene, EDITS_LANDED=true" {
  decide success hygiene "summary unusable" success true success
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[1]}" = "KIND=hygiene" ] || return 1
  [ "${lines[2]}" = "EDITS_LANDED=true" ] || return 1
}

@test "hygiene failure with a failed commit -> inconclusive/hygiene, EDITS_LANDED=false" {
  decide success hygiene "summary unusable" success true failure
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[1]}" = "KIND=hygiene" ] || return 1
  [ "${lines[2]}" = "EDITS_LANDED=false" ] || return 1
}

@test "guardrail failure with empty CHANGED never yields clean" {
  decide success "" "" failure "" skipped
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[0]}" != "OUTCOME=clean" ] || return 1
  [ "${lines[1]}" = "KIND=guardrail" ] || return 1
}

@test "guardrail success and no changes -> clean" {
  decide success "" "" success false skipped
  [ "${lines[0]}" = "OUTCOME=clean" ] || return 1
}

@test "guardrail success, changes committed -> fixed" {
  decide success "" "" success true success
  [ "${lines[0]}" = "OUTCOME=fixed" ] || return 1
}

@test "guardrail success, changes present but commit failed -> inconclusive/push" {
  decide success "" "" success true failure
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[1]}" = "KIND=push" ] || return 1
}

@test "push-rung reason reads accurately whether compose or push failed" {
  decide success "" "" success true failure
  reason=$(printf '%s\n' "${lines[@]:3}")
  [[ "$reason" == *"could not be committed"* ]] || return 1
  [[ "$reason" != *"could not be pushed"* ]] || return 1
}

@test "clean outcome surfaces the summary file content as REASON" {
  echo "nothing in scope was contradicted" > "$BATS_TEST_TMPDIR/summary.md"
  decide success "" "" success false skipped "$BATS_TEST_TMPDIR/summary.md"
  [ "${lines[0]}" = "OUTCOME=clean" ] || return 1
  reason=$(printf '%s\n' "${lines[@]:3}")
  [[ "$reason" == *"nothing in scope was contradicted"* ]] || return 1
}

@test "hygiene reason passes DEGRADED_REASON through verbatim" {
  decide success hygiene "summary contains tool-call framing tokens" success false skipped
  reason=$(printf '%s\n' "${lines[@]:3}")
  [[ "$reason" == *"summary contains tool-call framing tokens"* ]] || return 1
}

@test "REGRESSION: deleting the GUARD_RESULT rung would misrender a guardrail rejection as clean" {
  # This test documents the exact production bug: guardrail.sh exits 1 on a violation WITHOUT
  # ever writing changed=, so CHANGED is empty. Without the GUARD_RESULT rung ahead of the
  # CHANGED checks, the ladder falls through to `clean` here.
  decide success "" "" failure "" skipped
  [ "${lines[0]}" != "OUTCOME=clean" ] || return 1
}

@test "completely unset AUDIT_RESULT (not even empty string) still resolves to infra, not an error" {
  # steps.audit.outcome is always at least "" once referenced in real Actions env, but the script
  # must not depend on that -- under `set -u` a merely-missing var must not abort the script.
  run env GUARD_RESULT=success bash "$SCRIPT"
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "OUTCOME=infra" ] || return 1
}

@test "completely unset GUARD_RESULT with a successful audit routes past the guardrail rung as non-success" {
  run env AUDIT_RESULT=success CHANGED=false bash "$SCRIPT"
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "OUTCOME=inconclusive" ] || return 1
  [ "${lines[1]}" = "KIND=guardrail" ] || return 1
}
