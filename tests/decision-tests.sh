#!/usr/bin/env bash
# Extract only the read-only decision functions. Never source/run the optimizer.
# Functions and their globals are loaded dynamically; CDPATH is deliberately empty.
# shellcheck disable=SC1007,SC2034,SC2218
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEST_SCRIPT="${1:-${VPS_OPT_SCRIPT:-$HERE/../vps-stable-opt.sh}}"
if [[ ! -r "$TEST_SCRIPT" && -r "$HERE/v25-plan.sh" ]]; then TEST_SCRIPT="$HERE/v25-plan.sh"; fi
load_function() {
  local definition
  definition="$(awk -v name="$1" '
    $0 == name "() {" {copy=1;found=1}
    copy {print}
    copy && $0 == "}" {closed=1;exit}
    END {if(!found || !closed) exit 1}
  ' "$TEST_SCRIPT")"
  eval "$definition"
}
for name in journal_policy_paths sysctl_config_files trim_support decision_line decision_file_state decision_journal_state decision_report; do load_function "$name"; done
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
WARNINGS=0
warn() { WARNINGS=$((WARNINGS+1)); printf '%s\n' "$*"; }
JOURNAL_FILE="$TEST_ROOT/managed-journal.conf"
JOURNAL_LIMIT_GB=20
BBR_FILE="$TEST_ROOT/bbr.conf"
MODULE_FILE="$TEST_ROOT/module.conf"
F2B_FILE="$TEST_ROOT/99-vps-stable-sshd.local"
printf '%s\n' '[Journal]' 'SystemMaxUse=100M' 'RuntimeMaxUse=50M' 'MaxRetentionSec=14day' > "$TEST_ROOT/exact.conf"
[[ "$(decision_file_state "$TEST_ROOT/missing" text)" == missing ]] || fail 'missing file not classified'
printf '%s\n' text > "$TEST_ROOT/file"
[[ "$(decision_file_state "$TEST_ROOT/file" text)" == match ]] || fail 'exact file not classified'
[[ "$(decision_file_state "$TEST_ROOT/file" other)" == conflict ]] || fail 'changed file not preserved'
ln -s "$TEST_ROOT/file" "$TEST_ROOT/link"
[[ "$(decision_file_state "$TEST_ROOT/link" text)" == conflict ]] || fail 'symlink not preserved'
[[ "$(decision_file_state "$TEST_ROOT" text)" == conflict ]] || fail 'directory not preserved'
printf '%s\n' '#SystemMaxUse=10M' > "$TEST_ROOT/comment.conf"
[[ "$(decision_journal_state "$TEST_ROOT/comment.conf")" == missing ]] || fail 'comment treated as journal policy'
printf '%s\n' 'SystemMaxUse=30M' > "$TEST_ROOT/custom.conf"
[[ "$(decision_journal_state "$TEST_ROOT/custom.conf")" == custom ]] || fail 'custom journal policy not preserved'
cp -- "$TEST_ROOT/exact.conf" "$JOURNAL_FILE"
[[ "$(decision_journal_state "$JOURNAL_FILE")" == match ]] || fail 'managed journal not recognized'
printf '%s\n' other > "$JOURNAL_FILE"
[[ "$(decision_journal_state "$JOURNAL_FILE")" == conflict ]] || fail 'changed managed journal not preserved'
rm -f -- "$JOURNAL_FILE"

# Mock every system probe. Unexpected mutations fail rather than touch the host.
BBR_CONFLICT=0 SWAP_PRESENT=0 PKG_AVAILABLE=1 NTP_SYNC=no PROVIDER_PRESENT=0
TRIM_ENABLED=0 FIREWALL_ACTIVE=0 FIREWALL_CONFLICT=0 SSH_VERIFIED=1 RULES_SAFE=1 F2B_FOREIGN=0
BBR_CURRENT=cubic BBR_AVAILABLE='reno cubic' QDISC_CURRENT=pfifo_fast
MEM_MIB=1024 ROOT_GIB=10 ROOT_FS=ext4 ROOT_DEV=/dev/vda1
bbr_config_conflict() { warn 'mock confidential config line'; ((BBR_CONFLICT)); }
bbr_set_elsewhere() { ((${BBR_ELSEWHERE:-0})); }
zram_module_available() { ((${ZRAM_MODULE:-1})); }
active() { [[ "$1" == fail2ban ]] && ((${F2B_RUNNING:-0})); }
swap_exists() { ((SWAP_PRESENT)); }
available() { ((PKG_AVAILABLE)); }
installed() { [[ "$1" == chrony ]] && ((PROVIDER_PRESENT)); }
foreign_f2b_config() { ((F2B_FOREIGN)); }
firewall_conflict() { ((FIREWALL_CONFLICT)); }
ssh_detect() { ((SSH_VERIFIED)); }
ufw_stored_rules_safe() { ((RULES_SAFE)); }
ssh_password_disabled() { ((${KEY_ONLY:-0})); }
ufw() {
  [[ "$*" == status ]] || fail "unexpected ufw mutation: $*"
  if ((FIREWALL_ACTIVE)); then printf 'Status: active\n'; else printf 'Status: inactive\n'; fi
}
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_congestion_control') printf '%s\n' "$BBR_CURRENT" ;;
    '-n net.ipv4.tcp_available_congestion_control') printf '%s\n' "$BBR_AVAILABLE" ;;
    '-n net.core.default_qdisc') printf '%s\n' "$QDISC_CURRENT" ;;
    *) fail "unexpected sysctl operation: $*" ;;
  esac
}
timedatectl() {
  [[ "$*" == 'show -p NTPSynchronized --value' ]] || fail "unexpected time mutation: $*"
  printf '%s\n' "$NTP_SYNC"
}
systemctl() {
  [[ "$*" == 'is-enabled -q fstrim.timer' ]] || fail "unexpected service mutation: $*"
  ((TRIM_ENABLED))
}
fstrim() { fail 'read-only report executed TRIM'; }
DISC_MAX=2G
lsblk() { [[ "$*" == '-dn -o DISC-MAX /dev/vda1' ]] || fail "unexpected lsblk $*"; printf '%s\n' "$DISC_MAX"; }
modprobe() { fail 'read-only report loaded a module'; }
apt-get() { fail 'read-only report executed APT'; }
install_pkgs() { fail 'read-only report installed a package'; }
put_file() { fail 'read-only report changed configuration'; }
# Avoid inspecting actual /etc journal files in report cases.
decision_journal_state() { printf '%s\n' "${JOURNAL_STATE:-missing}"; }
assert_contains() { grep -Fq -- "$1" "$TEST_ROOT/report" || fail "missing report text: $1"; }
assert_absent() { if grep -Fq -- "$1" "$TEST_ROOT/report"; then fail "unexpected report text: $1"; fi; }

BBR_ELSEWHERE=1 BBR_AVAILABLE='reno cubic bbr'
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '开机时也会由别的配置文件设置，不再重复写入'
BBR_ELSEWHERE=0 BBR_AVAILABLE='reno cubic'
decision_report 0 0 > "$TEST_ROOT/report"
assert_absent '不再重复写入'
assert_contains '内存低于 2GiB，未发现 Swap/ZRAM'
# Ubuntu cloud kernels have no zram module: the plan says so up front.
ZRAM_MODULE=0
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '这个内核没有 zram 模块'
# Found on a real VPS: a machine already set up still showed Fail2ban as
# "准备调整". This tool's jail in place and running is kept as it is.
assert_contains '配置 SSH 防爆破'
: > "$F2B_FILE"; F2B_RUNNING=1
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '本工具的 Fail2ban 规则已经在运行'
assert_absent '配置 SSH 防爆破'
rm -f "$F2B_FILE"; F2B_RUNNING=0
assert_absent '计划配置约内存一半大小的 ZRAM'
ZRAM_MODULE=1
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '当前未确认 BBR 可用'
assert_absent '内核不支持'
assert_contains '系统盘不大于 20GiB'
assert_contains '必须通过新 SSH 窗口验证'
assert_absent 'mock confidential config line'
assert_contains '会询问是否只允许密钥登录'
assert_contains '80/443 会单独询问'
assert_contains '最先执行'
[[ "$WARNINGS" == 0 ]] || fail 'BBR probe altered warning counter'
KEY_ONLY=1
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '已经只允许密钥登录'
KEY_ONLY=0

PREFLIGHT_BLOCKERS=0 SOURCE_REVIEW_REQUIRED=0
decision_report > "$TEST_ROOT/report"
assert_contains '没有提供本次执行前体检结果'
assert_contains '本次软件源检查结果未知'
decision_report 2 1 > "$TEST_ROOT/report"
assert_contains '2 项阻断问题'
assert_contains '存在需要人工核对的软件源'

BBR_CONFLICT=1 SWAP_PRESENT=1 NTP_SYNC=yes ROOT_GIB=40 FIREWALL_ACTIVE=1 F2B_FOREIGN=1 TRIM_ENABLED=1
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '发现已有或无法读取的 TCP/队列策略'
assert_contains '已发现 Swap/ZRAM 或相关配置'
assert_contains '系统时间已经同步'
assert_contains '系统盘大于 20GiB'
assert_contains 'UFW 已开启，保留已有规则'
assert_contains '已有其他 Fail2ban 管理配置'
assert_contains '定期 TRIM 已启用'
# Disk without discard support: not reported as an enabled TRIM.
DISC_MAX='   0B'
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '系统盘不支持 TRIM'
assert_absent '定期 TRIM 已启用'
DISC_MAX=2G
[[ "$WARNINGS" == 0 ]] || fail 'BBR conflict warning escaped its subshell'

BBR_CONFLICT=0 SWAP_PRESENT=0 MEM_MIB=2048 ROOT_GIB=20 JOURNAL_STATE=custom FIREWALL_ACTIVE=0 FIREWALL_CONFLICT=1
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '内存不少于 2GiB'
assert_contains '已有日志容量或保留时间策略'
assert_contains '发现其他防火墙规则'

FIREWALL_CONFLICT=0 SSH_VERIFIED=0
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '未验证到实际 SSH 监听端口'
SSH_VERIFIED=1 RULES_SAFE=0
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains 'UFW 留有需要人工核对的规则'
RULES_SAFE=1 JOURNAL_STATE=conflict PKG_AVAILABLE=0 MEM_MIB=512 PROVIDER_PRESENT=1 NTP_SYNC=no
decision_report 0 0 > "$TEST_ROOT/report"
assert_contains '目标日志配置已有不同内容'
assert_contains '当前软件索引未确认组件可用'
assert_contains '保留已有 chrony'
printf 'PASS: read-only decisions, current preflight inputs, conservative preservation and no mutation commands.\n'
