#!/usr/bin/env bash
# Memory: the disk swap (when it is made, its size, the 3 GB that stay free,
# a new size, someone else's file left alone, the rollback and vps check),
# ZRAM's size and algorithm as parameters (applied from the next boot while a
# ZRAM is in use), and parameters that are words. Every system command is a
# mock; /proc and /sys are fixtures.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions param_list param_kind param_recommended param_reason param_check param_caution param_read param_value \
  param_mode param_store param_names param_info param_adjust params_import swap_unit_text swap_create zram_size_expr zram_config_text verify_set param_apply param_live
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
P="$TEST_ROOT/proc" Z="$TEST_ROOT/zram0"
mkdir -p "$P" "$Z" "$TEST_ROOT/state"
# The functions that read /proc or /sys work on fixtures here.
for fn in swapoff_safe swap_file_active swap_stage check_swap restore_swap_group zram_stage check_zram restore_value restore_apply_one; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" |
    sed -e "s#/proc/swaps#$P/swaps#g" -e "s#/proc/meminfo#$P/meminfo#g" -e "s#/proc/sys/kernel/random/boot_id#$P/boot_id#g" -e "s#/sys/block/zram0#$Z#g")"
done
STATE_ROOT="$TEST_ROOT/state" PARAMS_FILE="$TEST_ROOT/state/params"
SWAP_FILE="$TEST_ROOT/swapfile" SWAP_UNIT_FILE="$TEST_ROOT/unit/swapfile.swap" ZRAM_FILE="$TEST_ROOT/zram.conf" ZRAM_SYSCTL_FILE="$TEST_ROOT/no-zram-sysctl.conf"
state_secure_dir() { mkdir -p -- "$1"; }
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$P/swaps"
printf 'MemTotal:        1000000 kB\nMemAvailable:     600000 kB\n' > "$P/meminfo"
printf 'boot-1\n' > "$P/boot_id"
swaps_line() { printf '%s\tfile\t%s\t%s\t10\n' "$SWAP_FILE" "$1" "${2:-0}" >> "$P/swaps"; }
swaps_drop() { grep -vF "$SWAP_FILE" "$P/swaps" > "$P/swaps.new" || true; mv "$P/swaps.new" "$P/swaps"; }
swapon() { awk 'NR > 1 {print $1, $2}' "$P/swaps"; }
swapoff() { record "swapoff $*"; swaps_drop; }
fallocate() { record "fallocate $*"; truncate -s "$2" "${*: -1}"; }
mkswap() { record "mkswap ${*: -1}"; }
FREE=20000
df() { printf 'Filesystem 1M-blocks Used Available Capacity Mounted\n/dev/vda1 30000 10000 %s 33%% /\n' "$FREE"; }
ENABLED=0
systemctl() {
  record "systemctl $*"
  case "$*" in
    'enable --now swapfile.swap') ENABLED=1; swaps_line "$(($(stat -c %s -- "$SWAP_FILE") / 1024))" ;;
    'disable --now swapfile.swap') ENABLED=0; swaps_drop ;;
    'stop swapfile.swap') swaps_drop ;;
    'is-enabled -q swapfile.swap') ((ENABLED)) ;;
  esac
}
put_file() { [[ ! -e "$1" ]] || return 1; mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
module_result() { record "result $1 $2 ${3:-}"; }
OURS=0 OTHER_SWAP=0
restore_file_ours() { [[ "$1" == swap_unit ]] && ((OURS)); }
swap_exists() { ((OTHER_SWAP)); }
restore_resource() { record "resource $1"; }
restore_sysctl_runtime() { record "sysctl runtime $1"; }
MEM_MIB=1024 VIRT=kvm ROOT_FS=ext4 SWAP_CHOICE=''

# When it is made: on its own only below 2 GiB without any other swap.
reset; MEM_MIB=4096; swap_stage
grep -q '^result swap skipped RAM >= 2GiB' "$TEST_ROOT/trace" || fail 'a disk swap made on its own with 4 GiB'
reset; MEM_MIB=1024 OTHER_SWAP=1; swap_stage
grep -q '^result swap skipped other swap present' "$TEST_ROOT/trace" || fail 'a disk swap made on its own next to another swap'
OTHER_SWAP=0
reset; VIRT=openvz; swap_stage
grep -q '^result swap unsupported openvz' "$TEST_ROOT/trace" || fail 'a container got a swap file'
reset; VIRT=kvm ROOT_FS=btrfs; swap_stage
grep -q '^result swap unsupported btrfs' "$TEST_ROOT/trace" || fail 'btrfs got a swap file'
ROOT_FS=ext4
[[ ! -e "$SWAP_FILE" ]] || fail 'a swap file appeared while skipping'
printf 'PASS: a disk swap is made on its own only below 2 GiB, without another swap, on ext4 or xfs, outside containers.\n'

# Made: about the RAM, allocated, formatted, a unit with priority 10, started.
reset; swap_stage
[[ "$(($(stat -c %s -- "$SWAP_FILE") / 1048576))" == 1024 ]] || fail "size: $(stat -c %s -- "$SWAP_FILE")"
grep -Fxq "mkswap $SWAP_FILE" "$TEST_ROOT/trace" || fail 'not formatted'
grep -Fxq 'Priority=10' "$SWAP_UNIT_FILE" && grep -Fxq "What=$SWAP_FILE" "$SWAP_UNIT_FILE" && grep -Fxq 'WantedBy=swap.target' "$SWAP_UNIT_FILE" ||
  fail "unit: $(cat "$SWAP_UNIT_FILE")"
grep -Fxq 'systemctl enable --now swapfile.swap' "$TEST_ROOT/trace" || fail 'unit not enabled'
grep -q '^result swap applied 1024 MiB' "$TEST_ROOT/trace" || fail 'result'
[[ "$(stat -c %a -- "$SWAP_FILE")" == 600 ]] || [[ "$(uname -o 2>/dev/null)" == Msys ]] || fail 'swap file readable by others'
# vps check.
check_swap '1024 MiB'
[[ "$VERIFY_STATUS" == pass ]] || fail "check: $VERIFY_TEXT"
ENABLED=0; check_swap '1024 MiB'
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *开机不会启用* ]] || fail 'a swap not enabled at boot passed'
ENABLED=1
printf 'PASS: the disk swap is about the RAM, formatted, used after ZRAM, started at boot and checked.\n'

# The setup run again (found on Ubuntu VMs): this tool's own swap in use is
# not "another swap", so it stays applied; a ZRAM next to it still counts.
(
  eval "$(awk -v n=swap_exists '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/etc/fstab#$TEST_ROOT/fstab#g")"
  : > "$TEST_ROOT/fstab"
  eval "outer_$(declare -f systemctl)"
  systemctl() { if [[ "$*" == 'is-enabled zramswap.service' ]]; then return 1; fi; outer_systemctl "$@"; }
  OURS=1
  reset; swap_stage
  grep -q '^result swap applied 1024 MiB' "$TEST_ROOT/trace" || fail "a second setup did not keep its own swap: $(cat "$TEST_ROOT/trace")"
  printf '/dev/zram0\tpartition\t500000\t0\t100\n' >> "$P/swaps"
  reset; swap_stage
  grep -q '^result swap skipped other swap present' "$TEST_ROOT/trace" || fail 'a ZRAM next to the own swap was not counted'
)
grep -v '^/dev/zram0' "$P/swaps" > "$P/swaps.new" || true; mv "$P/swaps.new" "$P/swaps"
printf 'PASS: a setup run again keeps its own disk swap and still counts any other swap.\n'

# 3 GB stay free: the size shrinks, or there is no swap at all.
reset; swaps_drop; rm -f "$SWAP_FILE" "$SWAP_UNIT_FILE"; FREE=3600; swap_stage
[[ "$(($(stat -c %s -- "$SWAP_FILE") / 1048576))" == 512 ]] || fail "not shrunk to keep 3 GB: $(stat -c %s -- "$SWAP_FILE")"
reset; swaps_drop; rm -f "$SWAP_FILE" "$SWAP_UNIT_FILE"; FREE=3100; swap_stage
[[ ! -e "$SWAP_FILE" ]] && grep -q '^result swap unsupported not enough disk space' "$TEST_ROOT/trace" || fail 'a swap made with less than 3 GB left'
FREE=20000
printf 'PASS: at least 3 GB of the system disk stay free.\n'

# Someone else's /swapfile stays; this tool's own gets a new size.
printf 'theirs\n' > "$SWAP_FILE"; cp "$SWAP_FILE" "$TEST_ROOT/theirs"
reset; SWAP_CHOICE=1; swap_stage
cmp -s "$SWAP_FILE" "$TEST_ROOT/theirs" && grep -q '^result swap preserved' "$TEST_ROOT/trace" || fail "someone else's swap file was touched"
rm -f "$SWAP_FILE"
reset; swap_stage
OURS=1; param_store swap_mib 768
reset; swap_stage
[[ "$(($(stat -c %s -- "$SWAP_FILE") / 1048576))" == 768 ]] || fail 'not made again at the new size'
grep -Fxq 'systemctl stop swapfile.swap' "$TEST_ROOT/trace" || fail 'the old swap was not stopped first'
# A new size that does not fit in RAM now: kept as it is.
swaps_drop; swaps_line 786432 700000
reset; param_store swap_mib 1024; swap_stage
[[ "$(($(stat -c %s -- "$SWAP_FILE") / 1048576))" == 768 ]] && grep -q '^WARN 可用内存不够' "$TEST_ROOT/log" || fail 'a swap in use was resized without room in RAM'
printf 'PASS: a swap file that is not this tool is kept, its own one is made again at a new size when RAM allows.\n'

# Rollback: off (when its contents fit in RAM), the file, then the unit.
swaps_drop; swaps_line 786432 1000; param_store swap_mib ''
restore_needed() { return 0; }
reset; RESTORE_PARTIAL=0; restore_swap_group
[[ "$(cat "$TEST_ROOT/trace")" == $'systemctl disable --now swapfile.swap\nresource swap_file\nresource swap_unit\nsystemctl daemon-reload' ]] ||
  fail "rollback order: $(cat "$TEST_ROOT/trace")"
swaps_line 786432 700000
reset; RESTORE_PARTIAL=0; restore_swap_group
((RESTORE_PARTIAL)) && ! grep -q 'disable' "$TEST_ROOT/trace" || fail 'a full swap was turned off without room in RAM'
# The value and the undo of the file itself.
restore_read() { echo absent; }
restore_path() { return 1; }
[[ "$(restore_value swap_file)" == "file:$(stat -c %s -- "$SWAP_FILE"):on" ]] || fail "value: $(restore_value swap_file)"
swaps_drop; swaps_line 786432 1000
reset; restore_apply_one swap_file
[[ ! -e "$SWAP_FILE" ]] && grep -q "^swapoff -- $SWAP_FILE" "$TEST_ROOT/trace" || fail 'the swap file was not turned off and removed'
[[ "$(restore_value swap_file)" == absent ]] || fail 'value after removal'
printf 'PASS: the rollback turns the swap off only when it fits in RAM, then removes the file and the unit.\n'

# ZRAM: size and algorithm are parameters; a ZRAM in use gets the new ones
# from the next boot, and vps check says so until then.
OURS_ZRAM=1 ZRAM_ON=1
swap_exists() { return 0; }
zram_vendor_default_only() { return 1; }
restore_file_ours() { [[ "$1" == zram_file ]] && ((OURS_ZRAM)); }
zram_swap_active() { ((ZRAM_ON)); }
zram_tune() { record 'zram tune'; }
zram_module_available() { return 0; }
MEM_MIB=1024
# A ZRAM in use, from this tool's file.
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0\tpartition\t512000\t0\t100\n' > "$P/swaps"
zram_config_text > "$ZRAM_FILE"
reset; zram_stage
if grep -q 'from next boot' "$TEST_ROOT/trace"; then fail 'unchanged parameters rewrote the ZRAM file'; fi
param_store zram_percent 75; param_store zram_algorithm lz4
reset; zram_stage
grep -Fxq 'zram-size = ram * 75 / 100' "$ZRAM_FILE" && grep -Fxq 'compression-algorithm = lz4' "$ZRAM_FILE" || fail "ZRAM file: $(cat "$ZRAM_FILE")"
grep -q '^result zram applied zram0 = ram \* 75 / 100 (from next boot)' "$TEST_ROOT/trace" || fail "ZRAM result: $(cat "$TEST_ROOT/trace")"
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0\tpartition\t512000\t0\t100\n' > "$P/swaps"
printf 'lzo-rle [zstd] lz4\n' > "$Z/comp_algorithm"
check_zram 'zram0 = ram * 75 / 100 (from next boot)' boot-1
[[ "$VERIFY_STATUS" == reboot ]] || fail "before the reboot: $VERIFY_STATUS $VERIFY_TEXT"
printf 'boot-2\n' > "$P/boot_id"; printf 'lzo-rle zstd [lz4]\n' > "$Z/comp_algorithm"
check_zram 'zram0 = ram * 75 / 100 (from next boot)' boot-1
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *lz4* ]] || fail "after the reboot: $VERIFY_STATUS $VERIFY_TEXT"
param_store zram_percent ''
[[ "$(zram_size_expr)" == 'ram / 2' ]] || fail 'the usual size keeps its old form'
printf 'PASS: ZRAM size and algorithm follow the parameters, applied from the next boot while in use.\n'

# A word parameter: chosen from a list, never turned into a number.
param_store zram_percent ''; param_store zram_algorithm ''
param_item_on() { return 1; }
item_label() { echo ZRAM; }
confirm_yes() { return 0; }
printf '%s\n' '' 'gzip' 'lz4' | param_adjust zram > "$TEST_ROOT/out"
[[ "$(param_value zram_algorithm)" == lz4 ]] || fail "algorithm: $(cat "$TEST_ROOT/out")"
grep -q '请输入 zstd、lz4 或 lzo-rle' "$TEST_ROOT/out" || fail 'a wrong algorithm was not refused'
printf 'zram_algorithm=zstd\nzram_algorithm=gzip\nzram_percent=040\n\n' | params_import > "$TEST_ROOT/out"
[[ "$(param_value zram_algorithm)" == zstd && "$(param_value zram_percent)" == 40 ]] || fail "import: $(cat "$TEST_ROOT/out")"
printf 'PASS: a word parameter is chosen from its list and kept as a word.\n'

# The resource view lists a service under two names once (on a real Debian 13
# VPS sshd.service, an alias of ssh.service, made SSH appear twice).
load_optimizer_functions resources_line
systemctl() {
  case "$*" in
    'show -p Id --value ssh.service'|'show -p Id --value sshd.service') echo ssh.service ;;
    'show -p Id --value fail2ban.service') echo fail2ban.service ;;
    'show -p ActiveState --value '*) echo active ;;
    'show -p MemoryCurrent --value '*) echo 8388608 ;;
    'show -p CPUUsageNSec --value '*) echo 2000000000 ;;
  esac
}
out="$(resources_line ssh ssh.service SSH x; resources_line ssh sshd.service SSH x; resources_line fail2ban fail2ban.service Fail2ban y)"
[[ "$(grep -c '^  SSH：内存 8 MiB，开机以来 CPU 2 秒。x$' <<< "$out")" == 1 && "$out" == *'Fail2ban：内存 8 MiB'* ]] || fail "resources: $out"
unset -f systemctl
printf 'PASS: the resource view lists a service under two names once.\n'
