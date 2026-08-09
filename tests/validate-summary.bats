#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/validate-summary.sh"

setup() {
  cd "$BATS_TEST_TMPDIR"
  SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  # Scope the script's scratch file to this test's tmpdir; the default /tmp path would collide
  # when bats runs with --jobs.
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
}

run_validate() {
  run env SUMMARY_PATH="$SUMMARY" EDITED_COUNT="${1:-0}" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
}

@test "PR #8/#11 regression: DSML closing tags rejected" {
  printf '</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n</\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"framing"* ]] || return 1
}

@test "ASCII-normalised DSML variant also rejected" {
  printf '</|DSML|invoke>\n' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
}

@test "PR #12 regression: reasoning flood rejected on line cap" {
  { for i in $(seq 1 80); do echo "Let me reconsider point $i once more."; done; } > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line cap"* ]] || return 1
}

@test "empty summary rejected" {
  : > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
}

@test "whitespace-only summary rejected" {
  printf '   \n\n\t\n' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
}

@test "valid no-update verdict with zero edits accepted" {
  echo 'No documentation updates needed — nothing in scope was contradicted.' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 0 ]
}

@test "valid Subject form with edits accepted" {
  printf 'Subject: docs: sync documentation with code changes\n\n- `README.md` — port 3400 to 3500.\n' > "$SUMMARY"
  run_validate 2
  [ "$status" -eq 0 ]
}

@test "state machine: edits present but no-update verdict is rejected" {
  echo 'No documentation updates needed — nothing drifted.' > "$SUMMARY"
  run_validate 3
  [ "$status" -eq 1 ]
}

@test "state machine: zero edits but Subject form is rejected" {
  printf 'Subject: docs: sync\n\n- `README.md` — invented.\n' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
}

@test "state machine: edits present but no bullet is rejected" {
  printf 'Subject: docs: sync documentation with code changes\n\nI changed some things.\n' > "$SUMMARY"
  run_validate 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"bullet"* ]] || return 1
}

@test "state machine: Subject form that also claims no updates is rejected" {
  printf 'Subject: docs: sync\n\n- `README.md` — port.\n\nNo documentation updates needed — actually nothing.\n' > "$SUMMARY"
  run_validate 2
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"claims no updates"* ]] || return 1
}

@test "EDITED_COUNT unset produces a one-line stdout reason and exit 1" {
  echo 'No documentation updates needed — clean.' > "$SUMMARY"
  run env -u EDITED_COUNT SUMMARY_PATH="$SUMMARY" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 1 ] || return 1
  [ -n "$output" ] || return 1
}

@test "byte cap enforced" {
  { echo 'No documentation updates needed — see below.'; head -c 9000 /dev/zero | tr '\0' 'x'; } > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"byte cap"* ]] || return 1
}

@test "CRLF line endings do not break validation" {
  printf 'No documentation updates needed — clean.\r\n' > "$SUMMARY"
  run_validate 0
  [ "$status" -eq 0 ]
}
