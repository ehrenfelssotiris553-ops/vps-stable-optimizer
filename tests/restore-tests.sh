#!/usr/bin/env bash
# Isolated recovery tests: only extracted functions are evaluated. No optimizer
# entrypoint, real systemctl, sysctl, ufw, package manager or swapoff is executed.
# Globals below are consumed by functions extracted at runtime.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/test-common.sh"
load_optimizer_functions state_path_safe state_secure_dir restore_ids restore_all_ids restore_label restore_path restore_unit restore_data_safe restore_write restore_read restore_service_value ufw_policy_value audit_ufw_ipv6 restore_value restore_fingerprint restore_snapshot restore_prepare restore_record_packages restore_record_fw_rule restore_record_sysctl restore_sysctl_runtime restore_before_stage restore_after_stage restore_capture_failure restore_record_hosts_line restore_hosts_line_present restore_hosts_lines_apply restore_needed restore_file_apply restore_service_apply restore_zram_safe restore_apply_one restore_mark restore_at_origin restore_resource f2b_action_referenced_elsewhere restore_fail2ban_group restore_fw_rules_apply restore_firewall_group restore_ssh_group restore_zram_group restore_tool_packages restore_packages_offer \
  restore_packages_record restore_group_ids restore_group_pending restore_group_apply zram_swap_active zram_reset_idle restore_zram_settle restore_tool_package port_source_valid
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
ZRAM_SYSCTL_FILE="$TMP/99-vps-stable-zram.conf"
JOURNAL_FILE="$TMP/journal.conf"
APT_FILE="$TMP/apt.conf"
F2B_DIR="$TMP/f2b"
F2B_FILE="$F2B_DIR/jail.d/99-vps-stable-sshd.local"
F2B_ACTION_FILE="$F2B_DIR/action.d/vps-stable-ufw-sshd.conf"
SSH_DROPIN="$TMP/ssh/01-vps-stable-keyonly.conf"
SSH_PUBKEY_DROPIN="$TMP/ssh/00-vps-stable-pubkey.conf"
ZRAM_VENDOR_FILE="$TMP/zram-vendor.conf"
UFW_CONF="$TMP/ufw.conf"
mkdir -p "$RESTORE_ROOT"
chmod 700 "$STATE_ROOT" "$RESTORE_ROOT"
module_result() { :; }
module_expect() { return 1; }
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
apt_wait_idle() { :; }

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

# A later hand edit no longer blocks the step, and rollback still returns the
# file to its state before this tool's first run (here: absent).
restore_before_stage journal
printf 'managed again\n' > "$JOURNAL_FILE"
restore_after_stage journal
printf 'administrator edit\n' > "$JOURNAL_FILE"
restore_before_stage journal || die 'a hand edit blocked the step'
expect "$RESTORE_STAGE" journal
restore_after_stage journal
RESTORE_PARTIAL=0
restore_resource journal_file
[[ ! -e "$JOURNAL_FILE" ]] || die 'hand-edited file was not returned to its original absence'
expect "$(restore_read journal_file state)" restored
expect "$RESTORE_PARTIAL" 0

# A resource already undone by hand is simply recorded as restored.
restore_before_stage journal
printf 'managed once more\n' > "$JOURNAL_FILE"
restore_after_stage journal
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

# A metadata-only difference from the original also needs restoring.
printf 'managed module\n' > "$MODULE_FILE"
restore_snapshot bbr_module
if restore_needed bbr_module; then die 'an unchanged file was reported as changed'; fi
chmod 600 "$MODULE_FILE"
restore_needed bbr_module || die 'mode-only edit should count as a change'

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
# A setting changed only by hand (the tool left it as it was) is also put back.
(
  RESTORE_ROOT="$TMP/tz-hand/restore-v2"
  mkdir -p "$RESTORE_ROOT/tz"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT" "$RESTORE_ROOT/tz"
  printf 'UTC\n' > "$RESTORE_ROOT/tz/origin_value"
  printf 'value:UTC\n' | tee "$RESTORE_ROOT/tz/origin_fp" > "$RESTORE_ROOT/tz/last_fp"
  printf 'clean\n' > "$RESTORE_ROOT/tz/state"
  chmod 600 "$RESTORE_ROOT/tz/"*
  TZ_NOW=Asia/Tokyo
  restore_value() { [[ "$1" == tz ]] || return 1; echo "$TZ_NOW"; }
  timedatectl() { [[ "$*" == 'set-timezone UTC' ]] || die "unexpected timedatectl $*"; TZ_NOW=UTC; }
  restore_needed tz || die 'a hand-made timezone change was not listed for rollback'
  RESTORE_PARTIAL=0
  restore_resource tz
  expect "$TZ_NOW" UTC
  expect "$(restore_read tz state)" restored
  expect "$RESTORE_PARTIAL" 0
)

# /etc/hosts is shared: only the line this tool appended is removed, later
# lines from the administrator stay.
(
  RESTORE_ROOT="$TMP/hosts/restore-v2" HOSTS="$TMP/hosts/hosts"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "${RESTORE_ROOT%/*}" "$RESTORE_ROOT"
  restore_path() { [[ "$1" == hosts_file ]] || return 1; printf '%s\n' "$HOSTS"; }
  printf '127.0.0.1 localhost\n' > "$HOSTS"
  restore_snapshot hosts_file
  printf '127.0.1.1\tvps-1\n' >> "$HOSTS"
  restore_record_hosts_line $'127.0.1.1\tvps-1' || die 'hosts line not recorded'
  if restore_record_hosts_line '127.0.1.1 vps; rm -rf /'; then die 'unsafe hosts line recorded'; fi
  restore_mark hosts_file applied
  printf '10.0.0.5 db\n' >> "$HOSTS"
  restore_needed hosts_file || die 'appended hosts line not listed for rollback'
  RESTORE_PARTIAL=0
  restore_resource hosts_file
  expect "$(cat "$HOSTS")" $'127.0.0.1 localhost\n10.0.0.5 db'
  expect "$(restore_read hosts_file state)" restored
  if restore_needed hosts_file; then die 'hosts still listed after its line was removed'; fi
  expect "$RESTORE_PARTIAL" 0
)
printf 'PASS: baselines, the back-to-original rule, integrity, allowlisted values, hosts lines and APT policy recovery.\n'

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
  # A listed UDP service (WireGuard) allowed when the firewall was turned on.
  restore_record_fw_rule 'ufw allow 51820/udp'
  if restore_record_fw_rule 'ufw deny 22/tcp; rm -rf /'; then die 'unsafe rule text recorded'; fi
  if restore_record_fw_rule 'ufw allow 53/icmp'; then die 'unknown protocol recorded'; fi
  # The SSH rate-limit exemption of the allowlisted address: one address only.
  restore_record_fw_rule 'ufw allow from 203.0.113.9 to any port 22 proto tcp'
  if restore_record_fw_rule 'ufw allow from 203.0.113.0/24 to any port 22 proto tcp'; then die 'a network recorded as an exemption'; fi
  if restore_record_fw_rule 'ufw allow from 203.0.113.999 to any port 22 proto tcp'; then die 'an invalid address recorded'; fi
  expect "$(cat "$RESTORE_ROOT/fw_rules")" $'ufw limit 22/tcp\nufw allow 80/tcp\nufw allow 51820/udp\nufw allow from 203.0.113.9 to any port 22 proto tcp'
  ADDED=$'ufw allow from 203.0.113.9 to any port 22 proto tcp\nufw limit 22/tcp\nufw allow 80/tcp\nufw allow 51820/udp\nufw allow 8080/tcp\nufw deny from 198.51.100.7 to any port 22 proto tcp'
  ufw() {
    case "$*" in
      'show added') printf 'Added user rules:\n%s\n' "$ADDED" ;;
      '--force delete allow 80/tcp'|'--force delete limit 22/tcp'|'--force delete allow 51820/udp'|'--force delete allow from 203.0.113.9 to any port 22 proto tcp') printf '%s\n' "$*" >> "$TRACE" ;;
      *) die "unexpected fixture UFW: $*" ;;
    esac
  }
  restore_fw_rules_apply
  # The exemption goes even while UFW stays on: it is not the SSH access itself.
  expect "$(cat "$TRACE")" $'--force delete allow 80/tcp\n--force delete allow 51820/udp\n--force delete allow from 203.0.113.9 to any port 22 proto tcp'
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

# UFW not installed before: once it is off, its defaults file and a stopped,
# disabled ufw.service are the original state too, so a second rollback finds
# nothing left, and the module is recorded as undone for vps check.
(
  value_fixture fw-absent-all
  RUNTIME=inactive SVC='enabled:active'
  restore_value() { case "$1" in ufw_runtime) echo "$RUNTIME" ;; ufw_policy_in) echo DROP ;; ufw_ipv6) echo yes ;; svc_ufw) echo "$SVC" ;; *) return 1 ;; esac; }
  systemctl() {
    case "$1" in
      show) echo loaded ;;
      is-enabled) echo "${SVC%%:*}" ;;
      is-active) echo "${SVC##*:}" ;;
      stop) printf 'stop\n' >> "$TRACE"; SVC="${SVC%%:*}:inactive" ;;
      disable) printf 'disable\n' >> "$TRACE"; SVC="disabled:${SVC##*:}" ;;
      *) die "unexpected systemctl $*" ;;
    esac
  }
  ufw() { die "no UFW command is needed: $*"; }
  module_result() { printf 'result %s %s\n' "$1" "$2" >> "$TRACE"; }
  value_baseline ufw_policy_in absent DROP
  value_baseline ufw_ipv6 absent yes
  value_baseline svc_ufw absent enabled:active
  restore_at_origin ufw_policy_in || die 'defaults of a switched-off UFW not counted as original'
  restore_at_origin ufw_ipv6 || die 'IPv6 switch of a switched-off UFW not counted as original'
  if restore_at_origin svc_ufw; then die 'a running ufw.service counted as never installed'; fi
  RUNTIME=active
  if restore_at_origin ufw_policy_in; then die 'live firewall defaults counted as never installed'; fi
  RUNTIME=inactive
  restore_group_apply firewall
  expect "$(cat "$TRACE")" $'stop\ndisable\nresult firewall reverted'
  expect "$SVC" disabled:inactive
  expect "$RESTORE_PARTIAL" 0
  if restore_group_pending firewall; then die 'firewall still pending after its rollback'; fi
  : > "$TRACE"
  restore_group_apply firewall
  [[ ! -s "$TRACE" ]] || die 'second rollback changed something or recorded again'
)

# ufw.service was running before; now the firewall is off but ufw.conf still
# says ENABLED=yes: starting the service would turn the firewall on. Rollback
# never does that (like the firewall switch itself).
(
  value_fixture fw-service-guard
  RUNTIME=inactive SVC='disabled:inactive'
  restore_value() { case "$1" in ufw_runtime) echo "$RUNTIME" ;; svc_ufw) echo "$SVC" ;; *) return 1 ;; esac; }
  systemctl() {
    case "$1" in
      show) echo loaded ;;
      is-enabled) echo "${SVC%%:*}" ;;
      is-active) echo "${SVC##*:}" ;;
      enable) printf 'enable\n' >> "$TRACE"; SVC="enabled:${SVC##*:}" ;;
      start) printf 'start\n' >> "$TRACE"; SVC="${SVC%%:*}:active" ;;
      *) die "unexpected systemctl $*" ;;
    esac
  }
  value_baseline svc_ufw enabled:active disabled:inactive
  printf 'ENABLED=yes\n' > "$UFW_CONF"
  restore_resource svc_ufw
  [[ ! -s "$TRACE" ]] || die 'rollback started ufw.service and turned the firewall on'
  expect "$RESTORE_PARTIAL" 1
  # With ENABLED=no the service only restores its own state: allowed.
  printf 'ENABLED=no\n' > "$UFW_CONF"
  RESTORE_PARTIAL=0
  restore_resource svc_ufw
  expect "$(cat "$TRACE")" $'enable\nstart'
  expect "$RESTORE_PARTIAL" 0
)

# journald could not be restarted after its file went back: the group stays
# pending for a retry and is not recorded as undone until the restart works.
(
  value_fixture journal-retry
  JOURNAL_FILE="$TMP/journal-retry/99-vps-stable.conf"
  RESTART_OK=0
  systemctl() { [[ "$*" == 'restart systemd-journald' ]] || die "unexpected systemctl $*"; printf 'restart\n' >> "$TRACE"; ((RESTART_OK)); }
  module_result() { printf 'result %s %s\n' "$1" "$2" >> "$TRACE"; }
  restore_snapshot journal_file
  printf '[Journal]\nSystemMaxUse=100M\n' > "$JOURNAL_FILE"
  restore_mark journal_file applied
  restore_group_apply journal
  [[ ! -e "$JOURNAL_FILE" ]] || die 'journal configuration not restored'
  expect "$RESTORE_PARTIAL" 1
  if grep -q '^result journal reverted' "$TRACE"; then die 'failed journald restart recorded as undone'; fi
  restore_group_pending journal || die 'pending journald restart hidden from per-item rollback'
  RESTART_OK=1 RESTORE_PARTIAL=0; : > "$TRACE"
  restore_group_apply journal
  expect "$(cat "$TRACE")" $'restart\nresult journal reverted'
  if restore_group_pending journal; then die 'journal group still pending after the retry worked'; fi
)

# zram-generator's own default turns ZRAM on again at boot: rollback says so
# and offers to remove the package this tool installed.
(
  value_fixture zram-vendor
  ZRAM_FILE="$TMP/zram-vendor/zram-generator.conf"
  restore_value() { case "$1" in zram_swap) echo absent ;; *) return 1 ;; esac; }
  value_baseline zram_swap absent absent
  restore_snapshot zram_file
  printf '[zram0]\nzram-size = ram / 4\n' > "$ZRAM_FILE"
  restore_mark zram_file applied
  printf '[zram0]\n' > "$ZRAM_VENDOR_FILE"
  installed() { [[ "$1" == systemd-zram-generator ]]; }
  systemctl() {
    case "$*" in
      daemon-reload) ;;
      'reset-failed systemd-zram-setup@zram0.service dev-zram0.swap') printf 'reset-failed\n' >> "$TRACE" ;;
      *) die "unexpected systemctl $*" ;;
    esac
  }
  restore_packages_offer() { printf 'offer %s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN %s\n' "$*" >> "$TRACE"; }
  restore_zram_group
  [[ ! -e "$ZRAM_FILE" ]] || die 'ZRAM configuration not removed'
  grep -q '^WARN systemd-zram-generator' "$TRACE" || die 'package default turning ZRAM back on not explained'
  grep -Fxq 'offer systemd-zram-generator' "$TRACE" || die 'removal of the package not offered'
  grep -Fxq reset-failed "$TRACE" || die 'a failed earlier ZRAM start stays listed after the rollback'
  # Full rollback: the package step at the end asks once for all packages.
  : > "$TRACE"; printf '[zram0]\nzram-size = ram / 4\n' > "$ZRAM_FILE"; restore_mark zram_file applied
  RESTORE_ALL=1 restore_zram_group > /dev/null
  if grep -q '^offer' "$TRACE"; then die 'package offered twice during a full rollback'; fi
)

# Found on a real VPS: with the package default in place, systemd started ZRAM
# again seconds after the rollback (the next unit start pulls in swap.target),
# and zram0 stayed set up, so turning ZRAM on later failed with "busy".
# Once the package is gone, that ZRAM is switched off for good and released.
(
  value_fixture zram-settle
  ZRAM_FILE="$TMP/zram-settle/zram-generator.conf"
  value_baseline zram_swap absent absent
  SWAP=/dev/zram0:366076:100 INSTALLED=0
  restore_value() { case "$1" in zram_swap) echo "$SWAP" ;; *) return 1 ;; esac; }
  installed() { [[ "$1" == systemd-zram-generator ]] && ((INSTALLED)); }
  active() { [[ "$1" == dev-zram0.swap && "$SWAP" != absent ]]; }
  systemctl() { [[ "$*" == 'stop dev-zram0.swap' ]] || die "unexpected systemctl $*"; printf 'stop swap\n' >> "$TRACE"; SWAP=absent; }
  zram_reset_idle() { printf 'reset\n' >> "$TRACE"; }
  # Without the package removed in this run, a running ZRAM is not touched
  # (it may be one the user set up later, with zram-tools for example).
  ZRAM_PACKAGE_REMOVED=0
  restore_zram_settle > /dev/null
  [[ ! -s "$TRACE" ]] || die "ZRAM switched off although the package was not removed now: $(cat "$TRACE")"
  ZRAM_PACKAGE_REMOVED=1
  restore_zram_settle > /dev/null
  [[ "$(head -n 2 "$TRACE")" == $'stop swap\nreset' ]] || die "ZRAM brought back by the package default not switched off: $(cat "$TRACE")"
  expect "$(restore_read zram_swap state)" restored
  # Kept package: its default ZRAM is started now and the user is told so.
  INSTALLED=1 SWAP=absent; : > "$TRACE"
  printf '[zram0]\n' > "$ZRAM_VENDOR_FILE"
  restore_tool_packages() { echo systemd-zram-generator; }
  systemctl() { [[ "$*" == 'start dev-zram0.swap' ]] || die "unexpected systemctl $*"; printf 'start\n' >> "$TRACE"; SWAP=/dev/zram0:1:100; }
  module_result() { printf 'result %s %s\n' "$1" "$2" >> "$TRACE"; }
  warn() { printf 'WARN %s\n' "$*" >> "$TRACE"; }
  restore_zram_settle
  grep -Fxq start "$TRACE" || die 'kept package default ZRAM not started'
  grep -q '^WARN 保留了 systemd-zram-generator' "$TRACE" || die 'kept package default ZRAM not explained'
  grep -Fxq 'result zram present' "$TRACE" || die 'running package default ZRAM recorded as undone'
  # An administrator's own zram-generator: a rollback never switches ZRAM on.
  restore_tool_packages() { :; }
  SWAP=absent; : > "$TRACE"
  restore_zram_settle
  [[ ! -s "$TRACE" ]] || die "rollback started the administrator's ZRAM: $(cat "$TRACE")"
  # This tool's own configuration is back in place: nothing to settle.
  restore_tool_packages() { echo systemd-zram-generator; }
  printf '[zram0]\n' > "$ZRAM_FILE"
  restore_zram_settle
  [[ ! -s "$TRACE" ]] || die 'ZRAM settled while a ZRAM configuration exists'
)

# A zram0 left set up without swap on it is reset; one in use is left alone.
(
  dev="$TMP/zram-dev"; mkdir -p "$dev"
  printf '1\n' > "$dev/initstate"; : > "$dev/reset"
  zram_swap_active() { return 1; }
  zram_reset_idle "$dev"
  expect "$(cat "$dev/reset")" 1
  : > "$dev/reset"
  zram_swap_active() { return 0; }
  zram_reset_idle "$dev"
  [[ ! -s "$dev/reset" ]] || die 'zram0 in use was reset'
  printf '0\n' > "$dev/initstate"; zram_swap_active() { return 1; }
  zram_reset_idle "$dev"
  [[ ! -s "$dev/reset" ]] || die 'an idle unset zram0 was reset'
)

# The ZRAM tuning goes back with ZRAM: its file and the running values.
(
  value_fixture zram-tune
  ZRAM_SYSCTL_FILE="$TMP/zram-tune/99-vps-stable-zram.conf"
  ZRAM_FILE="$TMP/zram-tune/zram.conf"
  restore_snapshot zram_sysctl_file
  printf 'vm.swappiness = 100\nvm.page-cluster = 0\n' > "$ZRAM_SYSCTL_FILE"
  restore_mark zram_sysctl_file applied
  RESTORE_READY=1
  restore_record_sysctl vm.swappiness 60 zram_sysctl_runtime
  restore_record_sysctl vm.page-cluster 3 zram_sysctl_runtime
  restore_group_pending zram || die 'ZRAM tuning not pending'
  installed() { return 1; }
  sysctl() { [[ "$1" == -w ]] || die "unexpected sysctl $*"; printf '%s\n' "$2" >> "$TRACE"; }
  systemctl() {
    case "$*" in
      daemon-reload) ;;
      'reset-failed systemd-zram-setup@zram0.service dev-zram0.swap') printf 'reset-failed\n' >> "$TRACE.units" ;;
      *) die "unexpected systemctl $*" ;;
    esac
  }
  restore_zram_group > /dev/null
  [[ ! -e "$ZRAM_SYSCTL_FILE" ]] || die 'ZRAM tuning file kept'
  expect "$(cat "$TRACE")" $'vm.swappiness=60\nvm.page-cluster=3'
  [[ ! -e "$RESTORE_ROOT/zram_sysctl_runtime" && ! -e "$RESTORE_ROOT/sysctl_runtime" ]] || die 'ZRAM originals kept or mixed with the hardening record'
  if restore_group_pending zram; then die 'ZRAM group still pending after its rollback'; fi
)
# Debian 12 and Ubuntu keep no default in /usr/lib: once this tool's config is
# gone the package does nothing, so it is offered for removal like vnStat (found
# on a real Ubuntu 24.04 VPS, where the unused package was left installed).
(
  value_fixture zram-no-vendor
  ZRAM_FILE="$TMP/zram-no-vendor/zram-generator.conf"
  ZRAM_VENDOR_FILE="$TMP/zram-no-vendor/absent-vendor.conf"
  restore_value() { case "$1" in zram_swap) echo absent ;; *) return 1 ;; esac; }
  value_baseline zram_swap absent absent
  restore_snapshot zram_file
  printf '[zram0]\nzram-size = ram / 2\n' > "$ZRAM_FILE"
  restore_mark zram_file applied
  installed() { [[ "$1" == systemd-zram-generator ]]; }
  restore_tool_packages() { echo systemd-zram-generator; }
  systemctl() {
    case "$*" in
      daemon-reload) ;;
      'reset-failed systemd-zram-setup@zram0.service dev-zram0.swap') printf 'reset-failed\n' >> "$TRACE" ;;
      *) die "unexpected systemctl $*" ;;
    esac
  }
  restore_packages_offer() { printf 'offer %s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN %s\n' "$*" >> "$TRACE"; }
  restore_zram_group > /dev/null
  [[ ! -e "$ZRAM_FILE" ]] || die 'ZRAM configuration not removed'
  grep -Fxq 'offer systemd-zram-generator' "$TRACE" || die 'unused tool package not offered for removal'
  if grep -q '^WARN systemd-zram-generator' "$TRACE"; then die 'warned about a package default that does not exist'; fi
  # A package that was there before this tool is never offered.
  : > "$TRACE"; printf '[zram0]\n' > "$ZRAM_FILE"; restore_mark zram_file applied
  restore_tool_packages() { :; }
  restore_zram_group > /dev/null
  if grep -q '^offer' "$TRACE"; then die "an administrator's zram-generator was offered for removal"; fi
)
printf 'PASS: ZRAM rollback survives the package default, releases zram0 and restores its tuning.\n'
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
# Image that had key login off: both drop-ins go back, sshd reloads once.
(
  RESTORE_ROOT="$TMP/ssh2/restore-v2"
  mkdir -p "$RESTORE_ROOT" "$TMP/ssh2"; chmod 700 "$RESTORE_ROOT"
  SSH_DROPIN="$TMP/ssh2/01-vps-stable-keyonly.conf" SSH_PUBKEY_DROPIN="$TMP/ssh2/00-vps-stable-pubkey.conf"
  RESTORE_PARTIAL=0
  load_optimizer_functions restore_fingerprint
  restore_snapshot ssh_dropin; restore_snapshot ssh_pubkey_dropin
  printf 'PubkeyAuthentication yes\n' > "$SSH_PUBKEY_DROPIN"
  printf 'PasswordAuthentication no\n' > "$SSH_DROPIN"
  restore_mark ssh_dropin applied; restore_mark ssh_pubkey_dropin applied
  ssh_reload() { printf 'reload\n' >> "$TMP/ssh2/trace"; }
  restore_ssh_group > "$TMP/ssh2/out"
  [[ ! -e "$SSH_DROPIN" && ! -e "$SSH_PUBKEY_DROPIN" ]] || die 'SSH drop-ins survived rollback'
  expect "$(cat "$TMP/ssh2/trace")" reload
  expect "$(restore_read ssh_pubkey_dropin state)" restored
  grep -Fq '记得密码' "$TMP/ssh2/out" || die 'turning key login off again was not announced'
  expect "$RESTORE_PARTIAL" 0
)
printf 'PASS: SSH drop-in rollback (key-only and key-login switch) reloads sshd once.\n'

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
  # Per-interface IPv6 values: eth0 and veth0 are different keys, the first
  # value still wins, and an interface that is gone (a container's veth) has
  # nothing left to restore instead of leaving the rollback unfinished.
  : > "$TMP/sysctl/trace"
  restore_record_sysctl net.ipv6.conf.vps-gone0.accept_redirects 1
  restore_record_sysctl net.ipv6.conf.vps-gone0.accept_redirects 0
  restore_record_sysctl net.ipv6.conf.xvps-gone0.accept_redirects 1
  restore_record_sysctl kernel.dmesg_restrict 0
  expect "$(cut -d= -f1 "$RESTORE_ROOT/sysctl_runtime" | tr '\n' ' ')" 'net.ipv6.conf.vps-gone0.accept_redirects net.ipv6.conf.xvps-gone0.accept_redirects kernel.dmesg_restrict '
  expect "$(grep -c '^net.ipv6.conf.vps-gone0.accept_redirects=1$' "$RESTORE_ROOT/sysctl_runtime")" 1
  restore_sysctl_runtime
  expect "$(cat "$TMP/sysctl/trace")" 'kernel.dmesg_restrict=0'
  expect "$RESTORE_PARTIAL" 0
  [[ ! -e "$RESTORE_ROOT/sysctl_runtime" ]] || die 'a vanished interface left the sysctl rollback unfinished'
  # TCP buffer keys hold three numbers; their own record is restored as a whole.
  : > "$TMP/sysctl/trace"
  restore_record_sysctl net.ipv4.tcp_rmem '4096 131072 6291456' tcp_sysctl_runtime
  restore_record_sysctl net.core.rmem_max 212992 tcp_sysctl_runtime
  if restore_record_sysctl net.ipv4.tcp_wmem '4096 16384 $(id)' tcp_sysctl_runtime; then die 'non-numeric buffer value recorded'; fi
  restore_sysctl_runtime tcp_sysctl_runtime
  expect "$(cat "$TMP/sysctl/trace")" $'net.ipv4.tcp_rmem=4096 131072 6291456\nnet.core.rmem_max=212992'
  [[ ! -e "$RESTORE_ROOT/tcp_sysctl_runtime" ]] || die 'applied buffer originals kept'
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
  TOOLS_PACKAGES=(curl wget)
  module_expect() { [[ "$1" == tools ]]; }
  module_result() { printf 'result %s %s\n' "$1" "$2" >> "$TMP/pkg/results"; }
  expect "$(restore_tool_packages | tr '\n' ' ')" 'ufw fail2ban python3-systemd '
  TRACE="$TMP/pkg/trace"; : > "$TRACE"
  confirm_yes() { [[ "$1" == *卸载* ]]; }
  RESTORE_PARTIAL=0
  SIM_EXTRA=iptables
  apt-get() {
    case "$*" in
      '-s remove --autoremove ufw fail2ban python3-systemd') printf 'Remv ufw [0.36]\nRemv fail2ban [1.0]\nRemv python3-systemd [235]\nRemv %s [1.8]\n' "$SIM_EXTRA" ;;
      '-s remove ufw fail2ban python3-systemd') printf 'Remv ufw [0.36]\nRemv fail2ban [1.0]\nRemv python3-systemd [235]\n' ;;
      '-y -q -o DPkg::Lock::Timeout=120 remove '*) printf '%s\n' "$*" >> "$TRACE" ;;
      *) die "unexpected apt-get $*" ;;
    esac
  }
  restore_packages_offer
  expect "$(cat "$TRACE")" '-y -q -o DPkg::Lock::Timeout=120 remove --autoremove ufw fail2ban python3-systemd'
  # A tool package is gone now: vps check reports the tools as undone, not broken.
  expect "$(cat "$TMP/pkg/results")" 'result tools reverted'
  # Autoremove would take a package that existed before: fall back to plain remove.
  SIM_EXTRA=iptables-old; : > "$TRACE"
  restore_packages_offer
  expect "$(cat "$TRACE")" '-y -q -o DPkg::Lock::Timeout=120 remove ufw fail2ban python3-systemd'
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
  expect "${ZRAM_PACKAGE_REMOVED:-0}" 0
  # Removing the zram package is remembered for restore_zram_settle.
  printf 'systemd-zram-generator\n' >> "$RESTORE_ROOT/packages/installed"
  installed() { [[ " ufw fail2ban python3-systemd curl bash systemd-zram-generator " == *" $1 "* ]]; }
  apt-get() {
    case "$*" in
      '-s remove --autoremove systemd-zram-generator') printf 'Remv systemd-zram-generator [1.2]\n' ;;
      '-y -q -o DPkg::Lock::Timeout=120 remove --autoremove systemd-zram-generator') printf '%s\n' "$*" >> "$TRACE" ;;
      *) die "unexpected apt-get $*" ;;
    esac
  }
  restore_packages_offer systemd-zram-generator > /dev/null
  expect "$ZRAM_PACKAGE_REMOVED" 1
  # The membership check reads the whole list (no early exit under pipefail).
  restore_tool_package systemd-zram-generator || die 'tool package not found'
  if restore_tool_package curl; then die 'a package present before the tool counted as its own'; fi
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
  load_optimizer_functions restore_service_value restore_value restore_fingerprint
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
