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
for audit_name in audit_clean_text audit_bounded_lines audit_sshd_values audit_passwd_state audit_ufw_ipv6 audit_journal_counts audit_journal_health; do
  load_audit_function "$audit_name"
done
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "Missing: $2"; }
assert_not() { [[ "$1" != *"$2"* ]] || fail "Unexpected: $2"; }
say() { printf 'SECTION %s\n' "$*"; }
# sshd is a mock here: its runtime directory is not needed.
sshd_runtime_dir() { :; }
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

[[ "$(printf 'root NP 2026-01-01 0 99999 7 -1\n' | audit_passwd_state)" == NP ]] || fail 'NP missing'
if printf 'root BAD invalid\n' | audit_passwd_state >/dev/null; then fail 'invalid passwd status accepted'; fi
passed 'passwd status rejects unknown codes'

[[ "$(printf 'IPV6="yes" # comment\n' | audit_ufw_ipv6)" == yes ]] || fail 'quoted UFW yes'
[[ "$(printf "IPV6='no'\n" | audit_ufw_ipv6)" == no ]] || fail 'quoted UFW no'
[[ "$(printf 'IPV6=yes\nIPV6=no\n' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'duplicate assignment'
[[ "$(printf 'IPV6=$(touch SECRET_MARKER)\n' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'shell expression accepted'
[[ "$(printf '' | audit_ufw_ipv6)" == UNKNOWN ]] || fail 'missing UFW setting'
passed 'UFW parser never executes shell expressions and handles ambiguity'

out="$(printf 'normal SECRET_LOG_MUST_NOT_LEAK\nOut of memory: Killed process 123 PRIVATE_TOKEN\nBuffer I/O error on dev vda\nKernel panic - not syncing:\n' | audit_journal_counts)"
[[ "$out" == '4 1 1 1 0 0' ]] || fail "journal counter output: $out"
assert_not "$out" SECRET_LOG_MUST_NOT_LEAK
assert_not "$out" PRIVATE_TOKEN
[[ "$(printf '' | audit_journal_counts)" == '0 0 0 0 0 0' ]] || fail 'empty journal parser'
[[ "$(printf 'Hint: You are currently not seeing messages\n' | audit_journal_counts)" == '1 0 0 0 1 0' ]] || fail 'partial visibility hint missing'
out="$(awk 'BEGIN {for(i=1;i<=3002;i++) print "sample"}' | audit_journal_counts)"
[[ "$out" == '3000 0 0 0 0 1' ]] || fail 'journal scan cap'
passed 'journal raw text never printed; empty/partial logs and scan cap represented'

# Seen on fresh cloud machines in CI: boot parameters that read like errors,
# and an empty floppy drive on KVM. A real NVMe timeout still counts.
out="$(printf '%s\n' 'Command line: BOOT_IMAGE=/boot/vmlinuz root=/dev/vda1 nvme_core.io_timeout=240 panic=-1' \
  'Kernel command line: BOOT_IMAGE=/boot/vmlinuz nvme_core.io_timeout=240' \
  'blk_update_request: I/O error, dev fd0, sector 0 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 0' \
  'Buffer I/O error on dev fd0, logical block 0, async page read' \
  'I/O error, dev sr0, sector 0 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2' | audit_journal_counts)"
[[ "$out" == '5 0 0 0 0 0' ]] || fail "boot parameters or an empty floppy/CD drive counted as storage errors: $out"
[[ "$(printf 'nvme nvme0: I/O 7 QID 2 timeout, aborting\n' | audit_journal_counts)" == '1 0 1 0 0 0' ]] || fail 'a real NVMe timeout was missed'
[[ "$(printf 'blk_update_request: I/O error, dev vda, sector 2048\n' | audit_journal_counts)" == '1 0 1 0 0 0' ]] || fail 'a real disk error was missed'
passed 'boot parameters and empty floppy/CD drives are no storage errors; real disk and NVMe errors are'
# A service that fails to open something is no hint that the journal is unreadable.
[[ "$(printf 'Failed to open nftables netlink socket. IPMasquerade= and NFTSet= settings will not be applied. Ignoring: Protocol not supported\n' | audit_journal_counts)" == '1 0 0 0 0 0' ]] ||
  fail 'a service message counted as a journal access problem'
[[ "$(printf 'Failed to open journal: Permission denied\n' | audit_journal_counts)" == '1 0 0 0 1 0' ]] || fail 'journalctl access error missed'
passed 'journal access hints are journalctl messages, not any service message'

journalctl() {
  [[ "$*" == "--system -b 0 --since -24 hours -n 1000 --no-pager -o cat" ]] || fail 'unexpected journal call'
  case "${JOURNAL_TEST_MODE:-data}" in
    data) printf 'normal SECRET_LOG_MUST_NOT_LEAK\nOut of memory: Killed process 123 PRIVATE_TOKEN\n' ;;
    empty) : ;;
    error) printf 'SECRET_ERROR_MUST_NOT_LEAK\n' >&2; return 1 ;;
  esac
}
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
