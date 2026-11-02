#!/usr/bin/env bash
# Network items: this tool's own sysctl files (sysctl_owned_apply), connection
# tracking capacity (only raised, the module loaded at boot, usage in vps check),
# not answering ping, SSH keepalive (tested by sshd first), preferring IPv4
# only when IPv6 is broken, the time of the daily upgrade and the tools list.
# Every system command is a mock.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions sysctl_owned_apply restore_sysctl_original conntrack_stage ping_stage check_conntrack check_ping \
  verify_conntrack_usage verify_line verify_set param_value param_read param_recommended param_check param_caution param_store \
  ipv6_broken append_line_safely ipv4_stage check_ipv4 apt_time_apply check_keepalive param_kind
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
STATE_ROOT="$TEST_ROOT/state" PARAMS_FILE="$TEST_ROOT/state/params" RESTORE_ROOT="$TEST_ROOT/restore"
mkdir -p "$STATE_ROOT" "$RESTORE_ROOT"
state_secure_dir() { mkdir -p -- "$1"; }
CONNTRACK_FILE="$TEST_ROOT/conntrack.conf" CONNTRACK_MODULE_FILE="$TEST_ROOT/conntrack-module.conf" PING_FILE="$TEST_ROOT/noping.conf"
declare -A SYSVAL=()
sysctl() {
  case "$1" in
    -n) [[ -n "${SYSVAL[$2]:-}" ]] && echo "${SYSVAL[$2]}" ;;
    -w) record "sysctl $*"; SYSVAL[${2%%=*}]="${2#*=}" ;;
    -e) record "sysctl $*"; while IFS=' =' read -r k v; do [[ "$k" == '#'* || -z "$k" ]] || SYSVAL[$k]="${v# }"; done < "$3" ;;
    *) fail "unexpected sysctl $*" ;;
  esac
}
CONFIGURED=none
sysctl_key_configured() { [[ "$1" == "$CONFIGURED" ]]; }
restore_record_sysctl() { record "orig $1=$2 $3"; grep -q "^$1=" "$RESTORE_ROOT/$3" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "$RESTORE_ROOT/$3"; }
put_file() { [[ ! -e "$1" ]] || return 1; printf '%s\n' "$2" > "$1"; }
module_result() { record "result $1 $2 ${3:-}"; }
OURS=0
restore_file_ours() { ((OURS)); }
sysctl_file_mismatch() {
  local k v
  while IFS=' =' read -r k v; do
    [[ "$k" == '#'* || -z "$k" ]] && continue
    v="${v# }"; [[ "${SYSVAL[$k]:-}" == "$v" ]] || echo "bad $k"
  done < "$1"
}

# Connection tracking not in use (no firewall): nothing to do.
reset; MEM_MIB=2048; conntrack_stage
grep -q '^result conntrack skipped' "$TEST_ROOT/trace" || fail 'conntrack set without the module'
# 2 GiB: 131072 entries, above the kernel's 65536; the 5-day timeout is the kernel's own: not written.
SYSVAL[net.netfilter.nf_conntrack_max]=65536 SYSVAL[net.netfilter.nf_conntrack_tcp_timeout_established]=432000 SYSVAL[net.netfilter.nf_conntrack_count]=100
reset; conntrack_stage
grep -Fxq 'net.netfilter.nf_conntrack_max = 131072' "$CONNTRACK_FILE" || fail "limit not raised: $(cat "$CONNTRACK_FILE")"
if grep -q timeout_established "$CONNTRACK_FILE"; then fail 'the default timeout was written'; fi
[[ "$(cat "$CONNTRACK_MODULE_FILE")" == nf_conntrack ]] || fail 'the module is not loaded before systemd-sysctl at boot'
grep -q '^result conntrack applied' "$TEST_ROOT/trace" || fail 'result'
grep -Fxq 'orig net.netfilter.nf_conntrack_max=65536 conntrack_sysctl_runtime' "$TEST_ROOT/trace" || fail 'original not recorded'
# A shorter timeout from the user: written; the limit from the value before the tool.
param_store conntrack_hours 6
reset; OURS=1; conntrack_stage
grep -Fxq 'net.netfilter.nf_conntrack_tcp_timeout_established = 21600' "$CONNTRACK_FILE" || fail "timeout not written: $(cat "$CONNTRACK_FILE")"
grep -Fxq 'net.netfilter.nf_conntrack_max = 131072' "$CONNTRACK_FILE" || fail 'limit lost when rewritten'
# A kernel limit already larger: never lowered; back to the defaults: file and module go.
param_store conntrack_hours ''
printf 'net.netfilter.nf_conntrack_max=262144\nnet.netfilter.nf_conntrack_tcp_timeout_established=432000\n' > "$RESTORE_ROOT/conntrack_sysctl_runtime"
reset; conntrack_stage
[[ ! -e "$CONNTRACK_FILE" && ! -e "$CONNTRACK_MODULE_FILE" ]] || fail "this tool's files stayed though nothing is raised"
grep -Fxq 'sysctl -w net.netfilter.nf_conntrack_max=262144' "$TEST_ROOT/trace" || fail 'the larger kernel value was not set back'
grep -q '^result conntrack preserved' "$TEST_ROOT/trace" || fail 'result when nothing is raised'
printf 'PASS: connection tracking is only raised, loaded before systemd-sysctl, and goes away when not needed.\n'

# vps check: the values and how full the table is.
rm -f "$RESTORE_ROOT/conntrack_sysctl_runtime"; OURS=0
SYSVAL[net.netfilter.nf_conntrack_max]=65536
reset; conntrack_stage
check_conntrack ''
[[ "$VERIFY_STATUS" == pass ]] || fail "check: $VERIFY_TEXT"
SYSVAL[net.netfilter.nf_conntrack_max]=65536
check_conntrack ''
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *开机时* ]] || fail 'values not applied at boot passed'
VERIFY_NOTICE=0 VERIFY_PASS=0 VERIFY_ISSUES=()
SYSVAL[net.netfilter.nf_conntrack_count]=50000
out="$(verify_conntrack_usage; echo "notice=$VERIFY_NOTICE")"
[[ "$out" == *'⚠ 注意  连接跟踪：用了 76%'* && "$out" == *notice=1 ]] || fail "a full table not noticed: $out"
SYSVAL[net.netfilter.nf_conntrack_count]=10
[[ "$(verify_conntrack_usage)" == *'✔ 正常  连接跟踪：用了 0%'* ]] || fail 'usage not shown'
unset 'SYSVAL[net.netfilter.nf_conntrack_max]'
[[ -z "$(verify_conntrack_usage)" ]] || fail 'usage shown without connection tracking'
printf 'PASS: vps check shows the connection tracking usage and warns when the table gets full.\n'

# Ping: IPv4 and IPv6 switched off, originals recorded, reported when already off.
SYSVAL[net.ipv4.icmp_echo_ignore_all]=0 SYSVAL[net.ipv6.icmp.echo_ignore_all]=0
reset; OURS=0; ping_stage
grep -Fxq 'net.ipv4.icmp_echo_ignore_all = 1' "$PING_FILE" && grep -Fxq 'net.ipv6.icmp.echo_ignore_all = 1' "$PING_FILE" || fail "ping file: $(cat "$PING_FILE")"
grep -Fxq 'orig net.ipv6.icmp.echo_ignore_all=0 ping_sysctl_runtime' "$TEST_ROOT/trace" || fail 'IPv6 original not recorded'
check_ping ''
[[ "$VERIFY_STATUS" == pass ]] || fail 'ping check'
# A key set in another file stays as it is.
rm -f "$PING_FILE"; CONFIGURED=net.ipv6.icmp.echo_ignore_all SYSVAL[net.ipv4.icmp_echo_ignore_all]=0
reset; ping_stage
if grep -q ipv6 "$PING_FILE"; then fail 'a key set elsewhere was written'; fi
CONFIGURED=none
# Not this tool's file: kept, reported.
printf 'net.ipv4.icmp_echo_ignore_all = 0\n' > "$PING_FILE"
reset; OURS=0; ping_stage
grep -q '^result ping preserved file differs' "$TEST_ROOT/trace" || fail 'a foreign file was not kept'
printf 'PASS: not answering ping covers IPv4 and IPv6 and keeps what other files set.\n'

# Parameters: ranges and the recommendation by RAM.
for pair in 256:16384 1024:65536 2048:131072 32768:1048576; do
  MEM_MIB="${pair%%:*}"; [[ "$(param_recommended conntrack_max)" == "${pair#*:}" ]] || fail "recommended for $MEM_MIB MiB: $(param_recommended conntrack_max)"
done
if param_check conntrack_hours 1 > /dev/null; then fail 'a timeout below 2 hours was allowed'; fi
[[ -n "$(param_caution conntrack_hours 3)" ]] || fail 'a short timeout not warned about'
printf 'PASS: the connection tracking parameters follow RAM and keep at least 2 hours.\n'

# SSH keepalive: this tool's drop-in, tested by sshd before the reload; taken
# back when sshd refuses it; an interval set elsewhere stays.
S="$TEST_ROOT/ssh"; mkdir -p "$S/sshd_config.d"; : > "$S/sshd_config"
KEEPALIVE_FILE="$S/sshd_config.d/00-vps-stable-keepalive.conf" SSH_DROPIN="$S/sshd_config.d/01-vps-stable-keyonly.conf"
for fn in keepalive_stage; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/etc/ssh#$S#g")"
done
SSHD_OK=1
sshd() {
  case "$1" in
    -t) ((SSHD_OK)) ;;
    -T) local v=0 f
        for f in "$S"/sshd_config.d/*.conf "$S/sshd_config"; do
          [[ -f "$f" ]] || continue
          v="$(awk '$1 == "ClientAliveInterval" {print $2; exit}' "$f")"; [[ -z "$v" ]] || break; v=0
        done
        echo "clientaliveinterval $v" ;;
  esac
}
ssh_reload() { record 'ssh reload'; }
reset; KEEPALIVE_CHOICE=1 OURS=0; keepalive_stage
grep -Fxq 'ClientAliveInterval 60' "$KEEPALIVE_FILE" && grep -Fxq 'ClientAliveCountMax 3' "$KEEPALIVE_FILE" || fail "keepalive file: $(cat "$KEEPALIVE_FILE")"
grep -Fxq 'ssh reload' "$TEST_ROOT/trace" && grep -q '^result keepalive applied 60 s' "$TEST_ROOT/trace" || fail "keepalive: $(cat "$TEST_ROOT/trace")"
check_keepalive '60 s'
[[ "$VERIFY_STATUS" == pass ]] || fail "keepalive check: $VERIFY_TEXT"
# A new interval: this tool's file is written again.
param_store ssh_keepalive_seconds 30
reset; OURS=1; keepalive_stage
grep -Fxq 'ClientAliveInterval 30' "$KEEPALIVE_FILE" || fail 'new interval not written'
# sshd refuses the configuration: taken back, no reload.
rm -f "$KEEPALIVE_FILE"; SSHD_OK=0
reset; keepalive_stage
[[ ! -e "$KEEPALIVE_FILE" ]] && ! grep -q 'ssh reload' "$TEST_ROOT/trace" && grep -q '^result keepalive failed' "$TEST_ROOT/trace" ||
  fail 'a configuration sshd refused stayed or was reloaded'
SSHD_OK=1
# An interval set elsewhere stays.
printf 'ClientAliveInterval 120\n' > "$S/sshd_config"
reset; keepalive_stage
[[ ! -e "$KEEPALIVE_FILE" ]] && grep -q '^result keepalive preserved ClientAliveInterval 120' "$TEST_ROOT/trace" || fail 'an interval set elsewhere was overridden'
: > "$S/sshd_config"; param_store ssh_keepalive_seconds ''
# The SSH hardening of earlier versions set 300 seconds in its own drop-in
# (01-): not "set elsewhere", and the keepalive file comes first for sshd.
printf 'PasswordAuthentication no\nClientAliveInterval 300\nClientAliveCountMax 2\n' > "$SSH_DROPIN"
reset; keepalive_stage
[[ "$(sshd -T)" == 'clientaliveinterval 60' ]] && grep -q '^result keepalive applied 60 s' "$TEST_ROOT/trace" ||
  fail "an old hardening drop-in kept its 300 seconds: $(sshd -T), $(cat "$TEST_ROOT/trace")"
rm -f "$SSH_DROPIN" "$KEEPALIVE_FILE"
printf 'PASS: SSH keepalive is tested by sshd first, follows its parameter and keeps an interval set elsewhere.\n'

# IPv4 first: only when IPv6 is broken (public IPv6, the mirror unreachable
# over it, reachable over IPv4).
OS=debian GLOBAL6=1 OK_ADDR=''
host_has_global_ipv6() { ((GLOBAL6)); }
getent() {
  case "$1" in ahostsv6) echo '2001:db8::80 STREAM deb.debian.org' ;; ahostsv4) echo '192.0.2.80 STREAM deb.debian.org' ;;
    ahosts) echo "${FIRST:-192.0.2.80} STREAM deb.debian.org" ;; esac
}
timeout() { [[ " $OK_ADDR " == *" $(sed 's#.*/dev/tcp/\([^/]*\)/.*#\1#' <<< "$*") "* ]]; }
OK_ADDR='192.0.2.80'; ipv6_broken || fail 'a broken IPv6 not detected'
OK_ADDR='192.0.2.80 2001:db8::80'; if ipv6_broken; then fail 'a working IPv6 called broken'; fi
OK_ADDR=''; if ipv6_broken; then fail 'no network at all called a broken IPv6'; fi
# One lost IPv6 connection is no reason (seen on a real Debian 13 VPS whose
# IPv6 works): every address is tried twice.
sleep() { :; }
TRIES=0
timeout() {
  local a; a="$(sed 's#.*/dev/tcp/\([^/]*\)/.*#\1#' <<< "$*")"
  if [[ "$a" == *:* ]]; then TRIES=$((TRIES + 1)); if [[ -n "${FLAKY:-}" && "$TRIES" == 1 ]]; then return 1; fi; fi
  [[ " $OK_ADDR " == *" $a "* ]]
}
FLAKY=1 OK_ADDR='192.0.2.80 2001:db8::80'; if ipv6_broken; then fail 'one lost IPv6 connection called a broken IPv6'; fi
FLAKY=''
# Several addresses of the mirror: one of them reachable is enough.
getent() {
  case "$1" in ahostsv6) printf '%s\n' '2001:db8::80 STREAM deb.debian.org' '2001:db8::80 DGRAM' '2001:db8::81 STREAM' ;;
    ahostsv4) echo '192.0.2.80 STREAM deb.debian.org' ;; ahosts) echo "${FIRST:-192.0.2.80} STREAM deb.debian.org" ;; esac
}
OK_ADDR='192.0.2.80 2001:db8::81'; if ipv6_broken; then fail 'a mirror reachable on its second IPv6 address called broken'; fi
OK_ADDR='192.0.2.80'; ipv6_broken || fail 'a broken IPv6 with several addresses not detected'
unset -f sleep
GLOBAL6=0 OK_ADDR='192.0.2.80'; if ipv6_broken; then fail 'a host without IPv6 called broken'; fi
GAI_FILE="$TEST_ROOT/gai.conf"
printf '#precedence ::ffff:0:0/96  100\n' > "$GAI_FILE"
backup_config_path() { :; }
record_config_change() { :; }
reset; IPV4_CHOICE=1; ipv4_stage
grep -Fxq 'precedence ::ffff:0:0/96  100' "$GAI_FILE" && grep -Fxq '#precedence ::ffff:0:0/96  100' "$GAI_FILE" || fail "gai.conf: $(cat "$GAI_FILE")"
grep -q '^OK .*Go 写的程序不读这个设置' "$TEST_ROOT/log" || fail 'the Go programs note is missing'
check_ipv4 ''
[[ "$VERIFY_STATUS" == pass ]] || fail "IPv4 check: $VERIFY_TEXT"
FIRST=2001:db8::80; check_ipv4 ''
[[ "$VERIFY_STATUS" == fail ]] || fail 'IPv6 still first passed'
FIRST=''
printf 'precedence ::1/128 50\n' > "$GAI_FILE"; cp "$GAI_FILE" "$TEST_ROOT/gai.before"
reset; ipv4_stage
cmp -s "$GAI_FILE" "$TEST_ROOT/gai.before" && grep -q '^result ipv4 preserved' "$TEST_ROOT/trace" || fail 'a precedence policy set by someone else was changed'
printf 'PASS: IPv4 first is recommended only for a broken IPv6, written to gai.conf, and keeps an own policy.\n'

# The daily upgrade: the distribution's time without a drop-in; another time
# with one (the timer restarted); back again: the drop-in goes.
APT_TIME_FILE="$TEST_ROOT/timer.d/50-vps-stable-time.conf"; mkdir -p "$TEST_ROOT/timer.d"
active() { return 0; }
systemctl() { record "systemctl $*"; }
reset; apt_time_apply
[[ ! -e "$APT_TIME_FILE" ]] || fail 'a drop-in for the default time'
param_store apt_upgrade_time 03:30
reset; apt_time_apply
grep -Fxq 'OnCalendar=*-*-* 03:30:00' "$APT_TIME_FILE" && grep -Fxq 'OnCalendar=' "$APT_TIME_FILE" || fail "drop-in: $(cat "$APT_TIME_FILE")"
grep -Fxq 'systemctl restart apt-daily-upgrade.timer' "$TEST_ROOT/trace" || fail 'timer not restarted'
param_store apt_upgrade_time ''
reset; OURS=1; apt_time_apply
[[ ! -e "$APT_TIME_FILE" ]] || fail 'the drop-in stayed after going back to the default time'
for bad in 3:30 24:00 '03:30 '; do if param_check apt_upgrade_time "$bad" > /dev/null; then fail "time accepted: <$bad>"; fi; done
printf 'PASS: the time of the daily upgrade is a drop-in only when it differs from the distribution.\n'

# The tools list: package names only, at most 30; dropping tmux is explained.
param_check tools_list 'curl jq mtr-tiny' > /dev/null || fail 'a valid list refused'
for bad in '' 'curl;rm' 'Curl' "$(printf 'p%s ' {1..31})"; do if param_check tools_list "$bad" > /dev/null; then fail "list accepted: <$bad>"; fi; done
[[ -n "$(param_caution tools_list 'curl vim')" ]] || fail 'dropping tmux not explained'
param_store tools_list 'curl jq'
[[ "$(param_value tools_list)" == 'curl jq' ]] || fail 'a list was not kept with its spaces'
printf 'PASS: the tools list takes package names only and keeps its spaces.\n'

# The performance check: from a 3-second sample, stolen CPU and paging are
# reported with what they mean; a quiet machine is all clear.
F="$TEST_ROOT/proc"; mkdir -p "$F/pressure" "$F/net"
for fn in perf_main; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/proc/#$F/#g")"
done
STAT1='cpu 1000 0 1000 7000 0 0 0 0 0 0' STAT2='cpu 1100 0 1100 7600 0 0 0 200 0 0'
# The first read of /proc/stat sees STAT1, every later one STAT2.
printf '%s\n' "$STAT1" > "$F/stat"
sleep() { printf '%s\n' "$STAT2" > "$F/stat"; printf 'pswpin 600\npswpout 600\n' > "$F/vmstat"; }
printf 'pswpin 0\npswpout 0\n' > "$F/vmstat"
printf '0.50 0.40 0.30 1/100 1\n' > "$F/loadavg"
printf 'some avg10=0.00 avg60=0.50 avg300=0.00 total=1\n' | tee "$F/pressure/cpu" "$F/pressure/memory" "$F/pressure/io" > /dev/null
printf 'MemTotal: 1000000 kB\nMemAvailable: 500000 kB\n' > "$F/meminfo"
printf 'Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs\nTcp: 1 200 120000 -1 10 10 0 0 1 1000 1000 5\n' > "$F/net/snmp"
nproc() { echo 2; }
df() { if [[ "$2" == -Pi || "$1" == -Pi ]]; then printf 'h\n/dev/vda1 100 10 90 10%% /\n'; else printf 'h\n/dev/vda1 100 40 60 40%% /\n'; fi; }
say() { :; }
out="$(perf_main)"
[[ "$out" == *'⚠ 注意  CPU 被抢：20%'* ]] || fail "stolen CPU not reported: $out"
[[ "$out" == *'⚠ 注意  换页：每秒约 400 页'* ]] || fail "paging not reported: $out"
[[ "$out" == *'✔ 正常  TCP 重传：开机以来 0.5%'* ]] || fail "retransmissions: $out"
[[ "$out" == *'有 2 项要留意'* ]] || fail "summary: $out"
printf '%s\n' "$STAT1" > "$F/stat"; STAT2='cpu 1100 0 1100 7800 0 0 0 0 0 0'
sleep() { printf '%s\n' "$STAT2" > "$F/stat"; }
printf 'pswpin 0\npswpout 0\n' > "$F/vmstat"
[[ "$(perf_main)" == *'都正常'* ]] || fail 'a quiet machine not all clear'
printf 'PASS: the performance check reports stolen CPU and paging with what they mean.\n'
