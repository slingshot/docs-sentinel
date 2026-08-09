#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/run-auditor.sh"
ENGINE="$BATS_TEST_DIRNAME/../engine"

setup() {
  cd "$BATS_TEST_TMPDIR"
  rm -rf repo bin
  git init -q -b main repo
  mkdir -p bin
  cd repo
  git config user.email t@e.st && git config user.name T
  echo "readme v1" > README.md
  echo "code v1" > app.ts
  git add -A && git commit -qm init
  git commit -q --allow-empty -m second

  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"; : > "$GITHUB_OUTPUT"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_sum"; : > "$GITHUB_STEP_SUMMARY"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  export ENGINE_DIR="$ENGINE"
  export RANGE="HEAD~1...HEAD"
  export PROMPT_PATH="$BATS_TEST_TMPDIR/prompt.md"
  echo "audit the change" > "$PROMPT_PATH"
  export CLAUDE_BIN="$BATS_TEST_TMPDIR/bin/fake-claude"
  export ATTEMPT_LOG="$BATS_TEST_TMPDIR/attempts.log"
  : > "$ATTEMPT_LOG"
}

# Build a stub `claude`. $1 is a shell snippet run per attempt; it may inspect $attempt_no.
make_claude() {
  cat > "$CLAUDE_BIN" <<STUB
#!/usr/bin/env bash
echo x >> "$ATTEMPT_LOG"
attempt_no=\$(grep -c '' "$ATTEMPT_LOG")
$1
STUB
  chmod +x "$CLAUDE_BIN"
}

emit_ok_stream() {
  cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"text","text":"<docs-sentinel-summary>\nNo documentation updates needed — nothing drifted.\n</docs-sentinel-summary>"}]}}
{"type":"result","subtype":"success","is_error":false}
JSON
}

run_auditor() { run env bash "$SCRIPT"; }
out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }

@test "clean first attempt -> not degraded, one invocation" {
  make_claude "$(declare -f emit_ok_stream); emit_ok_stream"
  run_auditor
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "" ]
  [ "$(grep -c '' "$ATTEMPT_LOG")" -eq 1 ]
}

@test "hygiene failure retries once then degrades, keeping edits" {
  make_claude '
    echo "edited" > README.md
    printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"garbage with <invoke tags\"}]}}\n"
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}\n"'
  run_auditor
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "hygiene" ]
  [ "$(grep -c '' "$ATTEMPT_LOG")" -eq 2 ]
  grep -q "edited" README.md
}

@test "execution failure discards edits and resets the tree" {
  make_claude '
    echo "half-written" > README.md
    printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}}\n"'
  run_auditor
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "execution" ]
  [ -z "$(git diff --name-only)" ]
  grep -q "readme v1" README.md
}

@test "non-zero exit is an execution failure" {
  make_claude 'exit 3'
  run_auditor
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "execution" ]
}

@test "tree and context file are reset between attempts" {
  make_claude '
    if [ "$attempt_no" -eq 1 ]; then
      echo "poisoned" > .docs-sentinel-context.md
      echo "attempt1" > README.md
      printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"bad <tool_use\"}]}}\n"
      printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}\n"
    else
      grep -q poisoned .docs-sentinel-context.md && echo "CONTEXT_NOT_RESET" >&2
      grep -q attempt1 README.md && echo "TREE_NOT_RESET" >&2
      [ -s .docs-sentinel-context.md ] || echo "CONTEXT_NOT_REGENERATED" >&2
      printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"No documentation updates needed — clean.\"}]}}\n"
      printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}\n"
    fi'
  run_auditor
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "" ]
  ! grep -q "CONTEXT_NOT_RESET" "$RUNNER_TEMP"/auditor-stderr-2.log
  ! grep -q "TREE_NOT_RESET" "$RUNNER_TEMP"/auditor-stderr-2.log
  ! grep -q "CONTEXT_NOT_REGENERATED" "$RUNNER_TEMP"/auditor-stderr-2.log
}

@test "the credential never appears in argv" {
  make_claude 'printf "%s\n" "$@" > '"$BATS_TEST_TMPDIR"'/argv.txt
    '"$(declare -f emit_ok_stream)"'; emit_ok_stream'
  ANTHROPIC_AUTH_TOKEN="sk-super-secret" run_auditor
  [ "$status" -eq 0 ]
  ! grep -q "sk-super-secret" "$BATS_TEST_TMPDIR/argv.txt"
}

@test "degraded_reason is a single line" {
  make_claude 'exit 3'
  run_auditor
  [ "$(out degraded_reason | grep -c '')" -eq 1 ]
}
