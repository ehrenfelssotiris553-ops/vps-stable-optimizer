#!/usr/bin/env bash
# Isolated regression tests: extract function definitions from the delivered
# script; never source/execute its setup entry point. All firewall/service
# commands are mocks and all state is kept under mktemp.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions ufw_active firewall_conflict nft_ruleset_has_policy ufw_rule ufw_stored_rules_safe port_source_valid guard_leftovers guard_arm guard_confirm web_ports_wanted firewall_stage fail2ban_stage
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$CASE_DIR/messages"; }
warn() { printf 'WARN %s\n' "$*" >> "$CASE_DIR/messages"; }
die() { fail "$*"; }
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
confirm() { return 0; }
# Web ports follow WEB_YES; every other y/N (the console question) is accepted.
confirm_yes() { case "$1" in *80*) ((WEB_YES)) ;; *) return 0 ;; esac; }
module_result() { printf '%s %s\n' "$1" "$2" >> "$CASE_DIR/results"; }
ssh_detect() { SSH_PORTS=(22); return 0; }
ssh_password_disabled() { ((KEY_ONLY)); }
docker_firewall_note() { :; }
host_has_global_ipv6() { return 1; }
audit_ufw_ipv6() { echo yes; }
# Models the user accepting IPv6 protection before UFW is enabled.
ufw_ipv6_check() { if ((FLIP_IPV6)); then IPV6_FLIPPED=1; fi; }
# A new SSH login seen in the journal confirms without typing.
ssh_login_seen_since() { ((LOGIN_SEEN)); }

reset_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p -- "$CASE_DIR"
  : > "$CASE_DIR/calls"; : > "$CASE_DIR/messages"; : > "$CASE_DIR/rules"; : > "$CASE_DIR/input"; : > "$CASE_DIR/results"
  printf '0\n' > "$CASE_DIR/ufw-active"
  printf '0\n' > "$CASE_DIR/timer-active"
  printf '0\n' > "$CASE_DIR/service-started"
  printf '0\n' > "$CASE_DIR/service-queued"
  printf '0\n' > "$CASE_DIR/timer-stop-called"
  ENABLE_FAIL=0
  LARGE_NFT=0
  ROLLBACK_FIRED=0
  QUEUE_DURING_CONFIRM=0
  LEFTOVER_TIMER=0
  WEB_YES=1
  WEB_CHOICE=''
  FLIP_IPV6=0
  KEY_ONLY=0
  LOGIN_SEEN=0
  SERVICE_GONE=0
  FIREWALL_READY=0
  SSH_CONNECTION=''
  SSH_PORTS=()
  SECONDS=0
}
record() { printf '%s\n' "$*" >> "$CASE_DIR/calls"; }

# These function names intentionally shadow every system-changing executable
# used by the extracted functions, including hyphenated command names.
ufw() {
  record "ufw $*"
  case "$*" in
    status|'status numbered'|'status verbose')
      if [[ "$(cat "$CASE_DIR/ufw-active")" == 1 ]]; then printf 'Status: active\n'
      else printf 'Status: inactive\n'; fi ;;
    'show added') printf 'Added user rules:\n'; cat "$CASE_DIR/rules" ;;
    'limit 22/tcp'|'allow 22/tcp'|'allow 80/tcp'|'allow 443/tcp') printf 'ufw %s\n' "$*" >> "$CASE_DIR/rules" ;;
    'default deny incoming'|'default allow outgoing') : ;;
    '--force enable')
      if ((ENABLE_FAIL)); then return 1; fi
      printf '1\n' > "$CASE_DIR/ufw-active"
      if ((ROLLBACK_FIRED)); then printf '12345\n' > "$CASE_DIR/service-started"; fi
      if ((QUEUE_DURING_CONFIRM)); then printf '1\n' > "$CASE_DIR/service-queued"; fi ;;
    '--force disable') printf '0\n' > "$CASE_DIR/ufw-active" ;;
    *) fail "unmocked ufw command: $*" ;;
  esac
}
systemctl() {
  record "systemctl $*"
  case "$1" in
    list-units)
      if ((LEFTOVER_TIMER)); then printf '  vps-stable-ufw-rollback-111-222.timer loaded active waiting desc\n'; fi
      return 0 ;;
    is-active)
      case "${*: -1}" in
        vps-stable-ufw-rollback-*.timer) [[ "$(cat "$CASE_DIR/timer-active")" == 1 ]] ;;
        *) return 3 ;;
      esac ;;
    stop)
      shift
      local item
      for item in "$@"; do
        case "$item" in
          vps-stable-ufw-rollback-*.timer)
            printf '0\n' > "$CASE_DIR/timer-active"
            printf '1\n' > "$CASE_DIR/timer-stop-called" ;;
          vps-stable-ufw-rollback-*.service)
            # Real systemd: the never-run transient service is already unloaded.
            if ((SERVICE_GONE)); then printf 'Failed to stop %s: Unit %s not loaded.\n' "$item" "$item" >&2; return 5; fi
            printf '0\n' > "$CASE_DIR/service-queued" ;;
          *) fail "unmocked systemctl stop target: $item" ;;
        esac
      done ;;
    show)
      [[ "$*" == *ExecMainStartTimestampMonotonic* ]] || fail "unmocked systemctl property: $*"
      cat "$CASE_DIR/service-started" ;;
    *) fail "unmocked systemctl command: $*" ;;
  esac
}
systemd-run() {
  record "systemd-run $*"
  [[ "$*" == *'/usr/sbin/ufw --force disable'* ]] || fail 'unexpected rollback command'
  [[ "$*" == *'--timer-property=RemainAfterElapse=no'* ]] || fail 'guard timer would stay loaded after firing'
  printf '1\n' > "$CASE_DIR/timer-active"
}
nft() {
  record "nft $*"
  [[ "$*" == 'list ruleset' ]] || fail "unmocked nft command: $*"
  if ((LARGE_NFT)); then
    printf 'table inet foreign {\n chain input {\n'
    local i=0
    while ((i < 6000)); do
      printf '  ip saddr 192.0.2.1 counter packets 123456 bytes 123456789 accept comment "large fixture"\n'
      i=$((i+1))
    done
    printf ' }\n}\n'
  fi
}
iptables-save() { record 'iptables-save'; return 0; }
ip6tables-save() { record 'ip6tables-save'; return 0; }
foreign_f2b_config() { record 'unexpected Fail2ban setup after firewall refusal'; return 0; }

reset_case f2b_readiness_gate
printf '1\n' > "$CASE_DIR/ufw-active"
FIREWALL_READY=0
# The function must defend itself if called after a refused firewall. Overall
# entry-point sequencing is checked separately by entry-tests.sh.
fail2ban_stage
if grep -q '^unexpected Fail2ban setup' "$CASE_DIR/calls"; then
  fail 'Fail2ban setup continued while firewall stage was not ready'
fi

reset_case confirmed
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 1 ]] || fail 'confirmed firewall was not marked ready'
[[ "$(cat "$CASE_DIR/ufw-active")" == 1 ]] || fail 'confirmed firewall became inactive'
[[ "$(cat "$CASE_DIR/timer-active")" == 0 ]] || fail 'confirmed firewall retained timer'
grep -Fxq 'ufw limit 22/tcp' "$CASE_DIR/rules" || fail 'password SSH did not use the rate-limited rule'
grep -Fxq 'ufw allow 80/tcp' "$CASE_DIR/rules" || fail 'accepted web ports were not opened'
grep -Fxq 'firewall applied' "$CASE_DIR/results" || fail 'applied firewall result missing'

reset_case key_only_ssh
KEY_ONLY=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
grep -Fxq 'ufw allow 22/tcp' "$CASE_DIR/rules" || fail 'key-only SSH did not use a plain allow rule'
if grep -Fxq 'ufw limit 22/tcp' "$CASE_DIR/rules"; then fail 'key-only SSH still rate limited'; fi

reset_case web_declined
WEB_YES=0
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 1 ]] || fail 'declining web ports blocked the firewall'
if grep -Eq 'ufw allow (80|443)/tcp' "$CASE_DIR/rules"; then fail 'web ports opened without consent'; fi

reset_case web_choice_from_setup
WEB_YES=1 WEB_CHOICE=0
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
if grep -Eq 'ufw allow (80|443)/tcp' "$CASE_DIR/rules"; then fail 'setup choice "no web ports" was asked again or ignored'; fi

reset_case ipv6_enabled_before_activation
FLIP_IPV6=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
# ufw_rule adds the rule once; the explicit re-add lets UFW create the IPv6 copy.
[[ "$(grep -c '^ufw limit 22/tcp$' "$CASE_DIR/calls")" == 2 ]] || fail 'SSH rule not re-added after enabling IPv6 protection'
[[ "$FIREWALL_READY" == 1 ]] || fail 'IPv6 protection blocked activation'

reset_case leftover_timer
LEFTOVER_TIMER=1
firewall_stage < "$CASE_DIR/input" > "$CASE_DIR/stdout"
[[ "$FIREWALL_READY" == 0 ]] || fail 'pending guard timer did not block the firewall'
if grep -q '^systemd-run ' "$CASE_DIR/calls"; then fail 'a second guard was armed while one is pending'; fi
grep -Fq 'vps-stable-ufw-rollback-111-222.timer' "$CASE_DIR/messages" || fail 'leftover message does not name the unit'
grep -Fq 'systemctl stop' "$CASE_DIR/stdout" || fail 'leftover message does not explain how to clear it'

reset_case no_confirmation
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 0 ]] || fail 'unconfirmed firewall marked ready'
[[ "$(cat "$CASE_DIR/ufw-active")" == 0 ]] || fail 'unconfirmed firewall left active'
grep -Fxq 'ufw --force disable' "$CASE_DIR/calls" || fail 'no immediate disable after missing confirmation'
grep -Fxq 'firewall failed' "$CASE_DIR/results" || fail 'failed confirmation not recorded'

reset_case enable_failure
ENABLE_FAIL=1
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 0 ]] || fail 'enable failure marked ready'
[[ "$(cat "$CASE_DIR/timer-active")" == 1 ]] || fail 'enable failure disarmed safety timer'

reset_case rollback_already_started
ROLLBACK_FIRED=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 0 ]] || fail 'already-started rollback marked ready'
[[ "$(cat "$CASE_DIR/ufw-active")" == 0 ]] || fail 'uncertain rollback state did not disable firewall'

reset_case large_foreign_nft
LARGE_NFT=1
if firewall_conflict; then :; else fail 'large foreign nft ruleset was missed'; fi
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 0 ]] || fail 'external nft rules marked ready'
if grep -q '^ufw --force enable$' "$CASE_DIR/calls"; then fail 'external nft rules caused takeover'; fi

reset_case inactive_unknown_rules
printf 'ufw deny 12345/tcp\n' > "$CASE_DIR/rules"
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 0 ]] || fail 'unknown saved UFW rules marked ready'
if grep -q '^systemd-run ' "$CASE_DIR/calls"; then fail 'unknown saved rules armed activation'; fi
if grep -q '^ufw --force enable$' "$CASE_DIR/calls"; then fail 'unknown saved rules caused takeover'; fi

# A timer can have submitted a service job before its main process gets a start
# timestamp. Stopping only the timer does not cancel that queued service job.
reset_case queued_rollback_boundary
QUEUE_DURING_CONFIRM=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
if [[ "$(cat "$CASE_DIR/service-queued")" == 1 ]]; then
  printf '12345\n' > "$CASE_DIR/service-started"
  printf '0\n' > "$CASE_DIR/ufw-active"
fi
if [[ "$FIREWALL_READY" == 1 && "$(cat "$CASE_DIR/ufw-active")" == 0 ]]; then
  fail 'queued rollback disabled firewall after it was marked ready'
fi

# Reported on a real VPS: CONNECTED typed in time, but stopping the guard's
# transient service failed with "not loaded" and the firewall was turned off.
reset_case service_unit_already_unloaded
SERVICE_GONE=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" 2> "$CASE_DIR/stderr"
[[ "$FIREWALL_READY" == 1 && "$(cat "$CASE_DIR/ufw-active")" == 1 ]] || fail 'an unloaded guard service made a confirmed firewall fail'
[[ "$(cat "$CASE_DIR/timer-active")" == 0 ]] || fail 'guard timer kept after confirmation'

# A new SSH login through the enabled firewall confirms without typing anything.
reset_case confirmed_by_new_login
LOGIN_SEEN=1
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 1 && "$(cat "$CASE_DIR/timer-active")" == 0 ]] || fail 'a new SSH login did not confirm the firewall'
grep -q '自动确认' "$CASE_DIR/messages" || fail 'automatic confirmation not reported'

printf 'PASS: firewall confirmation, guard timers, SSH rule choice, optional web ports and conservative takeover.\n'
