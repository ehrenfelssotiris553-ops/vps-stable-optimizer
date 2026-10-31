#!/usr/bin/env bash
# CI only, as root on the machine under test: what package upgrades changed
# during the run, from APT's history. A rollback keeps upgrades by design (it
# never downgrades), so snapdiff.py accepts these packages and the files under
# /etc they own. Counted: every "Upgrade:" line, and the installs and removals
# of system upgrades (new kernels, old kernels cleaned up, unattended-upgrade).
# Usage: upgrade-info.sh 'YYYY-MM-DD HH:MM:SS' (only transactions from then on)
set -Eeuo pipefail
export LC_ALL=C
history=/var/log/apt/history.log
[[ -r "$history" ]] || exit 0
pkgs="$(awk -v since="${1:-}" '
  /^Start-Date:/ {line = $0; sub(/^Start-Date: */, "", line); gsub(/ +/, " ", line); recent = line >= since; system_upgrade = 0}
  !recent {next}
  /^Commandline:/ {
    system_upgrade = $0 ~ / (upgrade|full-upgrade|dist-upgrade)( |$)/ || $0 ~ /unattended-upgrade/ || $0 ~ /linux-(image|modules|headers)/
  }
  /^Upgrade:/ || (system_upgrade && /^(Install|Remove|Purge):/) {
    sub(/^[A-Za-z]+: /, "")
    n = split($0, items, /\), /)
    for (i = 1; i <= n; i++) {name = items[i]; sub(/[: ].*/, "", name); if (name != "") print name}
  }
' "$history" | sort -u)"
for p in $pkgs; do
  printf 'upgradepkg %s\n' "$p"
  dpkg -L "$p" 2>/dev/null | awk '/^\/etc\// {print "upgradefile " $0}'
done | sort -u
