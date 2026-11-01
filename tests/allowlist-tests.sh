#!/usr/bin/env bash
# The Fail2ban allowlist: several addresses kept in this tool's jail and in the
# running jail at once, networks no larger than /16 (/32 for IPv6), and the
# SSH rate-limit exemption kept in step (only for single addresses, and only
# the rules this tool recorded are removed). Every system command is a mock.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions f2b_jail_text f2b_jail_legacy_text f2b_jail_is_ours f2b_allowlist f2b_allow_valid f2b_allowlist_stage \
  f2b_allowlist_menu ssh_limit_exempt ssh_limit_exempt_one ssh_limit_unexempt port_source_valid restore_record_fw_rule f2b_replace_owned_file
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
F2B_FILE="$TEST_ROOT/jail.local" RESTORE_ROOT="$TEST_ROOT/restore" RESTORE_READY=1
mkdir -p "$RESTORE_ROOT"; chmod 700 "$RESTORE_ROOT"
backup_config_path() { :; }
record_config_change() { :; }
active() { [[ "$1" == fail2ban ]]; }
ufw_active() { return 0; }
fail2ban-client() { record "f2b $*"; if [[ "$*" == 'status sshd' ]]; then printf '`- Banned IP list:\t%s\n' "${BANNED:-}"; fi; }
# UFW's stored rules: limited SSH, plus what prepend and delete leave.
printf 'ufw limit 22/tcp\n' > "$TEST_ROOT/ufw"
ufw() {
  record "ufw $*"
  case "$*" in
    'show added') cat "$TEST_ROOT/ufw" ;;
    # ufw prepend allow proto tcp from IP to any port P: the IP is $6.
    'prepend allow proto tcp from '*) printf 'ufw allow from %s to any port %s proto tcp\n' "$6" "${*: -1}" >> "$TEST_ROOT/ufw" ;;
    # ufw --force delete allow proto tcp from IP to any port P: the IP is $7.
    '--force delete allow proto tcp from '*) grep -vxF "ufw allow from $7 to any port ${*: -1} proto tcp" "$TEST_ROOT/ufw" > "$TEST_ROOT/ufw.new" || true
      mv "$TEST_ROOT/ufw.new" "$TEST_ROOT/ufw" ;;
  esac
}
stage_run() { shift; "$@"; }
jail() { f2b_jail_text 22 "$1" > "$F2B_FILE"; }

# Addresses: IPs, and networks no larger than /16 (IPv4) or /32 (IPv6).
for good in 203.0.113.5 203.0.113.0/24 10.20.0.0/16 2001:db8::1 2001:db8::/32; do f2b_allow_valid "$good" > /dev/null || fail "rejected: $good"; done
for bad in 0.0.0.0/0 10.0.0.0/8 2001:db8::/16 300.1.1.1 'a.b.c.d' ''; do
  if f2b_allow_valid "$bad" > /dev/null; then fail "accepted: <$bad>"; fi
done
printf 'PASS: allowlist entries are IPs or networks no larger than /16 (IPv4) and /32 (IPv6).\n'

# Two single addresses and a network: jail file, running jail, exemptions.
jail 198.51.100.7
reset; F2B_ALLOW='198.51.100.7 203.0.113.5 203.0.113.0/24'; f2b_allowlist_stage
grep -Fxq 'ignoreip = 127.0.0.1/8 ::1 198.51.100.7 203.0.113.5 203.0.113.0/24' "$F2B_FILE" || fail "jail: $(cat "$F2B_FILE")"
[[ "$(f2b_allowlist | tr '\n' ' ')" == '198.51.100.7 203.0.113.5 203.0.113.0/24 ' ]] || fail 'allowlist read back'
f2b_jail_is_ours "$(cat "$F2B_FILE")" 22 || fail 'the jail with several addresses no longer counts as ours'
grep -Fxq 'f2b set sshd addignoreip 203.0.113.5' "$TEST_ROOT/trace" && grep -Fxq 'f2b set sshd addignoreip 203.0.113.0/24' "$TEST_ROOT/trace" ||
  fail "running jail not updated: $(cat "$TEST_ROOT/trace")"
if grep -q 'addignoreip 198.51.100.7' "$TEST_ROOT/trace"; then fail 'an address already there was added again'; fi
if grep -q 'reload' "$TEST_ROOT/trace"; then fail 'the jail was reloaded (bans would be at stake)'; fi
grep -Fxq 'ufw allow from 203.0.113.5 to any port 22 proto tcp' "$TEST_ROOT/ufw" || fail 'single address not exempt from the SSH limit'
grep -Fxq 'ufw allow from 198.51.100.7 to any port 22 proto tcp' "$TEST_ROOT/ufw" || fail 'the first address not exempt'
if grep -q '203.0.113.0/24 to any' "$TEST_ROOT/ufw"; then fail 'a network was exempt from the SSH limit'; fi
grep -Fxq 'ufw allow from 203.0.113.5 to any port 22 proto tcp' "$RESTORE_ROOT/fw_rules" || fail 'exemption not recorded for rollback'
printf 'PASS: the allowlist is written to the jail and the running jail, single addresses skip the SSH limit.\n'

# Removing one: out of both jails, its recorded exemption goes, a hand-made
# identical rule for another address stays.
printf 'ufw allow from 192.0.2.9 to any port 22 proto tcp\n' >> "$TEST_ROOT/ufw"
printf 'ufw allow from 192.0.2.9 to any port 22 proto tcp\n' >> "$TEST_ROOT/ufw.mine"
reset; F2B_ALLOW='198.51.100.7 203.0.113.0/24'; f2b_allowlist_stage
grep -Fxq 'ignoreip = 127.0.0.1/8 ::1 198.51.100.7 203.0.113.0/24' "$F2B_FILE" || fail "after removal: $(cat "$F2B_FILE")"
grep -Fxq 'f2b set sshd delignoreip 203.0.113.5' "$TEST_ROOT/trace" || fail 'removed address still in the running jail'
if grep -q '203.0.113.5' "$TEST_ROOT/ufw" "$RESTORE_ROOT/fw_rules"; then fail 'the exemption of a removed address stayed'; fi
grep -Fxq 'ufw allow from 192.0.2.9 to any port 22 proto tcp' "$TEST_ROOT/ufw" || fail 'a rule this tool did not add was removed'
# A user's own rule for an allowlisted address (not recorded) is not removed either.
printf 'ufw allow from 198.51.100.8 to any port 22 proto tcp\n' >> "$TEST_ROOT/ufw"
jail '198.51.100.7 198.51.100.8'
reset; F2B_ALLOW='198.51.100.7'; f2b_allowlist_stage
grep -Fxq 'ufw allow from 198.51.100.8 to any port 22 proto tcp' "$TEST_ROOT/ufw" || fail "a user's own exemption was removed"
# Emptied: no ignoreip line at all.
reset; F2B_ALLOW=''; f2b_allowlist_stage
if grep -q '^ignoreip' "$F2B_FILE"; then fail 'an empty allowlist left an ignoreip line'; fi
printf 'PASS: removing takes an address out of both jails and only its recorded exemption goes.\n'

# A jail that is not this tool's is left alone.
printf '[sshd]\nenabled = true\nignoreip = 10.0.0.1\n' > "$F2B_FILE"; cp "$F2B_FILE" "$TEST_ROOT/foreign"
reset; F2B_ALLOW='203.0.113.5'; f2b_allowlist_stage
cmp -s "$F2B_FILE" "$TEST_ROOT/foreign" || fail 'a foreign jail was changed'
grep -q '^WARN .*不是本工具写的' "$TEST_ROOT/log" || fail 'foreign jail not explained'
if grep -q 'addignoreip' "$TEST_ROOT/trace"; then fail 'the running jail was changed for a foreign jail'; fi
printf "PASS: a jail this tool did not write is left alone.\n"

# The menu: Enter adds your current IP, a banned one is offered an unban, the
# current IP needs a yes to go, a large network needs a yes to come.
jail ''; printf 'ufw limit 22/tcp\n' > "$TEST_ROOT/ufw"
SSH_CONNECTION='203.0.113.77 50000 10.0.0.2 22' BANNED='203.0.113.77'
confirm_default_yes() { record "ask $1"; return 0; }
CONFIRM=n
confirm_yes() { record "ask $1"; [[ "$CONFIRM" == y ]]; }
reset; printf 'a\n\n0\n' | f2b_allowlist_menu > /dev/null
[[ "$(f2b_allowlist)" == 203.0.113.77 ]] || fail "Enter did not add the current IP: $(cat "$F2B_FILE")"
grep -Fxq 'f2b set sshd unbanip 203.0.113.77' "$TEST_ROOT/trace" || fail 'the banned current IP was not unbanned on request'
reset; printf 'a\n203.0.0.0/16\n0\n' | f2b_allowlist_menu > /dev/null
grep -q '^ask 网段 203.0.0.0/16 很大' "$TEST_ROOT/trace" || fail 'a large network did not need a yes'
[[ "$(f2b_allowlist | wc -l)" == 1 ]] || fail 'a declined large network was added'
reset; printf 'd\n1\n0\n' | f2b_allowlist_menu > /dev/null
grep -q '^ask 203.0.113.77 是你现在的 IP' "$TEST_ROOT/trace" && [[ "$(f2b_allowlist)" == 203.0.113.77 ]] || fail 'the current IP went without a yes'
CONFIRM=y
reset; printf 'd\n1\n0\n' | f2b_allowlist_menu > /dev/null
[[ -z "$(f2b_allowlist)" ]] || fail 'confirmed removal of the current IP did not happen'
reset; printf 'a\nnot-an-ip\n0\n' | f2b_allowlist_menu > "$TEST_ROOT/out"
grep -q '格式不对' "$TEST_ROOT/out" && [[ -z "$(f2b_allowlist)" ]] || fail 'a bad address was not refused'
printf 'PASS: the allowlist menu adds the current IP by default and asks before risky changes.\n'

# The setup's single choice and every single address on the list skip the limit.
jail '198.51.100.7 203.0.113.0/24'; printf 'ufw limit 22/tcp\nufw limit 2222/tcp\n' > "$TEST_ROOT/ufw"
reset; F2B_IGNORE_CHOICE=192.0.2.44; ssh_limit_exempt
for ip in 192.0.2.44 198.51.100.7; do
  for p in 22 2222; do grep -Fxq "ufw allow from $ip to any port $p proto tcp" "$TEST_ROOT/ufw" || fail "$ip not exempt on $p"; done
done
if grep -q '203.0.113.0/24 to any' "$TEST_ROOT/ufw"; then fail 'a network was exempt'; fi
printf 'PASS: the setup choice and every single allowlisted address skip the SSH limit on every limited port.\n'
