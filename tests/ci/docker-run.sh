#!/usr/bin/env bash
# CI only, layer 2: a runner with Docker and a container that publishes a
# port, like a VPS that already runs a container service. Docker writes its
# own firewall rules; the tool must still turn UFW and Fail2ban on next to
# them (and say that published ports bypass UFW). The container must stay
# reachable and keep its Internet access through the setup, a Docker restart,
# the firewall paused and on again, and the rollback; Docker's FORWARD policy
# must be back as it was whenever UFW is off (`ufw disable` sets it to
# ACCEPT); and nothing may be left behind.
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"
on_target() { sudo bash -c "$1"; }

group 'Docker with a published port'
# runner-prepare.sh masked Docker; this run wants it.
sudo systemctl unmask docker.socket docker.service containerd.service
sudo systemctl start docker
sudo docker run -d --name web -p 8081:80 busybox \
  sh -c 'mkdir -p /www && echo ok > /www/index.html && exec httpd -f -p 80 -h /www'
web_ok() { [[ "$(curl -s -m 5 http://127.0.0.1:8081/ || true)" == ok ]]; }
egress_ok() { sudo docker run --rm busybox wget -q -T 15 -O /dev/null http://deb.debian.org/debian/; }
container_ok() {
  local i
  for ((i = 0; i < 15; i++)); do web_ok && break; sleep 2; done
  web_ok || fail "$1: the published container port does not answer"
  egress_ok || fail "$1: the container has no Internet access"
}
container_ok 'before the install'
# Docker's FORWARD policy (DROP when Docker turned forwarding on itself).
forward() { sudo iptables -S FORWARD | awk 'NR == 1'; }
before_forward="$(forward)"
printf 'FORWARD policy before the tool: %s\n' "$before_forward"
endgroup
# The whole picture before anything is installed, compared at the very end.
snapshot_since="$(date '+%F %T')"
# The snapshots belong to the CI user; only the scripts run as root.
# shellcheck disable=SC2024
sudo bash "$CI/snapshot.sh" > "$LOGS/snapshot-before.txt"

group 'Install and one-click setup (custom mode)'
sudo bash "$ROOT/install.sh" --local-file "$ROOT/vps-stable-opt.sh" --no-run
drive setup-custom.rules setup sudo vps setup || fail "setup exited with $?"
has setup '本次流程已完成'
lacks setup '里有其他防火墙规则'
has setup '检测到 Docker：用 -p 发布的容器端口会绕过 UFW'
has setup '防火墙已保留，自动撤销计时器已取消'
endgroup

group 'Acceptance check: firewall and Fail2ban on next to Docker'
rc=0; drive check.rules check sudo vps check || rc=$?
cat "$LOGS/check.log"
[[ "$rc" == 0 || "$rc" == 3 ]] || fail "check exited with $rc"
for item in 'BBR 网络优化' '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区' '防火墙' 'Fail2ban 防爆破'; do passed check "$item"; done
has check '封禁 192.0.2.123：UFW 中出现了对应的拦截规则'
has check '解封 192.0.2.123：拦截规则已删除'
has check 'Docker：已安装：用 -p 发布的容器端口会绕过防火墙'
# grep reads all of it: -q would stop early, and under pipefail the writer's
# SIGPIPE would hide a match.
sudo ufw status 2>/dev/null | grep -Fx 'Status: active' > /dev/null || fail 'UFW is not on next to Docker'
endgroup

group 'The container keeps working'
container_ok 'after the setup'
sudo systemctl restart docker
sudo docker start web >/dev/null
container_ok 'after Docker restarted under the new kernel settings'
endgroup

group 'The firewall paused and on again: Docker keeps its FORWARD policy, the container keeps working'
index="$(item_index firewall)" || fail 'no single item firewall'
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 2' '临时关闭防火墙吗？ ==> y' > "$LOGS/fw-pause.rules"
drive "$LOGS/fw-pause.rules" fw-pause sudo vps item || fail "pausing the firewall exited with $?"
if sudo ufw status 2>/dev/null | grep -Fx 'Status: active' > /dev/null; then fail 'the firewall is still on after the pause'; fi
[[ "$(forward)" == "$before_forward" ]] || fail "pausing the firewall left FORWARD at '$(forward)', Docker had '$before_forward'"
container_ok 'with the firewall paused'
{ printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1'; cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/fw-on.rules"
drive "$LOGS/fw-on.rules" fw-on sudo vps item || fail "turning the firewall on again exited with $?"
sudo ufw status 2>/dev/null | grep -Fx 'Status: active' > /dev/null || fail 'the firewall did not come on again'
container_ok 'with the firewall on again'
endgroup

group 'Rollback and uninstall'
drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
[[ "$(forward)" == "$before_forward" ]] || fail "the rollback left FORWARD at '$(forward)', Docker had '$before_forward'"
container_ok 'after the rollback'
drive uninstall.rules uninstall sudo vps uninstall || fail "uninstall exited with $?"
endgroup

group 'Nothing left behind: everything compared with before the install'
# shellcheck disable=SC2024
sudo bash "$CI/snapshot.sh" > "$LOGS/snapshot-after.txt"
# shellcheck disable=SC2024
sudo bash "$CI/upgrade-info.sh" "$snapshot_since" > "$LOGS/upgrade-info.txt"
rc=0
python3 "$CI/snapdiff.py" "$LOGS/snapshot-before.txt" "$LOGS/snapshot-after.txt" --upgrades "$LOGS/upgrade-info.txt" \
  --purged > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
printf 'PASS: Docker machine: firewall and Fail2ban on, container reachable and online throughout, FORWARD policy kept, clean rollback.\n'
