#!/usr/bin/env bash
# CI only, layer 3: the real tool on an official cloud image of each
# supported release, as a small VM inside the runner (QEMU, with KVM when the
# runner offers it). It covers what the runner itself cannot:
# - every supported release on a small-memory machine;
# - SSH logins from outside (the new-login confirmation, and fast repeated
#   logins from the allowlisted address);
# - the real effect from outside: a port the firewall blocks, opens and
#   closes again; a stranger on a second network card who guesses passwords
#   is banned for real, listed by `vps bans` with its time, and unbanned there;
# - a reboot;
# - setup in tmux surviving a dropped connection;
# - SSH hardening for real: a dropped connection mid-way puts the old login
#   settings back by itself; then key-only login, a new sudo admin and no root
#   login, which also survive a reboot;
# - then a full rollback and the uninstall.
# SYSTEM-old starts from the first image of the release instead, as some
# providers still hand out: years of updates, a new kernel, changed
# configuration files. There the setup runs in tmux and the connection is cut
# while the system upgrade runs; the setup must go on and be finished after
# logging in again.
# Usage: vm-run.sh debian-12|debian-13|ubuntu-22.04|ubuntu-24.04|ubuntu-26.04[-old] [MEMORY_MIB]
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"
system="${1:-}" memory="${2:-512}" old=0
if [[ "$system" == *-old ]]; then old=1; fi
case "${system%-old}" in
  debian-12) codename=bookworm first=20230612-1409 ;;
  debian-13) codename=trixie first='' ;;
  ubuntu-22.04) codename=jammy first=release-20220420 ;;
  ubuntu-24.04) codename=noble first=release-20240423 ;;
  ubuntu-26.04) codename=resolute first='' ;;
  *) fail 'usage: vm-run.sh debian-12|debian-13|ubuntu-22.04|ubuntu-24.04|ubuntu-26.04[-old] [MEMORY_MIB]' ;;
esac
if ((old)) && [[ -z "$first" ]]; then fail "no first image recorded for ${system%-old}"; fi
release="${system%-old}" release="${release#*-}"
WORK="${RUNNER_TEMP:-/tmp}/vm-$system"
mkdir -p -- "$WORK"
cd -- "$WORK"

group "$system cloud image"
if [[ "$system" == debian-* ]]; then
  image="debian-$release-genericcloud-amd64.qcow2"
  base="https://cloud.debian.org/images/cloud/$codename/latest"
  if ((old)); then image="debian-$release-genericcloud-amd64-$first.qcow2" base="https://cloud.debian.org/images/cloud/$codename/$first"; fi
  sums=SHA512SUMS check=sha512sum
else
  image="ubuntu-$release-server-cloudimg-amd64.img"
  base="https://cloud-images.ubuntu.com/releases/$release/release"
  if ((old)); then base="https://cloud-images.ubuntu.com/releases/$codename/$first"; fi
  sums=SHA256SUMS check=sha256sum
fi
curl -fsSLO "$base/$image"
curl -fsSLO "$base/$sums"
grep -E " \*?$image\$" "$sums" | "$check" -c - || fail 'cloud image checksum mismatch'
qemu-img create -q -f qcow2 -F qcow2 -b "$image" disk.qcow2 10G
ssh-keygen -q -t ed25519 -N '' -f key
# Root logs in with the key like on a VPS; password login stays on (so the
# firewall rate-limits SSH and the allowlist exemption is exercised).
cat > user-data <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
ssh_authorized_keys:
  - $(cat key.pub)
chpasswd:
  expire: false
  users:
    - {name: root, password: $(openssl rand -hex 16), type: text}
EOF
printf 'instance-id: vps-ci-%s\nlocal-hostname: vps-ci-%s\n' "$system" "${system//./-}" > meta-data
cloud-localds seed.img user-data meta-data
endgroup

accel=tcg cpu=max
if [[ -w /dev/kvm ]]; then accel=kvm cpu=host; fi
printf 'Accelerator: %s, memory: %s MiB\n' "$accel" "$memory"
qemu-system-x86_64 -machine accel="$accel" -cpu "$cpu" -m "$memory" -smp 2 \
  -drive file=disk.qcow2,if=virtio -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:01 \
  -netdev user,id=n1,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:2223-:22 -device virtio-net-pci,netdev=n1,mac=52:54:00:12:34:02 \
  -display none -serial file:"$LOGS/console-$system.log" -daemonize -pidfile qemu.pid
trap 'kill "$(cat "$WORK/qemu.pid" 2>/dev/null)" 2>/dev/null || true' EXIT

# Options go before the host (after it, ssh would send them as the command).
VM_OPTS=(-i "$WORK/key" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ConnectTimeout=10 -o ServerAliveInterval=15)
VM_HOST=root@127.0.0.1
# The same login as one string, for the "!" answers that run through sh.
VM_SSH="ssh ${VM_OPTS[*]} $VM_HOST"
export VM_SSH
# Commands are given as strings and expand on the VM, not here.
# shellcheck disable=SC2029
vm() { ssh "${VM_OPTS[@]}" "$VM_HOST" "$@"; }
on_target() { vm "$1"; }
# An interactive command of the tool on the VM, answered by a rules file
# (as root, or as VM_AS).
vm_drive() {
  local rules="$1" name="$2"
  shift 2
  drive "$rules" "$name" ssh "${VM_OPTS[@]}" -tt "${VM_AS:-$VM_HOST}" "TERM=xterm $*"
}
# Waits until COMMAND (by default a root login) works.
wait_ssh() {
  local i
  for ((i = 0; i < 120; i++)); do
    if "${@:-vm}" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  fail 'the VM did not come up for SSH'
}

# The admin account the SSH hardening creates: the same CI key, and a test
# password for sudo that exists only on this throwaway VM.
VM_OPS_HOST=ops@127.0.0.1
VM_SSH_OPS="ssh ${VM_OPTS[*]} $VM_OPS_HOST"
ADMIN_PW="$(openssl rand -hex 12)"
VM_PUBKEY="$(cat "$WORK/key.pub")"
# ops logs in with the key and uses sudo once, as the hardening asks: in a
# terminal like a person would (the tool looks for sudo's TTY= log line),
# typing the password at sudo's prompt (sudo drops input typed earlier).
cat > "$WORK/ops-sudo" <<EOF
#!/bin/sh
exec expect "$CI/answer.exp" "$CI/rules/sudo.rules" "$LOGS/ops-sudo.raw" ssh ${VM_OPTS[*]} -tt $VM_OPS_HOST 'sudo true'
EOF
chmod +x "$WORK/ops-sudo"
VM_OPS_SUDO="$WORK/ops-sudo"
export VM_SSH_OPS ADMIN_PW VM_PUBKEY VM_OPS_SUDO
# shellcheck disable=SC2029
vm_ops() { ssh "${VM_OPTS[@]}" "$VM_OPS_HOST" "$@"; }
# shellcheck disable=SC2029
vm_ops_sudo() { printf '%s\n' "$ADMIN_PW" | ssh "${VM_OPTS[@]}" "$VM_OPS_HOST" "sudo -S -p '' $*"; }
# The login methods sshd still offers USER, from a login that offers none
# (for example "publickey,password").
ssh_methods() {
  ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -o PreferredAuthentications=none -o ConnectTimeout=10 "$1@127.0.0.1" true 2>&1 |
    sed -n 's/.*Permission denied (\(.*\))\..*/\1/p' || true
}
KEYONLY=/etc/ssh/sshd_config.d/01-vps-stable-keyonly.conf
# What sudo logged, for a hardening run that did not see the admin's sudo.
sudo_journal() {
  vm 'journalctl -q -t sudo -n 8 --no-pager -o cat; journalctl -q _UID=0 -t sudo -n 3 --no-pager -o cat | sed "s/^/as uid 0: /"' || true
  cat "$LOGS/ops-sudo.raw" 2>/dev/null || true
}

group 'Boot and install'
wait_ssh
# shellcheck disable=SC2016
vm 'cloud-init status --wait >/dev/null 2>&1 || true; . /etc/os-release; echo "$PRETTY_NAME"; free -m | sed -n 2p'
# The whole picture before anything is installed, compared at the very end.
snapshot_since="$(vm "date '+%F %T'")"
vm 'bash -s' < "$CI/snapshot.sh" > "$LOGS/snapshot-before.txt"
scp -q -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$ROOT/install.sh" "$ROOT/vps-stable-opt.sh" root@127.0.0.1:/root/
vm 'bash /root/install.sh --local-file /root/vps-stable-opt.sh --no-run'
# Ubuntu's cloud kernels keep zram in linux-modules-extra, which the tool
# deliberately does not install: there ZRAM has to be reported unsupported.
zram_kernel=1
vm 'modinfo zram >/dev/null 2>&1' || zram_kernel=0
printf 'zram module in this kernel: %s\n' "$zram_kernel"
endgroup

if ((old)); then
  group 'Recommended setup in tmux; the connection drops in the middle of the system upgrade'
  ANSWER_TIMEOUT=2700 vm_drive tmux-upgrade.rules setup vps setup &
  drive_pid=$!
  upgrading() { vm 'grep -qsx apt_upgrade /var/lib/vps-stable-opt/run-*/active_stage && pgrep -x dpkg >/dev/null' 2>/dev/null; }
  # An old image first runs its own automatic updates, which the tool waits for.
  started=0
  for ((i = 0; i < 1080; i++)); do
    if upgrading; then started=1; break; fi
    sleep 5
  done
  ((started)) || fail 'the system upgrade never got going'
  # Like a network drop: the SSH client goes away while dpkg works.
  pkill -f 'answer\.exp .*tmux-upgrade\.rules' || true
  wait "$drive_pid" || true
  sleep 5
  vm 'tmux has-session -t =vps-setup' || fail 'the setup in tmux ended with the connection'
  printf 'After the drop: %s\n' "$(vm 'pgrep -a dpkg | head -n 2' || true)"
  ANSWER_TIMEOUT=2700 vm_drive tmux-return.rules setup-return vps || fail "return to tmux exited with $?"
  has setup-return '一键开荒已结束（退出码 0）'
  # tmux redraws the screen in pieces, which can split a line of text: the
  # facts come from the tool's own run log and a plan outside tmux.
  # (Every run log: only this setup has run so far.)
  vm 'cat /var/lib/vps-stable-opt/logs/run-*.log' |
    sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' > "$LOGS/setup-runlog.log"
  # How SSH looks after the upgrade (the firewall step needs it confirmed).
  vm 'sshd -t; echo "sshd -t: $?"; ls -ld /run/sshd; systemctl is-active ssh.socket ssh.service; ss -H -lntp "( sport = :22 )"; systemctl show ssh.socket -p Listen --value; dpkg-query -W openssh-server' \
    > "$LOGS/ssh-after-upgrade.log" 2>&1 || true
  notice "SSH after the upgrade ($system)" "$LOGS/ssh-after-upgrade.log"
  has setup-runlog '已在系统日志里看到新窗口登录成功，自动确认'
  has setup-runlog '本次流程已完成'
  ssh_facts setup-runlog
  vm 'vps plan' > "$LOGS/plan.log" 2>&1 || fail 'plan failed'
  plan_facts plan
else
  group 'Recommended setup over SSH'
  vm_drive setup-vm.rules setup vps setup || fail "setup exited with $?"
  has setup '已在系统日志里看到新窗口登录成功，自动确认'
  has setup '本次流程已完成'
  plan_facts setup
  ssh_facts setup
fi
# The health report must raise no false alarm on a fresh machine.
probe() {
  local rc=0
  vm 'bash -s' < "$CI/journal-probe.sh" > "$LOGS/$1.log" 2>&1 || rc=$?
  notice "$1 ($system)" "$LOGS/$1.log"
  ((rc == 0)) || fail "the health report counts journal lines on a fresh machine ($1 notice)"
}
probe journal-probe
endgroup

# `vps check` (after a command prefix such as sudo) with every item expected.
check_all() {
  local name="$1" rc=0
  shift
  vm_drive check.rules "$name" "$@" vps check || rc=$?
  cat "$LOGS/$name.log"
  [[ "$rc" == 0 || "$rc" == 3 ]] || fail "$name exited with $rc"
  for item in 'BBR 网络优化' '内核网络安全参数' '日志限制' '自动安全更新' '常用工具' '防火墙' 'Fail2ban 防爆破'; do
    passed "$name" "$item"
  done
  if ((zram_kernel)); then passed "$name" 'ZRAM 内存缓冲'
  else has "$name" '[➖ 未处理] ZRAM 内存缓冲：系统不支持'; fi
}
group 'Acceptance check'
check_all check
check_facts check
# The check's own SSH connection really runs BBR, as it says.
has check '当前 SSH 连接实际在用 bbr'
[[ "$(vm 'ss -tinH state established "( sport = :22 )"')" == *bbr* ]] || fail 'SSH connections do not use bbr'
if ((zram_kernel)); then
  # Size and algorithm as zramctl reads them from the kernel.
  read -r zbytes zalg < <(vm 'zramctl --noheadings --bytes --output DISKSIZE,ALGORITHM /dev/zram0')
  zline="$(grep -m1 'ZRAM 内存缓冲：' "$LOGS/check.log")"
  zsaid="$(sed -n 's/.*约 \([0-9]*\) MiB.*/\1/p' <<< "$zline")"
  near "${zsaid:-0}" $((zbytes / 1048576)) || fail "ZRAM is $((zbytes / 1048576)) MiB, the check says $zsaid"
  [[ "$zline" == *"压缩算法 $zalg"* ]] || fail "ZRAM uses $zalg, the check says: $zline"
fi
endgroup

group 'SSH with the listening socket only (as right after an OpenSSH update)'
# Where systemd's socket starts sshd on demand, an OpenSSH update stops the
# service until the next login; the tool must still see SSH then. Recorded
# for review: sshd -t, the privilege separation directory, the listener.
# shellcheck disable=SC2016
vm 'if systemctl is-active -q ssh.socket; then systemctl stop ssh.service; sleep 1; echo "service: $(systemctl is-active ssh.service)"; ls -ld /run/sshd 2>&1; sshd -t 2>&1; echo "sshd -t: $?"; sshd -T 2>&1 | grep -m1 "^port "; ss -H -lntp "( sport = :22 )"; else echo "no ssh.socket here"; fi' \
  > "$LOGS/ssh-socket-only.log" 2>&1 || true
notice "SSH with the socket only ($system)" "$LOGS/ssh-socket-only.log"
if [[ "$(vm 'systemctl is-active ssh.socket' 2>/dev/null || true)" == active ]]; then
  # The check runs in the same session that stopped the service: a new login
  # would start it again through the socket.
  vm_drive check.rules check-socket-only 'systemctl stop ssh.service; sleep 1; ls -ld /run/sshd 2>&1; vps check' ||
    [[ $? == 3 ]] || fail 'check with the socket only failed'
  passed check-socket-only '防火墙'
  has check-socket-only 'SSH 端口已放行'
fi
wait_ssh
endgroup

group 'Allowlisted address: no SSH rate limit'
vm 'ufw show added; ufw status numbered' > "$LOGS/ufw-rules.log" || fail 'cannot read the UFW rules'
cat "$LOGS/ufw-rules.log"
grep -Fxq 'ufw allow from 10.0.2.2 to any port 22 proto tcp' "$LOGS/ufw-rules.log" || fail 'exemption rule not listed as expected'
for i in 1 2 3 4 5 6 7 8 9 10; do vm true || fail "SSH login $i refused although the address is allowlisted"; done
endgroup

group 'From outside: the firewall really blocks, opens and closes a port'
vm 'nohup python3 -m http.server 8080 >/dev/null 2>&1 </dev/null &'
web() { curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8080/ || true; }
sleep 2
[[ -n "$(vm 'ss -H -lnt "( sport = :8080 )"')" ]] || fail 'the test web server on 8080 did not start'
[[ "$(web)" != 200 ]] || fail 'port 8080 answered before it was opened'
vm_drive port.rules port-open vps port open 8080 tcp || fail "port open exited with $?"
[[ "$(web)" == 200 ]] || fail 'port 8080 does not answer after vps port open'
vm_drive port.rules port-close vps port close 8080 tcp || fail "port close exited with $?"
[[ "$(web)" != 200 ]] || fail 'port 8080 still answers after vps port close'
vm 'pkill -f "http.server 8080"' || true
endgroup

group 'From outside: a stranger guessing passwords is banned for real, then unbanned'
# The second network card: there the VM sees this runner as 10.0.3.2, an
# address on no allowlist.
nic2="$(vm "ip -o link | awk -F': ' '/52:54:00:12:34:02/ {print \$2}'")"
[[ -n "$nic2" ]] || fail 'no second network card in the VM'
vm "ip addr add 10.0.3.15/24 dev $nic2 2>/dev/null; ip link set $nic2 up"
stranger() {
  ssh -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$@" </dev/null 2>&1 || true
}
# sshd answers with the methods it offers; a banned address gets nothing.
reachable() { [[ "$(stranger -o BatchMode=yes -o PreferredAuthentications=none nobody-ci@127.0.0.1 true)" == *'Permission denied'* ]]; }
for ((i = 0; i < 15; i++)); do reachable && break; sleep 2; done
reachable || fail 'the second network card does not reach sshd'
# Wrong passwords for an account that does not exist, as a scanner sends them.
printf '#!/bin/sh\necho wrong-password\n' > "$WORK/askpass"
chmod +x "$WORK/askpass"
for i in 1 2 3; do
  SSH_ASKPASS="$WORK/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none stranger -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=3 nobody-ci@127.0.0.1 true >/dev/null
done
banned() { [[ "$(vm 'fail2ban-client status sshd')" == *10.0.3.2* ]]; }
for ((i = 0; i < 30; i++)); do banned && break; sleep 2; done
banned || { vm 'fail2ban-client status sshd; journalctl -u ssh -u sshd -n 15 --no-pager -o cat' || true; fail 'the stranger was not banned'; }
if reachable; then fail 'the banned stranger still reaches sshd'; fi
vm true || fail 'the allowlisted address lost its access as well'
vm_drive bans.rules bans vps bans || fail "bans exited with $?"
grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*封禁.*10\.0\.3\.2' "$LOGS/bans.log" ||
  fail 'vps bans lists no timed ban of the stranger'
if banned; then fail 'the stranger is still banned after the unban in vps bans'; fi
# UFW also limits SSH to 6 new connections per 30 seconds from one address.
sleep 30
reachable || fail 'the stranger is still blocked after the unban'
endgroup

group 'Reboot'
vm 'systemctl reboot' || true
sleep 20
wait_ssh
check_all check-after-reboot
has check-after-reboot '开荒之后已经重启过'
probe journal-probe-after-reboot
endgroup

if ((!old)); then
  # (On an old image the first setup already ran in tmux and lost its connection.)
  group 'Setup in tmux survives a dropped connection'
  ANSWER_TIMEOUT=900 vm_drive tmux-start.rules tmux-start vps setup || fail "tmux start exited with $?"
  vm 'tmux has-session -t =vps-setup' || fail 'the setup in tmux ended with the connection'
  ANSWER_TIMEOUT=1800 vm_drive tmux-return.rules tmux-return vps || fail "return to tmux exited with $?"
  has tmux-return '一键开荒已结束（退出码 0）'
  if vm 'tmux has-session -t =vps-setup' 2>/dev/null; then fail 'the tmux session stayed after Enter'; fi
  endgroup

  group 'Ctrl+C in the middle of a setup, then the setup once more'
  vm_drive setup-vm.rules interrupt vps setup &
  drive_pid=$!
  # Once the questions are answered and the changes run.
  for ((i = 0; i < 300; i++)); do
    vm 'grep -qsxE "zram|apt_upgrade|bbr|sysctl|tcp|journal|trim|updates|autoreboot|timezone|hosts" /var/lib/vps-stable-opt/run-*/active_stage' 2>/dev/null && break
    sleep 1
  done
  printf 'Interrupted in stage: %s\n' "$(vm 'cat /var/lib/vps-stable-opt/run-*/active_stage | grep -vx none' || true)"
  # What Ctrl+C does: SIGINT to the whole foreground process group, apt and
  # dpkg included.
  # shellcheck disable=SC2016
  vm 'pgid="$(ps -o pgid= -p "$(pgrep -o -f "vps-stable-opt.sh setup")" | tr -d " ")"; [ -n "$pgid" ] && kill -INT -- "-$pgid"'
  if wait "$drive_pid"; then fail 'the interrupted setup ended as if nothing happened'; fi
  if vm 'dpkg --audit | grep -q .'; then
    # dpkg was cut off: the tool has to stop and say how to repair it.
    vm_drive setup-vm.rules interrupt-blocked vps setup || true
    has interrupt-blocked 'dpkg --configure -a'
    vm 'dpkg --configure -a'
  fi
  vm_drive setup-vm.rules after-interrupt vps setup || fail "setup after Ctrl+C exited with $?"
  has after-interrupt '本次流程已完成'
  check_all check-after-interrupt
  endgroup
fi

group 'SSH hardening: a connection dropped mid-way puts the old settings back'
vm_drive ssh-drop.rules ssh-drop vps ssh || { rc=$?; sudo_journal; fail "ssh hardening (dropped) exited with $rc"; }
has ssh-drop '系统日志确认 ops 已用密钥登录成功'
has ssh-drop 'ops 当前已有 0 个公钥'
has ssh-drop '已关闭 SSH 密码登录'
# The guard timer (240 s) undoes it; ops logs in with the key all along.
drop_at=$SECONDS undone=0
for ((i = 0; i < 120; i++)); do
  if vm_ops "[ ! -e $KEYONLY ]" 2>/dev/null; then undone=1; break; fi
  sleep 5
done
printf 'Key-only login undone %s s after the drop.\n' "$((SECONDS - drop_at))"
# Judged by the loop, not by a second login: right after the file goes, the
# undo reloads sshd, and a connection made in that moment is reset (seen on
# Debian 12, the undo on time at 240 s).
if ((undone == 0)); then
  # Present, or no SSH at all? Then when the undo timer was made and ran.
  seen="$(vm_ops "if [ -e $KEYONLY ]; then echo present; else echo absent; fi" 2>&1 || true)"
  vm_ops_sudo 'sh -c "date; systemctl list-units --all --no-legend \"vps-stable-ssh-revert-*\"; journalctl -b --no-pager -o short-precise | grep -E \"vps-stable-ssh-revert|Reload\" | tail -n 15; journalctl -n 8 --no-pager -o short -u ssh.service"' \
    > "$LOGS/ssh-drop-undo.log" 2>&1 || true
  notice "SSH undo after the drop ($system)" "$LOGS/ssh-drop-undo.log"
  fail "key-only login stayed after the dropped connection (ops sees the file: ${seen:-no SSH})"
fi
# The undo removes the file, then reloads sshd: give the reload a moment.
for ((i = 0; i < 60; i++)); do vm true 2>/dev/null && break; sleep 5; done
if ! vm true 2>/dev/null; then
  vm_ops_sudo 'sh -c "systemctl is-active ssh.service ssh.socket; ls /etc/ssh/sshd_config.d; sshd -T -C user=root,host=x,addr=10.0.2.2 | grep -iE \"^(permitrootlogin|passwordauthentication) \"; systemctl list-units --all --no-legend \"vps-stable-ssh-revert-*\"; journalctl -u ssh.service -u ssh.socket -n 25 --no-pager -o short"' \
    > "$LOGS/ssh-undo.log" 2>&1 || true
  notice "SSH after the undo ($system)" "$LOGS/ssh-undo.log"
  fail 'root cannot log in again after the undo'
fi
[[ "$(ssh_methods root)" == *password* ]] || fail "password login not back after the undo: $(ssh_methods root)"
endgroup

group 'SSH hardening: key-only login, admin ops with sudo, no root login'
vm_drive ssh-apply.rules ssh-apply vps ssh || { rc=$?; sudo_journal; fail "ssh hardening exited with $rc"; }
has ssh-apply '已在系统日志里看到新窗口登录成功，自动确认'
has ssh-apply '新的 SSH 登录设置已保留'
has ssh-apply 'ops 当前已有 1 个公钥'
hardened() {
  if vm true 2>/dev/null; then fail "$1: root can still log in over SSH"; fi
  [[ "$(ssh_methods ops)" == publickey ]] || fail "$1: sshd still offers $(ssh_methods ops)"
  vm_ops_sudo true || fail "$1: ops cannot use sudo"
}
hardened 'after hardening'
vm_ops_sudo systemctl reboot || true
sleep 20
wait_ssh vm_ops
hardened 'after a reboot'
VM_AS=$VM_OPS_HOST check_all check-hardened sudo
passed check-hardened 'SSH 登录加固'
endgroup

group 'Full rollback and uninstall'
# Root has no SSH login now: the admin rolls back, which brings it back.
VM_AS=$VM_OPS_HOST vm_drive rollback.rules rollback sudo vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
has rollback '已恢复 SSH 原来的登录设置'
vm true || fail 'root cannot log in after the rollback'
[[ "$(ssh_methods root)" == *password* ]] || fail "password login not restored by the rollback: $(ssh_methods root)"
# shellcheck disable=SC2016
vm 'for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-bbr.conf /etc/systemd/zram-generator.conf /etc/fail2ban/jail.d/99-vps-stable-sshd.local /etc/systemd/journald.conf.d/99-vps-stable.conf; do [ ! -e "$f" ] || { echo "left: $f"; exit 1; }; done' ||
  fail 'files left after rollback'
vm 'swapon --noheadings | grep -q zram' && fail 'ZRAM still on after rollback'
vm_drive uninstall.rules uninstall vps uninstall || fail "uninstall exited with $?"
vm 'command -v vps' && fail 'vps command left after uninstall'
endgroup

group 'Nothing left behind: everything compared with before the install'
vm 'bash -s' < "$CI/snapshot.sh" > "$LOGS/snapshot-after.txt"
vm "bash -s '$snapshot_since'" < "$CI/upgrade-info.sh" > "$LOGS/upgrade-info.txt"
rc=0
# ops, the admin made by the SSH hardening, stays by design (with its key).
python3 "$CI/snapdiff.py" "$LOGS/snapshot-before.txt" "$LOGS/snapshot-after.txt" --upgrades "$LOGS/upgrade-info.txt" \
  --allow-user ops --purged > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
printf 'PASS: %s VM (%s MiB): setup, check, allowlisted logins, reboot, tmux reconnect, SSH hardening (dropped and kept), rollback, uninstall.\n' "$system" "$memory"
