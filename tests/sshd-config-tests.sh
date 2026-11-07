#!/usr/bin/env bash
# sshd's reading order, as this tool works it out to find the lines that win
# over its own drop-in, and commenting such lines out and back again without
# changing anything else. A real Debian 13 VPS (2026-11-03) had
# "PasswordAuthentication yes" in sshd_config.d/00-ppflight-cloud.conf and in
# a file that sshd_config includes on its first line: the SSH hardening could
# not turn password login off and did not say where it was kept on.
# Files are fixtures; no sshd runs here (the CI compares with a real one).
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions sshd_line_value sshd_config_walk sshd_include_args sshd_reads sshd_setting_overrides sshd_port_lines \
  sshd_lines_show sshd_lines_off sshd_lines_on sshd_lines_on_cmd sshd_off_files restore_record_sshd_file audit_clean_text
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN %s\n' "$*" >> "$T/log"; }
backup_config_path() { printf '%s\n' "$1" >> "$T/backups"; }
record_config_change() { :; }
restore_data_safe() { [[ -f "$1" && ! -L "$1" ]]; }
RESTORE_ROOT="$T/restore" RESTORE_READY=1 SSHD_CONFIG=/etc/ssh/sshd_config
mkdir -p "$RESTORE_ROOT"

# ---- Values -------------------------------------------------------------------
for line in 'PasswordAuthentication yes' 'passwordauthentication YES' 'PasswordAuthentication=yes' \
  'PasswordAuthentication = "yes"' 'PasswordAuthentication yes # the provider' $'PasswordAuthentication\tyes'; do
  [[ "$(sshd_line_value "$line")" == yes ]] || fail "value of <$line>: $(sshd_line_value "$line")"
done
[[ "$(sshd_line_value 'Port 2222')" == 2222 && -z "$(sshd_line_value 'Port # none')" ]] || fail 'Port values'
got="$(sshd_include_args 'Include /etc/a.conf b/*.conf # note' | tr '\n' ' ')"
[[ "$got" == '/etc/a.conf /etc/ssh/b/*.conf ' ]] || fail "Include arguments: $got"
printf 'PASS: sshd_config values in all their spellings.\n'

# ---- The layout of the real VPS -----------------------------------------------
E="$T/etc/ssh"
D="$E/sshd_config.d"
mkdir -p "$D"
SSHD_CONFIG="$E/sshd_config"
OWN="$D/01-vps-stable-keyonly.conf"
# sshd_config: the provider's file first, the drop-ins (a relative Include,
# as in Debian's own sshd_config), then later settings and a Match block.
printf '%s\n' "Include $E/ppflight-login.conf" '# Provider image' 'Port 22' '' 'Include sshd_config.d/*.conf' \
  'ChallengeResponseAuthentication yes' 'PasswordAuthentication yes' 'Match User backup' '	PasswordAuthentication yes' > "$SSHD_CONFIG"
# Its Match block ends with the file: "Port 22" in sshd_config is global again.
printf '%s\n' '# provider login settings' 'PasswordAuthentication yes' 'Match Address 10.0.0.0/8' '  PermitRootLogin yes' > "$E/ppflight-login.conf"
printf '%s\n' '# cloud' 'PasswordAuthentication yes' 'ChallengeResponseAuthentication yes' > "$D/00-ppflight-cloud.conf"
printf '%s\n' '# VPS Stable Optimizer' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' > "$OWN"
printf '%s\n' 'PasswordAuthentication yes' > "$D/50-cloud-init.conf"
printf '%s\n' 'PasswordAuthentication yes' > "$D/README"

order="$(sshd_config_walk | awk -F'\t' '{n = split($1, p, "/"); printf "%s:%s:%s ", p[n], $2, $3}')"
expect='sshd_config:1:0 ppflight-login.conf:2:0 ppflight-login.conf:3:0 ppflight-login.conf:4:1 sshd_config:3:0 sshd_config:5:0 00-ppflight-cloud.conf:2:0 00-ppflight-cloud.conf:3:0 01-vps-stable-keyonly.conf:2:0 01-vps-stable-keyonly.conf:3:0 01-vps-stable-keyonly.conf:4:0 50-cloud-init.conf:1:0 sshd_config:6:0 sshd_config:7:0 sshd_config:8:0 sshd_config:9:1 '
[[ "$order" == "$expect" ]] || fail "reading order:
 got    $order
 wanted $expect"
printf 'PASS: the reading order follows each Include where it stands, in name order, and a Match block ends with its file.\n'

names() { awk -F'\t' 'NF {n = split($1, p, "/"); printf "%s:%s:%s ", p[n], $2, $3}' <<< "$1"; }
got="$(names "$(sshd_setting_overrides passwordauthentication no "$OWN")")"
[[ "$got" == 'ppflight-login.conf:2:0 00-ppflight-cloud.conf:2:0 sshd_config:9:1 ' ]] || fail "password login kept on by: $got"
got="$(names "$(sshd_setting_overrides kbdinteractiveauthentication no "$OWN")")"
[[ "$got" == '00-ppflight-cloud.conf:3:0 ' ]] || fail "keyboard-interactive (old name) kept on by: $got"
got="$(names "$(sshd_setting_overrides permitrootlogin no "$OWN")")"
[[ "$got" == 'ppflight-login.conf:4:1 ' ]] || fail "root login kept on by: $got"
got="$(names "$(sshd_setting_overrides x11forwarding no "$OWN")")"
[[ -z "$got" ]] || fail "a setting nobody else sets: $got"
printf 'PASS: the lines that win are the ones read before this tool'"'"'s file and any Match line, not those read after it.\n'

# The first line read already says "no": nothing wins over this tool.
F="$T/first"; mkdir -p "$F/d"
printf '%s\n' "Include $F/d/*.conf" > "$F/sshd_config"
printf 'PasswordAuthentication no\n' > "$F/d/00-a.conf"; printf 'PasswordAuthentication yes\n' > "$F/d/00-b.conf"
got="$(SSHD_CONFIG="$F/sshd_config" sshd_setting_overrides passwordauthentication no "$F/d/01-vps-stable-keyonly.conf")"
[[ -z "$got" ]] || fail "a later line counted although an earlier one says no: $got"

# sshd reads this tool's file, or would once it exists; not without the Include.
sshd_reads "$OWN" || fail 'the own drop-in not read'
sshd_reads "$D/00-vps-stable-port.conf" || fail 'a drop-in to be written counted as not read'
if sshd_reads "$E/elsewhere/x.conf"; then fail 'a file no Include names counted as read'; fi
if SSHD_CONFIG="$F/missing" sshd_reads "$OWN"; then fail 'read without any sshd_config'; fi
printf 'Port 22\n' > "$F/plain"
if SSHD_CONFIG="$F/plain" sshd_reads "$F/d/01-x.conf"; then fail 'read although sshd_config includes nothing'; fi

# An Include that includes itself stops (16 levels, as OpenSSH).
printf '%s\n' "Include $F/loop.conf" > "$F/loop.conf"
[[ "$(SSHD_CONFIG="$F/loop.conf" sshd_config_walk | grep -c .)" == 17 ]] || fail 'Include loop not cut at 16 levels'

# Port lines: every one outside this tool's file (sshd listens on all).
printf '%s\n' '# VPS Stable Optimizer v2.8: SSH port' 'Port 2244' > "$D/00-vps-stable-port.conf"
got="$(names "$(sshd_port_lines "$D/00-vps-stable-port.conf")")"
[[ "$got" == 'sshd_config:3:0 ' ]] || fail "Port lines: $got"
rm -f "$D/00-vps-stable-port.conf"
shown="$(sshd_lines_show "$(sshd_setting_overrides passwordauthentication no "$OWN")")"
[[ "$shown" == *"ppflight-login.conf 第 2 行：PasswordAuthentication yes"* && "$shown" == *'Match 块里'* ]] || fail "shown: $shown"
printf 'PASS: nothing counts when the first line read agrees; files sshd reads (or would) are known; Include loops end; Port lines are listed.\n'

# ---- Commenting out and back --------------------------------------------------
snap="$T/snap"; mkdir -p "$snap"
cp -p "$SSHD_CONFIG" "$E/ppflight-login.conf" "$D/00-ppflight-cloud.conf" "$D/50-cloud-init.conf" "$snap/"
# A file without a newline at its end comes back without one.
printf 'PasswordAuthentication yes' > "$D/00-ppflight-cloud.conf"; cp -p "$D/00-ppflight-cloud.conf" "$snap/"
chmod 640 "$E/ppflight-login.conf"; mode="$(stat -c %a "$E/ppflight-login.conf")"
hits="$(sshd_setting_overrides passwordauthentication no "$OWN")"
sshd_lines_off ssh 1700000000-11 "$hits" || fail "commenting out failed: $(cat "$T/log" 2>/dev/null)"
[[ "$(sed -n 2p "$E/ppflight-login.conf")" == '#vps-stable-off(ssh,1700000000-11): PasswordAuthentication yes' ]] || fail "marked line: $(sed -n 2p "$E/ppflight-login.conf")"
[[ "$(sed -n 9p "$SSHD_CONFIG")" == $'#vps-stable-off(ssh,1700000000-11): \tPasswordAuthentication yes' ]] || fail 'indented Match line not kept whole after the mark'
[[ "$(sed -n 7p "$SSHD_CONFIG")" == 'PasswordAuthentication yes' ]] || fail 'a line read after this tool'"'"'s file was changed'
cmp -s "$D/50-cloud-init.conf" "$snap/50-cloud-init.conf" || fail 'a file that does not win was changed'
[[ "$(stat -c %a "$E/ppflight-login.conf")" == "$mode" ]] || fail 'file mode changed'
[[ -z "$(sshd_setting_overrides passwordauthentication no "$OWN")" ]] || fail 'still overridden after commenting out'
grep -Fxq "$SSHD_CONFIG" "$T/backups" && grep -Fxq "$E/ppflight-login.conf" "$T/backups" || fail 'changed files not backed up first'
[[ "$(sort "$RESTORE_ROOT/sshd_lines_off")" == "$(printf 'ssh\t%s\n' "$D/00-ppflight-cloud.conf" "$E/ppflight-login.conf" "$SSHD_CONFIG" | sort)" ]] ||
  fail "rollback record: $(cat "$RESTORE_ROOT/sshd_lines_off")"
[[ "$(sshd_off_files ssh 1700000000-11 | sort)" == "$(cut -f2 "$RESTORE_ROOT/sshd_lines_off" | sort)" ]] || fail 'files of the change'
[[ -z "$(sshd_off_files ssh 1700000000-99)" && -z "$(sshd_off_files sshport)" ]] || fail 'files of another change or group'
# The port change marks its own lines: each comes back with its own group.
sshd_lines_off sshport 1700000001-12 "$(sshd_port_lines "$D/00-vps-stable-port.conf")" || fail 'Port line not commented out'
[[ "$(sed -n 3p "$SSHD_CONFIG")" == '#vps-stable-off(sshport,1700000001-12): Port 22' ]] || fail 'Port line mark'
mapfile -t files < <(sshd_off_files ssh)
sshd_lines_on ssh 1700000000-11 "${files[@]}" || fail 'putting back failed'
[[ "$(sed -n 3p "$SSHD_CONFIG")" == '#vps-stable-off(sshport,1700000001-12): Port 22' ]] || fail 'the SSH group put back a Port line'
mapfile -t files < <(sshd_off_files sshport)
sshd_lines_on sshport '' "${files[@]}" || fail 'putting the Port line back failed'
for f in sshd_config ppflight-login.conf 00-ppflight-cloud.conf 50-cloud-init.conf; do
  [[ -f "$E/$f" ]] && file="$E/$f" || file="$D/$f"
  cmp -s "$file" "$snap/$f" || fail "$f is not byte for byte as before"
done
[[ "$(stat -c %a "$E/ppflight-login.conf")" == "$mode" ]] || fail 'file mode changed when put back'
printf 'PASS: lines are commented out behind a mark and come back byte for byte, each group and change its own.\n'

# The guard timer's command (no function of this tool at hand then).
sshd_lines_off ssh 1700000002-13 "$hits" || fail 'commenting out again failed'
mapfile -t files < <(sshd_off_files ssh 1700000002-13)
sh -c "true$(sshd_lines_on_cmd ssh 1700000002-13 "${files[@]}")" || fail 'the guard command failed'
for f in sshd_config ppflight-login.conf 00-ppflight-cloud.conf; do
  [[ -f "$E/$f" ]] && file="$E/$f" || file="$D/$f"
  cmp -s "$file" "$snap/$f" || fail "the guard command did not put $f back byte for byte"
done
printf 'PASS: the guard timer'"'"'s command puts the lines of its change back.\n'

# Refused before any file changes: a name a shell command could not carry
# safely, a link, a group rollback does not know.
printf 'PasswordAuthentication yes\n' > "$D/00 provider's.conf"
bad="$(sshd_setting_overrides passwordauthentication no "$OWN")"
[[ "$bad" == *"00 provider's.conf"* ]] || fail "fixture: $bad"
if sshd_lines_off ssh 1700000003-14 "$bad"; then fail 'a file name with a space and a quote was changed'; fi
cmp -s "$SSHD_CONFIG" "$snap/sshd_config" && cmp -s "$E/ppflight-login.conf" "$snap/ppflight-login.conf" || fail 'other files changed although one was refused'
rm -f "$D/00 provider's.conf"
if ln -s "$snap/50-cloud-init.conf" "$D/00-link.conf" 2>/dev/null && [[ -L "$D/00-link.conf" ]]; then
  if sshd_lines_off ssh 1700000003-14 "$(sshd_setting_overrides passwordauthentication no "$OWN")"; then fail 'a link was changed'; fi
  rm -f "$D/00-link.conf"
fi
if restore_record_sshd_file firewall "$SSHD_CONFIG"; then fail 'a group that does not put lines back accepted'; fi
printf 'PASS: odd names, links and unknown groups are refused before anything changes.\n'

# ---- The same layout read by a real sshd ---------------------------------------
# Layer 1 installs openssh-server (never started) and names its sshd in
# VPS_TEST_SSHD, so on Debian 12/13 and Ubuntu 22.04-26.04 (OpenSSH 8.9 to 10)
# this is never skipped: what this tool says wins is what sshd itself uses.
SSHD_BIN="${VPS_TEST_SSHD:-}"
if [[ -z "$SSHD_BIN" ]]; then
  printf 'SKIP: VPS_TEST_SSHD names no sshd: the reading order was not compared with a real one.\n'
  exit 0
fi
[[ -x "$SSHD_BIN" && $EUID -eq 0 ]] || fail "VPS_TEST_SSHD=$SSHD_BIN is no sshd to run (as root)"
made_run=0
if [[ ! -d /run/sshd ]]; then mkdir -m 0755 /run/sshd; made_run=1; fi
trap 'rm -rf -- "$T"; if ((made_run)); then rmdir /run/sshd 2>/dev/null || true; fi' EXIT
R="$T/real"; mkdir -p "$R/d"
ssh-keygen -q -t ed25519 -N '' -f "$R/hostkey" > /dev/null
SSHD_CONFIG="$R/sshd_config"
printf '%s\n' "HostKey $R/hostkey" "Include $R/provider-login.conf" 'Port 22' "Include $R/d/*.conf" \
  'ChallengeResponseAuthentication yes' 'PasswordAuthentication yes' 'Match User backup' '	PasswordAuthentication yes' > "$SSHD_CONFIG"
printf '%s\n' 'PasswordAuthentication yes' 'Match Address 10.0.0.0/8' '  PermitRootLogin yes' > "$R/provider-login.conf"
printf '%s\n' '# cloud' 'PasswordAuthentication yes' 'ChallengeResponseAuthentication yes' > "$R/d/00-provider-cloud.conf"
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' > "$R/d/01-vps-stable-keyonly.conf"
printf '%s\n' 'PasswordAuthentication yes' > "$R/d/50-cloud-init.conf"
printf '%s\n' 'Port 2244' > "$R/d/00-vps-stable-port.conf"
OWN="$R/d/01-vps-stable-keyonly.conf"
# KEY USER ADDR: the value sshd uses for that connection.
real() {
  "$SSHD_BIN" -T -f "$SSHD_CONFIG" -C "user=$2,host=client.example,addr=$3" > "$T/sshd-T" 2>&1 || fail "sshd -T failed: $(head -n 3 "$T/sshd-T")"
  awk -v k="$1" '$1 == k {print $2}' "$T/sshd-T" | sort -n | tr '\n' ' '
}
# (sshd before 9.x has no -V; the client of the same release tells.)
version="$(ssh -V 2>&1 | head -n 1 || true)"
# Before: sshd keeps password and keyboard-interactive login on, as predicted.
[[ "$(real passwordauthentication alice 203.0.113.9)" == 'yes ' && -n "$(sshd_setting_overrides passwordauthentication no "$OWN")" ]] || fail "$version: password login not predicted right"
[[ "$(real kbdinteractiveauthentication alice 203.0.113.9)" == 'yes ' && -n "$(sshd_setting_overrides kbdinteractiveauthentication no "$OWN")" ]] || fail "$version: keyboard-interactive (old name) not predicted right"
[[ "$(real permitrootlogin root 203.0.113.9)" == 'no ' && "$(real permitrootlogin root 10.1.2.3)" == 'yes ' ]] || fail "$version: the Match block of the included file"
[[ "$(real port alice 203.0.113.9)" == '22 2244 ' ]] || fail "$version: ports before"
# After commenting out what this tool lists: sshd uses this tool's values,
# for the Match blocks too; the ports are this tool's only.
sshd_lines_off ssh 1700000004-15 "$( { sshd_setting_overrides passwordauthentication no "$OWN"; sshd_setting_overrides kbdinteractiveauthentication no "$OWN"; sshd_setting_overrides permitrootlogin no "$OWN"; } | sort -u)" || fail 'commenting out failed'
sshd_lines_off sshport 1700000005-16 "$(sshd_port_lines "$R/d/00-vps-stable-port.conf")" || fail 'commenting out the Port line failed'
for who in 'alice 203.0.113.9' 'backup 203.0.113.9' 'root 10.1.2.3'; do
  read -r user addr <<< "$who"
  [[ "$(real passwordauthentication "$user" "$addr")" == 'no ' && "$(real kbdinteractiveauthentication "$user" "$addr")" == 'no ' ]] || fail "$version: password login still on for $who"
done
[[ "$(real permitrootlogin root 10.1.2.3)" == 'no ' ]] || fail "$version: root login still on through the Match block"
[[ "$(real port alice 203.0.113.9)" == '2244 ' ]] || fail "$version: ports after: $(real port alice 203.0.113.9)"
[[ "$(cat "$R/d/50-cloud-init.conf")" == 'PasswordAuthentication yes' ]] || fail 'a file read after this tool'"'"'s was changed'
# Put back: sshd as before.
mapfile -t files < <(sshd_off_files ssh); sshd_lines_on ssh '' "${files[@]}"
mapfile -t files < <(sshd_off_files sshport); sshd_lines_on sshport '' "${files[@]}"
[[ "$(real passwordauthentication alice 203.0.113.9)" == 'yes ' && "$(real port alice 203.0.113.9)" == '22 2244 ' ]] || fail "$version: not as before after putting back"
printf 'PASS: a real sshd (%s) uses exactly what this tool predicts, before and after the lines are commented out.\n' "$version"
