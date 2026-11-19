#!/usr/bin/env bash
# Tests for the simplified confirmations, the recommended setup set, rollback
# groups, the single-item menu, the coreutils self-check and the Ubuntu 26.04
# release entry. Every system command is a mock; files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions f2b_optional ssh_effective_value confirm_default_yes upgrade_has_kernel apt_index_stage setup_questions admin_name_valid port_source_valid restore_groups restore_group_label restore_group_ids restore_group_pending sshd_off_files restore_data_safe state_path_safe restore_group_apply restore_all_groups restore_pick_group restore_firewall_warning item_keys item_group item_state item_mark item_status_prepare item_actions ui_width item_label item_turn_off item_action param_list param_names item_firewall_pause ufw_forward_restore item_ask_reboot_time reboot_time_normalize restore_tool_package item_menu guard_confirm coreutils_selfcheck release_info
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }

# [Y/n]: Enter and y mean yes; n and anything else mean no.
eval "$(declare -f confirm_default_yes | sed 's/\[\[ -t 0 \]\] || return 1/:/')"
printf '\n' | confirm_default_yes 'q?' 2>/dev/null || fail 'Enter did not mean yes'
printf 'y\n' | confirm_default_yes 'q?' 2>/dev/null || fail 'y did not mean yes'
if printf 'n\n' | confirm_default_yes 'q?' 2>/dev/null; then fail 'n meant yes'; fi
if printf 'maybe\n' | confirm_default_yes 'q?' 2>/dev/null; then fail 'unclear answer meant yes'; fi
printf 'PASS: [Y/n] questions treat Enter as yes and anything unclear as no.\n'

# Recommended set: one question covers upgrade, automatic updates and the rest.
RUN_BACKUP_DIR="$TEST_ROOT/backup"; mkdir -p "$RUN_BACKUP_DIR"
SIM=$'Inst libc6 [2.36-9] (2.36-9+deb12u9)\nInst linux-image-6.1.0-29-amd64 (6.1.123-1)'
df() { printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n/dev/vda1 20000 5000 15000 25%% /\n'; }
apt-get() {
  case "$*" in
    'update -o APT::Update::Error-Mode=any') return 0 ;;
    '-s upgrade --with-new-pkgs') printf '%s\n' "$SIM" ;;
    *) fail "unexpected apt-get $*" ;;
  esac
}
ANSWERS=()
apt_wait_idle() { :; }
confirm_default_yes() { record "ask $1"; local a="${ANSWERS[0]:-y}"; ANSWERS=("${ANSWERS[@]:1}"); [[ "$a" == y ]]; }
reset; ANSWERS=(y) RECOMMENDED=0 UPGRADE_APPROVED=0 AUTO_UPDATES=0
apt_index_stage > "$TEST_ROOT/out"
[[ "$RECOMMENDED" == 1 && "$UPGRADE_APPROVED" == 1 && "$AUTO_UPDATES" == 1 && "$KERNEL_UPDATE" == 1 ]] || fail 'recommended set did not cover upgrade and automatic updates'
[[ "$(grep -c '^ask ' "$TEST_ROOT/trace")" == 1 ]] || fail 'recommended set asked more than one question'
reset; ANSWERS=(n y n) RECOMMENDED=0 UPGRADE_APPROVED=0 AUTO_UPDATES=0
apt_index_stage > "$TEST_ROOT/out"
[[ "$RECOMMENDED" == 0 && "$UPGRADE_APPROVED" == 1 && "$AUTO_UPDATES" == 0 ]] || fail 'custom answers not applied'
reset; SIM='' ANSWERS=(y) UPGRADE_APPROVED=0
apt_index_stage > "$TEST_ROOT/out"
[[ "$UPGRADE_APPROVED" == 0 ]] || fail 'upgrade approved with nothing to upgrade'
# Only package names, at most 60, wrapped without trailing spaces (a real VPS
# printed 120 raw APT lines before, then names with a space left at each end).
SIM="$(for i in $(seq 1 70); do printf 'Inst pkg%02d [1] (2 Debian:13/stable [amd64])\n' "$i"; done)"
reset; ANSWERS=(y)
apt_index_stage > "$TEST_ROOT/out"
if grep -q '^Inst ' "$TEST_ROOT/out"; then fail 'raw APT simulation lines printed'; fi
grep -q '^  pkg01 pkg02 ' "$TEST_ROOT/out" || fail 'package names not listed'
if grep -q 'pkg61' "$TEST_ROOT/out"; then fail 'more than 60 names listed'; fi
grep -q '共 70 个' "$TEST_ROOT/out" || fail 'total of a long list not shown'
if grep -qE '^  pkg.*[[:space:]]$' "$TEST_ROOT/out"; then fail 'package list lines end with a space'; fi
printf 'PASS: the recommended set is one question and still respects an empty upgrade.\n'

(
  confirm_yes() {
    case "$1" in
      *SSH\ 登录*) return 1 ;;
      *80*) return 1 ;;
      *) fail "recommended mode asked: $1" ;;
    esac
  }
  # Since 2.7.6 the Fail2ban allowlist is asked in the recommended set as well.
  confirm_default_yes() { case "$1" in *Fail2ban\ 白名单*) return 0 ;; *) fail "recommended mode asked: $1" ;; esac; }
  timezone_ask() { fail 'recommended mode asked for the timezone'; }
  hostname_resolves() { return 1; }
  swap_exists() { return 1; }
  IPV6_BROKEN=0
  ipv6_broken() { ((IPV6_BROKEN)); }
  PASSWORD_LOGIN=yes
  ssh_effective() { printf 'passwordauthentication %s\nkbdinteractiveauthentication no\n' "$PASSWORD_LOGIN"; }
  RECOMMENDED=1 UPGRADE_APPROVED=1 AUTO_UPDATES=1 MEM_MIB=4096 INSTALL_TOOLS=0 SSH_CONNECTION='203.0.113.9 1 192.0.2.1 22'
  TOOLS_PACKAGES=(curl)
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$INSTALL_TOOLS" == 1 && "$SYSCTL_CHOICE" == 1 && "$KERNEL_CLEAN_CHOICE" == 1 && "$HOSTS_CHOICE" == 1 ]] || fail 'recommended items not set'
  [[ "$VNSTAT_CHOICE" == 0 && "$ZRAM_CHOICE" == 0 && -z "$AUTO_REBOOT_TIME" && -z "$TZ_CHOICE" ]] || fail 'non-recommended items were switched on'
  # TCP tuning only raises ceilings: in the set from 1 GiB of RAM, not below.
  [[ "$TCP_BUFFER_CHOICE" == 1 ]] || fail 'TCP tuning not in the recommended set with 4 GiB'
  MEM_MIB=512 TCP_BUFFER_CHOICE=''
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$TCP_BUFFER_CHOICE" == 0 ]] || fail 'TCP tuning in the recommended set below 1 GiB'
  # SSH keepalive is in the set; IPv4 first only where IPv6 is broken.
  [[ "$KEEPALIVE_CHOICE" == 1 && "$IPV4_CHOICE" == 0 ]] || fail "keepalive/IPv4 in the recommended set: $KEEPALIVE_CHOICE $IPV4_CHOICE"
  IPV6_BROKEN=1
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$IPV4_CHOICE" == 1 ]] || fail 'IPv4 first not recommended with a broken IPv6'
  [[ "$SSH_CHOICE" == 0 && "$WEB_CHOICE" == 0 ]] || fail 'SSH/web questions were not asked separately'
  [[ "$F2B_IGNORE_CHOICE" == 203.0.113.9 && "$F2B_CHOICE" == 1 ]] || fail "recommended mode did not offer the Fail2ban allowlist: $F2B_IGNORE_CHOICE"
  # Key-only login below 1 GiB: Fail2ban is left out, and so is its allowlist.
  PASSWORD_LOGIN=no
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$F2B_CHOICE" == 0 && "$F2B_IGNORE_CHOICE" == none ]] || fail "Fail2ban recommended with key-only login below 1 GiB: $F2B_CHOICE $F2B_IGNORE_CHOICE"
  grep -Fq 'Fail2ban 防的是猜密码' "$TEST_ROOT/q-out" || fail 'leaving Fail2ban out not explained'
  PASSWORD_LOGIN=yes MEM_MIB=4096
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$F2B_CHOICE" == 1 ]] || fail 'Fail2ban left out with 4 GiB'
)
printf 'PASS: recommended mode sets only the low-risk items and still asks about SSH, web ports and the Fail2ban allowlist.\n'

# Rollback groups: Fail2ban and the SSH port (which lets the old port in again)
# before the firewall, pending detection, per-item pick.
[[ "$(restore_groups | head -n 3 | tr '\n' ' ')" == 'fail2ban sshport firewall ' ]] || fail 'Fail2ban and the SSH port must be undone before the firewall'
RESTORE_ROOT="$TEST_ROOT/restore-v2"; mkdir -p "$RESTORE_ROOT"
declare -A STATE=()
restore_read() { [[ "$2" == state && -n "${STATE[$1]:-}" ]] || return 1; echo "${STATE[$1]}"; }
# The tracked setting differs from its original state: modelled by "applied".
restore_needed() { [[ -d "$RESTORE_ROOT/$1" && "${STATE[$1]:-}" == applied ]]; }
for id in bbr_file f2b_jail ufw_runtime; do mkdir -p "$RESTORE_ROOT/$id"; done
STATE=([bbr_file]=applied [f2b_jail]=restored [ufw_runtime]=clean)
restore_group_pending bbr || fail 'applied BBR not pending'
if restore_group_pending fail2ban; then fail 'restored Fail2ban still pending'; fi
if restore_group_pending firewall; then fail 'clean firewall pending'; fi
printf 'ufw limit 22/tcp\n' > "$RESTORE_ROOT/fw_rules"
restore_group_pending firewall || fail 'recorded firewall rules not pending'
rm -f "$RESTORE_ROOT/fw_rules"
restore_firewall_group() { record 'group firewall'; }
restore_created_dirs() { :; }
restore_fail2ban_group() { record 'group fail2ban'; }
restore_ssh_group() { record 'group ssh'; }
restore_zram_group() { record 'group zram'; }
restore_dockerfw_group() { record 'group dockerfw'; }
restore_databackup_group() { record 'group databackup'; }
restore_hostname_group() { record 'group hostname'; }
restore_swap_group() { record 'group swap'; }
restore_sshport_group() { record 'group sshport'; }
check_reconcile() { record 'check reconcile'; }
check_after_rollback() { record 'check after rollback'; }
check_remove() { record 'check remove'; }
# No Docker running here (the Docker log group only warns when it runs).
active() { return 1; }
ssh_reload() { record 'ssh reload'; }
restore_resource() { record "resource $1"; }
restore_sysctl_runtime() { record 'sysctl runtime'; }
restore_packages_offer() { record "packages $*"; }
restore_zram_settle() { record 'zram settle'; }
restore_value() { echo inactive; }
restore_tool_packages() { :; }
reset; restore_all_groups
[[ "$(head -n 3 "$TEST_ROOT/trace" | tr '\n' ' ')" == 'group fail2ban group sshport group firewall ' ]] || fail 'full rollback order'
grep -Fxq 'resource bbr_file' "$TEST_ROOT/trace" || fail 'plain group resources not restored'
# A rename is undone with its own handler (cloud-init, the name, its hosts line).
grep -Fxq 'group hostname' "$TEST_ROOT/trace" || fail 'the rename was not undone by the full rollback'
# TG and the traffic alert: their settings, then the shared timer is taken away.
grep -Fxq 'resource notify_conf' "$TEST_ROOT/trace" && grep -Fxq 'resource quota_conf' "$TEST_ROOT/trace" && grep -Fxq 'check remove' "$TEST_ROOT/trace" ||
  fail "notifications not undone: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
grep -Fxq 'packages ' "$TEST_ROOT/trace" || fail 'full rollback did not offer package removal'
# The package default can bring ZRAM back: settled after the package question.
[[ "$(tail -n 1 "$TEST_ROOT/trace")" == 'zram settle' ]] || fail 'ZRAM not settled after the package question'
confirm_yes() { return 0; }
reset; printf '1\n' > "$TEST_ROOT/pick"
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/trace")" == $'resource bbr_file\nresource bbr_module\nresource cc\nresource qdisc' ]] || fail "per-item rollback touched more than BBR: $(cat "$TEST_ROOT/trace")"
reset; printf '9\n' > "$TEST_ROOT/pick"
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/trace" ]] || fail 'invalid pick changed something'
printf 'PASS: rollback groups keep the safe order and per-item rollback touches one group.\n'
# vps rollback, the disk swap alone: no run there to write ZRAM's values in, so
# it says how to get them back; nothing to say without a ZRAM.
ZRAM_ON=1
zram_swap_active() { ((ZRAM_ON)); }
confirm_yes() { return 0; }
reset; STATE=([swap_unit]=applied); printf '1\n' > "$TEST_ROOT/pick"
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
grep -Fq 'ZRAM 还在用' "$TEST_ROOT/out" || fail "no word about ZRAM's values: $(cat "$TEST_ROOT/out")"
ZRAM_ON=0; reset; STATE=([swap_unit]=applied)
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
if grep -Fq 'ZRAM 还在用' "$TEST_ROOT/out"; then fail 'ZRAM mentioned without a ZRAM'; fi
unset -f zram_swap_active

# Key login kept on when the SSH hardening was undone: still to do in the list,
# but vps check calls the hardening undone, not broken.
(
  module_result() { record "result $1 $2"; }
  restore_group_pending() { return 0; }
  restore_ssh_group() { RESTORE_SSH_KEPT=1; }
  reset; restore_group_apply ssh
  grep -Fxq 'result ssh reverted' "$TEST_ROOT/trace" || fail "the hardening not recorded as undone: $(cat "$TEST_ROOT/trace")"
  restore_ssh_group() { :; }
  reset; restore_group_apply ssh
  if grep -q '^result ssh' "$TEST_ROOT/trace"; then fail 'recorded as undone with something left'; fi
)

# TG or the traffic alert undone: inside a run the timer is written the usual
# way; `vps rollback` is no run and goes the direct way.
saved_ready="${RESTORE_READY:-0}"
RESTORE_READY=1; reset; restore_group_apply notify
grep -Fxq 'check reconcile' "$TEST_ROOT/trace" && ! grep -Fxq 'check after rollback' "$TEST_ROOT/trace" || fail "inside a run: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
RESTORE_READY=0; reset; restore_group_apply quota
grep -Fxq 'check after rollback' "$TEST_ROOT/trace" && ! grep -Fxq 'check reconcile' "$TEST_ROOT/trace" || fail "vps rollback: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
RESTORE_READY="$saved_ready"

# Single-item menu: off undoes only this tool's change; firewall pause; dispatch.
reset; STATE=()
item_turn_off bbr
grep -Fq '本工具没有改过' "$TEST_ROOT/log" || fail 'untouched item not explained'
[[ ! -s "$TEST_ROOT/trace" ]] || fail 'untouched item was changed'
reset; STATE=([bbr_file]=applied)
item_turn_off bbr
grep -Fxq 'resource bbr_file' "$TEST_ROOT/trace" || fail 'item off did not undo the tool change'
# Undoing the disk swap: this tool's ZRAM, alone again, gets its values back (a
# real VPS stayed on swappiness 60 / page-cluster 3). A ZRAM not of this tool
# is left alone, and so is every other item.
ZRAM_OURS=1 ZRAM_ON=1
restore_file_ours() { [[ "$1" == zram_file ]] && ((ZRAM_OURS)); }
zram_swap_active() { ((ZRAM_ON)); }
real_stage_run="$(declare -f stage_run || true)"
stage_run() { record "stage $*"; }
reset; STATE=([swap_unit]=applied); item_turn_off swap
grep -Fxq 'stage zram zram_tune' "$TEST_ROOT/trace" || fail "ZRAM values not back after the disk swap went: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
ZRAM_OURS=0; reset; STATE=([swap_unit]=applied); item_turn_off swap
if grep -q zram_tune "$TEST_ROOT/trace"; then fail 'a ZRAM of someone else was tuned'; fi
ZRAM_OURS=1 ZRAM_ON=0; reset; STATE=([swap_unit]=applied); item_turn_off swap
if grep -q zram_tune "$TEST_ROOT/trace"; then fail 'tuned without a ZRAM running'; fi
ZRAM_ON=1; reset; STATE=([bbr_file]=applied); item_turn_off bbr
if grep -q zram_tune "$TEST_ROOT/trace"; then fail 'another item tuned ZRAM'; fi
# The login record off: TG, still on, stops telling about logins; said then.
(
  STATE_ROOT="$TEST_ROOT/login-state"; mkdir -p "$STATE_ROOT"
  printf 'x\n' > "$STATE_ROOT/notify.conf"
  reset; STATE=([login_pam]=applied); item_turn_off login > "$TEST_ROOT/out"
  grep -Fq '收不到登录提醒' "$TEST_ROOT/out" || fail "TG not mentioned: $(cat "$TEST_ROOT/out")"
  rm -f "$STATE_ROOT/notify.conf"
  reset; STATE=([login_pam]=applied); item_turn_off login > "$TEST_ROOT/out"
  if grep -Fq '收不到登录提醒' "$TEST_ROOT/out"; then fail 'TG mentioned without TG'; fi
)
unset -f restore_file_ours zram_swap_active stage_run
if [[ -n "$real_stage_run" ]]; then eval "$real_stage_run"; fi
if grep -q '^result ' "$TEST_ROOT/trace"; then fail 'a group still pending was recorded as undone'; fi
# Once undone, vps check must report the item as undone, not as broken.
module_result() { record "result $1 $2"; }
restore_resource() { record "resource $1"; if [[ -n "${STATE[$1]:-}" ]]; then STATE[$1]=restored; fi; }
reset; STATE=([bbr_file]=applied)
item_turn_off bbr
grep -Fxq 'result bbr reverted' "$TEST_ROOT/trace" || fail 'undone item not recorded for vps check'
if grep -q '^packages' "$TEST_ROOT/trace"; then fail 'BBR off offered a package removal'; fi
# TCP buffers: the file first, then the recorded running values.
reset; STATE=([tcp_file]=applied)
item_turn_off tcp
[[ "$(tr '\n' ' ' < "$TEST_ROOT/trace")" == 'resource tcp_file sysctl runtime result tcp reverted ' ]] || fail "TCP buffer undo: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
# Automatic updates off: the package this tool installed for them is offered too.
restore_tool_packages() { printf '%s\n' htop unattended-upgrades tmux; }
reset; STATE=([apt_file]=applied)
item_turn_off updates
grep -Fxq 'packages unattended-upgrades' "$TEST_ROOT/trace" || fail 'updates off did not offer removing unattended-upgrades'
# Ubuntu ships it preinstalled: then nothing is offered.
restore_tool_packages() { :; }
reset; STATE=([apt_file]=applied)
item_turn_off updates
if grep -q '^packages' "$TEST_ROOT/trace"; then fail 'a preinstalled unattended-upgrades was offered for removal'; fi
# The SSH hardening undone on its own: password login works again, Fail2ban
# is not there (left out on a key-only machine under 1 GiB): turning it on is
# suggested, with the firewall on or not; otherwise nothing is said.
(
  load_optimizer_functions f2b_password_note
  restore_group_pending() { return 0; }
  restore_group_apply() { record "apply $1"; }
  restore_groups() { echo ssh; }
  restore_tool_packages() { :; }
  ufw_active() { ((UFW)); }
  active() { [[ "$1" == fail2ban ]] && ((F2B)); }
  ssh_password_disabled() { ((PW_OFF)); }
  note() { grep -q 'Fail2ban 没有运行' "$TEST_ROOT/log"; }
  UFW=1 F2B=0 PW_OFF=0
  reset; item_turn_off ssh > "$TEST_ROOT/out"
  note && grep -q '单项设置 → Fail2ban' "$TEST_ROOT/out" || fail 'turning Fail2ban on not suggested after password login came back'
  reset; printf '1\n' > "$TEST_ROOT/pick"; RESTORE_PARTIAL=0
  restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
  note || fail 'not suggested after undoing the SSH hardening from the rollback menu'
  UFW=0; reset; item_turn_off ssh > "$TEST_ROOT/out"
  note || fail 'not suggested with the firewall off: Fail2ban does not need it'
  for case in 'F2B=1' 'PW_OFF=1'; do
    UFW=1 F2B=0 PW_OFF=0; eval "$case"
    reset; item_turn_off ssh > /dev/null
    if note; then fail "Fail2ban suggested although $case"; fi
  done
  UFW=1 F2B=0 PW_OFF=0; reset; item_turn_off bbr > /dev/null
  if note; then fail 'Fail2ban suggested after undoing another item'; fi
)
restore_resource() { record "resource $1"; }
reset; TOOLS_PACKAGES=(curl htop)
item_turn_off tools
grep -Fxq 'packages curl htop' "$TEST_ROOT/trace" || fail 'tools off did not offer removal of tool packages only'
UFW_ON=1
ufw_active() { ((UFW_ON)); }
ufw() { [[ "$*" == '--force disable' ]] || fail "unexpected ufw $*"; record 'ufw off'; UFW_ON=0; }
restore_adopt() { record "adopt $1"; }
reset; item_firewall_pause
[[ "$(cat "$TEST_ROOT/trace")" == $'ufw off\nadopt ufw_runtime' ]] || fail 'firewall pause must record the new state'
# What the pause says of Fail2ban follows its ban action: the UFW rules of
# 2.8 stop working with UFW, the nftables sets do not.
(
  F2B_ACTION_FILE="$TEST_ROOT/f2b-action.conf"
  f2b_action_legacy_text > "$F2B_ACTION_FILE"; UFW_ON=1
  out="$(item_firewall_pause)"
  [[ "$out" == *'Fail2ban 的封禁也不起作用'* ]] || fail "pause with the UFW bans: $out"
  f2b_action_text > "$F2B_ACTION_FILE"; UFW_ON=1
  out="$(item_firewall_pause)"
  [[ "$out" == *'Fail2ban 的封禁照常'* && "$out" != *不起作用* ]] || fail "pause with the nftables bans: $out"
)
# The pages and the menus of the single items (two levels since 3.2).
load_optimizer_functions item_page item_group_menu item_overview item_status
ui_columns() { printf '%s\n' "${COLUMNS:-80}"; }
say() { printf '\n[%s]\n' "$*"; }
SYM_OK='+' SYM_HAVE='=' SYM_SKIP='-' SYM_WARN='!' C_OK='' C_DIM='' C_WARN='' C_BOLD='' C_RESET=''
item_turn_on() { record "on $1"; }
# The state of an item is what the test says here; what it is read from is
# tested further down, with the real item_probe.
PROBE=$'on\t已开启'
item_probe() { printf '%s\n' "$PROBE"; }
port_menu() { record 'port menu'; }
reset; printf '5\n' | item_action firewall > /dev/null; UFW_ON=1
item_action firewall < <(printf '1\n') > /dev/null
item_action upgrade < <(printf '2\n') > /dev/null
item_action bbr < <(printf '1\n') > /dev/null
item_action ports < /dev/null > /dev/null
[[ "$(grep -v '^adopt\|^ufw off' "$TEST_ROOT/trace" | tr '\n' ' ')" == 'on firewall on bbr port menu ' ]] || fail "item dispatch: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
# A number means the same on every page: 1 on, 2 off or undo, 3 the
# parameters, 4 their recommended values, 5 what only this item has. (Before
# 3.0 the login record's "3. 查看登录记录" opened its parameters instead.)
(
  param_adjust() { record "adjust $1"; }
  param_reset() { record "reset $1"; }
  item_turn_off() { record "off $1"; }
  f2b_allowlist_menu() { record allowlist; }
  item_firewall_pause() { record pause; }
  logins_show() { record logins; }
  tcp_bdp_menu() { record bdp; }
  display_name_ask() { record display; }
  reset
  for pair in 'general 3' 'general 4' 'general 1' 'ssh 3' 'ssh 4' 'ssh 1' 'firewall 2' 'firewall 3' 'firewall 4' 'firewall 5' 'fail2ban 3' 'fail2ban 4' 'fail2ban 5' \
      'login 3' 'login 5' 'tcp 3' 'tcp 5' 'hostname 1' 'hostname 2' 'hostname 5' 'bbr 0' 'bbr '; do
    item_action "${pair% *}" <<< "${pair#* }" > /dev/null
  done
  [[ "$(tr '\n' ' ' < "$TEST_ROOT/trace")" == 'adjust general reset general adjust ssh reset ssh on ssh off firewall adjust firewall reset firewall pause adjust fail2ban reset fail2ban allowlist adjust login logins adjust tcp bdp on hostname off hostname display ' ]] ||
    fail "the numbers of a page: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
  # Only looking (the login record, the list of container ports, leaving the
  # page) begins no run; anything that may change something does.
  item_session_begin() { record begin; }
  reset
  dockerfw_show() { record shown; }
  # A key that is no choice (a typo) is refused and begins nothing either.
  for pair in 'login 5' 'dockerfw 5' 'bbr 0' 'bbr ' 'bbr 9' 'bbr x' 'bbr 11' 'bbr 1'; do item_action "${pair% *}" <<< "${pair#* }" > "$TEST_ROOT/page"; done
  [[ "$(tr '\n' ' ' < "$TEST_ROOT/trace")" == 'logins shown begin on bbr ' ]] || fail "what begins a run on the page of an item: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
  reset; item_action bbr <<< 7 > "$TEST_ROOT/page"
  [[ "$(tail -n 1 "$TEST_ROOT/page")" == '无效选项。' && ! -s "$TEST_ROOT/trace" ]] || fail "a typo on the page of an item: $(tail -n 2 "$TEST_ROOT/page") / $(cat "$TEST_ROOT/trace")"
)
printf 'PASS: a number on the page of a single item means the same on every page; only looking begins no run.\n'
# What a page offers follows the state of the item and whose doing it is.
param_names() { [[ "$1" == fail2ban ]] && echo f2b_maxretry; return 0; }
page="$(item_actions bbr off system '未开启（当前 cubic）')"
[[ "$page" == *'1. 开启'* && "$page" != *'2.'* && "$page" == *'0. 返回'* ]] || fail "a page of an item that is off: $page"
page="$(item_actions bbr on tool '已开启')"
[[ "$page" == *'1. 重新应用'* && "$page" == *'2. 关闭'* ]] || fail "a page of an item that is on: $page"
# In force as the system came: nothing of this tool's to undo, and none is
# offered (up to 3.1.4 "2. 关闭" was, and then said there was nothing).
page="$(item_actions bbr on system '已开启')"
[[ "$page" == *'1. 重新应用'* && "$page" != *'2.'* ]] || fail "a page of an item the system came with: $page"
page="$(item_actions fail2ban on tool '已开启')"
[[ "$page" == *'3. 调整参数'* && "$page" != *'4.'* && "$page" == *'5. 管理白名单'* ]] || fail "the page of Fail2ban with nothing adjusted: $page"
PARAMS_FILE="$TEST_ROOT/page-params"; printf 'f2b_maxretry=3\n' > "$PARAMS_FILE"
page="$(item_actions fail2ban on tool '已开启')"
[[ "$page" == *'4. 恢复推荐值'* ]] || fail "the page of Fail2ban with a parameter adjusted: $page"
PARAMS_FILE=/nonexistent/vps-test-params
# Every choice on a line of its own (one line of some 100 columns up to 3.1.4).
[[ "$(grep -c '^  [0-9]\. [^0-9]*$' <<< "$page")" == "$(grep -o '[0-9]\. ' <<< "$page" | wc -l | tr -d ' ')" ]] || fail "choices sharing a line: $page"
# Key-only already (as many cloud images come) with root still allowed in:
# going on to forbid root is offered, which the page did not show before.
page="$(item_actions ssh on system '只允许密钥登录')"
[[ "$page" == *'1. 再禁止 root 直接登录'* && "$page" != *'2.'* ]] || fail "the SSH page of a key-only image: $page"
page="$(item_actions ssh on tool '只允许密钥登录，root 不能直接登录')"
[[ "$page" != *'1.'* && "$page" == *'2. 撤销'* ]] || fail "the SSH page after the full hardening: $page"
page="$(item_actions firewall off system '未开启')"
[[ "$page" == *'1. 开启'* && "$page" != *'5.'* ]] || fail "the firewall page while it is off: $page"
# The page itself: what the item is for, how it stands and whose doing that is.
PROBE=$'on\t已开启'
page="$(item_action fail2ban <<< 0)"
[[ "$page" == *' 作用：同一个 IP 连续输错 SSH 密码'* && "$page" == *' 现在：'*'已开启（系统原来就是这样，不是本工具设的）'* && "$page" == *' 参数：1 个'* ]] || fail "the page of an item: $page"
item_owner() { echo tool; }
page="$(item_action fail2ban <<< 0)"
[[ "$page" == *'已开启（本工具设的，可以撤销）'* ]] || fail "the page of an item this tool set up: $page"
item_owner() { echo system; }
# The state is the first field of what was read, whatever the text says.
PROBE=$'off\t已开启（文字和状态无关）'
[[ "$(item_state bbr)" == off && "$(item_status bbr)" == '已开启（文字和状态无关）' ]] || fail "state and text of an item: $(item_state bbr) / $(item_status bbr)"
[[ "$(item_mark on tool)" == + && "$(item_mark on system)" == = && "$(item_mark off system)" == - && "$(item_mark warn tool)" == '!' && -z "$(item_mark none system)" ]] ||
  fail "marks: $(item_mark on tool) $(item_mark on system) $(item_mark off system) $(item_mark warn tool) <$(item_mark none system)>"
unset -f param_names; load_optimizer_functions param_names
printf 'PASS: the page of a single item says what it is for and offers what fits its state.\n'

# The page comes again after each thing done there, until the user leaves.
PROBE=$'off\t未开启'
load_optimizer_functions item_page
reset; item_page bbr < <(printf '1\n1\n0\n') > "$TEST_ROOT/out"
[[ "$(tr '\n' ' ' < "$TEST_ROOT/trace")" == 'on bbr on bbr ' && "$(grep -c '^ 作用：' "$TEST_ROOT/out")" == 3 ]] || fail "the page of an item after an action: $(tr '\n' ' ' < "$TEST_ROOT/trace") / $(grep -c '^ 作用：' "$TEST_ROOT/out")"

# Two levels: the groups with all their items at a glance, then one group.
PROBE=$'on\t已开启'
reset; item_action() { record "action $1"; ITEM_LEAVE=1; }
printf '2\n1\n0\n0\n' | COLUMNS=80 item_menu > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/trace")" == 'action bbr' ]] || fail "group 2, item 1 did not open BBR: $(cat "$TEST_ROOT/trace")"
first="$(awk '/单项设置：/ {exit} {print}' "$TEST_ROOT/out")"
grep -q '^  2\. 网络 ' <<< "$first" && grep -q '^  7\. 高级 ' <<< "$first" || fail "no groups in the overview: $first"
for key in $(item_keys); do
  grep -Fq -- "$(item_brief "$key" '')" <<< "$first" || fail "$key is missing in the overview: $first"
done
# It fits one screen of 24 lines and 80 columns (the flat list had 43 lines).
(($(wc -l <<< "$first") <= 22)) || fail "the overview has $(wc -l <<< "$first") lines"
while IFS= read -r line; do
  ui_width w "$line"
  ((w <= 80)) || fail "a line of the overview is $w columns wide: $line"
done <<< "$first"
# A narrow terminal: the items go under the name of their group.
narrow="$(COLUMNS=44 item_menu <<< 0)"
while IFS= read -r line; do
  ui_width w "$line"
  ((w <= 44)) || fail "a line of the overview on a narrow terminal is $w columns wide: $line"
done <<< "$narrow"
# The group: its items one on a line, the status column lined up by display width.
second="$(awk '/单项设置：/ {on = 1} on' "$TEST_ROOT/out")"
grep -q '单项设置：网络' <<< "$second" || fail "the group page has no title: $second"
starts="$(sed -n 's/^ *[0-9]*\. \(.*\)  = 已开启$/\1/p' <<< "$second" | while IFS= read -r line; do ui_width "$line"; done | sort -u)"
[[ -n "$starts" && "$(wc -l <<< "$starts")" == 1 ]] || fail "status column not aligned: $(tr '\n' ' ' <<< "$starts") in $second"
# (The page comes again after the item was left: the first one is counted.)
[[ "$(awk '/单项设置：网络/ {n++} n == 1' <<< "$second" | grep -c '^ *[0-9]*[.] .*已开启$')" == "$(item_group_keys 网络 | wc -l | tr -d ' ')" ]] || fail "the group page does not list its items: $second"
[[ "$(item_keys | wc -l | tr -d ' ')" == 33 ]] || fail 'item count'
# Every item is in exactly one group, and the groups are those listed.
[[ "$(while IFS= read -r group; do item_group_keys "$group"; done < <(item_groups) | sort)" == "$(item_keys | sort)" ]] || fail 'the groups do not hold every item once'
(
  # Drawing the lists does not simulate an upgrade or ask sshd for every item.
  load_optimizer_functions item_status item_probe
  apt-get() { fail 'the list ran apt-get'; }
  ITEM_LIST_MODE=1
  [[ "$(item_status upgrade)" == 进入后检查 ]] || fail "upgrade in the list: $(item_status upgrade)"
  ITEM_SSHD_T=$'clientaliveinterval 60\npasswordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no'
  sshd() { fail 'the list asked sshd again'; }
  [[ "$(item_status keepalive)" == '每 60 秒' ]] || fail "keepalive in the list: $(item_status keepalive)"
  [[ "$(item_status ssh)" == '只允许密钥登录，root 不能直接登录' && "$(item_state ssh)" == on ]] || fail "SSH in the list: $(item_status ssh)"
  UFW_CONF="$TEST_ROOT/ufw.conf"; printf 'ENABLED=yes\n' > "$UFW_CONF"
  ufw() { fail 'the list ran ufw'; }
  ufw_active() { fail 'the list ran ufw'; }
  command() { [[ "$2" != ufw ]] || return 0; builtin command "$@"; }
  [[ "$(item_status firewall)" == 已开启 && "$(item_state firewall)" == on ]] || fail "firewall in the list: $(item_status firewall)"
  printf 'ENABLED=no\n' > "$UFW_CONF"
  [[ "$(item_state firewall)" == off ]] || fail "a firewall that is off: $(item_state firewall)"
  load_optimizer_functions quota_gb_text
  quota_status() { printf '830 1000\n'; }
  [[ "$(item_status quota)" == '本周期已用 0.8 GB / 1 GB' ]] || fail "traffic in the list: $(item_status quota)"
  # The state comes from the system: a file of this tool, a running value.
  SYSCTL_HARDENING_FILE="$TEST_ROOT/hardening.conf"
  [[ "$(item_state sysctl)" == off ]] || fail 'kernel parameters without the file'
  : > "$SYSCTL_HARDENING_FILE"
  [[ "$(item_state sysctl)" == on ]] || fail 'kernel parameters with the file'
  sysctl() { echo "${PING_VALUE:-0}"; }
  [[ "$(item_state ping)" == off ]] || fail 'ping answered'
  PING_VALUE=1
  [[ "$(item_state ping)" == on && "$(item_state upgrade)" == none ]] || fail 'ping not answered, or the upgrade taken for a switch'
)
(
  # Whose doing an item is: read from the rollback record alone.
  unset -f item_owner; load_optimizer_functions item_owner
  STATE_ROOT="$TEST_ROOT/owner-state"; mkdir -p "$STATE_ROOT/restore-v2/bbr_file" "$STATE_ROOT/restore-v2/cc" "$STATE_ROOT/restore-v2/packages"
  [[ "$(item_owner bbr)" == system ]] || fail 'an item without a record of a change counted as the tool'"'"'s'
  printf 'clean\n' > "$STATE_ROOT/restore-v2/cc/state"; printf 'restored\n' > "$STATE_ROOT/restore-v2/bbr_file/state"
  [[ "$(item_owner bbr)" == system ]] || fail 'an item whose change was undone counted as the tool'"'"'s'
  printf 'applied\n' > "$STATE_ROOT/restore-v2/bbr_file/state"
  [[ "$(item_owner bbr)" == tool && "$(item_owner sysctl)" == system && "$(item_owner general)" == system ]] || fail "owner: $(item_owner bbr) $(item_owner sysctl) $(item_owner general)"
  TOOLS_PACKAGES=(curl htop)
  printf 'curl\nvnstat\n' > "$STATE_ROOT/restore-v2/packages/installed"; printf 'curl\n' > "$STATE_ROOT/restore-v2/packages/before"
  [[ "$(item_owner tools)" == system && "$(item_owner vnstat)" == tool ]] || fail "owner of packages: $(item_owner tools) $(item_owner vnstat)"
  printf 'htop\n' >> "$STATE_ROOT/restore-v2/packages/installed"
  [[ "$(item_owner tools)" == tool ]] || fail 'a tool package this tool installed'
)
printf 'PASS: the single items are two levels deep, fit a screen, are aligned and do not run the expensive checks for every item.\n'
item_ask_reboot_time <<< '04:30' > /dev/null 2>&1 || fail 'valid reboot time rejected'
# Found on a real VPS: 4:30 was refused although it is a plain time.
item_ask_reboot_time <<< '4:30' > /dev/null 2>&1 || fail 'reboot time without a leading zero rejected'
[[ "$AUTO_REBOOT_TIME" == 04:30 ]] || fail "reboot time not normalized: $AUTO_REBOOT_TIME"
for bad in 24:00 4:5 0430 '04:30 x'; do
  if item_ask_reboot_time <<< "$bad" > /dev/null 2>&1; then fail "invalid reboot time accepted: $bad"; fi
  [[ -z "$AUTO_REBOOT_TIME" ]] || fail "rejected time kept: $bad"
done
printf 'PASS: single-item menu dispatch, undo of own changes only, firewall pause.\n'

# CONNECTED: a typo or lowercase asks again; n, timeout and end of input restore.
guard_input() { printf '%b' "$1" > "$TEST_ROOT/guard-in"; }
active() { [[ ! -e "$TEST_ROOT/guard-stopped" ]]; }
systemctl() {
  case "$1" in
    stop) record 'guard stop'; : > "$TEST_ROOT/guard-stopped" ;;
    show) echo 0 ;;
  esac
}
guard_try() { rm -f "$TEST_ROOT/guard-stopped"; reset; guard_input "$1"; guard_confirm unit "$((SECONDS + 100))" < "$TEST_ROOT/guard-in" > "$TEST_ROOT/guard-out" 2>&1; }
guard_try 'connected\nCONNECTED\n' || fail 'lowercase then CONNECTED was not accepted'
grep -Fq '要用大写' "$TEST_ROOT/guard-out" || fail 'lowercase CONNECTED gave no hint'
grep -Fxq 'guard stop' "$TEST_ROOT/trace" || fail 'guard timer not cancelled'
guard_try 'CONECTED\nCONNECTED\n' || fail 'typo then CONNECTED was not accepted'
grep -Fq '输入的不是 CONNECTED' "$TEST_ROOT/guard-out" || fail 'typo gave no hint'
if guard_try 'n\n'; then fail 'n did not restore'; fi
[[ ! -s "$TEST_ROOT/trace" ]] || fail 'n cancelled the guard timer'
if guard_try 'connected\n'; then fail 'end of input after a typo was accepted'; fi
if guard_try ''; then fail 'no input was accepted'; fi
if guard_confirm unit "$((SECONDS - 1))" < /dev/null > /dev/null 2>&1; then fail 'expired deadline accepted'; fi
# A new login seen by the check command confirms without any input.
rm -f "$TEST_ROOT/guard-stopped"; reset
guard_confirm unit "$((SECONDS + 100))" true < /dev/null > "$TEST_ROOT/guard-out" 2>&1 || fail 'check command did not confirm'
grep -Fxq 'guard stop' "$TEST_ROOT/trace" || fail 'guard timer not cancelled after automatic confirmation'
if guard_confirm unit "$((SECONDS + 100))" false < /dev/null > /dev/null 2>&1; then fail 'failed check plus no input was accepted'; fi
printf 'PASS: CONNECTED retries on typos with an uppercase hint; n, timeout and end of input restore.\n'

# Ubuntu 26.04 release entry.
OS=ubuntu OS_VERSION=26.04
[[ "$(release_info)" == $'resolute\t20310531\tUbuntu 26.04 standard maintenance' ]] || fail 'Ubuntu 26.04 release entry'
printf 'PASS: Ubuntu 26.04 LTS release entry.\n'

# The coreutils self-check passes on GNU coreutils and stops on a difference.
unset -f df
if [[ "$(uname -o 2>/dev/null)" == Msys ]]; then
  printf 'SKIP: coreutils self-check needs Linux permissions (Windows Git Bash cannot chmod).\n'
else
  coreutils_selfcheck || fail 'coreutils self-check failed on this system'
  ( sort() { command sort "$@" | tac; }; if coreutils_selfcheck; then fail 'a sort -V difference was not detected'; fi )
  printf 'PASS: coreutils self-check accepts GNU coreutils and detects a behaviour difference.\n'
fi
