#!/usr/bin/env bash
# Changing the SSH port: the firewall first, both ports under a timer, the old
# one closed only after a login on the new one, everything back when that does
# not come; a Port line elsewhere (a provider's "Port 22") commented out on a
# yes and put back; rollback lets the old port in before sshd goes back to it.
# sshd, systemd, UFW and the timer are mocks.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions ssh_port_text ssh_port_reload ssh_port_established ssh_port_restore_previous ssh_port_fw_close ssh_port_stage \
  restore_sshport_group check_sshport ufw_rule restore_record_fw_rule port_source_valid verify_set audit_clean_text \
  sshd_line_value sshd_config_walk sshd_include_args sshd_reads sshd_port_lines sshd_lines_show sshd_lines_off sshd_lines_on \
  sshd_lines_on_cmd sshd_off_files restore_record_sshd_file
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
module_result() { record "result $1 $2 ${3:-}"; }
S="$TEST_ROOT/ssh"
mkdir -p "$S/sshd_config.d" "$TEST_ROOT/state/restore-v2"
for fn in ssh_port_elsewhere; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/etc/ssh#$S#g" -e "s#/etc/systemd/system#$TEST_ROOT/systemd#g")"
done
STATE_ROOT="$TEST_ROOT/state" RESTORE_ROOT="$TEST_ROOT/state/restore-v2" RESTORE_READY=1
SSH_PORT_DROPIN="$S/sshd_config.d/00-vps-stable-port.conf"
SSHD_CONFIG="$S/sshd_config"
plain_config() { printf '%s\n' "Include $S/sshd_config.d/*.conf" > "$SSHD_CONFIG"; }
plain_config
# sshd listens on every Port line of sshd_config and the drop-in (22 without
# any), once reloaded.
LISTEN='22'
listen_from_config() {
  LISTEN="$( { sed -n 's/^Port //p' "$SSHD_CONFIG"; sed -n 's/^Port //p' "$SSH_PORT_DROPIN"; } 2>/dev/null | sort -u | tr '\n' ' ')"
  LISTEN="${LISTEN:-22}"
}
ssh_reload() { record 'ssh reload'; ((RELOAD_OK)) && listen_from_config; }
systemctl() { record "systemctl $*"; case "$1" in is-active) return 1 ;; esac; }
ssh_detect() { SSH_PORTS=(22); }
port_listening() { [[ " $LISTEN " == *" $1 "* ]]; }
sshd() { ((SSHD_OK)); }
sshd_runtime_dir() { :; }
guard_leftovers() { return 1; }
guard_arm() { record "guard $1"; }
guard_confirm() { record confirm; ((CONFIRM)); }
ssh_port_follow() { record "fail2ban follows $LISTEN"; }
ssh_limit_exempt() { record exempt; }
confirm_yes() { ((PROVIDER)); }
confirm_default_yes() { case "$1" in *注释掉*) record 'ask comment out'; ((COMMENT_OK)) ;; *) return 1 ;; esac; }
backup_config_path() { :; }
record_config_change() { :; }
restore_data_safe() { [[ -f "$1" && ! -L "$1" ]]; }
put_file() { [[ ! -e "$1" ]] || return 1; printf '%s\n' "$2" > "$1"; }
restore_file_ours() { return 0; }
ss() { [[ -s "$TEST_ROOT/in-use" ]] && cat "$TEST_ROOT/in-use"; return 0; }
# UFW: active, SSH limited on 22 (added by this tool).
ufw_active() { return 0; }
ufw() {
  case "$1" in
    show) cat "$TEST_ROOT/ufw" ;;
    allow|limit) printf 'ufw %s %s\n' "$1" "$2" >> "$TEST_ROOT/ufw"; record "ufw $*" ;;
    --force) shift 2; local rule="ufw $*"; [[ "$*" == allow\ proto\ tcp\ from* ]] && rule="ufw allow from $5 to any port $9 proto tcp"
      grep -vxF -- "$rule" "$TEST_ROOT/ufw" > "$TEST_ROOT/ufw.new" || true; mv "$TEST_ROOT/ufw.new" "$TEST_ROOT/ufw"; record "ufw delete $*" ;;
  esac
}
start() {
  : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; : > "$TEST_ROOT/in-use"
  printf 'ufw limit 22/tcp\nufw allow from 203.0.113.9 to any port 22 proto tcp\n' > "$TEST_ROOT/ufw"
  printf 'ufw limit 22/tcp\nufw allow from 203.0.113.9 to any port 22 proto tcp\n' > "$RESTORE_ROOT/fw_rules"
  rm -f "$SSH_PORT_DROPIN" "$RESTORE_ROOT/sshport"
  LISTEN=22 SSHD_OK=1 RELOAD_OK=1 CONFIRM=1 PROVIDER=1 SSHPORT_CHOICE=1 COMMENT_OK=1
}

# Confirmed: the new port let in first, both ports while waiting, then only the
# new one; this tool's rules for the old port go; where to go back is kept.
start
ssh_port_stage <<< 2244 > /dev/null
[[ "$(cat "$SSH_PORT_DROPIN")" == $'# VPS Stable Optimizer v2.8: SSH port\nPort 2244' && "$LISTEN" == '2244 ' ]] || fail "after: $(cat "$SSH_PORT_DROPIN"), listening $LISTEN"
order="$(grep -nE '^(ufw limit 2244|guard |confirm|fail2ban follows 22 2244)' "$TEST_ROOT/trace" | cut -d: -f2- | tr '\n' '|')"
[[ "$order" == 'ufw limit 2244/tcp|guard vps-stable-ssh-revert-'*'|fail2ban follows 22 2244 |confirm|' ]] || fail "order: $order"
grep -Fxq 'ufw limit 2244/tcp' "$TEST_ROOT/ufw" && ! grep -q ' 22/tcp\|port 22 ' "$TEST_ROOT/ufw" || fail "firewall after: $(cat "$TEST_ROOT/ufw")"
grep -Fxq 'ufw limit 2244/tcp' "$RESTORE_ROOT/fw_rules" && ! grep -q ' 22/tcp\|port 22 ' "$RESTORE_ROOT/fw_rules" || fail "record after: $(cat "$RESTORE_ROOT/fw_rules")"
[[ "$(cat "$RESTORE_ROOT/sshport")" == $'port=22\nverb=limit' ]] || fail "original: $(cat "$RESTORE_ROOT/sshport")"
grep -Fxq exempt "$TEST_ROOT/trace" && grep -q '^result sshport applied port 2244' "$TEST_ROOT/trace" || fail "result: $(cat "$TEST_ROOT/trace")"
grep -q '安全组里把旧端口 22 关掉' "$TEST_ROOT/log" || fail 'the provider firewall not mentioned'
printf 'PASS: a confirmed change lets the new port in first, waits on both, then closes the old port everywhere.\n'

# Not confirmed: everything as it was, the timer stopped.
start; CONFIRM=0
ssh_port_stage <<< 2244 > /dev/null
[[ ! -e "$SSH_PORT_DROPIN" && "$LISTEN" == 22 ]] || fail "not reverted: listening $LISTEN"
[[ "$(cat "$TEST_ROOT/ufw")" == $'ufw limit 22/tcp\nufw allow from 203.0.113.9 to any port 22 proto tcp' ]] || fail "firewall not back: $(cat "$TEST_ROOT/ufw")"
grep -q '^systemctl stop vps-stable-ssh-revert-.*\.timer' "$TEST_ROOT/trace" && grep -q '^result sshport failed new port not confirmed' "$TEST_ROOT/trace" || fail "revert: $(cat "$TEST_ROOT/trace")"
# A second change goes back to the first one's setting, not the default.
start; ssh_port_stage <<< 2244 > /dev/null
CONFIRM=0; ssh_detect() { SSH_PORTS=(2244); }; : > "$TEST_ROOT/trace"
ssh_port_stage <<< 2255 > /dev/null
[[ "$(cat "$SSH_PORT_DROPIN")" == *$'\nPort 2244' && "$LISTEN" == '2244 ' ]] || fail "second change not reverted to 2244: $(cat "$SSH_PORT_DROPIN")"
[[ "$(cat "$RESTORE_ROOT/sshport")" == $'port=22\nverb=limit' ]] || fail 'the original port was overwritten'
ssh_detect() { SSH_PORTS=(22); }
printf 'PASS: without a login on the new port everything goes back, to the previous change too.\n'

# Refused before anything changes.
for bad in 22 80 1023 70000 abc ''; do
  start; ssh_port_stage <<< "$bad" > /dev/null
  [[ ! -e "$SSH_PORT_DROPIN" && "$(grep -c '^ufw ' "$TEST_ROOT/trace")" == 0 ]] && grep -q '^result sshport declined' "$TEST_ROOT/trace" || fail "port <$bad> not refused"
done
start; printf 'LISTEN 0 128 0.0.0.0:2244 0.0.0.0:*\n' > "$TEST_ROOT/in-use"; ssh_port_stage <<< 2244 > /dev/null
grep -q '^result sshport declined port in use' "$TEST_ROOT/trace" || fail 'a port in use accepted'
start; PROVIDER=0; ssh_port_stage <<< 2244 > /dev/null
[[ ! -e "$SSH_PORT_DROPIN" ]] && grep -q '^result sshport declined provider firewall' "$TEST_ROOT/trace" || fail 'went on without the provider firewall'
# A Port line elsewhere, commenting it out declined: nothing changes, and
# where the line is was said.
start; printf 'Port 22\n' >> "$S/sshd_config"; cp -p "$S/sshd_config" "$TEST_ROOT/sshd_config.before"; COMMENT_OK=0
ssh_port_stage <<< 2244 > "$TEST_ROOT/out"
[[ ! -e "$SSH_PORT_DROPIN" ]] && grep -q '^result sshport preserved port set elsewhere' "$TEST_ROOT/trace" && grep -q 'sshd_config 第 2 行：Port 22' "$TEST_ROOT/out" ||
  fail 'a port set in sshd_config was overridden, or where it is was not said'
cmp -s "$S/sshd_config" "$TEST_ROOT/sshd_config.before" && ! grep -q '^ufw ' "$TEST_ROOT/trace" || fail 'something changed although commenting out was declined'
# Without the Include of sshd_config.d this tool's file would never be read.
start; printf 'Port 22\n' > "$S/sshd_config"; ssh_port_stage <<< 2244 > /dev/null
[[ ! -e "$SSH_PORT_DROPIN" ]] && grep -q '^result sshport preserved port set elsewhere' "$TEST_ROOT/trace" || fail 'went on although sshd does not read the drop-in'
if grep -Fxq 'ask comment out' "$TEST_ROOT/trace"; then fail 'offered to comment out a line although the drop-in would not be read'; fi
plain_config
mkdir -p "$TEST_ROOT/systemd/ssh.socket.d"; printf '[Socket]\nListenStream=2200\n' > "$TEST_ROOT/systemd/ssh.socket.d/port.conf"
start; ssh_port_stage <<< 2244 > /dev/null
grep -q '^result sshport preserved port set elsewhere' "$TEST_ROOT/trace" || fail 'a socket override was not respected'
rm -rf "$TEST_ROOT/systemd"
# sshd refusing it, or not listening on both: back, the new rule gone.
start; SSHD_OK=0; ssh_port_stage <<< 2244 > /dev/null
[[ ! -e "$SSH_PORT_DROPIN" ]] && ! grep -q 2244 "$TEST_ROOT/ufw" && grep -q '^result sshport failed sshd -t failed' "$TEST_ROOT/trace" || fail 'sshd -t failure'
start; RELOAD_OK=0; ssh_port_stage <<< 2244 > /dev/null
[[ ! -e "$SSH_PORT_DROPIN" ]] && ! grep -q 2244 "$TEST_ROOT/ufw" && grep -q '^result sshport failed not listening' "$TEST_ROOT/trace" || fail "not listening: $(cat "$TEST_ROOT/trace")"
printf 'PASS: a bad or busy port, no provider firewall, a port set elsewhere, sshd refusing or not listening: nothing stays changed.\n'

# Rollback: the original port is let in before sshd goes back to it.
start; ssh_port_stage <<< 2244 > /dev/null
restore_needed() { return 0; }
restore_resource() { record "resource $1"; rm -f "$SSH_PORT_DROPIN"; }
: > "$TEST_ROOT/trace"; RESTORE_PARTIAL=0
restore_sshport_group
order="$(grep -nE '^(ufw limit 22/tcp|exempt|resource sshport_dropin|ssh reload)' "$TEST_ROOT/trace" | cut -d: -f2- | tr '\n' '|')"
[[ "$order" == 'ufw limit 22/tcp|exempt|resource sshport_dropin|ssh reload|' && "$LISTEN" == 22 ]] || fail "rollback order: $order"
# A full rollback (vps rollback) records nothing new (RESTORE_READY=0), yet the
# rule letting the old port in again is this tool's: the firewall group, undone
# after it, must delete it (a real Debian 13 VPS kept "limit 22/tcp" in UFW
# after the full rollback).
start; ssh_port_stage <<< 2244 > /dev/null
if grep -Fxq 'ufw limit 22/tcp' "$RESTORE_ROOT/fw_rules"; then fail 'the old port rule still recorded after the change'; fi
: > "$TEST_ROOT/trace"; RESTORE_READY=0
restore_sshport_group
RESTORE_READY=1
grep -Fxq 'ufw limit 22/tcp' "$TEST_ROOT/ufw" && grep -Fxq 'ufw limit 22/tcp' "$RESTORE_ROOT/fw_rules" ||
  fail "the old port, let in again by a full rollback, is not recorded as this tool's rule: $(cat "$RESTORE_ROOT/fw_rules")"
# Someone else's rule for the old port stayed through the change: still theirs.
start; grep -vxF 'ufw limit 22/tcp' "$RESTORE_ROOT/fw_rules" > "$TEST_ROOT/fw.new" || true; mv "$TEST_ROOT/fw.new" "$RESTORE_ROOT/fw_rules"
ssh_port_stage <<< 2244 > /dev/null
grep -Fxq 'ufw limit 22/tcp' "$TEST_ROOT/ufw" || fail "someone else's rule for the old port was deleted"
: > "$TEST_ROOT/trace"; RESTORE_READY=0
restore_sshport_group
RESTORE_READY=1
if grep -Fxq 'ufw limit 22/tcp' "$RESTORE_ROOT/fw_rules"; then fail "someone else's rule for the old port recorded as this tool's"; fi
printf 'PASS: rollback lets the original port in (allowlisted addresses unlimited again) before SSH goes back to it, by a rule of its own.\n'

# A provider image with "Port 22" in sshd_config (a real Debian 13 VPS): on a
# yes it is commented out, the old port stays open through this tool's own
# file until the new one is confirmed, and every way back puts the line back.
port_case() {
  start; plain_config; printf '%s\n' 'Port 22' >> "$S/sshd_config"; cp -p "$S/sshd_config" "$TEST_ROOT/sshd_config.before"
  rm -f "$RESTORE_ROOT/sshd_lines_off"
}
port_case
ssh_port_stage <<< 2244 > "$TEST_ROOT/out"
tag="$(sed -n 's/^#vps-stable-off(sshport,\([0-9-]*\)): Port 22$/\1/p' "$S/sshd_config")"
[[ -n "$tag" && "$(cat "$SSH_PORT_DROPIN")" == *$'\nPort 2244' && "$LISTEN" == '2244 ' ]] || fail "after: $(cat "$S/sshd_config"), listening $LISTEN"
grep -q "^guard vps-stable-ssh-revert-$tag" "$TEST_ROOT/trace" && grep -q '^result sshport applied port 2244' "$TEST_ROOT/trace" || fail "result: $(cat "$TEST_ROOT/trace")"
# Rollback: the line back byte for byte, SSH on 22 again.
restore_needed() { return 0; }
restore_resource() { record "resource $1"; rm -f "$SSH_PORT_DROPIN"; }
: > "$TEST_ROOT/trace"; RESTORE_PARTIAL=0
restore_sshport_group
cmp -s "$S/sshd_config" "$TEST_ROOT/sshd_config.before" && [[ "$LISTEN" == '22 ' ]] && ((RESTORE_PARTIAL == 0)) || fail "rollback: $(cat "$S/sshd_config"), listening $LISTEN"
unset -f restore_needed restore_resource
# Not confirmed: the line back, the old port only.
port_case; CONFIRM=0
ssh_port_stage <<< 2244 > /dev/null
cmp -s "$S/sshd_config" "$TEST_ROOT/sshd_config.before" && [[ ! -e "$SSH_PORT_DROPIN" && "$LISTEN" == '22 ' ]] || fail "not confirmed: $(cat "$S/sshd_config"), listening $LISTEN"
# sshd refusing it: the line back too.
port_case; SSHD_OK=0
ssh_port_stage <<< 2244 > /dev/null
cmp -s "$S/sshd_config" "$TEST_ROOT/sshd_config.before" && [[ ! -e "$SSH_PORT_DROPIN" ]] || fail 'sshd -t failure left the line commented out'
# The guard timer's command carries the line back.
port_case; CONFIRM=0
guard_arm() { record "guard $*"; }
ssh_port_stage <<< 2244 > /dev/null
grep -q "^guard vps-stable-ssh-revert-.*; sed -i 's/^#vps-stable-off(sshport,[0-9]*-[0-9]*): //' '$S/sshd_config'; if systemctl" "$TEST_ROOT/trace" || fail "guard: $(grep '^guard' "$TEST_ROOT/trace")"
guard_arm() { record "guard $1"; }
# vps check: the provider wrote "Port 22" back at boot, SSH on 22 again.
port_case
ssh_port_stage <<< 2244 > /dev/null
sed -i 's/^#vps-stable-off(sshport,[0-9-]*): //' "$S/sshd_config"; listen_from_config; printf 'ufw limit 2244/tcp\n' > "$TEST_ROOT/ufw"
check_sshport ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'端口 22 上监听'*'sshd_config 第 2 行'* ]] || fail "check after a write-back: $VERIFY_STATUS $VERIFY_TEXT"
plain_config
printf 'PASS: a Port line elsewhere is commented out on a yes, put back by rollback, by the guard and when not confirmed; vps check sees one written back.\n'

# vps check: sshd listens on the ports of the file, the firewall lets them in.
printf 'Port 2244\n' > "$SSH_PORT_DROPIN"; LISTEN='2244 '; printf 'ufw limit 2244/tcp\n' > "$TEST_ROOT/ufw"
check_sshport ''; [[ "$VERIFY_STATUS" == pass ]] || fail "check: $VERIFY_TEXT"
: > "$TEST_ROOT/ufw"; check_sshport ''; [[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'没有放行 SSH 端口 2244'* ]] || fail 'a port not let in passed'
LISTEN=22; check_sshport ''; [[ "$VERIFY_STATUS" == fail ]] || fail 'a port sshd is not on passed'
printf 'PASS: vps check sees the SSH port in sshd and in the firewall.\n'
