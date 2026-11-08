#!/usr/bin/env bash
# Disk cleanup and the one-report health check: what is listed, what goes only
# when chosen, and what never goes. Every system command is a mock.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions clean_size_text clean_sum clean_add clean_scan clean_apply clean_packages clean_main report_main report_services audit_bounded_lines audit_clean_text
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/out"; }
say() { printf 'SAY %s\n' "$*"; }
ok() { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die() { fail "$*"; }
EUID_FAKE=0
validate_vm() { record validate; }
tool_lifecycle_lock() { record lock; }
apt_wait_idle() { :; }
apt_run() { record "apt_run $*"; }
kernel_cleanup() { record "kernels $1"; }
active() { [[ "$1" == docker ]] && ((DOCKER)); }
uname() { echo 6.1.0-9-amd64; }
# More free room at every look (in a file: it is called in $(...) too).
df() { local free; free="$(cat "$TEST_ROOT/free")"; printf 'h h h h h h\n/dev/vda1 100 40 %s 40%% /\n' "$free"; echo $((free + 2048)) > "$TEST_ROOT/free"; }
echo 1000 > "$TEST_ROOT/free"; DOCKER=0

# The real find, on the fixtures: rotated logs by age and name.
LOGS="$TEST_ROOT/log"; mkdir -p "$LOGS/nginx"
PARAMS_FILE="$TEST_ROOT/params"
eval "$(awk '$0 == "clean_old_logs() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed "s#/var/log#$LOGS#")"
for f in syslog.1 syslog.2.gz nginx/access.log.3.xz app.old app.log.2026 wtmp.1 btmp.1 lastlog.old; do printf x > "$LOGS/$f"; touch -d '60 days ago' "$LOGS/$f"; done
: > "$LOGS/fresh.1"; : > "$LOGS/syslog"; touch -d '60 days ago' "$LOGS/syslog"
gone="$(clean_old_logs -printf '%P\n' | sort | tr '\n' ' ')"
[[ "$gone" == 'app.old nginx/access.log.3.xz syslog.1 syslog.2.gz ' ]] || fail "rotated logs picked: $gone"
printf 'clean_log_days=90\n' > "$PARAMS_FILE"
[[ -z "$(clean_old_logs -printf '%P\n')" ]] || fail 'the age is not the parameter'
: > "$PARAMS_FILE"
printf 'PASS: only rotated logs old enough are picked; login records and live logs are not.\n'

[[ "$(clean_size_text 2048)" == '2 KiB' && "$(clean_size_text 5242880)" == '5 MiB' && "$(clean_size_text 1610612736)" == '1.5 GiB' ]] || fail 'sizes in words'
[[ "$(printf '1\n2\n' | clean_sum)" == 3 && "$(clean_sum < /dev/null)" == 0 ]] || fail 'adding up'

# What is on the machine is listed, nothing else; kernels and other packages apart.
SIM=$'Remv linux-image-6.1.0-7-amd64 [1]\nPurg linux-headers-6.1.0-7-amd64 [1]\nRemv linux-image-6.1.0-9-amd64 [1]\nRemv libfoo:amd64 [1]'
apt-get() {
  case "$*" in
    '-s autoremove --purge') printf '%s\n' "$SIM" ;;
    '-s remove '*) printf '%s\n' "${REMOVE_SIM:-Remv libfoo [1]}" ;;
    *) fail "unexpected apt-get $*" ;;
  esac
}
SIZES=''
find() {
  case "$*" in
    */var/cache/apt/archives*) [[ "$SIZES" == *apt* ]] && echo 52428800 ;;
    */var/crash*-delete*) record 'find delete crash' ;;
    */var/crash*) [[ "$SIZES" == *crash* ]] && echo 1048576 ;;
    "$LOGS"*-delete*) record 'find delete logs' ;;
    "$LOGS"*) command find "$@" ;;
  esac
  return 0
}
du() { if [[ "$SIZES" == *journal* ]]; then echo '209715200 /var/log/journal'; else echo '1024 /var/log/journal'; fi; }
journalctl() { record "journalctl $*"; }
docker() {
  case "$*" in
    'images -q --filter dangling=true') printf 'a\nb\n' ;;
    system\ df*) echo 'Build Cache=1.2GB (100%)' ;;
    *) record "docker $*" ;;
  esac
}
SIZES='apt journal crash' DOCKER=1
clean_scan
[[ " ${CLEAN_IDS[*]} " == ' apt journal logs crash docker kernel packages ' ]] || fail "listed: ${CLEAN_IDS[*]}"
[[ "${CLEAN_KERNELS[*]}" == 'linux-headers-6.1.0-7-amd64 linux-image-6.1.0-7-amd64' ]] || fail "kernels: ${CLEAN_KERNELS[*]} (the running one must never be among them)"
[[ "${CLEAN_OTHERS[*]}" == 'linux-image-6.1.0-9-amd64 libfoo' || "${CLEAN_OTHERS[*]}" == 'libfoo linux-image-6.1.0-9-amd64' ]] || fail "others: ${CLEAN_OTHERS[*]}"
[[ "${CLEAN_TEXT[0]}" == *'50 MiB'* && "${CLEAN_TEXT[1]}" == *'200 MiB'*'留 50 MiB'* ]] || fail "texts: ${CLEAN_TEXT[*]}"
SIZES='' DOCKER=0 SIM=''
# Rotated logs gone: nothing at all left to list.
rm -f "$LOGS"/syslog.1 "$LOGS"/syslog.2.gz "$LOGS"/nginx/access.log.3.xz "$LOGS"/app.old
clean_scan
((${#CLEAN_IDS[@]} == 0)) || fail "listed with nothing to clean: ${CLEAN_IDS[*]}"
printf 'PASS: what can go is listed with its size, and only that.\n'

# Docker: untagged images and the build cache only, never volumes or containers.
reset; clean_apply docker
[[ "$(tr '\n' '|' < "$TEST_ROOT/trace")" == 'docker image prune -f|docker builder prune -f|' ]] || fail "Docker: $(cat "$TEST_ROOT/trace")"
reset; clean_apply journal
grep -Fxq 'journalctl --vacuum-size=50M' "$TEST_ROOT/trace" || fail "journal: $(cat "$TEST_ROOT/trace")"
reset; clean_apply kernel
grep -Fxq 'kernels --ask' "$TEST_ROOT/trace" || fail 'old kernels are not asked about'
# Packages: only with a yes, and not when others would go with them.
CLEAN_OTHERS=(libfoo)
confirm_yes() { [[ "$ANSWER" == y ]]; }
reset; ANSWER=n; clean_packages > /dev/null
if grep -q '^apt_run' "$TEST_ROOT/trace"; then fail 'packages removed without a yes'; fi
reset; ANSWER=y; clean_packages > /dev/null
grep -Fq 'apt_run -y -q -o DPkg::Lock::Timeout=900 remove libfoo' "$TEST_ROOT/trace" || fail "packages: $(cat "$TEST_ROOT/trace")"
reset; ANSWER=y; REMOVE_SIM=$'Remv libfoo [1]\nRemv openssh-server [1]'; clean_packages > "$TEST_ROOT/out"
if grep -q '^apt_run' "$TEST_ROOT/trace"; then fail 'removed although something else would go with them'; fi
grep -Fq '连带删除其他软件' "$TEST_ROOT/out" || fail 'not said why nothing was removed'
REMOVE_SIM=''
printf 'PASS: Docker keeps volumes and containers; packages go only on a yes and alone.\n'

# Nothing happens without a choice; only what is chosen goes.
eval "$(declare -f clean_main | sed -e 's/\[\[ -t 0 \]\] || return 0/:/' -e 's/\[\[ \$EUID -eq 0 \]\]/[[ $EUID_FAKE -eq 0 ]]/')"
clean_scan() { CLEAN_IDS=(apt journal logs) CLEAN_TEXT=('A 缓存' 'B 日志' 'C 旧日志'); }
clean_apply() { record "apply $1"; }
clean_top() { record top; }
choose() { reset; echo 1000 > "$TEST_ROOT/free"; printf '%s\n' "$1" | clean_main > "$TEST_ROOT/out"; }
choose ''
[[ ! -s "$TEST_ROOT/trace" ]] || fail "Enter changed something: $(cat "$TEST_ROOT/trace")"
grep -Fq '什么都没有清理' "$TEST_ROOT/out" || fail 'Enter not answered'
grep -Fq '  1. A 缓存' "$TEST_ROOT/out" || fail "not listed before asking: $(cat "$TEST_ROOT/out")"
choose '2 3'
[[ "$(tr '\n' '|' < "$TEST_ROOT/trace")" == 'validate|lock|apply journal|apply logs|' ]] || fail "chosen: $(cat "$TEST_ROOT/trace")"
grep -Fq '多出 2 MiB 可用空间' "$TEST_ROOT/out" || fail "room gained not said: $(cat "$TEST_ROOT/out")"
choose a
[[ "$(grep -c '^apply' "$TEST_ROOT/trace")" == 3 ]] || fail "all: $(cat "$TEST_ROOT/trace")"
choose 'x 9'
if grep -q '^apply' "$TEST_ROOT/trace"; then fail 'an unknown choice cleaned something'; fi
grep -Fq '没有这一项：x' "$TEST_ROOT/out" || fail 'an unknown choice not said'
choose d
[[ "$(cat "$TEST_ROOT/trace")" == top ]] || fail "d: $(cat "$TEST_ROOT/trace")"
printf 'PASS: the cleanup lists first and removes only what is chosen.\n'

# The report: one report, what needs a look first.
(
  SYM_WARN='⚠' SYM_FAIL='✖' SYM_OK='✔' C_OK='' C_RESET='' C_BOLD=''
  eval "$(declare -f report_main | sed -e 's/\[\[ \$EUID -eq 0 \]\]/[[ $EUID_FAKE -eq 0 ]]/')"
  perf_main() { echo '✔ 正常  CPU 被抢：0%'; echo '⚠ 注意  系统盘：用了 95%'; }
  resources_main() { echo '常驻的服务：'; }
  preflight_report() { echo '⚠ 注意  系统盘：用了 95%'; echo '✖ 软件包坏了'; }
  report_services() { echo '没有启动失败的服务。'; }
  out="$(report_main)"
  first="$(grep -n '^结论：' <<< "$out" | cut -d: -f1)" details="$(grep -n '^详细：' <<< "$out" | cut -d: -f1)"
  [[ -n "$first" && -n "$details" ]] && ((first < details)) || fail "conclusion not before the details: $out"
  # The same line from two sections is counted once.
  grep -Fq '结论：有 2 项要留意' <<< "$out" || fail "count: $out"
  sed -n "$first,${details}p" <<< "$out" | grep -Fq '  ✖ 软件包坏了' || fail "a problem not listed first: $out"
  sed -n "$details,\$p" <<< "$out" | grep -Fq '常驻的服务' || fail "details missing: $out"
  perf_main() { echo '✔ 正常  CPU 被抢：0%'; }
  preflight_report() { :; }
  [[ "$(report_main)" == *'结论：没有发现要留意的项目'* ]] || fail "all clear: $(report_main)"
)
printf 'PASS: the machine report puts what needs a look first, each thing once.\n'
