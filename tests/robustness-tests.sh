#!/usr/bin/env bash
# Tests for the fixes from the full code review: hand-made changes taken as the
# new baseline, btrfs inode reporting, refreshing an empty package index before
# installing sudo, and the reboot offer after the single-item menu.
# Every system command is a mock; files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions restore_ids restore_before_stage preflight_block preflight_report audit_disk_risks coreutils_selfcheck admin_prepare item_main
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$T/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$T/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$T/trace"; }
reset() { : > "$T/trace"; : > "$T/log"; }

# A hand-made change: full setup skips the step, an explicit request (or the
# upgrade step's incidental firewall/time tracking) takes it as the new baseline.
RESTORE_READY=1 RESTORE_ROOT="$T/restore" ADOPT_OK=1
declare -A NOW=() LAST=()
restore_snapshot() { return 0; }
restore_fingerprint() { echo "value:${NOW[$1]:-same}"; }
restore_read() { case "$2" in last_fp) echo "value:${LAST[$1]:-same}" ;; state) echo applied ;; esac; }
restore_label() { printf '%s' "$1"; }
restore_adopt() { record "adopt $1"; ((ADOPT_OK)); }
reset; NOW=([cc]=cubic) LAST=([cc]=bbr) RESTORE_ADOPT_DRIFT=0
if restore_before_stage bbr; then fail 'full setup ran a step over a hand-made change'; fi
[[ ! -s "$T/trace" ]] || fail 'full setup adopted a hand-made change'
reset; RESTORE_ADOPT_DRIFT=1
restore_before_stage bbr || fail 'explicit request was blocked by a hand-made change'
[[ "$(cat "$T/trace")" == 'adopt cc' && "$RESTORE_STAGE" == bbr ]] || fail 'hand-made change not taken as the new baseline'
reset; NOW=([ufw_runtime]=inactive) LAST=([ufw_runtime]=active) RESTORE_ADOPT_DRIFT=0
restore_before_stage apt_upgrade || fail 'a manual ufw disable skipped the whole upgrade step'
[[ "$(cat "$T/trace")" == 'adopt ufw_runtime' ]] || fail 'upgrade step did not adopt the firewall state'
reset; NOW=([tz]=Asia/Tokyo) LAST=([tz]=UTC) RESTORE_ADOPT_DRIFT=1 ADOPT_OK=0
if restore_before_stage timezone; then fail 'step ran although its rollback record could not be updated'; fi
printf 'PASS: hand-made changes skip full setup steps but become the baseline for explicit requests and the upgrade step.\n'

# btrfs reports 0 inodes and "-": not an inode shortage and not an unknown state.
support_lifecycle_report() { :; }
apt_sources_report() { :; }
dpkg() { return 0; }
lslocks() { return 0; }
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
[[ -z "$(printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/vda2 0 0 0 - /\n' | audit_disk_risks inode)" ]] || fail 'btrfs inode line reported as unknown or full'
unset -f df
if [[ "$(uname -o 2>/dev/null)" == Msys ]]; then
  printf 'SKIP: coreutils self-check on btrfs needs Linux permissions (Windows Git Bash cannot chmod).\n'
else
  df() { if [[ "$*" == '-Pi /' ]]; then printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/vda2 0 0 0 - /\n'; else command df "$@"; fi; }
  coreutils_selfcheck || fail 'coreutils self-check rejects a btrfs root'
  unset -f df
fi
printf 'PASS: btrfs (dynamic inodes) is neither blocked nor reported as unknown.\n'

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

# Single-item menu: explicit requests adopt hand-made changes; a reboot is
# offered only for an upgrade made in this session.
eval "$(declare -f item_main | sed '/EUID/d')"
validate_vm() { :; }; start_logging() { :; }; prepare_run_state() { :; }; stage_run() { :; }
restore_prepare() { :; }; finish_run_state() { :; }
offer_reboot() { record offer; }
item_menu() { record "adopt=$RESTORE_ADOPT_DRIFT"; UPGRADE_APPROVED="$U" KERNEL_UPDATE="$K"; }
reset; RESTORE_ADOPT_DRIFT=0 UPGRADE_APPROVED=0 KERNEL_UPDATE=0 U=1 K=1
item_main > /dev/null
[[ "$(cat "$T/trace")" == $'adopt=1\noffer' ]] || fail "kernel upgrade in this session: $(tr '\n' ' ' < "$T/trace")"
reset; RESTORE_ADOPT_DRIFT=0 U=0 K=0
item_main > /dev/null
if grep -Fxq offer "$T/trace"; then fail 'reboot offered although nothing was upgraded in this session'; fi
printf 'PASS: single-item menu adopts hand-made changes and offers a reboot only after its own upgrade.\n'
