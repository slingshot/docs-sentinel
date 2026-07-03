#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/build-context.sh"

setup() {
  cd "$BATS_TEST_TMPDIR"
  git init -q -b main repo && cd repo
  git config user.email t@e.st && git config user.name T
  echo "hello" > app.txt
  echo "lock-v1" > bun.lock
  git add -A && git commit -qm init
  echo "world" >> app.txt
  echo "lock-v2" >> bun.lock
  git add -A && git commit -qm change
}

@test "rejects a malformed RANGE" {
  run env RANGE='HEAD~1...HEAD; rm -rf /' bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -f .docs-sentinel-context.md ]
}

@test "fails when RANGE is unset" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "writes context containing the changed file list and diff" {
  run env RANGE='HEAD~1...HEAD' bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'app.txt' .docs-sentinel-context.md
  grep -q '^+world' .docs-sentinel-context.md
  grep -q 'Diff range' .docs-sentinel-context.md
}

@test "DIFF_EXCLUDE drops matching content from the diff body but keeps the file list" {
  run env RANGE='HEAD~1...HEAD' DIFF_EXCLUDE='bun.lock package-lock.json' bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'bun.lock' .docs-sentinel-context.md
  ! grep -q '^+lock-v2' .docs-sentinel-context.md
}

@test "truncates diffs over 200KB and still exits 0" {
  head -c 400000 /dev/urandom | base64 > big.txt
  git add big.txt && git commit -qm big
  run env RANGE='HEAD~1...HEAD' bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -c < .docs-sentinel-context.md)" -lt 250000 ]
}
