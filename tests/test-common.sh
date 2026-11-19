#!/usr/bin/env bash
# This file is sourced only by the isolated regression tests.
# It reads function definitions from the deliverable. It never sources/runs
# the complete optimizer, so its top-level system discovery/setup cannot run.
TESTS_DIR="$HERE"
TEST_SCRIPT="$TESTS_DIR/../vps-stable-opt.sh"
if [[ -v VPS_OPT_SCRIPT ]]; then TEST_SCRIPT="$VPS_OPT_SCRIPT"; fi
[[ -r "$TEST_SCRIPT" ]] || { printf 'Unreadable optimizer: %s\n' "$TEST_SCRIPT" >&2; return 1; }
# Tests run the same over SSH and locally: the caller's session must not leak in.
unset SSH_CONNECTION SSH_CLIENT SSH_TTY SUDO_USER
# Never creates /run/sshd from a test; ssh-tests loads the real one to test it.
sshd_runtime_dir() { :; }
# Straight to the (mocked) systemctl; extras-tests loads the real one to test it.
systemctl_quiet_sysv() { systemctl "$@"; }
# One-click setup leaves nothing out (setup_skip unset); entry-tests loads the
# real one to test it.
setup_skipped() { return 1; }
# Straight to the (mocked) apt-get; extras-tests loads the real one to test it.
apt_run() { apt-get "$@"; }
# A step title through each test's own say(), as outside a setup; ui-tests
# loads the real one.
step() { say "$2"; }
# Answers come through pipes here, which the real one leaves alone anyway;
# consistency-tests checks it.
input_flush() { :; }
# True when the script under test can be sourced whole: it then defines every
# function with the real global settings and runs nothing (3.2 and later; an
# older one would start its menu). Tests of what depends on those settings (the
# error trap, errexit) source it at their top level and install the traps with
# runtime_traps; mocks are defined after that.
optimizer_sourceable() {
  grep -q '^VPS_SOURCED=0$' "$TEST_SCRIPT"
}
load_optimizer_functions() {
  local name definition
  for name in "$@"; do
    definition="$(awk -v name="$name" '
      $0 == name "() {" {copy=1; found=1}
      copy {print}
      copy && $0 == "}" {closed=1; exit}
      END {if (!found || !closed) exit 1}
    ' "$TEST_SCRIPT")" || {
      printf 'Cannot extract function %s from %s\n' "$name" "$TEST_SCRIPT" >&2
      return 1
    }
    # The extracted text contains only one definition in the repository format.
    eval "$definition"
  done
}
# The TG notification names, which the parameter checks (loaded by many tests)
# use; quiet when the script under test has none (an older one). Likewise the other lists the parameter checks use, and the size text.
load_optimizer_functions notify_event_names setup_skippable menu_alert_names menu_alert_on sysctl_hardening_all param_check_words mib_text names_only 2>/dev/null || true
# Which Fail2ban ban action is in place (the check, the plan, the firewall
# pause and the resources read it); none unless a test writes the file.
load_optimizer_functions f2b_action_text f2b_action_legacy_text f2b_action_kind 2>/dev/null || true
# What settles a change made under a guard, and the unit that undoes one after
# a reboot: the real functions. The unit's file is nowhere unless a test names
# a place of its own (firewall-tests and ssh-tests look at what is written).
GUARD_BOOT_SERVICE_FILE="${GUARD_BOOT_SERVICE_FILE:-/nonexistent/vps-test-guard-boot.service}"
load_optimizer_functions guard_script_end guard_boot_replay_text guard_boot_service_text guard_boot_on guard_boot_off guard_cancel guard_replayed_hint 2>/dev/null || true
# (Apart: an older script without them still gets the ones above.)
load_optimizer_functions guard_write guard_owed_any guard_owed_run 2>/dev/null || true
# What main says first in a run someone watches (nothing here: no terminal).
load_optimizer_functions startup_notes ui_on_terminal 2>/dev/null || true
# The single items: how a state is printed and marked, the names and groups.
# A `vps item` run changes nothing in these tests until one says so
# (robustness-tests loads the real beginning of such a run), and no item is
# this tool's doing unless a test has its own rollback record (item-tests).
load_optimizer_functions item_put item_state item_mark item_brief item_about item_groups item_group_keys ui_columns 2>/dev/null || true
# The table the names, groups and texts of the items come from (since 3.2.0).
load_optimizer_functions item_info_load 2>/dev/null || true
item_session_begin() { :; }
item_owner() { echo system; }
# What the page offers to undo follows the owner here (restore-tests and
# item-tests look at the real one).
item_undoable() { [[ "$(item_owner "$1")" == tool ]]; }
# The text of one item as the lists show it (a helper of the tests).
item_status() {
  local probe
  probe="$(item_probe "$1")"
  printf '%s\n' "${probe#*$'\t'}"
}
# One look in the (mocked) journal; ssh-tests loads the real one to test it.
journal_settle() { "$@"; }
# The switch for published Docker ports is off, unless a test says otherwise;
# dockerfw-tests loads the real one.
dockerfw_on() { return 1; }
# A zram module to offer only where a test says so; extras-tests loads the real one.
zram_module_offerable() { return 1; }
# The rollback tables, which every restore_* lookup reads.
load_optimizer_functions restore_table restore_group_table 2>/dev/null || true
# What a group has on record besides its resources (restore_group_pending and
# item_owner read it; since 3.2.0, apart for an older script).
load_optimizer_functions restore_group_extra 2>/dev/null || true
# Files shared with their owner (only the tool's part goes), and the copy kept
# of a file that changed since the tool wrote it; shared-tests is about them.
load_optimizer_functions restore_shared restore_shared_present restore_shared_apply restore_keep_replaced gai_note_line gai_prefer_line 2>/dev/null || true
F2B_ACTION_FILE="${F2B_ACTION_FILE:-/nonexistent/vps-test-f2b-action}"
# The parameters: many functions read theirs. Without a PARAMS_FILE of the
# test's own, every one is the recommended value; a test that sets one, or
# mocks param_value, still does so after this.
PARAMS_FILE="${PARAMS_FILE:-/nonexistent/vps-test-params}"
load_optimizer_functions param_list param_kind param_recommended param_reason param_check param_caution param_read param_value param_mode 2>/dev/null || true
