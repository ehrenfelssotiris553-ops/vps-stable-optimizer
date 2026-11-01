#!/usr/bin/env bash
# The parameter framework: automatic or user values kept strictly, adjusting and
# resetting from the single-item menu, the overview, export and import, and
# vps check telling when the value in force is no longer the one wanted.
# Every system command is a mock; all files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions param_list param_kind param_recommended param_reason param_check param_caution param_read param_value param_mode \
  param_store param_names param_info param_item_on param_adjust param_reset param_apply param_live params_overview params_export params_import \
  item_action item_symbols check_tcp verify_set verify_line
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf 'SAY %s\n' "$*"; }
ok() { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die() { fail "$*"; }
STATE_ROOT="$TEST_ROOT/state" PARAMS_FILE="$TEST_ROOT/state/params" MEM_MIB=2048 SCRIPT_VERSION=9.9.9
state_secure_dir() { mkdir -p -- "$1"; }
item_label() { case "$1" in tcp) echo 'TCP 缓冲区上限' ;; *) echo "$1" ;; esac; }
hostname() { echo test-host; }
APPLIED=''
item_turn_on() { printf 'apply %s\n' "$1" >> "$TEST_ROOT/applied"; }
MODULE='applied'
module_expect() { [[ "$1" == tcp && -n "$MODULE" ]] && printf '%s\t%s\t%s\n' "$MODULE" boot '32 MiB'; }

# Only known names with valid values count; anything else is ignored.
mkdir -p "$STATE_ROOT"
printf '%s\n' 'tcp_buffer_mib=999' 'unknown_param=5' 'garbage line' > "$PARAMS_FILE"
[[ "$(param_mode tcp_buffer_mib)" == 自动 && "$(param_value tcp_buffer_mib)" == 32 ]] || fail 'an out-of-range value was used'
printf '%s\n' 'tcp_buffer_mib=48' > "$PARAMS_FILE"
[[ "$(param_value tcp_buffer_mib)" == 48 && "$(param_mode tcp_buffer_mib)" == 你调过 ]] || fail 'a valid user value was not used'
for bad in 3 257 abc '' '-5' '1e3' '64 ' 0x40; do
  if param_check tcp_buffer_mib "$bad" > /dev/null; then fail "accepted: <$bad>"; fi
done
for good in 4 64 256 008; do param_check tcp_buffer_mib "$good" > /dev/null || fail "rejected: $good"; done
# Storing replaces the old line and keeps the others; an empty value removes it.
printf '%s\n' 'tcp_buffer_mib=48' 'ui_ascii=1' > "$PARAMS_FILE"
param_store tcp_buffer_mib 96
[[ "$(sort "$PARAMS_FILE" | tr '\n' ' ')" == 'tcp_buffer_mib=96 ui_ascii=1 ' ]] || fail "store: $(cat "$PARAMS_FILE")"
param_store tcp_buffer_mib ''
[[ "$(cat "$PARAMS_FILE")" == 'ui_ascii=1' ]] || fail "reset: $(cat "$PARAMS_FILE")"
if param_store 'bad name' 1; then fail 'a malformed name was stored'; fi
# Recommendation follows RAM, with the reason.
MEM_MIB=8192; [[ "$(param_value tcp_buffer_mib)" == 64 ]] || fail 'recommendation did not follow RAM'
[[ "$(param_reason tcp_buffer_mib)" == *'64 MiB 能让一个连接在 200 ms 延迟的线路上跑到约 2684 Mbps'* ]] || fail "reason: $(param_reason tcp_buffer_mib)"
MEM_MIB=2048
[[ -n "$(param_caution tcp_buffer_mib 200)" && -n "$(param_caution tcp_buffer_mib 4)" && -z "$(param_caution tcp_buffer_mib 32)" ]] ||
  fail 'cautions for extreme values'
printf 'PASS: parameters are stored strictly, follow the recommendation when automatic and warn about extreme values.\n'

# Adjusting: Enter keeps, a bad value asks again, an extreme one needs a yes,
# "auto" resets; the item is applied again only when it is on.
: > "$PARAMS_FILE"; : > "$TEST_ROOT/applied"
CONFIRM=n
confirm_yes() { printf 'ASK %s\n' "$1"; [[ "$CONFIRM" == y ]]; }
out="$(printf '\n' | param_adjust tcp)"
[[ "$out" == *'参数没有改动'* && ! -s "$TEST_ROOT/applied" ]] || fail "Enter changed something: $out"
out="$(printf '%s\n' 500 abc 64 | param_adjust tcp)"
[[ "$out" == *'请输入 4 到 256 之间的整数'* ]] || fail 'out-of-range value not refused'
[[ "$(param_value tcp_buffer_mib)" == 64 ]] || fail "adjusted value not kept: $(cat "$PARAMS_FILE")"
grep -Fxq 'apply tcp' "$TEST_ROOT/applied" || fail 'an item that is on was not applied again'
: > "$TEST_ROOT/applied"; CONFIRM=n
out="$(printf '%s\n' 200 '' | param_adjust tcp)"
[[ "$out" == *'ASK 仍然用 200 MiB 吗？'* && "$(param_value tcp_buffer_mib)" == 64 ]] || fail 'an extreme value was taken without a yes'
CONFIRM=y
printf '%s\n' 200 | param_adjust tcp > /dev/null
[[ "$(param_value tcp_buffer_mib)" == 200 ]] || fail 'a confirmed extreme value was not kept'
printf 'auto\n' | param_adjust tcp > /dev/null
[[ "$(param_mode tcp_buffer_mib)" == 自动 ]] || fail 'auto did not reset'
# An item that is off keeps the value for when it is turned on.
: > "$TEST_ROOT/applied"; MODULE='declined'
out="$(printf '16\n' | param_adjust tcp)"
[[ "$out" == *'开启时就会用新的参数'* && ! -s "$TEST_ROOT/applied" ]] || fail 'an item that is off was applied'
MODULE='applied'
param_reset tcp > /dev/null
[[ "$(param_mode tcp_buffer_mib)" == 自动 ]] || fail 'reset to recommended'
printf 'PASS: adjusting and resetting from the single item, applied again only when the item is on.\n'

# The single item offers both; items without parameters do not.
item_status() { echo '已开启'; }
item_turn_off() { :; }
port_menu() { :; }
[[ "$(printf '0\n' | item_action tcp)" == *'3. 调整参数   4. 恢复推荐值'* ]] || fail 'tcp item lacks adjust and reset'
[[ "$(printf '0\n' | item_action bbr)" != *'调整参数'* ]] || fail 'an item without parameters offers to adjust'
param_store tcp_buffer_mib 48
printf '4\n' | item_action tcp > /dev/null
[[ "$(param_mode tcp_buffer_mib)" == 自动 ]] || fail '4 in the item menu did not reset'
printf 'PASS: the single-item menu offers adjust and reset where an item has parameters.\n'

# Overview, export and import (round trip; unknown or bad lines skipped).
param_store tcp_buffer_mib 48
out="$(params_overview)"
[[ "$out" == *'现在用 48 MiB（你调过）· 本机推荐 32 MiB'* ]] || fail "overview: $out"
exported="$(params_export)"
grep -Fxq 'tcp_buffer_mib=48' <<< "$exported" || fail "export: $exported"
param_store tcp_buffer_mib ''
grep -Fxq 'tcp_buffer_mib=auto' <<< "$(params_export)" || fail 'automatic value not exported as auto'
confirm_default_yes() { [[ "$CONFIRM" == y ]]; }
CONFIRM=y; : > "$TEST_ROOT/applied"
out="$({ printf '%s\n' "$exported" 'nonsense=1' 'tcp_buffer_mib=999' ''; } | params_import)"
[[ "$(param_value tcp_buffer_mib)" == 48 ]] || fail "import did not restore the value: $out"
[[ "$out" == *'不认识这一行，跳过：nonsense=1'* && "$out" == *'值不在允许范围内，跳过：tcp_buffer_mib=999'* ]] || fail "bad lines not reported: $out"
grep -Fxq 'apply tcp' "$TEST_ROOT/applied" || fail 'imported values not applied to an item that is on'
printf 'tcp_buffer_mib=auto\n\n' | params_import > /dev/null
[[ "$(param_mode tcp_buffer_mib)" == 自动 ]] || fail 'importing auto did not reset'
CONFIRM=n
printf 'tcp_buffer_mib=64\n\n' | params_import > /dev/null
[[ "$(param_mode tcp_buffer_mib)" == 自动 ]] || fail 'a declined import was kept'
printf 'PASS: the overview shows value, recommendation and reason; export and import round-trip and skip bad lines.\n'

# Importing the values a machine already has applies nothing again (found on
# CI: every item that was on was turned on again). TG and the traffic alert
# read theirs when the check runs: never turned on again for it, which would
# ask their questions again.
CONFIRM=y; param_store tcp_buffer_mib 48; : > "$TEST_ROOT/applied"
printf 'tcp_buffer_mib=48\nzram_percent=auto\n\n' | params_import > /dev/null
[[ ! -s "$TEST_ROOT/applied" ]] || fail "unchanged values applied again: $(cat "$TEST_ROOT/applied")"
module_expect() { [[ "$1" == quota || "$1" == notify ]] && printf 'applied\tboot\tx\n'; }
out="$(printf 'quota_alerts=50 100\nnotify_summary_time=21:00\n\n' | params_import)"
[[ ! -s "$TEST_ROOT/applied" && "$out" == *'下次检查时就会用新的参数'* && "$(param_value quota_alerts)" == '50 100' ]] ||
  fail "TG or the traffic alert turned on again: $(cat "$TEST_ROOT/applied") $out"
[[ "$(param_apply quota)" == *'下次检查时'* && ! -s "$TEST_ROOT/applied" ]] || fail 'adjusting the traffic alert turned it on again'
param_store quota_alerts ''; param_store notify_summary_time ''; param_store tcp_buffer_mib ''
module_expect() { [[ "$1" == tcp && -n "$MODULE" ]] && printf '%s\t%s\t%s\n' "$MODULE" boot '32 MiB'; }
printf 'PASS: an import applies only what changed, and never turns TG or the traffic alert on again.\n'

# vps check: an applied cap that is no longer the one wanted is "可更新".
TCP_BUFFER_FILE="$TEST_ROOT/tcp.conf"; : > "$TCP_BUFFER_FILE"
sysctl_file_mismatch() { :; }
param_store tcp_buffer_mib ''
check_tcp '32 MiB'
[[ "$VERIFY_STATUS" == pass ]] || fail "the recommended cap in force: $VERIFY_STATUS $VERIFY_TEXT"
MEM_MIB=8192; check_tcp '32 MiB'
[[ "$VERIFY_STATUS" == update && "$VERIFY_TEXT" == *'本机现在推荐 64 MiB'* ]] || fail "a RAM upgrade not noticed: $VERIFY_STATUS $VERIFY_TEXT"
MEM_MIB=2048; param_store tcp_buffer_mib 48; check_tcp '32 MiB'
[[ "$VERIFY_STATUS" == update && "$VERIFY_TEXT" == *'你设置的是 48 MiB'* ]] || fail "a user value not applied yet: $VERIFY_TEXT"
VERIFY_UPDATE=0 VERIFY_ISSUES=()
line="$(verify_line update 'TCP 缓冲区上限' 'x'; echo "n=$VERIFY_UPDATE")"
[[ "$line" == *'⚠ 可更新  TCP 缓冲区上限：x'* ]] || fail "update line: $line"
printf 'PASS: vps check says when a parameter now asks for another value.\n'

# The ASCII symbols setting.
: > "$PARAMS_FILE"; CONFIRM=y
item_symbols > /dev/null
grep -Fxq 'ui_ascii=1' "$PARAMS_FILE" || fail 'ASCII setting not saved'
item_symbols > /dev/null
if grep -q ui_ascii "$PARAMS_FILE"; then fail 'ASCII setting not removed'; fi
printf 'PASS: the ASCII symbols setting is saved and removed from the single-item menu.\n'
