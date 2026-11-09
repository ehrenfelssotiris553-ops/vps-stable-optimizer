#!/usr/bin/env bash
# SSH login hardening tests: actual stage and helpers; sshd, journal, guard
# timers, passwords and account management are mocks. No real SSH config is touched.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions audit_passwd_state ssh_dropin_text ssh_pubkey_valid ssh_key_count ssh_effective ssh_effective_value ssh_login_seen ssh_sudo_seen console_password_state ssh_home_safe ssh_append_key admin_name_valid admin_prepare ssh_console_guard ssh_enable_pubkey guard_since ssh_harden_stage \
  sshd_line_value sshd_config_walk sshd_include_args sshd_reads sshd_setting_overrides sshd_lines_show sshd_lines_off sshd_lines_on \
  sshd_lines_on_cmd sshd_off_files ssh_overrides_offer ssh_hardening_overridden restore_record_sshd_file audit_clean_text \
  restore_ssh_group check_ssh check_ssh_override verify_set
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
for setting in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no'; do
  grep -Fxq "$setting" <<< "$(ssh_dropin_text 1)" || fail "drop-in lacks: $setting"
done
# Idle connections belong to the SSH keepalive item: the hardening sets none.
for setting in ClientAliveInterval ClientAliveCountMax; do
  if grep -q "^$setting" <<< "$(ssh_dropin_text 1)"; then fail "the hardening drop-in sets $setting"; fi
done
effective=$'passwordauthentication yes\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2'
[[ "$(ssh_effective_value "$effective" authorizedkeysfile)" == '.ssh/authorized_keys .ssh/authorized_keys2' ]] || fail 'multi-word sshd value'
ROOT_LINES=$'Accepted password for alice from 203.0.113.9 port 1 ssh2\nAccepted publickey for alice2 from 203.0.113.9 port 2 ssh2: ED25519 SHA256:x'
journalctl() {
  if [[ " $* " == *' -t sudo '* ]]; then
    # sudo logs under the real UID of whoever ran it (alice: 1001, as seen on
    # Debian 12/13 and Ubuntu 22.04-26.04, sudo-rs too): a different command
    # and failed attempts. mallory (1002) can log anything as "sudo".
    if [[ " $* " == *' _UID=1001 '* ]]; then
      printf '%s\n' 'alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/id' \
        '    alice : 3 incorrect password attempts ; TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true' \
        '    alice : user NOT in sudoers ; TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true' "${SUDO_LINE:-}"
    fi
    if [[ " $* " != *' _UID='* || " $* " == *' _UID=1002 '* ]]; then echo 'alice : TTY=forged ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true'; fi
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
getent() { [[ "$1 $2" == 'passwd alice' ]] && echo 'alice:x:1001:1001::/home/alice:/bin/bash'; }
if ssh_sudo_seen alice 1; then fail 'a different command, a failed attempt or a forged line counted as working sudo'; fi
SUDO_LINE='alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/true'
ssh_sudo_seen alice 1 || fail 'sudo true in the journal was missed'
if ssh_sudo_seen nobody-here 1; then fail 'sudo counted for an unknown account'; fi
# The journal a moment behind: looked at again before anyone is asked.
(
  load_optimizer_functions journal_settle
  sleep() { :; }
  looks="$(mktemp)"
  found_third() { printf 'x' >> "$looks"; (($(wc -c < "$looks") >= 3)); }
  journal_settle found_third || fail 'a record that arrives a moment later was missed'
  [[ "$(wc -c < "$looks" | tr -d ' ')" == 3 ]] || fail "journal looked at $(wc -c < "$looks") times, should stop at the third"
  : > "$looks"
  never() { printf 'x' >> "$looks"; return 1; }
  if journal_settle never; then fail 'nothing in the journal counted as found'; fi
  (($(wc -c < "$looks") <= 6)) || fail 'keeps looking'
  rm -f -- "$looks"
  for name in ssh_login_seen ssh_sudo_seen; do
    grep -Eq "journal_settle $name " "$TEST_SCRIPT" || fail "$name is looked up only once before asking"
  done
)
unset -f getent
# The privilege separation directory sshd -t needs: created when missing (as
# ssh.service does), an existing directory or link left alone.
(
  load_optimizer_functions sshd_runtime_dir
  sshd() { :; }
  base="$(mktemp -d)"
  sshd_runtime_dir "$base/sshd"
  [[ -d "$base/sshd" && "$(stat -c %a "$base/sshd")" == 755 ]] || fail 'missing sshd runtime directory not created as 0755'
  mkdir "$base/own"; touch "$base/own/keep"; sshd_runtime_dir "$base/own"
  [[ -f "$base/own/keep" ]] || fail 'an existing directory was changed'
  # (Windows Git Bash cannot create links without extra rights.)
  if ln -s /nonexistent "$base/link" 2>/dev/null; then
    sshd_runtime_dir "$base/link"
    [[ -L "$base/link" ]] || fail 'a link was replaced'
  fi
  sshd_runtime_dir "$base/absent-parent/sshd"
  [[ ! -e "$base/absent-parent" ]] || fail 'a missing parent directory was created'
  rm -rf -- "$base"
)
# The journal is searched from whole seconds: a login just before a change,
# in the same second, must fall before the confirmation window.
before="$(date +%s)"
(($(guard_since) > before)) || fail 'the confirmation window starts in the second of the change'
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
  case "$1" in
    *公钥登录*) record 'ask pubkey'; ((ENABLE_PUBKEY)) ;;
    *注释掉*) record 'ask comment out'; ((COMMENT_OK)) ;;
    *) fail "unexpected Y/n question: $1" ;;
  esac
}
guard_leftovers() { return 1; }
guard_arm() { record "arm $*"; }
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
      # The provider's layout of a real Debian 13 VPS, read the way sshd reads
      # it (written out here, not worked out): its included file, its 00-
      # drop-in, this tool's 00-/01- ones, cloud-init's 50-; the first value wins.
      if ((PROVIDER)); then
        pa=yes pub=yes
        local f v found_pa='' found_pub=''
        for f in "$CASE/ppflight-login.conf" "$CASE/sshd_config.d/00-ppflight-cloud.conf" "$SSH_PUBKEY_DROPIN" "$SSH_DROPIN" "$CASE/sshd_config.d/50-cloud-init.conf"; do
          v="$(awk 'tolower($1) == "passwordauthentication" {print tolower($2); exit}' "$f" 2>/dev/null || true)"
          if [[ -z "$found_pa" && -n "$v" ]]; then found_pa="$v"; fi
          v="$(awk 'tolower($1) == "pubkeyauthentication" {print tolower($2); exit}' "$f" 2>/dev/null || true)"
          if [[ -z "$found_pub" && -n "$v" ]]; then found_pub="$v"; fi
        done
        pa="${found_pa:-yes}" pub="${found_pub:-yes}"
      fi
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
  ALREADY_OFF=0 DROPIN_WINS=1 ROOT_WINS=1 SSHD_T_RC=0 PROVIDER=0 COMMENT_OK=1
  SSHD_CONFIG="$CASE/sshd_config" RESTORE_ROOT="$CASE/restore" RESTORE_READY=1
  mkdir -p "$RESTORE_ROOT"
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

# ---- A provider's setting read before this tool's ----------------------------
# The layout of a real Debian 13 VPS (2026-11-03): sshd_config includes the
# provider's file on its first line, and the provider's 00- drop-in sorts
# before this tool's 01- one; cloud-init's 50- comes after it and does not win.
restore_data_safe() { [[ -f "$1" && ! -L "$1" ]]; }
provider_case() {
  new_case "$1"
  PROVIDER=1
  mkdir -p "$CASE/sshd_config.d"
  printf '%s\n' "Include $CASE/ppflight-login.conf" "Include $CASE/sshd_config.d/*.conf" > "$SSHD_CONFIG"
  printf '%s\n' 'PasswordAuthentication yes' > "$CASE/ppflight-login.conf"
  printf '%s\n' '# provider' 'PasswordAuthentication yes' > "$CASE/sshd_config.d/00-ppflight-cloud.conf"
  printf '%s\n' 'PasswordAuthentication yes' > "$CASE/sshd_config.d/50-cloud-init.conf"
  mkdir -p "$CASE/before"
  cp -p "$CASE/ppflight-login.conf" "$CASE/sshd_config.d/00-ppflight-cloud.conf" "$CASE/sshd_config.d/50-cloud-init.conf" "$CASE/before/"
}
same_as_before() {
  local f
  for f in ppflight-login.conf 00-ppflight-cloud.conf 50-cloud-init.conf; do
    if [[ -f "$CASE/$f" ]]; then cmp -s "$CASE/$f" "$CASE/before/$f" || return 1
    else cmp -s "$CASE/sshd_config.d/$f" "$CASE/before/$f" || return 1; fi
  done
}

provider_case provider_wins
ssh_harden_stage < "$CASE/input" > "$CASE/out"
grep -Fxq 'ask comment out' "$CASE/trace" || fail 'commenting out the provider lines was not offered'
grep -q 'ppflight-login.conf 第 1 行：PasswordAuthentication yes' "$CASE/out" && grep -q '00-ppflight-cloud.conf 第 2 行：PasswordAuthentication yes' "$CASE/out" ||
  fail "the winning lines were not shown: $(cat "$CASE/out")"
if grep -q '50-cloud-init.conf' "$CASE/out"; then fail 'a line read after this tool'"'"'s file was shown as winning'; fi
tag="$(sed -n 's/^#vps-stable-off(ssh,\([0-9-]*\)): PasswordAuthentication yes$/\1/p' "$CASE/ppflight-login.conf")"
[[ -n "$tag" ]] || fail "provider file not commented out: $(cat "$CASE/ppflight-login.conf")"
[[ "$(sed -n 2p "$CASE/sshd_config.d/00-ppflight-cloud.conf")" == "#vps-stable-off(ssh,$tag): PasswordAuthentication yes" ]] || fail 'provider drop-in not commented out'
cmp -s "$CASE/sshd_config.d/50-cloud-init.conf" "$CASE/before/50-cloud-init.conf" || fail 'cloud-init'"'"'s file, read later, was changed'
arm="$(grep '^arm ' "$CASE/trace")"
[[ "$arm" == "arm vps-stable-ssh-revert-$tag rm -f -- '$SSH_DROPIN'; sed -i 's/^#vps-stable-off(ssh,$tag): //' "* ]] || fail "guard does not put the lines back: $arm"
[[ "$arm" == *"'$CASE/ppflight-login.conf'"* && "$arm" == *"'$CASE/sshd_config.d/00-ppflight-cloud.conf'"* ]] || fail "guard misses a file: $arm"
grep -Fxq 'result ssh applied key-only user=alice' "$CASE/trace" || fail "hardening not applied: $(cat "$CASE/trace")"
grep -q '注释掉的行保持注释' "$CASE/out" || fail 'what stays commented out was not said'
# Rollback: the provider's lines back byte for byte, sshd reloaded.
restore_needed() { return 1; }
restore_read() { return 1; }
restore_resource() { record "resource $1"; rm -f -- "$SSH_DROPIN"; }
restore_mark() { :; }
: > "$CASE/trace"; RESTORE_PARTIAL=0
restore_ssh_group
same_as_before || fail 'rollback did not put the provider'"'"'s lines back byte for byte'
grep -Fxq reload "$CASE/trace" && ((RESTORE_PARTIAL == 0)) || fail "rollback: $(cat "$CASE/trace")"
: > "$CASE/trace"; restore_ssh_group
if grep -Fxq reload "$CASE/trace"; then fail 'a second rollback still found something to undo'; fi
unset -f restore_needed restore_read restore_resource restore_mark

# vps check after the provider wrote its line back at boot.
provider_case written_back
ssh_harden_stage < "$CASE/input" > "$CASE/out"
sed -i 's/^#vps-stable-off(ssh,[0-9-]*): //' "$CASE/sshd_config.d/00-ppflight-cloud.conf"
ssh_password_disabled() { [[ "$(sshd -T | awk '$1 == "passwordauthentication" {print $2}')" == no ]]; }
check_ssh 'key-only user=alice'
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'00-ppflight-cloud.conf 第 2 行'*'服务商'*'SSH 加固'* ]] || fail "check after a write-back: $VERIFY_STATUS $VERIFY_TEXT"
sed -i '2s/^/#vps-stable-off(ssh,1-1): /' "$CASE/sshd_config.d/00-ppflight-cloud.conf"
check_ssh 'key-only user=alice'
[[ "$VERIFY_STATUS" == pass ]] || fail "check with the lines commented out: $VERIFY_TEXT"
unset -f ssh_password_disabled

provider_case provider_declined
COMMENT_OK=0
ssh_harden_stage < "$CASE/input" > "$CASE/out"
same_as_before && [[ ! -e "$SSH_DROPIN" ]] || fail 'something changed although commenting out was declined'
grep -q '^result ssh preserved earlier sshd setting wins' "$CASE/trace" || fail 'declined: not reported as kept'
if grep -q '^arm ' "$CASE/trace"; then fail 'guard armed although nothing changed'; fi

provider_case provider_unconfirmed
GUARD_OK=0
ssh_harden_stage < "$CASE/input" > "$CASE/out"
same_as_before && [[ ! -e "$SSH_DROPIN" ]] || fail 'an unconfirmed change left provider lines commented out'
grep -q '^result ssh failed second login not confirmed' "$CASE/trace" || fail 'unconfirmed: not reported'

# Commented out, yet sshd still keeps password login on (a line this tool
# cannot see): everything goes back.
provider_case still_overridden
printf 'PasswordAuthentication yes\n' > "$CASE/sshd_config.d/00-aaa-hidden.conf"
cp -p "$CASE/sshd_config.d/00-aaa-hidden.conf" "$CASE/before/"
sshd_reads() { return 0; }
sshd_setting_overrides() { printf '%s\t2\t0\tPasswordAuthentication yes\n' "$CASE/sshd_config.d/00-ppflight-cloud.conf"; }
ssh_harden_stage < "$CASE/input" > "$CASE/out"
same_as_before && [[ ! -e "$SSH_DROPIN" ]] || fail 'lines left commented out although it did not help'
grep -q '^result ssh preserved' "$CASE/trace" || fail 'still overridden: not reported'
load_optimizer_functions sshd_reads sshd_setting_overrides

# Key login turned off by the provider's 00- drop-in, which sorts before this
# tool's 00-vps-stable-pubkey.conf: commented out (it stays: key login only
# adds a way in), then the hardening goes on with its own change.
provider_case pubkey_provider
printf '%s\n' '# provider' 'PasswordAuthentication yes' 'PubkeyAuthentication no' > "$CASE/sshd_config.d/00-ppflight-cloud.conf"
cp -p "$CASE/sshd_config.d/00-ppflight-cloud.conf" "$CASE/before/"
ssh_harden_stage < "$CASE/input" > "$CASE/out"
grep -q '^#vps-stable-off(ssh,[0-9]*-[0-9]*-1): PubkeyAuthentication no$' "$CASE/sshd_config.d/00-ppflight-cloud.conf" || fail "key login line: $(cat "$CASE/sshd_config.d/00-ppflight-cloud.conf")"
grep -Fxq 'result ssh applied key-only user=alice' "$CASE/trace" || fail "hardening after key login: $(cat "$CASE/trace")"
arm="$(grep '^arm ' "$CASE/trace")"
if [[ "$arm" == *'-1): '* ]]; then fail "the hardening's guard would put the key login line back: $arm"; fi
printf 'PASS: a provider'"'"'s earlier line is named, commented out on a yes and put back by the guard, the rollback, or when it does not help; vps check names a line written back.\n'

# The session limits are parameters. A key-only drop-in of this tool with the
# old ones is written again under a guard timer, kept after a key login, put
# back without one; the same text or a file that is not ours stays as it is.
(
  load_optimizer_functions ssh_dropin_refresh
  P="$TEST_ROOT/ssh-params"; printf 'ssh_max_auth_tries=6\nssh_login_grace_seconds=45\nssh_x11_forwarding=yes\n' > "$P"
  text="$(PARAMS_FILE="$P" ssh_dropin_text 1)"
  for setting in 'MaxAuthTries 6' 'LoginGraceTime 45' 'X11Forwarding yes' 'PermitRootLogin no'; do
    grep -Fxq "$setting" <<< "$text" || fail "drop-in with parameters lacks: $setting"
  done
  new_case refresh
  STATE_ROOT="$CASE/state"; mkdir -p "$STATE_ROOT" "$(dirname "$SSH_DROPIN")"
  ssh_dropin_text 1 > "$SSH_DROPIN"; cp "$SSH_DROPIN" "$CASE/old"
  restore_file_ours() { [[ "$1" == ssh_dropin ]] && ((OURS)); }
  module_expect() { printf 'applied\tboot-1\tkey-only user=alice root-ssh=off\n'; }
  OURS=1 GUARD_OK=1
  PARAMS_FILE="$P" ssh_dropin_refresh > "$CASE/out"
  [[ "$(cat "$SSH_DROPIN")" == "$text" ]] || fail "new limits not written: $(cat "$SSH_DROPIN")"
  grep -q "^arm vps-stable-ssh-revert-[0-9-]* cp -pf '$STATE_ROOT/ssh-dropin-previous' '$SSH_DROPIN'" "$CASE/trace" || fail "no guard: $(cat "$CASE/trace")"
  grep -Fxq 'result ssh applied key-only user=alice root-ssh=off' "$CASE/trace" || fail "result after the refresh: $(cat "$CASE/trace")"
  # No key login: the previous drop-in back, reloaded.
  cp "$CASE/old" "$SSH_DROPIN"; : > "$CASE/trace"; GUARD_OK=0
  PARAMS_FILE="$P" ssh_dropin_refresh > "$CASE/out"
  cmp -s "$SSH_DROPIN" "$CASE/old" && grep -Fxq reload "$CASE/trace" || fail 'an unconfirmed refresh was kept'
  if grep -q '^result ' "$CASE/trace"; then fail 'an unconfirmed refresh recorded as applied'; fi
  # Nothing to do: the same limits, or not this tool's file.
  : > "$CASE/trace"; ssh_dropin_refresh > "$CASE/out"
  if grep -q '^arm ' "$CASE/trace"; then fail 'a guard for unchanged limits'; fi
  OURS=0; : > "$CASE/trace"; PARAMS_FILE="$P" ssh_dropin_refresh > "$CASE/out"
  cmp -s "$SSH_DROPIN" "$CASE/old" && ! grep -q '^arm ' "$CASE/trace" || fail "a drop-in that is not ours was changed"
  # The guard timer: the confirmation time plus a minute.
  load_optimizer_functions guard_arm
  systemd-run() { printf '%s\n' "$*" > "$CASE/run"; }
  active() { return 0; }
  STATE_ROOT="$CASE/state"; mkdir -p "$STATE_ROOT"
  printf 'guard_seconds=300\n' > "$P"
  PARAMS_FILE="$P" guard_arm unit-a /bin/true
  grep -Fq -- '--on-active=360s' "$CASE/run" || fail "guard timer with 300 s: $(cat "$CASE/run")"
  PARAMS_FILE=/nonexistent guard_arm unit-b /bin/true
  grep -Fq -- '--on-active=240s' "$CASE/run" || fail "guard timer by default: $(cat "$CASE/run")"
  # What systemd is given is one plain path: a ";" on its command line came back
  # as "\\;" after a daemon-reload on systemd 252, and nothing was put back.
  PARAMS_FILE=/nonexistent guard_arm unit-c "rm -f -- 'a b'; systemctl try-reload-or-restart ssh.service"
  if grep -Eq '[;]| -c ' "$CASE/run"; then fail "commands on systemd's command line: $(cat "$CASE/run")"; fi
  [[ "$(cat "$CASE/state/guard/unit-c.sh")" == "rm -f -- 'a b'; systemctl try-reload-or-restart ssh.service" ]] || fail "guard file: $(cat "$CASE/state/guard/unit-c.sh")"
  grep -Fq "/bin/sh $CASE/state/guard/unit-c.sh" "$CASE/run" || fail "guard file not run: $(cat "$CASE/run")"
  # A file whose timer is gone goes at the next arming; one still counting stays.
  active() { [[ "$1" != unit-a.timer ]]; }
  PARAMS_FILE=/nonexistent guard_arm unit-d true
  [[ ! -e "$CASE/state/guard/unit-a.sh" && -e "$CASE/state/guard/unit-b.sh" ]] || fail "guard files: $(ls "$CASE/state/guard" | tr '\n' ' ')"
)
printf 'PASS: the SSH session limits and the guard time are parameters; changed limits are applied under a guard.\n'
