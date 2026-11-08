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

group 'answer.exp: a question no rule knows fails within seconds'
# Not only [y/N]: a number menu or a free answer missing from a rules file
# used to wait out the whole time limit (25 to 50 minutes) before failing.
printf '%s\n' '不会出现的问题 ==> x' > "$LOGS/unknown-question.rules"
rc=0 asked_at=$SECONDS
# shellcheck disable=SC2016
ANSWER_IDLE=5 drive "$LOGS/unknown-question.rules" unknown-question bash -c 'read -r -p "请选择: " answer; echo "answered $answer"' || rc=$?
((rc == 3 && SECONDS - asked_at < 60)) || fail "answer.exp on a question no rule knows: exit $rc after $((SECONDS - asked_at)) s"
endgroup

# How Fail2ban bans: the nftables sets of this version, or (upgraded, until
# Fail2ban is turned on again) the UFW rules of the previous release.
F2B_BANS=nft
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
  # The previous release's launcher is replaced by this one's.
  cmp -s /usr/local/bin/vps <(awk '/^cat > "\$TMP_DIR\/launcher" <</ {f = 1; next} f && /^EOF$/ {exit} f' "$ROOT/install.sh") ||
    fail "the launcher of $old_version was not replaced: $(cat /usr/local/bin/vps)"
  # Its Fail2ban bans stay UFW rules until Fail2ban is turned on again.
  # Up to 2.8 each ban was a UFW rule; from 2.9 on an element of the nftables sets.
  if ! grep -Fq 'table inet vps-stable-f2b' "$LOGS/old-vps-stable-opt.sh"; then F2B_BANS=ufw; fi
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

# Anyone but root is told to use sudo by the launcher (the main script is
# root's only: bash used to say "Permission denied").
rc=0; out="$(vps item 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == 'vps 需要 root 权限：请用 sudo vps item（root 用户直接输入 vps）。' ]] || fail "vps item without sudo: $rc $out"

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
  for item in 'BBR 网络优化' '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区' '防火墙'; do
    passed "$name" "$item"
  done
  f2b_checked "$name"
  [[ "$(tz)" == Asia/Shanghai ]] || fail "$name: timezone is $(tz)"
}
# NAME: the Fail2ban lines of a vps check. With the bans of the previous
# release (F2B_BANS=ufw: upgraded, Fail2ban not turned on again yet) the
# switch to the nftables sets is offered and the live test finds a UFW rule;
# otherwise the check passes and the live test finds the address in the set.
# (F2B_BANS is set before the install; this is defined after it.)
f2b_checked() {
  if [[ "$F2B_BANS" == ufw ]]; then
    grep -Eq '^⚠ 可更新[[:space:]]+Fail2ban 防爆破：封禁还是旧版的做法' "$LOGS/$1.log" || fail "$1: the switch to the nftables sets is not offered"
    has "$1" '封禁 192.0.2.123：UFW 中出现了对应的拦截规则'
  else
    passed "$1" 'Fail2ban 防爆破'
    has "$1" '封禁 192.0.2.123：nftables 封禁集合里出现了这个地址'
  fi
  has "$1" '解封 192.0.2.123：拦截已撤掉，恢复原样'
}
# ADDRESS: in this tool's IPv4 ban set (no -q: under pipefail nft's SIGPIPE
# would fail a match).
in_ban_set() { sudo nft list set inet vps-stable-f2b sshd4 2>/dev/null | grep -Fw -- "$1" > /dev/null; }
# Up to 30 seconds for the jail after a (re)start of Fail2ban.
f2b_wait() {
  local i
  for ((i = 0; i < 30; i++)); do sudo fail2ban-client status sshd > /dev/null 2>&1 && return 0; sleep 1; done
  fail 'the sshd jail did not come back'
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
  for item in 'BBR 网络优化' '内核网络安全参数' '常用工具' '防火墙' '自动安全更新' '登录记录和提醒'; do passed check-again "$item"; done
  f2b_checked check-again
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
  F2B_BANS=nft
  endgroup
fi
group 'Acceptance check'
check_all check
# The previous release kept a policy with only Update-Package-Lists as it was.
if [[ "$mode" != upgrade ]]; then passed check '自动安全更新'; fi
apt_readable 'after the setup'
check_facts check
# A VPN server's tun interface behind UFW, which drops forwarded packets:
# vps check says how to let them through (and says nothing once it is gone).
printf '%s\n' '显示详细状态吗？ ==> n' '做一次 Fail2ban 实弹测试吗？ ==> n' > "$LOGS/check-route.rules"
sudo ip tuntap add dev tun-ci0 mode tun
rc=0; drive "$LOGS/check-route.rules" check-route sudo vps check || rc=$?
sudo ip link delete tun-ci0
[[ "$rc" == 0 || "$rc" == 3 ]] || fail "vps check with a tun interface exited with $rc"
has check-route '转发：这台机器在转发流量（有 tun-ci0 接口）'
has check-route 'ufw route allow in on tun-ci0 out on'
if grep -q 'tun-ci0' "$LOGS/check.log"; then fail 'the forwarding note named an interface that was not there yet'; fi
endgroup

if [[ "$F2B_BANS" == ufw ]]; then
  group "Fail2ban: the UFW bans of $old_version become nftables sets"
  # A ban Fail2ban still runs, and one that ran out while it was down (only
  # UFW has it, as after a hard reboot): the first goes into the set, the
  # second is gone, and so is every UFW rule of the old action.
  sudo fail2ban-client set sshd banip 198.51.100.77 > /dev/null || fail "cannot ban with the action of $old_version"
  sudo ufw prepend deny proto tcp from 198.51.100.78 to any port 22 > /dev/null || fail 'cannot add a left-over ban'
  for ((i = 0; i < 10; i++)); do ufw_added > "$LOGS/ufw-before-nft.log"; grep -F 198.51.100.77 "$LOGS/ufw-before-nft.log" > /dev/null && break; sleep 1; done
  if ! grep -F 198.51.100.77 "$LOGS/ufw-before-nft.log" > /dev/null || ! grep -F 198.51.100.78 "$LOGS/ufw-before-nft.log" > /dev/null; then
    fail "the bans of $old_version are not UFW rules: $(cat "$LOGS/ufw-before-nft.log")"
  fi
  item_do item-fail2ban-nft fail2ban 1
  has item-fail2ban-nft '封禁改为 nftables 集合'
  ufw_added > "$LOGS/ufw-after-nft.log"
  if grep -E '198\.51\.100\.7[78]' "$LOGS/ufw-after-nft.log"; then fail 'UFW rules of the old bans left'; fi
  for ((i = 0; i < 10; i++)); do in_ban_set 198.51.100.77 && break; sleep 1; done
  in_ban_set 198.51.100.77 || fail "the running ban is not in the set: $(sudo nft list table inet vps-stable-f2b 2>&1)"
  if in_ban_set 198.51.100.78; then fail 'the ban that ran out came back'; fi
  sudo fail2ban-client set sshd unbanip 198.51.100.77 > /dev/null || fail 'cannot unban from the set'
  if in_ban_set 198.51.100.77; then fail 'the unbanned address is still in the set'; fi
  F2B_BANS=nft
  check_all check-nft
  endgroup
fi

group 'Fail2ban: what its sets hold without it knowing goes when it starts'
# A ban left in the kernel when Fail2ban did not stop cleanly (killed: no
# unban, no stop action; with the UFW action of the previous release such a
# rule stayed for good): its start makes the table afresh and puts back only
# the bans it runs. Started again by systemd (Restart=on-failure) or here.
sudo nft add element inet vps-stable-f2b sshd4 '{ 198.51.100.79 }' || fail "cannot add to the set: $(sudo nft list ruleset 2>&1 | head -n 20)"
in_ban_set 198.51.100.79 || fail 'the element added by hand is not in the set'
sudo systemctl kill -s KILL fail2ban
sleep 3
sudo systemctl start fail2ban
f2b_wait
# The killed one's table is there until the jail's start action runs.
for ((i = 0; i < 15; i++)); do in_ban_set 198.51.100.79 || break; sleep 1; done
if in_ban_set 198.51.100.79; then fail 'an element Fail2ban does not know stayed in the set over its unclean restart'; fi
# The listing belongs to the CI user; only nft runs as root.
# shellcheck disable=SC2024
sudo nft list chain inet vps-stable-f2b input > "$LOGS/f2b-chain.txt" 2>&1 || fail "no ban chain after the restart: $(cat "$LOGS/f2b-chain.txt")"
cat "$LOGS/f2b-chain.txt"
grep -E 'ct state new tcp dport (22|\{ 22 \}) ip saddr @sshd4 drop' "$LOGS/f2b-chain.txt" > /dev/null || fail 'the chain does not drop new SSH connections from the IPv4 set'
endgroup

group 'Single items: each switched off (back to how the system was) and on again'
# Only looking at the menu leaves no run record or backup behind (only 20 are
# kept, and such sessions used to push out those of real changes); the next
# change keeps one.
runs() { sudo find /var/lib/vps-stable-opt /var/backups/vps-stable-opt -maxdepth 1 -name 'run-*' | wc -l; }
runs_before="$(runs)" latest_before="$(sudo cat /var/lib/vps-stable-opt/latest)"
printf '%s\n' '请选择要修改的项目 ==> 0' > "$LOGS/item-look.rules"
drive "$LOGS/item-look.rules" item-look sudo vps item || fail "looking at the single items exited with $?"
# When it keeps its record: what was newer than its start (the run it kept
# has the mark). The run goes on; the failure comes at the end.
look_problem=''
if ! grep -Fq '这次只是查看，没有改动' "$LOGS/item-look.log" || [[ "$(runs)" != "$runs_before" ]] ||
   [[ "$(sudo cat /var/lib/vps-stable-opt/latest)" != "$latest_before" ]]; then
  look_problem="a session that only looked kept its record: $runs_before -> $(runs) records and backups (see the notice)"
  mark="/var/lib/vps-stable-opt/$(sudo cat /var/lib/vps-stable-opt/latest)/.started"
  { printf 'mark %s\nnow  %s\n' "$(sudo stat -c %y "$mark" 2>&1)" "$(date '+%F %T.%N %z')"
    printf 'dpkg.log %s\n' "$(stat -c %y /var/log/dpkg.log 2>&1)"
    sudo find /etc /var/lib/vps-stable-opt -xdev -newer "$mark" ! -path '/var/lib/vps-stable-opt/run-*' \
      ! -path '/var/lib/vps-stable-opt/logs*' -printf '%TY-%Tm-%Td %TT %y %p\n' 2>&1 | head -n 30
  } > "$LOGS/item-look-why.log" 2>&1 || true
  notice "item-look kept its record ($mode $(uname -m))" "$LOGS/item-look-why.log"
  printf '::error::%s\n' "$look_problem"
fi
item_do item-bbr-off bbr 2
[[ "$(sudo cat /var/lib/vps-stable-opt/latest)" != "$latest_before" ]] || fail 'a session that changed something left no record'
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
    # With 16 GB the kernel's own table is already the largest it makes by
    # itself (262144): nothing to raise here. The small VMs of vm-run check it.
    buckets_set="$(awk '$1 == "net.netfilter.nf_conntrack_buckets" {print $3}' /etc/sysctl.d/99-vps-stable-conntrack.conf)"
    if [[ -n "$buckets_set" && "$(sysctl -n net.netfilter.nf_conntrack_buckets)" != "$buckets_set" ]]; then
      fail "connection tracking on: the kernel has $(sysctl -n net.netfilter.nf_conntrack_buckets) buckets, the file says $buckets_set"
    fi
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
# A run of the check of its own, after what was just done: systemctl start
# joins a run the timer started a moment before instead of starting one (on an
# arm runner the run in progress had read the login record before the hook
# wrote to it: the hook's sudo reached TG, the login did not). So wait until
# none is running first; one the timer starts after that sees it all.
check_run() {
  local i
  for ((i = 0; i < 120; i++)); do
    [[ "$(systemctl show -p ActiveState --value vps-stable-check.service)" == activating ]] || break
    sleep 1
  done
  sudo systemctl start vps-stable-check.service
}
check_run
sudo rm -f /var/lib/vps-stable-opt/notify/five
sudo true
sudo env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin PAM_TYPE=open_session PAM_SERVICE=sshd PAM_USER=runner PAM_RHOST=192.0.2.8 PAM_TTY=/dev/pts/9 \
  /usr/bin/timeout 3 /bin/bash /var/lib/vps-stable-opt/login-hook || fail "the login hook exited with $?"
check_run
cat "$LOGS/tg-sent.log"
grep -Fq 'sudo：runner 运行了 /usr/bin/true' "$LOGS/tg-sent.log" || fail 'a sudo did not reach TG'
grep -Fq '登录：runner 来自 192.0.2.8' "$LOGS/tg-sent.log" || fail 'a login did not reach TG'
# The daily summary as the timer sends it, here with the acceptance check's
# conclusion every day: the service runs vps check for real, within its time.
sudo sh -c "printf 'notify_summary_time=00:00\nnotify_summary_check=always\n' >> /var/lib/vps-stable-opt/params; printf '1999-01-01\n' > /var/lib/vps-stable-opt/notify/summary-date"
summary_at=$SECONDS
check_run
printf 'The check with the daily summary took %s s.\n' "$((SECONDS - summary_at))"
cat "$LOGS/tg-sent.log"
grep -Fq '每日汇总（过去 24 小时）' "$LOGS/tg-sent.log" || fail 'no daily summary reached TG'
grep -Eq '^验收：[0-9]+ 项正常，[0-9]+ 项未生效' "$LOGS/tg-sent.log" || fail 'the daily summary has no conclusion of the acceptance check'
sudo sed -i '/^notify_summary_time=/d; /^notify_summary_check=/d' /var/lib/vps-stable-opt/params
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
item_do item-firewall-off firewall 2
[[ "$(ufw_line)" == "$before_ufw" ]] || fail "firewall off: $(ufw_line)"
# Not answering ping is still on: neither UFW's values from before it was
# turned on nor its sysctl.conf at the start again may take that back.
[[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]] || fail 'firewall off: ping answered again (that item is still on)'
# The bans are Fail2ban's own nftables set: it works with the firewall off.
item_do item-fail2ban-no-firewall fail2ban 1
systemctl is-active -q fail2ban || fail 'Fail2ban with the firewall off: not running'
sudo nft list chain inet vps-stable-f2b input > /dev/null || fail 'Fail2ban with the firewall off: no ban table'
item_do item-fail2ban-off-again fail2ban 2
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
[[ "$(sysctl -n net.ipv4.tcp_notsent_lowat)" == 131072 ]] || fail "the limit of what waits to be sent: $(sysctl -n net.ipv4.tcp_notsent_lowat)"
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

group 'The machine report, and the disk cleanup on what it should and should not take'
# shellcheck disable=SC2024
sudo vps report > "$LOGS/report.log" 2>&1 || fail "vps report exited with $?"
has report '结论'
has report '详细：'
has report '资源占用一览'
sudo sh -c 'printf x > /var/log/vps-ci.log.1; printf x > /var/log/vps-ci-fresh.log.1; printf x > /var/log/wtmp.7; printf x > /var/log/vps-ci.log; touch -d "60 days ago" /var/log/vps-ci.log.1 /var/log/wtmp.7 /var/log/vps-ci.log'
printf '%s\n' '要清理哪几项 ==> a' '确认删除这些旧内核吗？ ==> n' '确认卸载这些不再需要的软件包吗？ ==> n' > "$LOGS/clean.rules"
drive "$LOGS/clean.rules" clean sudo vps clean || fail "vps clean exited with $?"
has clean '清理完了'
if sudo test -e /var/log/vps-ci.log.1; then fail 'the cleanup left an old rotated log'; fi
for f in /var/log/vps-ci-fresh.log.1 /var/log/wtmp.7 /var/log/vps-ci.log; do
  sudo test -e "$f" || fail "the cleanup took $f"
done
sudo rm -f /var/log/vps-ci-fresh.log.1 /var/log/wtmp.7 /var/log/vps-ci.log
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

group 'Data backup: a local directory, then another machine over SFTP, restored for real'
# Small on purpose: a runner's own /home is large.
backup_dir=/var/lib/vps-stable-opt/databackup
backup_tested=1
sudo mkdir -p /srv/ci-data/sub
echo 'precious data' | sudo tee /srv/ci-data/sub/keep.txt > /dev/null
echo 'scratch' | sudo tee /srv/ci-data/skip.tmp > /dev/null
printf '%s\n' 'backup_paths=/srv/ci-data /nonexistent/not-there' 'backup_drill_days=1' > "$LOGS/backup-params.txt"
drive params.rules backup-params sudo vps params import "$LOGS/backup-params.txt" || fail "params import exited with $?"
backup_index="$(item_index databackup)" || fail 'no single item databackup'
# NAME CHOICE RULE...: `vps item`, data backup, CHOICE on its page.
backup_item() {
  local name="$1" choice="$2"
  shift 2
  { printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> %s\n' "$backup_index" "$choice"
    if (($#)); then printf '%s\n' "$@"; fi
    cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/$name.rules"
  drive "$LOGS/$name.rules" "$name" sudo vps item || fail "data backup ($name) exited with $?"
}
# Independently of the tool: restic itself, with the tool's password.
restic_ci() { sudo restic --no-cache --password-file "$backup_dir/password" "$@"; }
backup_last() { sudo cut -f"$1" "$backup_dir/last"; }

# Enter at the password question: one is generated.
backup_item backup-local 1 '备份目标 \[1-4 ==> 4' '备份到本机哪个目录 ==> /var/backups/vps-data-ci' '仍然只备份到本机吗 ==> y' '备份密码（输入时不显示 ==>' '已经把这个密码存到 ==> y'
has backup-local '数据备份已开启'
sudo systemctl is-active vps-stable-backup.timer > /dev/null || fail 'the backup timer is not running'
[[ "$(sudo stat -c %a "$backup_dir")" == 700 && "$(sudo stat -c %a "$backup_dir/password")" == 600 && "$(sudo stat -c %a "$backup_dir/conf")" == 600 ]] || fail 'backup settings readable by others'
# The generated password: on the terminal once, in no file but its own.
pw="$(sudo cat "$backup_dir/password")"
has backup-local "$pw"
if sudo grep -rlF --exclude=password -- "$pw" /var/lib/vps-stable-opt /var/backups/vps-stable-opt | grep .; then fail 'the generated backup password is in a log or backup of the tool'; fi
restic_ci -r /var/backups/vps-data-ci ls latest > "$LOGS/backup-ls.txt" || fail 'restic cannot read what the tool wrote'
grep -Fxq /srv/ci-data/sub/keep.txt "$LOGS/backup-ls.txt" || fail "file not in the backup: $(cat "$LOGS/backup-ls.txt")"
if grep -Fq skip.tmp "$LOGS/backup-ls.txt"; then fail 'an excluded file is in the backup'; fi
if sudo grep -rqF 'precious data' /var/backups/vps-data-ci; then fail 'the backup is not encrypted'; fi

# A file added later is in the next backup; the time follows the parameter.
echo 'added later' | sudo tee /srv/ci-data/later.txt > /dev/null
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-now.log" 2>&1 || fail "vps backup now exited with $?"
has backup-now '备份完成'
restic_ci -r /var/backups/vps-data-ci ls latest | grep -Fx /srv/ci-data/later.txt > /dev/null || fail 'a new file is not in the next backup'
# shellcheck disable=SC2024
sudo vps backup list > "$LOGS/backup-list.log" 2>&1 || fail "vps backup list exited with $?"
has backup-list 'vps-stable'
printf 'backup_time=05:00\n' > "$LOGS/backup-time.txt"
drive params.rules backup-time sudo vps params import "$LOGS/backup-time.txt" || fail "params import exited with $?"
sudo grep -Fxq 'OnCalendar=*-*-* 05:00:00' /etc/systemd/system/vps-stable-backup.timer || fail 'the timer does not follow the parameter'
sudo systemctl is-active vps-stable-backup.timer > /dev/null || fail 'the timer stopped after the change'

# Through the timer's own service, with the restore drill due.
sudo rm -f "$backup_dir/drill-last"
sudo systemctl start vps-stable-backup.service || fail 'the backup service failed'
[[ "$(backup_last 2)" == ok ]] || fail "service: $(sudo cat "$backup_dir/last")"
[[ "$(backup_last 3)" == *恢复演练通过* ]] || fail "no drill: $(sudo cat "$backup_dir/last")"
sudo test -s "$backup_dir/drill-last" || fail 'drill not recorded'
if sudo find /var/tmp -maxdepth 1 -name 'vps-backup-drill.*' | grep .; then fail 'the restored sample was left behind'; fi

# The target gone: said so; back: works again.
sudo mv /var/backups/vps-data-ci /var/backups/vps-data-ci.away
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-broken.log" 2>&1 || fail "vps backup now exited with $?"
has backup-broken '备份没有成功'
[[ "$(backup_last 2)" == fail ]] || fail "a failed backup recorded as $(backup_last 2)"
sudo mv /var/backups/vps-data-ci.away /var/backups/vps-data-ci
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-repaired.log" 2>&1 || fail "vps backup now exited with $?"
has backup-repaired '备份完成'

# Restored for real: to a new directory, the file as it was.
echo 'changed since' | sudo tee /srv/ci-data/sub/keep.txt > /dev/null
backup_item backup-restore 5 '回车返回: ==> 3' '恢复哪一次 ==>' '恢复哪个文件或目录 ==> /srv/ci-data/sub/keep.txt' '恢复到 /root/vps-restore ==> y'
has backup-restore '已恢复到 /root/vps-restore-'
target="$(sudo find /root -maxdepth 1 -name 'vps-restore-*' | awk 'NR == 1')"
[[ "$(sudo cat "$target/srv/ci-data/sub/keep.txt")" == 'precious data' ]] || fail "restored: $(sudo cat "$target/srv/ci-data/sub/keep.txt")"
[[ "$(sudo cat /srv/ci-data/sub/keep.txt)" == 'changed since' ]] || fail 'the restore touched the file in place'
sudo rm -rf -- "$target"

# Another machine: this one, as a user of its own over SFTP. The old password
# stays; the key that logs in is added at the moment the tool asks for it.
sudo useradd -m -s /bin/bash cibackup
sftp_port="$(sudo sshd -T | awk '$1 == "port" && !seen {print $2; seen = 1}')"
printf 'install -d -o cibackup -g cibackup -m 700 /home/cibackup/.ssh\ninstall -o cibackup -g cibackup -m 600 %s/id_ed25519.pub /home/cibackup/.ssh/authorized_keys\n' "$backup_dir" > "$LOGS/backup-add-key.sh"
backup_item backup-sftp 1 '沿用上次的备份目标吗 ==> n' '备份目标 \[1-4 ==> 1' '对方的地址 ==> 127.0.0.1' "对方的 SSH 端口 ==> $sftp_port" '对方的账户名 ==> cibackup' '对方保存备份的目录 ==> backups/ci' '指纹对得上吗 ==> y' "加好了按回车 ==> !!sudo bash $LOGS/backup-add-key.sh"
has backup-sftp '数据备份已开启'
sudo test -f /home/cibackup/backups/ci/config || fail 'no repository on the other machine'
[[ "$(sudo stat -c %U /home/cibackup/backups/ci/config)" == cibackup ]] || fail 'repository not written as that user'
if sudo grep -rqF 'precious data' /home/cibackup/backups; then fail 'the backup is not encrypted on the other machine'; fi
sudo rm -f "$backup_dir/drill-last"
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-sftp-now.log" 2>&1 || fail "vps backup now exited with $?"
has backup-sftp-now '恢复演练通过'
# A host key that changed: refused, not accepted.
ssh-keygen -q -t ed25519 -N '' -f "$LOGS/other-host-key"
sudo cp -- "$backup_dir/known_hosts" "$backup_dir/known_hosts.keep"
sudo awk -v k="$(cut -d' ' -f2 "$LOGS/other-host-key.pub")" '{print $1, "ssh-ed25519", k}' "$backup_dir/known_hosts.keep" | sort -u | sudo tee "$backup_dir/known_hosts" > /dev/null
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-hostkey.log" 2>&1 || fail "vps backup now exited with $?"
has backup-hostkey '备份没有成功'
sudo mv -- "$backup_dir/known_hosts.keep" "$backup_dir/known_hosts"
# shellcheck disable=SC2024
sudo vps backup now > "$LOGS/backup-final.log" 2>&1 || fail "vps backup now exited with $?"
has backup-final '备份完成'
endgroup

group 'Acceptance check after the single items'
check_all check-again
passed check-again '自动安全更新'
passed check-again '数据备份'
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
has resources 'Fail2ban 正在封禁：'
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
    /etc/systemd/system/vps-stable-check.timer /etc/systemd/system/vps-stable-check.service \
    /etc/systemd/system/vps-stable-backup.timer /etc/systemd/system/vps-stable-backup.service; do
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
# The backups stay where they are; then what this run made for them goes.
if [[ -n "${backup_tested:-}" ]]; then
  sudo test -f /var/backups/vps-data-ci/config || fail 'the rollback or uninstall touched the backups'
  sudo test -f /home/cibackup/backups/ci/config || fail 'the rollback or uninstall touched the backups on the other machine'
  sudo rm -rf /var/backups/vps-data-ci /srv/ci-data
  sudo userdel -r cibackup 2>/dev/null || true
fi
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
[[ -z "${look_problem:-}" ]] || fail "$look_problem"
printf 'PASS: real run (%s) on %s: install, setup, check, single items, ports, rollback, uninstall.\n' \
  "$mode" "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
