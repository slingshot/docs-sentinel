#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/render-status.sh"

render() {
  run env OUTCOME="$1" REASON="${2:-}" BODY="${3:-}" KIND="${4:-}" EDITS_LANDED="${5:-false}" \
      RUN_URL="https://example/run" bash "$SCRIPT"
}

@test "inconclusive NEVER renders the no-drift heading" {
  render inconclusive "summary contains tool-call framing tokens" "" hygiene
  [ "$status" -eq 0 ]
  [[ "$output" != *"no documentation drift detected"* ]] || return 1
  [[ "$output" == *"inconclusive"* ]] || return 1
  [[ "$output" == *"not** been confirmed"* ]] || return 1
}

@test "guardrail rejection reads as a rejection, not a clean pass" {
  render inconclusive "guardrail rejected the auditor's edits" "" guardrail
  [ "$status" -eq 0 ]
  [[ "$output" != *"no documentation drift detected"* ]] || return 1
  [[ "$output" == *"every** edit was reverted"* ]] || return 1
}

@test "execution failure says the audit did not complete" {
  render inconclusive "claude exited with status 3" "" execution
  [[ "$output" == *"did not complete"* ]] || return 1
  [[ "$output" != *"summary was unusable"* ]] || return 1
}

@test "hygiene failure with landed edits says the edits landed" {
  render inconclusive "summary unusable" "" hygiene true
  [[ "$output" == *"still committed to this PR"* ]] || return 1
}

@test "hygiene failure without landed edits does not claim edits landed" {
  render inconclusive "summary unusable" "" hygiene false
  [[ "$output" != *"still committed to this PR"* ]] || return 1
}

@test "failed push reads as unpushed, not as fixed" {
  render inconclusive "could not push" "" push
  [[ "$output" == *"could not be committed"* ]] || return 1
}

@test "infra failure NEVER renders the no-drift heading" {
  render infra
  [ "$status" -eq 0 ]
  [[ "$output" != *"no documentation drift detected"* ]] || return 1
  [[ "$output" == *"could not run"* ]] || return 1
}

@test "clean renders the no-drift heading" {
  render clean "nothing in scope was contradicted"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no documentation drift detected"* ]] || return 1
}

@test "fixed passes the composed body through verbatim" {
  render fixed "" "🤖 **Docs audit** updated documentation."
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated documentation"* ]] || return 1
}

@test "inconclusive surfaces the reason" {
  render inconclusive "claude exited with status 3"
  [[ "$output" == *"claude exited with status 3"* ]] || return 1
}

@test "unknown outcome fails closed" {
  render bogus
  [ "$status" -eq 1 ]
}
