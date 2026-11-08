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
load_optimizer_functions notify_check_text check_service_text check_timer_text check_file_write check_reconcile check_remove restore_path tg_call notify_stage \
  quota_status menu_quota_alert dockerlog_text dockerlog_merge check_dockerlog check_notify check_quota check_timer_ok verify_set audit_when audit_clean_text \
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
# alert once, a new period started on the reset day. MB are decimal (10^6
# bytes): 2 000 000 bytes are 2 MB, not 1.
printf 'iface=eth0\nquota_mb=10\nreset_day=1\nmode=both\nused_mb=7\n' > "$STATE_ROOT/quota.conf"
rm -f "$D"/traffic*; run
mb=1000000
printf 'Inter-|\n face |\n  eth0: %s 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0\n' $((1000 + mb)) $((2000 + mb)) > "$F/proc/net/dev"
: > "$T/sent"; run
[[ "$(cat "$D/traffic-used")" == 9 ]] && sent | grep -Fq '到了额度 10 MB 的 80%' && sent | grep -Fq '的 90%' || fail "traffic 80/90%: $(cat "$D/traffic-used") $(sent)"
: > "$T/sent"; run
[[ -z "$(sent)" ]] || fail "a traffic alert told twice: $(sent)"
# A reboot: the counters start again from 0.
printf 'Inter-|\n face |\n  eth0: %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' "$mb" > "$F/proc/net/dev"
: > "$T/sent"; run
[[ "$(cat "$D/traffic-used")" == 10 ]] && sent | grep -Fq '的 100%' || fail "after a reboot: $(cat "$D/traffic-used") $(sent)"
read -r used quota < <(quota_status)
[[ "$used" == 10 && "$quota" == 10 ]] || fail "quota status: $used $quota"
# Without the alert: nothing, and no failure (it is read through < <(...)).
mv "$STATE_ROOT/quota.conf" "$T/quota.conf.saved"
[[ -z "$(quota_status)" ]] && quota_status || fail 'quota status without the alert'
mv "$T/quota.conf.saved" "$STATE_ROOT/quota.conf"
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

# The summary with the acceptance check: by default only when an item failed
# (its conclusion and the failed items, at most 5); every day; or never (the
# check does not even run). Switched off: no summary, the count starts again.
summary_day() { printf '1999-01-01\n' > "$D/summary-date"; : > "$T/sent"; rm -f "$T/checked"; run; }
cat > "$T/main.sh" <<EOF
#!/bin/bash
[ "\$1" = check ] || exit 9
: > '$T/checked'
printf '\033[1m结论：\033[0m%s\n' "\$(cat '$T/conclusion')"
printf '需要你看一下：\n'
for i in 1 2 3 4 5 6; do printf '  ✖ 未生效  第 %s 项：说明\n' "\$i"; done
printf '  ⚠ 注意  转发：提醒\n\n详细：\n  ✖ 未生效  第 1 项：说明\n'
exit "\$(cat '$T/check-rc')"
EOF
printf '10 项正常，6 项未生效，0 项按计划未处理，0 项无法确认。\n' > "$T/conclusion"; printf '3\n' > "$T/check-rc"
summary_day
[[ -e "$T/checked" ]] && sent | grep -Fxq '验收：10 项正常，6 项未生效，0 项按计划未处理，0 项无法确认。' || fail "summary with a failed check: $(sent)"
[[ "$(sent | grep -c '^✖ 未生效  第 [0-9] 项：说明$')" == 5 ]] || fail "failed items in the summary: $(sent)"
if sent | grep -Fq '转发'; then fail 'a notice sent as a failed item'; fi
printf '0\n' > "$T/check-rc"; printf '16 项正常，0 项未生效。\n' > "$T/conclusion"
summary_day
[[ -e "$T/checked" ]] && sent | grep -Fq 每日汇总 || fail 'no summary when the check passed'
if sent | grep -Fq '验收'; then fail 'a passing check attached although only failures were asked for'; fi
printf 'notify_summary_check=always\n' >> "$PARAMS_FILE"; summary_day
sent | grep -Fxq '验收：16 项正常，0 项未生效。' || fail "a passing check not attached with always: $(sent)"
printf 'notify_summary_check=never\n' >> "$PARAMS_FILE"; printf '3\n' > "$T/check-rc"; summary_day
[[ ! -e "$T/checked" ]] && sent | grep -Fq 每日汇总 && ! sent | grep -Fq '验收' || fail "never: check run or attached: $(sent)"
sed -i '/^notify_summary_check=/d' "$PARAMS_FILE"
printf 'notify_summary=no\n' >> "$PARAMS_FILE"; printf '7\n' > "$D/failed"; summary_day
[[ -z "$(sent)" && ! -e "$T/checked" && "$(cat "$D/failed")" == 0 && "$(cat "$D/summary-date")" == "$(date +%F)" ]] ||
  fail "summary switched off: sent $(sent), failed $(cat "$D/failed")"
sed -i '/^notify_summary=/d' "$PARAMS_FILE"; : > "$T/main.sh"
printf 'PASS: the summary can be switched off; the acceptance check is attached when an item failed, always, or never (then not run).\n'

# Only the notifications asked for; the thresholds for CPU and memory.
printf 'notify_events=login disk\n' >> "$PARAMS_FILE"
printf '%s\troot\t203.0.113.8\tpublickey\tssh\t0\n' "$(($(date +%s) + 20))" >> "$STATE_ROOT/logins"
printf '%s.1 host useradd[1]: new user: name=intruder, UID=1009\n' "$(date +%s)" > "$T/journal"
printf 'boot-3\n' > "$F/proc/sys/kernel/random/boot_id"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq '登录：root 来自 203.0.113.8' || fail "a login asked for not sent: $(sent)"
if sent | grep -Fq '开机了' || sent | grep -Fq '新建了账户'; then fail "notifications not asked for were sent: $(sent)"; fi
sed -i '/^notify_events=/d' "$PARAMS_FILE"; : > "$T/journal"
# CPU: 50% and above for 5 minutes (one check); memory: under 50% available.
printf 'notify_cpu_percent=50\nnotify_cpu_minutes=5\nnotify_mem_percent=50\n' >> "$PARAMS_FILE"
printf 'cpu 100 0 100 800 0 0 0 0 0 0\n' > "$F/proc/stat"; rm -f "$D/five" "$D/cpu" "$D/cpu-hot" "$D/flag-cpu"; run
printf 'cpu 700 0 100 1200 0 0 0 0 0 0\n' > "$F/proc/stat"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq 'CPU 已经连续 5 分钟以上占用 50% 以上（现在 60%）' || fail "CPU threshold: $(sent)"
if sent | grep -Fq '内存快不够了'; then fail 'memory told with 60% available'; fi
printf 'MemTotal: 1000000 kB\nMemAvailable: 400000 kB\n' > "$F/proc/meminfo"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq '内存快不够了：只剩 40% 可用' || fail "memory threshold: $(sent)"
printf 'MemTotal: 1000000 kB\nMemAvailable: 600000 kB\n' > "$F/proc/meminfo"
sed -i '/^notify_cpu_percent=/d; /^notify_cpu_minutes=/d; /^notify_mem_percent=/d' "$PARAMS_FILE"
# The timer every 30 minutes, rarer than these checks' 5: one busy check (a
# 30-minute average) already covers the 10 minutes asked for, and says 30.
printf 'notify_cpu_percent=50\ncheck_minutes_tg=30\n' >> "$PARAMS_FILE"
printf 'cpu 100 0 100 800 0 0 0 0 0 0\n' > "$F/proc/stat"; rm -f "$D/five" "$D/cpu" "$D/cpu-hot" "$D/flag-cpu"; run
printf 'cpu 700 0 100 1200 0 0 0 0 0 0\n' > "$F/proc/stat"; rm -f "$D/five"; : > "$T/sent"; run
sent | grep -Fq 'CPU 已经连续 30 分钟以上占用 50% 以上（现在 60%）' || fail "CPU with the timer every 30 minutes: $(sent)"
sed -i '/^notify_cpu_percent=/d; /^check_minutes_tg=/d' "$PARAMS_FILE"
printf 'PASS: only the notifications asked for are sent; the CPU and memory thresholds are parameters, the CPU minutes counted as the checks really run.\n'

# The checks of what was done on the machine, every 10 minutes when asked.
printf 'notify_events_minutes=10\n' >> "$PARAMS_FILE"
past=$(($(date +%s) - 400)); printf '%s\n' "$past" > "$D/five"; : > "$T/sent"; run
[[ "$(cat "$D/five")" == "$past" ]] || fail 'the checks ran after 400 s although every 10 minutes was asked for'
sed -i '/^notify_events_minutes=/d' "$PARAMS_FILE"; run
[[ "$(cat "$D/five")" != "$past" ]] || fail 'the checks did not run after 400 s by default (every 5 minutes)'
printf 'PASS: the checks of what was done on the machine run at the interval asked for.\n'

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
# Limited in time; long enough for the acceptance check of the daily summary (60 s).
grep -Fq "ExecStart=/usr/bin/timeout 110 /bin/bash $STATE_ROOT/notify-check" "$CHECK_SERVICE_FILE" || fail 'the check is not limited in time'
# vps check: the check has stopped when it missed its interval and 9 minutes
# more (10 minutes every minute; 39 every 30 minutes).
: > "$D/queue"
printf '%s\n' "$(($(date +%s) - 300))" > "$D/last-run"; check_notify
[[ "$VERIFY_STATUS" == pass ]] || fail "a check 5 minutes ago: $VERIFY_STATUS $VERIFY_TEXT"
printf '%s\n' "$(($(date +%s) - 1200))" > "$D/last-run"; check_notify
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'超过 10 分钟没跑了'* ]] || fail "a check 20 minutes ago, every minute: $VERIFY_STATUS $VERIFY_TEXT"
printf 'check_minutes_tg=30\n' >> "$PARAMS_FILE"; check_notify
[[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *'每 30 分钟检查一次'* ]] || fail "a check 20 minutes ago, every 30 minutes: $VERIFY_STATUS $VERIFY_TEXT"
printf '%s\n' "$(($(date +%s) - 2400))" > "$D/last-run"; check_notify
[[ "$VERIFY_STATUS" == fail && "$VERIFY_TEXT" == *'超过 39 分钟没跑了'* ]] || fail "a check 40 minutes ago, every 30 minutes: $VERIFY_STATUS $VERIFY_TEXT"
sed -i '/^check_minutes_tg=/d' "$PARAMS_FILE"
# Other intervals when the parameters say so (this tool's timer is written again).
printf 'check_minutes_tg=3\ncheck_minutes_quota=10\n' >> "$PARAMS_FILE"
reset; check_reconcile
grep -Fxq 'OnCalendar=*:0/3' "$CHECK_TIMER_FILE" || fail "timer with TG every 3 minutes: $(cat "$CHECK_TIMER_FILE")"
mv "$STATE_ROOT/notify.conf" "$T/notify.conf.saved"
reset; check_reconcile
grep -Fxq 'OnCalendar=*:0/10' "$CHECK_TIMER_FILE" || fail "timer for traffic only every 10 minutes: $(cat "$CHECK_TIMER_FILE")"
sed -i '/^check_minutes_tg=/d; /^check_minutes_quota=/d' "$PARAMS_FILE"
reset; check_reconcile
grep -Fxq 'OnCalendar=*:0/5' "$CHECK_TIMER_FILE" || fail "timer for traffic only: $(cat "$CHECK_TIMER_FILE")"
rm -f "$STATE_ROOT/quota.conf"
reset; check_reconcile
[[ ! -e "$CHECK_TIMER_FILE" && ! -e "$CHECK_SERVICE_FILE" && ! -e "$STATE_ROOT/notify-check" && ! -e "$D" ]] && grep -Fxq 'systemctl disable --now vps-stable-check.timer' "$TEST_ROOT/trace" ||
  fail "timer not taken away: $(cat "$TEST_ROOT/trace")"
# A unit someone changed stays; one an earlier version wrote (what this tool
# last wrote, its text older than this version's) goes.
mkdir -p "$T/units"; printf '[Timer]\nOnCalendar=hourly\n' > "$CHECK_TIMER_FILE"
restore_file_ours() { return 1; }
reset; check_remove
[[ -f "$CHECK_TIMER_FILE" ]] && grep -q '被改过' "$TEST_ROOT/log" || fail 'a changed unit was removed'
restore_file_ours() { [[ "$1" == check_timer_file ]]; }
reset; check_remove
[[ ! -e "$CHECK_TIMER_FILE" ]] && ! grep -q '被改过' "$TEST_ROOT/log" || fail "the unit an earlier version wrote stayed"
restore_file_ours() { return 0; }
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
# The chat is found in any JSON layout.
rm -f "$STATE_ROOT/notify.conf"; TG_UPDATES='{"ok": true, "result": [{"update_id": 2, "message": {"chat": {"id": -100123, "type": "group"}}}]}'
reset; printf '123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq\n\n' | notify_stage > /dev/null
grep -Fxq 'chat=-100123' "$STATE_ROOT/notify.conf" || fail "chat in spaced JSON: $(cat "$STATE_ROOT/notify.conf" 2>&1)"
rm -f "$STATE_ROOT/notify.conf"; TG_SEND=1
reset; printf '123456789:AAbbccddeeffgghhiijjkkllmmnnooppqq\n\n' | notify_stage > /dev/null
grep -q '^result notify failed test message failed' "$TEST_ROOT/trace" && [[ ! -e "$STATE_ROOT/notify.conf" ]] || fail 'a failed test message still saved the settings'
printf 'PASS: TG checks the token, finds the chat, sends a test and keeps the settings for root only.\n'

# The traffic alert's questions (its interface looked up in the fixture).
eval "$(awk '$0 == "quota_stage() {" {c = 1} c {print} c && $0 == "}" {exit}' "$TEST_SCRIPT" | sed -e "s#/proc/#$F/proc/#g")"
ip() { echo '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2 uid 0'; }
reset; QUOTA_CHOICE=1
quota_stage <<< $'1000\n15\n2\n12.5' > /dev/null
[[ "$(cat "$STATE_ROOT/quota.conf")" == $'iface=eth0\nquota_mb=1000000\nreset_day=15\nmode=both\nused_mb=12500' ]] || fail "quota settings: $(cat "$STATE_ROOT/quota.conf")"
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

# Docker's acceptance line: in force only once Docker started after daemon.json
# was written (its default log driver, json-file, proves nothing).
DOCKER_DAEMON_FILE="$T/daemon.json"; dockerlog_text > "$DOCKER_DAEMON_FILE"
read -r up _ < /proc/uptime; boot=$(($(date +%s) - ${up%%.*}))
DOCKER_ON=1 DOCKER_MONO=''
active() { [[ "$1" == docker ]] && ((DOCKER_ON)); }
systemctl() { if [[ "$*" == 'show docker -p ActiveEnterTimestampMonotonic --value' ]]; then echo "$DOCKER_MONO"; fi; }
docker() { if [[ "$*" == 'info --format {{.LoggingDriver}}' ]]; then echo json-file; fi; }
# Docker started 5 seconds after the boot (systemd counts in microseconds
# since then); a CI machine may have booted only minutes ago.
DOCKER_MONO=5000000
touch -d "@$(date +%s)" "$DOCKER_DAEMON_FILE"
check_dockerlog; [[ "$VERIFY_STATUS" == update && "$VERIFY_TEXT" == *'还没重启'* ]] || fail "written after Docker started: $VERIFY_STATUS $VERIFY_TEXT"
touch -d "@$((boot - 100))" "$DOCKER_DAEMON_FILE"
check_dockerlog; [[ "$VERIFY_STATUS" == pass ]] || fail "Docker started after the file was written: $VERIFY_STATUS $VERIFY_TEXT"
DOCKER_ON=0
check_dockerlog; [[ "$VERIFY_STATUS" == pass && "$VERIFY_TEXT" == *'启动时就会用上'* ]] || fail "Docker not running: $VERIFY_STATUS $VERIFY_TEXT"
DOCKER_ON=1 DOCKER_MONO=''
check_dockerlog; [[ "$VERIFY_STATUS" == unknown ]] || fail "no start time: $VERIFY_STATUS $VERIFY_TEXT"
unset -f active systemctl docker
printf 'PASS: the Docker line is in force only once Docker started after daemon.json was written.\n'

# The new parameters.
for good in 'notify_services xray nginx' 'notify_services none' 'quota_alerts 50 100' 'notify_summary_time 23:59' 'notify_disk_percent 80' 'docker_log_files 5' \
    'notify_summary no' 'notify_summary_check always' 'notify_events all' 'notify_events login console traffic' 'notify_cpu_percent 100' 'notify_cpu_minutes 5' 'notify_mem_percent 50'; do
  param_check ${good%% *} "${good#* }" > /dev/null || fail "refused: $good"
done
for bad in 'notify_services x;y' 'quota_alerts 0' 'quota_alerts 101' 'notify_summary_time 24:00' 'notify_disk_percent 100' 'notify_sudo_args maybe' 'docker_log_max_mb 0' \
    'notify_summary maybe' 'notify_summary_check sometimes' 'notify_events login;id' 'notify_events logins' 'notify_cpu_percent 49' 'notify_cpu_minutes 4' 'notify_mem_percent 0' 'notify_mem_percent 51'; do
  if param_check ${bad%% *} "${bad#* }" > /dev/null; then fail "accepted: $bad"; fi
done
[[ -n "$(param_caution notify_sudo_args yes)" ]] || fail 'whole sudo commands not explained'
printf 'PASS: the notification, traffic and Docker parameters are checked.\n'
