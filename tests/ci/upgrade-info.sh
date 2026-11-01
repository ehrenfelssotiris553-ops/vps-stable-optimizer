#!/usr/bin/env bash
# CI only, as root on the machine under test: what package upgrades changed
# during the run, from APT's history. A rollback keeps upgrades by design (it
# never downgrades), so snapdiff.py accepts these packages and the files under
# /etc they own. Counted: every "Upgrade:" line, and the installs and removals
# of system upgrades (new kernels, old kernels cleaned up, unattended-upgrade).
# Usage: upgrade-info.sh 'YYYY-MM-DD HH:MM:SS' (only transactions from then on)
set -Eeuo pipefail
export LC_ALL=C
# Units their own service switched off during the run, as the journal shows
# it: a systemctl that the unit's own service started removed its enablement
# link. Debian 13's apt-listchanges.timer ("try hourly to initialize the
# database") does this once the database is made, at the top of an hour.
journalctl -q --since "${1:-}" -o short-unix --no-pager -t systemd -t systemctl 2>/dev/null | awk '
  $3 ~ /^systemctl\[[0-9]+\]:$/ && $4 == "Removed" {pid = $3; gsub(/[^0-9]/, "", pid); link = $5; gsub(/[^A-Za-z0-9_.@\/-]/, "", link); sub(/\.$/, "", link)
    if (link ~ /^\/etc\/systemd\/system\/[^\/]+\.wants\//) {n = split(link, part, "/"); removed[pid] = part[n]}}
  $3 ~ /^systemd\[1\]:$/ && $4 == "Reload" && $5 == "requested" && $8 == "PID" {pid = $9; for (i = 10; i <= NF; i++) if ($i == "(unit") {u = $(i + 1); sub(/\)\.*$/, "", u); by[pid] = u}}
  END {for (p in removed) {u = removed[p]; s = by[p]; sub(/\.[a-z]+$/, "", u); sub(/\.service$/, "", s); if (s != "" && u == s) print "selfdisabled " removed[p]}}' | sort -u || true
history=/var/log/apt/history.log
[[ -r "$history" ]] || exit 0
pkgs="$(awk -v since="${1:-}" '
  /^Start-Date:/ {line = $0; sub(/^Start-Date: */, "", line); gsub(/ +/, " ", line); recent = line >= since; system_upgrade = 0}
  !recent {next}
  /^Commandline:/ {
    system_upgrade = $0 ~ / (upgrade|full-upgrade|dist-upgrade)( |$)/ || $0 ~ /unattended-upgrade/ || $0 ~ /linux-(image|modules|headers)/
  }
  system_upgrade && /^Upgrade:/ {print "@system-upgrade"}
  /^Upgrade:/ || (system_upgrade && /^(Install|Remove|Purge):/) {
    sub(/^[A-Za-z]+: /, "")
    n = split($0, items, /\), /)
    for (i = 1; i <= n; i++) {name = items[i]; sub(/[: ].*/, "", name); if (name != "") print name}
  }
' "$history" | sort -u)"
for p in $pkgs; do
  if [[ "$p" == @system-upgrade ]]; then echo 'systemupgrade yes'; continue; fi
  printf 'upgradepkg %s\n' "$p"
  { dpkg -L "$p" 2>/dev/null || true; } |
    awk -F/ '/^\/etc\// {print "upgradefile " $0} /\/systemd\/system\/[^\/]+\.(service|timer|socket|path|target|mount)$/ {print "upgradeunit " $NF}'
done | sort -u
