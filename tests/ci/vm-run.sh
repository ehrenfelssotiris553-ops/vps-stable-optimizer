#!/usr/bin/env bash
# CI only, layer 3: the real tool on a Debian cloud VM started inside the
# runner (QEMU, with KVM when the runner offers it). It covers what the
# runner itself cannot:
# - Debian 12/13 and a small-memory machine;
# - SSH logins from outside (the new-login confirmation, and fast repeated
#   logins from the allowlisted address);
# - a reboot;
# - setup in tmux surviving a dropped connection;
# - then a full rollback and the uninstall.
# Usage: vm-run.sh 12|13 [MEMORY_MIB]
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"
release="${1:-}" memory="${2:-512}"
case "$release" in 12) codename=bookworm ;; 13) codename=trixie ;; *) fail 'usage: vm-run.sh 12|13 [MEMORY_MIB]' ;; esac
WORK="${RUNNER_TEMP:-/tmp}/vm-$release"
mkdir -p -- "$WORK"
cd -- "$WORK"

group "Debian $release cloud image"
image="debian-$release-genericcloud-amd64.qcow2"
base="https://cloud.debian.org/images/cloud/$codename/latest"
curl -fsSLO "$base/$image"
curl -fsSLO "$base/SHA512SUMS"
grep " $image\$" SHA512SUMS | sha512sum -c - || fail 'cloud image checksum mismatch'
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
printf 'instance-id: vps-ci-%s\nlocal-hostname: vps-ci-%s\n' "$release" "$release" > meta-data
cloud-localds seed.img user-data meta-data
endgroup

accel=tcg cpu=max
if [[ -w /dev/kvm ]]; then accel=kvm cpu=host; fi
printf 'Accelerator: %s, memory: %s MiB\n' "$accel" "$memory"
qemu-system-x86_64 -machine accel="$accel" -cpu "$cpu" -m "$memory" -smp 2 \
  -drive file=disk.qcow2,if=virtio -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$LOGS/console-$release.log" -daemonize -pidfile qemu.pid
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
# An interactive command of the tool on the VM, answered by a rules file.
vm_drive() {
  local rules="$1" name="$2"
  shift 2
  drive "$rules" "$name" ssh "${VM_OPTS[@]}" -tt "$VM_HOST" "TERM=xterm $*"
}
wait_ssh() {
  local i
  for ((i = 0; i < 120; i++)); do
    if vm true 2>/dev/null; then return 0; fi
    sleep 5
  done
  fail 'the VM did not come up for SSH'
}

group 'Boot and install'
wait_ssh
# shellcheck disable=SC2016
vm 'cloud-init status --wait >/dev/null 2>&1 || true; . /etc/os-release; echo "$PRETTY_NAME"; free -m | sed -n 2p'
scp -q -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$ROOT/install.sh" "$ROOT/vps-stable-opt.sh" root@127.0.0.1:/root/
vm 'bash /root/install.sh --local-file /root/vps-stable-opt.sh --no-run'
endgroup

group 'Recommended setup over SSH'
vm_drive setup-vm.rules setup vps setup || fail "setup exited with $?"
has setup '已在系统日志里看到新窗口登录成功，自动确认'
has setup '本次流程已完成'
endgroup

check_all() {
  local name="$1" rc=0
  vm_drive check.rules "$name" vps check || rc=$?
  cat "$LOGS/$name.log"
  [[ "$rc" == 0 || "$rc" == 3 ]] || fail "$name exited with $rc"
  for item in 'BBR 网络优化' '内核网络安全参数' 'ZRAM 内存缓冲' '日志限制' '自动安全更新' '常用工具' '防火墙' 'Fail2ban 防爆破'; do
    passed "$name" "$item"
  done
}
group 'Acceptance check'
check_all check
endgroup

group 'Allowlisted address: no SSH rate limit'
vm 'ufw show added; ufw status numbered' > "$LOGS/ufw-rules.log" || fail 'cannot read the UFW rules'
cat "$LOGS/ufw-rules.log"
grep -Fxq 'ufw allow from 10.0.2.2 to any port 22 proto tcp' "$LOGS/ufw-rules.log" || fail 'exemption rule not listed as expected'
for i in 1 2 3 4 5 6 7 8 9 10; do vm true || fail "SSH login $i refused although the address is allowlisted"; done
endgroup

group 'Reboot'
vm 'systemctl reboot' || true
sleep 20
wait_ssh
check_all check-after-reboot
has check-after-reboot '开荒之后已经重启过'
endgroup

group 'Setup in tmux survives a dropped connection'
ANSWER_TIMEOUT=900 vm_drive tmux-start.rules tmux-start vps setup || fail "tmux start exited with $?"
vm 'tmux has-session -t =vps-setup' || fail 'the setup in tmux ended with the connection'
ANSWER_TIMEOUT=1800 vm_drive tmux-return.rules tmux-return vps || fail "return to tmux exited with $?"
has tmux-return '一键开荒已结束（退出码 0）'
if vm 'tmux has-session -t =vps-setup' 2>/dev/null; then fail 'the tmux session stayed after Enter'; fi
endgroup

group 'Full rollback and uninstall'
vm_drive rollback.rules rollback vps rollback || fail "rollback exited with $?"
has rollback '撤销完成'
# shellcheck disable=SC2016
vm 'for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-bbr.conf /etc/systemd/zram-generator.conf /etc/fail2ban/jail.d/99-vps-stable-sshd.local /etc/systemd/journald.conf.d/99-vps-stable.conf; do [ ! -e "$f" ] || { echo "left: $f"; exit 1; }; done' ||
  fail 'files left after rollback'
vm 'swapon --noheadings | grep -q zram' && fail 'ZRAM still on after rollback'
vm_drive uninstall.rules uninstall vps uninstall || fail "uninstall exited with $?"
vm 'command -v vps' && fail 'vps command left after uninstall'
endgroup
printf 'PASS: Debian %s VM (%s MiB): setup, check, allowlisted logins, reboot, tmux reconnect, rollback, uninstall.\n' "$release" "$memory"
