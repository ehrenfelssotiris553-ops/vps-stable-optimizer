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
# The other top-level paths (state, /usr/share), which restore_path names too.
while IFS='=' read -r name value; do
  [[ -n "${PATHS[$name]:-}" ]] || printf -v "$name" '%s' "$value"
done < <(grep -E '^[A-Z][A-Z0-9_]*=/[^ ]*$' "$TEST_SCRIPT")
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

# Package scripts run with the umask of whoever starts apt: every apt-get that
# changes the system goes through apt_run (umask 022). Simulations (-s) and
# apt_run itself are the only other calls.
# apt_run's own lines are left out by position, not by what they say.
direct="$(awk '$0 == "apt_run() {" {skip = 1} !skip {print NR ": " $0} skip && $0 == "}" {skip = 0}' "$TEST_SCRIPT" |
  grep -E '(^|[^-_[:alnum:]])apt-get ' | grep -vE '^[0-9]+: [[:space:]]*#|apt-get -s |'"'"'apt-get upgrade failed'"'" || true)"
[[ -z "$direct" ]] || fail "apt-get called without apt_run (package scripts would inherit umask 077): $direct"
source_of apt_run | grep -Fxq '  umask 022' || fail 'apt_run does not set umask 022'
printf 'PASS: every apt-get that changes the system runs with umask 022.\n'

# Colours and state symbols come only from the interface block at the top, so
# NO_COLOR, a log or a saved report, and VPS_ASCII=1 reach every line.
# The login hook's text is left out by position: PAM runs it as a script of its
# own, which has no C_ variables and writes only to a login terminal.
raw="$(awk '/^login_hook_text\(\) \{$/ {skip = 1} !skip {print NR ":" $0} $0 == "HOOK" {skip = 0}' "$TEST_SCRIPT" |
  grep -F '\033[' | grep -vF "C_OK=\$'" | grep -vF '\r\033[K' || true)"
[[ -z "$raw" ]] || fail "a colour written out instead of a C_ variable: $raw"
# The help text is left out by position, and a line naming the set itself
# ("✔ ⚠ ...", in the symbols setting) is not a state either.
# The check script's text is left out too: its messages go to Telegram, not
# to a terminal.
symbols="$(awk '/<<.(HELP|CHECK).$/ {skip = 1} !skip {print NR ":" $0} $0 == "HELP" || $0 == "CHECK" {skip = 0}' "$TEST_SCRIPT" |
  grep -E '✔|⚠|✖|○|✅|❌|➖|⏳|❓' | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF "SYM_OK='" | grep -vF '✔ ⚠' |
  sed -E 's/\$\{SYM_[A-Z]+-[^}]*\}//g' | grep -E '✔|⚠|✖|○|✅|❌|➖|⏳|❓' || true)"
[[ -z "$symbols" ]] || fail "a state symbol written out instead of a SYM_ variable: $symbols"
# Every question drops what was typed before it was shown (found on a VM: the
# screen redrawn after reconnecting to tmux sent answers to old questions, and
# the next question, the firewall's, took one of them).
for fn in confirm confirm_yes confirm_default_yes guard_confirm; do
  awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | grep -Fx '  input_flush' > /dev/null ||
    fail "$fn does not drop the input typed before its question"
done
# Input from a pipe is never dropped (tests and scripted answers).
eval "$(awk '$0 == "input_flush() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT")"
[[ "$(printf 'y\n' | { input_flush; read -r line; echo "$line"; })" == y ]] || fail 'input from a pipe was dropped'
printf 'PASS: colours and state symbols come only from the interface block.\n'

# Every parameter belongs to an existing single item, and on a small, a middle
# and a large machine its recommendation is allowed and comes with a reason.
(
  load_optimizer_functions param_list param_recommended param_reason param_check param_kind
  while IFS=$'\t' read -r name item label unit; do
    grep -Fxq -- "$item" <(item_keys) || fail "parameter $name belongs to no single item ($item)"
    [[ -n "$label" ]] || fail "parameter $name has no label"
    # Numbers have a unit; a word (an algorithm's name) has none.
    if [[ "$(param_kind "$name")" == int && -z "$unit" ]]; then fail "parameter $name has no unit"; fi
    for MEM_MIB in 512 2048 16384; do
      value="$(param_recommended "$name")" || fail "no recommendation for $name"
      param_check "$name" "$value" > /dev/null || fail "recommendation for $name with $MEM_MIB MiB is not allowed: $value"
      [[ -n "$(param_reason "$name")" ]] || fail "no reason for $name"
    done
  done < <(param_list)
)
printf 'PASS: every parameter belongs to a single item, and its recommendation is allowed and explained.\n'
