#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/compose-message.sh"

setup() {
  cd "$BATS_TEST_TMPDIR"
  rm -rf repo
  git init -q -b main repo && cd repo
  git config user.email t@e.st && git config user.name T
  echo "port is 3400" > README.md
  git add -A && git commit -qm init
  echo "port is 3500" > README.md          # uncommitted doc edit, like the real flow
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"
  : > "$GITHUB_OUTPUT"
  printf 'README.md\n' > "$BATS_TEST_TMPDIR/files.txt"
  printf -- '- `README.md` — updated the port to 3500.\n' > "$BATS_TEST_TMPDIR/summary.md"
}

@test "body has summary, file bullet, doc diff, footer" {
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  body="$RUNNER_TEMP/docs-sentinel-body.md"
  grep -q 'What changed and why' "$body"
  grep -q 'updated the port to 3500' "$body"
  grep -q -- '- `README.md`' "$body"
  grep -q '+port is 3500' "$body"
  grep -q 'docs-sentinel' "$body"
}

@test "commit subject carries the skip marker" {
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  head -1 "$RUNNER_TEMP/docs-sentinel-commit.txt" | grep -qF '[skip docs-sentinel]'
}

@test "missing summary degrades gracefully" {
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/nope.md" \
      GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'What changed and why' "$RUNNER_TEMP/docs-sentinel-body.md"
}

@test "emits commit_path, body_path, and multiline commit_message outputs" {
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  grep -q '^commit_path=' "$GITHUB_OUTPUT"
  grep -q '^body_path=' "$GITHUB_OUTPUT"
  grep -q '^commit_message<<' "$GITHUB_OUTPUT"
}

@test "empty FILES_PATH yields no doc diff, not a full-tree diff" {
  : > "$BATS_TEST_TMPDIR/files.txt"
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" GITHUB_OUTPUT="$GITHUB_OUTPUT" \
      RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '+port is 3500' "$RUNNER_TEMP/docs-sentinel-body.md"
}

@test "summary containing the old static delimiter cannot break GITHUB_OUTPUT" {
  printf 'evil\n__DOCS_SENTINEL_MSG__\ninjected=1\n' > "$BATS_TEST_TMPDIR/summary.md"
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  opener=$(grep -o 'commit_message<<.*' "$GITHUB_OUTPUT" | head -1 | sed 's/commit_message<<//')
  [ "$opener" != "__DOCS_SENTINEL_MSG__" ]
  grep -qx "$opener" "$GITHUB_OUTPUT"
}
