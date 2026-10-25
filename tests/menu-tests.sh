#!/usr/bin/env bash
# Extracts actual definitions only; never sources/runs optimizer top-level code.
# Every child program and backup fixture stays inside one temporary directory.
set -Eeuo pipefail
export LC_ALL=C
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions menu_action records_report state_path_safe
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
STATE_REPORT_CALLS=0
state_report() { STATE_REPORT_CALLS=$((STATE_REPORT_CALLS+1)); }

# A real Bash child is required: shell functions mocking bash would conceal
# the errexit regression that isolation is intended to prevent.
CHILD_SCRIPT="$TEST_ROOT/child with spaces.sh"
CHILD_ARGS="$TEST_ROOT/child-args"
CHILD_MARKER="$TEST_ROOT/should-not-run"
export CHILD_ARGS CHILD_MARKER
cat > "$CHILD_SCRIPT" <<'CHILD'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$#" "$1" > "$CHILD_ARGS"
case "$1" in
  plan) exit 23 ;;
  setup) false; printf 'errexit was suppressed\n' > "$CHILD_MARKER" ;;
  firewall|ssh|port|check|records|uninstall) exit 0 ;;
  rollback) exit 2 ;;
  *) exit 99 ;;
esac
CHILD

menu_action "$CHILD_SCRIPT" plan > "$TEST_ROOT/failed-output" 2>&1
printf 'continued\n' > "$TEST_ROOT/parent-continued"
[[ -f "$TEST_ROOT/parent-continued" ]] || fail 'failed child stopped the menu caller'
grep -Fq '23' "$TEST_ROOT/failed-output" || fail 'child exit status was not reported'
[[ "$(cat "$CHILD_ARGS")" == $'1\nplan' ]] || fail 'child arguments or script path were split'

menu_action "$CHILD_SCRIPT" setup > "$TEST_ROOT/errexit-output" 2>&1
[[ ! -e "$CHILD_MARKER" ]] || fail 'child inherited a disabled errexit context'
grep -Fq '退出码 1' "$TEST_ROOT/errexit-output" || fail 'child errexit status was not reported'
menu_action "$CHILD_SCRIPT" rollback > "$TEST_ROOT/partial-output" 2>&1
grep -Fq '撤销只完成了一部分' "$TEST_ROOT/partial-output" || fail 'partial rollback was reported as a generic failure'
for action in firewall ssh port check records uninstall; do
  menu_action "$CHILD_SCRIPT" "$action" > "$TEST_ROOT/success-output" 2>&1
  [[ "$(cat "$CHILD_ARGS")" == "1"$'\n'"$action" ]] || fail 'allowed action was not passed unchanged'
done
printf '%s\n' 'PASS: actual menu dispatcher isolates child failures and preserves child errexit.'

# The dispatch allowlist must reject unknown input before starting the child.
rm -- "$CHILD_ARGS"
set +e
( set -Eeuo pipefail; menu_action "$CHILD_SCRIPT" 'check; touch injected'; printf 'bad\n' > "$CHILD_MARKER" ) > "$TEST_ROOT/invalid-output" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" != 0 ]] || fail 'invalid action was accepted'
[[ ! -e "$CHILD_ARGS" && ! -e "$CHILD_MARKER" ]] || fail 'invalid action reached a child or continued past die'
printf '%s\n' 'PASS: dispatch rejects invalid action text before invoking Bash.'

LOG_DIR="$TEST_ROOT/logs"
STATE_ROOT="$TEST_ROOT/state"
BACKUP_ROOT="$TEST_ROOT/absent-backups"
records_report > "$TEST_ROOT/absent-output"
[[ ! -e "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || fail 'records created an absent backup root'
if ((EUID != 0)); then
  [[ "$STATE_REPORT_CALLS" == 0 ]] || fail 'non-root records accessed private run metadata'
  grep -Fq 'sudo vps records' "$TEST_ROOT/absent-output" || fail 'non-root access guidance missing'
  printf '%s\n' 'PASS: non-root records refuses private metadata and does not create directories.'
  printf '%s\n' 'SKIP: root-only backup listing fixtures; rerun as root to cover these branches.'
  exit 0
fi
[[ "$STATE_REPORT_CALLS" == 1 ]] || fail 'root records did not include run metadata'
grep -Fq '还没有配置备份' "$TEST_ROOT/absent-output" || fail 'absent backup guidance missing'

# All fixtures below belong to the test process; no real backup is consulted.
BACKUP_ROOT="$TEST_ROOT/backups"
mkdir -m 750 -- "$BACKUP_ROOT"
older="$BACKUP_ROOT/run-20261021T010101Z-101-abc123"
newer="$BACKUP_ROOT/run-20261023T020202Z-102-XYZ789"
invalid="$BACKUP_ROOT/run-invalid-name"
linked="$BACKUP_ROOT/run-20261022T020202Z-103-def456"
mkdir -m 710 -- "$older" "$newer" "$invalid" "$TEST_ROOT/external"
printf '%s\n' 'DO-NOT-DISPLAY-RAW-CONFIG' > "$older/recovery-notes.txt"
printf '%s\n' 'DO-NOT-DISPLAY-RAW-CONFIG' > "$newer/manifest.tsv"
printf '%s\n' 'DO-NOT-DISPLAY-RAW-CONFIG' > "$TEST_ROOT/external/private.conf"
ln -s -- "$TEST_ROOT/external" "$linked"
fixture_metadata() { find "$TEST_ROOT/backups" -printf '%P|%y|%m|%l\n' | sort; }
fixture_contents() { sha256sum "$older/recovery-notes.txt" "$newer/manifest.tsv" "$TEST_ROOT/external/private.conf"; }
before_metadata="$(fixture_metadata)"
before_contents="$(fixture_contents)"
records_report > "$TEST_ROOT/records-output"
[[ "$(fixture_metadata)" == "$before_metadata" ]] || fail 'records changed fixture paths or permissions'
[[ "$(fixture_contents)" == "$before_contents" ]] || fail 'records changed fixture contents'
[[ "$(awk '/^  / {count++} END {print count+0}' "$TEST_ROOT/records-output")" == 2 ]] || fail 'records did not restrict listing to valid owned directories'
[[ "$(awk '/^  / {print; exit}' "$TEST_ROOT/records-output")" == "  $newer" ]] || fail 'newer backup was not listed first'
grep -Fxq "  $older" "$TEST_ROOT/records-output" || fail 'valid backup omitted'
if grep -Fq "$invalid" "$TEST_ROOT/records-output" || grep -Fq "$linked" "$TEST_ROOT/records-output"; then fail 'records listed an invalid or symlink backup'; fi
if grep -Fq 'DO-NOT-DISPLAY-RAW-CONFIG' "$TEST_ROOT/records-output"; then fail 'records printed raw backup contents'; fi

# A symlink backup root must be rejected even if its target belongs to root.
BACKUP_ROOT="$TEST_ROOT/root-link"
ln -s -- "$TEST_ROOT/backups" "$BACKUP_ROOT"
records_report > "$TEST_ROOT/symlink-output"
if grep -q '^  ' "$TEST_ROOT/symlink-output"; then fail 'records followed a symlink backup root'; fi
[[ -L "$BACKUP_ROOT" && "$(readlink -- "$BACKUP_ROOT")" == "$TEST_ROOT/backups" ]] || fail 'records changed the symlink root'
[[ "$(fixture_metadata)" == "$before_metadata" && "$(fixture_contents)" == "$before_contents" ]] || fail 'records changed a rejected symlink target'
printf '%s\n' 'PASS: root records lists safe temporary backup directories without changing modes or exposing file contents.'
printf '%s\n' 'NOTE: interactive TTY menu navigation requires a separate manual check.'
