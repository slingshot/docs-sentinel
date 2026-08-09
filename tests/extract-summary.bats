#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/extract-summary.sh"

setup() {
  cd "$BATS_TEST_TMPDIR"
  STREAM="$BATS_TEST_TMPDIR/stream.jsonl"
}

# Append one assistant message whose content blocks are given as a JSON array literal.
assistant() { printf '{"type":"assistant","message":{"content":%s}}\n' "$1" >> "$STREAM"; }
text_block() { jq -nc --arg t "$1" '[{type:"text",text:$t}]'; }
run_extract() { run env STREAM_PATH="$STREAM" bash "$SCRIPT"; }

@test "keeps text blocks and discards thinking and tool_use" {
  : > "$STREAM"
  assistant '[{"type":"thinking","thinking":"let me reconsider whether to edit"},
              {"type":"tool_use","id":"t1","name":"Read","input":{}},
              {"type":"text","text":"Subject: docs: sync"}]'
  echo '{"type":"result","subtype":"success","is_error":false}' >> "$STREAM"
  run_extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subject: docs: sync"* ]]
  [[ "$output" != *"reconsider"* ]]
  [[ "$output" != *"tool_use"* ]]
}

@test "joins multiple text blocks with a blank line" {
  : > "$STREAM"
  assistant '[{"type":"text","text":"first"},{"type":"text","text":"second"}]'
  run_extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"first"* ]] && [[ "$output" == *"second"* ]]
}

@test "prefers the fenced message over a later bare sign-off" {
  : > "$STREAM"
  assistant "$(text_block '<docs-sentinel-summary>
Subject: docs: sync documentation with code changes

- `README.md` — port changed.
</docs-sentinel-summary>')"
  assistant "$(text_block 'Done.')"
  run_extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subject: docs: sync"* ]]
  [[ "$output" != *"Done."* ]]
  [[ "$output" != *"docs-sentinel-summary"* ]]
}

@test "falls back to the last message when no fence appears" {
  : > "$STREAM"
  assistant "$(text_block 'first message')"
  assistant "$(text_block 'No documentation updates needed — nothing drifted.')"
  run_extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"No documentation updates needed"* ]]
  [[ "$output" != *"first message"* ]]
}

@test "survives a truncated trailing line" {
  : > "$STREAM"
  assistant "$(text_block 'No documentation updates needed — clean.')"
  printf '{"type":"result","subty' >> "$STREAM"
  run_extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"No documentation updates needed"* ]]
}

@test "unbalanced fence -> exit 1" {
  : > "$STREAM"
  assistant "$(text_block '<docs-sentinel-summary>
Subject: docs: sync')"
  run_extract
  [ "$status" -eq 1 ]
}

@test "duplicated fence pair -> exit 1" {
  : > "$STREAM"
  assistant "$(text_block '<docs-sentinel-summary>a</docs-sentinel-summary>
<docs-sentinel-summary>b</docs-sentinel-summary>')"
  run_extract
  [ "$status" -eq 1 ]
}

@test "no assistant messages -> empty output, exit 0" {
  echo '{"type":"result","subtype":"success","is_error":false}' > "$STREAM"
  run_extract
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
