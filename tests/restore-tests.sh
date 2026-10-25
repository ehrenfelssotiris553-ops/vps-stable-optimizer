#!/usr/bin/env bash
# Isolated recovery tests: only extracted functions are evaluated. No optimizer
# entrypoint, real systemctl, sysctl, ufw, package manager or swapoff is executed.
# Globals below are consumed by functions extracted at runtime.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/test-common.sh"
load_optimizer_functions state_path_safe state_secure_dir restore_ids restore_all_ids restore_label restore_path restore_unit restore_data_safe restore_write restore_read restore_service_value ufw_policy_value audit_ufw_ipv6 restore_value restore_fingerprint restore_snapshot restore_prepare restore_record_packages restore_record_fw_rule restore_record_sysctl restore_sysctl_runtime restore_before_stage restore_after_stage restore_capture_failure restore_current_matches restore_file_apply restore_service_apply restore_zram_safe restore_apply_one restore_mark restore_at_origin restore_resource f2b_action_referenced_elsewhere restore_fail2ban_group restore_fw_rules_apply restore_firewall_group restore_ssh_group restore_zram_group restore_tool_packages restore_packages_offer
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
WARNINGS=0
RESTORE_ROOT="$TMP/state/restore-v2"
RESTORE_READY=1
RESTORE_STAGE=''
RESTORE_PARTIAL=0
STATE_ROOT="$TMP/state"
BBR_FILE="$TMP/bbr.conf"
MODULE_FILE="$TMP/module.conf"
ZRAM_FILE="$TMP/zram.conf"
JOURNAL_FILE="$TMP/journal.conf"
APT_FILE="$TMP/apt.conf"
F2B_DIR="$TMP/f2b"
F2B_FILE="$F2B_DIR/jail.d/99-vps-stable-sshd.local"
F2B_ACTION_FILE="$F2B_DIR/action.d/vps-stable-ufw-sshd.conf"
SSH_DROPIN="$TMP/ssh/01-vps-stable-keyonly.conf"
mkdir -p "$RESTORE_ROOT"
chmod 700 "$STATE_ROOT" "$RESTORE_ROOT"
ok() { printf '[OK] %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '[WARN] %s\n' "$*"; }
say() { :; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
expect() { [[ "$1" == "$2" ]] || die "expected <$2>, got <$1>"; }
# Every host-changing command is blocked unless a particular test replaces it.
systemctl() { die "unexpected host command systemctl $*"; }
sysctl() { die "unexpected host command sysctl $*"; }
timedatectl() { die "unexpected host command timedatectl $*"; }
ufw() { die "unexpected host command ufw $*"; }
swapoff() { die "unexpected host command swapoff $*"; }
apt-get() { die "unexpected host command apt-get $*"; }
fail2ban-client() { die "unexpected host command fail2ban-client $*"; }
active() { return 1; }

# A first baseline records absence. A second snapshot cannot replace it.
restore_snapshot bbr_file
expect "$(restore_read bbr_file origin_fp)" absent
printf 'managed\n' > "$BBR_FILE"
restore_snapshot bbr_file
expect "$(restore_read bbr_file origin_fp)" absent
expect "$(restore_read bbr_file last_fp)" absent
rm "$BBR_FILE"

# Track an applied file, then restore it to absence without touching software.
restore_before_stage journal
printf 'journal policy\n' > "$JOURNAL_FILE"
restore_after_stage journal
expect "$(restore_read journal_file state)" applied
restore_resource journal_file
[[ ! -e "$JOURNAL_FILE" ]] || die 'new managed file was not removed'
expect "$(restore_read journal_file state)" restored

# Retain the FIRST original content, permissions and owner over repeat runs.
printf 'original APT policy\n' > "$APT_FILE"
chmod 640 "$APT_FILE"
restore_snapshot apt_file
original_fp="$(restore_read apt_file origin_fp)"
[[ "$(stat -c %a "$RESTORE_ROOT/apt_file/origin")" == 640 ]] || die 'saved original lost its own permissions'
printf 'managed APT policy\n' > "$APT_FILE"
restore_write "$RESTORE_ROOT/apt_file" last_fp "$(restore_fingerprint apt_file)"
restore_write "$RESTORE_ROOT/apt_file" state applied
restore_snapshot apt_file
expect "$(restore_read apt_file origin_fp)" "$original_fp"
restore_resource apt_file
expect "$(cat "$APT_FILE")" 'original APT policy'
expect "$(stat -c %a "$APT_FILE")" 640
expect "$(restore_fingerprint apt_file)" "$original_fp"

# A later administrator edit is a conflict; do not delete it or adopt its hash.
restore_before_stage journal
printf 'managed again\n' > "$JOURNAL_FILE"
restore_after_stage journal
managed_fp="$(restore_read journal_file last_fp)"
printf 'administrator edit\n' > "$JOURNAL_FILE"
if restore_before_stage journal; then die 'external edit should skip the stage'; fi
expect "$RESTORE_STAGE" ''
expect "$(restore_read journal_file last_fp)" "$managed_fp"
RESTORE_PARTIAL=0
restore_resource journal_file
expect "$(cat "$JOURNAL_FILE")" 'administrator edit'
expect "$RESTORE_PARTIAL" 1

# A resource already undone by hand is simply recorded as restored.
rm -f "$JOURNAL_FILE"
RESTORE_PARTIAL=0
restore_resource journal_file
expect "$(restore_read journal_file state)" restored
expect "$RESTORE_PARTIAL" 0

# A partial stage is captured by the error/exit hook exactly once.
restore_before_stage zram || die 'zram baseline could not be captured'
printf 'partial ZRAM file\n' > "$ZRAM_FILE"
restore_capture_failure
expect "$(restore_read zram_file state)" applied
expect "$RESTORE_STAGE" ''
saved_fp="$(restore_read zram_file last_fp)"
restore_capture_failure
expect "$(restore_read zram_file last_fp)" "$saved_fp"

# Metadata changes alone also constitute an administrator conflict.
printf 'managed module\n' > "$MODULE_FILE"
restore_snapshot bbr_module
restore_write "$RESTORE_ROOT/bbr_module" state applied
chmod 600 "$MODULE_FILE"
fp_before_mode="$(restore_fingerprint bbr_module)"
restore_write "$RESTORE_ROOT/bbr_module" last_fp "$fp_before_mode"
chmod 644 "$MODULE_FILE"
if restore_current_matches bbr_module; then die 'mode-only edit should conflict'; fi

# Refuse target and baseline symlinks; never follow a stored arbitrary path.
printf 'precious\n' > "$TMP/precious"
ln -s "$TMP/precious" "$TMP/link.conf"
old_bbr="$BBR_FILE"; BBR_FILE="$TMP/link.conf"
if restore_fingerprint bbr_file; then die 'target symlink accepted'; fi
BBR_FILE="$old_bbr"
mkdir -m 700 "$TMP/fake-resource"
ln -s "$TMP/fake-resource" "$RESTORE_ROOT/f2b_jail"
if restore_snapshot f2b_jail; then die 'state resource symlink accepted'; fi
rm "$RESTORE_ROOT/f2b_jail"
expect "$(cat "$TMP/precious")" precious

# Corrupted original snapshots fail integrity checks and retain baseline data.
printf 'managed policy\n' > "$APT_FILE"
restore_write "$RESTORE_ROOT/apt_file" last_fp "$(restore_fingerprint apt_file)"
restore_write "$RESTORE_ROOT/apt_file" state applied
printf 'corruption\n' > "$RESTORE_ROOT/apt_file/origin"
RESTORE_PARTIAL=0
restore_resource apt_file
expect "$(cat "$APT_FILE")" 'managed policy'
expect "$RESTORE_PARTIAL" 1
expect "$(restore_read apt_file state)" applied

# Runtime recovery accepts only allowlisted values, not shell expressions.
mkdir -m 700 "$RESTORE_ROOT/cc"
# shellcheck disable=SC2016
printf '$(touch forbidden)\n' > "$RESTORE_ROOT/cc/origin_value"
chmod 600 "$RESTORE_ROOT/cc/origin_value"
if restore_apply_one cc; then die 'untrusted sysctl value accepted'; fi
[[ ! -e forbidden ]] || die 'recovery data was executed'
mkdir -m 700 "$RESTORE_ROOT/tz"
printf 'Asia/Shanghai; rm -rf /\n' > "$RESTORE_ROOT/tz/origin_value"
chmod 600 "$RESTORE_ROOT/tz/origin_value"
if restore_apply_one tz; then die 'untrusted timezone value accepted'; fi

# Service state changes do not unmask, start failed or guess unknown services.
mkdir -m 700 "$RESTORE_ROOT/svc_trim"
printf 'masked:inactive\n' > "$RESTORE_ROOT/svc_trim/origin_value"
chmod 600 "$RESTORE_ROOT/svc_trim/origin_value"
(
  restore_service_value() { echo disabled:inactive; }
  if restore_service_apply svc_trim; then die 'masked baseline should need manual review'; fi
)

# Postinst's 20auto-upgrades is captured BEFORE apt, including first-run absence.
# No package command runs: fixtures model exactly the file postinst can write.
(
  RESTORE_ROOT="$TMP/postinst-absent/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  AUTO_FILE="$TMP/20auto-upgrades"
  restore_path() { [[ "$1" == apt_auto_file ]] || return 1; printf '%s\n' "$AUTO_FILE"; }
  restore_value() { case "$1" in svc_*) echo disabled:inactive ;; ntp) echo no ;; ufw_policy_*|ufw_runtime) echo absent ;; *) return 1 ;; esac; }
  RESTORE_READY=1 RESTORE_STAGE=''
  restore_before_stage apt_upgrade || die 'APT pre-install baseline failed'
  expect "$(restore_read apt_auto_file origin_fp)" absent
  printf 'APT::Periodic::Unattended-Upgrade "1";\n' > "$AUTO_FILE"
  restore_after_stage apt_upgrade
  expect "$(restore_read apt_auto_file state)" applied
  restore_resource apt_auto_file
  [[ ! -e "$AUTO_FILE" ]] || die 'postinst-created auto update policy survived rollback'
  expect "$(restore_read apt_auto_file state)" restored

  # An existing disabled policy must be restored with its original permissions.
  RESTORE_ROOT="$TMP/postinst-existing/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  printf 'APT::Periodic::Unattended-Upgrade "0";\n' > "$AUTO_FILE"
  chmod 640 "$AUTO_FILE"
  restore_before_stage apt_upgrade || die 'existing APT policy baseline failed'
  original="$(restore_read apt_auto_file origin_fp)"
  printf 'APT::Periodic::Unattended-Upgrade "1";\n' > "$AUTO_FILE"
  chmod 644 "$AUTO_FILE"
  restore_after_stage apt_upgrade
  restore_resource apt_auto_file
  expect "$(restore_read apt_auto_file origin_fp)" "$original"
  expect "$(restore_fingerprint apt_auto_file)" "$original"
  expect "$(cat "$AUTO_FILE")" 'APT::Periodic::Unattended-Upgrade "0";'
)
printf 'PASS: baselines, conflicts, integrity, allowlisted values and APT policy recovery.\n'

# Value resources for the firewall are modelled by a private fixture.
value_fixture() {
  RESTORE_ROOT="$TMP/$1/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  TRACE="$TMP/$1/trace"; : > "$TRACE"
  RUNTIME=active POLICY_IN=DROP RESTORE_PARTIAL=0
  restore_value() { case "$1" in ufw_runtime) echo "$RUNTIME" ;; ufw_policy_in) echo "$POLICY_IN" ;; ufw_policy_out) echo ACCEPT ;; *) return 1 ;; esac; }
  ufw_active() { [[ "$RUNTIME" == active ]]; }
  ssh_candidates() { echo 22; }
}
# Creates a baseline whose original value is $2 and whose tool-recorded value is $3.
value_baseline() {
  local id="$1" origin="$2" last="$3" dir="$RESTORE_ROOT/$1"
  mkdir -m 700 "$dir"
  printf '%s\n' "$origin" > "$dir/origin_value"
  printf 'value:%s\n' "$origin" > "$dir/origin_fp"
  printf 'value:%s\n' "$last" > "$dir/last_fp"
  printf 'applied\n' > "$dir/state"
  chmod 600 "$dir"/*
}

# Exactly the recorded rules are deleted; later port rules and bans stay. An SSH
# allowance is never removed while UFW stays on.
(
  value_fixture fw-rules
  RESTORE_READY=1
  restore_record_fw_rule 'ufw limit 22/tcp'
  restore_record_fw_rule 'ufw allow 80/tcp'
  restore_record_fw_rule 'ufw allow 80/tcp'
  if restore_record_fw_rule 'ufw deny 22/tcp; rm -rf /'; then die 'unsafe rule text recorded'; fi
  expect "$(cat "$RESTORE_ROOT/fw_rules")" $'ufw limit 22/tcp\nufw allow 80/tcp'
  ADDED=$'ufw limit 22/tcp\nufw allow 80/tcp\nufw allow 8080/tcp\nufw deny from 198.51.100.7 to any port 22 proto tcp'
  ufw() {
    case "$*" in
      'show added') printf 'Added user rules:\n%s\n' "$ADDED" ;;
      '--force delete allow 80/tcp'|'--force delete limit 22/tcp') printf '%s\n' "$*" >> "$TRACE" ;;
      *) die "unexpected fixture UFW: $*" ;;
    esac
  }
  restore_fw_rules_apply
  expect "$(cat "$TRACE")" '--force delete allow 80/tcp'
  expect "$RESTORE_PARTIAL" 1
  expect "$(cat "$RESTORE_ROOT/fw_rules")" 'ufw limit 22/tcp'
  RUNTIME=inactive RESTORE_PARTIAL=0; : > "$TRACE"
  restore_fw_rules_apply
  expect "$(cat "$TRACE")" '--force delete limit 22/tcp'
  [[ ! -e "$RESTORE_ROOT/fw_rules" ]] || die 'fully processed rule record kept'
  expect "$RESTORE_PARTIAL" 0
)

# The group turns UFW off before deleting the SSH rule it added.
(
  value_fixture fw-order
  value_baseline ufw_runtime inactive active
  printf 'ufw limit 22/tcp\n' > "$RESTORE_ROOT/fw_rules"; chmod 600 "$RESTORE_ROOT/fw_rules"
  ufw() {
    case "$*" in
      '--force disable') printf 'disable\n' >> "$TRACE"; RUNTIME=inactive ;;
      'show added') printf 'Added user rules:\nufw limit 22/tcp\n' ;;
      '--force delete limit 22/tcp') printf 'delete\n' >> "$TRACE" ;;
      *) die "unexpected fixture UFW: $*" ;;
    esac
  }
  restore_firewall_group
  expect "$(cat "$TRACE")" $'disable\ndelete'
  expect "$(restore_read ufw_runtime state)" restored
  expect "$RESTORE_PARTIAL" 0
)

# Rollback never turns a firewall on and never narrows a live firewall's defaults.
(
  value_fixture fw-never-narrow
  RUNTIME=inactive
  value_baseline ufw_runtime active inactive
  ufw() { die "rollback changed UFW: $*"; }
  restore_resource ufw_runtime
  expect "$RESTORE_PARTIAL" 1
  expect "$(restore_read ufw_runtime state)" applied
  RUNTIME=active RESTORE_PARTIAL=0
  value_baseline ufw_policy_in ACCEPT DROP
  restore_resource ufw_policy_in
  expect "$RESTORE_PARTIAL" 1
  RUNTIME=inactive RESTORE_PARTIAL=0
  ufw() { [[ "$*" == 'default allow incoming' ]] || die "unexpected fixture UFW: $*"; printf 'policy\n' >> "$TRACE"; POLICY_IN=ACCEPT; }
  restore_resource ufw_policy_in
  expect "$(cat "$TRACE")" policy
  expect "$(restore_read ufw_policy_in state)" restored
)

# "Not installed before" and "off now" are the same original firewall state.
(
  value_fixture fw-absent
  RUNTIME=inactive
  value_baseline ufw_runtime absent active
  ufw() { die "no UFW command is needed: $*"; }
  restore_resource ufw_runtime
  expect "$(restore_read ufw_runtime state)" restored
  expect "$RESTORE_PARTIAL" 0
)
printf 'PASS: rule-level firewall rollback, access-widening order and no re-enabling.\n'

# Fail2ban: lift this tool's bans first, remove only its own files, and let a
# Fail2ban that existed before reload its own configuration.
f2b_fixture() {
  RESTORE_ROOT="$TMP/$1/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  F2B_DIR="$TMP/$1/fail2ban"
  F2B_FILE="$F2B_DIR/jail.d/99-vps-stable-sshd.local"
  F2B_ACTION_FILE="$F2B_DIR/action.d/vps-stable-ufw-sshd.conf"
  mkdir -p "$F2B_DIR/jail.d" "$F2B_DIR/action.d"
  TRACE="$TMP/$1/trace"; : > "$TRACE"
  RESTORE_PARTIAL=0
  load_optimizer_functions restore_value restore_fingerprint
  restore_snapshot f2b_jail; restore_snapshot f2b_action
  printf '[sshd]\naction = vps-stable-ufw-sshd[port="%%(port)s"]\n' > "$F2B_FILE"
  printf '[Definition]\n' > "$F2B_ACTION_FILE"
  restore_mark f2b_jail applied; restore_mark f2b_action applied
  active() { [[ "$1" == fail2ban ]]; }
  fail2ban-client() {
    case "$*" in
      'get sshd banip') echo '198.51.100.7 2001:db8::9' ;;
      'set sshd unbanip '*) printf 'unban %s\n' "${*: -1}" >> "$TRACE" ;;
      *) die "unexpected fail2ban-client $*" ;;
    esac
  }
  systemctl() { [[ "$*" == 'restart fail2ban' ]] || die "unexpected systemctl $*"; printf 'restart\n' >> "$TRACE"; }
}
(
  f2b_fixture f2b-preexisting
  restore_fail2ban_group
  expect "$(cat "$TRACE")" $'unban 198.51.100.7\nunban 2001:db8::9\nrestart'
  [[ ! -e "$F2B_FILE" && ! -e "$F2B_ACTION_FILE" ]] || die 'tool Fail2ban files survived rollback'
  expect "$(restore_read f2b_jail state)" restored
  expect "$RESTORE_PARTIAL" 0
)
(
  f2b_fixture f2b-shared-action
  printf '[nginx]\naction = vps-stable-ufw-sshd\n' > "$F2B_DIR/jail.d/admin.local"
  fail2ban-client() { die 'a shared action must not trigger unbans'; }
  restore_fail2ban_group
  [[ -e "$F2B_FILE" && -e "$F2B_ACTION_FILE" ]] || die 'shared action was removed'
  expect "$RESTORE_PARTIAL" 1
)
printf 'PASS: Fail2ban rollback unbans first, keeps shared actions and reloads a pre-existing service.\n'

# SSH: removing the key-only drop-in restores password login after a reload.
(
  RESTORE_ROOT="$TMP/ssh/restore-v2"
  mkdir -p "$RESTORE_ROOT" "$TMP/ssh"; chmod 700 "$RESTORE_ROOT"
  RESTORE_PARTIAL=0
  load_optimizer_functions restore_fingerprint
  restore_snapshot ssh_dropin
  printf 'PasswordAuthentication no\n' > "$SSH_DROPIN"
  restore_mark ssh_dropin applied
  ssh_reload() { printf 'reload\n' >> "$TMP/ssh/trace"; }
  restore_ssh_group
  [[ ! -e "$SSH_DROPIN" ]] || die 'SSH drop-in survived rollback'
  expect "$(cat "$TMP/ssh/trace")" reload
  expect "$(restore_read ssh_dropin state)" restored
)
printf 'PASS: SSH key-only drop-in rollback reloads sshd.\n'

# sysctl originals: first value wins, only numeric values, restored after the file.
(
  RESTORE_ROOT="$TMP/sysctl/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  RESTORE_READY=1 RESTORE_PARTIAL=0
  restore_record_sysctl kernel.kptr_restrict 0
  restore_record_sysctl kernel.kptr_restrict 2
  if restore_record_sysctl 'kernel.x;id' 1; then die 'unsafe sysctl key recorded'; fi
  if restore_record_sysctl kernel.dmesg_restrict '$(id)'; then die 'non-numeric sysctl value recorded'; fi
  expect "$(cat "$RESTORE_ROOT/sysctl_runtime")" 'kernel.kptr_restrict=0'
  sysctl() { [[ "$1" == -w ]] || die "unexpected sysctl $*"; printf '%s\n' "$2" >> "$TMP/sysctl/trace"; }
  restore_sysctl_runtime
  expect "$(cat "$TMP/sysctl/trace")" 'kernel.kptr_restrict=0'
  [[ ! -e "$RESTORE_ROOT/sysctl_runtime" ]] || die 'applied sysctl originals kept'
  expect "$RESTORE_PARTIAL" 0
)

# UFW IPv6 switch: tracked as a value and switched back with the real helper.
(
  value_fixture fw-ipv6
  load_optimizer_functions restore_apply_one
  value_baseline ufw_ipv6 no yes
  restore_value() { case "$1" in ufw_ipv6) echo "$IPV6_NOW" ;; *) return 1 ;; esac; }
  IPV6_NOW=yes RUNTIME=inactive
  ufw_set_ipv6() { printf 'set %s\n' "$1" >> "$TRACE"; IPV6_NOW="$1"; }
  restore_resource ufw_ipv6
  expect "$(cat "$TRACE")" 'set no'
  expect "$(restore_read ufw_ipv6 state)" restored
)
printf 'PASS: sysctl runtime originals and the UFW IPv6 switch are restored.\n'

# Packages: only those installed by this tool and absent before its first run,
# and only when APT's simulation removes nothing that existed before.
(
  RESTORE_ROOT="$TMP/pkg/restore-v2"
  mkdir -p "$RESTORE_ROOT/packages"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT" "$RESTORE_ROOT/packages"
  printf 'ufw\nfail2ban\npython3-systemd\ncurl\nbad;name\n' > "$RESTORE_ROOT/packages/installed"
  printf 'bash\ncurl\niptables-old\n' > "$RESTORE_ROOT/packages/before"
  chmod 600 "$RESTORE_ROOT/packages/"*
  installed() { [[ " ufw fail2ban python3-systemd curl bash " == *" $1 "* ]]; }
  expect "$(restore_tool_packages | tr '\n' ' ')" 'ufw fail2ban python3-systemd '
  TRACE="$TMP/pkg/trace"; : > "$TRACE"
  confirm_yes() { [[ "$1" == *卸载* ]]; }
  RESTORE_PARTIAL=0
  SIM_EXTRA=iptables
  apt-get() {
    case "$*" in
      '-s remove --autoremove ufw fail2ban python3-systemd') printf 'Remv ufw [0.36]\nRemv fail2ban [1.0]\nRemv python3-systemd [235]\nRemv %s [1.8]\n' "$SIM_EXTRA" ;;
      '-s remove ufw fail2ban python3-systemd') printf 'Remv ufw [0.36]\nRemv fail2ban [1.0]\nRemv python3-systemd [235]\n' ;;
      '-y -q remove '*) printf '%s\n' "$*" >> "$TRACE" ;;
      *) die "unexpected apt-get $*" ;;
    esac
  }
  restore_packages_offer
  expect "$(cat "$TRACE")" '-y -q remove --autoremove ufw fail2ban python3-systemd'
  # Autoremove would take a package that existed before: fall back to plain remove.
  SIM_EXTRA=iptables-old; : > "$TRACE"
  restore_packages_offer
  expect "$(cat "$TRACE")" '-y -q remove ufw fail2ban python3-systemd'
  # Even plain removal would take something else: nothing is removed.
  apt-get() {
    case "$*" in
      '-s remove'*) printf 'Remv ufw [0.36]\nRemv bash [5.2]\n' ;;
      *) die "removal ran despite a dependent pre-existing package: $*" ;;
    esac
  }
  : > "$TRACE"
  restore_packages_offer
  [[ ! -s "$TRACE" ]] || die 'unsafe package removal executed'
)

# The first package inventory is kept; records accept only real package names.
# restore_prepare insists on root, so this part runs only in a root test session.
if ((EUID == 0)); then (
  RESTORE_ROOT='' STATE_ROOT="$TMP/prep"
  mkdir -p "$STATE_ROOT"; chmod 700 "$STATE_ROOT"
  dpkg-query() { printf 'installed\tbash\nconfig-files\told-removed\ninstalled\tcurl\n'; }
  restore_prepare
  expect "$(cat "$RESTORE_ROOT/packages/before")" $'bash\ncurl'
  dpkg-query() { printf 'installed\tsomething-new\n'; }
  restore_prepare
  expect "$(cat "$RESTORE_ROOT/packages/before")" $'bash\ncurl'
  installed() { [[ "$1" == fail2ban || "$1" == curl ]]; }
  restore_record_packages fail2ban 'evil;rm' not-installed fail2ban
  expect "$(cat "$RESTORE_ROOT/packages/installed")" fail2ban
) else printf 'SKIP: restore_prepare package inventory (requires root).\n'; fi
printf 'PASS: package removal offer is limited, simulated first and never removes pre-existing software.\n'

# A masked unit is a valid unchanged baseline, common on chrony VPS images.
# Read the actual service-value function; no mock bypasses the LoadState parser.
(
  load_optimizer_functions restore_service_value restore_value restore_fingerprint restore_current_matches
  RESTORE_ROOT="$TMP/masked-service/restore-v2"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  TEST_MASK_LOAD=masked TEST_MASK_ENABLED=masked
  systemctl() {
    case "$*" in
      'show systemd-timesyncd.service -p LoadState --value') echo "$TEST_MASK_LOAD" ;;
      'is-enabled systemd-timesyncd.service') echo "$TEST_MASK_ENABLED" ;;
      'is-active systemd-timesyncd.service') echo inactive ;;
      'show ufw.service -p LoadState --value') echo not-found ;;
      *) die "unexpected masked fixture service change: $*" ;;
    esac
  }
  expect "$(restore_service_value svc_timesync)" masked:inactive
  restore_snapshot svc_timesync
  expect "$(restore_read svc_timesync origin_value)" masked:inactive
  expect "$(restore_read svc_timesync state)" clean
  expect "$(restore_service_value svc_ufw)" absent
  # Recording a masked service must not grant permission to unmask it later.
  TEST_MASK_LOAD=loaded TEST_MASK_ENABLED=disabled
  if restore_service_apply svc_timesync; then die 'changed masked baseline was automatically unmasked/restored'; fi
  TEST_MASK_LOAD=error
  if restore_service_value svc_timesync; then die 'an erroneous unit load state was accepted'; fi
)
printf 'recovery tests passed\n'
