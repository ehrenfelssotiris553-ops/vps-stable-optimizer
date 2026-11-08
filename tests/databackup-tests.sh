#!/usr/bin/env bash
# Data backup: the settings, what restic is given (and what it must never see
# on its command line), one run with all its outcomes, the password, the
# answers it accepts, the stage and the way back. restic, ssh and systemd are
# stand-ins here; tests/ci/real-run.sh and docker-run.sh back up and restore for real.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions databackup_on databackup_conf databackup_conf_write databackup_restic databackup_notify databackup_finish databackup_drill databackup_run \
  databackup_service_text databackup_timer_text databackup_units_write databackup_ask_sftp databackup_ask_s3 databackup_ask_rclone databackup_ask_local databackup_ask_target \
  databackup_password databackup_stage databackup_restore databackup_now databackup_menu databackup_main menu_backup_alert check_databackup audit_clean_text audit_when \
  restore_ids restore_group_ids restore_databackup_group restore_groups item_keys item_label
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
STATE_ROOT="$TEST_ROOT/state" CALLS="$TEST_ROOT/calls" D="$TEST_ROOT/state/databackup"
BACKUP_SERVICE_FILE="$TEST_ROOT/backup.service" BACKUP_TIMER_FILE="$TEST_ROOT/backup.timer" PARAMS_FILE="$TEST_ROOT/params"
mkdir -p -- "$D"
linux() { [[ "$(uname -s)" == Linux ]]; }
# Git Bash cannot set Unix modes on a directory.
if ! linux; then install() { mkdir -p -- "${@: -1}"; }; fi
say() { :; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*"; }
die() { printf 'DIE: %s\n' "$*"; exit 1; }
# flock is part of the real runs; here only "free" and "held" matter.
flock() { return "${FLOCK_RC:-0}"; }
# Sets one parameter for this section.
param() { printf '%s=%s\n' "$1" "$2" >> "$PARAMS_FILE"; }
# Every parameter this run looks at, without depending on what exists here.
reset() {
  : > "$CALLS"
  rm -rf -- "$D"
  mkdir -p -- "$D" "$TEST_ROOT/data/keep"
  rm -f -- "$PARAMS_FILE" "$STATE_ROOT/notify.conf" "$STATE_ROOT/backup-before" "$BACKUP_SERVICE_FILE" "$BACKUP_TIMER_FILE"
  rm -rf -- "$STATE_ROOT/notify"
  param backup_paths "$TEST_ROOT/data /nonexistent/backup-path"
  param backup_drill_days 0
  databackup_conf_write type=local "repo=$TEST_ROOT/repo"
}
# Records one call per line, arguments separated by |.
restic() {
  local IFS='|'
  printf '%s\n' "$*" >> "$CALLS"
  printf '%s:%s:%s\n' "${AWS_ACCESS_KEY_ID:-}" "${AWS_SECRET_ACCESS_KEY:-}" "${AWS_DEFAULT_REGION:-}" > "$TEST_ROOT/restic.env"
  case "|$*|" in
    *'|backup|'*) printf 'Files: 1 new\nprocessed 3 files, 1.500 KiB in 0:01\n'; if ((${RESTIC_BACKUP_RC:-0} != 0)); then echo 'Fatal: the disk is on fire'; fi; return "${RESTIC_BACKUP_RC:-0}" ;;
    *'|forget|'*) return "${RESTIC_FORGET_RC:-0}" ;;
    *'|check|'*) return "${RESTIC_CHECK_RC:-0}" ;;
    *'|ls|'*)
      printf 'snapshot 12345678 of [/etc] filtered by []:\n'
      printf 'drwxr-xr-x     0     0      0 2026-11-08 03:30:00 /etc\n'
      printf -- '-rw-r--r--     0     0      6 2026-11-08 03:30:00 /etc/a.conf\n'
      printf -- '-rw-r--r--     0     0      4 2026-11-08 03:30:00 /etc/b[1].conf\n'
      printf -- '-rw-r--r--     0     0      4 2026-11-08 03:30:00 /etc/with space.conf\n'
      printf -- '-rw-r--r--     0     0 999999999 2026-11-08 03:30:00 /etc/huge.bin\n'
      printf -- '-rw-r--r--     0     0      0 2026-11-08 03:30:00 /etc/empty\n' ;;
    *'|restore|'*)
      local target='' prev=''
      local a
      for a in "$@"; do if [[ "$prev" == --target ]]; then target="$a"; fi; prev="$a"; done
      if [[ "${RESTIC_RESTORE_BAD:-0}" != 1 ]]; then mkdir -p -- "$target/etc" && printf 'hello\n' > "$target/etc/a.conf"; else mkdir -p -- "$target/etc" && printf 'x' > "$target/etc/a.conf"; fi
      return "${RESTIC_RESTORE_RC:-0}" ;;
    *'|snapshots|'*) return "${RESTIC_SNAPSHOTS_RC:-0}" ;;
    *'|cat|config|'*) return "${RESTIC_CAT_RC:-0}" ;;
    *'|init|'*) return "${RESTIC_INIT_RC:-0}" ;;
  esac
}
calls_of() { grep -E -- "[|]$1([|]|$)" "$CALLS" || true; }

# 1. Settings are read, never run; written whole and for root only.
reset
databackup_conf_write 'a=$(touch '"$TEST_ROOT"'/ran)' 'b=one two' 'b=second'
[[ "$(databackup_conf a)" == '$(touch '"$TEST_ROOT"'/ran)' ]] || fail "value not read literally: $(databackup_conf a)"
[[ ! -e "$TEST_ROOT/ran" ]] || fail 'a value of the settings was executed'
[[ "$(databackup_conf b)" == 'one two' ]] || fail 'first value of a key'
[[ -z "$(databackup_conf nothing)" ]] || fail 'value of a missing key'
if linux; then [[ "$(stat -c %a "$D/conf")" == 600 ]] || fail "settings mode $(stat -c %a "$D/conf")"; fi
[[ -z "$(find "$D" -name '.conf.*' -print -quit)" ]] || fail 'temporary file left'
printf 'PASS: the settings are read as text and written for root only.\n'

# 2. What restic gets. The keys and the password never reach its command line.
reset
databackup_conf_write type=s3 repo=s3:https://x.example/b/p access_key=AKIDSECRETA secret_key=SECRETSECRETB region=auto
databackup_restic snapshots
line="$(cat "$CALLS")"
[[ "$line" == "--cache-dir|$D/cache|--password-file|$D/password|-r|s3:https://x.example/b/p|snapshots" ]] || fail "arguments: $line"
if grep -Fq 'SECRET' "$CALLS"; then fail "a storage key on restic's command line: $line"; fi
[[ "$(cat "$TEST_ROOT/restic.env")" == 'AKIDSECRETA:SECRETSECRETB:auto' ]] || fail "keys not passed on: $(cat "$TEST_ROOT/restic.env")"
[[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] || fail 'key left in the environment of the script itself'
: > "$CALLS"
databackup_conf_write type=sftp 'repo=sftp:bak@203.0.113.7:backups/x' host=203.0.113.7 port=2222 user=bak
databackup_restic snapshots
line="$(cat "$CALLS")"
[[ "$line" == *"|-o|sftp.command=ssh -i $D/id_ed25519 -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$D/known_hosts"* ]] || fail "sftp: $line"
[[ "$line" == *' bak@203.0.113.7 -s sftp|snapshots' ]] || fail "sftp end: $line"
[[ "$(cat "$TEST_ROOT/restic.env")" == '::' ]] || fail 'keys of an earlier target passed on'
printf 'PASS: passwords and keys reach restic through a file and the environment only; SFTP checks the host key.\n'

# 3. One run.
reset
touch "$TEST_ROOT/data/a.tmp"
param backup_exclude "/root/.cache *.tmp"
param backup_limit_mbps 10
(cd "$TEST_ROOT/data" && databackup_run > /dev/null) || fail 'a run that worked failed'
line="$(calls_of backup)"
for want in '--one-file-system' '--exclude-caches' '--tag|vps-stable' "--exclude|$D" '--exclude|/root/.cache' '--exclude|*.tmp' "--exclude|$TEST_ROOT/repo" '--limit-upload|1220' "|$TEST_ROOT/data"; do
  [[ "$line" == *"$want"* ]] || fail "backup without $want: $line"
done
if [[ "$line" == *'--exclude|a.tmp'* ]]; then fail 'exclude rule expanded by the shell'; fi
if [[ "$line" == *nonexistent* ]]; then fail 'a directory that does not exist given to restic'; fi
IFS=$'\t' read -r when status note < "$D/last"
[[ "$status" == ok && "$note" == '3 个文件，1.500 KiB，用时 0:01' ]] || fail "last: $status $note"
[[ "$when" =~ ^[0-9]+$ && "$(cat "$D/last-ok")" == "$when" ]] || fail 'time of the last success'
line="$(calls_of forget)"
for want in '--tag|vps-stable' '--keep-daily|7' '--keep-weekly|4' '--keep-monthly|6' '--prune'; do [[ "$line" == *"$want"* ]] || fail "forget without $want: $line"; done
[[ -s "$D/last-prune" ]] || fail 'time of the clean-up not kept'
: > "$CALLS"
databackup_run > /dev/null || fail 'second run'
if [[ "$(calls_of forget)" == *--prune* ]]; then fail 'the heavy clean-up runs more than once a week'; fi
[[ -n "$(calls_of forget)" ]] || fail 'old backups no longer thinned out'
printf '1\n' > "$D/last-prune"
: > "$CALLS"
databackup_run > /dev/null || fail 'a week later'
[[ "$(calls_of forget)" == *--prune* ]] || fail 'no clean-up after a week'
printf 'PASS: a run backs up what exists, keeps the exclude rules literal and thins out old backups.\n'

reset
(RESTIC_BACKUP_RC=3; databackup_run > /dev/null) || fail 'some files unreadable counted as failed'
[[ "$(cut -f2 "$D/last")" == ok && "$(cut -f3 "$D/last")" == *有文件读不了* ]] || fail "partial: $(cat "$D/last")"
reset
if (RESTIC_BACKUP_RC=1; databackup_run > /dev/null); then fail 'a failed backup reported as done'; fi
[[ "$(cut -f2 "$D/last")" == fail && "$(cut -f3 "$D/last")" == *'the disk is on fire'* ]] || fail "failure: $(cat "$D/last")"
[[ ! -e "$D/last-ok" ]] || fail 'failure counted as success'
[[ -z "$(calls_of forget)" ]] || fail 'old backups removed after a failed backup'
reset
(RESTIC_FORGET_RC=1; databackup_run > /dev/null) || fail 'failed clean-up fails the backup'
[[ "$(cut -f2 "$D/last")" == ok && "$(cut -f3 "$D/last")" == *清理旧备份没有成功* ]] || fail "clean-up: $(cat "$D/last")"
[[ ! -e "$D/last-prune" ]] || fail 'failed clean-up counted as done'
reset
param backup_paths /nonexistent/one
if databackup_run > /dev/null; then fail 'nothing to back up reported as done'; fi
[[ "$(cut -f3 "$D/last")" == *都不存在* ]] || fail "no paths: $(cat "$D/last")"
[[ -z "$(calls_of backup)" ]] || fail 'restic started with nothing to back up'
reset
rc=0; (FLOCK_RC=1; databackup_run > /dev/null) || rc=$?
((rc == 75)) || fail "another backup running: $rc"
[[ ! -s "$CALLS" ]] || fail "restic started next to another backup: $(cat "$CALLS")"
[[ ! -e "$D/last" ]] || fail 'another backup running recorded as a result'
reset
rm -f -- "$D/conf"
if databackup_run > /dev/null; then fail 'no settings reported as done'; fi
printf 'PASS: partial, failed, nothing to do and a second run at once are told apart.\n'

# The script to run first (a database dump), only as root's own regular file.
reset
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$TEST_ROOT" > "$STATE_ROOT/backup-before"
chmod +x "$STATE_ROOT/backup-before"
databackup_run > /dev/null || fail 'run with a script first'
[[ -e "$TEST_ROOT/hook-ran" ]] || fail 'script to run first did not run'
rm -f -- "$TEST_ROOT/hook-ran"
reset
printf '#!/bin/sh\nexit 1\n' > "$STATE_ROOT/backup-before"
chmod +x "$STATE_ROOT/backup-before"
if databackup_run > /dev/null; then fail 'failed dump reported as done'; fi
[[ "$(cut -f3 "$D/last")" == *备份前要运行的脚本失败了* ]] || fail "hook: $(cat "$D/last")"
[[ -z "$(calls_of backup)" ]] || fail 'backed up without the fresh dump'
if linux; then
  reset
  printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$TEST_ROOT" > "$TEST_ROOT/elsewhere"
  chmod +x "$TEST_ROOT/elsewhere"
  ln -s "$TEST_ROOT/elsewhere" "$STATE_ROOT/backup-before"
  databackup_run > /dev/null || fail 'run with a linked script'
  [[ ! -e "$TEST_ROOT/hook-ran" ]] || fail 'followed a symbolic link to a script'
  rm -f -- "$STATE_ROOT/backup-before"
fi
printf 'PASS: the script to run first runs only as a plain file here, and stops the backup when it fails.\n'

# The restore drill: a real restore of a sample, sizes compared.
# Git Bash has no /var/tmp; everywhere else the real place is checked.
DRILL_ROOT=/var/tmp
if [[ ! -d "$DRILL_ROOT" ]]; then
  DRILL_ROOT="$TEST_ROOT/vartmp"
  mkdir -p -- "$DRILL_ROOT"
  mktemp() { if [[ "${2:-}" == /var/tmp/* ]]; then command mktemp -d "$DRILL_ROOT/vps-backup-drill.XXXXXX"; else command mktemp "$@"; fi; }
fi
reset
param backup_drill_days 30
(shuf() { cat; }; databackup_run > /dev/null) || fail 'run with a drill'
[[ -n "$(calls_of check)" ]] || fail 'no check in the drill'
line="$(calls_of restore)"
[[ "$line" == *'--include|/etc/a.conf'* ]] || fail "drill sample: $line"
for bad in 'b[1]' 'with space' huge.bin /etc/empty; do if [[ "$line" == *"$bad"* ]]; then fail "drill sample has $bad (a pattern, a space, too big or empty): $line"; fi; done
[[ "$line" == *"--target|$DRILL_ROOT/vps-backup-drill."* ]] || fail "drill target: $line"
[[ -s "$D/drill-last" && "$(cut -f3 "$D/last")" == *恢复演练通过* ]] || fail 'drill not recorded'
[[ -z "$(find "$DRILL_ROOT" -maxdepth 1 -name 'vps-backup-drill.*' -print -quit 2>/dev/null)" ]] || fail 'restored files left behind'
: > "$CALLS"
databackup_run > /dev/null || fail 'run after the drill'
[[ -z "$(calls_of check)" ]] || fail 'drill before it is due'
printf '1\n' > "$D/drill-last"
: > "$CALLS"
if (shuf() { cat; }; RESTIC_RESTORE_BAD=1; databackup_run > /dev/null); then fail 'a restore that came back wrong passed'; fi
[[ "$(cut -f2 "$D/last")" == fail && "$(cut -f3 "$D/last")" == *恢复演练没有通过* ]] || fail "drill: $(cat "$D/last")"
reset
param backup_drill_days 30
if (RESTIC_CHECK_RC=1; databackup_run > /dev/null); then fail 'a repository that fails its check passed'; fi
[[ -z "$(calls_of restore)" ]] || fail 'restore tried after a failed check'
[[ ! -e "$D/drill-last" ]] || fail 'failed drill counted as done'
reset
param backup_drill_days 0
databackup_run > /dev/null
[[ -z "$(calls_of check)" ]] || fail 'drill although set to never'
printf 'PASS: the drill really restores a sample and fails when what comes back is wrong.\n'

# What is told, and to whom.
notify_run() { reset; mkdir -p -- "$STATE_ROOT/notify"; printf 'chat=1\n' > "$STATE_ROOT/notify.conf"; for pair in "$@"; do param "${pair%%=*}" "${pair#*=}"; done; }
queued() { cat "$STATE_ROOT/notify/queue" 2>/dev/null || true; }
notify_run; (RESTIC_BACKUP_RC=1; databackup_run > /dev/null) || true
[[ "$(queued)" == *数据备份失败* ]] || fail "failure not told: $(queued)"
[[ "$(wc -l < "$STATE_ROOT/notify/queue" | tr -d ' ')" == 1 ]] || fail 'one notification is one line'
notify_run; databackup_run > /dev/null
[[ -z "$(queued)" ]] || fail "success told with the setting fail: $(queued)"
notify_run backup_notify=all; databackup_run > /dev/null
[[ "$(queued)" == *数据备份完成* ]] || fail 'success not told with the setting all'
notify_run backup_notify=never; (RESTIC_BACKUP_RC=1; databackup_run > /dev/null) || true
[[ -z "$(queued)" ]] || fail 'told with the setting never'
notify_run 'notify_events=login oom'; (RESTIC_BACKUP_RC=1; databackup_run > /dev/null) || true
[[ -z "$(queued)" ]] || fail 'told although this kind is switched off'
notify_run 'notify_events=login backup'; (RESTIC_BACKUP_RC=1; databackup_run > /dev/null) || true
[[ -n "$(queued)" ]] || fail 'not told although this kind is on'
reset; (RESTIC_BACKUP_RC=1; databackup_run > /dev/null) || true
[[ ! -e "$STATE_ROOT/notify/queue" ]] || fail 'queued without TG set up'
reset; mkdir -p -- "$STATE_ROOT/notify"; printf 'chat=1\n' > "$STATE_ROOT/notify.conf"
databackup_notify $'line one\nline two'
[[ "$(tr '\037' '@' < "$STATE_ROOT/notify/queue")" == 'line one@line two' ]] || fail "line breaks: $(queued)"
printf 'PASS: results reach TG as set, in the one-line form its queue needs.\n'

# 4. The password: shown on the terminal, never in anything that gets logged.
pass_reset() { rm -f -- "$D/password" "$TEST_ROOT/tty"; }
confirm_yes() { record_ask "$1"; return "${CONFIRM_RC:-0}"; }
confirm_default_yes() { record_ask "$1"; return "${CONFIRM_DEFAULT_RC:-0}"; }
record_ask() { printf 'ask %s\n' "$1" >> "$CALLS"; }
exec {UI_TTY_FD}> "$TEST_ROOT/tty"
pass_reset; exec {UI_TTY_FD}> "$TEST_ROOT/tty"
out="$(printf '\n' | databackup_password 2>&1)" || fail "generated: $out"
pw="$(cat "$D/password")"
[[ "$pw" =~ ^[A-Za-z0-9]{20,32}$ ]] || fail "generated password: $pw"
grep -Fq "$pw" "$TEST_ROOT/tty" || fail 'generated password not shown on the terminal'
if grep -Fq "$pw" <<< "$out"; then fail 'generated password in the output that goes to the run log'; fi
if linux; then [[ "$(stat -c %a "$D/password")" == 600 ]] || fail 'password file mode'; fi
pass_reset; exec {UI_TTY_FD}> "$TEST_ROOT/tty"
out="$(printf 'my-secret-pass\nmy-secret-pass\n' | databackup_password 2>&1)" || fail "typed: $out"
[[ "$(cat "$D/password")" == my-secret-pass ]] || fail 'typed password not saved'
if grep -Fq 'my-secret-pass' <<< "$out" || grep -Fq 'my-secret-pass' "$TEST_ROOT/tty"; then fail 'typed password echoed'; fi
pass_reset
if printf 'my-secret-pass\nother-pass\n' | databackup_password > /dev/null 2>&1; then fail 'two different answers accepted'; fi
[[ ! -e "$D/password" ]] || fail 'saved after two different answers'
if printf 'short\nshort\n' | databackup_password > /dev/null 2>&1; then fail 'short password accepted'; fi
[[ ! -e "$D/password" ]] || fail 'short password saved'
if (CONFIRM_RC=1; printf '\n' | databackup_password > /dev/null 2>&1); then fail 'went on without the password being kept elsewhere'; fi
[[ ! -e "$D/password" ]] || fail 'saved although the user has no copy'
if (UI_TTY_FD=''; printf '\n' | databackup_password > /dev/null 2>&1); then fail 'generated a password it cannot show'; fi
[[ ! -e "$D/password" ]] || fail 'saved a password nobody saw'
printf 'old-password\n' > "$D/password"
: > "$CALLS"
databackup_password < /dev/null > /dev/null || fail 'existing password'
[[ "$(cat "$D/password")" == old-password && ! -s "$CALLS" ]] || fail 'existing password asked for or replaced'
printf 'PASS: a generated password is shown once on the terminal only, and nothing is saved that the user has no copy of.\n'

# 5. The answers that are accepted.
ssh-keygen() { case "$1" in -q) printf 'PRIVATE\n' > "$D/id_ed25519"; printf 'ssh-ed25519 AAAA bak\n' > "$D/id_ed25519.pub" ;; -lf) echo '256 SHA256:abc host (ED25519)' ;; esac; }
ssh-keyscan() { [[ "${KEYSCAN_RC:-0}" == 0 ]] || return 1; echo 'host ssh-ed25519 AAAA'; }
sftp() { printf 'sftp %s\n' "$*" >> "$CALLS"; return "${SFTP_RC:-0}"; }
hostname() { echo testhost; }
rm_conf() { rm -f -- "$D/conf" "$D/known_hosts" "$D/known_hosts.new" "$D/id_ed25519"; : > "$CALLS"; }
refused() { # WHAT FUNCTION INPUT
  rm_conf
  if printf '%b' "$3" | "$2" > /dev/null 2>&1; then fail "$1 accepted"; fi
  [[ ! -e "$D/conf" ]] || fail "$1: settings written"
}
refused 'empty SFTP host' databackup_ask_sftp '\n'
refused 'SFTP host with a shell character' databackup_ask_sftp 'a;reboot\n22\nbak\nbackups\n\n'
refused 'SFTP host with an option' databackup_ask_sftp 'x y\n22\nbak\nbackups\n\n'
refused 'port 70000' databackup_ask_sftp 'h.example\n70000\nbak\nbackups\n\n'
refused 'port 0' databackup_ask_sftp 'h.example\n0\nbak\nbackups\n\n'
refused 'port with text' databackup_ask_sftp 'h.example\n22a\nbak\nbackups\n\n'
refused 'odd user' databackup_ask_sftp 'h.example\n22\nroot;x\nbackups\n\n'
refused 'directory with ..' databackup_ask_sftp 'h.example\n22\nbak\n../etc\n\n'
refused 'directory with a shell character' databackup_ask_sftp 'h.example\n22\nbak\na$(b)\n\n'
(KEYSCAN_RC=1; refused 'unreachable host' databackup_ask_sftp 'h.example\n22\nbak\nbackups\n')
(CONFIRM_DEFAULT_RC=1; refused 'a fingerprint the user does not recognise' databackup_ask_sftp 'h.example\n22\nbak\nbackups\n'; [[ ! -e "$D/known_hosts" && ! -e "$D/known_hosts.new" ]] || fail 'host key kept after it was rejected')
(SFTP_RC=1; refused 'a key that does not log in' databackup_ask_sftp 'h.example\n22\nbak\nbackups\n\n\n\n'; [[ "$(grep -c '^sftp ' "$CALLS")" == 3 ]] || fail 'not tried three times')
rm_conf
out="$(printf 'h.example\n2222\nbak\nmy/backups\n\n' | databackup_ask_sftp 2>&1)" || fail "SFTP: $out"
[[ "$(databackup_conf type)|$(databackup_conf repo)|$(databackup_conf host)|$(databackup_conf port)|$(databackup_conf user)" == 'sftp|sftp:bak@h.example:my/backups|h.example|2222|bak' ]] || fail "SFTP settings: $(cat "$D/conf")"
grep -Fq "ssh-ed25519 AAAA bak" <<< "$out" || fail 'public key not shown'
grep -Fq 'SHA256:abc' <<< "$out" || fail 'fingerprint not shown'
[[ -s "$D/known_hosts" ]] || fail 'host key not kept'
grep -q 'StrictHostKeyChecking=yes' "$CALLS" || fail "login test does not check the host: $(cat "$CALLS")"
rm_conf
printf '2001:db8::7\n22\nbak\nb\n\n' | databackup_ask_sftp > /dev/null 2>&1 || fail 'IPv6 host'
[[ "$(databackup_conf repo)" == 'sftp:bak@[2001:db8::7]:b' ]] || fail "IPv6 repo: $(databackup_conf repo)"

refused 'empty S3 address' databackup_ask_s3 '\n'
refused 'S3 address without a scheme' databackup_ask_s3 'x.example\nbucket\np\nauto\nAK\nSK\n'
refused 'S3 address with a path' databackup_ask_s3 'https://x.example/a;b\nbucket\np\nauto\nAK\nSK\n'
refused 'bucket with a slash' databackup_ask_s3 'https://x.example\na/b\np\nauto\nAK\nSK\n'
refused 'prefix with ..' databackup_ask_s3 'https://x.example\nbucket\n../p\nauto\nAK\nSK\n'
refused 'empty S3 key' databackup_ask_s3 'https://x.example\nbucket\np\nauto\n\nSECRET\n'
refused 'S3 secret with a space' databackup_ask_s3 'https://x.example\nbucket\np\nauto\nAK\nS E\n'
rm_conf
out="$(printf 'https://x.example/\nbucket\nsome/prefix\nauto\nAKID\nSECRETVALUE\n' | databackup_ask_s3 2>&1)" || fail "S3: $out"
[[ "$(databackup_conf repo)|$(databackup_conf access_key)|$(databackup_conf secret_key)|$(databackup_conf region)" == 's3:https://x.example/bucket/some/prefix|AKID|SECRETVALUE|auto' ]] || fail "S3 settings: $(cat "$D/conf")"
if grep -Fq SECRETVALUE <<< "$out"; then fail 'the S3 secret was printed'; fi

rclone() { case "$1" in listremotes) printf '%s' "${RCLONE_REMOTES-gdrive:
}" ;; lsd) return "${RCLONE_RC:-0}" ;; esac; }
install_pkgs() { printf 'install %s\n' "$*" >> "$CALLS"; }
(RCLONE_REMOTES=''; refused 'rclone with nothing set up' databackup_ask_rclone '')
refused 'empty rclone target' databackup_ask_rclone '\n'
refused 'rclone target without a remote' databackup_ask_rclone 'just-a-path\n'
refused 'rclone target with a shell character' databackup_ask_rclone 'gdrive:a;b\n'
(RCLONE_RC=1; refused 'a remote that cannot be reached' databackup_ask_rclone 'gdrive:b\n')
rm_conf
printf 'gdrive:backups/x\n' | databackup_ask_rclone > /dev/null 2>&1 || fail 'rclone target'
[[ "$(databackup_conf repo)" == 'rclone:gdrive:backups/x' ]] || fail "rclone repo: $(databackup_conf repo)"

refused 'relative directory' databackup_ask_local 'some/dir\n'
refused 'directory with ..' databackup_ask_local '/var/../etc\n'
(CONFIRM_RC=1; refused 'a local directory not confirmed' databackup_ask_local "$TEST_ROOT/l\n"; [[ ! -e "$TEST_ROOT/l" ]] || fail 'directory made although refused')
rm_conf
out="$(printf '%s/local-repo/\n' "$TEST_ROOT" | databackup_ask_local 2>&1)" || fail "local: $out"
[[ "$(databackup_conf repo)" == "$TEST_ROOT/local-repo" && -d "$TEST_ROOT/local-repo" ]] || fail "local repo: $(databackup_conf repo)"
grep -Fq '机器出事' <<< "$out" || fail 'no warning about keeping the backup on the same machine'
rm_conf
if printf '\n' | databackup_ask_target > /dev/null 2>&1; then fail 'Enter at the target question did not cancel'; fi
if printf '9\n' | databackup_ask_target > /dev/null 2>&1; then fail 'number 9 accepted as a target'; fi
printf 'PASS: every answer that would reach a command line or a file is checked first.\n'

# 6. The stage: nothing is switched on before one backup has worked.
state_secure_dir() { mkdir -p -- "$1"; }
installed() { return "${INSTALLED_RC:-0}"; }
install_pkgs() { printf 'install %s\n' "$*" >> "$CALLS"; return "${INSTALL_RC:-0}"; }
module_result() { RESULT="$1 $2"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$CALLS"; return "${SYSTEMCTL_RC:-0}"; }
restore_file_ours() { return 0; }
restore_adopt() { printf 'adopt %s\n' "$1" >> "$CALLS"; }
check_file_write() { printf 'write %s\n' "$1" >> "$CALLS"; printf '%s\n' "$3" > "$2"; }
put_target() { databackup_conf_write type=local "repo=$TEST_ROOT/repo"; }
databackup_ask_target() { [[ "${TARGET_RC:-0}" == 0 ]] || return 1; printf 'ask target\n' >> "$CALLS"; put_target; }
databackup_password() { [[ "${PASSWORD_RC:-0}" == 0 ]] || return 1; printf 'pw\n' > "$D/password"; }
stage_reset() { reset; rm -f -- "$D/conf"; DATABACKUP_CHOICE=1 RESTIC_CAT_RC=1 RESULT=''; }
no_units() { [[ ! -e "$BACKUP_SERVICE_FILE" && ! -e "$BACKUP_TIMER_FILE" ]] || fail "$1: units written"; }
go() { databackup_stage > "$TEST_ROOT/out" 2>&1; }

stage_reset; DATABACKUP_CHOICE=''; go
[[ "$RESULT" == 'databackup declined' ]] || fail "not chosen: $RESULT"; no_units 'not chosen'; [[ ! -s "$CALLS" ]] || fail 'something happened although not chosen'
(stage_reset; INSTALLED_RC=1 INSTALL_RC=1; go; [[ "$RESULT" == 'databackup failed' ]] || fail "no restic: $RESULT"; no_units 'no restic')
(stage_reset; TARGET_RC=1; go; [[ "$RESULT" == 'databackup declined' ]] || fail "no target: $RESULT"; no_units 'no target')
(stage_reset; PASSWORD_RC=1; go; [[ "$RESULT" == 'databackup declined' ]] || fail "no password: $RESULT"; no_units 'no password')
(stage_reset; RESTIC_INIT_RC=1; go; [[ "$RESULT" == 'databackup failed' ]] || fail "init: $RESULT"; no_units 'init failed'; [[ -z "$(calls_of backup)" ]] || fail 'backed up without a repository')
(stage_reset; RESTIC_BACKUP_RC=1; go; [[ "$RESULT" == 'databackup failed' ]] || fail "first backup: $RESULT"; no_units 'first backup failed'; grep -Fq 'the disk is on fire' "$TEST_ROOT/out" || fail "reason not shown: $(cat "$TEST_ROOT/out")")
(
  stage_reset; go
  [[ "$RESULT" == 'databackup applied' ]] || fail "on: $RESULT $(cat "$TEST_ROOT/out")"
  [[ -n "$(calls_of init)" ]] || fail 'repository not made'
  # Made first, then filled, then scheduled.
  [[ "$(grep -n '|init' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '|backup|' "$CALLS" | cut -d: -f1)" ]] || fail 'order init/backup'
  [[ "$(grep -n '|backup|' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^write databackup_service' "$CALLS" | cut -d: -f1)" ]] || fail 'scheduled before a backup worked'
  grep -Fq 'write databackup_timer_file' "$CALLS" || fail 'timer not written'
  grep -Fq 'systemctl enable --now vps-stable-backup.timer' "$CALLS" || fail 'timer not on'
  grep -Fq '03:30' "$TEST_ROOT/out" || fail "when not said: $(cat "$TEST_ROOT/out")"
)
(
  # On again with the settings kept: the repository is not made anew.
  stage_reset; put_target; RESTIC_CAT_RC=0; go
  [[ "$RESULT" == 'databackup applied' ]] || fail "again: $RESULT"
  [[ -z "$(calls_of init)" ]] || fail 'init on an existing repository'
  if grep -Fq 'ask target' "$CALLS"; then fail 'asked for a target although the old one is kept'; fi
)
(stage_reset; put_target; CONFIRM_DEFAULT_RC=1; go; grep -Fq 'ask target' "$CALLS" || fail 'old target forced on the user')
(stage_reset; param backup_time manual; go; [[ "$RESULT" == 'databackup applied' ]] || fail "manual: $RESULT"; [[ ! -e "$BACKUP_TIMER_FILE" ]] || fail 'timer file with manual'; if grep -Fq 'enable --now vps-stable-backup.timer' "$CALLS"; then fail 'timer on with manual'; fi; grep -Fq 'vps backup now' "$TEST_ROOT/out" || fail 'how to back up by hand not said')
(stage_reset; SYSTEMCTL_RC=1; go; [[ "$RESULT" == 'databackup failed' ]] || fail "timer not starting: $RESULT")
printf 'PASS: nothing is switched on before one backup has worked.\n'

# 7. The units and changing the schedule.
service="$(databackup_service_text)"
for line in 'Type=oneshot' 'Nice=10' 'IOSchedulingClass=idle' 'OOMScoreAdjust=500' 'ExecStart=/bin/bash /usr/local/lib/vps-stable-opt/vps-stable-opt.sh databackup-run'; do grep -Fxq "$line" <<< "$service" || fail "service without $line"; done
timer="$(databackup_timer_text 04:15)"
for line in 'OnCalendar=*-*-* 04:15:00' 'RandomizedDelaySec=900' 'Persistent=true' 'WantedBy=timers.target'; do grep -Fxq "$line" <<< "$timer" || fail "timer without $line: $timer"; done
reset
param backup_time 05:00
RESTORE_STAGE=''
databackup_units_write > /dev/null
grep -Fxq 'OnCalendar=*-*-* 05:00:00' "$BACKUP_TIMER_FILE" || fail 'timer does not follow the parameter'
grep -Fq 'adopt databackup_timer_file' "$CALLS" || fail 'a schedule changed from the parameters is not counted as this tool'"'"'s'
param backup_time manual
: > "$CALLS"
databackup_units_write > /dev/null
[[ ! -e "$BACKUP_TIMER_FILE" ]] || fail 'timer file left when changed to manual'
grep -Fq 'systemctl disable --now vps-stable-backup.timer' "$CALLS" || fail 'timer left running when changed to manual'
[[ -f "$BACKUP_SERVICE_FILE" ]] || fail 'service gone with manual'
RESTORE_STAGE=databackup
reset
databackup_units_write > /dev/null
if grep -Fq adopt "$CALLS"; then fail 'adopted inside its own stage, which records it anyway'; fi
RESTORE_STAGE=''
printf 'PASS: the schedule follows the parameter, also to and from manual.\n'

# 8. The check, the menu's line, the status.
verify_set() { VERDICT="$1 $2"; }
check() { VERDICT=''; check_databackup; }
now="$(date +%s)"
systemctl() { [[ "$1" != is-active ]] || return "${TIMER_RC:-0}"; }
reset; check; [[ "$VERDICT" == pass*还没有备份过* ]] || fail "check, none yet: $VERDICT"
reset; printf '%s\tok\t3 个文件\n' "$now" > "$D/last"; check; [[ "$VERDICT" == pass*'3 个文件'* ]] || fail "check, ok: $VERDICT"
(TIMER_RC=1; check; [[ "$VERDICT" == fail*定时备份* ]] || fail "check, timer off: $VERDICT")
reset; printf '%s\tfail\tthe disk\n' "$now" > "$D/last"; check; [[ "$VERDICT" == fail*'the disk'* ]] || fail "check, failed: $VERDICT"
reset; printf '%s\tok\tfine\n' "$((now - 3 * 86400 - 60))" > "$D/last"; check; [[ "$VERDICT" == fail*超过*天* ]] || fail "check, old: $VERDICT"
reset; printf '%s\tok\tfine\n' "$((now - 2 * 86400))" > "$D/last"; check; [[ "$VERDICT" == pass* ]] || fail "check, 2 days: $VERDICT"
reset; param backup_time manual; printf '%s\tok\tfine\n' "$((now - 30 * 86400))" > "$D/last"; check; [[ "$VERDICT" == pass* ]] || fail "check, manual and old: $VERDICT"
(reset; param backup_time manual; TIMER_RC=1; check; [[ "$VERDICT" == pass* ]] || fail "check, manual has no timer: $VERDICT")
reset; rm -f -- "$D/conf"; check; [[ "$VERDICT" == fail* ]] || fail "check, settings gone: $VERDICT"
: > "$BACKUP_SERVICE_FILE"
reset; : > "$BACKUP_SERVICE_FILE"
printf '%s\tfail\tthe disk\n' "$now" > "$D/last"
[[ "$(menu_backup_alert)" == *'the disk'* ]] || fail "menu line: $(menu_backup_alert)"
printf '%s\tok\tfine\n' "$now" > "$D/last"
[[ -z "$(menu_backup_alert)" ]] || fail 'menu line after a backup that worked'
rm -f -- "$D/last"
[[ -z "$(menu_backup_alert)" ]] || fail 'menu line before any backup'
databackup_on || fail 'not on'
rm -f -- "$BACKUP_SERVICE_FILE"
if databackup_on; then fail 'on without its service (after a rollback)'; fi
printf 'PASS: the check and the menu say when the last backup failed or is too old.\n'

# 9. Restoring goes to a new directory; what is on the machine is not touched.
reset
: > "$CALLS"
restore_run() { printf '%b' "$1" | databackup_restore > "$TEST_ROOT/out" 2>&1; }
restore_run 'not-an-id\n'; [[ -z "$(calls_of restore)" ]] || fail 'restored a bad snapshot ID'
restore_run '\nrelative/path\n'; [[ -z "$(calls_of restore)" ]] || fail 'restored a relative path'
restore_run '\n/etc/a;b\n'; [[ -z "$(calls_of restore)" ]] || fail 'restored a path with a shell character'
(CONFIRM_RC=1; restore_run '\n\n'; [[ -z "$(calls_of restore)" ]] || fail 'restored without a yes')
restore_run '\n/etc/nginx\n'
line="$(calls_of restore)"
[[ "$line" == *'|restore|latest|--target|/root/vps-restore-'* && "$line" == *'|--include|/etc/nginx' ]] || fail "restore: $line"
: > "$CALLS"
restore_run 'abcd1234\n\n'
line="$(calls_of restore)"
[[ "$line" == *'|restore|abcd1234|--target|/root/vps-restore-'* ]] || fail "restore of one snapshot: $line"
if [[ "$line" == *--include* ]]; then fail "restore of everything with a filter: $line"; fi
(RESTIC_SNAPSHOTS_RC=1; : > "$CALLS"; restore_run '\n\n'; [[ -z "$(calls_of restore)" ]] || fail 'restored without a list'; grep -Fq 读不到 "$TEST_ROOT/out" || fail 'list failure not said')
printf 'PASS: a restore goes to a new directory, after a yes.\n'

# 10. Backing up by hand: what it says.
reset
out="$(databackup_now 2>&1)"; [[ "$out" == *备份完成* ]] || fail "by hand: $out"
out="$( (RESTIC_BACKUP_RC=1; databackup_now 2>&1) )"; [[ "$out" == *备份没有成功*'the disk is on fire'* ]] || fail "by hand, failed: $out"
out="$( (FLOCK_RC=1; databackup_now 2>&1) )"; [[ "$out" == *另一次备份正在运行* ]] || fail "by hand, busy: $out"; [[ "$out" != *备份完成* ]] || fail 'busy reported as done'
rm -f -- "$D/conf"
out="$(databackup_now 2>&1)"; [[ "$out" == *还没有设置备份目标* ]] || fail "by hand, no settings: $out"
out="$(databackup_menu 2>&1 < /dev/null)"; [[ "$out" == *先选*开启* ]] || fail "menu, no settings: $out"
if ((EUID != 0)); then
  out="$( (MODE_ARGS=(now); databackup_main 2>&1) || true)"; [[ "$out" == *需要\ root* ]] || fail "not root: $out"
fi
printf 'PASS: backing up by hand says what really happened.\n'

# 11. The way back.
[[ "$(restore_ids databackup | tr '\n' ' ')" == 'databackup_timer databackup_service databackup_timer_file ' ]] || fail "tracked: $(restore_ids databackup | tr '\n' ' ')"
grep -Fxq databackup <<< "$(restore_groups)" || fail 'no rollback group'
grep -Fxq databackup <<< "$(item_keys)" || fail 'no single item'
[[ "$(item_label databackup)" == '数据备份' ]] || fail 'label'
reset
printf 'pw\n' > "$D/password"
restore_resource() { printf 'restore %s\n' "$1" >> "$CALLS"; }
systemctl() { :; }
out="$(restore_databackup_group)"
for id in databackup_timer databackup_service databackup_timer_file; do grep -Fxq "restore $id" "$CALLS" || fail "$id not restored"; done
grep -Fq 留在目标上 <<< "$out" || fail 'does not say the backups stay'
[[ -s "$D/password" && -s "$D/conf" ]] || fail 'the settings and password went with the rollback: the backups could not be used again'
[[ -z "$(calls_of forget)" ]] || fail 'the backups were touched by the rollback'
printf 'PASS: the rollback stops the schedule and leaves the backups and what opens them.\n'
