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

@test "skip marker is in the footer, not the subject" {
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  commit="$RUNNER_TEMP/docs-sentinel-commit.txt"
  # gate greps the WHOLE message, so the marker just has to be present somewhere
  grep -qF '[skip docs-sentinel]' "$commit"
  # ...but no longer on the subject line
  ! head -1 "$commit" | grep -qF '[skip docs-sentinel]'
  # it is the last non-empty line (a footer trailer)
  [ "$(grep -v '^[[:space:]]*$' "$commit" | tail -1)" = '[skip docs-sentinel]' ]
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
  grep -q '^pr_title=' "$GITHUB_OUTPUT"
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

@test "extracts a Subject: line as the commit subject and pr_title, keeps it out of the body" {
  printf 'Subject: docs(readme): sync dev port\n\n- `README.md` — updated the port to 3500.\n' \
    > "$BATS_TEST_TMPDIR/summary.md"
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  commit="$RUNNER_TEMP/docs-sentinel-commit.txt"
  [ "$(head -1 "$commit")" = 'docs(readme): sync dev port' ]
  ! grep -q '^Subject:' "$commit"                 # the sentinel line never leaks into the message
  grep -q 'updated the port to 3500' "$commit"    # body prose still present
  grep -qx 'pr_title=docs(readme): sync dev port' "$GITHUB_OUTPUT"
}

@test "no Subject: line falls back to the default subject" {
  # setup()'s summary.md has no Subject: line
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$(head -1 "$RUNNER_TEMP/docs-sentinel-commit.txt")" = 'docs: sync documentation with code changes' ]
  grep -qx 'pr_title=docs: sync documentation with code changes' "$GITHUB_OUTPUT"
}

@test "an over-long Subject: line falls back to the default subject" {
  long=$(printf 'x%.0s' $(seq 1 130))
  printf 'Subject: docs: %s\n\n- `README.md` — x.\n' "$long" > "$BATS_TEST_TMPDIR/summary.md"
  run env FILES_PATH="$BATS_TEST_TMPDIR/files.txt" SUMMARY_PATH="$BATS_TEST_TMPDIR/summary.md" \
      SHA=0123456789abcdef GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$(head -1 "$RUNNER_TEMP/docs-sentinel-commit.txt")" = 'docs: sync documentation with code changes' ]
}
