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
load_optimizer_functions item_actions item_state
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
# (tcp asks for three: the buffer cap, the two switches, the limit of what waits to be sent.)
out="$(printf '\n\n\n' | param_adjust tcp)"
[[ "$out" == *'参数没有改动'* && ! -s "$TEST_ROOT/applied" ]] || fail "Enter changed something: $out"
out="$(printf '%s\n' 500 abc 64 '' '' | param_adjust tcp)"
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
out="$(printf '16\n\n\n' | param_adjust tcp)"
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
[[ "$(printf '0\n' | item_action trim)" != *'调整参数'* ]] || fail 'an item without parameters offers to adjust'
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

# The switches and numbers opened up in 2.9: each limit accepted, one past it
# refused. Checked under LC_ALL=C, as this tool runs.
for pair in 'guard_seconds 120' 'guard_seconds 900' 'setup_skip none' 'setup_skip bbr firewall' 'run_keep 5' 'run_keep 200' \
    'audit_days 7' 'audit_days 365' 'menu_alerts all' 'menu_alerts none' 'menu_alerts verify reboot' 'menu_alert_days 1' 'menu_alert_days 30' \
    'ssh_rate_limit yes' 'ssh_rate_limit no' 'ssh_max_auth_tries 2' 'ssh_max_auth_tries 10' 'ssh_login_grace_seconds 10' 'ssh_login_grace_seconds 120' \
    'ssh_x11_forwarding yes' 'ssh_x11_forwarding no' 'sysctl_hardening_skip none' 'sysctl_hardening_skip kernel.kptr_restrict' \
    'bbr_qdisc fq' 'bbr_qdisc fq_codel' 'bbr_qdisc cake' 'zram_swappiness 1' 'zram_swappiness 200' 'zram_page_cluster 0' 'zram_page_cluster 3' \
    'auto_swap_below_mib 512' 'auto_swap_below_mib 16384' 'swap_min_free_gb 1' 'swap_min_free_gb 50' 'tcp_extras yes' 'tcp_extras no' \
    'journal_auto_disk_gib 0' 'journal_auto_disk_gib 4096' 'ssh_keepalive_count 1' 'ssh_keepalive_count 10' 'f2b_optional_below_mib 0' \
    'f2b_optional_below_mib 65536' 'conntrack_notice_percent 30' 'conntrack_notice_percent 95' 'login_keep_days 30' 'login_keep_days 1825' \
    'login_keep_lines 1000' 'login_keep_lines 100000' 'login_note yes' 'login_note no' 'login_note_minutes 1' 'login_note_minutes 120' \
    'check_minutes_tg 1' 'check_minutes_tg 30' 'check_minutes_quota 1' 'check_minutes_quota 60' 'notify_events_minutes 1' 'notify_events_minutes 60'; do
  LC_ALL=C param_check "${pair%% *}" "${pair#* }" > /dev/null || fail "rejected: $pair"
done
for pair in 'guard_seconds 119' 'guard_seconds 901' 'setup_skip apt_index' 'setup_skip bbr bbr2' 'run_keep 4' 'run_keep 201' 'audit_days 6' \
    'audit_days 366' 'menu_alerts some' 'menu_alerts none login' 'menu_alert_days 0' 'menu_alert_days 31' 'ssh_rate_limit maybe' 'ssh_max_auth_tries 1' \
    'ssh_max_auth_tries 11' 'ssh_login_grace_seconds 9' 'ssh_login_grace_seconds 121' 'ssh_x11_forwarding 1' 'sysctl_hardening_skip net.ipv4.ip_forward' \
    'bbr_qdisc pfifo_fast' 'zram_swappiness 0' 'zram_swappiness 201' 'zram_page_cluster 4' 'auto_swap_below_mib 511' 'auto_swap_below_mib 16385' \
    'swap_min_free_gb 0' 'swap_min_free_gb 51' 'tcp_extras on' 'journal_auto_disk_gib 4097' 'ssh_keepalive_count 0' 'ssh_keepalive_count 11' \
    'f2b_optional_below_mib 65537' 'conntrack_notice_percent 29' 'conntrack_notice_percent 96' 'login_keep_days 29' 'login_keep_days 1826' \
    'login_keep_lines 999' 'login_keep_lines 100001' 'login_note 1' 'login_note_minutes 0' 'login_note_minutes 121' 'check_minutes_tg 0' \
    'check_minutes_tg 31' 'check_minutes_quota 0' 'check_minutes_quota 61' 'notify_events_minutes 0' 'notify_events_minutes 61'; do
  if LC_ALL=C param_check "${pair%% *}" "${pair#* }" > /dev/null; then fail "accepted: $pair"; fi
done
# Every name of the name lists, one by one and all together (found here: under
# LC_ALL=C the descriptions in brackets were cut off only for some names).
notify_names='boot login console account sudo oom package key port autostart cpu disk memory reboot service traffic'
[[ "$(LC_ALL=C notify_event_names | LC_ALL=C names_only)" == "$notify_names" ]] || fail "notification names: $(LC_ALL=C notify_event_names | LC_ALL=C names_only)"
[[ "$(LC_ALL=C menu_alert_names | LC_ALL=C names_only)" == 'verify reboot login quota' ]] || fail "menu alert names: $(LC_ALL=C menu_alert_names | LC_ALL=C names_only)"
for name in $notify_names; do LC_ALL=C param_check notify_events "$name" > /dev/null || fail "notification name rejected: $name"; done
LC_ALL=C param_check notify_events "$notify_names" > /dev/null || fail 'all notification names together rejected'
for name in verify reboot login quota; do LC_ALL=C param_check menu_alerts "$name" > /dev/null || fail "menu alert name rejected: $name"; done
for name in $(setup_skippable); do LC_ALL=C param_check setup_skip "$name" > /dev/null || fail "setup step rejected: $name"; done
LC_ALL=C param_check setup_skip "$(setup_skippable | tr '\n' ' ')" > /dev/null || fail 'all setup steps together rejected'
for name in $(sysctl_hardening_all | sed 's/=.*//'); do LC_ALL=C param_check sysctl_hardening_skip "$name" > /dev/null || fail "hardening key rejected: $name"; done
printf 'PASS: every switch and number opened up in 2.9 keeps to its limits; every name of the name lists is accepted under LC_ALL=C.\n'

# Fail2ban's mode: the default leaves the jail as it was, the aggressive one
# is a line of its own and the jail is still recognised as this tool's.
(
  load_optimizer_functions f2b_jail_text f2b_jail_values_text f2b_jail_legacy_text f2b_jail_is_ours
  : > "$PARAMS_FILE"
  plain="$(f2b_jail_text 22)"
  if grep -q '^mode' <<< "$plain"; then fail "a mode line by default: $plain"; fi
  f2b_jail_is_ours "$plain" 22 || fail 'the default jail is not recognised'
  printf 'f2b_mode=aggressive\n' > "$PARAMS_FILE"
  aggressive="$(f2b_jail_text 22 198.51.100.7)"
  grep -Fxq 'mode = aggressive' <<< "$aggressive" || fail "no mode line: $aggressive"
  f2b_jail_is_ours "$aggressive" 22 || fail "a jail with a mode is not recognised as this tool's"
  [[ -n "$(param_caution f2b_mode aggressive)" && -z "$(param_caution f2b_mode normal)" ]] || fail 'the mode has no warning'
  if param_check f2b_mode strange > /dev/null; then fail 'an unknown mode was accepted'; fi
)
printf 'PASS: the Fail2ban mode is a parameter and leaves the default jail as it was.\n'
