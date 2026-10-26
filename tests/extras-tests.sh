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
load_optimizer_functions confirm kernel_cleanup auto_reboot_configure updates_stage sysctl_hardening_pairs sysctl_config_files sysctl_key_configured sysctl_hardening_stage hostname_resolves append_line_safely hosts_stage audit_ufw_ipv6 ufw_set_ipv6 f2b_jail_text f2b_jail_is_ours f2b_ignore_address port_source_valid timezone_resolve timezone_ask lock_holder_text log_rotate in_terminal_multiplexer admin_name_valid setup_questions reboot_time_normalize
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

# Old kernels: the ones APT would autoremove, purged by name, never the running
# one; other leftovers neither get removed nor block the cleanup (found on a real
# Ubuntu 24.04 VPS: libfwupd2 left by an upgrade stopped every kernel cleanup).
uname() { echo 6.1.0-28-amd64; }
SIM='' PURGE_SIM=''
apt_wait_idle() { :; }
apt-get() {
  case "$*" in
    '-s autoremove --purge') printf '%s\n' "$SIM" ;;
    '-s purge '*) printf '%s\n' "${PURGE_SIM:-$(for p in "${@:3}"; do printf 'Purg %s [1]\n' "$p"; done)}" ;;
    '-y -q -o DPkg::Lock::Timeout=120 purge '*) record "purge ${*:6}" ;;
    *) fail "unexpected apt-get $*" ;;
  esac
}
reset; SIM=$'Purg linux-image-6.1.0-18-amd64 [6.1.76-1]\nPurg linux-headers-6.1.0-18-common [6.1.76-1]'
kernel_cleanup
grep -Fxq 'purge linux-headers-6.1.0-18-common linux-image-6.1.0-18-amd64' "$TEST_ROOT/trace" || fail "old kernels not removed: $(cat "$TEST_ROOT/trace")"
reset; SIM=$'Purg linux-image-6.1.0-18-amd64 [6.1.76-1]\nPurg libfwupd2 [1.9]'
kernel_cleanup > "$TEST_ROOT/out"
grep -Fxq 'purge linux-image-6.1.0-18-amd64' "$TEST_ROOT/trace" || fail 'a leftover library blocked the kernel cleanup'
if grep -q 'libfwupd2' "$TEST_ROOT/trace"; then fail 'cleanup removed a non-kernel package'; fi
grep -q 'libfwupd2' "$TEST_ROOT/out" || fail 'leftover packages not mentioned'
reset; SIM='Purg libfwupd2 [1.9]'
kernel_cleanup > "$TEST_ROOT/out"
if grep -q '^purge' "$TEST_ROOT/trace"; then fail 'cleanup ran without an old kernel'; fi
grep -q '没有需要清理的旧内核' "$TEST_ROOT/log" || fail 'no old kernel not reported as such'
reset; SIM='Purg linux-image-6.1.0-28-amd64 [6.1.119-1]'
kernel_cleanup
if grep -q '^purge' "$TEST_ROOT/trace"; then fail 'cleanup removed the running kernel'; fi
reset; SIM='Reading package lists...'
kernel_cleanup
if grep -q '^purge' "$TEST_ROOT/trace"; then fail 'cleanup ran with nothing to remove'; fi
# The purge itself would take something else along: nothing is removed.
reset; SIM='Purg linux-image-6.1.0-18-amd64 [6.1.76-1]' PURGE_SIM=$'Purg linux-image-6.1.0-18-amd64 [1]\nPurg important-tool [2]'
kernel_cleanup
if grep -q '^purge' "$TEST_ROOT/trace"; then fail 'kernel purge that removes more than kernels was run'; fi
PURGE_SIM=''
SIM='Purg linux-image-6.1.0-18-amd64 [6.1.76-1]'
confirm_yes() { record "ask $1"; ((KEEP_ANSWER)); }
reset; KEEP_ANSWER=0; kernel_cleanup --ask
grep -q '^ask ' "$TEST_ROOT/trace" || fail 'single-item cleanup did not ask before removing kernels'
if grep -q '^purge' "$TEST_ROOT/trace"; then fail 'declined cleanup still removed kernels'; fi
reset; KEEP_ANSWER=1; kernel_cleanup --ask
grep -q '^purge ' "$TEST_ROOT/trace" || fail 'confirmed cleanup did not remove kernels'
reset; kernel_cleanup
if grep -q '^ask ' "$TEST_ROOT/trace"; then fail 'setup cleanup asked again after the up-front question'; fi
unset -f confirm_yes
printf 'PASS: old kernel cleanup removes only old kernel packages and asks first when requested.\n'

# Reboot window: written only when no other APT file sets a reboot policy.
APT_REBOOT_FILE="$TEST_ROOT/apt/53-vps-stable-auto-reboot"
mkdir -p "$TEST_ROOT/apt"
# What APT itself parsed, whatever the syntax (a block, as here) or file name.
APT_DUMP=''
apt-config() { [[ "$1" == dump ]] && printf '%s\n' "$APT_DUMP"; }
reset; AUTO_REBOOT_TIME=04:00 APT_DUMP='Unattended-Upgrade::Automatic-Reboot "false";'
auto_reboot_configure
[[ ! -e "$APT_REBOOT_FILE" ]] || fail 'an existing reboot policy (block syntax) was overridden'
grep -q '^result autoreboot preserved' "$TEST_ROOT/trace" || fail 'existing reboot policy not recorded as kept'
reset; AUTO_REBOOT_TIME=04:00 APT_DUMP=''
auto_reboot_configure
grep -Fxq 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' "$APT_REBOOT_FILE" || fail 'reboot window not written'
reset; AUTO_REBOOT_TIME=''; auto_reboot_configure
grep -q '^result autoreboot declined' "$TEST_ROOT/trace" || fail 'empty reboot time not treated as no reboot'
reset; AUTO_REBOOT_TIME='25:00'; auto_reboot_configure
grep -q '^result autoreboot failed' "$TEST_ROOT/trace" || fail 'invalid reboot time accepted'
printf 'PASS: automatic reboot window validation and writing.\n'

# Automatic updates: an existing policy APT reports (any syntax) is kept.
APT_FILE="$TEST_ROOT/apt/52-vps-stable-auto-upgrades"
AUTO_UPDATES=1
installed() { [[ "$1" == unattended-upgrades ]]; }
systemctl() { record "systemctl $*"; }
reset; APT_DUMP=$'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";'
updates_stage
[[ ! -e "$APT_FILE" ]] || fail 'an administrator policy that turned updates off was overridden'
grep -q '^result updates preserved' "$TEST_ROOT/trace" || fail 'kept update policy not recorded'
reset; APT_DUMP=''
updates_stage
grep -Fxq 'APT::Periodic::Unattended-Upgrade "1";' "$APT_FILE" || fail 'update policy not written when none existed'
reset; APT_DUMP=$'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";'
updates_stage
grep -q '^result updates present' "$TEST_ROOT/trace" || fail 'already enabled updates not recognised'
unset -f installed systemctl apt-config
printf 'PASS: automatic updates keep a policy APT already reports, in any syntax.\n'

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
OURS=0
restore_file_ours() { [[ "$1" == sysctl_file ]] && ((OURS)); }
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
# IPv6 takes accept_redirects from each interface only, and all/default never
# reach one that already exists (found on a real VPS: eth0 stayed at 1). A
# glob line covers every interface at boot; existing ones are set right away.
SYSVAL[net.ipv6.conf.all.accept_redirects]=1
SYSVAL[net.ipv6.conf.default.accept_redirects]=1
sysctl_ipv6_iface_redirects() { printf '%s\n' net.ipv6.conf.eth0.accept_redirects=1 net.ipv6.conf.lo.accept_redirects=1; }
sysctl() {
  case "$1" in
    -n) [[ -n "${SYSVAL[$2]:-}" ]] && echo "${SYSVAL[$2]}" ;;
    -e|-w) record "sysctl $*" ;;
    *) fail "unexpected sysctl $*" ;;
  esac
}
reset; SYSCTL_CHOICE=1; rm -f "$SYSCTL_HARDENING_FILE"
sysctl_hardening_stage
grep -Fxq 'net.ipv6.conf.*.accept_redirects = 0' "$SYSCTL_HARDENING_FILE" || fail 'IPv6 per-interface glob not written'
grep -Fxq 'orig net.ipv6.conf.eth0.accept_redirects=1' "$TEST_ROOT/trace" || fail 'interface original not recorded for rollback'
grep -Fxq 'sysctl -w net.ipv6.conf.eth0.accept_redirects=0' "$TEST_ROOT/trace" || fail 'existing interface not switched now'
# The administrator's own IPv6 redirect policy: no glob on top of it.
reset; rm -f "$SYSCTL_HARDENING_FILE"; CONFIGURED=net.ipv6.conf.all.accept_redirects
sysctl_hardening_stage
if grep -Fq 'conf.*' "$SYSCTL_HARDENING_FILE"; then fail 'glob written although IPv6 redirects are configured elsewhere'; fi
if grep -q 'sysctl -w' "$TEST_ROOT/trace"; then fail 'interfaces changed although IPv6 redirects are configured elsewhere'; fi
CONFIGURED=kernel.dmesg_restrict
# Upgraded from 2.7.1: this tool's own older file (no glob line) is replaced,
# not reported as a conflict; a file that is not ours is still left alone.
printf '# VPS Stable Optimizer v2.6: network hardening\nkernel.kptr_restrict = 2\n' > "$SYSCTL_HARDENING_FILE"
reset; OURS=1
sysctl_hardening_stage
grep -Fxq 'net.ipv6.conf.*.accept_redirects = 0' "$SYSCTL_HARDENING_FILE" || fail "this tool's older file not brought up to date"
grep -q '^result sysctl applied' "$TEST_ROOT/trace" || fail 'updated own file not recorded as applied'
printf 'kernel.kptr_restrict = 1\n' > "$SYSCTL_HARDENING_FILE"
reset; OURS=0
sysctl_hardening_stage
[[ "$(cat "$SYSCTL_HARDENING_FILE")" == 'kernel.kptr_restrict = 1' ]] || fail 'a file that is not ours was replaced'
grep -q '^result sysctl preserved' "$TEST_ROOT/trace" || fail 'foreign file not reported as kept'
rm -f "$SYSCTL_HARDENING_FILE"
unset 'SYSVAL[net.ipv6.conf.all.accept_redirects]' 'SYSVAL[net.ipv6.conf.default.accept_redirects]'
unset -f sysctl_ipv6_iface_redirects
(
  load_optimizer_functions sysctl_ipv6_iface_redirects
  P="$TEST_ROOT/proc-ipv6"
  for d in all default eth0 veth-a1 eth0.100; do mkdir -p "$P/$d"; printf '1\n' > "$P/$d/accept_redirects"; done
  # all/default are separate keys; a dotted VLAN name cannot be a dotted sysctl key.
  out="$(sysctl_ipv6_iface_redirects "$P" | sort | tr '\n' ' ')"
  [[ "$out" == 'net.ipv6.conf.eth0.accept_redirects=1 net.ipv6.conf.veth-a1.accept_redirects=1 ' ]] || fail "interface list: $out"
)
printf 'PASS: sysctl hardening keeps foreign keys, skips absent keys, records originals and reaches every IPv6 interface.\n'

# Real sysctl_key_configured against fixture files.
(
  load_optimizer_functions sysctl_key_configured
  printf 'net/ipv4/tcp_syncookies = 0\n' > "$TEST_ROOT/fixture.conf"
  # The scan reads its file list from sysctl_config_files.
  sysctl_config_files() { printf '%s\n' "$TEST_ROOT/fixture.conf" /nonexistent/sysctl.d/*.conf; }
  sysctl_key_configured net.ipv4.tcp_syncookies || fail 'slash-notation key not detected'
  if sysctl_key_configured kernel.kptr_restrict; then fail 'unrelated key detected'; fi
  # A glob policy (all interfaces) covers the key; comments do not count.
  printf '# kernel.kptr_restrict = 0\nnet.ipv4.conf.*.accept_redirects = 1\n' > "$TEST_ROOT/fixture.conf"
  sysctl_key_configured net.ipv4.conf.all.accept_redirects || fail 'administrator glob policy not detected'
  if sysctl_key_configured kernel.kptr_restrict; then fail 'a commented-out key counted as configured'; fi
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
  # 4:00 is the same time as 04:00, the form unattended-upgrades expects.
  printf '4:00\nops\n' > "$TEST_ROOT/q-input"
  setup_questions < "$TEST_ROOT/q-input" > "$TEST_ROOT/q-out"
  [[ "$INSTALL_TOOLS" == 1 && "$VNSTAT_CHOICE" == 0 && "$KERNEL_CLEAN_CHOICE" == 0 ]] || fail 'tool/vnstat/kernel choices'
  [[ "$AUTO_REBOOT_TIME" == 04:00 && "$ZRAM_CHOICE" == 0 && "$SYSCTL_CHOICE" == 1 ]] || fail 'reboot/zram/sysctl choices'
  [[ "$SSH_CHOICE" == 1 && "$ADMIN_CHOICE" == 1 && "$ADMIN_NAME" == ops ]] || fail 'SSH/admin choices'
  [[ "$WEB_CHOICE" == 0 && "$F2B_IGNORE_CHOICE" == none && "$TZ_CHOICE" == Asia/Shanghai && "$TZ_ASKED" == 1 ]] || fail 'web/allowlist/timezone choices'
  grep -Fq '需要你在场' "$TEST_ROOT/q-out" || fail 'user not told the end needs them'
)
printf 'PASS: setup questions are asked once and stored.\n'

# ZRAM on Ubuntu, found on a real Ubuntu 24.04 VPS: the cloud kernel has no zram
# module, and its zram-generator package installs the default "[zram0]" right at
# /etc/systemd/zram-generator.conf (Debian 13 keeps it in /usr/lib), which this
# tool then refused to overwrite.
(
  load_optimizer_functions zram_stage zram_file_packaged
  ZRAM_FILE="$TEST_ROOT/zram/zram-generator.conf"
  ZRAM_VENDOR_FILE="$TEST_ROOT/zram/no-vendor-file"
  mkdir -p "$TEST_ROOT/zram"
  MEM_MIB=1024 ZRAM_CHOICE=0 MODULE=1 SWAP_ON=0 VENDOR_ONLY=0 OURS=0
  zram_module_available() { ((MODULE)); }
  swap_exists() { [[ -e "$ZRAM_FILE" ]] || ((SWAP_ON)); }
  swapon() { if ((SWAP_ON)); then echo /dev/zram0; fi; }
  zram_swap_active() { ((SWAP_ON)); }
  zram_vendor_default_only() { ((VENDOR_ONLY)); }
  restore_file_ours() { ((OURS)); }
  available() { return 0; }
  # The Ubuntu package brings its own default config with it.
  install_pkgs() { record "install $*"; [[ -e "$ZRAM_FILE" ]] || printf '[zram0]\n' > "$ZRAM_FILE"; }
  conffile_unchanged() { [[ "$(cat -- "$1")" == '[zram0]' ]]; }
  zram_start() { record 'zram start'; }
  zram_tune() { record 'zram tune'; }
  systemctl() { record "systemctl $*"; }
  # No zram module: nothing installed, nothing written, reported as unsupported.
  reset; MODULE=0
  zram_stage > /dev/null
  grep -q '^result zram unsupported' "$TEST_ROOT/trace" || fail 'missing zram module not reported as unsupported'
  if grep -q '^install' "$TEST_ROOT/trace" || [[ -e "$ZRAM_FILE" ]]; then fail 'ZRAM set up on a kernel without zram'; fi
  # The packaged default that appears with the package is replaced and started.
  reset; MODULE=1
  zram_stage > /dev/null
  grep -Fxq 'compression-algorithm = zstd' "$ZRAM_FILE" || fail "the package's default file was not replaced by this tool's config"
  grep -Fxq 'zram start' "$TEST_ROOT/trace" || fail 'ZRAM not started after replacing the packaged default'
  grep -q '^result zram applied' "$TEST_ROOT/trace" || fail 'ZRAM not recorded as applied'
  # The packaged default left behind with no swap running (a run before this
  # fix): taken over even without an explicit request, and started now.
  reset; printf '[zram0]\n' > "$ZRAM_FILE"; VENDOR_ONLY=1
  zram_stage > /dev/null
  grep -Fxq 'compression-algorithm = zstd' "$ZRAM_FILE" || fail 'packaged default without a running swap not taken over'
  grep -Fxq 'zram start' "$TEST_ROOT/trace" || fail 'taken-over ZRAM not started'
  # A packaged default that is running stays unless ZRAM was asked for.
  reset; printf '[zram0]\n' > "$ZRAM_FILE"; SWAP_ON=1
  zram_stage > /dev/null
  [[ "$(cat "$ZRAM_FILE")" == '[zram0]' ]] || fail 'a running packaged default was replaced without being asked'
  # This tool's own config whose ZRAM cannot start: told why, not retried.
  reset; SWAP_ON=0 VENDOR_ONLY=0 OURS=1 MODULE=0
  printf '[zram0]\nzram-size = ram / 2\n' > "$ZRAM_FILE"
  zram_stage > /dev/null
  grep -q '^result zram unsupported' "$TEST_ROOT/trace" || fail 'own config on a kernel without zram not explained'
  if grep -Fxq 'zram start' "$TEST_ROOT/trace"; then fail 'tried to start ZRAM without the module'; fi
  # zram_file_packaged: only the unchanged packaged file counts.
  printf '[zram0]\n' > "$ZRAM_FILE"
  zram_file_packaged || fail 'unchanged packaged default not recognised'
  printf '[zram0]\nzram-size = 512\n' > "$ZRAM_FILE"
  if zram_file_packaged; then fail 'an edited ZRAM config counted as the package default'; fi
)
printf 'PASS: ZRAM is skipped without a zram module and replaces only an unchanged packaged default.\n'
