#!/usr/bin/env bash
# CI only, layer 2: the real tool on a throwaway Ubuntu runner. The steps are
# install, plan, one-click setup in custom mode, acceptance check, every single
# item switched off and on again, port management, a second check, full
# rollback with package removal, and uninstall. Each step is followed by checks
# on what it must leave behind. Run from anywhere; needs sudo without a password.
# Usage: real-run.sh [fresh|upgrade|alt|keep|docker]
#   upgrade: install and set up with the previous release (the newest other
#   version on origin/main, needs the git history), then upgrade in place;
#   everything after that is done by this version, as on a machine that updates.
#   alt: the setup answered the least recommended way (setup-alt.rules); what
#   was declined must stay as it was. No single items.
#   keep: uninstalled without the rollback (the settings stay, nothing of the
#   tool keeps running or is called by PAM), then installed and set up again.
#   docker: a machine running a container service (docker-run.sh).
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"
mode="${1:-fresh}"
case "$mode" in
  fresh | upgrade | alt | keep) ;;
  docker) exec bash "$CI/docker-run.sh" ;;
  *) fail 'usage: real-run.sh [fresh|upgrade|alt|keep|docker]' ;;
esac
version="$(sed -n 's/^SCRIPT_VERSION=//p' "$ROOT/vps-stable-opt.sh")"
# No step here waits long for its next question: a stuck one fails with its
# transcript well before the job's time limit.
# (Longer than apt's own 15 minutes of waiting for the package lock.)
export ANSWER_TIMEOUT="${ANSWER_TIMEOUT:-1500}"

state() {
  sysctl -n net.ipv4.tcp_congestion_control net.core.rmem_max net.ipv4.tcp_rmem kernel.kptr_restrict \
    net.ipv4.conf.all.accept_redirects net.ipv4.icmp_echo_ignore_all 2>/dev/null | tr -s '\t\n' '  '
}
tz() { timedatectl show -p Timezone --value; }
on_target() { sudo bash -c "$1"; }
ufw_line() { sudo ufw status 2>/dev/null | head -n 1 || true; }
ufw_added() { sudo ufw show added; }
# APT's policy as root sees it: apt-daily and unattended-upgrade run as root
# (that other users can read it too is apt_readable's check). grep reads the
# whole dump: with -q it stops at the first match, and under pipefail the
# writer's SIGPIPE turns a match into a failure (every time on Ubuntu 26.04,
# whose apt 3 writes the dump in more pieces).
apt_has() { sudo apt-config dump 2>/dev/null | grep -Fx -- "$1" > /dev/null; }
# NAME: the periodic policy as root and as this user, and the files behind it.
apt_views() {
  { echo '-- as root:'; sudo apt-config dump 2>/dev/null | grep '^APT::Periodic::' || true
    echo '-- as the CI user:'; apt-config dump 2>/dev/null | grep '^APT::Periodic::' || true
    echo '-- files setting it:'; sudo grep -lrs 'Periodic' /etc/apt/apt.conf /etc/apt/apt.conf.d | xargs -r sudo ls -l --
  } > "$LOGS/apt-views-$1.txt" 2>&1 || true
  notice "periodic APT policy, $1 ($mode, $(uname -m))" "$LOGS/apt-views-$1.txt"
}
installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == 'install ok installed' ]]; }
tool_packages() {
  local p
  for p in curl wget ca-certificates vim htop unzip lsof tmux; do if installed "$p"; then printf '%s ' "$p"; fi; done
}
before_state="$(state)" before_tz="$(tz)" before_ufw="$(ufw_line)"
tcp_rmem_max() { sysctl -n net.ipv4.tcp_rmem | awk '{print $3}'; }
before_cc="$(sysctl -n net.ipv4.tcp_congestion_control)" before_rmem="$(sysctl -n net.core.rmem_max)"
before_tcp_rmem="$(tcp_rmem_max)"
before_kptr="$(sysctl -n kernel.kptr_restrict)" before_tools="$(tool_packages)"
before_trim="$(systemctl is-enabled fstrim.timer 2>/dev/null || true)"
# An SSH keepalive the runner's image sets itself (GitHub's: 120 seconds) is
# kept by the tool; without one the tool's 60 seconds apply.
ka_kept=''
if sudo test -x /usr/sbin/sshd && sudo grep -REiq '^[[:space:]]*ClientAliveInterval' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
  sudo mkdir -p /run/sshd
  ka_kept="$(sudo /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "clientaliveinterval" && $2 != 0 {print $2}' || true)"
fi
printf 'SSH keepalive set by the image: %s\n' "${ka_kept:-none}"
before_updates=0 before_reboot=0
if apt_has 'APT::Periodic::Unattended-Upgrade "1";'; then before_updates=1; fi
if apt_has 'Unattended-Upgrade::Automatic-Reboot "true";'; then before_reboot=1; fi
before_periodic="$(sudo apt-config dump 2>/dev/null | grep '^APT::Periodic::' || true)"
apt_views before
# apt's configuration stays readable for every user (checked as this CI user):
# package scripts inherit the umask of whoever runs apt, and the tool's is 077.
apt_unreadable() { find /etc/apt -xdev ! -readable -print 2>/dev/null | sort || true; }
before_unreadable="$(apt_unreadable)"
apt_readable() {
  local left
  left="$(comm -13 <(printf '%s\n' "$before_unreadable") <(apt_unreadable) | grep . || true)"
  [[ -z "$left" ]] || fail "$1: apt configuration other users cannot read: $(tr '\n' ' ' <<< "$left")"
}
# What the run leaves under /etc that only root can read (reported, not judged).
run_marker="$LOGS/run-start"
touch "$run_marker"
printf 'Periodic APT policy before: %s\n' "$(tr '\n' ' ' <<< "${before_periodic:-none}")"
printf 'Before: %s | %s | %s\n' "$before_state" "$before_tz" "${before_ufw:-ufw not installed}"
# Firewall rules at the start: the tool keeps a firewall that has rules.
# shellcheck disable=SC2024
sudo nft list ruleset > "$LOGS/ruleset-start.txt" 2>&1 || true
if [[ -s "$LOGS/ruleset-start.txt" ]]; then notice "firewall rules at the start ($mode, $(uname -m))" "$LOGS/ruleset-start.txt"; fi
# The whole picture before anything is installed, compared at the very end.
# The snapshots belong to the CI user; only the scripts run as root.
snapshot_since="$(date '+%F %T')"
# shellcheck disable=SC2024
sudo bash "$CI/snapshot.sh" > "$LOGS/snapshot-before.txt"

if [[ "$mode" == upgrade ]]; then
  group 'Install the previous release'
  previous="$(previous_release "$version")" || fail 'no previous release on origin/main'
  read -r old_commit old_version <<< "$previous"
  printf 'Previous release: %s (%s)\n' "$old_version" "$old_commit"
  # The previous release starts stopped APT timers at once, and their catch-up
  # upgrade holds the package lock for the rest of the run here (hundreds of
  # updates; fixed in this version). Mark their last run as now, as this
  # version would; the other modes leave it to the tool.
  sudo touch /var/lib/systemd/timers/stamp-apt-daily.timer /var/lib/systemd/timers/stamp-apt-daily-upgrade.timer 2>/dev/null || true
  git -C "$ROOT" show "$old_commit:install.sh" > "$LOGS/old-install.sh"
  git -C "$ROOT" show "$old_commit:vps-stable-opt.sh" > "$LOGS/old-vps-stable-opt.sh"
  sudo bash "$LOGS/old-install.sh" --local-file "$LOGS/old-vps-stable-opt.sh" --no-run
  [[ "$(sudo vps --version)" == "$old_version" ]] || fail 'the previous release is not the installed one'
  endgroup
  group "One-click setup by $old_version (custom mode)"
  drive setup-custom.rules setup-old sudo vps setup || fail "setup by $old_version exited with $?"
  has setup-old '本次流程已完成'
  endgroup
  group "Upgrade in place to $version"
  sudo bash "$ROOT/install.sh" --local-file "$ROOT/vps-stable-opt.sh" --no-run
  [[ "$(sudo vps --version)" == "$version" ]] || fail 'the upgrade did not install this version'
  endgroup
else
  group 'Install from the checkout'
  sudo bash "$ROOT/install.sh" --local-file "$ROOT/vps-stable-opt.sh" --no-run
  [[ "$(sudo vps --version)" == "$version" ]] || fail 'installed version differs'
  endgroup

  group 'Plan (read-only)'
  # The transcript belongs to the CI user; only the tool runs as root.
  # shellcheck disable=SC2024
  sudo vps plan > "$LOGS/plan.log" 2>&1 || fail 'plan failed'
  grep -F '根据本次体检，接下来准备怎么做' "$LOGS/plan.log" || fail 'plan has no decision report'
  [[ "$(state)" == "$before_state" ]] || fail 'plan changed kernel settings'
  plan_facts plan
  endgroup

  rules=setup-custom.rules
  if [[ "$mode" == alt ]]; then rules=setup-alt.rules; fi
  group "One-click setup ($rules)"
  drive "$rules" setup sudo vps setup || fail "setup exited with $?"
  sed -n '/^【15\/15】Fail2ban/,/^【/p' "$LOGS/setup.log" > "$LOGS/setup-fail2ban.log"
  notice "Fail2ban step of the setup ($mode, $(uname -m))" "$LOGS/setup-fail2ban.log"
  has setup '本次流程已完成'
  ssh_facts setup
  endgroup
fi

# The health report must raise no false alarm on a fresh machine.
# The transcript belongs to the CI user; only the probe runs as root.
rc=0
# shellcheck disable=SC2024
sudo bash "$CI/journal-probe.sh" > "$LOGS/journal-probe.log" 2>&1 || rc=$?
notice "journal probe ($mode, $(uname -m))" "$LOGS/journal-probe.log"
((rc == 0)) || fail 'the health report counts journal lines on a fresh machine (see the journal probe notice)'

# NAME KEY CHOICE...: one `vps item` run that picks KEY in the menu, answers
# CHOICE... in turn in the item's own menu, and is then back at the menu and
# leaves it. Stage questions are answered as in the custom setup.
item_do() {
  local name="$1" key="$2" index rules="$LOGS/$1.rules"
  shift 2
  index="$(item_index "$key")" || fail "no single item $key"
  { printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> @seq %s\n' "$index" "$*"
    cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$rules"
  drive "$rules" "$name" sudo vps item || fail "single item $key ($*) exited with $?"
}

check_all() {
  local name="$1" rc=0
  drive check.rules "$name" sudo vps check || rc=$?
  cat "$LOGS/$name.log"
  [[ "$rc" == 0 || "$rc" == 3 ]] || fail "$name exited with $rc"
  for item in 'BBR 网络优化' '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区' '防火墙' 'Fail2ban 防爆破'; do
    passed "$name" "$item"
  done
  has "$name" '封禁 192.0.2.123：UFW 中出现了对应的拦截规则'
  has "$name" '解封 192.0.2.123：拦截规则已删除'
  [[ "$(tz)" == Asia/Shanghai ]] || fail "$name: timezone is $(tz)"
}
if [[ "$mode" == keep ]]; then
  group 'Uninstall without the rollback: the settings stay, nothing of the tool runs or is called any more'
  item_do item-quota-on quota 1
  grep -Fq /var/lib/vps-stable-opt/login-hook /etc/pam.d/common-session || fail 'the login record is not on before the uninstall'
  systemctl is-active -q vps-stable-check.timer || fail 'the check timer does not run before the uninstall'
  drive uninstall.rules uninstall sudo vps uninstall || fail "uninstall exited with $?"
  if command -v vps > /dev/null; then fail 'vps command left after uninstall'; fi
  if grep -Fq login-hook /etc/pam.d/common-session; then fail 'common-session still calls the login hook of the removed tool'; fi
  for f in /usr/share/pam-configs/vps-stable-login /etc/profile.d/zz-vps-stable-login.sh /etc/systemd/system/vps-stable-check.timer \
      /etc/systemd/system/vps-stable-check.service /var/lib/vps-stable-opt /var/backups/vps-stable-opt /usr/local/lib/vps-stable-opt; do
    if sudo test -e "$f"; then fail "$f left after uninstall"; fi
  done
  if systemctl is-active -q vps-stable-check.timer; then fail 'the check timer still runs after uninstall'; fi
  # A login session goes through common-session (root needs no password for su).
  sudo su -l "$(id -un)" -c true || fail 'a login session fails after the uninstall'
  # The optimizations themselves stay.
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'BBR went with the uninstall'
  [[ "$(ufw_line)" == 'Status: active' ]] || fail 'the firewall went with the uninstall'
  systemctl is-active -q fail2ban || fail 'Fail2ban stopped with the uninstall'
  [[ -e /etc/sysctl.d/98-vps-stable-hardening.conf ]] || fail 'the security parameters went with the uninstall'
  endgroup
  group 'Installed again and set up again over the kept settings'
  sudo bash "$ROOT/install.sh" --local-file "$ROOT/vps-stable-opt.sh" --no-run
  [[ "$(sudo vps --version)" == "$version" ]] || fail 'the second install is not this version'
  drive setup-custom.rules setup-again sudo vps setup || fail "setup again exited with $?"
  has setup-again '本次流程已完成'
  rc=0; drive check.rules check-again sudo vps check || rc=$?
  cat "$LOGS/check-again.log"
  [[ "$rc" == 0 || "$rc" == 3 ]] || fail "check after the setup again exited with $rc"
  # Its own earlier files with exactly its text are taken up again; without the
  # records it cannot tell the others (TCP buffers) from an administrator's.
  for item in 'BBR 网络优化' '内核网络安全参数' '常用工具' '防火墙' 'Fail2ban 防爆破' '自动安全更新' '登录记录和提醒'; do passed check-again "$item"; done
  has check-again '封禁 192.0.2.123：UFW 中出现了对应的拦截规则'
  has check-again '解封 192.0.2.123：拦截规则已删除'
  grep -Fq /var/lib/vps-stable-opt/login-hook /etc/pam.d/common-session || fail 'the login record is not on again'
  (($(tcp_rmem_max) > before_tcp_rmem)) || fail 'the TCP buffers are not raised any more'
  [[ "$(tz)" == Asia/Shanghai ]] || fail "timezone: $(tz)"
  endgroup
  # shellcheck disable=SC2119
  no_tool_errors
  printf 'PASS: real run (keep) on %s: uninstalled with the settings kept, nothing left running, installed and set up again.\n' \
    "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
  exit 0
fi
if [[ "$mode" == alt ]]; then
  group 'Acceptance check: what was declined stayed as it was'
  rc=0; drive check.rules check sudo vps check || rc=$?
  cat "$LOGS/check.log"
  [[ "$rc" == 0 || "$rc" == 3 ]] || fail "check exited with $rc"
  for item in '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区' '自动安全更新'; do
    grep -Eq "^○ 未处理[[:space:]]+$item：" "$LOGS/check.log" || fail "declined $item is not reported as left alone"
  done
  passed check '防火墙'
  passed check 'Fail2ban 防爆破'
  check_facts check
  [[ "$(sysctl -n kernel.kptr_restrict)" == "$before_kptr" ]] || fail 'declined security parameters changed kptr_restrict'
  [[ "$(sysctl -n net.core.rmem_max)" == "$before_rmem" && "$(tcp_rmem_max)" == "$before_tcp_rmem" ]] || fail 'declined TCP buffers changed'
  [[ "$(tz)" == "$before_tz" ]] || fail "the kept timezone changed: $(tz)"
  [[ "$(tool_packages)" == "$before_tools" ]] || fail "declined tools were installed: $(tool_packages)"
  if installed vnstat; then fail 'declined vnStat was installed'; fi
  for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-tcp.conf \
      /etc/apt/apt.conf.d/52-vps-stable-auto-upgrades /etc/apt/apt.conf.d/53-vps-stable-auto-reboot; do
    if sudo test -e "$f"; then fail "$f written although declined"; fi
  done
  ufw_added > "$LOGS/ufw-added.log"
  cat "$LOGS/ufw-added.log"
  grep -Fxq 'ufw allow 80/tcp' "$LOGS/ufw-added.log" || fail 'website port 80 not opened'
  grep -Fxq 'ufw allow 443/tcp' "$LOGS/ufw-added.log" || fail 'website port 443 not opened'
  if grep -q '^ufw allow from ' "$LOGS/ufw-added.log"; then fail 'an allowlist rule although the allowlist was declined'; fi
  endgroup
else
if [[ "$mode" == upgrade ]] && grep -q 'Could not get lock' "$LOGS/setup-old.log"; then
  # The previous release waited only 120 seconds for the package lock that the
  # automatic update it had just started still held: this version finishes
  # what that left undone (Fail2ban needs the package).
  group "Fail2ban again, by $version (the previous release lost the package lock)"
  item_do item-fail2ban-after-upgrade fail2ban 1
  endgroup
fi
group 'Acceptance check'
check_all check
# The previous release kept a policy with only Update-Package-Lists as it was.
if [[ "$mode" != upgrade ]]; then passed check '自动安全更新'; fi
apt_readable 'after the setup'
check_facts check
endgroup

group 'Single items: each switched off (back to how the system was) and on again'
item_do item-bbr-off bbr 2
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "$before_cc" ]] || fail 'BBR off: congestion control not back'
item_do item-bbr-on bbr 1
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'BBR on: not bbr'

item_do item-sysctl-off sysctl 2
[[ ! -e /etc/sysctl.d/98-vps-stable-hardening.conf ]] || fail 'security parameters off: file left'
[[ "$(sysctl -n kernel.kptr_restrict)" == "$before_kptr" ]] || fail 'security parameters off: kptr_restrict not back'
item_do item-sysctl-on sysctl 1
[[ -e /etc/sysctl.d/98-vps-stable-hardening.conf ]] || fail 'security parameters on: no file'

item_do item-tcp-off tcp 2
[[ ! -e /etc/sysctl.d/99-vps-stable-tcp.conf ]] || fail 'TCP buffers off: file left'
[[ "$(sysctl -n net.core.rmem_max)" == "$before_rmem" ]] || fail 'TCP buffers off: rmem_max not back'
[[ "$(tcp_rmem_max)" == "$before_tcp_rmem" ]] || fail 'TCP buffers off: tcp_rmem not back'
item_do item-tcp-on tcp 1
# The limit TCP uses; net.core.rmem_max stays as it is when another file sets it.
(($(tcp_rmem_max) > before_tcp_rmem)) || fail "TCP buffers on: tcp_rmem not raised ($(tcp_rmem_max))"

item_do item-journal-off journal 2
[[ ! -e /etc/systemd/journald.conf.d/99-vps-stable.conf ]] || fail 'journal limit off: file left'
journal_since="$(date '+%F %T')"
item_do item-journal-on journal 1
[[ -e /etc/systemd/journald.conf.d/99-vps-stable.conf ]] || fail 'journal limit on: no file'
# What journald uses, as it says when it starts: "System Journal (...) is X, max 100.0M, ..."
# (or the runtime journal's half, where nothing is kept on disk).
# shellcheck disable=SC2024
sudo journalctl -q --since "$journal_since" -t systemd-journald -o cat --no-pager > "$LOGS/journald-limit.log" 2>&1 || true
grep -Eq '^(System Journal .* max 100(\.0)?M|Runtime Journal .* max 50(\.0)?M)' "$LOGS/journald-limit.log" ||
  fail "journal limit on: journald does not use 100 MiB: $(tail -n 5 "$LOGS/journald-limit.log" | tr '\n' ' ')"

item_do item-trim-off trim 2
[[ "$(systemctl is-enabled fstrim.timer 2>/dev/null || true)" == "$before_trim" ]] || fail 'TRIM off: timer not back'
item_do item-trim-on trim 1
[[ "$(systemctl is-enabled fstrim.timer 2>/dev/null || true)" == enabled ]] || fail 'TRIM on: timer not enabled'

item_do item-autoreboot-off autoreboot 2
now=0; if apt_has 'Unattended-Upgrade::Automatic-Reboot "true";'; then now=1; fi
[[ "$now" == "$before_reboot" ]] || fail 'automatic reboot off: not back'
item_do item-autoreboot-on autoreboot 1
apt_has 'Unattended-Upgrade::Automatic-Reboot "true";' || fail 'automatic reboot on: not on'
apt_has 'Unattended-Upgrade::Automatic-Reboot-Time "04:30";' || fail 'automatic reboot on: time is not 04:30'

item_do item-updates-off updates 2
now=0; if apt_has 'APT::Periodic::Unattended-Upgrade "1";'; then now=1; fi
[[ "$now" == "$before_updates" ]] || fail 'automatic updates off: not back'
[[ "$(sudo apt-config dump 2>/dev/null | grep '^APT::Periodic::' || true)" == "$before_periodic" ]] ||
  fail 'automatic updates off: the periodic policy is not as it was'
item_do item-updates-on updates 1
apt_views 'after automatic updates on'
# GitHub's images set only Update-Package-Lists "1": the tool fills in the
# missing key. A value other than "1" would be kept (see extras-tests.sh).
if grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) ' <<< "$before_periodic" | grep -vF ' "1";' > /dev/null; then
  fail "this image sets its own periodic policy ($(tr '\n' ' ' <<< "$before_periodic")): the test expects none other than \"1\""
fi
apt_has 'APT::Periodic::Update-Package-Lists "1";' || fail 'automatic updates on: package lists are not updated daily'
apt_has 'APT::Periodic::Unattended-Upgrade "1";' || fail 'automatic updates on: security updates are not installed daily'
systemctl is-active -q apt-daily-upgrade.timer || fail 'automatic updates on: apt-daily-upgrade.timer is not running'
# Off may have purged unattended-upgrades and on reinstalled it: its scripts
# wrote 20auto-upgrades again.
apt_readable 'automatic updates on'

item_do item-timezone-off timezone 2
[[ "$(tz)" == "$before_tz" ]] || fail "timezone back: $(tz)"
item_do item-timezone-on timezone 1
[[ "$(tz)" == Asia/Shanghai ]] || fail "timezone set: $(tz)"

# Disk swap by hand (these runners may have a swap already: it is asked).
if [[ -e /swapfile ]]; then
  printf '::notice::%s\n' 'disk swap item not tested here: /swapfile exists before the tool'
else
  item_do item-swap-on swap 1
  awk '$1 == "/swapfile" && $5 == 10 {f = 1} END {exit !f}' /proc/swaps || fail "disk swap on: not in use with priority 10: $(cat /proc/swaps)"
  systemctl is-enabled -q swapfile.swap || fail 'disk swap on: not enabled at boot'
  item_do item-swap-off swap 2
  if grep -q '^/swapfile ' /proc/swaps || [[ -e /swapfile || -e /etc/systemd/system/swapfile.swap ]]; then fail 'disk swap off: still there'; fi
fi

# Connection tracking (loaded by the firewall): only raised, to 64 entries a
# MiB of RAM between 16384 and 1048576; off puts the kernel's value back.
ct_max() { sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null; }
if ct_before="$(ct_max)"; then
  ct_want=$(($(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo) * 64))
  ((ct_want >= 16384)) || ct_want=16384; ((ct_want <= 1048576)) || ct_want=1048576
  ((ct_want > ct_before)) || ct_want="$ct_before"
  item_do item-conntrack-on conntrack 1
  [[ "$(ct_max)" == "$ct_want" ]] || fail "connection tracking on: nf_conntrack_max is $(ct_max), not $ct_want"
  if ((ct_want > ct_before)); then
    sudo grep -Fxq nf_conntrack /etc/modules-load.d/99-vps-stable-conntrack.conf || fail 'connection tracking on: the module is not loaded at boot'
  fi
  item_do item-conntrack-off conntrack 2
  [[ "$(ct_max)" == "$ct_before" ]] || fail "connection tracking off: nf_conntrack_max is $(ct_max), was $ct_before"
  for f in /etc/sysctl.d/99-vps-stable-conntrack.conf /etc/modules-load.d/99-vps-stable-conntrack.conf; do
    if sudo test -e "$f"; then fail "connection tracking off: $f left"; fi
  done
  # Left on: the full rollback must put it back as well.
  item_do item-conntrack-on-again conntrack 1
else
  printf '::notice::%s\n' 'connection tracking not tested here: nf_conntrack is not loaded'
fi

# Not answering ping, left on for the rollback.
before_ping="$(sysctl -n net.ipv4.icmp_echo_ignore_all)"
item_do item-ping-on ping 1
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]] || fail 'ping off: echo still answered'
item_do item-ping-off ping 2
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == "$before_ping" ]] || fail 'ping back: not as it was'
if sudo test -e /etc/sysctl.d/99-vps-stable-noping.conf; then fail 'ping back: file left'; fi
if sudo test -e /etc/systemd/system/ufw.service.d/99-vps-stable-noping.conf; then fail 'ping back: the UFW drop-in left'; fi
item_do item-ping-on-again ping 1
# UFW applies its own sysctl.conf whenever it starts, and the stock one answers
# ping (net/ipv4/icmp_echo_ignore_all=0): on a real Debian 13 VPS ping was
# answered again after every reboot, which no run here had covered. Started
# as at boot, it must stay off.
[[ "$(ufw_line)" == 'Status: active' ]] || fail "the firewall is not on for the ping check: $(ufw_line)"
sudo systemctl restart ufw.service
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]] || fail 'ping answered again after ufw.service started (as at boot)'

# Preferring IPv4 (/etc/gai.conf): the line in, then the file exactly as it
# was; left on for the rollback.
gai_before=''
if [[ -e /etc/gai.conf ]]; then gai_before="$LOGS/gai.conf.before"; cp -- /etc/gai.conf "$gai_before"; fi
item_do item-ipv4-on ipv4 1
grep -Fxq 'precedence ::ffff:0:0/96  100' /etc/gai.conf || fail "IPv4 first on: not in /etc/gai.conf: $(grep -v '^#' /etc/gai.conf | tr '\n' ' ')"
item_do item-ipv4-off ipv4 2
if [[ -n "$gai_before" ]]; then cmp -s /etc/gai.conf "$gai_before" || fail 'IPv4 first off: /etc/gai.conf is not as it was'
elif [[ -e /etc/gai.conf ]]; then fail 'IPv4 first off: /etc/gai.conf left'; fi
item_do item-ipv4-on-again ipv4 1

# SSH keepalive, where the runner has an SSH server: what sshd itself uses,
# and the image's own interval kept without a file of this tool.
if sudo test -x /usr/sbin/sshd; then
  item_do item-keepalive-off keepalive 2
  if sudo test -e /etc/ssh/sshd_config.d/00-vps-stable-keepalive.conf; then fail 'SSH keepalive off: file left'; fi
  item_do item-keepalive-on keepalive 1
  sudo /usr/sbin/sshd -T 2>/dev/null | grep -Fx "clientaliveinterval ${ka_kept:-60}" > /dev/null ||
    fail "SSH keepalive on: sshd uses $(sudo /usr/sbin/sshd -T 2>/dev/null | grep '^clientaliveinterval' || echo nothing), not ${ka_kept:-60}"
  if [[ -n "$ka_kept" ]]; then
    if sudo test -e /etc/ssh/sshd_config.d/00-vps-stable-keepalive.conf; then fail "SSH keepalive on: a file of this tool next to the image's $ka_kept seconds"; fi
    has item-keepalive-on "SSH 已经有保活设置（每 $ka_kept 秒），保持不变。"
  fi
else
  printf '::notice::%s\n' 'SSH keepalive not tested here: no SSH server on this runner'
fi

# Login record: nobody logs in to a runner over SSH, so the hook is run the
# way PAM runs it when a session opens (vm-run has real logins).
item_do item-login-on login 1
grep -Fq /var/lib/vps-stable-opt/login-hook /etc/pam.d/common-session || fail 'login record on: not in common-session'
# shellcheck disable=SC2024
sudo env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin PAM_TYPE=open_session PAM_SERVICE=sshd PAM_USER=runner PAM_RHOST=192.0.2.7 PAM_TTY=/dev/pts/9 \
  /usr/bin/timeout 3 /bin/bash /var/lib/vps-stable-opt/login-hook || fail "the login hook exited with $?"
# The note is the account's own file, which its login shell shows.
[[ -O /run/vps-stable-login/runner ]] || fail "the note does not belong to the account: $(ls -l /run/vps-stable-login 2>&1)"
cat /run/vps-stable-login/runner > "$LOGS/login-note.log"
cat "$LOGS/login-note.log"
has login-note '这是第一次从 192.0.2.7 登录'
sudo tail -n 1 /var/lib/vps-stable-opt/logins | grep -q $'\trunner\t192.0.2.7\tunknown\tssh\t1$' || fail "login record: $(sudo tail -n 1 /var/lib/vps-stable-opt/logins)"
item_do item-login-off login 2
if grep -Fq login-hook /etc/pam.d/common-session; then fail 'login record off: still in common-session'; fi
# Left on: the full rollback takes it out as well.
item_do item-login-on-again login 1

# TG notifications against a stand-in for the Bot API on 127.0.0.1: the test
# message, then a sudo and a login reach it; the check leaves nothing in the
# journal although it runs every minute.
export TG_TOKEN='123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq'
# Its output goes to a file of its own: report.sh reads this script through a
# pipe and would wait for anything left holding it (a stand-in still running
# after a failed check kept a whole job waiting until its time limit).
python3 "$CI/fake-tg.py" "$LOGS/tg-sent.log" 8443 > "$LOGS/fake-tg.out" 2>&1 < /dev/null &
tg_pid=$!
trap 'kill "$tg_pid" 2>/dev/null || true' EXIT
sleep 1
index="$(item_index notify)" || fail 'no single item notify'
{ printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> @seq 1\n' "$index"; cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/item-notify-on.rules"
drive "$LOGS/item-notify-on.rules" item-notify-on sudo VPS_TG_API=http://127.0.0.1:8443 vps item || fail "TG on exited with $?"
if ! grep -Fq 'TG 通知已开启' "$LOGS/tg-sent.log" || ! grep -Fxq 'chat=424242' "$LOGS/tg-sent.log"; then fail "no test message: $(cat "$LOGS/tg-sent.log" 2>&1)"; fi
[[ "$(sudo stat -c %a /var/lib/vps-stable-opt/notify.conf)" == 600 ]] || fail 'the TG settings are readable by others'
systemctl is-active -q vps-stable-check.timer || fail 'the check timer is not running'
grep -Fxq 'OnCalendar=*:0/1' /etc/systemd/system/vps-stable-check.timer || fail 'the check does not run every minute with TG'
check_started="$(date '+%F %T')"
sudo systemctl start vps-stable-check.service
sudo rm -f /var/lib/vps-stable-opt/notify/five
sudo true
sudo env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin PAM_TYPE=open_session PAM_SERVICE=sshd PAM_USER=runner PAM_RHOST=192.0.2.8 PAM_TTY=/dev/pts/9 \
  /usr/bin/timeout 3 /bin/bash /var/lib/vps-stable-opt/login-hook || fail "the login hook exited with $?"
sudo systemctl start vps-stable-check.service
cat "$LOGS/tg-sent.log"
grep -Fq 'sudo：runner 运行了 /usr/bin/true' "$LOGS/tg-sent.log" || fail 'a sudo did not reach TG'
grep -Fq '登录：runner 来自 192.0.2.8' "$LOGS/tg-sent.log" || fail 'a login did not reach TG'
# As root: the CI user may not read the system journal (an empty answer then proves nothing).
# shellcheck disable=SC2024
sudo journalctl -u vps-stable-check.service --since "$check_started" --no-pager -q > "$LOGS/check-journal.log" 2>&1 || true
sudo journalctl --since "$check_started" --no-pager -q -n 1 > /dev/null || fail 'the journal cannot be read'
if [[ -s "$LOGS/check-journal.log" ]]; then
  cat "$LOGS/check-journal.log"; fail 'the check writes to the journal every time it runs'
fi
item_do item-notify-off notify 2
if sudo test -e /var/lib/vps-stable-opt/notify.conf || [[ -e /etc/systemd/system/vps-stable-check.timer ]]; then fail 'TG off: the settings or the timer stayed'; fi
kill "$tg_pid" 2>/dev/null || true
trap - EXIT

# The traffic alert: every 5 minutes; left on for the rollback. 1000 GB are
# 1000000 MB (decimal, as traffic is billed), and 5 GB used already.
item_do item-quota-on quota 1
if ! sudo grep -Fxq 'quota_mb=1000000' /var/lib/vps-stable-opt/quota.conf || ! sudo grep -Fxq 'mode=both' /var/lib/vps-stable-opt/quota.conf ||
   ! sudo grep -Fxq 'used_mb=5000' /var/lib/vps-stable-opt/quota.conf; then
  fail "traffic alert settings: $(sudo cat /var/lib/vps-stable-opt/quota.conf 2>&1)"
fi
grep -Fxq 'OnCalendar=*:0/5' /etc/systemd/system/vps-stable-check.timer || fail 'the traffic alert alone does not run every 5 minutes'
# What it counts is what the kernel counts for that network card, in and out:
# its counters (read between the test's own reads around each check), exactly
# what they grew by, and that as MB of 10^6 bytes on top of the 5000 MB; and a
# 30 MB download is in it. (The download must be checked itself: the image URL
# answers with a redirect, which curl without -L takes as success with 367
# bytes; that once looked like counters missing the traffic.) A check of the
# timer at the same moment makes ours skip, so it runs until the count is newer.
iface="$(sudo sed -n 's/^iface=//p' /var/lib/vps-stable-opt/quota.conf)"
nic() { awk -v i="$iface:" '$1 == i {print $2, $10}' /proc/net/dev; }
tool_traffic() { sudo cat /var/lib/vps-stable-opt/notify/traffic; }
check_now() {
  local since i
  sleep 1; since="$(date +%s)"
  for ((i = 0; i < 5; i++)); do
    sudo systemctl start vps-stable-check.service
    (($(sudo stat -c %Y /var/lib/vps-stable-opt/notify/traffic 2>/dev/null || echo 0) >= since)) && return 0
    sleep 2
  done
  fail 'the traffic check did not run'
}
check_now
read -r _ rx1 tx1 arx1 atx1 < <(tool_traffic)
read -r krx0 ktx0 < <(nic)
got_bytes="$(curl -fsSL --max-time 180 --max-filesize 40000000 -r 0-29999999 -o /dev/null -w '%{size_download}' \
  https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img)" || fail 'the test download failed'
[[ "$got_bytes" == 30000000 ]] || fail "the test download brought $got_bytes bytes, not 30000000"
read -r krx1 ktx1 < <(nic)
check_now
read -r _ rx2 tx2 arx2 atx2 < <(tool_traffic)
read -r krx2 ktx2 < <(nic)
shown="$(sudo cat /var/lib/vps-stable-opt/notify/traffic-used)"
{ printf 'kernel %s before the first check, then %s/%s; tool %s/%s, added %s/%s\n' "$iface" "$krx0" "$ktx0" "$rx1" "$tx1" "$arx1" "$atx1"
  printf 'kernel before the second check %s/%s, after %s/%s; tool %s/%s, added %s/%s; shown %s MB\n' "$krx1" "$ktx1" "$krx2" "$ktx2" "$rx2" "$tx2" "$arx2" "$atx2" "$shown"
  cat /proc/net/dev
} > "$LOGS/traffic-diagnosis.txt" 2>&1
notice "traffic count ($mode, $(uname -m))" "$LOGS/traffic-diagnosis.txt"
traffic_problem=''
for v in "$rx1" "$tx1" "$arx1" "$atx1" "$rx2" "$tx2" "$arx2" "$atx2" "$krx0" "$ktx0" "$krx1" "$ktx1" "$krx2" "$ktx2" "$shown"; do
  [[ "$v" =~ ^[0-9]+$ ]] || traffic_problem='a traffic count could not be read (see the traffic count notice)'
done
if [[ -n "$traffic_problem" ]]; then :
elif ! ((rx1 <= krx0 && krx1 <= rx2 && rx2 <= krx2 && tx1 <= ktx0 && ktx1 <= tx2 && tx2 <= ktx2)); then
  traffic_problem="the traffic alert did not read the kernel's counters of $iface (see the traffic count notice)"
elif ((rx2 - rx1 < 30000000)); then traffic_problem="$iface received $((rx2 - rx1)) bytes between the checks, less than the 30 MB downloaded"
elif ((arx2 - arx1 != rx2 - rx1 || atx2 - atx1 != tx2 - tx1)); then
  traffic_problem="the traffic alert added $((arx2 - arx1))/$((atx2 - atx1)) bytes, the counters grew by $((rx2 - rx1))/$((tx2 - tx1))"
elif ((shown != (arx2 + atx2) / 1000000 + 5000)); then
  traffic_problem="the traffic alert shows $shown MB for $((arx2 + atx2)) bytes and 5000 MB used already"
fi
if [[ -n "$traffic_problem" ]]; then printf '::error::%s\n' "$traffic_problem"; fi

# Docker's log limit, where the runner has Docker: the rest of daemon.json kept,
# and back exactly as it was when turned off.
if command -v dockerd > /dev/null; then
  dj_before=()
  if sudo test -e /etc/docker/daemon.json; then sudo cp /etc/docker/daemon.json "$LOGS/daemon.json.before"; dj_before=("$LOGS/daemon.json.before"); fi
  item_do item-dockerlog-on dockerlog 1
  sudo python3 -c 'import json, sys
d = json.load(open("/etc/docker/daemon.json"))
assert d["log-opts"] == {"max-size": "10m", "max-file": "3"} and d["log-driver"] == "json-file", d
before = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
assert all(d[k] == v for k, v in before.items() if not k.startswith("log-")), (before, d)' "${dj_before[@]}" ||
    fail "daemon.json: $(sudo cat /etc/docker/daemon.json)"
  item_do item-dockerlog-off dockerlog 2
  if [[ -e "$LOGS/daemon.json.before" ]]; then sudo cmp -s /etc/docker/daemon.json "$LOGS/daemon.json.before" || fail 'Docker log limit off: daemon.json not as it was'
  elif sudo test -e /etc/docker/daemon.json; then fail 'Docker log limit off: daemon.json left'; fi
fi

item_do item-vnstat-off vnstat 2
if installed vnstat; then fail 'vnStat off: still installed'; fi
item_do item-vnstat-on vnstat 1
systemctl is-active -q vnstat || fail 'vnStat on: not running'

item_do item-tools-off tools 2
[[ "$(tool_packages)" == "$before_tools" ]] || fail "tools off: $(tool_packages)(was $before_tools)"
item_do item-tools-on tools 1
[[ "$(tool_packages)" == 'curl wget ca-certificates vim htop unzip lsof tmux ' ]] || fail "tools on: $(tool_packages)"

item_do item-fail2ban-off fail2ban 2
# jail.d is root-only on some releases (Ubuntu 26.04).
if sudo test -e /etc/fail2ban/jail.d/99-vps-stable-sshd.local; then fail 'Fail2ban off: jail left'; fi
item_do item-firewall-off firewall 3
[[ "$(ufw_line)" == "$before_ufw" ]] || fail "firewall off: $(ufw_line)"
# Not answering ping is still on: neither UFW's values from before it was
# turned on nor its sysctl.conf at the start again may take that back.
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]] || fail 'firewall off: ping answered again (that item is still on)'
item_do item-firewall-on firewall 1
[[ "$(ufw_line)" == 'Status: active' ]] || fail 'firewall on: not active'
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]] || fail 'firewall on: ping answered again (that item is still on)'
item_do item-fail2ban-on fail2ban 1
sudo test -e /etc/fail2ban/jail.d/99-vps-stable-sshd.local || fail 'Fail2ban on: no jail'
systemctl is-active -q fail2ban || fail 'Fail2ban on: not running'
endgroup

group 'Parameters: the TCP cap recommended, adjusted, exported, reset and imported'
# The recommendation, worked out here from the RAM (16 MiB below 1 GiB, 32
# below 4 GiB, 64 above), must be what the tool shows and what the kernel has.
mem_mib="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
want=64; if ((mem_mib < 4096)); then want=32; fi; if ((mem_mib < 1024)); then want=16; fi
# The transcript belongs to the CI user; only the tool runs as root.
# shellcheck disable=SC2024
sudo vps params > "$LOGS/params.log" 2>&1 || fail 'vps params failed'
cat "$LOGS/params.log"
has params "现在用 $want MiB（自动）· 本机推荐 $want MiB"
[[ "$(tcp_rmem_max)" == $((want * 1048576)) ]] || fail "tcp_rmem is $(tcp_rmem_max), not the recommended $want MiB"
# Adjusted from the single item (item.rules answers 40).
item_do item-tcp-adjust tcp 3
[[ "$(tcp_rmem_max)" == $((40 * 1048576)) ]] || fail "adjusted to 40 MiB: tcp_rmem is $(tcp_rmem_max)"
sudo grep -Fxq 'tcp_buffer_mib=40' /var/lib/vps-stable-opt/params || fail 'the adjusted value is not stored'
# shellcheck disable=SC2024
sudo vps params export > "$LOGS/params-export.txt" || fail 'vps params export failed'
grep -Fxq 'tcp_buffer_mib=40' "$LOGS/params-export.txt" || fail "export: $(cat "$LOGS/params-export.txt")"
# Back to the recommendation from the single item.
item_do item-tcp-reset tcp 4
[[ "$(tcp_rmem_max)" == $((want * 1048576)) ]] || fail "reset: tcp_rmem is $(tcp_rmem_max), not $want MiB"
if sudo grep -q tcp_buffer_mib /var/lib/vps-stable-opt/params; then fail 'reset left a stored value'; fi
# Imported from the exported file, and applied to the item that is on.
drive params.rules params-import sudo vps params import "$LOGS/params-export.txt" || fail "params import exited with $?"
[[ "$(tcp_rmem_max)" == $((40 * 1048576)) ]] || fail "import: tcp_rmem is $(tcp_rmem_max), not 40 MiB"
item_do item-tcp-reset-again tcp 4
[[ "$(tcp_rmem_max)" == $((want * 1048576)) ]] || fail "second reset: tcp_rmem is $(tcp_rmem_max)"
endgroup

group 'Port management'
# Through the menu: open TCP 8080 for everyone, then leave.
item_do item-ports ports 1 0
ufw_added > "$LOGS/ufw-added.log"
grep -Fxq 'ufw allow 8080/tcp' "$LOGS/ufw-added.log" || fail 'port 8080/tcp not opened from the menu'
# From the command line: a range for one address only, then both closed again.
drive port.rules port-open sudo vps port open 9000-9100 tcp from 203.0.113.5 || fail "port open exited with $?"
ufw_added > "$LOGS/ufw-added.log"
grep -Fxq 'ufw allow from 203.0.113.5 to any port 9000:9100 proto tcp' "$LOGS/ufw-added.log" || fail 'restricted range not opened'
drive port.rules port-close-1 sudo vps port close 8080 tcp || fail "port close exited with $?"
drive port.rules port-close-2 sudo vps port close 9000-9100 tcp || fail "port close exited with $?"
ufw_added > "$LOGS/ufw-added.log"
cat "$LOGS/ufw-added.log"
if grep -Eq '8080|9000:9100' "$LOGS/ufw-added.log"; then fail 'a closed port is still open'; fi
endgroup

group 'Acceptance check after the single items'
check_all check-again
passed check-again '自动安全更新'
apt_readable 'after the single items'
# Colours are for the screen: the tool's logs and saved reports are plain text.
coloured="$(sudo grep -rlF $'\x1b[' /var/lib/vps-stable-opt/logs 2>/dev/null || true)"
[[ -z "$coloured" ]] || fail "colour codes in the tool's logs or reports: $(tr '\n' ' ' <<< "$coloured")"
sudo ls /var/lib/vps-stable-opt/logs | grep '^verify-' > /dev/null || fail 'no saved acceptance report to look at'
# The read-only reports: they finish and say what they found.
# shellcheck disable=SC2024
sudo vps perf > "$LOGS/perf.log" 2>&1 || fail "vps perf exited with $?"
cat "$LOGS/perf.log"
has perf 'CPU 被抢'
has perf '系统盘'
grep -Eq '都正常|项要留意' "$LOGS/perf.log" || fail 'vps perf: no summary'
# shellcheck disable=SC2024
sudo vps resources > "$LOGS/resources.log" 2>&1 || fail "vps resources exited with $?"
cat "$LOGS/resources.log"
has resources 'Fail2ban：内存'
has resources '防火墙里的封禁规则'
# The security audit, without a terminal (no deep check, nothing marked): all
# six parts and the conclusion; a runner image is full of programs of its own,
# so what it finds is not judged here (vm-run does that on clean images).
# shellcheck disable=SC2024
sudo vps audit > "$LOGS/audit.log" 2>&1 || fail "vps audit exited with $?"
cat "$LOGS/audit.log"
for part in 一、谁登录过 二、账户和公钥 三、装过什么 四、正在运行什么 五、开机自启和定时任务 六、系统文件有没有被换过 '结论：' '局限：'; do has audit "$part"; done
sudo ls /var/lib/vps-stable-opt/logs | grep '^audit-' > /dev/null || fail 'no saved audit report'
sudo find /etc -xdev -type f -newer "$run_marker" ! -perm -o=r -printf '%m %u:%g %p\n' 2>/dev/null | sort > "$LOGS/root-only.txt" || true
if [[ -s "$LOGS/root-only.txt" ]]; then notice "files under /etc only root can read, written during the run ($mode, $(uname -m))" "$LOGS/root-only.txt"; fi
endgroup
fi

group 'Full rollback with package removal'
drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
[[ "$(state)" == "$before_state" ]] || fail "kernel settings not restored: $(state) (was $before_state)"
[[ "$(tz)" == "$before_tz" ]] || fail "timezone not restored: $(tz)"
[[ "$(ufw_line)" == "$before_ufw" ]] || fail 'firewall not back to how it was'
for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-tcp.conf /etc/sysctl.d/99-vps-stable-bbr.conf \
    /etc/fail2ban/jail.d/99-vps-stable-sshd.local /etc/fail2ban/action.d/vps-stable-ufw-sshd.conf /etc/fail2ban/fail2ban.d/99-vps-stable.local \
    /etc/apt/apt.conf.d/53-vps-stable-auto-reboot \
    /etc/sysctl.d/99-vps-stable-conntrack.conf /etc/sysctl.d/99-vps-stable-noping.conf /etc/systemd/system/ufw.service.d/99-vps-stable-noping.conf \
    /etc/ssh/sshd_config.d/00-vps-stable-keepalive.conf /usr/share/pam-configs/vps-stable-login /etc/profile.d/zz-vps-stable-login.sh \
    /etc/systemd/system/vps-stable-check.timer /etc/systemd/system/vps-stable-check.service; do
  if sudo test -e "$f"; then fail "$f left after rollback"; fi
done
if grep -Fq login-hook /etc/pam.d/common-session; then fail 'the login record is still in common-session after the rollback'; fi
if [[ -n "${ct_before:-}" && -n "$(ct_max)" ]]; then
  [[ "$(ct_max)" == "$ct_before" ]] || fail "connection tracking not restored: $(ct_max) (was $ct_before)"
fi
endgroup

group 'Uninstall'
drive uninstall.rules uninstall sudo vps uninstall || fail "uninstall exited with $?"
if command -v vps >/dev/null; then fail 'vps command left after uninstall'; fi
for d in /usr/local/lib/vps-stable-opt /var/lib/vps-stable-opt /var/backups/vps-stable-opt; do
  [[ ! -e "$d" ]] || fail "$d left after uninstall"
done
endgroup

group 'Nothing left behind: everything compared with before the install'
# shellcheck disable=SC2024
sudo bash "$CI/snapshot.sh" > "$LOGS/snapshot-after.txt"
# shellcheck disable=SC2024
sudo bash "$CI/upgrade-info.sh" "$snapshot_since" > "$LOGS/upgrade-info.txt"
rc=0
# The previous release recorded no package states, so this version only
# removes (never purges) what that one installed; and it handed packages that
# were there already to apt-get install, which marks them installed by hand.
purged=(--purged --marks)
if [[ "$mode" == upgrade ]]; then purged=(); fi
python3 "$CI/snapdiff.py" "$LOGS/snapshot-before.txt" "$LOGS/snapshot-after.txt" --upgrades "$LOGS/upgrade-info.txt" \
  "${purged[@]}" > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
# shellcheck disable=SC2119
no_tool_errors
# Found at the traffic check and kept until here, so that the rest still ran.
[[ -z "${traffic_problem:-}" ]] || fail "$traffic_problem"
printf 'PASS: real run (%s) on %s: install, setup, check, single items, ports, rollback, uninstall.\n' \
  "$mode" "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
