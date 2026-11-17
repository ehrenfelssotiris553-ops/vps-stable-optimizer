#!/usr/bin/env bash
# The whole script, sourced, with its real global settings: the error trap,
# the exit trap and errexit as every run of the tool has them. What only holds
# without them (functions lifted out one by one never have them) does not hold
# for a user: up to 3.1.4 an unexpected error in a small step of one-click
# setup still ended the whole run, although the step ran on its own.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
optimizer_sourceable || fail "this version of the script cannot be sourced whole: $TEST_SCRIPT"

# Sourcing defines everything and runs nothing; the caller keeps its own
# umask, PATH and shell options.
(
  umask 027
  before="$(umask):$PATH:$-"
  # shellcheck source=/dev/null
  source "$TEST_SCRIPT"
  [[ "$(umask):$PATH:$-" == "$before" ]] || fail "sourcing changed umask, PATH or the shell options: $before -> $(umask):$PATH:$-"
  [[ "$VPS_SOURCED" == 1 ]] || fail 'the script does not know it was sourced'
  for name in main menu runtime_args runtime_traps runtime_detect stage_run_isolated on_error on_exit; do
    declare -F "$name" > /dev/null || fail "sourcing did not define $name"
  done
  [[ -z "$(trap -p ERR)" && -z "$(trap -p INT)" ]] || fail 'sourcing installed the traps of a run'
) || exit 1
# Run directly it is the tool itself: the version, the help and a wrong mode
# end before anything is detected or changed.
[[ "$(bash "$TEST_SCRIPT" --version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'run directly, --version does not print the version'
bash "$TEST_SCRIPT" help | grep -Fq 'vps setup' || fail 'run directly, help does not print the help'
rc=0; bash "$TEST_SCRIPT" no-such-mode > /dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "run directly, a wrong mode exits with $rc"
printf 'PASS: sourced, the script defines everything and runs nothing; run directly, it is the tool.\n'

# One-click setup with the real traps: STEPS... are run through setup_run, each
# "name:function". Prints what happened; the status is that of the run. Never
# called inside a condition (if, ||, &&): Bash would switch errexit off for
# everything in it, the subshell included.
run_setup() {
  local out="$1"
  shift
  (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$TEST_SCRIPT"
    record() { printf '%s\n' "$*" >> "$out"; }
    stage_run() { shift; "$@"; }
    state_write() { :; }
    state_event() { record "event $*"; }
    module_result() { record "result $1 $2"; }
    setup_skipped() { return 1; }
    restore_capture_failure() { :; }
    record_failure() { record "run failed (line $1, exit $2)"; }
    record_exit() { record "run exit $1"; }
    warn() { WARNINGS=$((WARNINGS + 1)); }
    boom() { record "$1 starts"; false; record "$1 went on after the error"; }
    fine() { record "$1 done"; }
    interrupted() { record "$1 starts"; exit 130; }
    WARNINGS=0 LOCK_OWNER_FILE="$TEST_ROOT/lock-owner"
    runtime_traps
    for step in "$@"; do setup_run "${step%%:*}" "${step#*:}" "${step%%:*}"; done
    record 'the setup reached its end'
  ) > "$out.screen" 2>&1
}

# A small step failing unexpectedly ends only itself: the steps after it run,
# the SSH hardening, the firewall and Fail2ban at the end included.
OUT="$TEST_ROOT/isolated"; : > "$OUT"
set +e; run_setup "$OUT" trim:boom bbr:fine ssh:fine firewall:fine; rc=$?; set -e
[[ "$rc" == 0 ]] || fail "an error in a small step ended the whole setup (exit $rc): $(tr '\n' '|' < "$OUT") / $(tr '\n' '|' < "$OUT.screen")"
[[ "$(tr '\n' '|' < "$OUT")" == 'trim starts|event trim failed 1|result trim failed|bbr done|ssh done|firewall done|the setup reached its end|run exit 0|' ]] ||
  fail "an error in a small step: $(tr '\n' '|' < "$OUT")"
grep -Fq '这一步先跳过，后面的步骤继续' "$OUT.screen" || fail 'the failed step does not say that the setup goes on'
if grep -Fq '不要盲目重跑' "$OUT.screen"; then fail 'the failed step also printed the message of a run that ended'; fi
printf 'PASS: with the real traps, an unexpected error in a small step ends only that step.\n'

# The trap is back afterwards: an error in a step the rest depends on still
# ends the run and is recorded as its failure.
OUT="$TEST_ROOT/dependent"; : > "$OUT"
set +e; run_setup "$OUT" trim:boom ssh:boom firewall:fine; rc=$?; set -e
[[ "$rc" == 1 ]] || fail "an error in the SSH step after a failed small step ended the run with $rc"
[[ "$(tr '\n' '|' < "$OUT")" == 'trim starts|event trim failed 1|result trim failed|ssh starts|run failed (line '*', exit 1)|run exit 1|' ]] ||
  fail "an error in a step the rest depends on: $(tr '\n' '|' < "$OUT")"
grep -Fq '不要盲目重跑' "$OUT.screen" || fail 'the run that ended does not say so'
printf 'PASS: after it the error trap is back: a step the rest depends on still ends the run.\n'

# Ctrl+C (or a lost connection) inside such a step ends the whole run, as
# everywhere else, and is not taken for an error of the step.
OUT="$TEST_ROOT/interrupt"; : > "$OUT"
set +e; run_setup "$OUT" journal:interrupted bbr:fine; rc=$?; set -e
[[ "$rc" == 130 ]] || fail "Ctrl+C inside a small step ended the run with $rc"
[[ "$(tr '\n' '|' < "$OUT")" == 'journal starts|run exit 130|' ]] || fail "Ctrl+C inside a small step: $(tr '\n' '|' < "$OUT")"
if grep -Fq '出错' "$OUT.screen"; then fail "Ctrl+C inside a small step is shown as an error: $(cat "$OUT.screen")"; fi
printf 'PASS: Ctrl+C inside a small step ends the run and is no error of the step.\n'
