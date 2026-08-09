#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../engine/classify-run.sh"

setup() {
  cd "$BATS_TEST_TMPDIR"
  STREAM="$BATS_TEST_TMPDIR/stream.jsonl"
}

# Emit a well-formed stream whose terminal result event is customisable.
write_stream() {
  local subtype="${1:-success}" is_error="${2:-false}" extra="${3:-}"
  {
    echo '{"type":"system","subtype":"init"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
    printf '{"type":"result","subtype":"%s","is_error":%s%s}\n' "$subtype" "$is_error" "$extra"
  } > "$STREAM"
}

run_classify() { run env STREAM_PATH="$STREAM" bash "$SCRIPT"; }

@test "clean success stream -> exit 0" {
  write_stream success false
  run_classify
  [ "$status" -eq 0 ]
}

@test "empty stream -> exit 1" {
  : > "$STREAM"
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]
}

@test "truncated final line -> exit 1" {
  write_stream success false
  printf '{"type":"result","subtype":"suc' >> "$STREAM"
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]
}

@test "missing terminal result event -> exit 1" {
  {
    echo '{"type":"system","subtype":"init"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
  } > "$STREAM"
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one"* ]]
}

@test "is_error true -> exit 1" {
  write_stream success true
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"is_error"* ]]
}

@test "non-success subtype -> exit 1" {
  write_stream error_max_turns false
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"error_max_turns"* ]]
}

@test "api_error_status present -> exit 1" {
  write_stream success false ',"api_error_status":429'
  run_classify
  [ "$status" -eq 1 ]
  [[ "$output" == *"api_error_status"* ]]
}
