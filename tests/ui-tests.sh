#!/usr/bin/env bash
# The text interface: display widths for CJK terminals, setup step titles,
# apt's output kept in the log with one progress line on the terminal, and the
# acceptance report with its conclusion first. Every system command is a mock.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions ui_width step apt_run apt_progress verify_line verify_summary
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf 'SAY %s\n' "$*"; }
die() { fail "$*"; }

# Widths as a CJK terminal draws them, whatever the locale of the caller.
for locale in C "$(locale -a 2>/dev/null | grep -im1 '^c\.utf-\?8$' || echo C)"; do
  (
    export LC_ALL="$locale"
    [[ "$(ui_width 'abc')" == 3 ]] || fail "$locale: ASCII width"
    [[ "$(ui_width '中文')" == 4 ]] || fail "$locale: CJK width $(ui_width '中文')"
    [[ "$(ui_width 'a中b：')" == 6 ]] || fail "$locale: mixed width with full-width punctuation"
    [[ "$(ui_width '✔ 好')" == 5 ]] || fail "$locale: a symbol counts two columns, as in Xshell"
    [[ "$(ui_width 'é')" == 1 ]] || fail "$locale: a two-byte letter is one column"
    [[ "$(ui_width '')" == 0 ]] || fail "$locale: empty text"
    ui_width w '端口管理 8080'
    [[ "$w" == 13 ]] || fail "$locale: width stored in a variable: $w"
  )
done
printf 'PASS: display widths count CJK, full-width punctuation and symbols as two columns.\n'

# Setup steps show how far the setup is; a single item shows its title only.
UI_STEPS=0
[[ "$(step 10 '自动安全更新')" == 'SAY 自动安全更新' ]] || fail 'a step outside a setup was numbered'
UI_STEPS=15
out="$(step 5 '系统升级与组件安装')"
[[ "$out" == *'【5/15】系统升级与组件安装'* ]] || fail "step number missing: $out"
[[ "$out" == *'[#####..........]'* ]] || fail "step progress marks: $out"
UI_STEPS=0
printf 'PASS: setup steps are numbered with their progress, single items are not.\n'

# apt during a logged run: everything in the log, what runs and a progress line
# on the terminal, the last lines when it fails, and umask 022 for its scripts.
RUN_LOG="$TEST_ROOT/run.log"; : > "$RUN_LOG"
exec {UI_TTY_FD}> "$TEST_ROOT/tty"
APT_RC=0
apt-get() {
  umask > "$TEST_ROOT/umask"
  [[ "$1 $2" == '-o APT::Status-Fd=3' ]] || fail "status fd not asked for: $*"
  printf 'Get:1 http://deb.example/ trixie/main ufw\n'
  printf 'dpkg: warning: something\n' >&2
  printf 'pmstatus:ufw:16.6667:Preparing ufw\npmstatus:ufw:83.3:Setting up ufw\n' >&3
  if ((APT_RC)); then printf 'E: Sub-process /usr/bin/dpkg returned an error code (1)\n'; fi
  return "$APT_RC"
}
umask 077
out="$(apt_run -y -q -o DPkg::Lock::Timeout=900 install --no-install-recommends ufw)"
[[ "$(cat "$TEST_ROOT/umask")" == 0022 ]] || fail 'package scripts did not get umask 022'
[[ "$(umask)" == 0077 ]] || fail 'the tool umask was not restored'
[[ "$out" == *'apt-get install ufw（完整输出写进日志）'* ]] || fail "what runs is not shown: $out"
if [[ "$out" == *'Get:1'* || "$out" == *'dpkg: warning'* ]]; then fail "apt output reached the screen: $out"; fi
grep -Fq 'Get:1 http://deb.example/' "$RUN_LOG" || fail 'apt output missing from the log'
grep -Fq 'dpkg: warning: something' "$RUN_LOG" || fail 'apt errors missing from the log'
if grep -q 'pmstatus' "$RUN_LOG"; then fail 'status lines went to the log'; fi
grep -Fq '安装和配置 83% ufw' "$TEST_ROOT/tty" || fail "no progress on the terminal: $(cat "$TEST_ROOT/tty")"
APT_RC=100
rc=0; out="$(apt_run -y install ufw)" || rc=$?
[[ "$rc" == 100 ]] || fail "apt's exit code lost: $rc"
[[ "$out" == *'apt-get 没有成功（退出码 100）'* && "$out" == *'E: Sub-process /usr/bin/dpkg returned an error code (1)'* ]] ||
  fail "a failure does not show apt's last lines: $out"
[[ "$out" == *"完整输出：$RUN_LOG"* ]] || fail 'the log is not named after a failure'
# Not a logged run: apt-get as it is (its output where the caller sends it).
RUN_LOG='' APT_RC=0
apt-get() { printf 'plain %s\n' "$*"; }
[[ "$(apt_run update)" == 'plain update' ]] || fail 'apt outside a logged run was changed'
printf 'PASS: apt output goes to the log, the terminal gets a progress line and the last lines of a failure.\n'

# The acceptance report: conclusion and what needs a look first, then the details.
VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_REBOOT=0
verify_checks() {
  verify_line pass 'BBR 网络优化' '默认算法 bbr'
  verify_line fail '防火墙' 'UFW 没有运行'
  verify_line na '时区' '你选择了不处理'
  verify_line reboot '内核' '重启后才会使用'
}
out="$(verify_summary)"
first="$(grep -n '^结论：' <<< "$out" | cut -d: -f1)" details="$(grep -n '^详细：' <<< "$out" | cut -d: -f1)"
[[ -n "$first" && -n "$details" ]] && ((first < details)) || fail "conclusion not before the details: $out"
grep -Fq '结论：1 项正常，1 项未生效，1 项按计划未处理，0 项无法确认，1 项等重启后生效。' <<< "$out" || fail "counts: $out"
issues="$(sed -n "$first,${details}p" <<< "$out")"
grep -Fq '  ✖ 未生效  防火墙：UFW 没有运行' <<< "$issues" || fail "a failed item not listed with the conclusion: $issues"
grep -Fq '  ⚠ 待重启  内核：重启后才会使用' <<< "$issues" || fail 'an item waiting for a reboot not listed with the conclusion'
if grep -q 'BBR' <<< "$issues"; then fail 'an item that passed was listed as needing a look'; fi
for line in '✔ 生效  BBR 网络优化：默认算法 bbr' '✖ 未生效  防火墙：UFW 没有运行' '○ 未处理  时区：你选择了不处理'; do
  sed -n "$details,\$p" <<< "$out" | grep -Fxq "$line" || fail "detail line missing: $line"
done
VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_REBOOT=0
verify_checks() { verify_line pass 'BBR 网络优化' '默认算法 bbr'; }
verify_summary | grep -Fq '✔ 没有需要处理的项目。' || fail 'an all-clear report does not say so'
printf 'PASS: the acceptance report puts its conclusion and the items to look at first.\n'
