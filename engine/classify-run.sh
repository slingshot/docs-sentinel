#!/usr/bin/env bash
# Decide whether an auditor attempt actually COMPLETED, independent of whether its prose is usable.
# This is the execution-vs-hygiene split: edits from a run that did not complete must never be
# committed, because the guardrail proves paths and churn are legal — not that the edit set is
# coherent. A run killed mid-edit-loop leaves a half-updated but fully allowlist-compliant document.
#
# Env contract:
#   STREAM_PATH (required)  path to the claude --output-format stream-json JSONL file
#
# Exit 0 and print "ok" when the run completed cleanly; exit 1 and print a one-line reason otherwise.
set -euo pipefail

: "${STREAM_PATH:?STREAM_PATH not set}"

fail() { echo "$1"; exit 1; }

[ -s "$STREAM_PATH" ] || fail "empty event stream"

# Every line must parse. A truncated tail is the signature of a killed or disconnected run, and it
# is precisely the case where a syntactically valid earlier message could be mistaken for a verdict.
# Only non-blank lines are counted, so a trailing newline the gateway happens to emit is not
# mistaken for a truncated/malformed line.
total=$(grep -c '[^[:space:]]' "$STREAM_PATH" || true)
parsed=$(jq -Rc 'fromjson? // empty' "$STREAM_PATH" 2>/dev/null | grep -c '' || true)
[ "$total" -eq "$parsed" ] || fail "malformed or truncated JSONL ($parsed/$total lines parsed)"

# Every parsed value must be an object (the event stream format)
parsed_objects=$(jq -Rc 'fromjson? // empty | select(type == "object") // empty' "$STREAM_PATH" 2>/dev/null | grep -c '' || true)
[ "$parsed_objects" -eq "$parsed" ] || fail "stream contains non-object JSON values ($parsed_objects/$parsed are objects)"

RESULTS=$(jq -Rc 'fromjson? // empty' "$STREAM_PATH" | jq -sc '[.[] | select(type == "object" and .type == "result")]')

n=$(printf '%s' "$RESULTS" | jq 'length')
[ "$n" -eq 1 ] || fail "expected exactly one terminal result event, found $n"

is_error=$(printf '%s' "$RESULTS" | jq -r '.[0].is_error // false')
[ "$is_error" = "false" ] || fail "result.is_error is true"

subtype=$(printf '%s' "$RESULTS" | jq -r '.[0].subtype // ""')
[ "$subtype" = "success" ] || fail "result.subtype is '$subtype', expected 'success'"

api_err=$(printf '%s' "$RESULTS" | jq -r '.[0].api_error_status // ""')
if [ -n "$api_err" ] && [ "$api_err" != "null" ]; then
  fail "result.api_error_status is $api_err"
fi

echo "ok"
