#!/usr/bin/env bash
# Write the code change (changed files + unified diff) to .docs-sentinel-context.md at the repo
# root, which the auditor prompt instructs the agent to read first.
#
# Env contract:
#   RANGE        (required)  git revision range, shape A...B — built by the gate job from SHAs/refs
#   DIFF_EXCLUDE (optional)  space-separated pathspec patterns excluded from the diff BODY
#                            (the changed-file LIST is never filtered — the auditor should still
#                            see that e.g. a lockfile changed, just not wade through its contents)
set -euo pipefail

: "${RANGE:?RANGE not set}"

# Defense in depth: RANGE is built by the workflow from git SHAs and branch refs, but validate its
# shape before passing it (unquoted, as a git revision range) to git.
if ! printf '%s' "$RANGE" | grep -qE '^[A-Za-z0-9/._~^-]+\.\.\.[A-Za-z0-9/._~^-]+$'; then
  echo "::error::Unexpected diff range: $RANGE"
  exit 1
fi

# Turn DIFF_EXCLUDE into git exclude pathspecs. The ${arr[@]+...} guard keeps empty-array
# expansion safe under `set -u` on bash 3.2 (macOS) — do not "simplify" it away.
EXCLUDES=()
for pat in ${DIFF_EXCLUDE:-}; do
  EXCLUDES+=(":(exclude,glob)**/$pat" ":(exclude)$pat")
done

CONTEXT_FILE=".docs-sentinel-context.md"
{
  echo "# Code change context"
  echo
  echo "Diff range: \`$RANGE\`"
  echo
  echo "## Changed files"
  echo '```'
  # shellcheck disable=SC2086
  git diff --name-only --diff-filter=ACMR $RANGE
  echo '```'
  echo
  echo "## Unified diff (truncated to 200 KB)"
  echo '```diff'
  # `head -c` closes the pipe once it has its 200 KB, which sends `git diff` SIGPIPE (exit 141).
  # Without scoping `pipefail` off here, that would propagate and `set -e` would abort the whole
  # script on any diff larger than the cap. The early close is intentional truncation, not failure.
  set +o pipefail
  # shellcheck disable=SC2086
  git diff --diff-filter=ACMR $RANGE -- . ${EXCLUDES[@]+"${EXCLUDES[@]}"} | head -c 200000
  set -o pipefail
  echo '```'
} > "$CONTEXT_FILE"

echo "Wrote $CONTEXT_FILE ($(wc -c < "$CONTEXT_FILE") bytes)."
