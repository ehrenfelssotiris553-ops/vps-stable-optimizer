#!/usr/bin/env bash
# CI only, layer 2: the real tool on a throwaway Ubuntu runner. The steps are
# install, plan, one-click setup in custom mode, acceptance check, full
# rollback with package removal, and uninstall. Each step is followed by checks
# on what it must leave behind. Run from anywhere; needs sudo without a password.
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"

state() {
  sysctl -n net.ipv4.tcp_congestion_control net.core.rmem_max net.ipv4.tcp_rmem kernel.kptr_restrict \
    net.ipv4.conf.all.accept_redirects 2>/dev/null | tr -s '\t\n' '  '
}
tz() { timedatectl show -p Timezone --value; }
before_state="$(state)" before_tz="$(tz)"
before_ufw="$(sudo ufw status 2>/dev/null | head -n 1 || true)"
printf 'Before: %s | %s | %s\n' "$before_state" "$before_tz" "${before_ufw:-ufw not installed}"

group 'Install from the checkout'
sudo bash "$ROOT/install.sh" --local-file "$ROOT/vps-stable-opt.sh" --no-run
[[ "$(sudo vps --version)" == "$(sed -n 's/^SCRIPT_VERSION=//p' "$ROOT/vps-stable-opt.sh")" ]] || fail 'installed version differs'
endgroup

group 'Plan (read-only)'
# The transcript belongs to the CI user; only the tool runs as root.
# shellcheck disable=SC2024
sudo vps plan > "$LOGS/plan.log" 2>&1 || fail 'plan failed'
grep -F '根据本次体检，接下来准备怎么做' "$LOGS/plan.log" || fail 'plan has no decision report'
[[ "$(state)" == "$before_state" ]] || fail 'plan changed kernel settings'
endgroup

group 'One-click setup (custom mode)'
drive setup-custom.rules setup sudo vps setup || fail "setup exited with $?"
has setup '本次流程已完成'
endgroup

group 'Acceptance check'
rc=0; drive check.rules check sudo vps check || rc=$?
cat "$LOGS/check.log"
[[ "$rc" == 0 || "$rc" == 3 ]] || fail "check exited with $rc"
for item in 'BBR 网络优化' '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区' '防火墙' 'Fail2ban 防爆破'; do passed check "$item"; done
has check '封禁 192.0.2.123：UFW 中出现了对应的拦截规则'
has check '解封 192.0.2.123：拦截规则已删除'
[[ "$(tz)" == Asia/Shanghai ]] || fail "timezone is $(tz)"
endgroup

group 'Full rollback with package removal'
drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
[[ "$(state)" == "$before_state" ]] || fail "kernel settings not restored: $(state) (was $before_state)"
[[ "$(tz)" == "$before_tz" ]] || fail "timezone not restored: $(tz)"
[[ "$(sudo ufw status 2>/dev/null | head -n 1 || true)" == "$before_ufw" ]] || fail 'firewall not back to how it was'
for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-tcp.conf /etc/sysctl.d/99-vps-stable-bbr.conf \
    /etc/fail2ban/jail.d/99-vps-stable-sshd.local /etc/apt/apt.conf.d/53-vps-stable-auto-reboot; do
  [[ ! -e "$f" ]] || fail "$f left after rollback"
done
endgroup

group 'Uninstall'
drive uninstall.rules uninstall sudo vps uninstall || fail "uninstall exited with $?"
if command -v vps >/dev/null; then fail 'vps command left after uninstall'; fi
for d in /usr/local/lib/vps-stable-opt /var/lib/vps-stable-opt /var/backups/vps-stable-opt; do
  [[ ! -e "$d" ]] || fail "$d left after uninstall"
done
endgroup
printf 'PASS: real run on %s: install, plan, setup, check, rollback, uninstall.\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
