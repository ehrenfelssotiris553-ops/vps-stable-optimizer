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
# The switch for published Docker ports is off, unless a test says otherwise;
# dockerfw-tests loads the real one.
dockerfw_on() { return 1; }
# The rollback tables, which every restore_* lookup reads.
load_optimizer_functions restore_table restore_group_table 2>/dev/null || true
F2B_ACTION_FILE="${F2B_ACTION_FILE:-/nonexistent/vps-test-f2b-action}"
# The parameters: many functions read theirs. Without a PARAMS_FILE of the
# test's own, every one is the recommended value; a test that sets one, or
# mocks param_value, still does so after this.
PARAMS_FILE="${PARAMS_FILE:-/nonexistent/vps-test-params}"
load_optimizer_functions param_list param_kind param_recommended param_reason param_check param_caution param_read param_value param_mode 2>/dev/null || true
