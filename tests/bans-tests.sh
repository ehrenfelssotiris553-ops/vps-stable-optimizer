#!/usr/bin/env bash
# Fail2ban ban records (menu 13 / vps bans): the real functions with
# fail2ban-client and the log replaced by fixtures.
# shellcheck disable=SC2034,SC2329,SC2016
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions f2b_ban_events bans_main
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }

# Log events: sshd only, bans, restored bans and unbans; the rotated file first.
LOG="$TEST_ROOT/fail2ban.log"
printf '%s\n' '2026-10-24 08:00:00,001 fail2ban.actions        [811]: NOTICE  [sshd] Ban 192.0.2.50' > "$LOG.1"
printf '%s\n' \
  '2026-10-25 09:00:00,001 fail2ban.actions        [811]: NOTICE  [sshd] Ban 203.0.113.9' \
  '2026-10-25 21:00:00,002 fail2ban.actions        [811]: NOTICE  [sshd] Unban 203.0.113.9' \
  '2026-10-26 10:00:00,003 fail2ban.actions        [811]: NOTICE  [sshd] Ban 198.51.100.7' \
  '2026-10-26 10:00:01,004 fail2ban.actions        [811]: NOTICE  [recidive] Ban 192.0.2.1' \
  '2026-10-26 10:30:00,005 fail2ban.actions        [811]: NOTICE  [sshd] Restore Ban 2001:db8::7' \
  '2026-10-26 10:31:00,006 fail2ban.filter         [811]: INFO    [sshd] Found 198.51.100.8 - 2026-10-26 10:31:00' > "$LOG"
events="$(f2b_ban_events "$LOG")"
expected=$'2026-10-24 08:00:00\t封禁\t192.0.2.50\n2026-10-25 09:00:00\t封禁\t203.0.113.9\n2026-10-25 21:00:00\t解封\t203.0.113.9\n2026-10-26 10:00:00\t封禁\t198.51.100.7\n2026-10-26 10:30:00\t重启后恢复封禁\t2001:db8::7'
[[ "$events" == "$expected" ]] || { printf '%s\n' "$events" >&2; fail 'ban events not read correctly'; }
[[ "$(f2b_ban_events "$LOG" 2 | cut -f3 | tr '\n' ' ')" == '198.51.100.7 2001:db8::7 ' ]] || fail 'event limit keeps the newest'
# Fail2ban logging to the journal instead of a file.
journalctl() { printf '%s\n' '2026-10-26T12:00:00+0000 vps fail2ban-server[811]: NOTICE  [sshd] Ban 198.51.100.9'; }
[[ "$(f2b_ban_events "$TEST_ROOT/no-such.log")" == $'2026-10-26 12:00:00\t封禁\t198.51.100.9' ]] || fail 'journal events not read'
unset -f journalctl
printf 'PASS: ban events come from the log (or the journal), sshd only, oldest first.\n'

# bans_main insists on root and asks for an unban only on a terminal.
eval "$(declare -f bans_main | sed -e 's/\$EUID -eq 0/0 -eq 0/' -e 's/ && -t 0//')"
F2B_ON=1
active() { [[ "$1" == fail2ban ]] && ((F2B_ON)); }
fail2ban-client() {
  case "$*" in
    'status sshd') printf '%s\n' 'Status for the jail: sshd' '|- Filter' $'|  |- Currently failed:\t1' $'|  |- Total failed:\t15' \
      $'\x60- Actions' $'   |- Currently banned:\t2' $'   |- Total banned:\t3' $'   \x60- Banned IP list:\t198.51.100.7 2001:db8::7' ;;
    'get sshd bantime') echo 43200 ;;
    'get sshd banip --with-time') printf '%s\n' $'198.51.100.7 \t2026-10-26 10:00:00 + 43200 = 2026-10-26 22:00:00' \
      $'2001:db8::7 \t2026-10-26 10:30:00 + 43200 = 2026-10-26 22:30:00' ;;
    'get sshd ignoreip') printf '%s\n' 'These IP addresses/networks are ignored:' '|- 127.0.0.1/8' $'\x60- ::1' ;;
    'set sshd unbanip '*) printf '%s\n' "$*" >> "$TEST_ROOT/calls" ;;
    *) fail "unexpected fail2ban-client $*" ;;
  esac
}
f2b_ban_events() { printf '2026-10-26 10:00:00\t封禁\t198.51.100.7\n'; }
confirm_yes() { printf 'ask %s\n' "$1" >> "$TEST_ROOT/log"; ((YES)); }
tool_lifecycle_lock() { printf 'lock\n' >> "$TEST_ROOT/calls"; }
reset() { : > "$TEST_ROOT/log"; : > "$TEST_ROOT/calls"; YES=1; }

reset
bans_main < /dev/null > "$TEST_ROOT/out"
for text in '正在封禁：2 个 IP（每次封 12 小时）' '识别出 15 次失败登录，封禁过 3 次' '198.51.100.7' '到 2026-10-26 22:30:00 解封' \
            '白名单（不会被封）：127.0.0.1/8 ::1' '2026-10-26 10:00:00  封禁'; do
  grep -Fq -- "$text" "$TEST_ROOT/out" || fail "report lacks: $text"
done
SSH_CONNECTION='203.0.113.20 50000 192.0.2.1 22'
bans_main < /dev/null > "$TEST_ROOT/out"
grep -Fq '你当前的 IP 203.0.113.20 没有被封禁' "$TEST_ROOT/out" || fail 'own address not checked'
unset SSH_CONNECTION
printf 'PASS: ban records show counts, current bans with times, the allowlist and recent events.\n'

reset
printf '2001:db8::7\n' > "$TEST_ROOT/in"
bans_main < "$TEST_ROOT/in" > /dev/null
[[ "$(cat "$TEST_ROOT/calls")" == $'lock\nset sshd unbanip 2001:db8::7' ]] || fail 'confirmed unban of a listed IPv6 address'
for answer in 192.0.2.55 198.51.100 '198.51.100.7 2001:db8::7' ''; do
  reset
  printf '%s\n' "$answer" > "$TEST_ROOT/in"
  bans_main < "$TEST_ROOT/in" > /dev/null
  [[ ! -s "$TEST_ROOT/calls" ]] || fail "unbanned for input <$answer>"
done
reset; YES=0
printf '198.51.100.7\n' > "$TEST_ROOT/in"
bans_main < "$TEST_ROOT/in" > /dev/null
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'unbanned although declined'
reset; F2B_ON=0
bans_main < /dev/null > "$TEST_ROOT/out"
grep -Fq 'Fail2ban 没有运行' "$TEST_ROOT/log" || fail 'stopped Fail2ban not explained'
printf 'PASS: only a listed address is unbanned, after a yes; a stopped Fail2ban is explained.\n'
