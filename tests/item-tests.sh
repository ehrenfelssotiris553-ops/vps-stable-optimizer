#!/usr/bin/env bash
# Tests for the simplified confirmations, the recommended setup set, rollback
# groups, the single-item menu, the coreutils self-check and the Ubuntu 26.04
# release entry. Every system command is a mock; files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions confirm_default_yes upgrade_has_kernel apt_index_stage setup_questions admin_name_valid port_source_valid restore_groups restore_group_label restore_group_ids restore_group_pending restore_group_apply restore_all_groups restore_pick_group restore_firewall_warning item_keys item_label item_turn_off item_action item_firewall_pause item_ask_reboot_time item_menu guard_confirm coreutils_selfcheck release_info
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
printf 'PASS: the recommended set is one question and still respects an empty upgrade.\n'

(
  confirm_yes() {
    case "$1" in
      *SSH\ 登录*) return 1 ;;
      *80*) return 1 ;;
      *) fail "recommended mode asked: $1" ;;
    esac
  }
  confirm_default_yes() { fail "recommended mode asked: $1"; }
  timezone_ask() { fail 'recommended mode asked for the timezone'; }
  hostname_resolves() { return 1; }
  swap_exists() { return 1; }
  RECOMMENDED=1 UPGRADE_APPROVED=1 AUTO_UPDATES=1 MEM_MIB=4096 INSTALL_TOOLS=0 SSH_CONNECTION='203.0.113.9 1 192.0.2.1 22'
  TOOLS_PACKAGES=(curl)
  setup_questions < /dev/null > "$TEST_ROOT/q-out"
  [[ "$INSTALL_TOOLS" == 1 && "$SYSCTL_CHOICE" == 1 && "$KERNEL_CLEAN_CHOICE" == 1 && "$HOSTS_CHOICE" == 1 ]] || fail 'recommended items not set'
  [[ "$VNSTAT_CHOICE" == 0 && "$ZRAM_CHOICE" == 0 && -z "$AUTO_REBOOT_TIME" && -z "$TZ_CHOICE" && "$F2B_IGNORE_CHOICE" == none ]] || fail 'non-recommended items were switched on'
  [[ "$SSH_CHOICE" == 0 && "$WEB_CHOICE" == 0 ]] || fail 'SSH/web questions were not asked separately'
)
printf 'PASS: recommended mode sets only the low-risk items and still asks about SSH and web ports.\n'

# Rollback groups: Fail2ban before the firewall, pending detection, per-item pick.
[[ "$(restore_groups | head -n 2 | tr '\n' ' ')" == 'fail2ban firewall ' ]] || fail 'Fail2ban must be undone before the firewall'
RESTORE_ROOT="$TEST_ROOT/restore-v2"; mkdir -p "$RESTORE_ROOT"
declare -A STATE=()
restore_read() { [[ "$2" == state && -n "${STATE[$1]:-}" ]] || return 1; echo "${STATE[$1]}"; }
for id in bbr_file f2b_jail ufw_runtime; do mkdir -p "$RESTORE_ROOT/$id"; done
STATE=([bbr_file]=applied [f2b_jail]=restored [ufw_runtime]=clean)
restore_group_pending bbr || fail 'applied BBR not pending'
if restore_group_pending fail2ban; then fail 'restored Fail2ban still pending'; fi
if restore_group_pending firewall; then fail 'clean firewall pending'; fi
printf 'ufw limit 22/tcp\n' > "$RESTORE_ROOT/fw_rules"
restore_group_pending firewall || fail 'recorded firewall rules not pending'
rm -f "$RESTORE_ROOT/fw_rules"
restore_firewall_group() { record 'group firewall'; }
restore_fail2ban_group() { record 'group fail2ban'; }
restore_ssh_group() { record 'group ssh'; }
restore_zram_group() { record 'group zram'; }
restore_resource() { record "resource $1"; }
restore_sysctl_runtime() { record 'sysctl runtime'; }
restore_packages_offer() { record "packages $*"; }
restore_value() { echo inactive; }
restore_tool_packages() { :; }
reset; restore_all_groups
[[ "$(head -n 2 "$TEST_ROOT/trace" | tr '\n' ' ')" == 'group fail2ban group firewall ' ]] || fail 'full rollback order'
grep -Fxq 'resource bbr_file' "$TEST_ROOT/trace" || fail 'plain group resources not restored'
grep -Fxq 'packages ' "$TEST_ROOT/trace" || fail 'full rollback did not offer package removal'
confirm_yes() { return 0; }
reset; printf '1\n' > "$TEST_ROOT/pick"
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/trace")" == $'resource bbr_file\nresource bbr_module\nresource cc\nresource qdisc' ]] || fail "per-item rollback touched more than BBR: $(cat "$TEST_ROOT/trace")"
reset; printf '9\n' > "$TEST_ROOT/pick"
restore_pick_group < "$TEST_ROOT/pick" > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/trace" ]] || fail 'invalid pick changed something'
printf 'PASS: rollback groups keep the safe order and per-item rollback touches one group.\n'

# Single-item menu: off undoes only this tool's change; firewall pause; dispatch.
reset; STATE=()
item_turn_off bbr
grep -Fq '本工具没有改过' "$TEST_ROOT/log" || fail 'untouched item not explained'
[[ ! -s "$TEST_ROOT/trace" ]] || fail 'untouched item was changed'
reset; STATE=([bbr_file]=applied)
item_turn_off bbr
grep -Fxq 'resource bbr_file' "$TEST_ROOT/trace" || fail 'item off did not undo the tool change'
reset; TOOLS_PACKAGES=(curl htop)
item_turn_off tools
grep -Fxq 'packages curl htop' "$TEST_ROOT/trace" || fail 'tools off did not offer removal of tool packages only'
UFW_ON=1
ufw_active() { ((UFW_ON)); }
ufw() { [[ "$*" == '--force disable' ]] || fail "unexpected ufw $*"; record 'ufw off'; UFW_ON=0; }
restore_adopt() { record "adopt $1"; }
reset; item_firewall_pause
[[ "$(cat "$TEST_ROOT/trace")" == $'ufw off\nadopt ufw_runtime' ]] || fail 'firewall pause must record the new state'
item_turn_on() { record "on $1"; }
item_status() { echo status; }
port_menu() { record 'port menu'; }
reset; printf '2\n' | item_action firewall > /dev/null; UFW_ON=1
item_action firewall < <(printf '1\n') > /dev/null
item_action upgrade < <(printf '2\n') > /dev/null
item_action bbr < <(printf '1\n') > /dev/null
item_action ports < /dev/null > /dev/null
[[ "$(grep -v '^adopt\|^ufw off' "$TEST_ROOT/trace" | tr '\n' ' ')" == 'on firewall on bbr port menu ' ]] || fail "item dispatch: $(tr '\n' ' ' < "$TEST_ROOT/trace")"
reset; item_action() { record "action $1"; }
printf '4\n0\n' | item_menu > /dev/null
[[ "$(cat "$TEST_ROOT/trace")" == 'action bbr' ]] || fail 'menu number did not map to the item'
[[ "$(item_keys | wc -l | tr -d ' ')" == 18 ]] || fail 'item count'
printf '04:30\n' | item_ask_reboot_time 2>/dev/null || fail 'valid reboot time rejected'
if printf '4:30\n' | item_ask_reboot_time 2>/dev/null; then fail 'invalid reboot time accepted'; fi
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
