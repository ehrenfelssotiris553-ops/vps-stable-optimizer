#!/usr/bin/env bash
# This runner never invokes plan/setup/firewall/check on the optimizer.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEST_SCRIPT="$HERE/../vps-stable-opt.sh"
if [[ -v VPS_OPT_SCRIPT ]]; then TEST_SCRIPT="$VPS_OPT_SCRIPT"; fi
export VPS_OPT_SCRIPT="$TEST_SCRIPT"
bash -n "$TEST_SCRIPT"
bash -n "$HERE/../install.sh"
for test in "$HERE"/*.sh; do bash -n "$test"; done
printf 'PASS: Bash syntax checks.\n'
failed=()
for test in ufw-tests.sh firewall-tests.sh bbr-tests.sh f2b-tests.sh entry-tests.sh backup-tests.sh audit-tests.sh preflight-tests.sh config-write-tests.sh menu-tests.sh decision-tests.sh tool-tests.sh restore-tests.sh stage-hooks-tests.sh journal-policy-tests.sh port-tests.sh ssh-tests.sh verify-tests.sh extras-tests.sh item-tests.sh robustness-tests.sh install-tests.sh update-tests.sh bans-tests.sh ui-tests.sh params-tests.sh hostname-tests.sh allowlist-tests.sh memory-tests.sh network-tests.sh login-tests.sh consistency-tests.sh; do
  printf '\nRunning %s\n' "$test"
  # Every file runs, so one pass shows all failures; the run still fails.
  # A function a test forgot to load, or a variable it forgot to set, fails
  # the file too: inside a condition or a $(...) they only make a check
  # quietly take the other branch.
  rc=0
  bash "$HERE/$test" "$TEST_SCRIPT" > >(tee "$HERE/.run-all.out") 2>&1 || rc=$?
  wait
  if ((rc)); then failed+=("$test")
  elif grep -E ': (line [0-9]+: )?[A-Za-z_][A-Za-z0-9_-]*: command not found$' "$HERE/.run-all.out" > /dev/null; then
    printf 'FAIL: %s called a command that does not exist (see above)\n' "$test"; failed+=("$test")
  elif grep -E ': line [0-9]+: [A-Za-z_][A-Za-z0-9_]*: unbound variable$' "$HERE/.run-all.out" > /dev/null; then
    printf 'FAIL: %s used a variable it never set (see above)\n' "$test"; failed+=("$test")
  fi
done
rm -f "$HERE/.run-all.out"
if ((${#failed[@]})); then
  printf '\nFAILED: %s\n' "${failed[*]}" >&2
  exit 1
fi
printf '\nAll isolated regression tests passed. No optimizer setup was executed.\n'
