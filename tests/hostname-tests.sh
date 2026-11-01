#!/usr/bin/env bash
# Renaming the machine and its display name: valid names only, /etc/hosts gets
# a line only when the new name does not resolve (and loses this tool's line for
# the old name), cloud-init is told to keep the name, the rollback undoes the
# rename and nothing else, and vps check sees a name changed back at boot.
# Every system command is a mock; all files live under mktemp.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions hostname_valid hostname_ask hostname_resolves append_line_safely restore_record_hosts_line \
  restore_hosts_lines_apply restore_data_safe state_path_safe display_name_get display_name_ask param_store ui_width verify_set
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
H="$TEST_ROOT/hosts" N="$TEST_ROOT/hostname" C="$TEST_ROOT/cloud/cloud.cfg.d"
# The functions that name /etc/hosts, /etc/hostname or cloud-init's directory
# work on fixtures here.
for fn in hostname_hosts_update hostname_stage check_hostname restore_hostname_group cloud_hosts_managed cloud_hosts_refresh; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" |
    sed -e "s#/etc/hosts#$H#g" -e "s#/etc/hostname#$N#g" -e "s#/etc/cloud/cloud.cfg.d#$C#g")"
done
RESTORE_ROOT="$TEST_ROOT/restore" RESTORE_READY=1 STATE_ROOT="$TEST_ROOT/state" PARAMS_FILE="$TEST_ROOT/state/params"
mkdir -p "$RESTORE_ROOT" "$STATE_ROOT" "$C"; chmod 700 "$RESTORE_ROOT"
CLOUD_HOSTNAME_FILE="$C/99-vps-stable-hostname.cfg"
restore_path() { [[ "$1" == hosts_file ]] && printf '%s\n' "$H"; }
hostname() { cat "$N"; }
hostnamectl() { record "hostnamectl $*"; ((${HOSTNAMECTL_FAILS:-0} == 0)) || return 1; printf '%s\n' "${*: -1}" > "$N"; }
getent() { [[ "$1" == hosts ]] && awk -v n="$2" '{for (i = 2; i <= NF; i++) if ($i == n) f = 1} END {exit !f}' "$H"; }
backup_config_path() { :; }
record_config_change() { :; }
put_file() { [[ ! -e "$1" ]] || return 1; mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
OURS=1
restore_file_ours() { [[ "$1" == cloud_hostname_file ]] && ((OURS)); }
module_result() { record "result $1 $2 ${3:-}"; }
state_secure_dir() { mkdir -p -- "$1"; }
# cloud-init as on Debian's images: /etc/hosts written from the template with
# the configured name (the one in this tool's file, if any).
MARK="# Your system has configured 'manage_etc_hosts' as True."
cloud-init() {
  record "cloud-init $*"
  local name
  name="$(awk '$1 == "hostname:" {print $2}' "$CLOUD_HOSTNAME_FILE" 2>/dev/null)"
  printf '%s\n127.0.1.1 %s %s\n127.0.0.1 localhost\n' "$MARK" "${name:-provider-name}" "${name:-provider-name}" > "$H"
}

# Names this tool sets.
for good in vps tokyo-1 a.b-c.example x1 "$(printf 'a%.0s' {1..63})"; do hostname_valid "$good" || fail "rejected: $good"; done
for bad in '' -a a- Tokyo a_b 'a..b' '.a' 'a b' '中文' "$(printf 'a%.0s' {1..64})"; do
  if hostname_valid "$bad"; then fail "accepted: <$bad>"; fi
done
printf 'PASS: only lowercase letters, digits and hyphens, at most 63 characters.\n'

# A rename on a Debian-style image ("127.0.1.1 debian" from the image).
printf '127.0.0.1\tlocalhost\n127.0.1.1\tdebian\n' > "$H"; printf 'debian\n' > "$N"
reset; HOSTNAME_CHOICE=tokyo-1; hostname_stage
grep -Fxq 'hostnamectl --static --transient set-hostname tokyo-1' "$TEST_ROOT/trace" || fail "hostnamectl: $(cat "$TEST_ROOT/trace")"
grep -Fxq $'127.0.1.1\ttokyo-1' "$H" || fail "the new name got no hosts line: $(cat "$H")"
grep -Fxq $'127.0.1.1\tdebian' "$H" || fail "the image's line was touched"
grep -Fxq $'127.0.1.1\ttokyo-1' "$RESTORE_ROOT/hostname_hosts_line" || fail 'the added line is not recorded for the rollback'
[[ ! -e "$RESTORE_ROOT/hosts_line" ]] || fail "the rename used the setup's hosts record"
grep -Fxq 'preserve_hostname: true' "$CLOUD_HOSTNAME_FILE" && grep -Fxq 'hostname: tokyo-1' "$CLOUD_HOSTNAME_FILE" ||
  fail "cloud-init not told to keep the name: $(cat "$CLOUD_HOSTNAME_FILE" 2>/dev/null)"
grep -q '^result hostname applied tokyo-1' "$TEST_ROOT/trace" || fail 'rename result not recorded'
# Renamed again: this tool's line for tokyo-1 goes, tokyo-2 gets one, the
# cloud-init file is rewritten.
reset; HOSTNAME_CHOICE=tokyo-2; hostname_stage
if grep -q 'tokyo-1' "$H" "$RESTORE_ROOT/hostname_hosts_line"; then fail 'the old name of this tool stayed in /etc/hosts or its record'; fi
grep -Fxq $'127.0.1.1\ttokyo-2' "$H" || fail 'second rename got no hosts line'
grep -Fxq 'hostname: tokyo-2' "$CLOUD_HOSTNAME_FILE" || fail 'cloud-init file not rewritten'
# A name that already resolves gets no line; without cloud-init no file.
reset; printf '127.0.0.1\tlocalhost\n10.0.0.5\tweb01\n' > "$H"; rm -rf "$C" "$RESTORE_ROOT/hostname_hosts_line"
HOSTNAME_CHOICE=web01; hostname_stage
[[ "$(grep -c web01 "$H")" == 1 ]] || fail 'a line added for a name that resolves'
[[ ! -e "$CLOUD_HOSTNAME_FILE" ]] || fail 'a cloud-init file written without cloud-init'
# hostnamectl failing: nothing else is touched.
mkdir -p "$C"; cp "$H" "$TEST_ROOT/hosts.before"
reset; HOSTNAMECTL_FAILS=1 HOSTNAME_CHOICE=other; hostname_stage
HOSTNAMECTL_FAILS=0
cmp -s "$H" "$TEST_ROOT/hosts.before" || fail '/etc/hosts changed although the rename failed'
grep -q '^result hostname failed' "$TEST_ROOT/trace" || fail 'failed rename not recorded'
printf 'PASS: a rename sets both names, a hosts line only when needed, and tells cloud-init to keep it.\n'

# Where cloud-init writes /etc/hosts (Debian's images), it writes it again with
# the new name right away, and with the old one when the rename is undone.
rm -rf "$C" "$RESTORE_ROOT/hostname_hosts_line"; mkdir -p "$C"
printf '%s\n127.0.1.1 provider-name provider-name\n127.0.0.1 localhost\n' "$MARK" > "$H"; printf 'provider-name\n' > "$N"
reset; HOSTNAME_CHOICE=tokyo-5; hostname_stage
grep -Fxq 'cloud-init single --name update_etc_hosts --frequency always' "$TEST_ROOT/trace" || fail "cloud-init not asked to write /etc/hosts: $(cat "$TEST_ROOT/trace")"
grep -Fxq '127.0.1.1 tokyo-5 tokyo-5' "$H" || fail "cloud-init's /etc/hosts has not the new name: $(cat "$H")"
[[ ! -s "$RESTORE_ROOT/hostname_hosts_line" ]] || fail 'a line of its own added although cloud-init wrote the name'
restore_resource() {
  record "resource $1"
  if [[ "$1" == cloud_hostname_file ]]; then rm -f -- "$CLOUD_HOSTNAME_FILE"; fi
  if [[ "$1" == hostname ]]; then printf 'provider-name\n' > "$N"; fi
}
reset; RESTORE_PARTIAL=0; restore_hostname_group
grep -Fxq '127.0.1.1 provider-name provider-name' "$H" || fail "the old name not written back by cloud-init: $(cat "$H")"
printf "PASS: where cloud-init writes /etc/hosts, it is asked to write it again after the rename and after its rollback.\n"

# The rollback undoes the rename: cloud-init file, the name (restore_resource),
# its own hosts line; the image's line and the setup's line stay.
printf '127.0.0.1\tlocalhost\n127.0.1.1\tdebian\n127.0.1.1\tsetup-line\n127.0.1.1\ttokyo-9\n' > "$H"
printf '127.0.1.1\ttokyo-9\n' > "$RESTORE_ROOT/hostname_hosts_line"
printf '127.0.1.1\tsetup-line\n' > "$RESTORE_ROOT/hosts_line"
chmod 600 "$RESTORE_ROOT/hostname_hosts_line" "$RESTORE_ROOT/hosts_line"
restore_resource() { record "resource $1"; }
reset; RESTORE_PARTIAL=0; restore_hostname_group
[[ "$(cat "$TEST_ROOT/trace")" == $'resource cloud_hostname_file\nresource hostname' ]] || fail "rollback order: $(cat "$TEST_ROOT/trace")"
[[ "$(cat "$H")" == $'127.0.0.1\tlocalhost\n127.0.1.1\tdebian\n127.0.1.1\tsetup-line' ]] || fail "rollback hosts: $(cat "$H")"
[[ ! -e "$RESTORE_ROOT/hostname_hosts_line" ]] || fail 'the rename record stayed after the rollback'
((RESTORE_PARTIAL == 0)) || fail 'rollback reported as partial'
printf "PASS: the rollback undoes the rename and its own hosts line, nothing else.\n"

# vps check: the name still in force after a reboot, and resolving.
printf 'tokyo-1\n' > "$N"; printf '127.0.1.1\ttokyo-1\n' > "$H"; : > "$CLOUD_HOSTNAME_FILE"
check_hostname tokyo-1
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *'cloud-init 开机时不会改回'* ]] || fail "check: $VERIFY_STATUS $VERIFY_TEXT"
printf 'provider-name\n' > "$N"
check_hostname tokyo-1
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'可能被服务商的初始化程序改回去了'* ]] || fail "changed back at boot not noticed: $VERIFY_TEXT"
printf 'tokyo-1\n' > "$N"; : > "$H"
check_hostname tokyo-1
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'解析不了'* ]] || fail 'an unresolvable name passed'
printf 'PASS: vps check notices a name changed back at boot or not resolving.\n'

# Asking: uppercase is lowercased, a bad name asked again, the same name kept.
printf 'debian\n' > "$N"
confirm_yes() { return 0; }
HOSTNAME_CHOICE=''
# In this shell (not a pipe), so the choice it sets is seen here.
hostname_ask < <(printf '%s\n' 'bad_name' 'Tokyo-3') > /dev/null || fail 'a valid name refused'
[[ "$HOSTNAME_CHOICE" == tokyo-3 ]] || fail "uppercase not lowercased: $HOSTNAME_CHOICE"
HOSTNAME_CHOICE=''
if printf 'debian\n' | hostname_ask > /dev/null; then fail 'the same name started a rename'; fi
if printf '\n' | hostname_ask > /dev/null; then fail 'Enter did not cancel'; fi
printf 'PASS: the new name is asked for, lowercased and checked.\n'

# Display name: Chinese allowed, control characters dropped, 24 columns at most.
printf '%s\n' "$(printf '很长%.0s' {1..7})" $'东京\x1b[31m-1' | display_name_ask > /dev/null
[[ "$(display_name_get)" == '东京[31m-1' ]] || fail "display name: <$(display_name_get)>"
printf '%s\n' '-' | display_name_ask > /dev/null
if display_name_get > /dev/null; then fail 'display name not deleted'; fi
printf 'PASS: the display name takes Chinese, drops control characters and is limited to 24 columns.\n'
