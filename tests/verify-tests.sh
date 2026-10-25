#!/usr/bin/env bash
# Acceptance-check tests: actual result records, classification and checks.
# Every probe of the live system is a mock; nothing is changed.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions state_path_safe state_secure_dir module_result module_expect module_result_label verify_line verify_module verify_set verify_ssh_connection_cc check_bbr check_timezone check_ssh ssh_effective_value check_sysctl verify_reboot_state upgrade_has_kernel
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { fail "$*"; }
STATE_ROOT="$TEST_ROOT/state"
mkdir -p "$STATE_ROOT"
RUN_STATE_DIR=''
BOOT_ID=11111111-2222-3333-4444-555555555555
cat() {
  if [[ "${1:-}" == /proc/sys/kernel/random/boot_id ]]; then printf '%s\n' "$BOOT_ID"; else command cat "$@"; fi
}

# Outside a recorded run nothing is written.
module_result bbr applied 'bbr + fq'
[[ ! -e "$STATE_ROOT/modules" ]] || fail 'result recorded outside a run'
RUN_STATE_DIR="$TEST_ROOT/run"; mkdir -p "$RUN_STATE_DIR"
module_result bbr applied 'bbr + fq'
module_result zram skipped ''
module_result 'bad name' applied x
module_result trim bogus x
module_result ntp applied $'two\tparts\nand\033[31mcolour'
[[ -f "$STATE_ROOT/modules/bbr" && -f "$STATE_ROOT/modules/zram" ]] || fail 'module results not stored'
[[ ! -e "$STATE_ROOT/modules/trim" ]] || fail 'unknown result value stored'
[[ "$(ls "$STATE_ROOT/modules" | tr '\n' ' ')" == 'bbr ntp zram ' ]] || fail 'invalid module name stored'
[[ "$(module_expect bbr)" == "applied"$'\t'"$BOOT_ID"$'\t''bbr + fq' ]] || fail 'expectation fields'
# An empty detail must not shift the boot id into the detail field.
IFS=$'\t' read -r result boot detail <<< "$(module_expect zram)"
[[ "$result" == skipped && "$boot" == "$BOOT_ID" && -z "$detail" ]] || fail 'empty detail shifted fields'
[[ "$(module_expect ntp | cut -f3)" == 'twopartsand[31mcolour' ]] || fail 'control characters not removed from detail'
grep -c . "$RUN_STATE_DIR/modules.tsv" | grep -qx 3 || fail 'run log of module results'
module_result bbr failed 'second run'
[[ "$(module_expect bbr | cut -f1)" == failed ]] || fail 'latest result does not win'
printf 'PASS: module results are sanitized, run-scoped and the latest result wins.\n'

VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0
check_pass() { verify_set pass "checked with <$1>"; }
check_fail() { verify_set fail 'not effective'; }
module_result bbr applied 'bbr + fq'
module_result zram skipped 'RAM >= 2GiB'
module_result journal failed 'journald restart failed'
module_result trim present 'fstrim.timer'
out="$( { verify_module bbr 'BBR' check_pass; verify_module trim 'TRIM' check_fail; verify_module zram 'ZRAM' check_pass; verify_module journal '日志' check_pass; verify_module ssh 'SSH' check_pass; } | sed $'s/\033\\[[0-9;]*m//g')"
grep -Fq '[✅ 生效]   BBR：checked with <bbr + fq>' <<< "$out" || fail 'applied module was not checked'
grep -Fq 'TRIM：not effective' <<< "$out" || fail 'present module check result missing'
grep -Fq 'ZRAM：按条件跳过（RAM >= 2GiB）' <<< "$out" || fail 'skipped module reported as checked'
grep -Fq '日志：开荒时没有成功（journald restart failed）' <<< "$out" || fail 'failed module not reported as failed'
grep -Fq 'SSH：没有开荒记录' <<< "$out" || fail 'unrecorded module not reported'
verify_module bbr 'BBR' check_pass > /dev/null
verify_module trim 'TRIM' check_fail > /dev/null
[[ "$VERIFY_PASS" == 1 && "$VERIFY_FAIL" == 1 ]] || fail 'verification counters'
printf 'PASS: only applied/present modules are checked; others are reported as intentionally unhandled.\n'

out="$(verify_reboot_state)"
grep -Fq '还没有经过重启验证' <<< "$out" || fail 'same boot not detected'
BOOT_ID=99999999-2222-3333-4444-555555555555
out="$(verify_reboot_state)"
grep -Fq '已经重启过' <<< "$out" || fail 'reboot since setup not detected'
STATE_ROOT="$TEST_ROOT/empty"
out="$(verify_reboot_state)"
grep -Fq '没有找到开荒记录' <<< "$out" || fail 'missing records not reported'
STATE_ROOT="$TEST_ROOT/state"
printf 'PASS: reboot state compares the recorded and current boot IDs.\n'

CC=bbr QD=fq SS_INFO='cubic wscale:7,7'
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_congestion_control') echo "$CC" ;;
    '-n net.core.default_qdisc') echo "$QD" ;;
    *) fail "unexpected sysctl $*" ;;
  esac
}
ss() { [[ "$*" == '-tinH state established ( sport = :22 and dport = :50000 )' ]] || fail "unexpected ss $*"; printf 'ESTAB 0 0 192.0.2.1:22 203.0.113.9:50000\n\t %s\n' "$SS_INFO"; }
SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
check_bbr ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" != *实际在用* ]] || fail 'BBR defaults without connection evidence'
SS_INFO='bbr wscale:7,7 bbr:(bw:10Mbps,mrtt:1)'
check_bbr ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *实际在用* ]] || fail 'current SSH connection evidence missed'
CC=cubic
check_bbr ''
[[ "$VERIFY_STATUS" == fail ]] || fail 'non-BBR default passed'
timedatectl() { echo Asia/Shanghai; }
check_timezone Asia/Shanghai
[[ "$VERIFY_STATUS" == pass ]] || fail 'matching timezone failed'
check_timezone Europe/Berlin
[[ "$VERIFY_STATUS" == fail ]] || fail 'different timezone passed'
printf 'PASS: BBR and timezone checks use live values and connection evidence.\n'

PW_OFF=1 ROOT_VALUE=no
ssh_password_disabled() { ((PW_OFF)); }
ssh_effective() { printf 'permitrootlogin %s\n' "$ROOT_VALUE"; }
check_ssh 'key-only user=ops root-ssh=off'
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *ops* ]] || fail 'root-off SSH check'
ROOT_VALUE=yes
check_ssh 'key-only user=ops root-ssh=off'
[[ "$VERIFY_STATUS" == fail ]] || fail 'root still allowed but reported as effective'
check_ssh 'key-only user=alice'
[[ "$VERIFY_STATUS" == pass ]] || fail 'root login was not part of this change'
PW_OFF=0
check_ssh 'key-only user=alice'
[[ "$VERIFY_STATUS" == fail ]] || fail 'password login still on but reported as effective'
SYSCTL_HARDENING_FILE="$TEST_ROOT/98-hardening.conf"
printf '# header\nkernel.kptr_restrict = 2\nnet.ipv4.tcp_syncookies = 1\n' > "$SYSCTL_HARDENING_FILE"
sysctl() { case "$2" in kernel.kptr_restrict) echo "$KPTR" ;; net.ipv4.tcp_syncookies) echo 1 ;; esac; }
KPTR=2; check_sysctl '2 keys'
[[ "$VERIFY_STATUS" == pass ]] || fail 'matching sysctl values failed'
KPTR=0; check_sysctl '2 keys'
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *kernel.kptr_restrict=0* ]] || fail 'drifted sysctl value not reported'
printf 'PASS: SSH (including root login) and sysctl checks compare live values.\n'

upgrade_has_kernel $'Inst libc6 [2.36-9] (2.36-9+deb12u9 Debian:12.9/stable [amd64])\nInst linux-image-6.1.0-29-amd64 (6.1.123-1 Debian-Security:12/stable-security [amd64])' || fail 'new kernel ABI package missed'
if upgrade_has_kernel $'Inst libc6 [2.36-9] (2.36-9+deb12u9)\nConf libc6 (2.36-9+deb12u9)'; then fail 'kernel reported without a kernel package'; fi
printf 'PASS: upgrade simulation detects new kernels.\n'
