#!/usr/bin/env bash
# Extracts actual definitions only; never sources/runs optimizer top-level code.
# Every child program and backup fixture stays inside one temporary directory.
set -Eeuo pipefail
export LC_ALL=C
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions menu_action records_report state_path_safe menu menu_entries menu_render menu_header menu_ip ui_width display_name_get menu_login_alert login_recent menu_quota_alert quota_status
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# No display name stored (the header shows the hostname).
PARAMS_FILE="$TEST_ROOT/params"
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
  check) exit "${CHECK_EXIT:-0}" ;;
  firewall|ssh|port|records|uninstall|update|bans) exit 0 ;;
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
CHECK_EXIT=3 menu_action "$CHILD_SCRIPT" check > "$TEST_ROOT/check-output" 2>&1
grep -Fq '验收发现有项目未生效' "$TEST_ROOT/check-output" || fail 'failed acceptance items reported as a generic failure'
for action in firewall ssh port check records uninstall update bans; do
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

# The menu numbers, grouped by how often each item is used (update last).
(
  eval "$(declare -f menu | sed 's/\[\[ -t 0 \]\] || die/true || die/')"
  # shellcheck disable=SC2034
  SCRIPT_VERSION=9.9.9 OS=debian OS_VERSION=13 ROOT_GIB=20 STATE_ROOT="$TEST_ROOT/state" LOG_DIR="$TEST_ROOT/logs" COLUMNS=100
  menu_reboot_hint() { :; }
  menu_pending_reboot_hint() { echo 'PENDING-REBOOT-HINT'; }
  setup_tmux_running() { return 0; }
  systemctl() { return 1; }
  menu_action() { printf '%s\n' "$2" >> "$TEST_ROOT/menu-actions"; }
  : > "$TEST_ROOT/menu-actions"
  # 1 opens the read-only checks: 1 the plan, 2 performance, 3 resources.
  # 7 opens the security audit (1) and the login record (2).
  { printf '1\n1\n\n'; for n in $(seq 2 14) 15; do if ((n == 7)); then printf '7\n1\n\n'; else printf '%s\n\n' "$n"; fi; done
    printf '1\n2\n\n1\n3\n\n1\n\n7\n2\n\n7\n\n'; } > "$TEST_ROOT/menu-input"
  printf '0\n' >> "$TEST_ROOT/menu-input"
  menu < "$TEST_ROOT/menu-input" > "$TEST_ROOT/menu-out"
  expected='plan setup check port item bans audit reboot firewall ssh records rollback uninstall update perf resources logins '
  [[ "$(tr '\n' ' ' < "$TEST_ROOT/menu-actions")" == "$expected" ]] || fail "menu numbers map to: $(tr '\n' ' ' < "$TEST_ROOT/menu-actions")"
  if grep -Fq '还在开发中' "$TEST_ROOT/menu-out"; then fail '7 still says the security audit is to come'; fi
  grep -Fq '无效选项，请输入 0 至 14 或 h' "$TEST_ROOT/menu-out" || fail 'number 15 not rejected'
  grep -Fq '14. 检查更新' "$TEST_ROOT/menu-out" || fail 'update is not the last item'
  grep -Fq '3. 开荒验收' "$TEST_ROOT/menu-out" || fail 'acceptance check does not follow setup'
  grep -Fq '第一次用：先选 1 体检' "$TEST_ROOT/menu-out" || fail 'no first-time hint before any setup'
  # Banners: an update waiting for a reboot, and a setup still running in tmux.
  grep -Fq 'PENDING-REBOOT-HINT' "$TEST_ROOT/menu-out" || fail 'pending reboot not shown in the menu'
  grep -Fq '一键开荒正在 tmux 里运行' "$TEST_ROOT/menu-out" || fail 'setup running in tmux not shown in the menu'
)
printf '%s\n' 'PASS: menu numbers follow the grouped order, with update last.'

# Two columns on a wide terminal, aligned by display width (CJK counts two);
# one column on a narrow one; every entry in both.
(
  wide="$(menu_render 100)" narrow="$(menu_render 44)"
  for f in "$wide" "$narrow"; do
    grep -Eq '^  h\. 使用说明 +0\. 退出$' <<< "$f" || fail "no help and exit line: $f"
  done
  for n in $(seq 1 14); do
    grep -Eq "(^| )$n\. " <<< "$wide" || fail "entry $n missing from the wide menu"
    grep -Eq "^ *$n\. " <<< "$narrow" || fail "entry $n missing from the narrow menu"
  done
  grep -Eq '^  1\. 体检.* 4\. 端口管理$' <<< "$wide" || fail "groups not side by side: $wide"
  grep -Fxq '  4. 端口管理' <<< "$narrow" || fail "narrow menu not one column: $narrow"
  # The right column lines up: in every row with two entries, the right
  # entry's dot (the 4th column of its cell) is at the same display column.
  two='[0-9]\. .* [0-9]{1,2}\. ' upto='^(.* [0-9]{1,2})\. '
  starts="$(while IFS= read -r line; do
    [[ "$line" =~ $two && "$line" =~ $upto ]] || continue
    ui_width "${BASH_REMATCH[1]}"; done <<< "$wide" | sort -u)"
  [[ -n "$starts" && "$(wc -l <<< "$starts")" == 1 ]] || fail "right column not aligned: dots at $(tr '\n' ' ' <<< "$starts")"
  if grep -q ' $' <<< "$wide"; then fail 'trailing spaces in the wide menu'; fi
)
printf '%s\n' 'PASS: the menu is two aligned columns when wide and one when narrow.'

# After an update the new version's menu opens (exec), unless it does not parse.
grep -A4 'if \[\[ "$action" == update && "$(sha256sum' "$TEST_SCRIPT" | grep -Fq 'exec /bin/bash -- "$self" menu' ||
  fail 'an update does not open the new menu'
grep -A3 'if \[\[ "$action" == update && "$(sha256sum' "$TEST_SCRIPT" | grep -Fq 'bash -n -- "$self"' ||
  fail 'the updated script is not checked before it replaces the menu'
printf '%s\n' 'PASS: after an update the new version of the menu opens.'

# The menu says when an update waits for a reboot, and for how long; a newer
# kernel that was already there at boot (a provider kernel) is left to vps check.
(
  load_optimizer_functions menu_pending_reboot_hint boot_kernels
  B="$TEST_ROOT/boot"; mkdir -p "$B"
  : > "$B/vmlinuz-6.1.0-10-amd64"; : > "$B/vmlinuz-6.1.0-11-amd64"
  RUNNING=6.1.0-10-amd64
  uname() { echo "$RUNNING"; }
  printf '100.00 50.00\n' > "$TEST_ROOT/up-short"
  printf '0.00 0.00\n' > "$TEST_ROOT/up-zero"
  out="$(menu_pending_reboot_hint "$B" "$TEST_ROOT/no-flag" "$TEST_ROOT/up-short")"
  [[ "$out" == *'新内核 6.1.0-11-amd64 已经装好，重启后才会用上：方便时选 8 重启。'* ]] || fail "new kernel not announced: $out"
  [[ -z "$(menu_pending_reboot_hint "$B" "$TEST_ROOT/no-flag" "$TEST_ROOT/up-zero")" ]] || fail 'a kernel present at boot was announced'
  touch -d '3 days ago' "$TEST_ROOT/flag"
  out="$(menu_pending_reboot_hint "$B" "$TEST_ROOT/flag" "$TEST_ROOT/up-zero")"
  [[ "$out" == *'有系统更新要重启后才完全生效（已等 3 天）'* ]] || fail "reboot-required flag not announced with its age: $out"
  RUNNING=6.1.0-11-amd64
  [[ -z "$(menu_pending_reboot_hint "$B" "$TEST_ROOT/no-flag" "$TEST_ROOT/up-short")" ]] || fail 'announced although the newest kernel runs'
)
printf '%s\n' 'PASS: the menu announces an update that waits for a reboot.'

LOG_DIR="$TEST_ROOT/logs"
LEGACY_LOG_DIR="$TEST_ROOT/legacy-logs"
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
if grep -Fq '旧版本的操作日志' "$TEST_ROOT/absent-output"; then fail 'an absent legacy log directory was mentioned'; fi
mkdir -- "$LEGACY_LOG_DIR"
records_report > "$TEST_ROOT/legacy-output"
grep -Fq "旧版本的操作日志：$LEGACY_LOG_DIR" "$TEST_ROOT/legacy-output" || fail 'a legacy log directory was not mentioned'

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
