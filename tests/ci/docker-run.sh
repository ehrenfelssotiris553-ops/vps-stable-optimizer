#!/usr/bin/env bash
# CI only, layer 2: a runner with Docker and a container that publishes a
# port, like a VPS that already runs a container service. Docker writes its
# own firewall rules, so the tool must keep the firewall as it is and say why;
# the container must stay reachable and keep its Internet access through the
# setup, a Docker restart (it rebuilds its networking under the new kernel
# settings) and the rollback; and nothing may be left behind.
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
has setup '里有其他防火墙规则'
endgroup

group 'Acceptance check: the firewall kept, Docker named'
rc=0; drive check.rules check sudo vps check || rc=$?
cat "$LOGS/check.log"
[[ "$rc" == 0 || "$rc" == 3 ]] || fail "check exited with $rc"
for item in 'BBR 网络优化' '内核网络安全参数' 'TCP 缓冲区上限' '常用工具' '时区'; do passed check "$item"; done
has check '防火墙：保留了已有配置（other firewall rules present）'
has check 'Docker：已安装：用 -p 发布的容器端口会绕过防火墙'
if sudo ufw status 2>/dev/null | grep -Fxq 'Status: active'; then fail 'UFW was turned on next to Docker'; fi
endgroup

group 'The container keeps working'
container_ok 'after the setup'
sudo systemctl restart docker
sudo docker start web >/dev/null
container_ok 'after Docker restarted under the new kernel settings'
endgroup

group 'Rollback and uninstall'
drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
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
  > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
printf 'PASS: Docker machine: firewall kept, container reachable and online throughout, clean rollback.\n'
