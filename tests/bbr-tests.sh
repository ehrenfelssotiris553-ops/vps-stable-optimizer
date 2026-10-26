#!/usr/bin/env bash
# Pure Bash regression tests. Only actual deliverable functions are loaded;
# never source or execute the complete VPS setup script.
# The sysctl mock is called indirectly; BBR_FILE changes inside ( ) on purpose.
# shellcheck disable=SC2030,SC2031,SC2329
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
HERE="$PWD"
source ./test-common.sh
load_optimizer_functions sysctl_vendor_default sysctl_config_files bbr_config_conflict bbr_stage bbr_report sysctl_boot_value bbr_set_elsewhere
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
BBR_FILE="$TEST_ROOT/99-vps-stable-bbr.conf"
MODULE_FILE="$TEST_ROOT/99-vps-stable-module.conf"
CALLS="$TEST_ROOT/calls"
LOG="$TEST_ROOT/log"
: > "$CALLS"; : > "$LOG"
say() { :; }
ok() { printf '%s\n' "$*" >> "$LOG"; }
warn() { printf '%s\n' "$*" >> "$LOG"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
module_result() { printf 'result %s %s\n' "$1" "$2" >> "$CALLS"; }
expect_conflict() { bbr_config_conflict "$TEST_ROOT/input.conf" || fail "$1"; }
expect_clear() { if bbr_config_conflict "$TEST_ROOT/input.conf"; then fail "$1"; fi; }

printf '%s\n' 'net.ipv4.tcp_congestion_control = cubic' > "$TEST_ROOT/input.conf"
expect_conflict 'dotted conflict'
printf '%s\n' '-net/ipv4/tcp_congestion_control = cubic' > "$TEST_ROOT/input.conf"
expect_conflict 'slash conflict with optional minus'
printf '%s\n' '-net.core.default_qdisc = fq_codel' > "$TEST_ROOT/input.conf"
expect_conflict 'qdisc conflict with optional minus'
printf '%s\n' '  # net.ipv4.tcp_congestion_control = cubic' ' ;net/core/default_qdisc=cake' > "$TEST_ROOT/input.conf"
expect_clear 'whole-line hash and semicolon comments'
printf '%s\n' '  -net/ipv4/tcp_congestion_control = bbr  ' $'\t-net.core.default_qdisc\t=\tfq\t' > "$TEST_ROOT/input.conf"
expect_clear 'matching values with whitespace and minus prefix'
printf '%s' 'net/core/default_qdisc = cake' > "$TEST_ROOT/input.conf"
expect_conflict 'last line without newline'
printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr # trailing text' > "$TEST_ROOT/input.conf"
expect_conflict 'inline text is not silently stripped'
printf '%s\n' '-net.ipv4.tcp_congestion_control' > "$TEST_ROOT/input.conf"
expect_conflict 'explicit glob exclusion policy'
printf '%s\n' 'net.ipv4.tcp_* = cubic' > "$TEST_ROOT/input.conf"
expect_conflict 'wildcard covering target'
printf '%s\n' 'net.ipv4.tcp_keepalive_time = 90' > "$TEST_ROOT/input.conf"
expect_clear 'unrelated sysctl setting'
printf '%s\n' 'net/core/default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' > "$TEST_ROOT/input.conf"
expect_clear 'matching dotted and slash keys'

# Packaged defaults applied before our 99- file are not an administrator policy:
# Ubuntu 22.04 ships /usr/lib/sysctl.d/50-default.conf with fq_codel.
sysctl_vendor_default /usr/lib/sysctl.d/50-default.conf || fail 'Ubuntu 22.04 default treated as administrator policy'
sysctl_vendor_default /lib/sysctl.d/50-default.conf || fail '/lib/sysctl.d default not recognised'
if sysctl_vendor_default /usr/lib/sysctl.d/99-zzz.conf; then fail 'packaged file applied after ours was ignored'; fi
if sysctl_vendor_default /etc/sysctl.d/50-default.conf; then fail '/etc file treated as a packaged default'; fi
if sysctl_vendor_default /usr/local/lib/sysctl.d/50-x.conf; then fail '/usr/local file treated as a packaged default'; fi
mkdir -p "$TEST_ROOT/vendor"
printf '%s\n' '# Fair Queue CoDel packet scheduler to fight bufferbloat' '-net.core.default_qdisc = fq_codel' > "$TEST_ROOT/vendor/50-default.conf"
eval "$(declare -f sysctl_vendor_default | sed '1s/sysctl_vendor_default/real_vendor_default/')"
sysctl_vendor_default() { [[ "$1" == "$TEST_ROOT/vendor/"* ]]; }
if bbr_config_conflict "$TEST_ROOT/vendor/50-default.conf"; then fail 'distribution fq_codel default still blocks BBR'; fi
cp "$TEST_ROOT/vendor/50-default.conf" "$TEST_ROOT/admin.conf"
bbr_config_conflict "$TEST_ROOT/admin.conf" || fail 'the same line from an administrator file no longer blocks BBR'
eval "$(declare -f real_vendor_default | sed '1s/real_vendor_default/sysctl_vendor_default/')"

# The value systemd-sysctl sets at the next boot: name order, last assignment
# wins, an /etc name masks the same name further down, /run and an unlinked
# /etc/sysctl.conf do not count (Debian 13 stopped reading it), and this
# tool's own file is left out. Found on a real VPS: the provider's BBR lived
# only in /etc/sysctl.conf, which Debian 13 no longer applies at boot.
(
  R="$TEST_ROOT/sysroot"
  mkdir -p "$R/etc/sysctl.d" "$R/usr/lib/sysctl.d" "$R/run/sysctl.d"
  boot() { sysctl_boot_value "$1" "$R"; }
  [[ -z "$(boot net.core.default_qdisc)" ]] || fail 'empty sysctl.d gave a value'
  printf -- '-net.core.default_qdisc = fq_codel\n' > "$R/usr/lib/sysctl.d/50-default.conf"
  printf 'net/core/default_qdisc=fq\n net.ipv4.tcp_congestion_control = bbr \n' > "$R/etc/sysctl.d/90-provider.conf"
  [[ "$(boot net.core.default_qdisc)" == fq && "$(boot net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'a later provider file did not win over the packaged default'
  mv "$R/etc/sysctl.d/90-provider.conf" "$R/etc/sysctl.d/10-provider.conf"
  [[ "$(boot net.core.default_qdisc)" == fq_codel ]] || fail 'name order ignored: 50-default runs after 10-provider'
  # A same-named file in /etc masks the packaged one entirely.
  rm "$R/etc/sysctl.d/10-provider.conf"
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$R/usr/lib/sysctl.d/60-bbr.conf"
  [[ "$(boot net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'packaged file not read'
  : > "$R/etc/sysctl.d/60-bbr.conf"
  [[ -z "$(boot net.ipv4.tcp_congestion_control)" ]] || fail 'masked packaged file still counted'
  rm "$R/etc/sysctl.d/60-bbr.conf" "$R/usr/lib/sysctl.d/60-bbr.conf"
  # /run is gone after a reboot; /etc/sysctl.conf counts only through a link.
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$R/run/sysctl.d/90-runtime.conf"
  printf 'net.ipv4.tcp_congestion_control=bbr\nnet.core.default_qdisc=fq\n' > "$R/etc/sysctl.conf"
  [[ -z "$(boot net.ipv4.tcp_congestion_control)" ]] || fail '/run or an unlinked /etc/sysctl.conf counted as boot configuration'
  cp "$R/etc/sysctl.conf" "$R/etc/sysctl.d/99-sysctl.conf"   # Debian 12/Ubuntu link it here
  [[ "$(boot net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'linked /etc/sysctl.conf not read'
  # This tool's own file never counts as "set elsewhere".
  rm "$R/etc/sysctl.d/99-sysctl.conf"
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$R/etc/sysctl.d/99-vps-stable-bbr.conf"
  BBR_FILE="$R/etc/sysctl.d/99-vps-stable-bbr.conf"
  [[ -z "$(boot net.ipv4.tcp_congestion_control)" ]] || fail "this tool's own file counted"
  # Set elsewhere only while also running now.
  printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$R/etc/sysctl.d/90-provider.conf"
  RUNNING=bbr
  sysctl() { case "$*" in '-n net.ipv4.tcp_congestion_control') echo "$RUNNING" ;; '-n net.core.default_qdisc') echo fq ;; esac; }
  bbr_set_elsewhere "$R" || fail 'BBR set at boot and running not recognised'
  RUNNING=cubic
  if bbr_set_elsewhere "$R"; then fail 'BBR not running counted as set'; fi
)

# Retain real parser under another name; redirect the stage scan to temporary
# files and record arguments to verify all system config locations are covered.
eval "$(declare -f bbr_config_conflict | sed '1s/bbr_config_conflict/bbr_real_conflict/')"
bbr_config_conflict() {
  printf 'scan %s\n' "$*" >> "$CALLS"
  bbr_real_conflict "$TEST_ROOT/input.conf"
}
modprobe() { printf '%s\n' modprobe >> "$CALLS"; return "${MODPROBE_FAIL:-0}"; }
grep() {
  if [[ "$*" == *'/etc/modules-load.d/'* ]]; then return 1; fi
  command grep "$@"
}
sysctl() {
  if [[ "$*" == '-n net.ipv4.tcp_available_congestion_control' ]]; then
    printf '%s\n' "${AVAILABLE_CC:-reno cubic bbr}"
  elif [[ "$1" == -w ]]; then
    printf 'write %s\n' "$*" >> "$CALLS"
  elif [[ "$*" == '-n net.ipv4.tcp_congestion_control' ]]; then printf 'bbr\n'
  elif [[ "$*" == '-n net.core.default_qdisc' ]]; then printf 'fq\n'
  else printf 'net.ipv4.tcp_congestion_control = bbr\nnet.core.default_qdisc = fq\n'; fi
}
put_file() {
  printf 'put %s\n' "$1" >> "$CALLS"
  if [[ "$1" == "$BBR_FILE" && "${PERSIST_FAIL:-0}" == 1 ]]; then return 1; fi
  if [[ "$1" == "$MODULE_FILE" && "${MODULE_FAIL:-0}" == 1 ]]; then return 1; fi
  printf '%s\n' "$2" > "$1"
}
tc() { printf '%s\n' 'qdisc fq_codel 0: dev eth0 root refcnt 2'; }
bbr_set_elsewhere() { ((${ELSEWHERE:-0})); }

# Already set at boot by another file and running: no duplicate files.
: > "$CALLS"
ELSEWHERE=1 bbr_stage
if command grep -Eq '^(put|write) ' "$CALLS"; then fail 'BBR already set at boot elsewhere was written again'; fi
command grep -qx 'result bbr present' "$CALLS" || fail 'BBR set elsewhere not recorded as present'

: > "$CALLS"
PERSIST_FAIL=1 bbr_stage
if command grep -q '^write ' "$CALLS"; then fail 'persistence failure changed runtime'; fi
for path in /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
  command grep -Fq "$path" "$CALLS" || fail "missing scan location $path"
done
: > "$CALLS"
MODULE_FAIL=1 bbr_stage
if command grep -q '^write ' "$CALLS"; then fail 'module persistence failure changed runtime'; fi
: > "$CALLS"
bbr_stage
command grep -q '^write -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr$' "$CALLS" || fail 'confirmed persistence did not apply defaults'
command grep -qx 'result bbr applied' "$CALLS" || fail 'applied BBR result not recorded'
command grep -qx 'net.core.default_qdisc = fq' "$BBR_FILE" || fail 'persistent fq line missing'
command grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$BBR_FILE" || fail 'persistent bbr line missing'
: > "$CALLS"
printf '%s\n' 'net/ipv4/tcp_congestion_control=cubic' > "$TEST_ROOT/input.conf"
bbr_stage
if command grep -Eq '^((put|write) |modprobe$)' "$CALLS"; then fail 'conflict performed setup work'; fi
: > "$CALLS"
: > "$TEST_ROOT/input.conf"
AVAILABLE_CC='reno cubic' MODPROBE_FAIL=1 bbr_stage
if command grep -Eq '^(put|write) ' "$CALLS"; then fail 'unsupported kernel changed settings'; fi

bbr_report > "$TEST_ROOT/report"
command grep -q 'fq_codel' "$TEST_ROOT/report" || fail 'actual tc queues missing'
if command grep -q 'BBR + fq currently active' "$TEST_ROOT/report" "$LOG"; then fail 'false active claim'; fi
printf 'PASS: BBR parser, persistence gating, all scan directories, and honest reporting.\n'
