#!/usr/bin/env bash
# Actual stage wrapper; all state/restore operations are fixture-only mocks.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions stage_run
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { fail "$*"; }
warn() { printf 'warn %s\n' "$*" >> "$TRACE"; }
state_event() { printf 'event %s\n' "$*" >> "$TRACE"; }
state_write() { printf 'write %s\n' "$*" >> "$TRACE"; }
restore_before_stage() { printf 'before %s\n' "$*" >> "$TRACE"; ((BEFORE_OK)); }
restore_after_stage() { printf 'after %s\n' "$*" >> "$TRACE"; ((AFTER_OK)); }
work_stage() { printf 'work\n' >> "$TRACE"; }
TRACE="$TEST_ROOT/skipped"
BEFORE_OK=0 AFTER_OK=1 CURRENT_STAGE=''
stage_run example work_stage
if grep -Eq '^(work|after)' "$TRACE"; then fail 'stage ran after tracking gate refused it'; fi
grep -Fxq 'event example skipped 0' "$TRACE" || fail 'skipped stage missing state event'
[[ -z "$CURRENT_STAGE" ]] || fail 'skipped stage remained active'
TRACE="$TEST_ROOT/success"
BEFORE_OK=1
stage_run example work_stage
[[ "$(awk '/^(before|work|after)/' "$TRACE")" == $'before example\nwork\nafter example' ]] || fail 'tracking order changed'
grep -Fxq 'event example success 0' "$TRACE" || fail 'successful tracking missing state event'
# Failure is tested in a subshell invoked directly, preserving actual errexit.
TRACE="$TEST_ROOT/failure"
AFTER_OK=0
set +e
( set -Eeuo pipefail; stage_run example work_stage; printf 'BAD\n' >> "$TRACE" )
status=$?
set -e
[[ "$status" != 0 ]] || fail 'failed final tracking was hidden'
if grep -Eq '^(BAD|event example success)' "$TRACE"; then fail 'tracking failure was marked success'; fi
printf 'PASS: tracking gates precede work; tracking failure stops completion.\n'
