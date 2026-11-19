#!/usr/bin/env bash
# CI only. Runs one step command with its output kept; when it fails, the end
# of that output, and of the newest transcript under the CI logs, become error
# annotations. GitHub shows annotations to everyone, while the full logs of a
# public repository can only be read after signing in.
# Usage: report.sh TITLE COMMAND [ARG ...]
# STEP_MINUTES (set by the workflow): the command is stopped that long after it
# started, before the job's own limit, which ends a job without a word: so a
# step that hangs still says where. (It gets TERM, then KILL 150 seconds later.)
set -Eeuo pipefail
title="$1"
shift
logs="${CI_LOGS:-${RUNNER_TEMP:-/tmp}/vps-ci-logs}"
out="${RUNNER_TEMP:-/tmp}/step-$$.log"
limit=()
if [[ "${STEP_MINUTES:-}" =~ ^[1-9][0-9]*$ ]]; then limit=(timeout --kill-after=150s "${STEP_MINUTES}m"); fi

# One annotation with the last 40 lines of FILE (colours removed; %, CR and LF
# escaped as the workflow command format requires).
annotate() {
  local text
  text="$(tail -n 40 -- "$2" | sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
    sed -e ':a' -e 'N' -e '$!ba' -e 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
  printf '::error title=%s::%s\n' "$1" "$text"
}

rc=0
"${limit[@]}" "$@" 2>&1 | tee -- "$out" || rc="${PIPESTATUS[0]}"
if ((${#limit[@]})) && ((rc == 124 || rc == 137)); then
  printf '::error title=%s::stopped at the time limit of the step (%s minutes)\n' "$title" "$STEP_MINUTES"
fi
if ((rc)); then
  annotate "$title (exit $rc)" "$out"
  # Failures from earlier in a long output (each test file keeps going).
  if grep -E '^(FAIL|STOP):|^Running |unbound variable|command not found|No such file|Cannot extract|answer.exp:' -- "$out" > "$out.lines"; then
    annotate "$title - failure lines" "$out.lines"
  fi
  # (A transcript still being written is only the .raw one: its command was stopped.)
  latest="$(find "$logs" -maxdepth 1 \( -name '*.log' -o -name '*.raw' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  if [[ -n "$latest" ]]; then annotate "$title - end of ${latest##*/}" "$latest"; fi
fi
exit "$rc"
