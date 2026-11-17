#!/usr/bin/env bash
# A change made under a guard (firewall, SSH hardening, SSH port, Docker ports)
# is undone by a transient timer unless it is confirmed. A reboot takes that
# timer away: up to 3.1.4 the unconfirmed change then stayed for good. Now the
# file the timer would run is also run at the next boot, by a unit that is
# there only while something waits. A change this run settles itself loses its
# file first, so nothing undoes a confirmed change later.
# The files are really run here (with /bin/sh, as systemd runs them); only
# systemctl and systemd-run are stand-ins. The whole script is sourced.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
optimizer_sourceable || fail "this version of the script cannot be sourced whole: $TEST_SCRIPT"
# shellcheck source=/dev/null
source "$TEST_SCRIPT"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
say() { :; }
ok() { :; }
warn() { printf 'WARN %s\n' "$*" >> "$TRACE"; }
PARAMS_FILE="$TEST_ROOT/no-params"

# systemctl for the files run with /bin/sh and for the functions alike: every
# call is noted; a timer is alive while its mark is there.
BIN="$TEST_ROOT/bin"; mkdir -p "$BIN"
MARKS="$TEST_ROOT/marks"
{
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"systemctl \$*\" >> \"\$TRACE\""
  printf '%s\n' 'case "$1" in' '  is-active) for last in "$@"; do :; done; [ -e "$MARKS/$last" ] || exit 3 ;;' \
    '  stop) shift; for unit in "$@"; do rm -f "$MARKS/$unit"; done ;;' '  show) echo 0 ;;' 'esac' 'exit 0'
} > "$BIN/systemctl"
chmod +x "$BIN/systemctl"
PATH="$BIN:$PATH"
export TRACE MARKS
systemctl() {
  if [[ "$1" == stop && "$2" == *.timer && -e "$STATE_ROOT/guard/${2%.timer}.sh" ]]; then printf 'the file was still there when %s was stopped\n' "$2" >> "$TRACE"; fi
  "$BIN/systemctl" "$@"
}
SYSTEMD_RUN_RC=0
systemd-run() {
  local arg
  printf 'systemd-run %s\n' "$*" >> "$TRACE"
  ((SYSTEMD_RUN_RC == 0)) || return "$SYSTEMD_RUN_RC"
  for arg in "$@"; do
    if [[ "$arg" == --unit=* ]]; then : > "$MARKS/${arg#--unit=}.timer"; fi
  done
}
fresh() {
  CASE="$TEST_ROOT/$1"
  STATE_ROOT="$CASE/state" GUARD_BOOT_SERVICE_FILE="$CASE/etc/vps-stable-guard-boot.service" TRACE="$CASE/trace"
  rm -rf -- "$MARKS"
  mkdir -p "$STATE_ROOT" "$CASE/etc" "$MARKS"
  : > "$TRACE"
  SYSTEMD_RUN_RC=0
}
# What a reboot does: every transient timer is gone, and the boot unit (when
# it is there and has something to run) runs its script.
reboot_now() {
  rm -f -- "$MARKS"/*.timer
  [[ -f "$GUARD_BOOT_SERVICE_FILE" ]] || return 0
  compgen -G "$STATE_ROOT/guard/*.sh" > /dev/null || return 0
  /bin/sh "$(sed -n 's#^ExecStart=/bin/sh ##p' "$GUARD_BOOT_SERVICE_FILE")"
}
boot_unit_there() { [[ -f "$GUARD_BOOT_SERVICE_FILE" && -f "$STATE_ROOT/guard/replay" ]]; }
boot_unit_gone() { [[ ! -e "$GUARD_BOOT_SERVICE_FILE" && ! -e "$STATE_ROOT/guard/replay" ]]; }
A=vps-stable-ufw-rollback-111-1 B=vps-stable-ssh-revert-222-2

# Armed: the way back is a file, the boot unit is in place and enabled before
# the timer starts, and it runs that file's directory.
fresh armed
guard_arm "$A" "touch '$CASE/undone-a'" || fail 'the guard was not armed'
[[ "$(head -n 1 "$STATE_ROOT/guard/$A.sh")" == "touch '$CASE/undone-a'" ]] || fail "the file does not start with the way back: $(cat "$STATE_ROOT/guard/$A.sh")"
boot_unit_there || fail 'no boot unit while a change waits for its confirmation'
grep -Fxq "ExecStart=/bin/sh $STATE_ROOT/guard/replay" "$GUARD_BOOT_SERVICE_FILE" || fail "the boot unit does not run the script: $(cat "$GUARD_BOOT_SERVICE_FILE")"
grep -Fxq "ConditionPathExistsGlob=$STATE_ROOT/guard/*.sh" "$GUARD_BOOT_SERVICE_FILE" || fail 'the boot unit would run with nothing waiting'
grep -Fxq 'WantedBy=multi-user.target' "$GUARD_BOOT_SERVICE_FILE" || fail 'the boot unit is not started at boot'
[[ "$(grep -n '^systemctl enable vps-stable-guard-boot.service$' "$TRACE" | cut -d: -f1)" -lt "$(grep -n '^systemd-run ' "$TRACE" | cut -d: -f1)" ]] ||
  fail "the boot unit was not enabled before the timer started: $(tr '\n' '|' < "$TRACE")"
# A reboot before the confirmation: the change is undone at boot, once, and
# nothing of the guard is left on the system.
reboot_now
[[ -e "$CASE/undone-a" ]] || fail 'a reboot before the confirmation left the change in place: nothing undid it at boot'
[[ ! -e "$STATE_ROOT/guard/$A.sh" ]] || fail 'the file stayed after it ran at boot: it would run again at the next one'
boot_unit_gone || fail 'the boot unit stayed after the last change was undone'
grep -Fxq 'systemctl disable vps-stable-guard-boot.service' "$TRACE" || fail 'the boot unit was not disabled'
rm -f -- "$CASE/undone-a"
reboot_now
[[ ! -e "$CASE/undone-a" ]] || fail 'the change was undone again at a later boot'
# The menu says so, once (for root, who reads it there).
[[ "$(guard_replayed_hint)" == *'开机时已经自动撤销：防火墙。'* ]] || fail "the menu does not tell what was undone at boot: $(guard_replayed_hint)"
if ((EUID == 0)); then [[ -z "$(guard_replayed_hint)" ]] || fail 'the menu tells it again'; fi
printf 'PASS: a reboot before the confirmation undoes the change at boot, once, and leaves nothing behind.\n'

# Confirmed: the file goes before the timer is stopped, the boot unit goes
# with it, and no reboot undoes the change afterwards.
fresh confirmed
guard_arm "$B" "touch '$CASE/undone-b'" || fail 'the guard was not armed'
guard_confirm "$B" "$((SECONDS + 60))" true < /dev/null > /dev/null 2>&1 || fail 'the confirmation was not accepted'
[[ ! -e "$STATE_ROOT/guard/$B.sh" ]] || fail 'the way back of a confirmed change stayed'
if grep -q 'the file was still there' "$TRACE"; then fail "the timer was stopped before the file went (a run cut off in between would leave it for the next boot): $(tr '\n' '|' < "$TRACE")"; fi
boot_unit_gone || fail 'the boot unit stayed after the confirmation'
reboot_now
[[ ! -e "$CASE/undone-b" ]] || fail 'a confirmed change was undone at the next boot'
printf 'PASS: a confirmed change loses its way back first; no reboot undoes it.\n'

# Put back by the run itself (not confirmed, or it could not be applied).
fresh cancelled
guard_arm "$A" "touch '$CASE/undone-a'" || fail 'the guard was not armed'
guard_cancel "$A"
[[ ! -e "$STATE_ROOT/guard/$A.sh" && ! -e "$MARKS/$A.timer" ]] || fail 'the file or the timer stayed after the run put the change back'
if grep -q 'the file was still there' "$TRACE"; then fail 'the timer was stopped before the file went'; fi
boot_unit_gone || fail 'the boot unit stayed after the run put the change back'
reboot_now
[[ ! -e "$CASE/undone-a" ]] || fail 'the way back ran at boot although the run had put the change back itself'
printf 'PASS: a change the run put back itself is not undone a second time.\n'

# The timer fires with nobody there: its file undoes the change, removes
# itself and, as the last one, the boot unit.
fresh timer
guard_arm "$A" "touch '$CASE/undone-a'" || fail 'the guard was not armed'
/bin/sh "$STATE_ROOT/guard/$A.sh"
[[ -e "$CASE/undone-a" && ! -e "$STATE_ROOT/guard/$A.sh" ]] || fail 'the timer did not undo the change, or its file stayed'
boot_unit_gone || fail 'the boot unit stayed after the timer undid the last change'
printf 'PASS: the timer undoes the change and takes the boot unit away with the last file.\n'

# Two waiting (the second armed after a reboot test would be refused by the
# stages; the files themselves must still cope): one settled leaves the boot
# unit for the other; at boot only what has no live timer is run.
fresh two
guard_arm "$A" "touch '$CASE/undone-a'" || fail 'the first guard was not armed'
guard_arm "$B" "touch '$CASE/undone-b'" || fail 'the second guard was not armed'
guard_cancel "$A"
boot_unit_there || fail 'the boot unit went although another change still waits'
: > "$TRACE"
/bin/sh "$STATE_ROOT/guard/replay"
[[ ! -e "$CASE/undone-b" && -e "$STATE_ROOT/guard/$B.sh" ]] || fail 'the boot script ran a file whose timer is still alive'
reboot_now
[[ -e "$CASE/undone-b" && ! -e "$CASE/undone-a" ]] || fail "after a reboot with one change waiting: $(ls "$CASE" | tr '\n' ' ')"
boot_unit_gone || fail 'the boot unit stayed after the reboot'
printf 'PASS: with two changes waiting each is settled on its own.\n'

# The timer cannot be started: nothing is left that a reboot would run.
fresh no-timer
SYSTEMD_RUN_RC=1
if guard_arm "$A" "touch '$CASE/undone-a'"; then fail 'a guard without a timer counted as armed'; fi
[[ ! -e "$STATE_ROOT/guard/$A.sh" ]] || fail 'the file stayed although the timer never started'
boot_unit_gone || fail 'the boot unit stayed although the timer never started'
# The boot unit cannot be written: the timer still protects, and the user is told.
fresh no-boot-unit
GUARD_BOOT_SERVICE_FILE="$CASE/no-such-directory/vps-stable-guard-boot.service"
guard_arm "$A" "touch '$CASE/undone-a'" 2> /dev/null || fail 'the guard was not armed although its timer started'
grep -q '^WARN .*不要重启' "$TRACE" || fail "the user is not told to keep from rebooting: $(tr '\n' '|' < "$TRACE")"
printf 'PASS: a guard that cannot be armed leaves nothing; one without the boot unit says so.\n'
