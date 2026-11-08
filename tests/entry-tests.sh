#!/usr/bin/env bash
# Exercises the actual main function with every system-changing stage mocked.
# No optimizer discovery, traps, setup, or global initialization is sourced.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions main setup_run setup_step_independent stage_run_isolated
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
record() { printf '%s\n' "$*" >> "$CASE_DIR/calls"; }
say() { :; }
ok() { :; }
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
plan() { record 'read plan'; }
verify_main() { record 'read verify'; VERIFY_EXIT="$CHECK_RESULT"; }
port_main() { record 'port manager'; }
validate_vm() { record 'read validate_vm'; }
preflight_gate() { record 'read preflight_gate'; if ((GATE_FAIL)); then die 'mock preflight failure'; fi; }
confirm() { record "confirm ${2:-}"; ((CONFIRM_APPLY)); }
# The start-of-changes question is the only y/N asked by main itself.
confirm_yes() { record 'confirm APPLY'; ((CONFIRM_APPLY)); }
start_logging() { record 'write start_logging'; }
restore_prepare() { record 'write restore_prepare'; }
tool_prepare_data() { record 'write tool_prepare_data'; }
prepare_run_state() { record 'write prepare_run_state'; }
state_event() { record "event $*"; }
stage_run() {
  record "stage $*"
  if [[ "$1" == backup && "$2" == backup_configs ]] && ((BACKUP_FAIL)); then
    return 73
  fi
  if [[ "$1" == firewall ]]; then FIREWALL_READY="$FIREWALL_CONFIRMED"; fi
}
finish_run_state() { record 'write finish_run_state'; }
offer_reboot() { record 'offer reboot'; }
session_resilience_check() { record 'read session'; ((SESSION_OK)); }
attention_banner() { record 'banner'; }

run_case() {
  local name="$1" mode="$2" confirmed="$3" gate_fail="$4" backup_fail="$5"
  CASE_DIR="$TEST_ROOT/$name"
  mkdir -p -- "$CASE_DIR"
  : > "$CASE_DIR/calls"
  MODE="$mode"
  CONFIRM_APPLY="$confirmed"
  GATE_FAIL="$gate_fail"
  BACKUP_FAIL="$backup_fail"
  FIREWALL_READY=0
  FIREWALL_CONFIRMED=0
  SESSION_OK="${SESSION_OK:-1}"
  WARNINGS=0
  SCRIPT_VERSION=2.7.1
  RESTORE_EXIT_CODE=0
  VERIFY_EXIT=0
  CHECK_RESULT="${CHECK_RESULT:-0}"
  RUN_BACKUP_DIR="$CASE_DIR/backup"
  RUN_STATE_DIR="$CASE_DIR/state"
  # The outer call is deliberately not an if/!/&&/|| condition, as Bash would
  # disable errexit throughout the tested main function in those contexts.
  set +e
  ( set -Eeuo pipefail; main ) > "$CASE_DIR/output" 2>&1
  CASE_STATUS=$?
  set -e
}
assert_no_writes() {
  if grep -Eq '^(write|stage) ' "$CASE_DIR/calls"; then
    fail "$1 caused a mutation stage"
  fi
}

run_case plan_readonly plan 1 0 0
[[ "$CASE_STATUS" == 0 ]] || fail 'plan mode failed'
grep -Fxq 'read plan' "$CASE_DIR/calls" || fail 'plan mode did not report'
assert_no_writes 'plan mode'

run_case check_readonly check 1 0 0
[[ "$CASE_STATUS" == 0 ]] || fail 'check mode failed'
grep -Fxq 'read verify' "$CASE_DIR/calls" || fail 'check mode did not run the acceptance check'
assert_no_writes 'check mode'
# Something did not take effect: scripts and the menu see exit code 3.
CHECK_RESULT=3 run_case check_failed_items check 1 0 0
[[ "$CASE_STATUS" == 3 ]] || fail "check with failed items exited with $CASE_STATUS, not 3"

run_case port_dispatch port 1 0 0
[[ "$CASE_STATUS" == 0 ]] || fail 'port mode failed'
grep -Fxq 'port manager' "$CASE_DIR/calls" || fail 'port mode did not reach the port manager'
if grep -Fxq 'read plan' "$CASE_DIR/calls"; then fail 'port mode ran the full setup plan'; fi
assert_no_writes 'port mode'

for mode in setup firewall ssh; do
  run_case "decline_$mode" "$mode" 0 0 0
  [[ "$CASE_STATUS" == 0 ]] || fail "declining $mode failed"
  grep -Fxq 'confirm APPLY' "$CASE_DIR/calls" || fail "$mode omitted the APPLY gate"
  assert_no_writes "declined $mode"

  run_case "blocked_$mode" "$mode" 1 1 0
  [[ "$CASE_STATUS" != 0 ]] || fail "$mode ignored a blocked preflight"
  assert_no_writes "blocked $mode preflight"

  run_case "backup_failed_$mode" "$mode" 1 0 1
  [[ "$CASE_STATUS" == 73 ]] || fail "$mode hid a failed configuration snapshot"
  first_stage="$(awk '/^stage / {print; exit}' "$CASE_DIR/calls")"
  [[ "$first_stage" == 'stage backup backup_configs' ]] || fail "$mode changed the system before its configuration snapshot"
  [[ "$(grep -c '^stage ' "$CASE_DIR/calls")" == 1 ]] || fail "$mode continued after its snapshot failed"
  if grep -Fxq 'write finish_run_state' "$CASE_DIR/calls"; then fail "$mode marked a failed run complete"; fi

  run_case "firewall_not_ready_$mode" "$mode" 1 0 0
  [[ "$CASE_STATUS" == 0 ]] || fail "$mode mock run failed"
  # The bans are Fail2ban's own (nftables): it does not wait for the firewall.
  if [[ "$mode" == ssh ]]; then
    if grep -Fxq 'stage fail2ban fail2ban_stage' "$CASE_DIR/calls"; then fail 'the SSH hardening ran Fail2ban'; fi
  else
    grep -Fxq 'stage fail2ban fail2ban_stage' "$CASE_DIR/calls" || fail "$mode left Fail2ban out because the firewall was not confirmed"
  fi
  grep -Fxq 'stage verification verify_summary' "$CASE_DIR/calls" || fail "$mode skipped the final acceptance summary"
  [[ "$(tail -n 1 "$CASE_DIR/calls")" == 'offer reboot' ]] || fail "$mode did not offer the reboot last"
done

# Setup order: time before APT, every question next, ZRAM before the large
# upgrade, the attended SSH/firewall steps last.
run_case setup_order setup 1 0 0
order="$(awk '/^stage / {print $2}' "$CASE_DIR/calls" | tr '\n' ' ')"
[[ "$order" == 'backup ntp apt_index questions zram swap apt_upgrade bbr sysctl tcp journal trim updates autoreboot timezone hosts keepalive ipv4 login ssh firewall fail2ban verification ' ]] || fail "unexpected setup stage order: $order"
[[ "$(grep -n -e '^banner$' -e '^stage ssh ' "$CASE_DIR/calls" | head -n 1)" == *banner ]] || fail 'attention banner not shown before the attended steps'
grep -Fxq 'read session' "$CASE_DIR/calls" || fail 'setup did not check for tmux/screen'
# Asked before the plan: a setup handed to tmux shows its plan there, once.
[[ "$(grep -n -e '^read session$' -e '^read plan$' "$CASE_DIR/calls" | head -n 1)" == *'read session' ]] || fail 'setup showed the plan before offering tmux'

# Declining to continue outside tmux/screen changes nothing.
SESSION_OK=0 run_case setup_no_tmux setup 1 0 0
[[ "$CASE_STATUS" == 0 ]] || fail 'declining outside tmux failed'
assert_no_writes 'declined outside tmux'
if grep -Fxq 'confirm APPLY' "$CASE_DIR/calls"; then fail 'APPLY asked after declining to continue'; fi
if grep -Fxq 'read plan' "$CASE_DIR/calls"; then fail 'plan shown here although the setup went to tmux or was stopped'; fi
run_case firewall_no_session_check firewall 1 0 0
if grep -Fxq 'read session' "$CASE_DIR/calls"; then fail 'short firewall mode nagged about tmux'; fi
run_case ssh_only ssh 1 0 0
order="$(awk '/^stage / {print $2}' "$CASE_DIR/calls" | tr '\n' ' ')"
[[ "$order" == 'backup ssh verification ' ]] || fail "ssh mode ran unrelated stages: $order"

printf '%s\n' 'PASS: actual main gates read-only modes, confirmation, preflight, backup failure, stage order and reboot offer.'

# Steps one-click setup leaves out (setup_skip): recorded as skipped, not run.
(
  load_optimizer_functions setup_run setup_skipped
  T="$(mktemp -d)"; P="$T/params"; printf 'setup_skip=bbr firewall\n' > "$P"; PARAMS_FILE="$P"
  stage_run() { printf 'stage %s\n' "$*" >> "$T/trace"; }
  module_result() { printf 'result %s\n' "$*" >> "$T/trace"; }
  state_event() { printf 'event %s\n' "$*" >> "$T/trace"; }
  ok() { :; }
  item_label() { printf '%s\n' "$1"; }
  setup_run bbr bbr_stage; setup_run zram zram_stage; setup_run firewall firewall_stage
  [[ "$(cat "$T/trace")" == $'event bbr skipped 0\nresult bbr skipped setup_skip\nstage zram zram_stage\nevent firewall skipped 0\nresult firewall skipped setup_skip' ]] ||
    { printf 'FAIL: skipped steps: %s\n' "$(cat "$T/trace")" >&2; exit 1; }
  printf 'setup_skip=none\n' > "$P"; : > "$T/trace"; setup_run bbr bbr_stage
  [[ "$(cat "$T/trace")" == 'stage bbr bbr_stage' ]] || { printf 'FAIL: nothing skipped: %s\n' "$(cat "$T/trace")" >&2; exit 1; }
  rm -rf "$T"
)
printf 'PASS: one-click setup leaves out the steps the parameter names, recorded as skipped.\n'

# A small step stopping on an unexpected error does not take the rest of the
# setup with it (the SSH hardening, the firewall and Fail2ban come last); the
# steps the rest depends on still end the run. Not run inside a condition:
# Bash would switch errexit off for everything in it.
CASE_DIR="$TEST_ROOT/isolated"; mkdir -p "$CASE_DIR"; : > "$CASE_DIR/calls"
set +e
(
  set -Eeuo pipefail
  WARNINGS=3
  stage_run() { shift; "$@"; }
  state_write() { record "state $*"; }
  state_event() { record "event $*"; }
  module_result() { record "result $1 $2"; }
  item_label() { printf '%s' "$1"; }
  warn() { WARNINGS=$((WARNINGS + 1)); }
  boom() { false; record 'went on after the error'; }
  fine() { warn; record "ran with $WARNINGS warnings"; }
  setup_run trim boom
  record 'next step'
  setup_run bbr fine
  record "warnings $WARNINGS"
  setup_run ssh boom
  record 'went on after an error in the SSH step'
) > "$CASE_DIR/output" 2>&1
CASE_STATUS=$?
set -e
[[ "$(tr '\n' '|' < "$CASE_DIR/calls")" == 'state active_stage none|event trim failed 1|result trim failed|next step|ran with 5 warnings|warnings 5|' ]] ||
  fail "an error in one step: $(tr '\n' '|' < "$CASE_DIR/calls")"
[[ "$CASE_STATUS" != 0 ]] || fail 'an error in the SSH step did not end the run'
printf '%s\n' 'PASS: an unexpected error ends only that step of the setup; steps the rest depends on still end the run.'
