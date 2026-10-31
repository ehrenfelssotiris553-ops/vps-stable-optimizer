#!/usr/bin/env bash
# CI only. Runs one step command with its output kept; when it fails, the end
# of that output, and of the newest transcript under the CI logs, become error
# annotations. GitHub shows annotations to everyone, while the full logs of a
# public repository can only be read after signing in.
# Usage: report.sh TITLE COMMAND [ARG ...]
set -Eeuo pipefail
title="$1"
shift
logs="${CI_LOGS:-${RUNNER_TEMP:-/tmp}/vps-ci-logs}"
out="${RUNNER_TEMP:-/tmp}/step-$$.log"

# One annotation with the last 40 lines of FILE (colours removed; %, CR and LF
# escaped as the workflow command format requires).
annotate() {
  local text
  text="$(tail -n 40 -- "$2" | sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
    sed -e ':a' -e 'N' -e '$!ba' -e 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
  printf '::error title=%s::%s\n' "$1" "$text"
}

rc=0
"$@" 2>&1 | tee -- "$out" || rc="${PIPESTATUS[0]}"
if ((rc)); then
  annotate "$title (exit $rc)" "$out"
  latest="$(find "$logs" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  if [[ -n "$latest" ]]; then annotate "$title - end of ${latest##*/}" "$latest"; fi
fi
exit "$rc"
