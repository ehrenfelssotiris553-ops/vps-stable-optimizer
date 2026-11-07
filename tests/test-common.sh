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
