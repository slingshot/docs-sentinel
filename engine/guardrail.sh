#!/usr/bin/env bash
# Mechanical backstop the auditor cannot talk its way past: keep its edits inside the documentation
# allowlist and under a churn budget, or revert everything and fail.
#
# Env contract:
#   ALLOW        (required)  anchored ERE — the ONLY paths the auditor may touch
#   DENY         (optional)  ERE — forbidden even if allowlisted
#   FILE_BUDGET  (optional)  max edited files, default 15
#   LINE_BUDGET  (optional)  max total changed lines, default 800
#                Budgets must be non-negative integers; anything else is a config error (fail closed).
#   GITHUB_OUTPUT (required) step-output file; emits `changed` and (when true) `files_path`
set -euo pipefail

: "${ALLOW:?ALLOW (allowlist regex) not set}"
DENY="${DENY:-}"
FILE_BUDGET="${FILE_BUDGET:-15}"
LINE_BUDGET="${LINE_BUDGET:-800}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"

# Fail closed on garbage budgets — a misconfigured guardrail must not silently stop guarding.
for b in "$FILE_BUDGET" "$LINE_BUDGET"; do
  if ! printf '%s' "$b" | grep -qE '^[0-9]+$'; then
    echo "::error::Budget values must be non-negative integers (FILE_BUDGET='$FILE_BUDGET', LINE_BUDGET='$LINE_BUDGET')."
    exit 1
  fi
done

# Drop the transient context file so downstream `git add -A` can never commit it.
rm -f .docs-sentinel-context.md

# Tracked modifications the auditor made, HEAD-relative so STAGED edits are caught too. It cannot
# create files (Write is disallowed), so there are no untracked files to consider. (while-read, not
# mapfile: bash 3.2 portability.)
CHANGED=()
while IFS= read -r f; do
  if [ -n "$f" ]; then CHANGED+=("$f"); fi
done < <(git diff HEAD --name-only)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "Auditor made no documentation edits."
  echo "changed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "Auditor changed ${#CHANGED[@]} file(s):"
printf '  %s\n' "${CHANGED[@]}"

violation=0
for f in "${CHANGED[@]}"; do
  if [ -n "$DENY" ] && printf '%s' "$f" | grep -qE "$DENY"; then
    echo "::error::Auditor touched a forbidden file: $f"
    violation=1
    continue
  fi
  if ! printf '%s' "$f" | grep -qE "$ALLOW"; then
    echo "::error::Auditor touched a file outside the doc allowlist: $f"
    violation=1
  fi
done

# Size budget — a doc sync is surgical; a runaway rewrite is a bug.
nfiles=${#CHANGED[@]}
nlines=$(git diff HEAD --numstat | awk '{a+=$1; d+=$2} END {print a+d+0}')
echo "Churn: ${nfiles} file(s), ${nlines} line(s) changed."
if [ "$nfiles" -gt "$FILE_BUDGET" ] || [ "$nlines" -gt "$LINE_BUDGET" ]; then
  echo "::error::Edit exceeds budget (files ${nfiles}/${FILE_BUDGET}, lines ${nlines}/${LINE_BUDGET})."
  violation=1
fi

if [ "$violation" -ne 0 ]; then
  echo "Reverting ALL auditor edits."
  git reset -q --hard HEAD
  git clean -ffdx
  exit 1
fi

FILES_OUT="${RUNNER_TEMP:-/tmp}/docs-sentinel-changed.txt"
printf '%s\n' "${CHANGED[@]}" > "$FILES_OUT"
echo "changed=true" >> "$GITHUB_OUTPUT"
echo "files_path=$FILES_OUT" >> "$GITHUB_OUTPUT"
echo "Guardrail passed."
