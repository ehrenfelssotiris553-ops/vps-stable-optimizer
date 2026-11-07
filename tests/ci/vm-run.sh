#!/usr/bin/env bash
# CI only, layer 3: the real tool on an official cloud image of each
# supported release, as a small VM inside the runner (QEMU, with KVM when the
# runner offers it). It covers what the runner itself cannot:
# - every supported release on a small-memory machine, and one with 1.5 GiB
#   (from 1 GiB on the recommended set raises the TCP buffers);
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
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:2224-:2244 \
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
# The same VM on SSH port 2244 (the port change test), from 127.0.0.1:2224.
VM_NEW_OPTS=(-i "$WORK/key" -p 2224 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
VM_SSH_NEW="ssh ${VM_NEW_OPTS[*]} $VM_HOST"
export VM_SSH_NEW
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
# A provider's own SSH settings, read before this tool's files (a real Debian
# 13 VPS had them, 2026-11-03): the hardening and the port change must name
# these lines and comment them out on a yes, and every way back (the guard
# timer, the single item, the full rollback) must put them back byte for byte
# (the snapshot below has the file).
PROVIDER_CONF=/etc/ssh/sshd_config.d/00-aaa-provider.conf
vm "printf '%s\\n' '# A provider image (CI): read before the tool' 'PasswordAuthentication yes' 'Port 22' > $PROVIDER_CONF"
provider_line() { vm "grep -qx '$1' $PROVIDER_CONF" 2>/dev/null || vm_ops_sudo grep -qx "'$1'" "$PROVIDER_CONF"; }
# The whole picture before anything is installed, compared at the very end.
snapshot_since="$(vm "date '+%F %T'")"
vm 'bash -s' < "$CI/snapshot.sh" > "$LOGS/snapshot-before.txt"
scp -q -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$ROOT/install.sh" "$ROOT/vps-stable-opt.sh" root@127.0.0.1:/root/
vm 'bash /root/install.sh --local-file /root/vps-stable-opt.sh --no-run'
# An SSH keepalive the image sets itself (Debian's cloud images: 120 seconds)
# is kept by the tool; without one the tool's 60 seconds apply.
# shellcheck disable=SC2016
ka_kept="$(vm 'if grep -REiq "^[[:space:]]*ClientAliveInterval" /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
  mkdir -p /run/sshd; sshd -T 2>/dev/null | awk '"'"'$1 == "clientaliveinterval" && $2 != 0 {print $2}'"'"'; fi' || true)"
printf 'SSH keepalive set by the image: %s\n' "${ka_kept:-none}"
# Debian 13 has three times ended with apt-listchanges.timer disabled after
# the rollback, a unit the tool never names: its state after each step, shown
# when the comparison at the end fails.
lc_mark() {
  printf '%s: %s\n' "$1" "$(vm 'systemctl is-enabled apt-listchanges.timer 2>&1' || true)" >> "$LOGS/listchanges-steps.txt"
}
lc_mark 'after the install'
# Ubuntu's cloud kernels keep zram in linux-modules-extra, which the tool
# deliberately does not install: there ZRAM has to be reported unsupported.
zram_kernel=1
vm 'modinfo zram >/dev/null 2>&1' || zram_kernel=0
printf 'zram module in this kernel: %s\n' "$zram_kernel"
# From 1 GiB of RAM the recommended set raises the TCP buffers (16 MiB below
# 1 GiB, 32 below 4 GiB, 64 above): the kernel's value from before the tool,
# for the rollback.
# shellcheck disable=SC2016
vm_mem="$(vm 'awk "/^MemTotal:/ {printf \"%d\", \$2 / 1024}" /proc/meminfo')"
tcp_want=64; if ((vm_mem < 4096)); then tcp_want=32; fi; if ((vm_mem < 1024)); then tcp_want=16; fi
tcp_before="$(vm "sysctl -n net.ipv4.tcp_rmem | awk '{print \$3}'")"
printf 'RAM %s MiB: TCP buffers %s, receive cap before the tool %s\n' "$vm_mem" "$(if ((vm_mem >= 1024)); then echo "raised to $tcp_want MiB"; else echo 'left alone'; fi)" "$tcp_before"
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
  # The redrawn screen can show old questions as if they were waiting: the
  # answers sent to them reach the tool, which drops them at its next question.
  notice "answers after reconnecting ($system)" "$LOGS/setup-return.raw.answers"
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
  # Seen once on Ubuntu 24.04's old image (the firewall ended up off): what
  # the firewall step said, and the logins sshd wrote to the journal.
  if ! grep -Fq '已在系统日志里看到新窗口登录成功，自动确认' "$LOGS/setup-runlog.log"; then
    { echo '-- the firewall step in the run log:'
      grep -n -E '防火墙|确认|恢复|登录' "$LOGS/setup-runlog.log" | tail -n 20
      echo '-- sshd in the journal since the boot:'
      vm "journalctl -q --since '$snapshot_since' _UID=0 -t sshd -t sshd-session -o short-iso --no-pager | grep -E 'Accepted|listening|signal|terminat' | tail -n 15" || true
    } > "$LOGS/firewall-confirm.txt" 2>&1
    notice "firewall confirmation in tmux ($system)" "$LOGS/firewall-confirm.txt"
  fi
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
  for item in 'BBR 网络优化' '内核网络安全参数' '日志限制' '自动安全更新' '常用工具' '防火墙' 'Fail2ban 防爆破' '登录记录和提醒'; do
    passed "$name" "$item"
  done
  # SSH keepalive is in the recommended set: the image's own interval kept,
  # or the tool's 60 seconds; checked against sshd itself where root may log in.
  if [[ -n "$ka_kept" ]]; then has "$name" "SSH 保活：保留了已有配置（ClientAliveInterval $ka_kept）"
  else passed "$name" 'SSH 保活'; fi
  if (($# == 0)); then
    vm "mkdir -p /run/sshd; sshd -T 2>/dev/null | grep -qx 'clientaliveinterval ${ka_kept:-60}'" ||
      fail "$name: sshd does not use a keepalive of ${ka_kept:-60} seconds"
  fi
  if ((vm_mem >= 1024)); then
    passed "$name" 'TCP 缓冲区上限'
    ssh "${VM_OPTS[@]}" "${VM_AS:-$VM_HOST}" 'sysctl -n net.ipv4.tcp_rmem' | awk -v w=$((tcp_want * 1048576)) '$3 == w {f = 1} END {exit !f}' ||
      fail "$name: the kernel's TCP receive cap is not $tcp_want MiB"
  fi
  if ((zram_kernel)); then passed "$name" 'ZRAM 内存缓冲'
  else
    # No ZRAM on a small machine: a disk swap instead, used after ZRAM, at boot.
    has "$name" '○ 未处理  ZRAM 内存缓冲：系统不支持'
    passed "$name" '硬盘 Swap'
    # As whoever may log in now (after the SSH hardening root may not).
    ssh "${VM_OPTS[@]}" "${VM_AS:-$VM_HOST}" "awk '\$1 == \"/swapfile\" && \$5 == 10 {f = 1} END {exit !f}' /proc/swaps" ||
      fail "$name: /swapfile not in use with priority 10"
  fi
}
lc_mark 'after the setup'
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

group 'Login record: real SSH logins are recorded, an interactive one shows the note'
# Every vm command above was an SSH login from the host side (10.0.2.2).
vm 'tail -n 1 /var/lib/vps-stable-opt/logins' > "$LOGS/logins-tail.txt" || true
grep -q $'\troot\t10.0.2.2\tpublickey\tssh\t' "$LOGS/logins-tail.txt" || fail "an SSH login was not recorded: $(cat "$LOGS/logins-tail.txt")"
# A login without a command (sshd shows PAM's messages only then); the shell is left at once.
printf '%s\n' ':~# ==> exit' > "$LOGS/login-shell.rules"
drive "$LOGS/login-shell.rules" login-shell ssh "${VM_OPTS[@]}" -tt "$VM_HOST" || fail "the interactive login exited with $?"
has login-shell '—— VPS 机器管家：登录记录 ——'
has login-shell '上次登录：'
endgroup

group 'Security audit on a clean image: nothing suspect'
vm 'vps audit' > "$LOGS/audit.log" 2>&1 || fail "vps audit exited with $?"
cat "$LOGS/audit.log"
has audit '结论：'
# A fresh cloud image with only this tool on it: anything "suspect" is a false alarm.
if grep -F '✖ 可疑' "$LOGS/audit.log"; then fail 'the audit calls something on a clean image suspect (listed above)'; fi
# The login record of the recommended set, read back: root's key logins from
# outside (QEMU's user network shows them from 10.0.2.2), and a summary.
vm 'vps logins 5' > "$LOGS/logins.log" 2>&1 || fail "vps logins exited with $?"
cat "$LOGS/logins.log"
has logins '来源：本工具的登录记录'
has logins 'root 来自 10.0.2.2（密钥）'
grep -Eq '^  10\.0\.2\.2：[0-9]+ 次，最后一次 ' "$LOGS/logins.log" || fail 'vps logins has no summary for 10.0.2.2'
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

group 'Allowlist management: one more address, then removed again'
index="$(item_index fail2ban)" || fail 'no single item fail2ban'
allow_rules() {
  printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 3' "a 添加，d 删除，0 返回 ==> @seq $1 0" \
    '要加的 IP 或网段 ==> 192.0.2.50' '要删除第几个？ ==> 2' > "$WORK/allow-$1.rules"
}
allow_rules a
vm_drive "$WORK/allow-a.rules" allow-add vps item || fail "allowlist add exited with $?"
vm "grep -Fx 'ignoreip = 127.0.0.1/8 ::1 10.0.2.2 192.0.2.50' /etc/fail2ban/jail.d/99-vps-stable-sshd.local" || fail 'jail file not updated'
[[ "$(vm 'fail2ban-client get sshd ignoreip')" == *192.0.2.50* ]] || fail 'the running jail does not have the new address'
vm 'ufw show added' > "$LOGS/ufw-allow.log"
grep -Fxq 'ufw allow from 192.0.2.50 to any port 22 proto tcp' "$LOGS/ufw-allow.log" || fail 'the new address does not skip the SSH limit'
allow_rules d
vm_drive "$WORK/allow-d.rules" allow-delete vps item || fail "allowlist delete exited with $?"
vm "grep -Fx 'ignoreip = 127.0.0.1/8 ::1 10.0.2.2' /etc/fail2ban/jail.d/99-vps-stable-sshd.local" || fail 'address not removed from the jail file'
[[ "$(vm 'fail2ban-client get sshd ignoreip')" != *192.0.2.50* ]] || fail 'the running jail still has the removed address'
vm 'ufw show added' > "$LOGS/ufw-allow.log"
if grep -q '192.0.2.50' "$LOGS/ufw-allow.log"; then fail 'the exemption of the removed address stayed'; fi
grep -Fxq 'ufw allow from 10.0.2.2 to any port 22 proto tcp' "$LOGS/ufw-allow.log" || fail 'the remaining address lost its exemption'
endgroup

group 'From outside: the firewall really blocks, opens and closes a port, over IPv4 and IPv6'
# --bind :: (both families, IPv4 through a dual-stack socket): without it
# http.server listens on 0.0.0.0 only (the first address getaddrinfo gives).
vm 'nohup python3 -m http.server --bind :: 8080 >/dev/null 2>&1 </dev/null &'
web() { curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8080/ || true; }
# IPv6 from a network namespace on the VM: its packets come in on an interface
# of their own and go through UFW's ip6tables rules like any from outside
# (QEMU's user network forwards IPv4 only).
vm 'ip netns add ci6 && ip link add ci6-host type veth peer name ci6-peer && ip link set ci6-peer netns ci6 &&
  ip addr add fd00:6::1/64 dev ci6-host nodad && ip link set ci6-host up &&
  ip -n ci6 link set lo up && ip -n ci6 addr add fd00:6::2/64 dev ci6-peer nodad && ip -n ci6 link set ci6-peer up' ||
  fail 'no network namespace for the IPv6 check'
# shellcheck disable=SC2016
web6() { vm 'ip netns exec ci6 curl -6 -s -o /dev/null -m 5 -w "%{http_code}" "http://[fd00:6::1]:8080/"' || true; }
sleep 2
[[ -n "$(vm 'ss -H -lnt "( sport = :8080 )"')" ]] || fail 'the test web server on 8080 did not start'
[[ "$(vm 'grep -E "^IPV6=" /etc/default/ufw')" == 'IPV6=yes' ]] || fail 'UFW does not guard IPv6 here'
[[ "$(web)" != 200 ]] || fail 'port 8080 answered before it was opened'
# What the IPv6 path looks like when it fails; the run goes on, the failure
# comes at the end (so that everything after this still runs).
ipv6_why() {
  vm 'ss -H -lnt "( sport = :8080 )"; ip6tables -S 2>&1 | grep -E "8080|ufw6-user-input|-P INPUT"; ip -6 addr show dev ci6-host; ip -n ci6 -6 addr; ip -n ci6 -6 route
    ip netns exec ci6 curl -6 -sS -o /dev/null -m 5 -v "http://[fd00:6::1]:8080/" 2>&1 | tail -n 5' > "$LOGS/ipv6-why.log" 2>&1 || true
  notice "IPv6 to 8080 from the namespace ($system): $1" "$LOGS/ipv6-why.log"
  ipv6_problem="${ipv6_problem:-$1}"
}
[[ "$(web6)" != 200 ]] || ipv6_why 'port 8080 answered over IPv6 before it was opened'
vm_drive port.rules port-open vps port open 8080 tcp || fail "port open exited with $?"
[[ "$(web)" == 200 ]] || fail 'port 8080 does not answer after vps port open'
[[ "$(web6)" == 200 ]] || ipv6_why 'port 8080 does not answer over IPv6 after vps port open'
vm_drive port.rules port-close vps port close 8080 tcp || fail "port close exited with $?"
[[ "$(web)" != 200 ]] || fail 'port 8080 still answers after vps port close'
[[ "$(web6)" != 200 ]] || ipv6_why 'port 8080 still answers over IPv6 after vps port close'
vm 'pkill -f "[h]ttp.server --bind"; ip netns del ci6' || true
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

group 'From outside: the SSH rate limit holds for everyone else (what the allowlisted address skips)'
vm 'ufw show added' | grep -Fx 'ufw limit 22/tcp' > /dev/null || fail 'SSH is not rate limited although password login is on'
# Kept off Fail2ban's books for this (at runtime only, the jail file stays), so
# that only UFW decides: from the 6th new connection within 30 seconds it
# refuses the address. A ban would refuse them too and prove nothing.
vm 'fail2ban-client set sshd addignoreip 10.0.3.2' > /dev/null || fail 'cannot keep the stranger off Fail2ban for the test'
sleep 31
refused=0
for ((i = 0; i < 10; i++)); do reachable || refused=$((refused + 1)); done
vm 'fail2ban-client set sshd delignoreip 10.0.3.2' > /dev/null || true
printf 'Quick connections from the stranger refused by the rate limit: %s of 10\n' "$refused"
((refused >= 3)) || fail "the SSH rate limit did not hold: $refused of 10 quick connections refused"
endgroup

group 'Rename the machine; the display name in Chinese'
old_name="$(vm hostname)"
# The single item from the tool's own list: 2 renames, then 1 sets the display name.
index="$(item_index hostname)" || fail 'no single item hostname'
printf '%s\n' "请选择要修改的项目 ==> @seq $index $index 0" '请选择: ==> @seq 2 1' \
  '新的主机名（直接回车取消） ==> vps-ci-renamed' '把主机名从 ==> y' '新的显示名 ==> 测试机-一号' > "$WORK/rename.rules"
vm_drive "$WORK/rename.rules" rename vps item || fail "rename exited with $?"
[[ "$(vm hostname)" == vps-ci-renamed ]] || fail "hostname after the rename: $(vm hostname)"
[[ "$(vm 'head -n 1 /etc/hostname')" == vps-ci-renamed ]] || fail '/etc/hostname not renamed'
vm 'getent hosts vps-ci-renamed' > /dev/null || fail 'the new name does not resolve'
vm "grep -Fxq 'hostname: vps-ci-renamed' /etc/cloud/cloud.cfg.d/99-vps-stable-hostname.cfg" || fail 'cloud-init not told to keep the name'
vm "grep -Fxq 'display_name=测试机-一号' /var/lib/vps-stable-opt/params" || fail 'display name not saved'
endgroup

group 'Not answering ping, on through the reboot'
# UFW applies its own sysctl.conf whenever it starts, and the stock one answers
# ping (net/ipv4/icmp_echo_ignore_all=0): on a real Debian 13 VPS ping was
# answered again after every reboot, which no reboot here had covered.
index="$(item_index ping)" || fail 'no single item ping'
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1' '仍然禁止 ping 吗？ ==> y' > "$WORK/ping.rules"
vm_drive "$WORK/ping.rules" ping-on vps item || fail "ping on exited with $?"
[[ "$(vm 'sysctl -n net.ipv4.icmp_echo_ignore_all')" == 1 ]] || fail 'ping on: echo still answered'
[[ "$(vm 'ufw status | head -n 1')" == 'Status: active' ]] || fail 'the firewall is not on for the ping check'
endgroup

group 'Reboot'
vm 'systemctl reboot' || true
sleep 20
wait_ssh
check_all check-after-reboot
has check-after-reboot '开荒之后已经重启过'
# cloud-init sets the name from the seed at every boot unless told otherwise.
[[ "$(vm hostname)" == vps-ci-renamed ]] || fail "the name was changed back at boot: $(vm hostname)"
passed check-after-reboot '主机名'
passed check-after-reboot '禁止 ping'
[[ "$(vm 'sysctl -n net.ipv4.icmp_echo_ignore_all')" == 1 ]] || fail 'ping answered again after the reboot'
probe journal-probe-after-reboot
endgroup

group 'Single items only the menu has: system upgrade, old kernels, time sync, host name resolution, Fail2ban parameters'
# Each from the tool's own list; the answers are those of a user taking the
# recommendation. After the reboot an old image runs a newer kernel, so its
# old one can go.
for key in upgrade kernel ntp hosts; do
  index="$(item_index "$key")" || fail "no single item $key"
  printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1' '升级这 [0-9]+ 个软件包吗？ ==> y' '确认删除这些旧内核吗？ ==> y' '现在重启吗？ ==> n' > "$WORK/item-$key.rules"
  vm_drive "$WORK/item-$key.rules" "item-$key" vps item || fail "single item $key exited with $?"
done
grep -Eq '系统软件(已经是最新的|已升级)' "$LOGS/item-upgrade.log" || fail 'the system upgrade item did not finish'
vm 'apt-get -s upgrade --with-new-pkgs | grep -c "^Inst " || true' > "$LOGS/upgrade-left.txt"
[[ "$(cat "$LOGS/upgrade-left.txt")" == 0 ]] || fail "packages still to upgrade after the item: $(cat "$LOGS/upgrade-left.txt")"
grep -Eq '没有需要清理的旧内核|已清理 [0-9]+ 个旧内核包|保留旧内核' "$LOGS/item-kernel.log" || fail 'the old kernel item did not finish'
# shellcheck disable=SC2016
vm 'ls /boot/vmlinuz-* | grep -c "$(uname -r)"' > /dev/null || fail 'the running kernel is gone'
[[ "$(vm 'timedatectl show -p NTP --value')" == yes ]] || fail 'time synchronization not on after the item'
# shellcheck disable=SC2016
vm 'getent hosts "$(hostname)"' > /dev/null || fail 'the host name does not resolve after the item'
# Fail2ban: 3 tries instead of 5, then back to the recommendation; the running
# jail follows both times.
index="$(item_index fail2ban)" || fail 'no single item fail2ban'
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 4' '新的值 ==> @seq 3 auto' > "$WORK/f2b-params.rules"
vm_drive "$WORK/f2b-params.rules" f2b-params vps item || fail "Fail2ban parameters exited with $?"
[[ "$(vm 'fail2ban-client get sshd maxretry')" == 3 ]] || fail "the running jail does not use 3 tries: $(vm 'fail2ban-client get sshd maxretry')"
vm "grep -Fxq 'maxretry = 3' /etc/fail2ban/jail.d/99-vps-stable-sshd.local" || fail 'the jail file does not say 3 tries'
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 5' > "$WORK/f2b-reset.rules"
vm_drive "$WORK/f2b-reset.rules" f2b-reset vps item || fail "Fail2ban parameters reset exited with $?"
[[ "$(vm 'fail2ban-client get sshd maxretry')" == 5 ]] || fail "the running jail is not back at 5 tries: $(vm 'fail2ban-client get sshd maxretry')"
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

lc_mark 'after the reboot and the setups again'

group 'SSH port: 22 to 2244 from outside (the old port closed only after a login on the new one), then back'
# The single item from the tool's own list; the login that confirms stays a
# few seconds on the new port ($VM_SSH_NEW is expanded by the shell answer.exp starts).
index="$(item_index sshport)" || fail 'no single item sshport'
# shellcheck disable=SC2016
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1' '要我把这几行注释掉吗 ==> y' '新的端口 ==> 2244' '服务商那边已经放行 TCP ==> y' \
  '等待确认（剩余 ==> !$VM_SSH_NEW sleep 10' > "$LOGS/sshport-on.rules"
vm_drive "$LOGS/sshport-on.rules" sshport-on vps item || fail "the port change exited with $?"
has sshport-on 'SSH 端口已改成 2244'
has sshport-on '00-aaa-provider.conf 第 3 行：Port 22'
# Fail2ban follows the port; systemd's lines about its SysV script stay out.
if grep -q 'with SysV service script' "$LOGS/sshport-on.log"; then fail 'the port change printed the SysV lines of systemctl enable fail2ban'; fi
ssh "${VM_NEW_OPTS[@]}" "$VM_HOST" true || fail 'no login on the new port 2244'
if ssh "${VM_OPTS[@]}" -o ConnectTimeout=5 "$VM_HOST" true 2>/dev/null; then fail 'the old port 22 still lets logins in'; fi
ssh "${VM_NEW_OPTS[@]}" "$VM_HOST" 'cat /etc/ssh/sshd_config.d/00-vps-stable-port.conf; ufw show added; fail2ban-client get sshd actions >/dev/null && grep "^port" /etc/fail2ban/jail.d/99-vps-stable-sshd.local' > "$LOGS/sshport-state.txt" 2>&1 || true
cat "$LOGS/sshport-state.txt"
if ! grep -Fxq 'Port 2244' "$LOGS/sshport-state.txt" || ! grep -Fxq 'ufw limit 2244/tcp' "$LOGS/sshport-state.txt" || ! grep -Fxq 'port = 2244' "$LOGS/sshport-state.txt"; then
  fail 'sshd, the firewall or Fail2ban did not follow the new port'
fi
if grep -Eq '^ufw (allow|limit) 22/tcp$' "$LOGS/sshport-state.txt"; then fail "the firewall still lets the old port in"; fi
# Back, logged in on the new port: the old port is let in again first.
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 2' '撤销本工具对 ==> y' > "$LOGS/sshport-off.rules"
drive "$LOGS/sshport-off.rules" sshport-off ssh "${VM_NEW_OPTS[@]}" -tt "$VM_HOST" 'TERM=xterm vps item' || fail "putting the port back exited with $?"
vm true || fail 'no login on port 22 after putting the port back'
if ssh "${VM_NEW_OPTS[@]}" -o ConnectTimeout=5 "$VM_HOST" true 2>/dev/null; then fail 'port 2244 still lets logins in after putting the port back'; fi
provider_line 'Port 22' || fail "putting the port back did not put the provider's Port line back: $(vm "cat $PROVIDER_CONF")"
endgroup
group 'SSH hardening: a connection dropped mid-way puts the old settings back'
vm_drive ssh-drop.rules ssh-drop vps ssh || { rc=$?; sudo_journal; fail "ssh hardening (dropped) exited with $rc"; }
has ssh-drop '系统日志确认 ops 已用密钥登录成功'
has ssh-drop 'ops 当前已有 0 个公钥'
has ssh-drop '已关闭 SSH 密码登录'
has ssh-drop '00-aaa-provider.conf 第 2 行：PasswordAuthentication yes'
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
provider_line 'PasswordAuthentication yes' || fail "the guard timer did not put the provider's line back: $(vm "cat $PROVIDER_CONF")"
endgroup

group 'SSH hardening: key-only login, admin ops with sudo, no root login'
vm_drive ssh-apply.rules ssh-apply vps ssh || { rc=$?; sudo_journal; fail "ssh hardening exited with $rc"; }
has ssh-apply '已在系统日志里看到新窗口登录成功，自动确认'
has ssh-apply '新的 SSH 登录设置已保留'
has ssh-apply 'ops 当前已有 1 个公钥'
has ssh-apply '00-aaa-provider.conf 第 2 行：PasswordAuthentication yes'
has ssh-apply '注释掉的行保持注释'
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
# The provider writes its line back (some do at every boot): password login
# is on again, and vps check says which line of which file did it.
vm_ops_sudo cp -p "$PROVIDER_CONF" /root/provider.keep
vm_ops_sudo sed -i "'s/^#vps-stable-off(ssh,[0-9-]*): //'" "$PROVIDER_CONF"
# A connection made while sshd reloads is reset (seen on Debian 12 and the old
# Ubuntu 22.04 image): wait until ops logs in again.
ssh_back() {
  local i
  for ((i = 0; i < 30; i++)); do vm_ops true 2>/dev/null && return 0; sleep 2; done
  fail "$1: ops cannot log in after sshd reloaded"
}
vm_ops_sudo systemctl try-reload-or-restart ssh.service
ssh_back 'the provider line written back'
vm_ops_sudo vps check > "$LOGS/check-written-back.log" 2>&1 || true
grep -q '当前生效的 SSH 配置仍允许密码登录：.*00-aaa-provider.conf 第 2 行' "$LOGS/check-written-back.log" ||
  fail "vps check did not name the line written back: $(grep -m1 'SSH 登录加固' "$LOGS/check-written-back.log" || true)"
vm_ops_sudo mv -f /root/provider.keep "$PROVIDER_CONF"
vm_ops_sudo systemctl try-reload-or-restart ssh.service
ssh_back 'the provider line commented out again'
hardened 'with the provider line commented out again'
endgroup

group 'Full rollback and uninstall'
# The SSH port changed again and left so: the full rollback itself puts it back
# and must delete the rule it lets port 22 in with again (a real Debian 13 VPS
# kept "limit 22/tcp" in UFW after that; the single item above hid it, as it
# records that rule itself). The admin confirms on the new port.
index="$(item_index sshport)" || fail 'no single item sshport'
# ($ADMIN_PW is answer.exp's to expand.)
# shellcheck disable=SC2016
printf '%s\n' "请选择要修改的项目 ==> @seq $index 0" '请选择: ==> 1' '要我把这几行注释掉吗 ==> y' '新的端口 ==> 2244' '服务商那边已经放行 TCP ==> y' \
  "等待确认（剩余 ==> !ssh ${VM_NEW_OPTS[*]} $VM_OPS_HOST sleep 10" '\[sudo[^]]*\] [Pp]assword ==> $ADMIN_PW' > "$LOGS/sshport-again.rules"
VM_AS=$VM_OPS_HOST vm_drive "$LOGS/sshport-again.rules" sshport-again sudo vps item || fail "the second port change exited with $?"
has sshport-again 'SSH 端口已改成 2244'
# Root has no SSH login now: the admin rolls back (on port 2244), which brings it back.
drive rollback.rules rollback ssh "${VM_NEW_OPTS[@]}" -tt "$VM_OPS_HOST" 'TERM=xterm sudo vps rollback' || fail "rollback exited with $?"
has rollback '撤销完成'
grep -Eq '已删除本工具添加的规则：ufw (allow|limit) 22/tcp' "$LOGS/rollback.log" || fail 'the full rollback left the rule it let port 22 in with again'
has rollback '已恢复 SSH 原来的登录设置'
vm true || fail 'root cannot log in after the rollback'
[[ "$(vm "cat $PROVIDER_CONF")" == $'# A provider image (CI): read before the tool\nPasswordAuthentication yes\nPort 22' ]] ||
  fail "the full rollback did not put the provider's lines back: $(vm "cat $PROVIDER_CONF")"
lc_mark 'after the rollback (packages removed)'
[[ "$(ssh_methods root)" == *password* ]] || fail "password login not restored by the rollback: $(ssh_methods root)"
# shellcheck disable=SC2016
vm 'for f in /etc/sysctl.d/98-vps-stable-hardening.conf /etc/sysctl.d/99-vps-stable-bbr.conf /etc/sysctl.d/99-vps-stable-tcp.conf /etc/systemd/zram-generator.conf /etc/fail2ban/jail.d/99-vps-stable-sshd.local /etc/fail2ban/action.d/vps-stable-ufw-sshd.conf /etc/fail2ban/fail2ban.d/99-vps-stable.local /etc/systemd/journald.conf.d/99-vps-stable.conf; do [ ! -e "$f" ] || { echo "left: $f"; exit 1; }; done' ||
  fail 'files left after rollback'
vm 'swapon --noheadings | grep -q zram' && fail 'ZRAM still on after rollback'
# The value the tool recorded before raising it (below 1 GiB it was never
# raised, and the kernel works its default out from the free memory at boot).
if ((vm_mem >= 1024)); then
  [[ "$(vm "sysctl -n net.ipv4.tcp_rmem | awk '{print \$3}'")" == "$tcp_before" ]] || fail "the TCP receive cap is not back to $tcp_before after the rollback"
fi
vm '! grep -q login-hook /etc/pam.d/common-session && [ ! -e /usr/share/pam-configs/vps-stable-login ]' || fail 'the login record stayed after the rollback'
[[ "$(vm hostname)" == "$old_name" ]] || fail "the rollback did not bring the name $old_name back: $(vm hostname)"
vm '[ ! -e /swapfile ] && ! grep -q "^/swapfile " /proc/swaps' || fail 'the disk swap stayed after the rollback'
vm_drive uninstall.rules uninstall vps uninstall || fail "uninstall exited with $?"
vm 'command -v vps' && fail 'vps command left after uninstall'
lc_mark 'after the uninstall'
endgroup

group 'Nothing left behind: everything compared with before the install'
vm 'bash -s' < "$CI/snapshot.sh" > "$LOGS/snapshot-after.txt"
vm "bash -s '$snapshot_since'" < "$CI/upgrade-info.sh" > "$LOGS/upgrade-info.txt"
rc=0
# ops, the admin made by the SSH hardening, stays by design (with its key).
python3 "$CI/snapdiff.py" "$LOGS/snapshot-before.txt" "$LOGS/snapshot-after.txt" --upgrades "$LOGS/upgrade-info.txt" \
  --allow-user ops --purged --marks > "$LOGS/snapdiff.log" || rc=$?
cat "$LOGS/snapdiff.log"
if ((rc)); then
  { cat "$LOGS/listchanges-steps.txt"
    vm 'grep -h -i listchanges /var/log/dpkg.log /var/log/apt/history.log 2>/dev/null | tail -n 10; journalctl --no-pager -o short-precise 2>/dev/null | grep -i "apt-listchanges" | tail -n 15'
  } > "$LOGS/listchanges.log" 2>&1 || true
  notice "apt-listchanges and presets after the rollback ($system)" "$LOGS/listchanges.log"
fi
((rc == 0)) || fail 'differences after rollback and uninstall (listed above)'
endgroup
# Ctrl+C in the middle of a setup may stop it anywhere.
no_tool_errors interrupt
# Found at the IPv6 check and kept until here, so that the rest still ran.
[[ -z "${ipv6_problem:-}" ]] || fail "$ipv6_problem"
printf 'PASS: %s VM (%s MiB): setup, check, allowlisted logins, reboot, tmux reconnect, SSH hardening (dropped and kept), rollback, uninstall.\n' "$system" "$memory"
