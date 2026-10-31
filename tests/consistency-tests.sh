#!/usr/bin/env bash
# The deliverable's own bookkeeping stays complete: every /etc file this tool
# writes is tracked for rollback, labelled, in a rollback group and backed up
# before a run; every stage that changes the system is tracked; every module
# result is verified; every single-item key has a label, a status, a way to
# turn it on and (where the item has one) a rollback group to undo it.
# Reads the script and calls pure table functions only; nothing is changed.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions restore_ids restore_all_ids restore_label restore_path restore_groups restore_group_label restore_group_ids item_keys item_label
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# The text of one function, in the repository format the tests extract.
source_of() {
  awk -v name="$1" '$0 == name "() {" {copy = 1} copy {print} copy && $0 == "}" {exit}' "$TEST_SCRIPT"
}

# Managed files: the /etc paths assigned at the top level (a vendor default in
# /usr/lib and the lock note in /run are not this tool's configuration).
declare -A PATHS=()
while IFS='=' read -r name value; do
  PATHS[$name]="$value"
  printf -v "$name" '%s' "$value"
done < <(grep -E '^[A-Z][A-Z0-9_]*(_FILE|_DROPIN)=/etc/' "$TEST_SCRIPT")
((${#PATHS[@]} >= 13)) || fail "only ${#PATHS[@]} managed file paths found"

# Stages with rollback tracking: the case labels of restore_ids.
mapfile -t STAGES < <(source_of restore_ids | sed -n 's/^    \([a-z0-9_]*\)) .*/\1/p')
((${#STAGES[@]} >= 10)) || fail "only ${#STAGES[@]} tracked stages found"
mapfile -t IDS < <(restore_all_ids)
mapfile -t RB_GROUPS < <(restore_groups)
declare -A STAGE_OF=() GROUP_OF=() PATH_ID=() KNOWN=()
for id in "${IDS[@]}"; do KNOWN[$id]=1; done
for stage in "${STAGES[@]}"; do
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ -n "${KNOWN[$id]:-}" ]] || fail "stage $stage tracks $id, which restore_all_ids does not list"
    STAGE_OF[$id]+="$stage "
  done < <(restore_ids "$stage")
done
for group in "${RB_GROUPS[@]}"; do
  [[ "$(restore_group_label "$group")" != "$group" ]] || fail "rollback group without a label: $group"
  [[ -n "$(restore_group_ids "$group")" ]] || fail "rollback group without settings: $group"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ -n "${KNOWN[$id]:-}" ]] || fail "rollback group $group restores $id, which restore_all_ids does not list"
    GROUP_OF[$id]+="$group "
  done < <(restore_group_ids "$group")
done
for id in "${IDS[@]}"; do
  [[ "$(restore_label "$id")" != "$id" ]] || fail "tracked setting without a label: $id"
  [[ -n "${STAGE_OF[$id]:-}" ]] || fail "tracked setting that no stage snapshots: $id"
  [[ -n "${GROUP_OF[$id]:-}" ]] || fail "tracked setting in no rollback group: $id"
  if path="$(restore_path "$id")"; then PATH_ID[$path]="$id"; fi
done
printf 'PASS: %s tracked settings are labelled, snapshotted by a stage and in a rollback group.\n' "${#IDS[@]}"

backup="$(source_of backup_configs)"
for name in "${!PATHS[@]}"; do
  path="${PATHS[$name]}"
  [[ -n "${PATH_ID[$path]:-}" ]] || fail "$name ($path) is written but not tracked for rollback"
  if ! grep -Fq "\"\$$name\"" <<< "$backup" && ! grep -Eq "backup_config_group ${path%/*}( |\$)" <<< "$backup"; then
    fail "$name ($path) is not backed up before a run"
  fi
done
printf 'PASS: all %s managed files are tracked for rollback and backed up before a run.\n' "${#PATHS[@]}"

# Stages that change nothing of their own: the snapshot itself, the package
# index, the questions, the read-only acceptance check, and package-only
# installs (packages are recorded separately for optional removal).
untracked=' backup apt_index questions verification tools '
while IFS= read -r stage; do
  [[ "$untracked" == *" $stage "* ]] && continue
  [[ -n "$(restore_ids "$stage")" ]] || fail "stage $stage changes the system without rollback tracking"
done < <(grep -oE 'stage_run [a-z0-9_]+' "$TEST_SCRIPT" | awk '{print $2}' | sort -u)
printf 'PASS: every stage that changes the system is tracked for rollback.\n'

mapfile -t VERIFIED < <(grep -oE 'verify_module [a-z0-9_]+' "$TEST_SCRIPT" | awk '{print $2}')
while IFS= read -r module; do
  # A system upgrade is covered by the kernel line of the check.
  [[ "$module" == upgrade ]] && continue
  [[ " ${VERIFIED[*]} " == *" $module "* ]] || fail "module $module is recorded but never verified"
done < <(grep -oE 'module_result [a-z0-9_]+ ' "$TEST_SCRIPT" | awk '{print $2}' | sort -u)
while IFS= read -r check; do
  grep -q "^$check() {" "$TEST_SCRIPT" || fail "verify_module calls a missing check: $check"
done < <(grep -oE "verify_module [a-z0-9_]+ '[^']*' [a-z0-9_]+" "$TEST_SCRIPT" | awk '{print $NF}')
printf 'PASS: every recorded module is verified by an existing check.\n'

status="$(source_of item_status)"
on="$(source_of item_turn_on)"
while IFS= read -r key; do
  [[ "$(item_label "$key")" != "$key" ]] || fail "item without a label: $key"
  grep -Eq "^    $key\)" <<< "$status" || fail "item without a status line: $key"
  # Port management opens its own menu instead of turning something on.
  if [[ "$key" != ports ]]; then grep -Eq "^    $key\)" <<< "$on" || fail "item $key cannot be turned on"; fi
  case "$key" in
    # One-off actions, the port menu, and packages (offered for removal instead).
    upgrade|kernel|ports|tools|vnstat) ;;
    *) [[ " ${RB_GROUPS[*]} " == *" $key "* ]] || fail "item $key has no rollback group to undo it" ;;
  esac
done < <(item_keys)
printf 'PASS: every single item has a label, a status, a way to turn it on and a way back.\n'
