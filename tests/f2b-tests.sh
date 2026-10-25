#!/usr/bin/env bash
# Safe function tests: temporary directory and shell-function mocks only.
# Run on Linux: bash tests/f2b-tests.sh
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-common.sh
source "$HERE/test-common.sh"
load_optimizer_functions f2b_distribution_config foreign_f2b_config f2b_bootstrap_text f2b_jail_text f2b_jail_is_ours f2b_ignore_address port_source_valid f2b_action_text f2b_replace_owned_file fail2ban_stage
# Backup policy is exercised by backup-tests.sh and entry-tests.sh. This test
# replaces only that dependency while testing the actual Fail2ban transition.
backup_config_path() { :; }
record_config_change() { :; }
module_result() { printf '%s %s\n' "$1" "$2" >> "$CASE_DIR/results"; }
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
new_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p "$CASE_DIR/etc/fail2ban/jail.d" "$CASE_DIR/etc/fail2ban/action.d"
  F2B_DIR="$CASE_DIR/etc/fail2ban"
  F2B_FILE="$F2B_DIR/jail.d/99-vps-stable-sshd.local"
  F2B_ACTION_FILE="$F2B_DIR/action.d/vps-stable-ufw-sshd.conf"
  : > "$CASE_DIR/conffiles"; : > "$CASE_DIR/events"; : > "$CASE_DIR/ok"; : > "$CASE_DIR/warn"; : > "$CASE_DIR/results"
  FIREWALL_READY=1 UFW_ACTIVE=1 SSH_OK=1 PKG_FAIL2BAN=0 PKG_SYSTEMD=0 SERVICE_ACTIVE=0 TEST_STATUS=0 JAIL_STATUS=0
}
default_file() {
  local file="$1" text="$2" checksum
  printf '%s\n' "$text" > "$file"
  checksum="$(md5sum -- "$file")"
  printf ' %s %s\n' "$file" "${checksum%% *}" >> "$CASE_DIR/conffiles"
}
dpkg-query() { cat "$CASE_DIR/conffiles"; }
say() { :; }
ok() { printf '%s\n' "$*" >> "$CASE_DIR/ok"; }
warn() { printf '%s\n' "$*" >> "$CASE_DIR/warn"; }
ufw_active() { ((UFW_ACTIVE)); }
ssh_detect() { SSH_PORTS=(22 2222); ((SSH_OK)); }
available() { return 0; }
installed() {
  case "$1" in fail2ban) ((PKG_FAIL2BAN));; python3-systemd) ((PKG_SYSTEMD));; *) return 1;; esac
}
active() { ((SERVICE_ACTIVE)); }
put_file() {
  local dest="$1" contents="$2"
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ -f "$dest" && ! -L "$dest" && "$(cat "$dest")" == "$contents" ]]; return
  fi
  mkdir -p -- "$(dirname -- "$dest")"
  printf '%s\n' "$contents" > "$dest"
}
install_pkgs() {
  # Assert the package's postinst would read an explicitly disabled sshd jail.
  [[ "$(cat "$F2B_FILE")" == "$(f2b_bootstrap_text)" ]] || fail 'package installation was not guarded'
  printf 'install:guard\n' >> "$CASE_DIR/events"
  local pkg
  for pkg in "$@"; do
    case "$pkg" in fail2ban) PKG_FAIL2BAN=1;; python3-systemd) PKG_SYSTEMD=1;; esac
  done
  default_file "$F2B_DIR/jail.conf" $'[DEFAULT]\nenabled = false'
  default_file "$F2B_DIR/jail.d/defaults-debian.conf" $'[sshd]\nenabled = true'
}
fail2ban-client() {
  case "$*" in
    -t)
      printf 'test\n' >> "$CASE_DIR/events"
      [[ "$(cat "$F2B_FILE")" == "$(f2b_jail_text '22,2222')" ]] || fail 'testing unexpected jail'
      return "$TEST_STATUS";;
    'status sshd') printf 'status\n' >> "$CASE_DIR/events"; return "$JAIL_STATUS";;
    *) fail 'unexpected fail2ban command';;
  esac
}
systemctl() {
  printf '%s\n' "$1" >> "$CASE_DIR/events"
  case "$1" in start|restart) SERVICE_ACTIVE=1;; enable) :;; *) fail 'unexpected service command';; esac
}

new_case distribution
default_file "$F2B_DIR/jail.d/defaults-debian.conf" $'[sshd]\nenabled = true'
if foreign_f2b_config; then fail 'untouched Debian default mistaken for administrator config'; fi
printf '# administrator changed\n' >> "$F2B_DIR/jail.d/defaults-debian.conf"
foreign_f2b_config || fail 'modified distribution conf missed'
passed 'distribution checksum and modified .conf'

new_case unknown
printf '[sshd]\nenabled = false\n' > "$F2B_DIR/jail.d/sshd.conf"
foreign_f2b_config || fail 'unknown .conf missed'
passed 'unknown administrator .conf'

new_case local
ln -s missing "$F2B_DIR/jail.local"
foreign_f2b_config || fail 'dangling jail.local symlink missed'
passed 'administrator jail.local link'

new_case legacy
printf '[sshd]\nenabled = true\nbanaction = ufw\n' > "$F2B_FILE"
legacy="$(cat "$F2B_FILE")"
fail2ban_stage
[[ "$(cat "$F2B_FILE")" == "$legacy" && ! -s "$CASE_DIR/events" ]] || fail 'custom jail modified or package installed'
grep -Fxq 'fail2ban preserved' "$CASE_DIR/results" || fail 'preserved custom jail not recorded'
passed 'custom jail preserved without installation/restart'

new_case inactive
UFW_ACTIVE=0
fail2ban_stage
[[ ! -e "$F2B_FILE" && ! -s "$CASE_DIR/events" ]] || fail 'inactive UFW still configured/installed Fail2ban'
passed 'inactive UFW makes no changes'

new_case fresh
fail2ban_stage
expected=$'install:guard\ntest\nenable\nstart\nstatus'
[[ "$(cat "$CASE_DIR/events")" == "$expected" ]] || fail 'installation/test/service ordering'
# prepend keeps IPv6 bans valid; `insert 1` fails while rule 1 is an IPv4 rule.
grep -Fxq 'actionban = /usr/sbin/ufw prepend deny proto tcp from <ip> to any port <port>' "$F2B_ACTION_FILE" || fail 'port-specific prepend ban command missing'
if grep -Fq 'insert 1' "$F2B_ACTION_FILE"; then fail 'IPv6-incompatible insert position remains'; fi
grep -Fq 'Fail2ban 已就绪' "$CASE_DIR/ok" || fail 'ready status missing'
grep -Fxq 'fail2ban applied' "$CASE_DIR/results" || fail 'applied Fail2ban result missing'
passed 'first install is guarded, port-specific and tested before service start'

: > "$CASE_DIR/events"
fail2ban_stage
[[ "$(cat "$CASE_DIR/events")" == $'test\nenable\nrestart\nstatus' ]] || fail 'repeat run was not idempotent'
passed 'repeat run preserves files and revalidates the sshd jail'

new_case bad_test
TEST_STATUS=1
fail2ban_stage
[[ "$(cat "$F2B_FILE")" == "$(f2b_bootstrap_text)" ]] || fail 'bad test left enabled disk configuration'
[[ "$(cat "$CASE_DIR/events")" == $'install:guard\ntest' ]] || fail 'service enabled/restarted after failed test'
passed 'failed configuration test restores the disabled guard'

new_case missing_jail
JAIL_STATUS=1
fail2ban_stage
if grep -Fq 'Fail2ban 已就绪' "$CASE_DIR/ok"; then fail 'service active was treated as successful sshd protection'; fi
grep -Fq 'SSH 规则没有加载' "$CASE_DIR/warn" || fail 'missing jail warning absent'
passed 'failed sshd status never reports protection success'

printf '%s Fail2ban mock cases passed.\n' "$PASS"
