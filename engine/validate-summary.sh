#!/usr/bin/env bash
# Mechanically decide whether the auditor's summary is usable. This is the backstop the model cannot
# talk its way past — the same posture guardrail.sh takes toward file edits, applied to prose.
#
# The state machine is the part that actually prevents the PR #8 failure class: today a summary can
# disagree with the working tree in EITHER direction (claim no updates while edits exist, or claim
# edits while none exist) and still be rendered as a confident result.
#
# Env contract:
#   SUMMARY_PATH (required)  extracted summary text
#   EDITED_COUNT (required)  number of files currently modified in the working tree
#   LINE_CAP     (optional)  default 60 — a proxy for a reasoning flood
#   BYTE_CAP     (optional)  default 8192
#
# Exit 0 and print "ok" when usable; exit 1 and print a one-line reason otherwise.
set -euo pipefail

fail() { echo "$1"; exit 1; }

[ -n "${SUMMARY_PATH:-}" ] || fail "SUMMARY_PATH not set"
[ -n "${EDITED_COUNT:-}" ] || fail "EDITED_COUNT not set"
LINE_CAP="${LINE_CAP:-60}"
BYTE_CAP="${BYTE_CAP:-8192}"

if ! printf '%s' "$EDITED_COUNT" | grep -qE '^[0-9]+$'; then
  fail "EDITED_COUNT must be a non-negative integer (got '$EDITED_COUNT')"
fi

[ -s "$SUMMARY_PATH" ] || fail "summary is empty"

# Normalise line endings so a CRLF stream cannot defeat the anchored patterns below. The filename is
# suffixed with $$ and removed on exit so concurrent invocations (no shared RUNNER_TEMP) don't clobber
# each other's scratch file.
NORM="${RUNNER_TEMP:-/tmp}/docs-sentinel-summary.$$.norm"
trap 'rm -f "$NORM"' EXIT
tr -d '\r' < "$SUMMARY_PATH" > "$NORM"

if [ -z "$(tr -d '[:space:]' < "$NORM")" ]; then
  fail "summary is whitespace-only"
fi

bytes=$(wc -c < "$NORM" | tr -d ' ')
[ "$bytes" -le "$BYTE_CAP" ] || fail "summary exceeds byte cap ($bytes > $BYTE_CAP)"

lines=$(grep -c '' "$NORM" || true)
[ "$lines" -le "$LINE_CAP" ] || fail "summary exceeds line cap ($lines > $LINE_CAP)"

# Tool-call framing families, case-insensitive. U+FF5C (fullwidth vertical line) is DeepSeek's DSML
# delimiter; a gateway that ASCII-normalises it would emit `<|DSML|...>` instead, so both are listed.
# Trade-off, accepted deliberately: a repo whose docs discuss LLM tool-calling can trip this and
# degrade to inconclusive. The scan applies to the model's own summary prose, not to doc content,
# and failing toward "inconclusive" is the safe direction.
if grep -qiE '｜|<[|]|DSML|<invoke|<function_calls|<tool_calls|<tool_use' "$NORM"; then
  fail "summary contains tool-call framing tokens"
fi

first=$(grep -m1 -v '^[[:space:]]*$' "$NORM" || true)
NOUPDATE_RE='^No documentation updates needed'

if [ "$EDITED_COUNT" -eq 0 ]; then
  if ! printf '%s' "$first" | grep -qE "$NOUPDATE_RE"; then
    fail "no edits were made, but the summary is not a 'No documentation updates needed' verdict"
  fi
else
  if ! printf '%s' "$first" | grep -q '^Subject: '; then
    fail "$EDITED_COUNT file(s) were edited, but the summary has no leading 'Subject: ' line"
  fi
  if ! grep -qE '^[[:space:]]*[-*] ' "$NORM"; then
    fail "$EDITED_COUNT file(s) were edited, but the summary has no bullet list"
  fi
  if grep -qE "$NOUPDATE_RE" "$NORM"; then
    fail "$EDITED_COUNT file(s) were edited, but the summary claims no updates were needed"
  fi
fi

echo "ok"
