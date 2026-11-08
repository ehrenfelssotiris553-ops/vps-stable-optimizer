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
has check '封禁 192.0.2.123：nftables 封禁集合里出现了这个地址'
has check '解封 192.0.2.123：拦截已撤掉，恢复原样'
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
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 5' '临时关闭防火墙吗？ ==> y' > "$LOGS/fw-pause.rules"
drive "$LOGS/fw-pause.rules" fw-pause sudo vps item || fail "pausing the firewall exited with $?"
if sudo ufw status 2>/dev/null | grep -Fx 'Status: active' > /dev/null; then fail 'the firewall is still on after the pause'; fi
[[ "$(forward)" == "$before_forward" ]] || fail "pausing the firewall left FORWARD at '$(forward)', Docker had '$before_forward'"
container_ok 'with the firewall paused'
{ printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1'; cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/fw-on.rules"
drive "$LOGS/fw-on.rules" fw-on sudo vps item || fail "turning the firewall on again exited with $?"
sudo ufw status 2>/dev/null | grep -Fx 'Status: active' > /dev/null || fail 'the firewall did not come on again'
container_ok 'with the firewall on again'
endgroup

group 'Published ports behind the firewall: measured from outside the machine'
# This machine's own connections never pass FORWARD, so the client sits in a
# network namespace of its own, with two addresses (for the rules on one source).
sudo ip netns add ci-outside
sudo ip link add ci-host type veth peer name ci-peer
sudo ip link set ci-peer netns ci-outside
sudo ip addr add 198.18.0.1/24 dev ci-host
sudo ip link set ci-host up
sudo ip netns exec ci-outside ip addr add 198.18.0.2/24 dev ci-peer
sudo ip netns exec ci-outside ip addr add 198.18.0.3/24 dev ci-peer
sudo ip netns exec ci-outside ip link set ci-peer up
sudo ip netns exec ci-outside ip link set lo up
sudo ip netns exec ci-outside ip route add default via 198.18.0.1
from_outside() { [[ "$(sudo ip netns exec ci-outside curl -s -m 3 --interface "${1:-198.18.0.2}" http://198.18.0.1:8081/ 2>/dev/null || true)" == ok ]]; }
# SOURCE: up to some seconds, for the path unit to have followed UFW.
opens() { local i; for ((i = 0; i < 12; i++)); do if from_outside "${1:-198.18.0.2}"; then return 0; fi; sleep 1; done; return 1; }
closes() { local i; for ((i = 0; i < 12; i++)); do if ! from_outside "${1:-198.18.0.2}"; then return 0; fi; sleep 1; done; return 1; }
in_set() { sudo nft list set inet vps-stable-docker open_tcp 2>/dev/null | grep -E "[ ,{]$1[ ,}]" > /dev/null; }
table_there() { sudo nft list table inet vps-stable-docker > /dev/null 2>&1; }
opens || fail 'the baseline is wrong: the published port should answer from outside, past the firewall'
dockerfw_index="$(item_index dockerfw)" || fail 'no single item dockerfw'
# NAME CHOICE RULE...
dockerfw_item() {
  local name="$1" choice="$2"
  shift 2
  { printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> %s\n' "$dockerfw_index" "$choice"
    if (($#)); then printf '%s\n' "$@"; fi
    cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/$name.rules"
  drive "$LOGS/$name.rules" "$name" sudo vps item || fail "Docker ports ($name) exited with $?"
}
# Not confirmed: as it was.
dockerfw_item dockerfw-no 1 '继续让外面访问这些端口吗 ==> n' '从外面打开你的网站 ==> n'
has dockerfw-no '这次没有确认'
if table_there; then fail 'the rules stayed without a confirmation'; fi
opens || fail 'the port stayed closed without a confirmation'
# On, with the running port not kept open.
dockerfw_item dockerfw-on 1 '继续让外面访问这些端口吗 ==> n' '从外面打开你的网站 ==> CONNECTED'
has dockerfw-on '已开启：容器端口放行了才能从外面连'
closes || fail 'a port the firewall does not allow still answers from outside'
web_ok || fail 'this machine lost its own access to the container'
egress_ok || fail 'the container lost its Internet access'
# UFW is the one list: following it, within seconds, port by port and by source.
sudo ufw allow 8081/tcp > /dev/null
opens || fail 'allowed in UFW, still closed from outside'
sudo ufw delete allow 8081/tcp > /dev/null
closes || fail 'taken out of UFW, still open from outside'
sudo ufw allow from 198.18.0.2 to any port 8081 proto tcp > /dev/null
opens 198.18.0.2 || fail 'allowed for one source, closed for it'
closes 198.18.0.3 || fail 'allowed for one source, open for another'
sudo ufw delete allow from 198.18.0.2 to any port 8081 proto tcp > /dev/null
closes || fail 'source rule taken out, still open'
# Several commands in a row: the last ones are not lost. (Not neighbours: nft
# shows those as one range.)
sudo ufw allow 18082/tcp > /dev/null; sudo ufw allow 18092/tcp > /dev/null; sudo ufw allow 18102/tcp > /dev/null
for ((i = 0; i < 15; i++)); do if in_set 18082 && in_set 18092 && in_set 18102; then break; fi; sleep 1; done
if ! { in_set 18082 && in_set 18092 && in_set 18102; }; then fail "rules added in a row went missing: $(sudo nft list set inet vps-stable-docker open_tcp)"; fi
for port in 18082 18092 18102; do sudo ufw delete allow "$port/tcp" > /dev/null; done
# Docker restarted: still held back. The firewall paused: nothing is.
sudo systemctl restart docker
sudo docker start web > /dev/null
for ((i = 0; i < 15; i++)); do if web_ok; then break; fi; sleep 2; done
closes || fail 'open from outside after Docker restarted'
drive "$LOGS/fw-pause.rules" dockerfw-fw-pause sudo vps item || fail "pausing the firewall exited with $?"
opens || fail 'still closed with the firewall off'
if table_there; then fail 'the rules stayed with the firewall off'; fi
drive "$LOGS/fw-on.rules" dockerfw-fw-on sudo vps item || fail "turning the firewall on again exited with $?"
closes || fail 'not closed again with the firewall back on'
# Off: as without the switch. The check tells the state.
dockerfw_item dockerfw-off 2
if table_there; then fail 'the rules stayed after switching off'; fi
opens || fail 'still closed after switching off'
# On again, keeping the running port open: the check passes, the rollback below takes the rule back.
dockerfw_item dockerfw-on-again 1 '继续让外面访问这些端口吗 ==> y' '从外面打开你的网站 ==> CONNECTED'
sudo ufw show added | grep -Fx 'ufw allow 8081/tcp' > /dev/null || fail 'the running port was not added to the firewall'
opens || fail 'kept open as asked, closed from outside'
rc=0; drive check.rules check-dockerfw sudo vps check || rc=$?
[[ "$rc" == 0 || "$rc" == 3 ]] || fail "check exited with $rc"
passed check-dockerfw 'Docker 端口受防火墙管'
lacks check-dockerfw '绕过防火墙'
endgroup

group 'Data backup to S3-compatible storage (a stand-in on this machine)'
s3_store="$(mktemp -d)"
python3 "$CI/fake-s3.py" "$s3_store" ciaccesskey 9000 > "$LOGS/fake-s3.log" 2>&1 &
s3_pid=$!
for ((i = 0; i < 20; i++)); do if curl -s -m 2 -o /dev/null http://127.0.0.1:9000/; then break; fi; sleep 1; done
sudo mkdir -p /srv/ci-s3
echo 'object storage payload' | sudo tee /srv/ci-s3/file.txt > /dev/null
printf 'backup_paths=/srv/ci-s3\nbackup_drill_days=1\n' > "$LOGS/backup-params.txt"
drive params.rules backup-params sudo vps params import "$LOGS/backup-params.txt" || fail "params import exited with $?"
backup_index="$(item_index databackup)" || fail 'no single item databackup'
# ACCESS-KEY: the answers for this storage.
s3_answers() {
  printf '%s\n' '备份目标 \[1-4 ==> 2' '对象存储的地址 ==> http://127.0.0.1:9000' '存储桶的名字 ==> ci-bucket' '桶里的目录 ==> vps/one' '区域 ==> us-east-1' "Access Key ==> $1" 'Secret Key ==> cisecretvalue123'
}
# A key the storage does not know: said so, and nothing is switched on.
{ printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> 1\n' "$backup_index"
  s3_answers wrongaccesskey
  printf '%s\n' '备份密码（输入时不显示 ==>' '已经把这个密码存到 ==> y'
  cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/backup-s3-bad.rules"
drive "$LOGS/backup-s3-bad.rules" backup-s3-bad sudo vps item || fail "data backup with a wrong key exited with $?"
has backup-s3-bad '没能在备份目标上建好仓库'
lacks backup-s3-bad '数据备份已开启'
if sudo test -e /etc/systemd/system/vps-stable-backup.timer; then fail 'a backup that never worked was scheduled'; fi
# The right key: backed up, encrypted, and restored from there.
{ printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> 1\n' "$backup_index"
  printf '%s\n' '沿用上次的备份目标吗 ==> n'
  s3_answers ciaccesskey
  cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/backup-s3.rules"
drive "$LOGS/backup-s3.rules" backup-s3 sudo vps item || fail "data backup to S3 exited with $?"
has backup-s3 '数据备份已开启'
has backup-s3 '恢复演练通过'
[[ -f "$s3_store/ci-bucket/vps/one/config" ]] || fail "nothing arrived in the bucket: $(find "$s3_store" | head -n 20)"
if grep -rqF 'object storage payload' "$s3_store"; then fail 'the backup is not encrypted in the bucket'; fi
lacks backup-s3 'cisecretvalue123'
if sudo grep -rlF --exclude=conf -- cisecretvalue123 /var/lib/vps-stable-opt /var/backups/vps-stable-opt | grep .; then fail 'the storage secret is in a log or backup of the tool'; fi
[[ "$(sudo stat -c %a /var/lib/vps-stable-opt/databackup/conf)" == 600 ]] || fail 'the settings with the storage secret are readable by others'
{ printf '请选择要修改的项目 ==> @seq %s 0\n请选择: ==> 5\n' "$backup_index"
  printf '%s\n' '回车返回: ==> 3' '恢复哪一次 ==>' '恢复哪个文件或目录 ==>' '恢复到 /root/vps-restore ==> y'
  cat "$CI/rules/item.rules" "$CI/rules/setup-custom.rules"; } > "$LOGS/backup-s3-restore.rules"
drive "$LOGS/backup-s3-restore.rules" backup-s3-restore sudo vps item || fail "restore from S3 exited with $?"
target="$(sudo find /root -maxdepth 1 -name 'vps-restore-*' | head -n 1)"
[[ "$(sudo cat "$target/srv/ci-s3/file.txt")" == 'object storage payload' ]] || fail 'not restored from the bucket'
sudo rm -rf -- "$target" /srv/ci-s3
kill "$s3_pid"
rm -rf -- "$s3_store"
endgroup

group 'Rollback and uninstall'
drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
if sudo nft list table inet vps-stable-docker > /dev/null 2>&1; then fail 'the rollback left the rules for the Docker ports'; fi
if sudo test -e /etc/systemd/system/vps-stable-docker-fw.path; then fail 'the rollback left the unit that follows UFW'; fi
if sudo test -e /etc/systemd/system/vps-stable-backup.service; then fail 'the rollback left the backup service'; fi
opens || fail 'the rollback left the published port closed from outside'
[[ "$(forward)" == "$before_forward" ]] || fail "the rollback left FORWARD at '$(forward)', Docker had '$before_forward'"
container_ok 'after the rollback'
drive uninstall.rules uninstall sudo vps uninstall || fail "uninstall exited with $?"
endgroup

sudo ip netns del ci-outside
sudo ip link del ci-host 2> /dev/null || true

group 'Nothing left behind: everything compared with before the install'
# shellcheck disable=SC2024
sudo bash "$CI/snapshot.sh" > "$LOGS/snapshot-after.txt"
# shellcheck disable=SC2024
sudo bash "$CI/upgrade-info.sh" "$snapshot_since" > "$LOGS/upgrade-info.txt"
rc=0
python3 "$CI/snapdiff.py" "$LOGS/snapshot-before.txt" "$LOGS/snapshot-after.txt" --upgrades "$LOGS/upgrade-info.txt" \
  --purged --marks > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
# shellcheck disable=SC2119
no_tool_errors
printf 'PASS: Docker machine: firewall and Fail2ban on, container reachable and online throughout, FORWARD policy kept, clean rollback.\n'
