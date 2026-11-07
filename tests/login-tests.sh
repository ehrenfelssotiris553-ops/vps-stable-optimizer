#!/usr/bin/env bash
# Login record and note: the hook PAM runs (generated text, run here with
# PAM's variables and a fake journal), the PAM profile, turning it on and off
# through pam-auth-update (a mock), the menu's red line and vps check.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions login_pam_text login_hook_text login_profile_text login_pam_enabled login_stage login_known_seed f2b_allowlist port_source_valid login_recent menu_login_alert check_login verify_set \
  restore_value restore_apply_one restore_path
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
module_result() { record "result $1 $2 ${3:-}"; }
STATE_ROOT="$TEST_ROOT/state" PAM_COMMON_SESSION="$TEST_ROOT/common-session" LOGIN_PAM_FILE="$TEST_ROOT/pam-configs/vps-stable-login"
LOGIN_PROFILE_FILE="$TEST_ROOT/profile.d/zz-vps-stable-login.sh" LOGIN_NOTE_DIR="$TEST_ROOT/notes"
mkdir -p "$STATE_ROOT" "$TEST_ROOT/bin"
REC="$STATE_ROOT/logins"

# The hook as PAM runs it: sshd's lines come from a fake journal.
login_hook_text > "$TEST_ROOT/hook"
cat > "$TEST_ROOT/bin/journalctl" <<EOF
#!/bin/bash
cat "$TEST_ROOT/journal" 2>/dev/null
EOF
chmod +x "$TEST_ROOT/bin/journalctl"
if ! command -v flock > /dev/null; then printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/bin/flock"; chmod +x "$TEST_ROOT/bin/flock"; fi
# Giving the note to the account needs root: stood in for here (vm-run logs in for real).
printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/bin/chown"; chmod +x "$TEST_ROOT/bin/chown"
journal_line() { printf '%s.000001 host sshd[42]: Accepted %s for %s from %s port 50000 ssh2\n' "$(($(date +%s) - ${4:-2}))" "$1" "$2" "$3" >> "$TEST_ROOT/journal"; }
# The note the hook leaves for the account goes to TEST_ROOT/note.
hook() {
  rm -rf "$LOGIN_NOTE_DIR"
  env -i PATH="$TEST_ROOT/bin:$PATH" PAM_TYPE="${TYPE:-open_session}" PAM_SERVICE="${SERVICE:-sshd}" PAM_USER="$1" PAM_RHOST="${2:-}" \
    PAM_TTY="${TTY:-/dev/pts/0}" /bin/bash "$TEST_ROOT/hook" > "$TEST_ROOT/hook-out" 2>&1
  [[ ! -s "$TEST_ROOT/hook-out" ]] || fail "the hook printed something (PAM shows nothing of it): $(cat "$TEST_ROOT/hook-out")"
  cat "$LOGIN_NOTE_DIR/$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')" > "$TEST_ROOT/note" 2>/dev/null || : > "$TEST_ROOT/note"
}
field() { tail -n 1 "$REC" | cut -f"$1"; }

# A first login: recorded with its method, the address new, the note says so in red.
journal_line publickey root 203.0.113.5
hook root 203.0.113.5
[[ "$(wc -l < "$REC")" == 1 && "$(field 2)" == root && "$(field 3)" == 203.0.113.5 && "$(field 4)" == publickey && "$(field 5)" == ssh && "$(field 6)" == 1 ]] ||
  fail "first login: $(cat "$REC")"
grep -Fq '这是本工具记下的第一次登录' "$TEST_ROOT/note" && grep -Fq $'\e[31m这是第一次从 203.0.113.5 登录' "$TEST_ROOT/note" || fail "first note: $(cat "$TEST_ROOT/note")"
[[ "$(stat -c %a "$REC")" == 600 ]] || [[ "$(uname -o 2>/dev/null)" == Msys ]] || fail 'the record is readable by others'
# Again from there: not new; the note shows the previous login.
: > "$TEST_ROOT/journal"; journal_line publickey root 203.0.113.5
hook root 203.0.113.5
[[ "$(field 6)" == 0 ]] || fail 'a known address counted as new'
grep -Fq '上次登录：' "$TEST_ROOT/note" && grep -Fq 'root 来自 203.0.113.5（密钥）' "$TEST_ROOT/note" || fail "previous login: $(cat "$TEST_ROOT/note")"
if grep -Fq $'\e[31m' "$TEST_ROOT/note"; then fail 'a known address shown in red'; fi
printf 'PASS: a login is recorded with its method; a first-time address is shown in red, the previous login after it.\n'

# A login sshd wrote that opened no PAM session is recorded too, and shown.
: > "$TEST_ROOT/journal"; journal_line password admin 198.51.100.7 30; journal_line publickey root 203.0.113.5
hook root 203.0.113.5
grep -q $'\tadmin\t198.51.100.7\tpassword\tssh\t1$' "$REC" || fail "missed login not recorded: $(cat "$REC")"
grep -Fq '最近 10 分钟还有：' "$TEST_ROOT/note" && grep -Fq 'admin 来自 198.51.100.7（密码）  ← 第一次从这个 IP 登录' "$TEST_ROOT/note" || fail "missed login not shown: $(cat "$TEST_ROOT/note")"
# ...once: the next login does not add it again.
lines="$(wc -l < "$REC")"
hook root 203.0.113.5
[[ "$(grep -c $'\tadmin\t198.51.100.7\t' "$REC")" == 1 && "$(wc -l < "$REC")" == $((lines + 1)) ]] || fail "a missed login recorded twice: $(cat "$REC")"
printf 'PASS: a login only the journal has is recorded once and shown.\n'

# The console: recorded with its line, never "new". Other services and
# closing: nothing.
: > "$TEST_ROOT/journal"; journal_line publickey root 203.0.113.5
SERVICE=login TTY=tty1 hook root
[[ "$(field 3)" == console:tty1 && "$(field 4)" == console && "$(field 5)" == console && "$(field 6)" == 0 ]] || fail "console login: $(tail -n 1 "$REC")"
grep -Fq '服务商控制台（tty1）' <(SERVICE=login TTY=tty1 hook root; cat "$TEST_ROOT/note") || fail 'console login not named in the note'
lines="$(wc -l < "$REC")"
SERVICE=su hook root; TYPE=close_session hook root 203.0.113.5
[[ "$(wc -l < "$REC")" == "$lines" ]] || fail 'su or a closing session was recorded'
printf 'PASS: console logins are recorded with their line, su and closing not at all.\n'

# What PAM passes is cleaned: no tab or newline can make a second record line.
hook "$(printf 'ro\tot\nx')" "$(printf '203.0.113.9\t1\nevil')"
[[ "$(tail -n 1 "$REC" | awk -F'\t' '{print NF}')" == 6 && "$(field 2)" == rootx && "$(field 3)" == 203.0.113.91evil ]] || fail "unclean PAM values: $(tail -n 1 "$REC" | cat -A)"
# An address marked as normal is not new.
printf 'ip 192.0.2.44\n' > "$STATE_ROOT/known"
hook root 192.0.2.44
[[ "$(field 6)" == 0 ]] || fail 'an address marked as normal counted as new'
printf 'PASS: the values from PAM are cleaned, and addresses marked as normal are not new.\n'

# A year and 20000 lines at most.
now="$(date +%s)"
{ printf '%s\troot\t192.0.2.1\tpassword\tssh\t0\n' "$((now - 40000000))"; for ((i = 0; i < 20005; i++)); do printf '%s\troot\t192.0.2.2\tpublickey\tssh\t0\n' "$((now - 1000))"; done; } > "$REC"
hook root 192.0.2.2
[[ "$(wc -l < "$REC")" == 20000 ]] && ! grep -q $'\t192.0.2.1\t' "$REC" || fail "record not limited: $(wc -l < "$REC") lines"
printf 'PASS: the record keeps a year and at most 20000 lines.\n'
# Other lengths, and no note, when the parameters say so.
P="$TEST_ROOT/params-login"; printf 'login_keep_days=30\nlogin_keep_lines=1000\nlogin_note=no\nlogin_note_minutes=30\n' > "$P"
PARAMS_FILE="$P" login_hook_text > "$TEST_ROOT/hook"
{ printf '%s\troot\t192.0.2.1\tpassword\tssh\t0\n' "$((now - 40 * 86400))"; for ((i = 0; i < 1005; i++)); do printf '%s\troot\t192.0.2.2\tpublickey\tssh\t0\n' "$((now - 1000))"; done; } > "$REC"
hook root 192.0.2.2
[[ "$(wc -l < "$REC")" == 1000 ]] && ! grep -q $'\t192.0.2.1\t' "$REC" || fail "record with 30 days and 1000 lines: $(wc -l < "$REC") lines"
[[ ! -s "$TEST_ROOT/note" ]] || fail "a note although switched off: $(cat "$TEST_ROOT/note")"
grep -Fq 'cut=$((now - 1800))' "$TEST_ROOT/hook" && grep -Fq '最近 30 分钟还有' "$TEST_ROOT/hook" || fail 'the note window is not 30 minutes'
login_hook_text > "$TEST_ROOT/hook"
printf 'PASS: the record length and the note follow their parameters.\n'

# The PAM profile: optional, the hook under a timeout.
login_pam_text > "$TEST_ROOT/profile"
grep -Fxq 'Session-Type: Additional' "$TEST_ROOT/profile" && grep -Eq $'^\toptional\tpam_exec.so quiet /usr/bin/timeout 3 /bin/bash '"$STATE_ROOT"'/login-hook$' "$TEST_ROOT/profile" ||
  fail "PAM profile: $(cat -A "$TEST_ROOT/profile")"
printf 'PASS: the PAM line is optional and the hook runs under a timeout.\n'

# The login shell shows the note once (on a terminal only), then it is empty.
login_profile_text > "$TEST_ROOT/show.sh"
mkdir -p "$LOGIN_NOTE_DIR"; me="$(id -un)"
printf 'the note\n' > "$LOGIN_NOTE_DIR/$me"
[[ -z "$(sh "$TEST_ROOT/show.sh")" && -s "$LOGIN_NOTE_DIR/$me" ]] || fail 'the note was shown or emptied without a terminal'
if command -v script > /dev/null && script -qc true /dev/null > /dev/null 2>&1; then
  out="$(script -qc "sh $TEST_ROOT/show.sh" /dev/null)"
  [[ "$out" == *'the note'* && ! -s "$LOGIN_NOTE_DIR/$me" ]] || fail "the note on a terminal: <$out>"
  out="$(script -qc "sh $TEST_ROOT/show.sh" /dev/null)"
  [[ "$out" != *'the note'* ]] || fail 'the note was shown twice'
  printf 'PASS: the login shell shows the note once.\n'
else
  printf 'PASS (partly): no script(1) here for a terminal; the note stays without one.\n'
fi

# On through pam-auth-update; refused when common-session was edited by hand;
# rollback takes it out the same way.
put_file() { [[ ! -e "$1" ]] || [[ "$(cat "$1")" == "$2" ]] || return 1; mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
restore_file_ours() { return 0; }
EDITED=0
pam-auth-update() {
  record "pam-auth-update $*"
  ((EDITED == 0)) || return 0
  case "$*" in
    '--package --enable vps-stable-login') printf 'session optional pam_exec.so quiet stdout /usr/bin/timeout 3 /bin/bash %s/login-hook\n' "$STATE_ROOT" >> "$PAM_COMMON_SESSION" ;;
    '--package --remove vps-stable-login') sed -i '/login-hook/d' "$PAM_COMMON_SESSION" ;;
  esac
}
printf 'session required pam_unix.so\n' > "$PAM_COMMON_SESSION"
F2B_FILE="$TEST_ROOT/no-jail.local" F2B_IGNORE_CHOICE=''
reset; LOGIN_CHOICE=1; login_stage
[[ "$(cat "$STATE_ROOT/login-hook")" == "$(login_hook_text)" && -f "$LOGIN_PAM_FILE" && "$(cat "$LOGIN_PROFILE_FILE")" == "$(login_profile_text)" ]] &&
  login_pam_enabled && grep -q '^result login applied' "$TEST_ROOT/trace" ||
  fail "login on: $(cat "$TEST_ROOT/trace")"
[[ "$(restore_value login_pam)" == enabled ]] || fail 'login_pam value'
# The administrator's addresses are known from the start: the one it is turned
# on from, the setup's allowlist choice and single IPs on the allowlist (on a
# real Debian 13 VPS the address just allowlisted was shown in red).
: > "$STATE_ROOT/known"
printf '[sshd]\nignoreip = 127.0.0.1/8 ::1 203.0.113.9 198.18.0.0/24\n' > "$F2B_FILE"
SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 22' F2B_IGNORE_CHOICE='198.51.100.8'
reset; login_stage; login_stage
[[ "$(sort "$STATE_ROOT/known" | tr '\n' ' ')" == 'ip 198.51.100.7 ip 198.51.100.8 ip 203.0.113.9 ' ]] || fail "known at the start: $(cat "$STATE_ROOT/known")"
unset SSH_CONNECTION; F2B_IGNORE_CHOICE=''; rm -f "$F2B_FILE"; : > "$STATE_ROOT/known"
reset; login_stage
[[ "$(grep -c login-hook "$PAM_COMMON_SESSION")" == 1 && "$(grep -c pam-auth-update "$TEST_ROOT/trace")" == 0 ]] || fail 'turned on twice'
restore_read() { [[ "$2" == origin_value ]] && echo absent; }
restore_apply_one login_pam || fail 'login_pam not taken out'
! login_pam_enabled && grep -Fxq 'pam-auth-update --package --remove vps-stable-login' "$TEST_ROOT/trace" || fail 'rollback did not use pam-auth-update'
grep -Fxq 'session required pam_unix.so' "$PAM_COMMON_SESSION" || fail 'rollback changed other lines'
EDITED=1
reset; login_stage
grep -q '^result login failed' "$TEST_ROOT/trace" && grep -q '被手动改过' "$TEST_ROOT/log" || fail 'a hand-edited common-session was not reported'
EDITED=0
reset; LOGIN_CHOICE=0; login_stage
grep -q '^result login declined' "$TEST_ROOT/trace" || fail 'declined login record'
printf 'PASS: the login record goes on and off through pam-auth-update and never edits common-session itself.\n'

# The menu: a first-time address of the last 3 days, unless marked as normal.
now="$(date +%s)"
printf '%s\troot\t198.51.100.66\tpassword\tssh\t1\n%s\troot\t198.51.100.77\tpassword\tssh\t1\n%s\troot\t203.0.113.5\tpublickey\tssh\t0\n' \
  "$((now - 400000))" "$((now - 600))" "$((now - 60))" > "$REC"
: > "$STATE_ROOT/known"
out="$(menu_login_alert)"
[[ "$out" == *'陌生 IP 登录过：198.51.100.77（root，'* && "$out" != *198.51.100.66* && "$out" != *203.0.113.5* ]] || fail "menu alert: $out"
printf 'ip 198.51.100.77\n' > "$STATE_ROOT/known"
[[ -z "$(menu_login_alert)" ]] || fail 'an address marked as normal still alerted'
: > "$STATE_ROOT/known"
P="$TEST_ROOT/params-alert"; printf 'menu_alert_days=7\n' > "$P"
out="$(PARAMS_FILE="$P" menu_login_alert)"
[[ "$out" == *198.51.100.66* && "$out" == *198.51.100.77* ]] || fail "menu alert over 7 days: $out"
printf 'ip 198.51.100.77\n' > "$STATE_ROOT/known"
rm -f "$REC"; [[ -z "$(menu_login_alert)" ]] || fail 'an alert without a record'
printf 'PASS: the menu shows first-time addresses of the last 3 days in red until marked as normal.\n'

# vps check.
printf '%s\troot\t203.0.113.5\tpublickey\tssh\t0\n' "$now" > "$REC"
pam-auth-update --package --enable vps-stable-login; login_hook_text > "$STATE_ROOT/login-hook"; login_profile_text > "$LOGIN_PROFILE_FILE"
check_login ''
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *'记下了 1 次登录'* ]] || fail "check: $VERIFY_STATUS $VERIFY_TEXT"
printf '# older\n' > "$STATE_ROOT/login-hook"; check_login ''
[[ "$VERIFY_STATUS" == update ]] || fail 'an older hook not reported'
pam-auth-update --package --remove vps-stable-login; check_login ''
[[ "$VERIFY_STATUS" == fail ]] || fail 'a removed PAM line passed'
printf 'PASS: vps check sees the PAM line, an older hook and the number of logins.\n'

# vps logins: the last logins newest first, a first-time address not marked
# as normal in red, then every address with its count; from the journal when
# there is no record (saying so). Everything shown is cleaned.
(
  load_optimizer_functions logins_show logins_main
  C_FAIL='<red>' C_RESET='</red>'
  ok() { printf 'OK %s\n' "$*"; }
  : > "$PAM_COMMON_SESSION"
  rm -f "$STATE_ROOT/known"; mkdir -p "$STATE_ROOT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    1700000000 root 203.0.113.9 publickey ssh 1 \
    1700000100 ops 203.0.113.9 publickey ssh 0 \
    1700000200 root console:tty1 console console 0 \
    1700000300 root 198.51.100.7 password ssh 1 \
    1700000400 "evil$(printf '\033')[2J" 192.0.2.5 password ssh 1 > "$STATE_ROOT/logins"
  printf 'ip 203.0.113.9\n' > "$STATE_ROOT/known"
  out="$(logins_show 3)"
  [[ "$(grep -c '^  20[0-9][0-9]-' <<< "$out")" == 3 ]] || fail "not the last 3 logins: $out"
  first="$(grep -m1 '^  20[0-9][0-9]-' <<< "$out")"
  [[ "$first" == *'来自 192.0.2.5（密码）<red>  ← 第一次从这个 IP 登录</red>' && "$first" != *$'\033'* && "$first" == *' evil2J '* ]] ||
    fail "newest login, cleaned and red: $first"
  grep -q '服务商控制台（tty1）（控制台）' <<< "$out" || fail 'console login not shown'
  if grep -q '203.0.113.9（密钥）<red>' <<< "$out"; then fail 'a known address shown in red'; fi
  grep -q '一共 5 次；来源：本工具的登录记录' <<< "$out" || fail "count and source: $out"
  grep -q '203.0.113.9：2 次，最后一次 .*，账户 root ops，密钥' <<< "$out" || fail "summary per address: $out"
  grep -q '服务商控制台：1 次' <<< "$out" || fail 'console logins not counted'
  out="$(logins_show 30)"
  grep -q '203.0.113.9（密钥）（第一次出现，已标记为正常）' <<< "$out" || fail "a first-time address marked as normal: $out"
  # No record yet, login record off: sshd's lines from the journal.
  rm -f "$STATE_ROOT/logins"
  journalctl() { printf '%s\n' '1700000500.123456 host sshd-session[42]: Accepted publickey for alice from 203.0.113.20 port 5 ssh2: ED25519 SHA256:x' \
    '1700000600.1 host sshd[43]: Failed password for root from 192.0.2.66 port 6 ssh2'; }
  out="$(logins_show 30)"
  [[ "$out" == *'登录记录没开'* && "$out" == *'alice 来自 203.0.113.20（密钥）'* && "$out" == *'来源：系统日志'* && "$out" != *192.0.2.66* ]] || fail "from the journal: $out"
  journalctl() { :; }
  [[ "$(logins_show 30)" == *'没有找到登录'* ]] || fail 'no logins at all not said'
  # The command line: a number from 1 to 1000.
  for bad in 0 1001 abc -5; do
    if (MODE_ARGS=("$bad"); EUID=0 logins_main) > /dev/null 2>&1; then fail "vps logins $bad accepted"; fi
  done
)
printf 'PASS: vps logins shows the last logins newest first (first-time addresses in red, cleaned), a summary per address, and the journal without a record.\n'
