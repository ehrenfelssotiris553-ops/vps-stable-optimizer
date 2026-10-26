#!/usr/bin/env bash
# Only extracts function definitions. Never sources/runs the optimizer itself.
set -Eeuo pipefail
TEST_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-$TEST_SCRIPT_DIR/../vps-stable-opt.sh}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FUNCTIONS_FILE="$TEST_ROOT/functions.sh"
: > "$FUNCTIONS_FILE"
for function in state_path_safe state_secure_dir state_write state_event prepare_run_state run_records_prune backup_config_path backup_config_group backup_configs stage_run record_failure record_exit finish_run_state state_report record_config_change; do
  grep -Fqx "$function() {" "$SOURCE" || { printf 'Missing function: %s\n' "$function" >&2; exit 1; }
  awk -v fn="$function" '$0==fn"() {" {capture=1} capture {print} capture && $0=="}" {exit}' "$SOURCE" >> "$FUNCTIONS_FILE"
done
printf '%s\n' 'restore_before_stage() { return 0; }' 'restore_after_stage() { return 0; }' >> "$FUNCTIONS_FILE"
# shellcheck source=/dev/null
. "$FUNCTIONS_FILE"
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { :; }
warn() { WARNINGS=$((WARNINGS+1)); printf 'WARN: %s\n' "$*"; }
SCRIPT_VERSION=2.7.1
MODE=setup
OS=debian
OS_VERSION=12
WARNINGS=0
RUN_ID=''
RUN_STATE_DIR=''
RUN_BACKUP_DIR=''
CURRENT_STAGE=''
FAILURE_RECORDED=0
BACKUP_ITEM_COUNT=0
declare -A BACKED_UP_PATHS=()
STATE_ROOT="$TEST_ROOT/state"
BACKUP_ROOT="$TEST_ROOT/backups"

prepare_run_state
[[ "$(cat "$STATE_ROOT/latest")" == "$RUN_ID" && ! -L "$STATE_ROOT/latest" ]]
[[ "$(stat -c %a "$RUN_STATE_DIR")" == 700 && "$(stat -c %a "$RUN_BACKUP_DIR")" == 700 ]]
[[ "$(cat "$RUN_STATE_DIR/status")" == running ]]
[[ "$(cat "$RUN_STATE_DIR/version")" == 2.7.1 ]]
printf '%s\n' 'PASS: run metadata and private snapshot directories created'

mkdir -m 700 -- "$TEST_ROOT/fixture"
printf '%s\n' 'fixture config' > "$TEST_ROOT/fixture/config.conf"
chmod 640 -- "$TEST_ROOT/fixture/config.conf"
printf '%s\n' 'DO-NOT-COPY-PRIVATE-KEY' > "$TEST_ROOT/fixture/private-key"
ln -s private-key "$TEST_ROOT/fixture/link.conf"
backup_config_path "$TEST_ROOT/fixture/config.conf"
backup_config_path "$TEST_ROOT/fixture/link.conf"
backup_config_path "$TEST_ROOT/fixture/missing.conf"
backup_config_path "$TEST_ROOT/fixture/config.conf"
snapshot="$(awk -F '\t' -v p="$TEST_ROOT/fixture/config.conf" '$1==p {print $3}' "$RUN_BACKUP_DIR/manifest.tsv")"
link_snapshot="$(awk -F '\t' -v p="$TEST_ROOT/fixture/link.conf" '$1==p {print $3}' "$RUN_BACKUP_DIR/manifest.tsv")"
cmp -- "$TEST_ROOT/fixture/config.conf" "$snapshot"
[[ "$(stat -c %a "$snapshot")" == 640 ]]
[[ -L "$link_snapshot" && "$(readlink "$link_snapshot")" == private-key ]]
[[ "$(wc -l < "$RUN_BACKUP_DIR/manifest.tsv")" == 4 ]]
grep -Fqx "$TEST_ROOT/fixture/missing.conf"$'\tmissing\t-' "$RUN_BACKUP_DIR/manifest.tsv"
[[ "$(find "$RUN_BACKUP_DIR/files" -maxdepth 1 -type f | wc -l)" == 1 ]]
printf '%s\n' 'PASS: file modes and symlinks preserved, missing paths recorded, duplicate avoided'

record_config_change "$TEST_ROOT/fixture/config.conf" managed-transition
[[ "$(wc -l < "$RUN_STATE_DIR/changes.tsv")" == 2 ]]
grep -Fq "$TEST_ROOT/fixture/config.conf"$'\tmanaged-transition' "$RUN_STATE_DIR/changes.tsv"
[[ "$(stat -c %a "$RUN_STATE_DIR/changes.tsv")" == 600 ]]
printf '%s\n' 'PASS: configuration changes recorded in private plain-text metadata'

successful_stage() { printf '%s\n' success > "$TEST_ROOT/success"; }
stage_run example successful_stage
grep -q $'\texample\tsuccess\t0$' "$RUN_STATE_DIR/stages.tsv"
finish_run_state
record_exit 0
[[ "$(cat "$RUN_STATE_DIR/status")" == completed ]]
before_report="$(find "$STATE_ROOT" -type f -exec sha256sum {} + | sort)"
state_report > "$TEST_ROOT/report"
after_report="$(find "$STATE_ROOT" -type f -exec sha256sum {} + | sort)"
[[ "$before_report" == "$after_report" ]]
grep -q '还没有重启过' "$TEST_ROOT/report"
printf '%s\n' 'PASS: direct successful stage recorded; state report is read only'

# Each negative path runs in a fresh Bash process, preserving real errexit.
# All command replacements only affect temporary fixture operations.
cat > "$TEST_ROOT/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
. "$FUNCTIONS_FILE"
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
ok() { :; }
say() { :; }
warn() { :; }
SCRIPT_VERSION=2.7.1 MODE=setup OS=debian OS_VERSION=12 WARNINGS=0
RUN_ID='' RUN_STATE_DIR='' RUN_BACKUP_DIR='' CURRENT_STAGE='' FAILURE_RECORDED=0 BACKUP_ITEM_COUNT=0
declare -A BACKED_UP_PATHS=()
trap 'code=$?; record_failure "$LINENO" "$code"; exit "$code"' ERR
trap 'record_exit "$?"' EXIT
case "$CASE" in
  stage_failure)
    prepare_run_state
    broken_stage() { false; printf 'SHOULD-NOT-RUN\n' > "$MARKER"; }
    stage_run broken broken_stage
    ;;
  backup_failure)
    prepare_run_state
    cp() { return 77; }
    # Even a caller's condition must not suppress a mandatory backup failure.
    if ! backup_config_path "$FIXTURE"; then :; fi
    printf 'SHOULD-NOT-RUN\n' > "$MARKER"
    ;;
  directory_failure)
    prepare_run_state
    backup_config_path "$FIXTURE"
    printf 'SHOULD-NOT-RUN\n' > "$MARKER"
    ;;
  latest_symlink)
    prepare_run_state
    printf 'SHOULD-NOT-RUN\n' > "$MARKER"
    ;;
esac
RUNNER
export FUNCTIONS_FILE
for case_name in stage_failure backup_failure directory_failure; do
  case_root="$TEST_ROOT/$case_name"
  mkdir -m 700 -- "$case_root"
  fixture="$TEST_ROOT/fixture/config.conf"
  [[ "$case_name" != directory_failure ]] || fixture="$TEST_ROOT/fixture"
  if CASE="$case_name" STATE_ROOT="$case_root/state" BACKUP_ROOT="$case_root/backups" MARKER="$case_root/marker" FIXTURE="$fixture" bash "$TEST_ROOT/runner.sh" > "$case_root/output" 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$case_name" >&2; exit 1
  fi
  [[ ! -e "$case_root/marker" ]]
  failed_id="$(cat "$case_root/state/latest")"
  [[ "$(cat "$case_root/state/$failed_id/status")" == failed ]]
done
failed_id="$(cat "$TEST_ROOT/stage_failure/state/latest")"
grep -q $'\tbroken\tfailed\t1$' "$TEST_ROOT/stage_failure/state/$failed_id/stages.tsv"
printf '%s\n' 'PASS: stage failure halts subsequent commands and ERR/EXIT records failure'
printf '%s\n' 'PASS: failed copy and directory source halt even in a conditional caller'

mkdir -m 700 -- "$TEST_ROOT/link-state"
printf 'KEEP\n' > "$TEST_ROOT/sentinel"
ln -s "$TEST_ROOT/sentinel" "$TEST_ROOT/link-state/latest"
if CASE=latest_symlink STATE_ROOT="$TEST_ROOT/link-state" BACKUP_ROOT="$TEST_ROOT/link-backups" MARKER="$TEST_ROOT/link-marker" bash "$TEST_ROOT/runner.sh" > "$TEST_ROOT/link-output" 2>&1; then
  printf 'FAIL: symlink latest was accepted\n' >&2; exit 1
fi
[[ "$(cat "$TEST_ROOT/sentinel")" == KEEP && ! -e "$TEST_ROOT/link-marker" ]]
printf '%s\n' 'PASS: symlink latest rejected without altering its target'

printf '%s\n' '$(touch SHOULD-NOT-EXECUTE)' > "$STATE_ROOT/latest"
state_report > "$TEST_ROOT/invalid-report"
grep -q '运行编号格式异常' "$TEST_ROOT/invalid-report"
printf '%s\n' 'PASS: state pointer is validated as data, never sourced/evaluated'
printf '%s\n' 'All backup/state mocks passed.'
