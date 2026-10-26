#!/usr/bin/env bash
# Acceptance-check tests: actual result records, classification and checks.
# Every probe of the live system is a mock; nothing is changed.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions state_path_safe state_secure_dir module_result module_expect module_result_label verify_line verify_module verify_set verify_ssh_connection_cc check_bbr check_timezone check_ssh ssh_effective_value check_sysctl sysctl_file_mismatch verify_reboot_state upgrade_has_kernel boot_kernels verify_kernel \
  trim_support check_trim check_fail2ban check_firewall check_journal audit_ufw_ipv6 ufw_ssh_access port_item_covers verify_main verify_health
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
# Rollback runs outside a setup run, but its "reverted" record is still kept.
saved_run="$RUN_STATE_DIR"; RUN_STATE_DIR=''
module_result firewall reverted '由撤销功能恢复'
module_result zram applied 'outside a run'
RUN_STATE_DIR="$saved_run"
[[ "$(module_expect firewall | cut -f1)" == reverted ]] || fail 'rollback outside a run not recorded'
[[ "$(module_expect zram | cut -f1)" == skipped ]] || fail 'a non-rollback result was recorded outside a run'
printf 'PASS: module results are sanitized, run-scoped and the latest result wins.\n'

VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0
check_pass() { verify_set pass "checked with <$1>"; }
check_fail() { verify_set fail 'not effective'; }
module_result bbr applied 'bbr + fq'
module_result zram skipped 'RAM >= 2GiB'
module_result journal failed 'journald restart failed'
module_result trim present 'fstrim.timer'
out="$( { verify_module bbr 'BBR' check_pass; verify_module trim 'TRIM' check_fail; verify_module zram 'ZRAM' check_pass; verify_module journal '日志' check_pass; verify_module ssh 'SSH' check_pass; verify_module firewall '防火墙' check_fail; } | sed $'s/\033\\[[0-9;]*m//g')"
grep -Fq '[➖ 未处理] 防火墙：已撤销，恢复成本工具运行前的样子（由撤销功能恢复）' <<< "$out" || fail 'undone module reported as broken'
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
# A key the kernel (or container) does not offer cannot be confirmed: not a pass.
KPTR=''; check_sysctl '2 keys'
[[ "$VERIFY_STATUS" == unknown && "$VERIFY_TEXT" == *kernel.kptr_restrict* ]] || fail 'unreadable sysctl key passed'
# Multi-value keys: tabs from the kernel against spaces in the file still match.
printf 'net.ipv4.ip_local_port_range = 10000 65000\n' > "$SYSCTL_HARDENING_FILE"
sysctl() { printf '10000\t65000\n'; }
check_sysctl '1 key'
[[ "$VERIFY_STATUS" == pass ]] || fail 'multi-value sysctl key reported as drifted'
# A glob key is checked on every interface it covers (found on a real VPS:
# eth0 kept accepting IPv6 redirects while all/default said 0).
P="$TEST_ROOT/proc"
for d in all default eth0 lo; do mkdir -p "$P/net/ipv6/conf/$d"; printf '0\n' > "$P/net/ipv6/conf/$d/accept_redirects"; done
printf 'net.ipv6.conf.*.accept_redirects = 0\n' > "$TEST_ROOT/glob.conf"
[[ -z "$(sysctl_file_mismatch "$TEST_ROOT/glob.conf" "$P")" ]] || fail 'matching interfaces reported as drifted'
printf '1\n' > "$P/net/ipv6/conf/eth0/accept_redirects"
[[ "$(sysctl_file_mismatch "$TEST_ROOT/glob.conf" "$P")" == 'bad net.ipv6.conf.eth0.accept_redirects=1' ]] || fail 'interface still accepting redirects not reported'
# Keys with a dash (vm.page-cluster) are compared like any other.
printf 'vm.page-cluster = 0\n' > "$TEST_ROOT/zram.conf"
sysctl() { [[ "$2" == vm.page-cluster ]] && echo 3; }
[[ "$(sysctl_file_mismatch "$TEST_ROOT/zram.conf")" == 'bad vm.page-cluster=3' ]] || fail 'dashed sysctl key not compared'
printf 'PASS: SSH (including root login) and sysctl checks compare live values.\n'

# A kernel installed after this boot waits for the reboot: not a failure
# (found on a real VPS: the check right after setup showed it as broken).
(
  VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_REBOOT=0
  uname() { echo 6.1.0-28-amd64; }
  mkdir -p "$TEST_ROOT/boot"; : > "$TEST_ROOT/boot/vmlinuz-6.1.0-28-amd64"; : > "$TEST_ROOT/boot/vmlinuz-6.1.0-29-amd64"
  out="$(verify_kernel "$TEST_ROOT/boot" "$TEST_ROOT/no-flag"; echo "fail=$VERIFY_FAIL reboot=$VERIFY_REBOOT")"
  [[ "$out" == *待重启* && "$out" == *'fail=0 reboot=1'* ]] || fail "kernel installed in this boot reported as: $out"
  # Installed before this boot and still not running: a real problem.
  stat() { echo 1; }
  out="$(verify_kernel "$TEST_ROOT/boot" "$TEST_ROOT/no-flag"; echo "fail=$VERIFY_FAIL")"
  [[ "$out" == *'fail=1'* ]] || fail "newer kernel ignored at boot not reported: $out"
  unset -f stat
  # Running the newest kernel with another update waiting for a reboot.
  rm "$TEST_ROOT/boot/vmlinuz-6.1.0-29-amd64"; : > "$TEST_ROOT/flag"
  out="$(verify_kernel "$TEST_ROOT/boot" "$TEST_ROOT/flag"; echo "fail=$VERIFY_FAIL reboot=$VERIFY_REBOOT")"
  [[ "$out" == *'fail=0 reboot=1'* ]] || fail "pending reboot flag reported as: $out"
)
printf 'PASS: a kernel or update waiting for the reboot is shown as pending, not as broken.\n'

upgrade_has_kernel $'Inst libc6 [2.36-9] (2.36-9+deb12u9 Debian:12.9/stable [amd64])\nInst linux-image-6.1.0-29-amd64 (6.1.123-1 Debian-Security:12/stable-security [amd64])' || fail 'new kernel ABI package missed'
if upgrade_has_kernel $'Inst libc6 [2.36-9] (2.36-9+deb12u9)\nConf libc6 (2.36-9+deb12u9)'; then fail 'kernel reported without a kernel package'; fi
printf 'PASS: upgrade simulation detects new kernels.\n'

# TRIM: a root disk without discard support is "not handled", even with the timer on.
ROOT_DEV='/dev/vda1[/@rootfs]' DISC='   0B'
lsblk() { [[ "$*" == '-dn -o DISC-MAX /dev/vda1' ]] || fail "unexpected lsblk $*"; printf '%s\n' "$DISC"; }
active() { [[ "$1" == fstrim.timer ]]; }
systemctl() {
  case "$*" in
    'is-enabled -q fstrim.timer') return 0 ;;
    'show fstrim.timer -p NextElapseUSecRealtime --value') echo 'Mon 2026-11-02 00:00:00 UTC' ;;
    'is-enabled ufw.service') printf '%s\n' "$UFW_BOOT"; [[ "$UFW_BOOT" == enabled ]] ;;
    *) fail "unexpected systemctl $*" ;;
  esac
}
check_trim ''
[[ "$VERIFY_STATUS" == na ]] || fail 'TRIM on a disk without discard support passed'
trim_support && fail 'DISC-MAX 0B reported as supported'
DISC='2G'
check_trim ''
[[ "$VERIFY_STATUS" == pass ]] || fail 'supported TRIM with an active timer failed'
printf 'PASS: TRIM checks the disk discard support before the timer.\n'

# Fail2ban bans are UFW rules: no running firewall, no protection.
UFW_ON=0
ufw_active() { ((UFW_ON)); }
fail2ban-client() {
  case "$*" in
    'status sshd') printf 'Status for the jail: sshd\n|- Filter\n|  |- Total failed:\t3\n|- Actions\n   |- Total banned:\t1\n' ;;
    'get sshd actions') echo vps-stable-ufw-sshd ;;
  esac
}
active() { [[ "$1" == fail2ban ]]; }
check_fail2ban ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *防火墙没有运行* ]] || fail 'Fail2ban passed without a running firewall'
UFW_ON=1
check_fail2ban ''
[[ "$VERIFY_STATUS" == pass ]] || fail 'Fail2ban with a running firewall failed'

# UFW running now but not enabled at boot: after a reboot it would be gone.
ufw() {
  case "$*" in
    status) printf 'Status: active\n\nTo Action From\n22/tcp LIMIT Anywhere\n' ;;
    'status verbose') printf 'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n' ;;
  esac
}
ssh_candidates() { echo 22; }
UFW_BOOT=disabled
check_firewall ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *ufw.service* ]] || fail 'firewall not loaded at boot passed'
UFW_BOOT=enabled
check_firewall ''
[[ "$VERIFY_STATUS" == pass ]] || fail 'firewall enabled at boot failed'
# SSH allowed through the OpenSSH application profile (port 22/tcp).
ufw() {
  case "$*" in
    status) printf 'Status: active\n\nTo Action From\nOpenSSH LIMIT Anywhere\nOpenSSH (v6) LIMIT Anywhere (v6)\n' ;;
    'status verbose') printf 'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n' ;;
  esac
}
check_firewall ''
[[ "$VERIFY_STATUS" == pass ]] || fail "SSH allowed by the OpenSSH profile reported missing: $VERIFY_TEXT"
ssh_candidates() { echo 2222; }
check_firewall ''
[[ "$VERIFY_STATUS" == fail ]] || fail 'the OpenSSH profile (port 22) counted for SSH on port 2222'
ssh_candidates() { echo 22; }
UFW_STATUS=''
ufw() {
  case "$*" in
    status) printf 'Status: active\n\nTo Action From\n-- ------ ----\n%s\n' "$UFW_STATUS" ;;
    'status verbose') printf 'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n' ;;
  esac
}
# Rule order: a deny for everyone before an allow for one source blocks SSH.
UFW_STATUS=$'22/tcp DENY Anywhere\n22/tcp ALLOW 198.18.2.2\n22/tcp (v6) DENY Anywhere (v6)'
check_firewall ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *挡住* ]] || fail "SSH blocked by an earlier deny passed: $VERIFY_TEXT"
# An allow for the admin's address first: reachable from there only.
UFW_STATUS=$'22/tcp ALLOW 198.51.100.7\n22/tcp DENY Anywhere'
check_firewall ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *指定来源* ]] || fail "source-restricted SSH not explained: $VERIFY_TEXT"
# Fail2ban bans before the general rule do not matter; outgoing rules neither.
UFW_STATUS=$'22/tcp DENY 176.53.159.198\n22/tcp DENY OUT Anywhere\n22/tcp LIMIT Anywhere\n22/tcp (v6) LIMIT Anywhere (v6)'
check_firewall ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" != *指定来源* ]] || fail "bans before the SSH rule changed the result: $VERIFY_TEXT"
# A rule comment ("ufw ... comment 'SSH'") is not part of the source column.
UFW_STATUS=$'22/tcp                     LIMIT       Anywhere                   # SSH'
check_firewall ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" != *指定来源* ]] || fail "commented allow for everyone misread: $VERIFY_TEXT"
UFW_STATUS=$'22/tcp                     DENY        Anywhere                   # maintenance\n22/tcp                     ALLOW       Anywhere'
check_firewall ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *挡住* ]] || fail "commented deny for everyone ignored: $VERIFY_TEXT"
UFW_STATUS=$'22/tcp LIMIT Anywhere'
# Only a persistent "enabled" loads UFW at boot.
UFW_BOOT=enabled-runtime
check_firewall ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *enabled-runtime* ]] || fail 'runtime-only enablement passed'
UFW_BOOT=static
check_firewall ''
[[ "$VERIFY_STATUS" == unknown ]] || fail 'a static ufw.service was taken as enabled at boot'
UFW_BOOT=enabled
printf 'PASS: Fail2ban needs a running UFW; the firewall must also load at boot.\n'

# The usage sentence ends with ".", which must not be taken for the size.
systemd-analyze() { printf '[Journal]\nSystemMaxUse=100M\n'; }
journalctl() { echo 'Archived and active journals take up 24.0M in the file system.'; }
check_journal ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *'当前占用 24.0M' ]] || fail "journal usage misread: $VERIFY_TEXT"
printf 'PASS: journal check reads the limit and the current usage.\n'

# The exit code also covers the optional Fail2ban live test (run interactively).
(
  eval "$(declare -f verify_main | sed -e 's/((EUID != 0))/false/' -e 's/\[\[ -t 0 \]\]/true/')"
  LOG_DIR="$TEST_ROOT/no-log-dir" STATE_ROOT="$TEST_ROOT/no-state-dir" F2B_FILE="$TEST_ROOT/jail.local"
  printf 'action = vps-stable-ufw-sshd\n' > "$F2B_FILE"
  VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_EXIT=0
  verify_summary() { echo 'basic checks all pass'; }
  confirm_yes() { [[ "$1" == *实弹测试* ]]; }
  details_report() { :; }
  active() { [[ "$1" == fail2ban ]]; }
  verify_f2b_live_test() { verify_line fail '封禁 192.0.2.123' 'injected failure'; }
  verify_main > /dev/null
  [[ "$VERIFY_EXIT" == 3 ]] || fail 'a failed live test left the exit code at 0'
)
printf 'PASS: the acceptance exit code is set after the optional live test.\n'

# Failed services are named, so the user knows which one to look at.
(
  getent() { return 0; }
  OS=debian
  FAILED_UNITS=''
  systemctl() {
    [[ "$*" == 'list-units --state=failed --type=service --no-legend --no-pager --plain' ]] || fail "unexpected systemctl $*"
    printf '%s' "$FAILED_UNITS"
  }
  out="$(verify_health)"
  grep -Fq '本次启动没有失败的服务' <<< "$out" || fail "no failed service not reported: $out"
  FAILED_UNITS='systemd-networkd-wait-online.service loaded failed failed Wait for Network to be Configured
'
  out="$(verify_health)"
  grep -Fq '有 1 个失败的服务：systemd-networkd-wait-online.service。' <<< "$out" || fail "failed service not named: $out"
  FAILED_UNITS="$(printf 'u%s.service loaded failed failed x\n' 1 2 3 4)"
  out="$(verify_health)"
  grep -Fq '有 4 个失败的服务：u1.service u2.service u3.service 等。' <<< "$out" || fail "long list not shortened: $out"
)
printf 'PASS: failed services are named in the health check.\n'
