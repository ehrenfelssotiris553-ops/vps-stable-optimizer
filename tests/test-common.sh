#!/usr/bin/env bash
# This file is sourced only by the isolated regression tests.
# It reads function definitions from the deliverable. It never sources/runs
# the complete optimizer, so its top-level system discovery/setup cannot run.
TESTS_DIR="$HERE"
TEST_SCRIPT="$TESTS_DIR/../vps-stable-opt-v2.6.0.sh"
if [[ -v VPS_OPT_SCRIPT ]]; then TEST_SCRIPT="$VPS_OPT_SCRIPT"; fi
[[ -r "$TEST_SCRIPT" ]] || { printf 'Unreadable optimizer: %s\n' "$TEST_SCRIPT" >&2; return 1; }
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
