#!/usr/bin/env bash
# TG notifications, the monthly traffic alert and Docker's log limit. The check
# script is run for real (generated text, fixtures for /proc and the logs, fake
# system commands and a fake Telegram on PATH); turning things on and off, and
# the timer, with mocks.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions notify_check_text check_service_text check_timer_text check_file_write check_reconcile check_remove tg_call notify_stage \
  quota_status menu_quota_alert dockerlog_text dockerlog_merge check_notify check_quota check_timer_ok verify_set audit_when audit_clean_text \
  param_list param_kind param_recommended param_check param_read param_value param_caution
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
record() { printf '%s\n' "$*" >> "$TEST_ROOT/trace"; }
reset() { : > "$TEST_ROOT/trace"; : > "$TEST_ROOT/log"; }
module_result() { record "result $1 $2 ${3:-}"; }
T="$TEST_ROOT" F="$TEST_ROOT/fs" B="$TEST_ROOT/bin"
STATE_ROOT="$T/state" PARAMS_FILE="$T/state/params"
mkdir -p "$STATE_ROOT" "$F/proc/sys/kernel/random" "$F/proc/net" "$F/systemd" "$F/cron.d" "$B" "$T/home/root/.ssh"
: > "$T/main.sh"

# The check as the timer runs it, on the fixtures.
notify_check_text | sed -e "s#/usr/local/lib/vps-stable-opt/vps-stable-opt.sh#$T/main.sh#" -e "s#/proc/#$F/proc/#g" \
  -e "s#/var/log/dpkg.log#$F/dpkg.log#g" -e "s#/var/run/reboot-required#$F/reboot-required#g" -e "s#/etc/systemd/system#$F/systemd#g" \
  -e "s#/etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs#$F/cron.d#" > "$T/check"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
# Telegram: the config (with the token) from stdin, the message from its file.
stub curl "[ -e '$T/offline' ] && exit 7
cat > '$T/curl-stdin'; printf '%s\n' \"\$*\" >> '$T/curl-args'
for a in \"\$@\"; do case \"\$a\" in text@*) cat \"\${a#text@}\" >> '$T/sent'; echo '--' >> '$T/sent' ;; esac; done"
stub journalctl "if [ \"\$*\" = '-q -n 1 --show-cursor -o cat --no-pager' ]; then echo x; echo '-- cursor: c0'; exit 0; fi
cat '$T/journal' 2>/dev/null; echo \"-- cursor: c\$(date +%s%N)\""
stub ss "cat '$T/ss' 2>/dev/null"
stub getent "echo 'root:x:0:0::$T/home/root:/bin/bash'"
stub ssh-keygen "cat '$T/keys' 2>/dev/null"
stub df "printf 'h\n/dev/vda1 100 %s 0 %s%% /\n' \"\$(cat '$T/disk')\" \"\$(cat '$T/disk')\""
stub ps "echo 'miner 4242'"
stub systemctl "echo active"
stub fail2ban-client "echo '192.0.2.9'"
stub hostname "echo vps1"
if ! command -v flock > /dev/null; then stub flock 'exit 0'; fi
printf 'boot-1\n' > "$F/proc/sys/kernel/random/boot_id"
printf 'cpu 100 0 100 800 0 0 0 0 0 0\n' > "$F/proc/stat"
printf 'MemTotal: 1000000 kB\nMemAvailable: 600000 kB\n' > "$F/proc/meminfo"
printf '1000.0 2000.0\n' > "$F/proc/uptime"
printf 'Inter-|\n face |\n  eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n' > "$F/proc/net/dev"
printf '40\n' > "$T/disk"
: > "$F/dpkg.log"
run() { env -i PATH="$B:$PATH" HOME="$T" /bin/bash "$T/check"; }
sent() { cat "$T/sent" 2>/dev/null; }
D="$STATE_ROOT/notify"
printf 'token=123456:SECRET-TOKEN-abcdefghijklmnopqrstu\nchat=4242\napi=http://tg.test\nip=203.0.113.1\n' > "$STATE_ROOT/notify.conf"
printf 'display_name=东京-1\n' > "$PARAMS_FILE"

# The first run starts from now: nothing old is sent, no summary.
t0=$(($(date +%s) - 100))
printf '%s\troot\t203.0.113.5\tpublickey\tssh\t0\n' "$t0" > "$STATE_ROOT/logins"
printf '2026-01-01 10:00:00 install old:amd64 <none> 1\n' > "$F/dpkg.log"
printf '1700000000.1 host useradd[1]: new user: name=old, UID=1001\n' > "$T/journal"
run
[[ -z "$(sent)" ]] || fail "the first run sent something: $(sent)"
[[ -f "$D/last-run" && -f "$D/boot" && -f "$D/dpkg.off" ]] || fail 'the first run left no state'
printf 'PASS: the first run starts from now and sends nothing old.\n'

# A login: within a minute, with the machine's name and address; a first-time
# address with what to do. The token goes to curl through stdin only. It is
# in the same second as the last one handled (found on CI, where runs are fast).
now="$(date +%s)"
printf '%s\troot\t198.51.100.7\tpassword\tssh\t1\n' "$t0" >> "$STATE_ROOT/logins"
: > "$T/journal"
run
sent | grep -Fq '【东京-1 · 203.0.113.1】' && sent | grep -Fq '登录：root 来自 198.51.100.7（密码，' && sent | grep -Fq '第一次从这个 IP 登录' || fail "login message: $(sent)"
grep -Fq 'url = "http://tg.test/bot123456:SECRET-TOKEN-abcdefghijklmnopqrstu/sendMessage"' "$T/curl-stdin" || fail "curl config: $(cat "$T/curl-stdin")"
if grep -Fq SECRET-TOKEN "$T/curl-args"; then fail 'the token was on the command line'; fi
grep -Fq 'chat_id=4242' "$T/curl-args" || fail 'chat id not sent'
: > "$T/sent"; run
[[ -z "$(sent)" ]] || fail "a login was sent twice: $(sent)"
printf 'PASS: a login is sent at the next run with the machine name, and the token never reaches the command line.\n'

# Every 5 minutes: accounts, passwords, sudo (the program only), packages,
# keys, ports, things that start by themselves; failures only counted.
rm -f "$D/five"
printf '%s.1 host useradd[1]: new user: name=backup, UID=0\n%s.2 host passwd[2]: pam_unix(passwd:chauthtok): password changed for root\n' "$now" "$now" > "$T/journal"
printf '%s.3 host sudo[3]: ops : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/bin/mysql -pHunter2\n' "$now" >> "$T/journal"
printf '%s.4 host sshd[4]: Failed password for root from 192.0.2.9 port 1 ssh2\n%s.5 host sshd[5]: Invalid user x from 192.0.2.9 port 2\n' "$now" "$now" >> "$T/journal"
printf '%s.6 host kernel: Out of memory: Killed process 777 (java) total-vm:1kB\n' "$now" >> "$T/journal"
printf '2026-11-02 10:00:00 install nmap:amd64 <none> 7\n2026-11-02 10:00:01 upgrade bash:amd64 5.1 5.2\n2026-11-02 10:00:02 remove telnet:amd64 1 <none>\n' >> "$F/dpkg.log"
printf '256 SHA256:newkey laptop (ED25519)\n' > "$T/keys"; : > "$T/home/root/.ssh/authorized_keys"
printf 'tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=9,fd=3))\n' > "$T/ss"
printf '[Service]\n' > "$F/systemd/miner.service"
: > "$T/sent"; run
for want in '新建了账户：backup' '改了密码：账户 root' 'sudo：ops 运行了 /usr/bin/mysql' '内存不够：系统杀掉了进程 java' '装了软件包：nmap' '删了软件包：telnet' \
    '加了公钥：账户 root，SHA256:newkey（laptop）' '新开了端口：8080/tcp（nginx）' "新加了开机自启或定时任务：$F/systemd/miner.service"; do
  sent | grep -Fq "$want" || fail "missing: $want in $(sent)"
done
if sent | grep -Fq Hunter2; then fail 'a sudo argument (a password) was sent'; fi
if sent | grep -Fq 'Failed password'; then fail 'failed logins were sent one by one'; fi
[[ "$(cat "$D/failed")" == 2 ]] || fail "failed logins not counted: $(cat "$D/failed")"
if sent | grep -Fq bash; then fail 'an upgrade was sent as a new package'; fi
# Shown in full only when asked.
printf 'notify_sudo_args=yes\n' >> "$PARAMS_FILE"; rm -f "$D/five"
printf '%s.3 host sudo[3]: ops : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/bin/apt install x\n' "$now" > "$T/journal"
: > "$T/sent"; run
sent | grep -Fq 'sudo：ops 运行了 /usr/bin/apt install x' || fail "full sudo command: $(sent)"
sed -i '/^notify_sudo_args=/d' "$PARAMS_FILE"; : > "$T/journal"
printf 'PASS: accounts, passwords, sudo without its arguments, packages, keys, ports and autostart are sent; failures only counted.\n'

# Told once: a full disk, until it is well below the line again; a reboot.
printf '95\n' > "$T/disk"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq '系统盘快满了：已用 95%' || fail "full disk: $(sent)"
printf '92\n' > "$T/disk"; rm -f "$D/five"; : > "$T/sent"; run
[[ -z "$(sent)" ]] || fail "a full disk told twice: $(sent)"
printf '80\n' > "$T/disk"; rm -f "$D/five"; run; printf '95\n' > "$T/disk"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq '系统盘快满了' || fail 'a disk full again not told'
printf '40\n' > "$T/disk"
printf 'boot-2\n' > "$F/proc/sys/kernel/random/boot_id"; : > "$T/sent"; run
sent | grep -Fq '开机了：上次检查在' || fail "boot: $(sent)"
printf 'PASS: a full disk is told once until it goes well below the line; a reboot is told.\n'

# Offline: kept and sent later, each once.
touch "$T/offline"
printf '%s\troot\t203.0.113.5\tpublickey\tssh\t0\n' "$(($(date +%s) + 5))" >> "$STATE_ROOT/logins"
: > "$T/sent"; run
[[ -z "$(sent)" && "$(grep -c . "$D/queue")" == 1 ]] || fail "offline: queue $(cat "$D/queue" 2>&1)"
rm -f "$T/offline"; run
[[ "$(grep -c '登录：root 来自 203.0.113.5' "$T/sent")" == 1 && ! -s "$D/queue" ]] || fail "not sent once when back online: $(sent)"
printf 'PASS: messages wait while offline and go out once when the network is back.\n'

# The tool gone: the check stops quietly.
rm -f "$T/main.sh"; printf '%s\troot\t203.0.113.6\tpublickey\tssh\t0\n' "$(($(date +%s) + 9))" >> "$STATE_ROOT/logins"
: > "$T/sent"; run
[[ -z "$(sent)" ]] || fail 'the check ran without the tool'
: > "$T/main.sh"
printf 'PASS: without the tool the check does nothing.\n'

# Traffic: counters added up between runs, a reboot's reset counted, each
# alert once, a new period started on the reset day.
printf 'iface=eth0\nquota_mb=10\nreset_day=1\nmode=both\nused_mb=7\n' > "$STATE_ROOT/quota.conf"
rm -f "$D"/traffic*; run
mib=1048576
printf 'Inter-|\n face |\n  eth0: %s 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0\n' $((1000 + mib)) $((2000 + mib)) > "$F/proc/net/dev"
: > "$T/sent"; run
[[ "$(cat "$D/traffic-used")" == 9 ]] && sent | grep -Fq '到了额度 10 MB 的 80%' && sent | grep -Fq '的 90%' || fail "traffic 80/90%: $(cat "$D/traffic-used") $(sent)"
: > "$T/sent"; run
[[ -z "$(sent)" ]] || fail "a traffic alert told twice: $(sent)"
# A reboot: the counters start again from 0.
printf 'Inter-|\n face |\n  eth0: %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' "$mib" > "$F/proc/net/dev"
: > "$T/sent"; run
[[ "$(cat "$D/traffic-used")" == 10 ]] && sent | grep -Fq '的 100%' || fail "after a reboot: $(cat "$D/traffic-used") $(sent)"
read -r used quota < <(quota_status)
[[ "$used" == 10 && "$quota" == 10 ]] || fail "quota status: $used $quota"
[[ "$(menu_quota_alert)" == *'是额度 0 GB 的 100%'* ]] || fail "menu: $(menu_quota_alert)"
# A new period: from 0, the starting value gone, the alerts ready again.
read -r period rest < "$D/traffic"; printf '1999-01-01 %s\n' "$rest" > "$D/traffic"
: > "$T/sent"; run
sent | grep -Fq '新的流量周期从' && [[ "$(cat "$D/traffic-used")" == 0 ]] && ! grep -q '^used_mb=' "$STATE_ROOT/quota.conf" || fail "new period: $(cat "$D/traffic-used") $(sent)"
printf 'PASS: traffic is added up across reboots, each alert is sent once, a new period starts from zero.\n'

# The daily summary, with the failed logins, once a day after its time.
printf '0\n' > "$D/failed"; printf '5\n' > "$D/failed"
printf 'notify_summary_time=00:00\n' >> "$PARAMS_FILE"; printf '1999-01-01\n' > "$D/summary-date"
: > "$T/sent"; run
sent | grep -Fq '每日汇总（过去 24 小时）' && sent | grep -Fq '失败的登录：5 次；Fail2ban 正在封禁 1 个 IP' || fail "summary: $(sent)"
: > "$T/sent"; run
if sent | grep -Fq 每日汇总; then fail 'a second summary the same day'; fi
printf 'PASS: the daily summary carries the failed logins, once a day.\n'

# The timer: every minute with TG, every 5 minutes for the traffic alert only,
# gone with neither; quiet in the journal.
put_file() { [[ ! -e "$1" ]] || [[ "$(cat "$1")" == "$2" ]] || return 1; mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" > "$1"; }
restore_file_ours() { return 0; }
restore_adopt() { record "adopt $1"; }
systemctl() { record "systemctl $*"; case "$*" in 'is-enabled vps-stable-check.timer') [[ -f "$CHECK_TIMER_FILE" ]] && echo enabled ;; 'is-active -q vps-stable-check.timer') [[ -f "$CHECK_TIMER_FILE" ]] ;; esac; }
CHECK_SERVICE_FILE="$T/units/vps-stable-check.service" CHECK_TIMER_FILE="$T/units/vps-stable-check.timer" RESTORE_STAGE=''
reset; check_reconcile
grep -Fxq 'OnCalendar=*:0/1' "$CHECK_TIMER_FILE" && grep -Fxq 'LogLevelMax=notice' "$CHECK_SERVICE_FILE" && [[ "$(cat "$STATE_ROOT/notify-check")" == "$(notify_check_text)" ]] ||
  fail "timer with TG: $(cat "$CHECK_TIMER_FILE")"
grep -Fxq 'systemctl enable --now vps-stable-check.timer' "$TEST_ROOT/trace" && grep -Fxq 'adopt check_timer_file' "$TEST_ROOT/trace" || fail "timer not started or adopted: $(cat "$TEST_ROOT/trace")"
grep -Fq "ExecStart=/usr/bin/timeout 50 /bin/bash $STATE_ROOT/notify-check" "$CHECK_SERVICE_FILE" || fail 'the check is not limited in time'
mv "$STATE_ROOT/notify.conf" "$T/notify.conf.saved"
reset; check_reconcile
grep -Fxq 'OnCalendar=*:0/5' "$CHECK_TIMER_FILE" || fail "timer for traffic only: $(cat "$CHECK_TIMER_FILE")"
rm -f "$STATE_ROOT/quota.conf"
reset; check_reconcile
[[ ! -e "$CHECK_TIMER_FILE" && ! -e "$CHECK_SERVICE_FILE" && ! -e "$STATE_ROOT/notify-check" && ! -e "$D" ]] && grep -Fxq 'systemctl disable --now vps-stable-check.timer' "$TEST_ROOT/trace" ||
  fail "timer not taken away: $(cat "$TEST_ROOT/trace")"
# A unit someone changed stays.
mkdir -p "$T/units"; printf '[Timer]\nOnCalendar=hourly\n' > "$CHECK_TIMER_FILE"
reset; check_remove
[[ -f "$CHECK_TIMER_FILE" ]] && grep -q '被改过' "$TEST_ROOT/log" || fail 'a changed unit was removed'
rm -f "$CHECK_TIMER_FILE"
printf 'PASS: the timer runs every minute with TG, every 5 minutes for traffic only, and goes when neither is on.\n'

# Turning TG on: the format of the token, the chat found from the message sent
# to the bot, a test message, the settings only root can read.
mv "$T/notify.conf.saved" "$STATE_ROOT/notify.conf"; rm -f "$STATE_ROOT/notify.conf"
display_name_get() { echo 东京-1; }
menu_ip() { echo 203.0.113.1; }
confirm_yes() { return 1; }
TG_UPDATES='{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":987654,"type":"private"},"text":"hi"}}]}' TG_SEND=0
tg_call() { record "tg $3 $(cat)"; case "$3" in getUpdates) echo "$TG_UPDATES" ;; sendMessage) return "$TG_SEND" ;; esac; }
# The test containers have no curl: TG needs it to be there (tg_call answers).
curl() { :; }
check_reconcile() { record reconcile; }
reset; NOTIFY_CHOICE=1
printf 'not-a-token\n' | notify_stage
grep -q '^result notify failed bad token' "$TEST_ROOT/trace" && [[ ! -e "$STATE_ROOT/notify.conf" ]] || fail 'a bad token accepted'
reset; printf '123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq\n\n' | notify_stage > "$T/out"
grep -Fxq 'chat=987654' "$STATE_ROOT/notify.conf" && grep -Fxq 'token=123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq' "$STATE_ROOT/notify.conf" &&
  grep -q '^result notify applied' "$TEST_ROOT/trace" && grep -Fxq reconcile "$TEST_ROOT/trace" || fail "TG on: $(cat "$TEST_ROOT/trace")"
[[ "$(stat -c %a "$STATE_ROOT/notify.conf")" == 600 ]] || [[ "$(uname -o 2>/dev/null)" == Msys ]] || fail 'the TG settings are readable by others'
if grep -Fq AAbbccdd "$T/out"; then fail 'the token was shown'; fi
rm -f "$STATE_ROOT/notify.conf"; TG_SEND=1
reset; printf '123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq\n\n' | notify_stage > /dev/null
grep -q '^result notify failed test message failed' "$TEST_ROOT/trace" && [[ ! -e "$STATE_ROOT/notify.conf" ]] || fail 'a failed test message still saved the settings'
printf 'PASS: TG checks the token, finds the chat, sends a test and keeps the settings for root only.\n'

# The traffic alert's questions (its interface looked up in the fixture).
eval "$(awk '$0 == "quota_stage() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/proc/#$F/proc/#g")"
ip() { echo '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2 uid 0'; }
reset; QUOTA_CHOICE=1
quota_stage <<< $'1000\n15\n2\n12.5' > /dev/null
[[ "$(cat "$STATE_ROOT/quota.conf")" == $'iface=eth0\nquota_mb=1024000\nreset_day=15\nmode=both\nused_mb=12800' ]] || fail "quota settings: $(cat "$STATE_ROOT/quota.conf")"
reset; quota_stage <<< $'1000\n32\n1\n' > /dev/null
grep -q '^result quota declined bad day' "$TEST_ROOT/trace" || fail 'reset day 32 accepted'
printf 'PASS: the traffic alert takes the quota, the reset day, the mode and what is used already.\n'

# Docker: the limits from the parameters, merged into an existing daemon.json.
printf 'docker_log_max_mb=20\n' >> "$PARAMS_FILE"
[[ "$(dockerlog_text)" == *'"max-size": "20m"'* && "$(dockerlog_text)" == *'"max-file": "3"'* ]] || fail "daemon.json text: $(dockerlog_text)"
if command -v python3 > /dev/null && python3 -c 1 > /dev/null 2>&1; then
  DOCKER_DAEMON_FILE="$T/daemon.json"; backup_config_path() { :; }
  printf '{"data-root": "/srv/docker", "log-opts": {"max-size": "1g"}}\n' > "$DOCKER_DAEMON_FILE"
  dockerlog_merge || fail 'merge failed'
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["data-root"] == "/srv/docker" and d["log-opts"] == {"max-size": "20m", "max-file": "3"} and d["log-driver"] == "json-file", d' "$DOCKER_DAEMON_FILE" ||
    fail "merged: $(cat "$DOCKER_DAEMON_FILE")"
  printf 'not json\n' > "$DOCKER_DAEMON_FILE"
  if dockerlog_merge 2> /dev/null; then fail 'a broken daemon.json was overwritten'; fi
  grep -Fxq 'not json' "$DOCKER_DAEMON_FILE" || fail 'a broken daemon.json was changed'
  printf 'PASS: Docker log limits follow the parameters and keep the rest of daemon.json.\n'
else
  printf 'PASS (partly): Docker log limits follow the parameters; no python3 here for the merge.\n'
fi

# The new parameters.
for good in 'notify_services xray nginx' 'notify_services none' 'quota_alerts 50 100' 'notify_summary_time 23:59' 'notify_disk_percent 80' 'docker_log_files 5'; do
  param_check ${good%% *} "${good#* }" > /dev/null || fail "refused: $good"
done
for bad in 'notify_services x;y' 'quota_alerts 0' 'quota_alerts 101' 'notify_summary_time 24:00' 'notify_disk_percent 100' 'notify_sudo_args maybe' 'docker_log_max_mb 0'; do
  if param_check ${bad%% *} "${bad#* }" > /dev/null; then fail "accepted: $bad"; fi
done
[[ -n "$(param_caution notify_sudo_args yes)" ]] || fail 'whole sudo commands not explained'
printf 'PASS: the notification, traffic and Docker parameters are checked.\n'
