#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/guardrail.sh"
ALLOW_RE='^(README\.md|docs/.*)$'
DENY_RE='(^|/)CHANGELOG\.md$'

setup() {
  cd "$BATS_TEST_TMPDIR"
  rm -rf repo
  git init -q -b main repo && cd repo
  git config user.email t@e.st && git config user.name T
  echo "readme v1" > README.md
  mkdir -p docs src
  echo "guide v1" > docs/guide.md
  echo "log v1" > CHANGELOG.md
  echo "code v1" > src/app.ts
  git add -A && git commit -qm init
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  : > "$GITHUB_OUTPUT"
}

run_guard() {
  run env ALLOW="$ALLOW_RE" DENY="$DENY_RE" FILE_BUDGET="${FILE_BUDGET:-15}" \
      LINE_BUDGET="${LINE_BUDGET:-800}" GITHUB_OUTPUT="$GITHUB_OUTPUT" \
      RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
}

@test "no edits -> changed=false, exit 0" {
  run_guard
  [ "$status" -eq 0 ]
  grep -q 'changed=false' "$GITHUB_OUTPUT"
}

@test "allowed edit -> changed=true and files_path lists it" {
  echo "readme v2" > README.md
  run_guard
  [ "$status" -eq 0 ]
  grep -q 'changed=true' "$GITHUB_OUTPUT"
  files_path=$(grep '^files_path=' "$GITHUB_OUTPUT" | cut -d= -f2)
  grep -qx 'README.md' "$files_path"
}

@test "out-of-allowlist edit -> exit 1 and ALL edits reverted" {
  echo "code v2" > src/app.ts
  echo "readme v2" > README.md
  run_guard
  [ "$status" -eq 1 ]
  [ -z "$(git diff --name-only)" ]
}

@test "denylisted edit -> exit 1 and reverted (even though .md)" {
  echo "log v2" > CHANGELOG.md
  run env ALLOW='^.*\.md$' DENY="$DENY_RE" GITHUB_OUTPUT="$GITHUB_OUTPUT" \
      RUNNER_TEMP="$RUNNER_TEMP" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$(git diff --name-only)" ]
}

@test "file budget exceeded -> exit 1 and reverted" {
  echo "readme v2" > README.md
  echo "guide v2" > docs/guide.md
  FILE_BUDGET=1 run_guard
  [ "$status" -eq 1 ]
  [ -z "$(git diff --name-only)" ]
}

@test "line budget exceeded -> exit 1 and reverted" {
  printf 'a\nb\nc\nd\ne\nf\n' >> README.md
  LINE_BUDGET=2 run_guard
  [ "$status" -eq 1 ]
  [ -z "$(git diff --name-only)" ]
}

@test "removes the transient context file" {
  echo "ctx" > .docs-sentinel-context.md
  run_guard
  [ "$status" -eq 0 ]
  [ ! -f .docs-sentinel-context.md ]
}
