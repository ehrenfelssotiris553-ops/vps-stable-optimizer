#!/usr/bin/env bash
# Extract real lifecycle helpers; mock Linux probes, never install/uninstall.
# Definitions are loaded dynamically; later mock replacements are deliberate.
# shellcheck disable=SC2034,SC2329,SC2218
set -Eeuo pipefail
export LC_ALL=C
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions state_path_safe tool_fixed_paths tool_data_owned tool_expected_launcher tool_install_owned tool_tree_safe tool_no_pending_firewall
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p -- "$TEST_ROOT/real/nested"
ln -s -- "$TEST_ROOT/real" "$TEST_ROOT/link"
state_path_safe "$TEST_ROOT/real/nested/missing" || fail 'safe absent leaf rejected'
for path in / relative /tmp/../etc /tmp//a /tmp/a/ "$TEST_ROOT/link/file" "$TEST_ROOT/real/../other" $'/tmp/new\nline' $'/tmp/tab\tname'; do
  if state_path_safe "$path"; then fail "unsafe path accepted: $path"; fi
done
printf 'PASS: lifecycle path validator rejects symlink components and traversal.\n'

STATE_ROOT=/var/lib/vps-stable-opt BACKUP_ROOT=/var/backups/vps-stable-opt LOG_DIR=/var/lib/vps-stable-opt/logs LEGACY_LOG_DIR=/var/log/vps-stable-opt
tool_fixed_paths || fail 'fixed data paths rejected'
# Logs no longer go under /var/log (root:syslog 775 on Ubuntu).
LOG_DIR=/var/log/vps-stable-opt
if tool_fixed_paths; then fail 'log directory under /var/log accepted'; fi
LOG_DIR=/var/lib/vps-stable-opt/logs
STATE_ROOT="$TEST_ROOT/alternate"
if tool_fixed_paths; then fail 'override of cleanup target accepted'; fi
STATE_ROOT=/var/lib/vps-stable-opt

# All filesystem operations below redirect to controlled fixtures; no /etc,
# /usr/local, /var/lib, /var/log or /var/backups files are read or changed.
mkdir -p -- "$TEST_ROOT/data" "$TEST_ROOT/install"
printf '%s\n' 'vps-stable-opt-data:2.6' > "$TEST_ROOT/data/.tool-owner"
printf '%s\n' 'vps-stable-opt-installer:2.6' > "$TEST_ROOT/install/.installer-owner"
printf '%064d\n' 0 > "$TEST_ROOT/install/.installed-sha256"
printf '# fixture payload\n' > "$TEST_ROOT/install/vps-stable-opt.sh"
tool_expected_launcher > "$TEST_ROOT/launcher"
fixture_path() {
  case "$1" in
    /var/lib/vps-stable-opt/.tool-owner) printf '%s\n' "$TEST_ROOT/data/.tool-owner" ;;
    /usr/local/lib/vps-stable-opt/*) printf '%s/%s\n' "$TEST_ROOT/install" "${1##*/}" ;;
    /usr/local/bin/vps) printf '%s\n' "$TEST_ROOT/launcher" ;;
    *) return 1 ;;
  esac
}
tool_secure_dir() { [[ "$1" == /var/lib/vps-stable-opt || "$1" == /usr/local/lib/vps-stable-opt ]]; }
tool_secure_file() { local path; path="$(fixture_path "$1")" || return 1; [[ -f "$path" && ! -L "$path" ]]; }
# tool_expected_launcher writes its text with a plain `cat <<EOF`; pass that through.
cat() { local path; if (($# == 0)); then command cat; return; fi; [[ "$1" == -- && $# == 2 ]] || return 99; path="$(fixture_path "$2")" || return 98; command cat -- "$path"; }
stat() { local path; [[ "$1" == -c && "$2" == %s && "$3" == -- && $# == 4 ]] || return 99; path="$(fixture_path "$4")" || return 98; command stat -c '%s' -- "$path"; }
sha256sum() { [[ "$1" == -- && "$2" == /usr/local/lib/vps-stable-opt/vps-stable-opt.sh ]] || return 99; printf '%064d  fixture\n' 0; }
find() { printf '%s\n' .installer-owner vps-stable-opt.sh .installed-sha256; }
tool_data_owned /var/lib/vps-stable-opt || fail 'exact V2.6 data marker rejected'
printf '\n' >> "$TEST_ROOT/data/.tool-owner"
if tool_data_owned /var/lib/vps-stable-opt; then fail 'data marker with extra bytes accepted'; fi
printf '%s\n' 'vps-stable-opt-data:2.4' > "$TEST_ROOT/data/.tool-owner"
if tool_data_owned /var/lib/vps-stable-opt; then fail 'old data marker accepted'; fi
if tool_data_owned /tmp/vps-stable-opt; then fail 'unknown data root accepted'; fi
tool_install_owned || fail 'matching installer marker/hash/launcher rejected'
printf '\n' >> "$TEST_ROOT/launcher"
if tool_install_owned; then fail 'modified launcher accepted'; fi
tool_expected_launcher > "$TEST_ROOT/launcher"
printf '%s\n' 'vps-stable-opt-installer:1' > "$TEST_ROOT/install/.installer-owner"
if tool_install_owned; then fail 'old installer owner marker accepted'; fi
printf '%s\n' 'vps-stable-opt-installer:2.6' > "$TEST_ROOT/install/.installer-owner"
find() { printf '%s\n' .installer-owner vps-stable-opt.sh .installed-sha256 unknown-file; }
if tool_install_owned; then fail 'extra install directory contents accepted'; fi
printf 'PASS: data/install ownership requires exact markers, payload hash, launcher and file list.\n'

tool_data_owned() { [[ "$1" == /var/lib/vps-stable-opt ]]; }
FIND_OUTPUT='' FIND_STATUS=0 MOUNTS=$'/\n/var'
# util-linux 2.40 (Debian 13) refuses --raw together with --list.
findmnt() {
  if [[ " $* " == *' --raw '* && " $* " == *' --list '* ]]; then echo 'findmnt: mutually exclusive arguments: --pairs --list --raw --verify' >&2; return 1; fi
  printf '%s\n' "$MOUNTS"
}
find() { printf '%s' "$FIND_OUTPUT"; return "$FIND_STATUS"; }
tool_tree_safe /var/lib/vps-stable-opt || fail 'safe mocked data tree rejected'
FIND_OUTPUT=x
if tool_tree_safe /var/lib/vps-stable-opt; then fail 'unsafe owned tree contents accepted'; fi
FIND_OUTPUT='' FIND_STATUS=1
if tool_tree_safe /var/lib/vps-stable-opt; then fail 'failed tree inspection accepted'; fi
FIND_STATUS=0 MOUNTS=$'/\n/var/lib/vps-stable-opt/mounted'
if tool_tree_safe /var/lib/vps-stable-opt; then fail 'nested mount accepted'; fi
MOUNTS=$'/\n/var/lib/vps-stable-opt'
if tool_tree_safe /var/lib/vps-stable-opt; then fail 'mounted data root accepted'; fi
MOUNTS=$'/\n/var/lib/vps-stable-opt-other'
tool_tree_safe /var/lib/vps-stable-opt || fail 'unrelated mount blocked cleanup'
printf 'PASS: tree validation refuses unsafe contents, failed probes and nested/root mounts.\n'

TIMER_OUTPUT='' SERVICE_OUTPUT='' SYSTEMCTL_STATUS=0
systemctl() {
  [[ "$1" == list-units ]] || return 99
  [[ " $* " == *' --state=active,activating,deactivating '* ]] || return 98
  if [[ "$2" == --type=timer ]]; then
    # Emulate systemctl's requested state filter for an old stopped timer.
    if [[ "$TIMER_OUTPUT" != *' inactive '* ]]; then printf '%s' "$TIMER_OUTPUT"; fi
  else
    printf '%s' "$SERVICE_OUTPUT"
  fi
  return "$SYSTEMCTL_STATUS"
}
tool_no_pending_firewall || fail 'empty protection tasks rejected'
TIMER_OUTPUT='vps-stable-ufw-rollback-123.timer loaded active waiting'
if tool_no_pending_firewall; then fail 'pending firewall timer accepted'; fi
TIMER_OUTPUT='vps-stable-ufw-rollback-123.timer loaded inactive dead'
tool_no_pending_firewall || fail 'old stopped timer incorrectly blocked uninstall'
TIMER_OUTPUT='' SERVICE_OUTPUT='vps-stable-ufw-rollback-123.service loaded active running'
if tool_no_pending_firewall; then fail 'running firewall protection accepted'; fi
SERVICE_OUTPUT='' TIMER_OUTPUT='vps-stable-ssh-revert-123-456.timer loaded active waiting'
if tool_no_pending_firewall; then fail 'pending SSH revert timer accepted'; fi
TIMER_OUTPUT='' SYSTEMCTL_STATUS=1
if tool_no_pending_firewall; then fail 'unknown protection state accepted'; fi
printf 'PASS: uninstall guard refuses firewall/SSH timers, active services and unknown status.\n'

# Reported on a real VPS: uninstall stopped at "/" because it is not a tool
# path. "/" is accepted as a parent; ownership and permissions still count.
(
  load_optimizer_functions tool_secure_dir
  STAT_UID=0 STAT_MODE=755
  stat() { case "$2" in %u) echo "$STAT_UID" ;; %a) echo "$STAT_MODE" ;; *) return 99 ;; esac; }
  tool_secure_dir / || fail 'root directory rejected as a parent directory'
  STAT_MODE=777
  if tool_secure_dir /; then fail 'world-writable root directory accepted'; fi
  STAT_MODE=755 STAT_UID=1000
  if tool_secure_dir /; then fail 'root directory owned by a user accepted'; fi
  STAT_UID=0
  if tool_secure_dir '/var/../etc'; then fail 'unsafe path accepted'; fi
)
printf 'PASS: uninstall accepts "/" as a parent only when root-owned and not writable by others.\n'

# Found on a real Ubuntu 24.04 VPS: /var/log is root:syslog 775, and setup
# and uninstall both stopped at it. Logs now live in /var/lib; uninstall still
# checks /var/log, but only when an older version left its log directory there.
(
  load_optimizer_functions tool_uninstall_validate
  tool_fixed_paths() { return 0; }
  tool_secure_dir() { [[ "$1" != /var/log ]]; }
  tool_install_owned() { return 0; }
  tool_tree_safe() { return 0; }
  tool_no_pending_firewall() { return 0; }
  die() { printf 'STOP: %s\n' "$*"; exit 3; }
  STATE_ROOT="$TEST_ROOT/no-state" BACKUP_ROOT="$TEST_ROOT/no-backup" LOG_DIR="$TEST_ROOT/no-log" LEGACY_LOG_DIR="$TEST_ROOT/legacy-log"
  ( tool_uninstall_validate ) > /dev/null || fail 'uninstall stopped at a group-writable /var/log without old logs in it'
  mkdir -p "$LEGACY_LOG_DIR"
  if ( tool_uninstall_validate ) > /dev/null; then fail 'old logs under an unsafe /var/log were accepted'; fi
)
printf 'PASS: uninstall looks at /var/log only when old logs are still there.\n'
printf 'NOTE: privileged installation, flock concurrency, TTY confirmations and real deletion require isolated Linux VM validation.\n'
