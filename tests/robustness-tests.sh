#!/usr/bin/env bash
# Tests for the fixes from the code reviews: hand-made changes no longer block
# a step, btrfs inode reporting, an empty authorized_keys, waiting for the
# APT/dpkg locks, refreshing an empty package index before installing sudo,
# and the reboot offer after the single-item menu.
# Every system command is a mock; files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions restore_ids restore_before_stage preflight_block preflight_report audit_disk_risks coreutils_selfcheck admin_prepare item_main ssh_key_count apt_locks_held apt_wait_idle reboot_reason reboot_main
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$T/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$T/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$T/trace"; }
reset() { : > "$T/trace"; : > "$T/log"; }

# A hand-made change does not block the step any more: rollback always returns
# to the state before the tool's first run. A damaged rollback record still does.
RESTORE_READY=1 RESTORE_ROOT="$T/restore" BAD_STATE=0
declare -A NOW=() LAST=()
restore_snapshot() { return 0; }
restore_fingerprint() { echo "value:${NOW[$1]:-same}"; }
restore_read() {
  case "$2" in
    last_fp) echo "value:${LAST[$1]:-same}" ;;
    state) if ((BAD_STATE)); then echo damaged; else echo applied; fi ;;
  esac
}
restore_label() { printf '%s' "$1"; }
reset; NOW=([cc]=cubic) LAST=([cc]=bbr)
restore_before_stage bbr || fail 'a hand-made change blocked a setup step'
[[ "$RESTORE_STAGE" == bbr ]] || fail 'step not tracked for rollback'
grep -Fq '手动改过' "$T/log" || fail 'hand-made change not mentioned'
reset; NOW=([ufw_runtime]=inactive) LAST=([ufw_runtime]=active)
restore_before_stage apt_upgrade || fail 'a manual ufw disable skipped the whole upgrade step'
reset; NOW=() LAST=() BAD_STATE=1
if restore_before_stage bbr; then fail 'a damaged rollback record did not block the step'; fi
BAD_STATE=0
printf 'PASS: hand-made changes no longer block a step; a damaged rollback record still does.\n'

# btrfs reports 0 inodes and "-": not an inode shortage and not an unknown state.
# A package lock at health-check time is a warning: the APT steps wait for it.
support_lifecycle_report() { :; }
apt_sources_report() { :; }
dpkg() { return 0; }
LOCKS=''
lslocks() { printf '%s\n' "$LOCKS"; }
findmnt() { case "$*" in *TARGET*) echo / ;; *OPTIONS*) echo rw,relatime ;; esac; }
df() {
  case "$1" in
    -Pm) printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n/dev/vda2 20000 5000 15000 25%% /\n' ;;
    -Pi) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n%s\n' "$INODE_LINE" ;;
  esac
}
reset; INODE_LINE='/dev/vda2 0 0 0 - /'
preflight_report > "$T/out"
[[ "$PREFLIGHT_BLOCKERS" == 0 ]] || fail "btrfs blocked by an inode check: $(cat "$T/log")"
grep -Fq '不限' "$T/out" || fail 'btrfs inode line not explained'
reset; INODE_LINE='/dev/vda1 1000 995 5 100% /'
preflight_report > "$T/out"
((PREFLIGHT_BLOCKERS >= 1)) || fail 'a real inode shortage was not blocked'
reset; INODE_LINE='/dev/vda1 1310720 81234 1229486 7% /' LOCKS='/var/lib/dpkg/lock-frontend'
preflight_report > "$T/out"
[[ "$PREFLIGHT_BLOCKERS" == 0 ]] || fail 'a busy package lock blocked setup instead of being waited for'
grep -Fq '等它结束' "$T/log" || fail 'busy package lock not explained'
LOCKS=''
[[ -z "$(printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/vda2 0 0 0 - /\n' | audit_disk_risks inode)" ]] || fail 'btrfs inode line reported as unknown or full'
unset -f df
if [[ "$(uname -o 2>/dev/null)" == Msys ]]; then
  printf 'SKIP: coreutils self-check on btrfs needs Linux permissions (Windows Git Bash cannot chmod).\n'
else
  df() { if [[ "$*" == '-Pi /' ]]; then printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/vda2 0 0 0 - /\n'; else command df "$@"; fi; }
  coreutils_selfcheck || fail 'coreutils self-check rejects a btrfs root'
  unset -f df
fi
printf 'PASS: btrfs (dynamic inodes) is neither blocked nor reported as unknown; a busy package lock only warns.\n'

# APT steps wait while another program (the automatic update) holds the locks.
# lslocks runs inside $(...): the remaining busy answers live in a file.
lslocks() { if [[ -s "$T/busy" ]]; then sed -i '1d' "$T/busy"; echo '/var/lib/dpkg/lock-frontend'; fi; }
sleep() { record sleep; }
reset; printf 'busy\nbusy\n' > "$T/busy"
apt_wait_idle > "$T/out"
[[ "$(grep -c '^sleep$' "$T/trace")" == 2 ]] || fail 'did not wait while the package lock was held'
[[ "$(grep -c '等它结束' "$T/out")" == 1 ]] || fail 'waiting message missing or repeated'
reset; : > "$T/busy"
apt_wait_idle > "$T/out"
[[ ! -s "$T/trace" && ! -s "$T/out" ]] || fail 'waited although no lock was held'
unset -f sleep
printf 'PASS: APT steps wait for the automatic update to release its locks.\n'

# An authorized_keys without a valid key (empty or comment-only, common on VPS
# images) counts as 0 keys instead of aborting the run under set -e.
if command -v ssh-keygen >/dev/null; then
  : > "$T/empty_keys"
  count="$(ssh_key_count "$T/empty_keys")"
  [[ "$count" == 0 ]] || fail "empty authorized_keys counted as $count"
  printf '# keys are managed by the provider\n' > "$T/comment_keys"
  count="$(ssh_key_count "$T/comment_keys")"
  [[ "$count" == 0 ]] || fail "comment-only authorized_keys counted as $count"
  printf 'PASS: an empty or comment-only authorized_keys counts as 0 keys and does not abort.\n'
else
  printf 'SKIP: ssh-keygen unavailable.\n'
fi

# sudo on a fresh image with an empty package index: refresh once, then install.
getent() { [[ "$1 $2" == 'passwd ops' ]] && echo 'ops:x:1001:1001::/home/ops:/bin/bash'; }
command() { if [[ "$1" == -v && "${2:-}" == sudo ]]; then return 1; fi; builtin command "$@"; }
available() { record "available $1"; [[ -e "$T/index" ]]; }
apt_index_ready() { record refresh; : > "$T/index"; }
install_pkgs() { record "install $*"; }
id() { echo 'ops sudo'; }
console_password_state() { echo P; }
useradd() { record useradd; }
usermod() { record usermod; }
passwd() { :; }
reset; rm -f -- "$T/index"
admin_prepare ops > /dev/null || fail 'admin account not prepared after refreshing the index'
grep -Fxq refresh "$T/trace" && grep -Fxq 'install sudo' "$T/trace" || fail "empty index not refreshed before installing sudo: $(tr '\n' ' ' < "$T/trace")"
reset
admin_prepare ops > /dev/null || fail 'admin account not prepared with a ready index'
if grep -Fxq refresh "$T/trace"; then fail 'package index refreshed although sudo was available'; fi
unset -f command
printf 'PASS: an empty package index is refreshed once before sudo is reported missing.\n'

# Single-item menu: a reboot is offered only for an upgrade made in this session.
eval "$(declare -f item_main | sed '/EUID/d')"
validate_vm() { :; }; start_logging() { :; }; prepare_run_state() { :; }; stage_run() { :; }
restore_prepare() { :; }; finish_run_state() { :; }
offer_reboot() { record offer; }
item_menu() { record menu; UPGRADE_APPROVED="$U" KERNEL_UPDATE="$K"; }
reset; UPGRADE_APPROVED=0 KERNEL_UPDATE=0 U=1 K=1
item_main > /dev/null
[[ "$(cat "$T/trace")" == $'menu\noffer' ]] || fail "kernel upgrade in this session: $(tr '\n' ' ' < "$T/trace")"
reset; U=0 K=0
item_main > /dev/null
if grep -Fxq offer "$T/trace"; then fail 'reboot offered although nothing was upgraded in this session'; fi
printf 'PASS: single-item menu offers a reboot only after its own upgrade.\n'

# Menu 11 / vps reboot: says why a reboot is (not) needed, refuses while an SSH
# protection timer or a package installation is still running, asks first.
mkdir -p "$T/boot"; : > "$T/boot/vmlinuz-6.1.0-9-amd64"; : > "$T/boot/vmlinuz-6.1.0-10-amd64"
uname() { echo 6.1.0-9-amd64; }
[[ "$(reboot_reason "$T/boot" "$T/no-flag")" == *'新内核 6.1.0-10-amd64'* ]] || fail 'a newer installed kernel was not named'
uname() { echo 6.1.0-10-amd64; }
[[ "$(reboot_reason "$T/boot" "$T/no-flag")" == *'不重启也可以'* ]] || fail 'no reboot need was not explained'
: > "$T/reboot-flag"
[[ "$(reboot_reason "$T/boot" "$T/reboot-flag")" == *'系统提示需要重启'* ]] || fail 'reboot-required flag ignored'
unset -f uname
eval "$(declare -f reboot_main | sed '/EUID/d; /\[\[ -t 0 \]\]/d')"
reboot_reason() { echo reason; }
tool_lifecycle_lock() { :; }
tool_no_pending_firewall() { ((NO_PENDING)); }
apt_wait_idle() { record wait; }
apt_locks_held() { ((LOCKED)); }
confirm_yes() { record ask; ((YES)); }
sync() { :; }
systemctl() { record "systemctl $*"; }
try_reboot() { ( die() { record "die $1"; exit 1; }; reboot_main ) > /dev/null || true; }
reset; NO_PENDING=0 LOCKED=0 YES=1; try_reboot
grep -q '^die .*防失联确认' "$T/trace" || fail 'reboot not refused while an SSH protection timer is pending'
if grep -q 'systemctl reboot' "$T/trace"; then fail 'rebooted during a pending protection timer'; fi
reset; NO_PENDING=1 LOCKED=1; try_reboot
grep -q '^die .*安装或更新软件' "$T/trace" || fail 'reboot not refused while APT is busy'
if grep -q 'systemctl reboot' "$T/trace"; then fail 'rebooted while APT was busy'; fi
reset; LOCKED=0 YES=0; try_reboot
grep -Fxq ask "$T/trace" || fail 'reboot did not ask first'
if grep -q 'systemctl reboot' "$T/trace"; then fail 'rebooted after a no'; fi
reset; YES=1; try_reboot
grep -Fxq 'systemctl reboot' "$T/trace" || fail 'confirmed reboot did not run'
printf 'PASS: reboot explains the need, waits for or refuses busy states, and asks before rebooting.\n'
