#!/usr/bin/env bash
# Extract real lifecycle helpers; mock Linux probes, never install/uninstall.
# Definitions are loaded dynamically; later mock replacements are deliberate.
# shellcheck disable=SC2034,SC2329,SC2218
set -Eeuo pipefail
export LC_ALL=C
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions tool_path_safe tool_fixed_paths tool_data_owned tool_expected_launcher tool_install_owned tool_tree_safe tool_no_pending_firewall
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p -- "$TEST_ROOT/real/nested"
ln -s -- "$TEST_ROOT/real" "$TEST_ROOT/link"
tool_path_safe "$TEST_ROOT/real/nested/missing" || fail 'safe absent leaf rejected'
for path in / relative /tmp/../etc /tmp//a /tmp/a/ "$TEST_ROOT/link/file" "$TEST_ROOT/real/../other" $'/tmp/new\nline' $'/tmp/tab\tname'; do
  if tool_path_safe "$path"; then fail "unsafe path accepted: $path"; fi
done
printf 'PASS: lifecycle path validator rejects symlink components and traversal.\n'

STATE_ROOT=/var/lib/vps-stable-opt BACKUP_ROOT=/var/backups/vps-stable-opt LOG_DIR=/var/log/vps-stable-opt
tool_fixed_paths || fail 'fixed data paths rejected'
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
findmnt() { printf '%s\n' "$MOUNTS"; }
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
printf 'NOTE: privileged installation, flock concurrency, TTY confirmations and real deletion require isolated Linux VM validation.\n'
