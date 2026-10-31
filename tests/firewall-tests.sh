#!/usr/bin/env bash
# Isolated regression tests: extract function definitions from the delivered
# script; never source/execute its setup entry point. All firewall/service
# commands are mocks and all state is kept under mktemp.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions ufw_active firewall_conflict nft_ruleset_has_policy iptables_save_has_policy ufw_boot_enable ufw_rule ufw_stored_rules_safe port_source_valid guard_leftovers guard_arm guard_confirm web_ports_wanted firewall_blocked_listeners f2b_ignore_address ssh_allowlist_decide ssh_limit_exempt firewall_stage fail2ban_stage
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
ssh_login_seen() { ((LOGIN_SEEN)); }
# Listening sockets as `ss -H -lntup` prints them; a case sets LISTEN.
ss() { printf '%s' "$LISTEN"; }
# [Y/n] questions of the firewall step: allow the listed services too, and
# (turned on from the menus) the allowlist for Fail2ban and the SSH limit.
confirm_default_yes() {
  case "$1" in
    *白名单*) record "ask-allowlist $1"; ((ALLOW_YES)) ;;
    *) record "ask $1"; ((LISTEN_YES)) ;;
  esac
}

reset_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p -- "$CASE_DIR"
  : > "$CASE_DIR/calls"; : > "$CASE_DIR/messages"; : > "$CASE_DIR/rules"; : > "$CASE_DIR/input"; : > "$CASE_DIR/results"
  printf '0\n' > "$CASE_DIR/ufw-active"
  printf '0\n' > "$CASE_DIR/timer-active"
  printf '0\n' > "$CASE_DIR/service-started"
  printf '0\n' > "$CASE_DIR/service-queued"
  printf '0\n' > "$CASE_DIR/timer-stop-called"
  printf 'disabled\n' > "$CASE_DIR/ufw-boot"
  printf 'inactive\n' > "$CASE_DIR/ufw-service"
  ENABLE_FAIL=0
  BOOT_ENABLE_FAIL=0
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
  LISTEN=''
  LISTEN_YES=1
  F2B_IGNORE_CHOICE=''
  F2B_FILE="$CASE_DIR/no-jail"
  ALLOW_YES=0
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
    'limit 22/tcp'|'allow '[0-9]*/tcp|'allow '[0-9]*/udp) printf 'ufw %s\n' "$*" >> "$CASE_DIR/rules" ;;
    # UFW lists a prepended rule in its own words, without the position.
    'prepend allow proto tcp from '*)
      [[ "$*" =~ ^prepend\ allow\ proto\ tcp\ from\ ([^\ ]+)\ to\ any\ port\ ([0-9]+)$ ]] || fail "unexpected prepend: $*"
      printf 'ufw allow from %s to any port %s proto tcp\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "$CASE_DIR/rules" ;;
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
        ufw.service) [[ "$(cat "$CASE_DIR/ufw-service")" == active ]] ;;
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
    # `ufw enable` does not enable ufw.service; without it nothing loads at boot.
    is-enabled)
      [[ "${*: -1}" == ufw.service ]] || fail "unmocked systemctl is-enabled: $*"
      cat "$CASE_DIR/ufw-boot"
      [[ "$(cat "$CASE_DIR/ufw-boot")" == enabled ]] ;;
    enable)
      [[ "$*" == 'enable ufw.service' ]] || fail "unmocked systemctl enable: $*"
      if ((BOOT_ENABLE_FAIL)); then return 1; fi
      printf 'enabled\n' > "$CASE_DIR/ufw-boot" ;;
    # Only reached while UFW is active: ufw-init then reports "already started".
    start)
      [[ "$*" == 'start ufw.service' ]] || fail "unmocked systemctl start: $*"
      [[ "$(cat "$CASE_DIR/ufw-active")" == 1 ]] || fail 'ufw.service started while UFW was off'
      printf 'active\n' > "$CASE_DIR/ufw-service" ;;
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
if grep -q '^ask ' "$CASE_DIR/calls"; then fail 'asked about other services although nothing else listens'; fi
[[ "$(cat "$CASE_DIR/ufw-boot")" == enabled ]] || fail 'confirmed firewall not enabled at boot (ufw.service)'
# Started too, so the next run does not take the reboot for an outside change.
[[ "$(cat "$CASE_DIR/ufw-service")" == active ]] || fail 'ufw.service left inactive after the firewall was confirmed'

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
LISTEN='tcp   LISTEN 0      511          0.0.0.0:8080       0.0.0.0:*    users:(("nginx",pid=10,fd=6))
'
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
# ufw_rule adds the rule once; the explicit re-add lets UFW create the IPv6 copy.
[[ "$(grep -c '^ufw limit 22/tcp$' "$CASE_DIR/calls")" == 2 ]] || fail 'SSH rule not re-added after enabling IPv6 protection'
[[ "$(grep -c '^ufw allow 8080/tcp$' "$CASE_DIR/calls")" == 2 ]] || fail 'listed service not re-added after enabling IPv6 protection'
[[ "$FIREWALL_READY" == 1 ]] || fail 'IPv6 protection blocked activation'

# Services reachable now would be cut off by the firewall: listed before it is
# turned on and, on Enter, allowed as well. Left out: SSH, TCP 80/443 (asked
# separately), loopback and link-local addresses, system helpers (LLMNR),
# Docker's proxy (it bypasses UFW) and a port a stored rule already mentions
# (a source-limited rule must stay limited).
reset_case listeners_allowed
LISTEN='tcp   LISTEN 0      511          0.0.0.0:8080       0.0.0.0:*    users:(("nginx",pid=10,fd=6),("nginx",pid=11,fd=6))
tcp   LISTEN 0      511             [::]:8080          [::]:*    users:(("nginx",pid=10,fd=7))
tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=5,fd=3))
tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=10,fd=5))
tcp   LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*    users:(("systemd-resolve",pid=6,fd=14))
tcp   LISTEN 0      4096       127.0.0.1:6379       0.0.0.0:*    users:(("redis-server",pid=7,fd=6))
tcp   LISTEN 0      4096         0.0.0.0:5355       0.0.0.0:*    users:(("systemd-resolve",pid=6,fd=12))
tcp   LISTEN 0      4096         0.0.0.0:9000       0.0.0.0:*    users:(("docker-proxy",pid=9,fd=4))
tcp   LISTEN 0      151          0.0.0.0:3306       0.0.0.0:*    users:(("mysqld",pid=12,fd=20))
udp   UNCONN 0      0     [fe80::1]%eth0:546           [::]:*    users:(("dhcp6c",pid=8,fd=4))
udp   UNCONN 0      0            0.0.0.0:51820      0.0.0.0:*
udp   UNCONN 0      0                  *:443              *:*    users:(("hysteria",pid=13,fd=3))
'
printf 'ufw allow from 192.0.2.7 to any port 3306\n' > "$CASE_DIR/rules"
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > "$CASE_DIR/stdout"
[[ "$FIREWALL_READY" == 1 ]] || fail 'listing other services blocked the firewall'
[[ "$(grep -c '^ask ' "$CASE_DIR/calls")" == 1 ]] || fail 'the services were not offered exactly once'
for text in '8080/tcp     nginx' '51820/udp    （程序未知）' '443/udp      hysteria'; do
  grep -Fq -- "$text" "$CASE_DIR/stdout" || fail "listing lacks: $text"
done
if grep -Eq '^  (22|80|53|6379|5355|9000|3306|546)/' "$CASE_DIR/stdout"; then fail "listed a port that must be left out: $(grep '^  ' "$CASE_DIR/stdout" | tr '\n' ' ')"; fi
for rule in 'ufw allow 8080/tcp' 'ufw allow 51820/udp' 'ufw allow 443/udp'; do
  grep -Fxq "$rule" "$CASE_DIR/rules" || fail "listed service not allowed: $rule"
done
if grep -Fxq 'ufw allow 3306/tcp' "$CASE_DIR/rules"; then fail 'a source-limited rule was widened'; fi

reset_case listeners_declined
WEB_YES=0 LISTEN_YES=0
LISTEN='tcp   LISTEN 0      511          0.0.0.0:8080       0.0.0.0:*    users:(("nginx",pid=10,fd=6))
tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=10,fd=5))
'
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > "$CASE_DIR/stdout"
[[ "$FIREWALL_READY" == 1 ]] || fail 'declining the listed services blocked the firewall'
if grep -Eq 'ufw allow (8080|80)/tcp' "$CASE_DIR/rules"; then fail 'listed services allowed without consent'; fi
grep -q '^  8080/tcp ' "$CASE_DIR/stdout" || fail 'declined services were not listed first'
if grep -q '^  80/tcp ' "$CASE_DIR/stdout"; then fail 'port 80 listed although the web question decides it'; fi

# The allowlisted administrator address skips the SSH rate limit, so several
# connections at once (file transfer tools, editors) are not refused. It is the
# same choice as Fail2ban's allowlist; everyone else stays rate limited.
reset_case allowlist_exempt
F2B_IGNORE_CHOICE=203.0.113.9
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
[[ "$FIREWALL_READY" == 1 ]] || fail 'the exemption blocked the firewall'
grep -Fxq 'ufw prepend allow proto tcp from 203.0.113.9 to any port 22' "$CASE_DIR/calls" || fail 'allowlisted address not exempted from the SSH rate limit'
grep -Fxq 'ufw allow from 203.0.113.9 to any port 22 proto tcp' "$CASE_DIR/rules" || fail 'exemption rule not stored'
grep -Fxq 'ufw limit 22/tcp' "$CASE_DIR/rules" || fail 'everyone else lost the SSH rate limit'
if grep -q '^ask-allowlist' "$CASE_DIR/calls"; then fail 'allowlist asked again although setup decided it'; fi

reset_case allowlist_key_only
KEY_ONLY=1 F2B_IGNORE_CHOICE=203.0.113.9
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
if grep -q '^ufw prepend' "$CASE_DIR/calls"; then fail 'exemption added although SSH is not rate limited'; fi

reset_case allowlist_none
F2B_IGNORE_CHOICE=none SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
if grep -q '^ufw prepend\|^ask-allowlist' "$CASE_DIR/calls"; then fail 'declined allowlist still asked or exempted'; fi

# Turned on from the menus: the allowlist question comes here, once, for both.
reset_case allowlist_asked
SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22' ALLOW_YES=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
[[ "$(grep -c '^ask-allowlist' "$CASE_DIR/calls")" == 1 ]] || fail 'allowlist not asked exactly once'
[[ "$F2B_IGNORE_CHOICE" == 203.0.113.9 ]] || fail 'allowlist answer not kept for Fail2ban'
grep -Fxq 'ufw prepend allow proto tcp from 203.0.113.9 to any port 22' "$CASE_DIR/calls" || fail 'asked allowlist not exempted'

# The address already in this tool's jail counts without asking.
reset_case allowlist_from_jail
SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22' ALLOW_YES=1
F2B_FILE="$CASE_DIR/jail"; printf 'ignoreip = 127.0.0.1/8 ::1 198.51.100.4\n' > "$F2B_FILE"
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input" > /dev/null
if grep -q '^ask-allowlist' "$CASE_DIR/calls"; then fail 'asked although the jail has an allowlist'; fi
grep -Fxq 'ufw prepend allow proto tcp from 198.51.100.4 to any port 22' "$CASE_DIR/calls" || fail 'jail allowlist not exempted'

# An active firewall (setup run again) gets the exemption too, without a question.
reset_case allowlist_active
printf '1\n' > "$CASE_DIR/ufw-active"
printf 'ufw limit 22/tcp\n' > "$CASE_DIR/rules"
WEB_YES=0 F2B_IGNORE_CHOICE=203.0.113.9
firewall_stage < "$CASE_DIR/input" > /dev/null
grep -Fxq 'ufw prepend allow proto tcp from 203.0.113.9 to any port 22' "$CASE_DIR/calls" || fail 'active firewall did not get the exemption'
firewall_stage < "$CASE_DIR/input" > /dev/null
[[ "$(grep -c '^ufw prepend' "$CASE_DIR/calls")" == 1 ]] || fail 'exemption added twice'

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
[[ "$(cat "$CASE_DIR/ufw-boot")" == disabled ]] || fail 'unconfirmed firewall enabled at boot'
[[ "$(cat "$CASE_DIR/ufw-service")" == inactive ]] || fail 'unconfirmed firewall started ufw.service'

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

# Reported on a real VPS: UFW active but ufw.service disabled, so a reboot
# came back without a firewall. An already running UFW gets it enabled too.
reset_case already_active_not_at_boot
printf '1\n' > "$CASE_DIR/ufw-active"
WEB_YES=0
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 1 ]] || fail 'already active firewall not marked ready'
[[ "$(cat "$CASE_DIR/ufw-boot")" == enabled ]] || fail 'already active firewall not enabled at boot'

reset_case already_enabled_at_boot
printf '1\n' > "$CASE_DIR/ufw-active"
printf 'enabled\n' > "$CASE_DIR/ufw-boot"
WEB_YES=0
firewall_stage < "$CASE_DIR/input"
if grep -q '^systemctl enable' "$CASE_DIR/calls"; then fail 'ufw.service enabled again although it already was'; fi
[[ "$(cat "$CASE_DIR/ufw-service")" == active ]] || fail 'running UFW with an inactive ufw.service was not started'

reset_case boot_enable_failure
BOOT_ENABLE_FAIL=1
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
[[ "$FIREWALL_READY" == 1 ]] || fail 'failing boot enable turned a confirmed firewall off'
grep -Fq 'systemctl enable ufw' "$CASE_DIR/messages" || fail 'failing boot enable not explained'

# enabled-runtime ends at the next reboot: made persistent like "disabled".
reset_case runtime_only_boot_enable
printf 'enabled-runtime\n' > "$CASE_DIR/ufw-boot"
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
grep -Fxq 'systemctl enable ufw.service' "$CASE_DIR/calls" || fail 'runtime-only enablement was not made persistent'
[[ "$(cat "$CASE_DIR/ufw-boot")" == enabled ]] || fail 'ufw.service not persistently enabled'

# A static unit cannot be enabled: explained, not "fixed".
reset_case static_boot_state
printf 'static\n' > "$CASE_DIR/ufw-boot"
printf 'CONNECTED\n' > "$CASE_DIR/input"
firewall_stage < "$CASE_DIR/input"
if grep -q '^systemctl enable' "$CASE_DIR/calls"; then fail 'tried to enable a static ufw.service'; fi
grep -Fq 'static' "$CASE_DIR/messages" || fail 'static ufw.service not explained'

printf 'PASS: firewall confirmation, guard timers, SSH rule choice, optional web ports, services that would be blocked, boot loading and conservative takeover.\n'
