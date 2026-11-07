#!/usr/bin/env bash
# CI only, as root on the machine under test: one sorted line per fact about
# what the tool can change or leave behind. One snapshot is taken before the
# install and one after the full rollback and uninstall; snapdiff.py compares
# them and fails on every difference it cannot explain.
set -Eeuo pipefail
export LC_ALL=C
{
  sysctl -a 2>/dev/null | sed 's/^/sysctl /' || true
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null |
    awk '$1 == "ii" {print "pkg " $2} $1 == "rc" {print "pkgconf " $2}' || true
  # Configuration files that removed packages keep (state "rc"), dpkg's own
  # and those kept with ucf.
  rc="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 == "rc" {print $2}')"
  for p in $rc; do
    dpkg-query -W -f='${Conffiles}\n' "$p" 2>/dev/null | awk 'NF >= 2 {print "rcfile " $1}'
    if [[ -r /var/lib/ucf/registry ]]; then awk -v p="$p" '$1 == p {print "rcfile " $2}' /var/lib/ucf/registry; fi
  done
  apt-mark showauto 2>/dev/null | sed 's/^/autopkg /' || true
  systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk 'NF >= 2 {print "unit " $1 " " $2}' || true
  # (and the PAM profiles pam-auth-update reads, where the login record adds one)
  while IFS= read -r -d '' f; do
    h="$(sha256sum < "$f" 2>/dev/null || echo unreadable)"
    printf 'file %s %s\n' "$f" "${h%% *}"
  done < <(find /etc /usr/share/pam-configs -xdev -type f -print0 2>/dev/null | sort -z)
  # Which package each file under /etc belongs to (dpkg's lists, and ucf's for
  # the configuration it manages): a file a system upgrade dropped is explained
  # only as a file of an upgraded package.
  awk 'FNR == 1 {p = FILENAME; sub(/.*\//, "", p); sub(/\.list$/, "", p); sub(/:.*/, "", p)} /^\/etc\// {print "owner " $0 " " p}' \
    /var/lib/dpkg/info/*.list 2>/dev/null || true
  if [[ -r /var/lib/ucf/registry ]]; then awk 'NF >= 2 && $2 ~ /^\/etc\// {print "owner " $2 " " $1}' /var/lib/ucf/registry; fi
  # Whether the units the tool can turn on run, not only whether they start at
  # boot (systemctl is-active says "inactive" for one that is not there).
  for u in ufw.service fail2ban.service vnstat.service unattended-upgrades.service systemd-timesyncd.service chrony.service \
      fstrim.timer apt-daily.timer apt-daily-upgrade.timer swapfile.swap vps-stable-check.timer; do
    printf 'active %s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
  done
  # The disk swap file itself (an inactive one is not in /proc/swaps).
  if [[ -e /swapfile ]]; then printf 'swapfile %s\n' "$(stat -c '%s %a %U' /swapfile)"; fi
  find /etc -xdev -type l -printf 'link %p -> %l\n'
  find /etc -xdev -xtype l -printf 'dangling %p\n'
  find /etc -xdev -type d -printf 'dir %p\n'
  # Where the tool installs itself and keeps its data (packages put their own
  # things under /usr/local/share, for example fonts).
  for d in /usr/local/bin /usr/local/lib /var/lib/vps-stable-opt /var/backups/vps-stable-opt /var/log/vps-stable-opt; do
    if [[ -e "$d" ]]; then find "$d" -xdev -printf 'local %p\n'; fi
  done
  crontab -l -u root 2>/dev/null | sed 's/^/cron /' || true
  if command -v nft >/dev/null; then
    nft list ruleset 2>/dev/null | sed -E 's/ # handle [0-9]+//; s/counter packets [0-9]+ bytes [0-9]+/counter/; s/^[[:space:]]+//' | sed 's/^/nft /' || true
  fi
  for t in iptables-save ip6tables-save; do
    if command -v "$t" >/dev/null; then
      "$t" 2>/dev/null | grep -v '^#' | sed -E 's/\[[0-9]+:[0-9]+\]/[0:0]/' | sed "s/^/$t /" || true
    fi
  done
  awk 'NR > 1 {print "swap " $1 " " $2}' /proc/swaps
  # UFW's stored rules, line by line (a changed checksum alone does not say what).
  for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
    if [[ -r "$f" ]]; then { grep -v '^#' "$f" || true; } | sed "s|^|ufwrule ${f##*/}: |"; fi
  done
  getent passwd | awk -F: '{print "user " $1 " " $3}'
  systemctl list-units --all --no-legend --plain 'vps-stable-*' 2>/dev/null | awk '{print "vpsunit " $1}' || true
} | sort -u
