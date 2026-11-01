#!/usr/bin/env bash
# Actual journal stage and decision helper; all policy files are fixtures.
# Dynamic extracted functions consume the configuration globals below.
# shellcheck disable=SC2034
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions journal_policy_paths journal_stage decision_file_state decision_journal_state journal_config_text \
  param_value param_read param_recommended param_check param_mode
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { :; }
warn() { printf 'WARN: %s\n' "$*"; }
module_result() { :; }
all_paths="$(journal_policy_paths)"
for directory in /etc/systemd /run/systemd /usr/local/lib/systemd /usr/lib/systemd; do
  grep -Fq "$directory/journald.conf" <<< "$all_paths" || fail "missing policy directory: $directory"
done
ROOT_GIB=10 JOURNAL_LIMIT_GB=20
JOURNAL_FILE="$TEST_ROOT/managed.conf" PARAMS_FILE="$TEST_ROOT/params"
OURS=1
restore_file_ours() { [[ "$1" == journal_file ]] && ((OURS)); }
TRACE="$TEST_ROOT/trace"
POLICY=''
journal_policy_paths() { printf '%s\n' "$POLICY" "$JOURNAL_FILE"; }
put_file() {
  [[ "$1" == "$JOURNAL_FILE" ]] || fail 'stage wrote an unexpected file'
  printf 'put\n' >> "$TRACE"
  printf '%s\n' "$2" > "$JOURNAL_FILE"
}
systemctl() {
  [[ "$*" == 'restart systemd-journald' ]] || fail "unexpected service operation: $*"
  printf 'restart\n' >> "$TRACE"
}
for directory in run usr-local usr-lib; do
  mkdir -p -- "$TEST_ROOT/$directory/journald.conf.d"
  POLICY="$TEST_ROOT/$directory/journald.conf.d/50-vendor.conf"
  printf '[Journal]\nSystemMaxUse=30M\n' > "$POLICY"
  before="$(sha256sum -- "$POLICY")"
  : > "$TRACE"
  [[ "$(decision_journal_state --system)" == custom ]] || fail "vendor policy not reflected in plan: $directory"
  journal_stage
  [[ ! -s "$TRACE" && ! -e "$JOURNAL_FILE" ]] || fail "vendor policy was overridden: $directory"
  [[ "$(sha256sum -- "$POLICY")" == "$before" ]] || fail 'vendor file changed'
done
POLICY="$TEST_ROOT/missing"
: > "$TRACE"
[[ "$(decision_journal_state --system)" == missing ]] || fail 'missing policies misclassified'
journal_stage
[[ "$(cat "$TRACE")" == $'put\nrestart' ]] || fail 'missing policies did not lead to the normal managed setting'
[[ "$(decision_journal_state --system)" == match ]] || fail 'managed policy misclassified'
[[ "$(cat "$JOURNAL_FILE")" == $'[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\nMaxRetentionSec=90day' ]] || fail "managed policy: $(cat "$JOURNAL_FILE")"
printf 'PASS: runtime and vendor journal policies are preserved by planning and execution.\n'

# The 14 days of earlier versions, or new parameters: this tool's own file is
# written again; a file that is not this tool's own stays.
printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\nMaxRetentionSec=14day\n' > "$JOURNAL_FILE"
: > "$TRACE"; journal_stage
grep -Fxq 'MaxRetentionSec=90day' "$JOURNAL_FILE" || fail "an earlier version's file was not brought to 90 days"
printf 'journal_max_mb=20\njournal_days=30\n' > "$PARAMS_FILE"
: > "$TRACE"; journal_stage
[[ "$(cat "$JOURNAL_FILE")" == $'[Journal]\nSystemMaxUse=20M\nRuntimeMaxUse=16M\nMaxRetentionSec=30day' ]] || fail "parameters: $(cat "$JOURNAL_FILE")"
OURS=0; printf '[Journal]\nSystemMaxUse=500M\n' > "$JOURNAL_FILE"
put_file() { [[ ! -e "$1" ]] || return 1; printf '%s\n' "$2" > "$1"; }
journal_stage
[[ "$(cat "$JOURNAL_FILE")" == $'[Journal]\nSystemMaxUse=500M' ]] || fail 'a file that is not this tool was rewritten'
printf 'PASS: the journal limit and retention follow the parameters; earlier 14-day files become 90 days.\n'
