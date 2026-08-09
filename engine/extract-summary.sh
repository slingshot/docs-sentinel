#!/usr/bin/env bash
# Extract the auditor's summary from a claude --output-format stream-json event stream.
#
# Reasoning and tool-call framing are excluded STRUCTURALLY: assistant content is a typed union, so
# we keep only {"type":"text"} blocks. `thinking` and `tool_use` blocks are dropped by type, not by
# pattern-matching prose — which is what makes this robust where `jq -r '.result'` was not.
#
# Env contract:
#   STREAM_PATH (required)  path to the stream-json JSONL file
#
# Prints the summary on stdout. Exits 1 (message on stderr) when the fence is unbalanced or
# duplicated — guessing which fence was meant is exactly the leniency this job cannot afford.
set -euo pipefail

: "${STREAM_PATH:?STREAM_PATH not set}"

FENCE_OPEN='<docs-sentinel-summary>'
FENCE_CLOSE='</docs-sentinel-summary>'

# One JSON string per assistant message: its text blocks, in order, joined with a blank line.
# `fromjson? // empty` skips a truncated tail line instead of aborting the whole parse.
# `select(type == "object" and ...)` is required, not decorative: `.type` applied to a bare JSON
# scalar is a jq ERROR, not a graceful null, so a stray `true` or a whole-file JSON array would
# abort the script under `set -e` with jq's exit code instead of a clean message.
MSGS=$(jq -Rc 'fromjson? // empty' "$STREAM_PATH" \
  | jq -sc '[ .[]
              | select(type == "object" and .type == "assistant")
              | [ .message.content[]? | select(type == "object" and .type == "text") | .text ]
              | join("\n\n") ]')

count=$(printf '%s' "$MSGS" | jq 'length')
if [ "$count" -eq 0 ]; then
  exit 0
fi

# Prefer the LAST message containing a complete fence. Selecting the last message outright would
# pick up a trailing bare "Done." — models routinely sign off after a final check — which then fails
# shape validation and burns the retry on an otherwise healthy run.
chosen=""
i=$((count - 1))
while [ "$i" -ge 0 ]; do
  t=$(printf '%s' "$MSGS" | jq -r ".[$i]")
  if printf '%s' "$t" | grep -qF "$FENCE_OPEN" && printf '%s' "$t" | grep -qF "$FENCE_CLOSE"; then
    chosen="$t"
    break
  fi
  i=$((i - 1))
done

if [ -z "$chosen" ]; then
  chosen=$(printf '%s' "$MSGS" | jq -r ".[$((count - 1))]")
fi

opens=$(printf '%s' "$chosen" | grep -oF "$FENCE_OPEN" | grep -c '' || true)
closes=$(printf '%s' "$chosen" | grep -oF "$FENCE_CLOSE" | grep -c '' || true)

if [ "$opens" -ne 0 ] || [ "$closes" -ne 0 ]; then
  if [ "$opens" -ne 1 ] || [ "$closes" -ne 1 ]; then
    echo "unbalanced or duplicated docs-sentinel-summary fence (open=$opens close=$closes)" >&2
    exit 1
  fi
  # index()-based, so the fence literals are matched as fixed strings, never as regex.
  chosen=$(printf '%s\n' "$chosen" | awk -v o="$FENCE_OPEN" -v c="$FENCE_CLOSE" '
    BEGIN { inb = 0 }
    {
      line = $0
      if (!inb) {
        p = index(line, o)
        if (p == 0) next
        inb = 1
        line = substr(line, p + length(o))
      }
      q = index(line, c)
      if (q > 0) { print substr(line, 1, q - 1); exit }
      print line
    }')
fi

# Trim leading and trailing blank lines; keep interior blank lines (markdown needs them).
printf '%s\n' "$chosen" | awk '
  { lines[NR] = $0 }
  END {
    start = 1; end = NR
    while (start <= end && lines[start] ~ /^[[:space:]]*$/) start++
    while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
    for (i = start; i <= end; i++) print lines[i]
  }'
