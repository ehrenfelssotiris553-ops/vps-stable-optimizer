#!/usr/bin/env bash
# Isolated read-only audit regression tests. Extract actual release functions;
# never source or run the optimizer's top-level setup. All service tools mocked.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="${VPS_OPT_SCRIPT:-$HERE/../vps-stable-opt.sh}"
[[ -r "$TEST_SCRIPT" ]] || { printf 'Unreadable optimizer: %s\n' "$TEST_SCRIPT" >&2; exit 1; }
load_audit_function() {
  local name="$1" definition
  definition="$(awk -v name="$name" '
    $0==name "() {" {copy=1;found=1}
    copy {print}
    copy && $0=="}" {closed=1;exit}
    END {if(!found || !closed) exit 1}' "$TEST_SCRIPT")" || return 1
  eval "$definition"
}
for audit_name in audit_clean_text audit_bounded_lines audit_sshd_values audit_uid0_names audit_passwd_state audit_listener_rows audit_ufw_ipv6 audit_mem_values audit_disk_risks audit_journal_counts audit_accounts audit_authorized_keys audit_network docker_present docker_firewall_note security_audit audit_journal_health health_report; do
  load_audit_function "$audit_name"
done
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "Missing: $2"; }
assert_not() { [[ "$1" != *"$2"* ]] || fail "Unexpected: $2"; }
say() { printf 'SECTION %s\n' "$*"; }
ok() { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }

out="$(printf '%s\n' 'hostkey PRIVATE_KEY_PATH_MUST_NOT_LEAK' 'passwordauthentication yes' 'kbdinteractiveauthentication no' 'permitemptypasswords no' 'permitrootlogin yes' 'pubkeyauthentication yes' 'maxauthtries 6' 'authorizedkeyscommand SECRET_COMMAND_MUST_NOT_LEAK' | audit_sshd_values)"
assert_has "$out" 'passwordauthentication=yes'
assert_has "$out" 'maxauthtries=6'
assert_not "$out" PRIVATE_KEY_PATH_MUST_NOT_LEAK
assert_not "$out" SECRET_COMMAND_MUST_NOT_LEAK
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 6 ]] || fail 'SSH whitelist count'
passed 'SSH effective config whitelist prevents unrelated fields leaking'
out="$(printf '' | audit_sshd_values)"
assert_has "$out" 'passwordauthentication=UNKNOWN'
assert_not "$out" 'passwordauthentication=no'
passed 'empty SSH config remains unknown'

out="$(printf '%s\n' 'root:SENSITIVE_HASH_MUST_NOT_LEAK:0:0:root:/root:/bin/bash' 'operator:x:1000:1000::/home/operator:/bin/bash' 'rescue:x:0:0::/:/bin/bash' | audit_uid0_names)"
[[ "$out" == $'root\nrescue' ]] || fail 'UID0 parser'
assert_not "$out" SENSITIVE_HASH_MUST_NOT_LEAK
[[ "$(printf 'root NP 2026-01-01 0 99999 7 -1\n' | audit_passwd_state)" == NP ]] || fail 'NP missing'
if printf 'root BAD invalid\n' | audit_passwd_state >/dev/null; then fail 'invalid passwd status accepted'; fi
passed 'UID0 parser excludes password fields and passwd status rejects unknown codes'

out="$(printf '%s\n' 'tcp LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' 'tcp LISTEN 0 128 [::1]:22 [::]:*' 'udp UNCONN 0 0 0.0.0.0:443 0.0.0.0:*' 'tcp LISTEN 0 128 [::]:443 [::]:*' | audit_listener_rows)"
[[ "$(awk '/^\[回环绑定\]/{n++} END {print n+0}' <<< "$out")" == 2 ]] || fail 'loopback classification'
[[ "$(awk '/^\[非回环绑定\]/{n++} END {print n+0}' <<< "$out")" == 2 ]] || fail 'wildcard binding classification'
assert_not "$out" 公网可达
passed 'IPv4/IPv6 loopback and wildcard bindings classified without reachability claims'

[[ "$(printf 'IPV6="yes" # comment\n' | audit_ufw_ipv6)" == yes ]] || fail 'quoted UFW yes'
[[ "$(printf "IPV6='no'\n" | audit_ufw_ipv6)" == no ]] || fail 'quoted UFW no'
[[ "$(printf 'IPV6=yes\nIPV6=no\n' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'duplicate assignment'
[[ "$(printf 'IPV6=$(touch SECRET_MARKER)\n' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'shell expression accepted'
[[ "$(printf '' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'missing UFW setting'
passed 'UFW parser never executes shell expressions and handles ambiguity'

out="$(printf 'MemTotal: 2048000 kB\nMemAvailable: 512000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' | audit_mem_values)"
assert_has "$out" MemAvailable=512000
assert_has "$out" SwapTotal=0
out="$(printf 'MemTotal: bogus kB\n' | audit_mem_values)"
assert_has "$out" MemTotal=UNKNOWN
assert_has "$out" MemAvailable=UNKNOWN
out="$(printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 1024000 920000 104000 90%% /\n/dev/vda2 10000 2000 8000 20%% /boot\n' | audit_disk_risks 磁盘)"
assert_has "$out" '磁盘: / 已用 90%'
assert_not "$out" /boot
assert_has "$(printf '' | audit_disk_risks inode)" 无法解析
passed 'memory missing fields unknown, disk threshold identifies root and preserves /boot'

out="$(printf 'normal SECRET_LOG_MUST_NOT_LEAK\nOut of memory: Killed process 123 PRIVATE_TOKEN\nBuffer I/O error on dev vda\nKernel panic - not syncing:\n' | audit_journal_counts)"
[[ "$out" == '4 1 1 1 0 0' ]] || fail "journal counter output: $out"
assert_not "$out" SECRET_LOG_MUST_NOT_LEAK
assert_not "$out" PRIVATE_TOKEN
[[ "$(printf '' | audit_journal_counts)" == '0 0 0 0 0 0' ]] || fail 'empty journal parser'
[[ "$(printf 'Hint: You are currently not seeing messages\n' | audit_journal_counts)" == '1 0 0 0 1 0' ]] || fail 'partial visibility hint missing'
out="$(awk 'BEGIN {for(i=1;i<=3002;i++) print "sample"}' | audit_journal_counts)"
[[ "$out" == '3000 0 0 0 0 1' ]] || fail 'journal scan cap'
passed 'journal raw text never printed; empty/partial logs and scan cap represented'

sshd() {
  case "$*" in
    -t) return "${SSHD_RC:-0}" ;;
    -T)
      if [[ "${SSHD_EMPTY:-0}" == 1 ]]; then return 0; fi
      printf '%s\n' 'hostkey PRIVATE_KEY_PATH_MUST_NOT_LEAK' 'passwordauthentication yes' 'kbdinteractiveauthentication no' 'permitemptypasswords no' 'permitrootlogin yes' 'pubkeyauthentication yes' 'maxauthtries 6'
      return "${SSHD_RC:-0}" ;;
    *) fail 'unexpected sshd call' ;;
  esac
}
getent() { [[ "$*" == passwd ]] || fail 'unexpected getent call'; printf '%s\n' 'root:SENSITIVE_HASH_MUST_NOT_LEAK:0:0:root:/root:/bin/bash' 'rescue:x:0:0::/:/bin/bash'; }
passwd() {
  [[ "$1" == -S && $# == 2 ]] || fail 'mutating passwd call'
  if [[ "$2" == root ]]; then printf 'root NP 2026-01-01 0 99999 7 -1\n'
  else printf '%s P 2026-01-01 0 99999 7 -1\n' "$2"; fi
}
ss() { [[ "$*" == '-H -lntup' ]] || fail 'unexpected socket call'; printf 'tcp LISTEN 0 128 [::]:443 [::]:*\n'; }
ip() {
  case "$*" in
    '-br -4 address show') printf 'eth0 UP 192.0.2.1/24\n' ;;
    '-br -6 address show') printf 'eth0 UP 2001:db8::1/64\n' ;;
    '-4 route show default') printf 'default via 192.0.2.254 dev eth0\n' ;;
    '-6 route show default') return 0 ;;
    *) fail 'unexpected ip call' ;;
  esac
}
ufw() { [[ "$*" == 'status verbose' ]] || fail 'mutating UFW call'; printf 'Status: active\n'; }
aa-status() { [[ "$*" == --enabled ]] || fail 'unexpected AppArmor call'; return 1; }
SSH_CONNECTION='192.0.2.2 12345 192.0.2.1 22' SUDO_USER=operator
out="$(security_audit)"
assert_has "$out" 'root 的 passwd 状态为 NP'
assert_has "$out" 'operator: P'
assert_has "$out" '额外 UID 0 账户：rescue'
assert_has "$out" 'Match'
assert_has "$out" '商家安全组'
assert_has "$out" 'IPv6 查询未返回默认路由'
assert_has "$out" 'AppArmor'
assert_not "$out" PRIVATE_KEY_PATH_MUST_NOT_LEAK
assert_not "$out" SENSITIVE_HASH_MUST_NOT_LEAK
passed 'security audit uses only read calls, highlights password/UID0 risks and limits'

SSHD_EMPTY=1
out="$(security_audit)"
assert_has "$out" 'sshd -T 失败或返回空结果'
assert_not "$out" 'passwordauthentication=no'
SSHD_EMPTY=0 SSHD_RC=1
out="$(security_audit)"
assert_has "$out" 'sshd -t 未通过或权限不足'
assert_has "$out" 'sshd -T 失败或返回空结果'
passed 'sshd empty/failure results remain unknown'

df() {
  case "$*" in '-Pk / /boot'|'-Pi / /boot') ;;
    *) fail 'unexpected df call' ;;
  esac
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 10000 9600 400 96%% /\n/dev/vda2 10000 9500 500 95%% /boot\n'
}
systemctl() {
  [[ "$*" == 'list-units --state=failed --type=service --no-legend --no-pager --plain' ]] || fail 'mutating service call'
  case "${FAILED_TEST_MODE:-failed}" in failed) printf 'example.service loaded failed failed Example\n';; empty) :;; error) return 1;; esac
}
journalctl() {
  [[ "$*" == "--system -b 0 --since -24 hours -n 1000 --no-pager -o cat" ]] || fail 'unexpected journal call'
  case "${JOURNAL_TEST_MODE:-data}" in
    data) printf 'normal SECRET_LOG_MUST_NOT_LEAK\nOut of memory: Killed process 123 PRIVATE_TOKEN\n' ;;
    empty) : ;;
    error) printf 'SECRET_ERROR_MUST_NOT_LEAK\n' >&2; return 1 ;;
  esac
}
out="$(health_report)"
assert_has "$out" '磁盘: /boot 已用 95%'
assert_has "$out" 'inode: / 已用 96%'
assert_has "$out" '存在 failed 服务'
assert_not "$out" SECRET_LOG_MUST_NOT_LEAK
assert_not "$out" PRIVATE_TOKEN
FAILED_TEST_MODE=empty
out="$(health_report)"
assert_has "$out" '查询未返回 failed 服务；这不代表所有服务功能正常'
FAILED_TEST_MODE=error
out="$(health_report)"
assert_has "$out" 'failed 服务查询失败'
passed 'health audit reports capacity/inodes/failures without changing services'

if (( EUID==0 )); then
  JOURNAL_TEST_MODE=empty
  out="$(audit_journal_health)"
  assert_has "$out" '日志为空或出现访问提示'
  JOURNAL_TEST_MODE=error
  out="$(audit_journal_health)"
  assert_has "$out" '系统日志查询失败或权限不足'
  assert_not "$out" SECRET_ERROR_MUST_NOT_LEAK
  passed 'journal query empty/error remains unknown without raw error leakage'
else
  out="$(audit_journal_health)"
  assert_has "$out" '非 root'
  assert_has "$out" '状态未知'
  passed 'non-root journal audit explicitly marks visibility unknown'
fi
out="$(printf 'normal\033[31mBAD\033[0m\r\n' | audit_clean_text)"
assert_not "$out" $'\033'
out="$(printf 'one\ntwo\nthree\n' | audit_bounded_lines 2)"
assert_has "$out" '仅显示前 2 行'
assert_not "$out" three
passed 'terminal control bytes stripped and bounded display reports omitted rows'
printf 'Audit tests: %s passed\n' "$PASS"
