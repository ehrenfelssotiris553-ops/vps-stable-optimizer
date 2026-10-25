#!/usr/bin/env bash
# This runner never invokes plan/setup/firewall/check on the optimizer.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEST_SCRIPT="$HERE/../vps-stable-opt-v2.6.0.sh"
if [[ -v VPS_OPT_SCRIPT ]]; then TEST_SCRIPT="$VPS_OPT_SCRIPT"; fi
export VPS_OPT_SCRIPT="$TEST_SCRIPT"
bash -n "$TEST_SCRIPT"
bash -n "$HERE/../install.sh"
for test in "$HERE"/*.sh; do bash -n "$test"; done
printf 'PASS: Bash syntax checks.\n'
for test in ufw-tests.sh firewall-tests.sh bbr-tests.sh f2b-tests.sh entry-tests.sh backup-tests.sh audit-tests.sh preflight-tests.sh config-write-tests.sh menu-tests.sh decision-tests.sh tool-tests.sh restore-tests.sh stage-hooks-tests.sh journal-policy-tests.sh port-tests.sh ssh-tests.sh verify-tests.sh extras-tests.sh item-tests.sh; do
  printf '\nRunning %s\n' "$test"
  bash "$HERE/$test" "$TEST_SCRIPT"
done
printf '\nAll isolated regression tests passed. No optimizer setup was executed.\n'
