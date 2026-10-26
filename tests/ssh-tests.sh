#!/usr/bin/env bash
# SSH login hardening tests: actual stage and helpers; sshd, journal, guard
# timers, passwords and account management are mocks. No real SSH config is touched.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions audit_passwd_state ssh_dropin_text ssh_pubkey_valid ssh_key_count ssh_effective ssh_effective_value ssh_login_seen ssh_sudo_seen console_password_state ssh_home_safe ssh_append_key admin_name_valid admin_prepare ssh_console_guard ssh_enable_pubkey ssh_harden_stage
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if ! command -v ssh-keygen >/dev/null; then printf 'SKIP: ssh-keygen unavailable; SSH tests need OpenSSH tools.\n'; exit 0; fi

ssh-keygen -q -t ed25519 -N '' -C 'test key' -f "$TEST_ROOT/id_test" >/dev/null
KEY="$(cat "$TEST_ROOT/id_test.pub")"
ssh_pubkey_valid "$KEY" || fail 'generated public key rejected'
for bad in '' 'ssh-ed25519' "command=\"id\" $KEY" '-----BEGIN OPENSSH PRIVATE KEY-----' 'ssh-ed25519 AAAA$(id)' 'ssh-dss AAAAB3NzaC1kc3M= old'; do
  if ssh_pubkey_valid "$bad"; then fail "invalid public key accepted: $bad"; fi
done
[[ "$(ssh_dropin_text 0)" != *PermitRootLogin* ]] || fail 'root login disabled without being asked'
[[ "$(ssh_dropin_text 1)" == *$'\nPermitRootLogin no\n'* ]] || fail 'root login not disabled when asked'
for setting in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no' 'ClientAliveInterval 300' 'ClientAliveCountMax 2'; do
  grep -Fxq "$setting" <<< "$(ssh_dropin_text 1)" || fail "drop-in lacks: $setting"
done
effective=$'passwordauthentication yes\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2'
[[ "$(ssh_effective_value "$effective" authorizedkeysfile)" == '.ssh/authorized_keys .ssh/authorized_keys2' ]] || fail 'multi-word sshd value'
ROOT_LINES=$'Accepted password for alice from 203.0.113.9 port 1 ssh2\nAccepted publickey for alice2 from 203.0.113.9 port 2 ssh2: ED25519 SHA256:x'
journalctl() {
  if [[ " $* " == *' -t sudo '* ]]; then
    # A different command, failed attempts, and (without _UID=0) a forged line.
    printf '%s\n' 'alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/id' \
      '    alice : 3 incorrect password attempts ; TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true' \
      '    alice : user NOT in sudoers ; TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true' "${SUDO_LINE:-}"
    if [[ " $* " != *' _UID=0 '* ]]; then echo 'alice : TTY=forged ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true'; fi
  else
    printf '%s\n' "$ROOT_LINES" "${JOURNAL_LINE:-}"
    # `logger -t sshd` by a local user: not written as root, so _UID=0 hides it.
    if [[ " $* " != *' _UID=0 '* ]]; then echo 'Accepted publickey for alice from 198.51.100.7 port 5 ssh2: forged'; fi
  fi
}
if ssh_login_seen 1 alice publickey; then fail 'password, other-user or forged login counted as a key login'; fi
ssh_login_seen 1 || fail 'an accepted SSH login was missed'
ROOT_LINES=''
if ssh_login_seen 1; then fail 'a line a local user logged as "sshd" counted as an SSH login'; fi
JOURNAL_LINE='Accepted publickey for alice from 203.0.113.9 port 3 ssh2: ED25519 SHA256:x'
ssh_login_seen 1 alice publickey || fail 'key login in the journal was missed'
if ssh_sudo_seen alice 1; then fail 'a different command, a failed attempt or a forged line counted as working sudo'; fi
SUDO_LINE='alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true'
ssh_sudo_seen alice 1 || fail 'sudo true in the journal was missed'
passwd() { [[ "$1" == -S ]] && printf '%s %s 2026-10-25 0 99999 7 -1\n' "$2" "$PW_FIXTURE"; }
for PW_FIXTURE in P L NP; do [[ "$(console_password_state alice)" == "$PW_FIXTURE" ]] || fail "password state $PW_FIXTURE"; done
for name in ops deploy a_1; do admin_name_valid "$name" || fail "valid admin name rejected: $name"; done
for name in root Root 1ops '' 'ops;id' 'a b'; do if admin_name_valid "$name"; then fail "invalid admin name accepted: <$name>"; fi; done
stat() {
  case "$2" in %U) echo "$STAT_OWNER" ;; %a) echo "$STAT_MODE" ;; *) return 1 ;; esac
}
mkdir -p "$TEST_ROOT/h"
STAT_OWNER=alice STAT_MODE=750; ssh_home_safe alice "$TEST_ROOT/h" || fail 'own 750 home rejected'
STAT_OWNER=root STAT_MODE=755; ssh_home_safe alice "$TEST_ROOT/h" || fail 'root-owned 755 home rejected'
STAT_OWNER=bob STAT_MODE=750; if ssh_home_safe alice "$TEST_ROOT/h"; then fail 'home owned by another user accepted'; fi
STAT_OWNER=alice STAT_MODE=777; if ssh_home_safe alice "$TEST_ROOT/h"; then fail 'world-writable home accepted'; fi
unset -f stat
printf 'PASS: key validation, drop-in contents, journal evidence for logins and sudo, password state, home checks.\n'

# ---- Stage flows -----------------------------------------------------------
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$CASE/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$CASE/log"; }
die() { fail "$*"; }
record() { printf '%s\n' "$*" >> "$CASE/trace"; }
module_result() { record "result $1 $2 ${3:-}"; }
confirm_yes() {
  case "$1" in
    *再添加一个公钥*) ((ADD_MORE)) ;;
    *设置一个密码*) ((SET_PW)) ;;
    *密钥登录记录*) ((KEYOK)) ;;
    *sudo\ 的记录*) ((SUDOOK)) ;;
    *) fail "unexpected y/N question: $1" ;;
  esac
}
confirm() {
  case "$2" in KEYOK) ((KEYOK)) ;; SUDOOK) ((SUDOOK)) ;; NOCONSOLE) ((NOCONSOLE)) ;; *) fail "unexpected confirmation $2" ;; esac
}
confirm_default_yes() {
  case "$1" in *公钥登录*) record 'ask pubkey'; ((ENABLE_PUBKEY)) ;; *) fail "unexpected Y/n question: $1" ;; esac
}
guard_leftovers() { return 1; }
guard_arm() { record "arm $1"; }
guard_confirm() { ((GUARD_OK)); }
ssh_reload() { record reload; }
systemctl() { record "systemctl $*"; }
systemd-run() { :; }
backup_config_path() { :; }
record_config_change() { :; }
put_file() { mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
install_pkgs() { record "install $*"; }
available() { return 0; }
sudo() { :; }
logname() { echo "$LOGIN"; }
hostname() { echo testhost; }
ssh_home_safe() { ((HOME_SAFE)); }
runuser() { [[ "$1" == -u && "$3" == -- ]] || fail "unexpected runuser $*"; record "runuser $2"; shift 3; "$@"; }
declare -A PW=() HOMES=() GROUPS_OF=()
passwd() {
  if [[ "$1" == -S ]]; then printf '%s %s 2026-10-25 0 99999 7 -1\n' "$2" "${PW[$2]:-L}"; return 0; fi
  [[ "$1" == -- ]] || fail "unexpected passwd $*"
  record "passwd $2"; PW[$2]=P
}
getent() {
  [[ "$1" == passwd ]] || return 2
  [[ -n "${HOMES[$2]:-}" ]] || return 2
  printf '%s:x:%s:%s::%s:/bin/bash\n' "$2" "${UIDS[$2]:-1000}" "${UIDS[$2]:-1000}" "${HOMES[$2]}"
}
declare -A UIDS=()
useradd() { local name="${*: -1}"; record "useradd $name"; HOMES[$name]="$CASE/home-$name"; UIDS[$name]=1001; mkdir -p "${HOMES[$name]}"; }
usermod() { record "usermod $*"; GROUPS_OF[${*: -1}]+=' sudo'; }
id() {
  case "$1" in
    -nG) printf '%s%s\n' "$2" "${GROUPS_OF[$2]:-}" ;;
    -un) echo "$LOGIN" ;; -gn) echo "$2" ;; *) return 1 ;;
  esac
}
journalctl() {
  if [[ " $* " == *' -t sudo '* ]]; then
    if ((SUDO_SEEN)); then echo "$TARGET : TTY=pts/1 ; PWD=/home/$TARGET ; USER=root ; COMMAND=/usr/bin/true"; fi
  elif ((SEEN)); then echo "Accepted publickey for $TARGET from 203.0.113.9 port 4 ssh2: ED25519 SHA256:x"; fi
}
sshd() {
  local pa=yes root=yes pub=yes spec="${3:-}"
  case "$1" in
    -t) return "$SSHD_T_RC" ;;
    -T)
      if ((ALREADY_OFF)) || [[ -f "$SSH_DROPIN" && "$DROPIN_WINS" == 1 ]]; then pa=no; fi
      # Provider image with "PubkeyAuthentication no"; our 00- drop-in can win.
      if ((PUBKEY_OFF)); then pub=no; if [[ -f "$SSH_PUBKEY_DROPIN" ]] && ((PUBKEY_WINS)); then pub=yes; fi; fi
      if [[ -f "$SSH_DROPIN" && "$ROOT_WINS" == 1 ]] && grep -Fxq 'PermitRootLogin no' "$SSH_DROPIN"; then root=no; fi
      if [[ "$spec" != user=root,* ]]; then root=yes; [[ -f "$SSH_DROPIN" ]] && grep -Fxq 'PermitRootLogin no' "$SSH_DROPIN" && ((ROOT_WINS)) && root=no; fi
      printf 'passwordauthentication %s\nkbdinteractiveauthentication %s\npermitrootlogin %s\npubkeyauthentication %s\nauthenticationmethods any\nauthorizedkeysfile %s\n' "$pa" "$pa" "$root" "$pub" "$AKF" ;;
    *) fail "unexpected sshd $*" ;;
  esac
}

new_case() {
  CASE="$TEST_ROOT/$1"
  mkdir -p -- "$CASE/home-alice"
  : > "$CASE/trace"; : > "$CASE/log"
  HOMES=([alice]="$CASE/home-alice" [root]="$CASE/home-root")
  UIDS=([alice]=1000 [root]=0)
  GROUPS_OF=([alice]=' sudo')
  PW=([alice]=P [root]=L)
  SSH_DROPIN="$CASE/sshd_config.d/01-vps-stable-keyonly.conf"
  SSH_PUBKEY_DROPIN="$CASE/sshd_config.d/00-vps-stable-pubkey.conf"
  PUBKEY_OFF=0 PUBKEY_WINS=1 ENABLE_PUBKEY=1
  MODE=ssh SUDO_USER=alice LOGIN=alice TARGET=alice SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
  SSH_CHOICE='' ADMIN_CHOICE=0 ADMIN_NAME=''
  ADD_MORE=0 KEYOK=0 SUDOOK=0 NOCONSOLE=0 SET_PW=0 GUARD_OK=1 SEEN=1 SUDO_SEEN=1 HOME_SAFE=1
  ALREADY_OFF=0 DROPIN_WINS=1 ROOT_WINS=1 SSHD_T_RC=0
  AKF='.ssh/authorized_keys .ssh/authorized_keys2'
  printf '\n%s\n\n' "$KEY" > "$CASE/input"
}
auth_file() { printf '%s\n' "${HOMES[$TARGET]}/.ssh/authorized_keys"; }

new_case already_off
ALREADY_OFF=1
ssh_harden_stage < "$CASE/input"
grep -q '^result ssh present' "$CASE/trace" || fail 'already key-only SSH not reported as present'
[[ ! -e "$SSH_DROPIN" && ! -e "$(auth_file)" ]] || fail 'already key-only SSH was changed'

new_case success
ssh_harden_stage < "$CASE/input"
[[ "$(cat "$(auth_file)")" == "$KEY" ]] || fail 'public key not imported'
grep -Fxq 'runuser alice' "$CASE/trace" || fail 'key not written as the target account'
[[ "$(cat "$SSH_DROPIN")" == "$(ssh_dropin_text 0)" ]] || fail 'key-only drop-in missing or wrongly disabled root login'
[[ "$(grep -n '^arm ' "$CASE/trace" | cut -d: -f1)" -lt "$(grep -n '^reload$' "$CASE/trace" | cut -d: -f1)" ]] || fail 'sshd reloaded before the guard was armed'
grep -Fxq 'result ssh applied key-only user=alice' "$CASE/trace" || fail 'applied SSH result missing'

# Found on a real VPS: one mistyped paste ended the whole hardening and left
# vps check showing a red "failed" although nothing had changed. Now a bad key
# is asked for again, and giving none is "not handled", not a failure.
new_case bad_key_then_good
printf '\nnot-a-key hello\n%s\n\n' "$KEY" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ "$(cat "$(auth_file)")" == "$KEY" ]] || fail 'a valid key after a bad paste was not imported'
grep -Fxq 'result ssh applied key-only user=alice' "$CASE/trace" || fail 'hardening did not finish after a corrected paste'

new_case no_key_given
printf '\n\n\n' > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'password login disabled without any key'
grep -Fxq 'result ssh declined no public key given' "$CASE/trace" || fail 'missing key not recorded as declined'
if grep -q '^result ssh failed' "$CASE/trace"; then fail 'missing key recorded as a failure'; fi

new_case three_bad_keys
printf '\nbad one\nbad two\nbad three\n\n' > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'password login disabled after three invalid keys'
grep -Fxq 'result ssh declined no public key given' "$CASE/trace" || fail 'three invalid keys not handled as no key'

new_case sudo_user_disables_root
ADMIN_CHOICE=1
printf '%s\n\n' "$KEY" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
grep -Fxq 'PermitRootLogin no' "$SSH_DROPIN" || fail 'root login kept although a sudo account was confirmed'
grep -Fxq 'result ssh applied key-only user=alice root-ssh=off' "$CASE/trace" || fail 'root-off result missing'

new_case root_login_creates_admin
SUDO_USER='' LOGIN=root TARGET=ops ADMIN_CHOICE=1 ADMIN_NAME=ops
printf '%s\n\n' "$KEY" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
grep -Fxq 'useradd ops' "$CASE/trace" || fail 'admin account not created'
grep -q '^usermod -aG sudo' "$CASE/trace" || fail 'admin not added to sudo'
grep -Fxq 'passwd ops' "$CASE/trace" || fail 'admin password not set'
[[ "$(cat "$CASE/home-ops/.ssh/authorized_keys")" == "$KEY" ]] || fail 'key not imported for the admin'
grep -Fxq 'PermitRootLogin no' "$SSH_DROPIN" || fail 'root login not disabled after admin was verified'

new_case sudo_not_confirmed
ADMIN_CHOICE=1 SUDO_SEEN=0 SUDOOK=0
printf '%s\n\n' "$KEY" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ -f "$SSH_DROPIN" ]] || fail 'key-only login dropped together with the unconfirmed root change'
if grep -Fxq 'PermitRootLogin no' "$SSH_DROPIN"; then fail 'root login disabled without confirmed sudo'; fi

new_case no_console_password
PW=([alice]=L [root]=L) SET_PW=0 NOCONSOLE=0
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'password login disabled although no console login would work'
grep -Fxq 'result ssh declined no console password' "$CASE/trace" || fail 'console refusal not recorded'

new_case console_password_set_now
PW=([alice]=L [root]=L) SET_PW=1
ssh_harden_stage < "$CASE/input"
grep -Fxq 'passwd alice' "$CASE/trace" || fail 'console password was not offered'
[[ -f "$SSH_DROPIN" ]] || fail 'hardening stopped after the console password was set'

new_case root_setting_overridden
ADMIN_CHOICE=1 ROOT_WINS=0
printf '%s\n\n' "$KEY" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'drop-in kept although PermitRootLogin did not take effect'
grep -Fq 'PermitRootLogin' "$CASE/log" || fail 'overridden setting not named'
if grep -q '^arm ' "$CASE/trace"; then fail 'guard armed for an ineffective drop-in'; fi

new_case guard_timeout
GUARD_OK=0
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'unconfirmed key-only login was kept'
[[ "$(grep -c '^reload$' "$CASE/trace")" == 2 ]] || fail 'password login not reloaded back'
grep -q '^result ssh failed' "$CASE/trace" || fail 'reverted SSH change not recorded as failed'
[[ -e "$(auth_file)" ]] || fail 'imported key must be kept even when reverting'
grep -q '^systemctl stop vps-stable-ssh-revert-.*\.timer$' "$CASE/trace" || fail 'guard timer kept although the revert worked'

# The revert reload fails: sshd still runs key-only, so the guard (which
# reloads again when it fires) must stay armed.
new_case revert_reload_fails
GUARD_OK=0 RELOADS=0
ssh_reload() { record reload; RELOADS=$((RELOADS + 1)); ((RELOADS == 1)); }
ssh_harden_stage < "$CASE/input" > "$CASE/out"
[[ ! -e "$SSH_DROPIN" ]] || fail 'unconfirmed key-only login was kept'
if grep -q '^systemctl stop vps-stable-ssh-revert-' "$CASE/trace"; then fail 'guard timer cancelled although the revert reload failed'; fi
grep -q '^result ssh failed' "$CASE/trace" || fail 'failed revert not recorded'
ssh_reload() { record reload; }

new_case earlier_setting_wins
DROPIN_WINS=0
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'ineffective drop-in left behind'
grep -q '^result ssh preserved' "$CASE/trace" || fail 'overriding sshd setting not reported'

new_case invalid_key
printf '\nnot-a-key\n\n' > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ ! -e "$(auth_file)" && ! -e "$SSH_DROPIN" ]] || fail 'invalid key changed SSH'

new_case custom_key_file
AKF='/etc/ssh/keys/%u'
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'custom AuthorizedKeysFile changed SSH'

new_case unsafe_home
HOME_SAFE=0
ssh_harden_stage < "$CASE/input"
[[ ! -e "$(auth_file)" && ! -e "$SSH_DROPIN" ]] || fail 'unsafe home directory was written to'

new_case unseen_declined
SEEN=0 KEYOK=0
ssh_harden_stage < "$CASE/input"
[[ ! -e "$SSH_DROPIN" ]] || fail 'password login disabled without key-login evidence or KEYOK'

new_case bad_admin_name
SUDO_USER='' LOGIN=root ADMIN_CHOICE=1 ADMIN_NAME='Root'
: > "$CASE/input"
ssh_harden_stage < "$CASE/input"
if grep -q '^useradd' "$CASE/trace"; then fail 'invalid admin name created an account'; fi
grep -Fxq 'result ssh failed admin account not ready' "$CASE/trace" || fail 'invalid admin name not reported'

new_case duplicate_key
ADD_MORE=1
mkdir -p "${HOMES[alice]}/.ssh"; printf '%s\n' "$KEY" > "$(auth_file)"
ssh_harden_stage < "$CASE/input"
[[ "$(grep -c . "$(auth_file)")" == 1 ]] || fail 'duplicate public key appended'

new_case missing_newline
ADD_MORE=1
mkdir -p "${HOMES[alice]}/.ssh"; printf '%s' "$KEY" > "$(auth_file)"
ssh-keygen -q -t ed25519 -N '' -C 'second key' -f "$TEST_ROOT/id_second" >/dev/null
printf '\n%s\n\n' "$(cat "$TEST_ROOT/id_second.pub")" > "$CASE/input"
ssh_harden_stage < "$CASE/input"
[[ "$(grep -c . "$(auth_file)")" == 2 ]] || fail 'second key merged into the unterminated first line'
# Provider image with "PubkeyAuthentication no": key login is turned on first
# (password login untouched), then hardening continues as usual.
new_case pubkey_off_enabled
PUBKEY_OFF=1
ssh_harden_stage < "$CASE/input" > "$CASE/out"
grep -Fxq 'ask pubkey' "$CASE/trace" || fail 'enabling key login was not offered'
grep -Fxq 'PubkeyAuthentication yes' "$SSH_PUBKEY_DROPIN" || fail 'key login drop-in missing'
[[ -f "$SSH_DROPIN" ]] || fail 'hardening did not continue after enabling key login'
[[ "$(grep -c '^reload$' "$CASE/trace")" == 2 ]] || fail 'sshd not reloaded for key login and for key-only login'
grep -Fxq 'result ssh applied key-only user=alice' "$CASE/trace" || fail 'applied result missing after enabling key login'

new_case pubkey_off_declined
PUBKEY_OFF=1 ENABLE_PUBKEY=0
ssh_harden_stage < "$CASE/input" > "$CASE/out"
[[ ! -e "$SSH_PUBKEY_DROPIN" && ! -e "$SSH_DROPIN" ]] || fail 'SSH changed although enabling key login was declined'
grep -Fxq 'result ssh declined pubkey auth left disabled' "$CASE/trace" || fail 'declined key login not recorded'

new_case pubkey_off_overridden
PUBKEY_OFF=1 PUBKEY_WINS=0
ssh_harden_stage < "$CASE/input" > "$CASE/out"
[[ ! -e "$SSH_PUBKEY_DROPIN" && ! -e "$SSH_DROPIN" ]] || fail 'an ineffective key login drop-in was kept'
grep -q '^result ssh failed' "$CASE/trace" || fail 'ineffective key login drop-in not reported'
if grep -Fxq reload "$CASE/trace"; then fail 'sshd reloaded for an ineffective setting'; fi
printf 'PASS: SSH hardening: admin account, root login, console guard, key import as the account, evidence, timeout revert and key login turned on first.\n'
