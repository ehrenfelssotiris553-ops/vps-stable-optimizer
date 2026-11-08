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

# Stages with rollback tracking: every name in the table's third column.
mapfile -t STAGES < <(restore_table | awk -F'|' '{n = split($3, a, " "); for (i = 1; i <= n; i++) print a[i]}' | sort -u)
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
    # (and the general settings, which are parameters only).
    upgrade|kernel|ports|tools|vnstat|general) ;;
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

# Under pipefail "cmd | grep -q" can fail although grep found the line: grep
# stops at the first match, and a writer that still writes gets SIGPIPE (seen
# with apt-config on Ubuntu 26.04). grep reads to the end instead
# ("> /dev/null"), or reads a variable or a file.
piped="$(grep -nE '(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' "$TEST_SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$piped" ]] || fail "a pipe into grep -q (wrong under pipefail): $piped"
printf 'PASS: no pipe into grep -q.\n'

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

# Every step of one-click setup that decides by itself or asks can be left out
# (setup_skip), and the list of those names is exactly those steps.
block="$(source_of main | awk '/UI_STEPS=15/ {on = 1} on {print} /stage_run verification/ {exit}')"
runs="$(sed -n 's/^ *setup_run \([a-z0-9_]*\) .*/\1/p' <<< "$block" | sort -u | tr '\n' ' ')"
[[ "$runs" == "$(setup_skippable | sort -u | tr '\n' ' ')" ]] || fail "setup steps that can be left out ($runs) and setup_skippable differ"
others="$(sed -n 's/^ *stage_run \([a-z0-9_]*\) .*/\1/p' <<< "$block" | sort -u | tr '\n' ' ')"
[[ "$others" == 'apt_index apt_upgrade questions verification ' ]] || fail "setup steps that cannot be left out: $others"
printf 'PASS: every step of one-click setup can be left out by the parameter.\n'

# No new fixed numbers in what this tool writes to the system (user rule,
# 2026-11-07: every number that is a choice can be adjusted). Each number in
# these functions is listed here with its reason; anything else must come from
# a parameter (param_list). A new number fails here until it is one or is
# listed with a reason.
declare -A FIXED_NUMBERS=(
  # swap-priority: ZRAM is used before any disk swap (an order, not a choice).
  [zram_config_text]='100'
  # Priority: the disk swap after ZRAM (100).
  [swap_unit_text]='10'
  # The runtime journal: half the limit, at least 16 MiB (follows journal_max).
  [journal_config_text]='2 16'
  # The hardened value of each key; each key can be left out (sysctl_hardening_skip).
  [sysctl_hardening_all]='0 1 2'
  # PAM priority 0; the hook under a 3 s timeout so it can never hold up a login.
  [login_pam_text]='0 3'
  # [ -t 1 ]: only on a terminal.
  [login_profile_text]='1'
  # Field numbers and exit codes, umask 077 and mode 755, the red colour (31,
  # escape 033), seconds per minute and day, C.UTF-8, the sshd lines of the last
  # 600 s (50 at most) matched within 120 s, the last 300 records compared, and
  # the cut lengths of names (32), addresses (64) and lines (20); 6: the number
  # of the security audit in the menu, as a text to the user.
  [login_hook_text]='0 1 2 3 4 5 6 7 8 9 20 31 32 033 50 60 64 077 120 300 600 755 86400'
  # Positional ${2}; minutes and days in seconds.
  [f2b_jail_text]='2 60 86400'
  # Positional ${7}; localhost (127.0.0.1/8, ::1) is never banned.
  [f2b_jail_values_text]='1 7 8 127'
  # Minutes and hours.
  [f2b_policy_text]='0 60'
  # Bans are remembered at least a week, longer with a longer longest ban (f2b_maxtime_days).
  [f2b_db_text]='86400 604800'
  # Fail2ban's default port, replaced by each jail's own; priority -1 (the
  # ban chain before UFW's at 0); 2> (an IPv6 address is no IPv4 element).
  [f2b_action_text]='1 2 22'
  # Positional $1 and the root switch (0/1); the limits are parameters.
  [ssh_dropin_text]='0 1'
  # Nice=10 (in the background); 110 s: room for the daily summary's acceptance check (60 s).
  [check_service_text]='10 110'
  # *:0/N (N is check_minutes_*); AccuracySec=5s.
  [check_timer_text]='0 5'
  [zram_sysctl_pairs]='' [ping_ufw_text]='' [f2b_bootstrap_text]='' [ssh_port_text]='' [dockerlog_text]=''
)
for fn in "${!FIXED_NUMBERS[@]}"; do
  body="$(source_of "$fn" | grep -v '^[[:space:]]*#')"
  [[ -n "$body" ]] || fail "$fn not found"
  for n in $(grep -oE '(^|[^A-Za-z0-9_.$@])[0-9]+' <<< "$body" | grep -oE '[0-9]+' | sort -u); do
    [[ " ${FIXED_NUMBERS[$fn]} " == *" $n "* ]] || fail "$fn writes the fixed number $n: make it a parameter (param_list) or list it in consistency-tests with its reason"
  done
done
printf 'PASS: what this tool writes to the system has no fixed number without a reason.\n'

# The check script's fallbacks when a parameter is missing are the
# recommended values: a second copy of a number must not drift.
fallbacks="$(source_of notify_check_text | grep -oE "(num|param) [a-z_]+ ('[^']*'|[^ )\"']+)\)" |
  sed -E "s/^(num|param) ([a-z_]+) '?([^')]*)'?\)$/\2\t\3/")"
[[ "$(grep -c . <<< "$fallbacks")" -ge 10 ]] || fail "check script fallbacks not found: $fallbacks"
while IFS=$'\t' read -r name def; do
  want="$(param_recommended "$name")"
  [[ "$def" == "$want" ]] || fail "the check script falls back to $def for $name, the recommended value is $want"
done <<< "$fallbacks"
printf 'PASS: the check script falls back to the recommended value of each parameter.\n'

# Every parameter is in the README's table, by the name the menu shows.
README_FILE="$(dirname -- "$TEST_SCRIPT")/README.md"
[[ -r "$README_FILE" ]] || README_FILE="$HERE/../README.md"
while IFS=$'\t' read -r name _item label _unit; do
  grep -Fq "| $label |" "$README_FILE" || fail "parameter $name ($label) is not in the README's table"
done < <(param_list)
printf 'PASS: every parameter is in the README, by the name the menu shows.\n'

# The launcher install.sh writes is the one the main script knows (the
# uninstall checks it), and both know the same earlier ones (replaced on an
# upgrade, accepted until then).
INSTALL_SH="$(dirname -- "$TEST_SCRIPT")/install.sh"
[[ -r "$INSTALL_SH" ]] || INSTALL_SH="$HERE/../install.sh"
(
  load_optimizer_functions tool_expected_launcher tool_known_launchers
  launcher="$(awk '/^cat > "\$TMP_DIR\/launcher" <</ {f = 1; next} f && /^EOF$/ {exit} f' "$INSTALL_SH")"
  [[ -n "$launcher" && "$launcher" == "$(tool_expected_launcher)" ]] || fail 'install.sh writes another launcher than tool_expected_launcher'
  known="$(sed -n "s/^KNOWN_LAUNCHERS='\(.*\)'$/\1/p" "$INSTALL_SH")"
  [[ -n "$known" && "$known" == "$(tool_known_launchers)" ]] || fail "earlier launchers: install.sh $known, tool_known_launchers $(tool_known_launchers)"
)
printf 'PASS: install.sh writes the launcher the main script knows, and both know the same earlier ones.\n'
