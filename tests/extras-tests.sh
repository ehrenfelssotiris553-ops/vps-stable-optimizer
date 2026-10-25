#!/usr/bin/env bash
# Tests for the V2.6 additions: kernel cleanup, reboot window, sysctl hardening,
# hosts fix, UFW IPv6 switch, Fail2ban allowlist, timezone lookup, confirmation
# hints, lock owner text, log rotation, tmux detection and the setup questions.
# Every system command is a mock; all files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions confirm kernel_cleanup auto_reboot_configure sysctl_hardening_pairs sysctl_key_configured sysctl_hardening_stage hostname_resolves append_line_safely hosts_stage audit_ufw_ipv6 ufw_set_ipv6 f2b_jail_text f2b_jail_is_ours f2b_ignore_address port_source_valid timezone_resolve timezone_ask lock_holder_text log_rotate in_terminal_multiplexer admin_name_valid setup_questions
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
module_result() { record "result $1 $2 ${3:-}"; }
backup_config_path() { :; }
record_config_change() { :; }
restore_record_hosts_line() { :; }
put_file() { [[ ! -e "$1" ]] || return 1; mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }

# Old kernels: only kernel packages, never the running one, else skipped.
uname() { echo 6.1.0-28-amd64; }
SIM=''
apt_wait_idle() { :; }
apt-get() {
  case "$*" in
    '-s autoremove --purge') printf '%s\n' "$SIM" ;;
    '-y -q -o DPkg::Lock::Timeout=120 autoremove --purge') record 'autoremove' ;;
    *) fail "unexpected apt-get $*" ;;
  esac
}
reset; SIM=$'Purg linux-image-6.1.0-18-amd64 [6.1.76-1]\nPurg linux-headers-6.1.0-18-common [6.1.76-1]'
kernel_cleanup
grep -Fxq autoremove "$TEST_ROOT/trace" || fail 'old kernels not removed'
reset; SIM=$'Purg linux-image-6.1.0-18-amd64 [6.1.76-1]\nPurg libfoo1 [1.0]'
kernel_cleanup
if grep -Fxq autoremove "$TEST_ROOT/trace"; then fail 'cleanup removed a non-kernel package'; fi
reset; SIM='Purg linux-image-6.1.0-28-amd64 [6.1.119-1]'
kernel_cleanup
if grep -Fxq autoremove "$TEST_ROOT/trace"; then fail 'cleanup removed the running kernel'; fi
reset; SIM='Reading package lists...'
kernel_cleanup
if grep -Fxq autoremove "$TEST_ROOT/trace"; then fail 'cleanup ran with nothing to remove'; fi
SIM='Purg linux-image-6.1.0-18-amd64 [6.1.76-1]'
confirm_yes() { record "ask $1"; ((KEEP_ANSWER)); }
reset; KEEP_ANSWER=0; kernel_cleanup --ask
grep -q '^ask ' "$TEST_ROOT/trace" || fail 'single-item cleanup did not ask before removing kernels'
if grep -Fxq autoremove "$TEST_ROOT/trace"; then fail 'declined cleanup still removed kernels'; fi
reset; KEEP_ANSWER=1; kernel_cleanup --ask
grep -Fxq autoremove "$TEST_ROOT/trace" || fail 'confirmed cleanup did not remove kernels'
reset; kernel_cleanup
if grep -q '^ask ' "$TEST_ROOT/trace"; then fail 'setup cleanup asked again after the up-front question'; fi
unset -f confirm_yes
printf 'PASS: old kernel cleanup removes only old kernel packages and asks first when requested.\n'

# Reboot window: written only when no other APT file sets a reboot policy.
APT_REBOOT_FILE="$TEST_ROOT/apt/53-vps-stable-auto-reboot"
mkdir -p "$TEST_ROOT/apt"
reset; AUTO_REBOOT_TIME=04:00
auto_reboot_configure
grep -Fxq 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' "$APT_REBOOT_FILE" || fail 'reboot window not written'
reset; AUTO_REBOOT_TIME=''; auto_reboot_configure
grep -q '^result autoreboot declined' "$TEST_ROOT/trace" || fail 'empty reboot time not treated as no reboot'
reset; AUTO_REBOOT_TIME='25:00'; auto_reboot_configure
grep -q '^result autoreboot failed' "$TEST_ROOT/trace" || fail 'invalid reboot time accepted'
printf 'PASS: automatic reboot window validation and writing.\n'

# sysctl hardening: keys set elsewhere are kept, originals recorded after writing.
SYSCTL_HARDENING_FILE="$TEST_ROOT/sysctl/98-vps-stable-hardening.conf"
declare -A SYSVAL=([net.ipv4.tcp_syncookies]=1 [kernel.kptr_restrict]=0 [kernel.dmesg_restrict]=0 [net.ipv4.conf.all.accept_redirects]=1)
sysctl() {
  case "$1" in
    -n) [[ -n "${SYSVAL[$2]:-}" ]] && echo "${SYSVAL[$2]}" ;;
    -e) record "sysctl $*" ;;
    *) fail "unexpected sysctl $*" ;;
  esac
}
CONFIGURED=kernel.dmesg_restrict
sysctl_key_configured() { [[ "$1" == "$CONFIGURED" ]]; }
restore_record_sysctl() { record "orig $1=$2"; }
reset; SYSCTL_CHOICE=1
sysctl_hardening_stage
grep -Fxq 'kernel.kptr_restrict = 2' "$SYSCTL_HARDENING_FILE" || fail 'hardening value not written'
if grep -Fq dmesg_restrict "$SYSCTL_HARDENING_FILE"; then fail 'key configured elsewhere was overridden'; fi
if grep -Fq 'icmp_echo_ignore_broadcasts' "$SYSCTL_HARDENING_FILE"; then fail 'key absent on this kernel was written'; fi
grep -Fxq 'orig kernel.kptr_restrict=0' "$TEST_ROOT/trace" || fail 'original running value not recorded'
if grep -q 'ip_forward' "$SYSCTL_HARDENING_FILE"; then fail 'forwarding must not be changed (Docker/WireGuard)'; fi
reset; SYSCTL_CHOICE=0; rm -f "$SYSCTL_HARDENING_FILE"
sysctl_hardening_stage
[[ ! -e "$SYSCTL_HARDENING_FILE" ]] || fail 'sysctl changed without consent'
printf 'PASS: sysctl hardening keeps foreign keys, skips absent keys and records originals.\n'

# Real sysctl_key_configured against fixture files.
(
  load_optimizer_functions sysctl_key_configured
  printf 'net/ipv4/tcp_syncookies = 0\n' > "$TEST_ROOT/fixture.conf"
  # Redirect the scan by shadowing the glob through a temporary function copy.
  eval "$(declare -f sysctl_key_configured | sed "s#/etc/sysctl.conf /etc/sysctl.d/\*.conf /run/sysctl.d/\*.conf /usr/local/lib/sysctl.d/\*.conf /usr/lib/sysctl.d/\*.conf /lib/sysctl.d/\*.conf#$TEST_ROOT/fixture.conf#")"
  sysctl_key_configured net.ipv4.tcp_syncookies || fail 'slash-notation key not detected'
  if sysctl_key_configured kernel.kptr_restrict; then fail 'unrelated key detected'; fi
)

# /etc/hosts: appended only with consent and when the name does not resolve.
(
  RESOLVES=0
  getent() { ((RESOLVES)); }
  hostname() { echo vps-1; }
  printf '127.0.0.1 localhost\n' > "$TEST_ROOT/hosts"
  eval "$(declare -f hosts_stage | sed "s#/etc/hosts#$TEST_ROOT/hosts#g")"
  reset; HOSTS_CHOICE=0; hosts_stage
  [[ "$(grep -c . "$TEST_ROOT/hosts")" == 1 ]] || fail 'hosts changed without consent'
  reset; HOSTS_CHOICE=1
  printf() { builtin printf "$@"; if [[ "${2:-}" == $'127.0.1.1\tvps-1' ]]; then RESOLVES=1; fi; }
  hosts_stage
  grep -Fxq $'127.0.1.1\tvps-1' "$TEST_ROOT/hosts" || fail 'hostname line not added'
  # A last line without a newline must not swallow the new entry.
  builtin printf '127.0.0.1 localhost\n::1 localhost' > "$TEST_ROOT/hosts"
  reset; RESOLVES=0; hosts_stage
  grep -Fxq '::1 localhost' "$TEST_ROOT/hosts" || fail 'unterminated last line was merged with the new entry'
  grep -Fxq $'127.0.1.1\tvps-1' "$TEST_ROOT/hosts" || fail 'entry not on its own line'
)
printf 'PASS: hosts fix needs consent, appends the Debian-style line and keeps an unterminated last line intact.\n'

# UFW IPV6 switch rewrites exactly one simple assignment.
(
  printf 'IPV6=no\nDEFAULT_INPUT_POLICY="DROP"\n' > "$TEST_ROOT/ufw"
  eval "$(declare -f ufw_set_ipv6 | sed "s#file=/etc/default/ufw#file=$TEST_ROOT/ufw#")"
  ufw_set_ipv6 yes || fail 'IPV6 switch failed'
  [[ "$(audit_ufw_ipv6 < "$TEST_ROOT/ufw")" == yes ]] || fail 'IPV6 not switched on'
  grep -Fxq 'DEFAULT_INPUT_POLICY="DROP"' "$TEST_ROOT/ufw" || fail 'other settings changed'
  if ufw_set_ipv6 maybe; then fail 'invalid IPV6 value accepted'; fi
  printf 'IPV6=yes\nIPV6=no\n' > "$TEST_ROOT/ufw"
  if ufw_set_ipv6 yes; then fail 'ambiguous duplicate IPV6 lines rewritten'; fi
)
printf 'PASS: UFW IPv6 switch edits only an unambiguous assignment.\n'

# Fail2ban allowlist: optional, validated, and the managed jail is still ours.
jail="$(f2b_jail_text 22 203.0.113.9)"
grep -Fxq 'ignoreip = 127.0.0.1/8 ::1 203.0.113.9' <<< "$jail" || fail 'allowlist line missing'
f2b_jail_is_ours "$jail" 22 || fail 'managed jail with allowlist not recognised'
f2b_jail_is_ours "$(f2b_jail_text 22)" 22 || fail 'managed jail without allowlist not recognised'
if f2b_jail_is_ours "$(f2b_jail_text 2222)" 22; then fail 'jail for other ports treated as current'; fi
SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
F2B_IGNORE_CHOICE=none; [[ -z "$(f2b_ignore_address)" ]] || fail 'declined allowlist still returned an address'
F2B_IGNORE_CHOICE=198.51.100.4; [[ "$(f2b_ignore_address)" == 198.51.100.4 ]] || fail 'chosen allowlist address'
F2B_IGNORE_CHOICE='1.2.3.4;id'; [[ -z "$(f2b_ignore_address || true)" ]] || fail 'invalid allowlist address accepted'
printf 'PASS: Fail2ban allowlist is optional and validated.\n'

# Timezone lookup: exact, case-insensitive, and suggestions on a miss.
timedatectl() {
  case "$*" in
    list-timezones) printf '%s\n' Asia/Shanghai Asia/Hong_Kong Europe/London UTC ;;
    'show -p Timezone --value') echo UTC ;;
    *) fail "unexpected timedatectl $*" ;;
  esac
}
[[ "$(timezone_resolve Asia/Shanghai)" == Asia/Shanghai ]] || fail 'exact timezone'
[[ "$(timezone_resolve asia/shanghai)" == Asia/Shanghai ]] || fail 'case-insensitive timezone'
if timezone_resolve 'Asia/Shanghai;id' >/dev/null; then fail 'unsafe timezone text accepted'; fi
reset; printf 'Shanghai\nasia/shanghai\n' > "$TEST_ROOT/tz-input"
timezone_ask < "$TEST_ROOT/tz-input"
[[ "$TZ_CHOICE" == Asia/Shanghai ]] || fail 'timezone not resolved after a suggestion'
grep -Fq 'Asia/Shanghai' "$TEST_ROOT/log" || fail 'no suggestion for a partial timezone name'
printf '\n' > "$TEST_ROOT/tz-input"; timezone_ask < "$TEST_ROOT/tz-input"
[[ -z "$TZ_CHOICE" ]] || fail 'Enter did not keep the timezone'
# Common zones are offered by number: 1 is Asia/Shanghai, 2 Asia/Hong_Kong.
printf '1\n' > "$TEST_ROOT/tz-input"; timezone_ask < "$TEST_ROOT/tz-input" > "$TEST_ROOT/tz-menu"
[[ "$TZ_CHOICE" == Asia/Shanghai ]] || fail 'menu number 1 did not choose Asia/Shanghai'
grep -Fq '北京时间' "$TEST_ROOT/tz-menu" || fail 'common timezone list not shown'
printf '02\n' > "$TEST_ROOT/tz-input"; timezone_ask < "$TEST_ROOT/tz-input" > /dev/null
[[ "$TZ_CHOICE" == Asia/Hong_Kong ]] || fail 'a leading zero broke the menu number'
printf '99\nEurope/London\n' > "$TEST_ROOT/tz-input"; timezone_ask < "$TEST_ROOT/tz-input" > /dev/null
[[ "$TZ_CHOICE" == Europe/London ]] || fail 'an out-of-range number was not asked again'
printf 'PASS: timezone lookup with a numbered list of common zones and suggestions.\n'

# Confirmation words explain near misses instead of silently cancelling.
if ! [[ -t 0 ]]; then
  # confirm requires a terminal; emulate one by replacing the -t test.
  eval "$(declare -f confirm | sed 's/\[\[ -t 0 \]\] || return 1/:/')"
fi
out="$(printf 'apply\n' | confirm '开始？' APPLY || true)"
[[ "$out" == *大写* ]] || fail 'lower-case confirmation not explained'
out="$(printf 'yes\n' | confirm '开始？' APPLY || true)"
[[ "$out" == *不是\ APPLY* ]] || fail 'wrong confirmation not explained'
printf 'APPLY\n' | confirm '开始？' APPLY >/dev/null || fail 'exact confirmation rejected'
printf 'PASS: confirmation words explain near misses.\n'

# Lock owner text names the running task, or falls back when stale.
LOCK_OWNER_FILE="$TEST_ROOT/owner"
printf 'port %s\n' "$$" > "$LOCK_OWNER_FILE"
[[ "$(lock_holder_text)" == *端口管理* ]] || fail 'lock holder not named'
printf 'port 999999\n' > "$LOCK_OWNER_FILE"
[[ "$(lock_holder_text)" != *PID* ]] || fail 'stale lock owner reported as running'
printf 'item %s\n' "$$" > "$LOCK_OWNER_FILE"
[[ "$(lock_holder_text)" == *单项设置* ]] || fail 'single-item menu not named in the lock message'
printf 'PASS: lock message names the running task.\n'

# Log rotation keeps the newest files per prefix.
LOG_DIR="$TEST_ROOT/logs"; mkdir -p "$LOG_DIR"
for i in 1 2 3 4 5; do : > "$LOG_DIR/port-$i.log"; touch -d "2026-10-0$i" "$LOG_DIR/port-$i.log"; done
: > "$LOG_DIR/run-setup.log"
log_rotate 'port-*.log' 3
[[ "$(ls "$LOG_DIR" | tr '\n' ' ')" == 'port-4.log port-5.log run-setup.log ' ]] || fail "rotation result: $(ls "$LOG_DIR" | tr '\n' ' ')"
printf 'PASS: log rotation is per prefix and keeps setup logs.\n'

# tmux/screen detection via environment.
TMUX=/tmp/tmux-0/default,1,0; in_terminal_multiplexer || fail 'TMUX not detected'
unset TMUX; STY=123.pts-0; in_terminal_multiplexer || fail 'screen not detected'
unset STY
printf 'PASS: terminal multiplexer detection.\n'

# Setup questions are all asked up front and stored.
(
  confirm_yes() {
    case "$1" in
      *常用工具*|*SSH\ 登录*|*管理员*|*内核网络安全*) return 0 ;;
      *) return 1 ;;
    esac
  }
  confirm_default_yes() { case "$1" in *内核网络安全*) return 0 ;; *) return 1 ;; esac; }
  swap_exists() { return 1; }
  hostname_resolves() { return 0; }
  timezone_ask() { TZ_CHOICE=Asia/Shanghai; }
  logname() { echo root; }
  SUDO_USER='' UPGRADE_APPROVED=1 AUTO_UPDATES=1 MEM_MIB=4096 INSTALL_TOOLS=0 ADMIN_NAME=''
  SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
  TOOLS_PACKAGES=(curl)
  printf '04:00\nops\n' > "$TEST_ROOT/q-input"
  setup_questions < "$TEST_ROOT/q-input" > "$TEST_ROOT/q-out"
  [[ "$INSTALL_TOOLS" == 1 && "$VNSTAT_CHOICE" == 0 && "$KERNEL_CLEAN_CHOICE" == 0 ]] || fail 'tool/vnstat/kernel choices'
  [[ "$AUTO_REBOOT_TIME" == 04:00 && "$ZRAM_CHOICE" == 0 && "$SYSCTL_CHOICE" == 1 ]] || fail 'reboot/zram/sysctl choices'
  [[ "$SSH_CHOICE" == 1 && "$ADMIN_CHOICE" == 1 && "$ADMIN_NAME" == ops ]] || fail 'SSH/admin choices'
  [[ "$WEB_CHOICE" == 0 && "$F2B_IGNORE_CHOICE" == none && "$TZ_CHOICE" == Asia/Shanghai && "$TZ_ASKED" == 1 ]] || fail 'web/allowlist/timezone choices'
  grep -Fq '需要你在场' "$TEST_ROOT/q-out" || fail 'user not told the end needs them'
)
printf 'PASS: setup questions are asked once and stored.\n'
