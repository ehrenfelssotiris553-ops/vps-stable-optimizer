#!/usr/bin/env bash
# VPS Stable Optimizer v2.7.8 — tracked configuration restore and tool cleanup
# Supports Debian 12/13, Ubuntu 22.04/24.04/26.04 on systemd VMs.
# Review locally before running as root. Opening the menu does not apply optimization.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none LC_ALL=C
umask 077

SCRIPT_VERSION=2.7.8
MODE="${1:-menu}"
MODE_ARGS=("${@:2}")
JOURNAL_LIMIT_GB=20           # Set journal caps only when root disk <= 20 GiB
# Inside the root-only state directory: Ubuntu's /var/log is group-writable
# (root:syslog 775), which no root-written path may sit under.
LOG_DIR=/var/lib/vps-stable-opt/logs
# Where versions before 2.7.4 kept their logs; only removed on uninstall.
LEGACY_LOG_DIR=/var/log/vps-stable-opt
BBR_FILE=/etc/sysctl.d/99-vps-stable-bbr.conf
MODULE_FILE=/etc/modules-load.d/99-vps-stable-bbr.conf
ZRAM_FILE=/etc/systemd/zram-generator.conf
# SSH keepalive: before cloud-init's 50- file (sshd keeps the first value).
# sshd takes the first value it reads: 00- comes before the drop-ins of the
# SSH hardening (01-, which set ClientAliveInterval 300 before 2.8.0) and of
# cloud images (50-).
KEEPALIVE_FILE=/etc/ssh/sshd_config.d/00-vps-stable-keepalive.conf
# Preferring IPv4 in getaddrinfo (IPv6 stays on).
GAI_FILE=/etc/gai.conf
# The time of the daily security upgrade, when changed from the distribution's.
APT_TIME_FILE=/etc/systemd/system/apt-daily-upgrade.timer.d/50-vps-stable-time.conf
# Connection tracking capacity, and the module loaded before systemd-sysctl
# (otherwise UFW loads it later at boot and the values never apply).
CONNTRACK_FILE=/etc/sysctl.d/99-vps-stable-conntrack.conf
CONNTRACK_MODULE_FILE=/etc/modules-load.d/99-vps-stable-conntrack.conf
# Not answering ping (optional).
PING_FILE=/etc/sysctl.d/99-vps-stable-noping.conf
# Disk swap (only where no other swap exists): the file and its systemd unit.
SWAP_FILE=/swapfile
SWAP_UNIT_FILE=/etc/systemd/system/swapfile.swap
# The zram-generator package's own default (creates zram0 when nothing overrides it).
ZRAM_VENDOR_FILE=/usr/lib/systemd/zram-generator.conf
# Memory-management values that suit a swap that lives only in compressed RAM.
ZRAM_SYSCTL_FILE=/etc/sysctl.d/99-vps-stable-zram.conf
UFW_CONF=/etc/ufw/ufw.conf
JOURNAL_FILE=/etc/systemd/journald.conf.d/99-vps-stable.conf
F2B_FILE=/etc/fail2ban/jail.d/99-vps-stable-sshd.local
APT_FILE=/etc/apt/apt.conf.d/52-vps-stable-auto-upgrades
APT_REBOOT_FILE=/etc/apt/apt.conf.d/53-vps-stable-auto-reboot
SYSCTL_HARDENING_FILE=/etc/sysctl.d/98-vps-stable-hardening.conf
# Larger socket buffer ceilings for fast long-distance flows (optional).
TCP_BUFFER_FILE=/etc/sysctl.d/99-vps-stable-tcp.conf
F2B_ACTION_FILE=/etc/fail2ban/action.d/vps-stable-ufw-sshd.conf
F2B_DB_FILE=/etc/fail2ban/fail2ban.d/99-vps-stable.local
# sshd keeps the FIRST value it reads; 01- sorts before cloud-init's 50- file.
SSH_DROPIN=/etc/ssh/sshd_config.d/01-vps-stable-keyonly.conf
# The SSH port this tool set (sshd uses every Port line it reads).
SSH_PORT_DROPIN=/etc/ssh/sshd_config.d/00-vps-stable-port.conf
# Only written when a provider image ships "PubkeyAuthentication no".
SSH_PUBKEY_DROPIN=/etc/ssh/sshd_config.d/00-vps-stable-pubkey.conf
# Tells cloud-init to keep a hostname set with vps (it sets the provider's at boot).
CLOUD_HOSTNAME_FILE=/etc/cloud/cloud.cfg.d/99-vps-stable-hostname.cfg
WARNINGS=0
# This run's log (set by start_logging); apt writes its full output there.
RUN_LOG=''
AUTO_UPDATES=0
INSTALL_TOOLS=0
NEED_TIMESYNCD=0
KERNEL_UPDATE=0
FIREWALL_READY=0
RESTORE_EXIT_CODE=0
STATE_ROOT=/var/lib/vps-stable-opt
BACKUP_ROOT=/var/backups/vps-stable-opt
# Parameters the user set and per-machine settings (see param_list).
PARAMS_FILE="$STATE_ROOT/params"
PREFLIGHT_BLOCKERS=0
SOURCE_REVIEW_REQUIRED=0
PREFLIGHT_DONE=0
TOOLS_PACKAGES=(curl wget ca-certificates vim htop unzip lsof tmux)
# Setup choices asked once up front; an empty value means "ask when needed".
RECOMMENDED=0
SSH_CHOICE=''
ADMIN_CHOICE=''
ADMIN_NAME=''
TZ_CHOICE=''
TZ_ASKED=0
WEB_CHOICE=''
F2B_IGNORE_CHOICE=''
# The allowlist being written (f2b_allowlist_stage), space-separated.
F2B_ALLOW=''
SYSCTL_CHOICE=''
TCP_BUFFER_CHOICE=''
AUTO_REBOOT_TIME=''
KERNEL_CLEAN_CHOICE=''
VNSTAT_CHOICE=''
ZRAM_CHOICE=''
SWAP_CHOICE=''
HOSTS_CHOICE=''
HOSTNAME_CHOICE=''
KEEPALIVE_CHOICE=''
IPV4_CHOICE=''
LOGIN_CHOICE=''
# The PAM profile pam-auth-update reads (a file of this tool, outside /etc).
LOGIN_PAM_FILE=/usr/share/pam-configs/vps-stable-login
# Never written here: pam-auth-update changes it (tracked as login_pam).
PAM_COMMON_SESSION=/etc/pam.d/common-session
# Shows the note the hook left for the account, when its shell starts.
LOGIN_PROFILE_FILE=/etc/profile.d/zz-vps-stable-login.sh
LOGIN_NOTE_DIR=/run/vps-stable-login
# The check behind TG notifications and the traffic alert (a timer).
CHECK_SERVICE_FILE=/etc/systemd/system/vps-stable-check.service
CHECK_TIMER_FILE=/etc/systemd/system/vps-stable-check.timer
DOCKER_DAEMON_FILE=/etc/docker/daemon.json
NOTIFY_CHOICE='' QUOTA_CHOICE='' DOCKERLOG_CHOICE='' SSHPORT_CHOICE=''

case "$MODE" in menu|records|uninstall|rollback|setup|plan|perf|resources|audit|check|firewall|ssh|port|item|params|reboot|update|bans|help|-h|--help|--version) ;; *) echo '用法：bash vps-stable-opt.sh [menu|plan|perf|resources|audit|setup|item|params|firewall|ssh|port|check|records|rollback|uninstall|reboot|update|bans|help]' >&2; exit 2 ;; esac
[[ "$MODE" == --version ]] && { echo "$SCRIPT_VERSION"; exit 0; }
if [[ "$MODE" == help || "$MODE" == -h || "$MODE" == --help ]]; then
  cat <<'HELP'
VPS 机器管家 V2.7.8 — Debian 12/13、Ubuntu 22.04/24.04/26.04
安装后输入 vps 打开菜单；也可直接运行 bash vps-stable-opt.sh。
  vps plan       给机器做体检（只检查）
  vps perf       性能体检（只读）：CPU 是否被抢、内存和硬盘压力、换页、网络重传、连接跟踪
  vps resources  资源占用一览（只读）：常驻服务各占多少内存和 CPU、能不能关、封禁规则多少
  vps audit      安全排查（只读）：谁登录过、账户和公钥、装过什么、正在运行什么、开机自启和定时任务、系统文件
  vps setup      一键开荒：更新系统并优化机器（可选推荐设置，一次问完）
  vps check      开荒验收：逐项检查优化是否真的生效（适合重启后运行）
  vps port       端口管理；也可直接用：
                   vps port open 8080 | 443-600 | 8080,9000-9100 [tcp|udp|both] [from IP]
                   vps port close 8080 [tcp|udp|both]
                   vps port list
  vps item       单项设置：逐项开启或关闭某一项，不用重跑整个开荒；能调的项目可以调整参数
  vps params     参数总览（现在的值、推荐值和理由）；vps params export 导出，vps params import [文件] 导入
  vps bans       查看 Fail2ban 封禁记录，可以解封某个 IP
  vps reboot     重启服务器（先说明是否需要重启；防失联确认或软件安装没结束时不重启）
  vps firewall   设置防火墙与 SSH 防爆破（需已有 UFW）
  vps ssh        SSH 登录加固（只允许密钥登录，可选新建管理员并禁止 root 直接登录）
  vps records    查看操作记录和配置备份
  vps rollback   撤销本工具做过的设置（全部或只撤销某一项），可选卸载新装的软件包
  vps uninstall  卸载工具、记录和备份，保留软件与优化效果
  vps update     检查更新：GitHub 上有新版本时直接更新本工具（不改动系统设置）

大多数问题用 y 或回车回答：[Y/n] 回车表示「做」，[y/N] 回车表示「不做」。
只有三处要输入单词，提示里会写出要输入什么（区分大小写）：
  CONNECTED  防火墙、SSH 加固后，新开一个 SSH 窗口登录：登录成功通常会自动确认。没有自动确认时，
             回到原来的窗口输入（不是新窗口）；180 秒内没有确认会自动撤销。
  NOCONSOLE  没有控制台密码时仍要关闭 SSH 密码登录（不推荐）。
  UNINSTALL  卸载本工具（会删除全部备份）。
一键开荒会先问要不要在 tmux 里运行（回车就是要）：SSH 断线也不中断，重新登录输入 vps 选 2 就能回去。
符号：✔ 正常  ⚠ 注意  ✖ 失败  ○ 没做。显示成乱码时用 VPS_ASCII=1 vps 打开；不要颜色用 NO_COLOR=1 vps。
默认保留 SSH 端口、root 登录、DNS、IPv6、MTU；不自动重启整机。
回退只会放宽访问（关防火墙、恢复密码登录），不会把你锁在外面。
系统升级和新内核无法回退；需要整机还原请使用服务商快照。
卸载清掉备份后，即使重新安装也无法可靠回退；卸载不会删除用户上传副本。
HELP
  exit 0
fi

# Text interface. One symbol per state: ✔ done, ⚠ needs a look, ✖ failed,
# ○ not done. Colour only on a terminal, never in logs or saved reports
# (NO_COLOR or TERM=dumb turn it off); plain ASCII with VPS_ASCII=1 where a
# terminal draws these symbols badly. CJK terminals (Xshell and others) draw
# ambiguous-width symbols two columns wide, so nothing is aligned after one.
UI_COLOR=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then UI_COLOR=1; fi
# VPS_ASCII=0 or 1 wins over the setting saved from the single-item menu.
if [[ "${VPS_ASCII:-}" == 1 ]] || { [[ -z "${VPS_ASCII:-}" ]] && grep -qsx 'ui_ascii=1' "$PARAMS_FILE" 2>/dev/null; }; then
  SYM_OK='[OK]' SYM_WARN='[!]' SYM_FAIL='[X]' SYM_SKIP='[-]' SYM_NEXT='>' UI_OPEN='== ' UI_CLOSE=' =='
else
  SYM_OK='✔' SYM_WARN='⚠' SYM_FAIL='✖' SYM_SKIP='○' SYM_NEXT='›' UI_OPEN='【' UI_CLOSE='】'
fi
C_OK='' C_WARN='' C_FAIL='' C_TITLE='' C_DIM='' C_BOLD='' C_RESET=''
if ((UI_COLOR)); then
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m' C_TITLE=$'\033[1;36m' C_DIM=$'\033[2m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
fi
# The number of setup steps while a setup runs (0: titles without numbers).
UI_STEPS=0
# The terminal itself, kept before the output also goes to the log: the apt
# progress line is drawn there only.
UI_TTY_FD=''
if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then exec {UI_TTY_FD}>&1; fi

say() { printf '\n%s%s%s%s%s\n' "${C_TITLE-}" "${UI_OPEN-【}" "$*" "${UI_CLOSE-】}" "${C_RESET-}"; }
ok() { printf '%s%s%s %s\n' "${C_OK-}" "${SYM_OK-✔}" "${C_RESET-}" "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '%s%s %s%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" "$*" "${C_RESET-}"; }
die() { printf '%s%s %s%s\n' "${C_FAIL-}" "${SYM_FAIL-✖}" "$*" "${C_RESET-}" >&2; exit 1; }

# N TITLE: a setup step, with how far the setup has come ("[5/15]" and one
# mark per step); outside a setup (a single item) only the title.
step() {
  local n="$1" title="$2" bar='' i
  if ((${UI_STEPS:-0} <= 0)); then say "$title"; return 0; fi
  for ((i = 1; i <= UI_STEPS; i++)); do
    if ((i <= n)); then bar+='#'; else bar+='.'; fi
  done
  printf '\n%s%s%s/%s%s%s%s  %s[%s]%s\n' "${C_TITLE-}" "${UI_OPEN-【}" "$n" "$UI_STEPS" "${UI_CLOSE-】}" "$title" "${C_RESET-}" "${C_DIM-}" "$bar" "${C_RESET-}"
}

# Display columns of TEXT, counted on its bytes: ASCII and two-byte UTF-8 one
# column, three- and four-byte (CJK, full-width punctuation, the symbols above)
# two. Prints the number; with a variable name first, stores it there instead.
ui_width() {
  local LC_ALL=C text="${!#}" chars wide
  chars="${text//[$'\x80'-$'\xbf']/}"
  wide="${text//[^$'\xe0'-$'\xf7']/}"
  if (($# > 1)); then printf -v "$1" '%s' "$((${#chars} + ${#wide}))"
  else printf '%s\n' "$((${#chars} + ${#wide}))"; fi
}

on_error() {
  local code="$1" line="$2"
  trap - ERR
  if declare -F restore_capture_failure >/dev/null; then restore_capture_failure || true; fi
  if declare -F record_failure >/dev/null; then record_failure "$line" "$code" || true; fi
  printf '%s%s 出错：第 %s 行，退出码 %s；请查看运行记录，不要盲目重跑。%s\n' "${C_FAIL-}" "${SYM_FAIL-✖}" "$line" "$code" "${C_RESET-}" >&2
  exit "$code"
}

on_exit() {
  local code="$1"
  if declare -F restore_capture_failure >/dev/null; then restore_capture_failure || true; fi
  if declare -F record_exit >/dev/null; then record_exit "$code" || true; fi
  # The lock holder note in /run only means something while this process runs.
  if [[ -n "${TOOL_LIFECYCLE_PID:-}" && "$TOOL_LIFECYCLE_PID" == "$BASHPID" ]]; then rm -f -- "$LOCK_OWNER_FILE" 2>/dev/null || true; fi
}

trap 'on_error "$?" "$LINENO"' ERR
trap 'on_exit "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -r /etc/os-release ]] || die '找不到 /etc/os-release，无法识别系统。'
# shellcheck source=/etc/os-release
# Linux provides this file; it is deliberately not bundled or followed on Windows.
# shellcheck disable=SC1091
. /etc/os-release
OS="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
case "$OS:$OS_VERSION" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
  *) die "不支持的系统：${PRETTY_NAME:-$OS $OS_VERSION}；没有做任何修改。" ;;
esac
command -v systemctl >/dev/null || die '缺少 systemctl。'
VIRT="$(systemd-detect-virt 2>/dev/null || true)"
[[ -n "$VIRT" ]] || VIRT=none
MEM_MIB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null || echo unknown)"
ROOT_FS="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
ROOT_GIB="$(df -Pk / | awk 'NR==2 {printf "%d", $2/1024/1024}')"

# Keys pressed on the terminal before a question is shown (Enter during a long
# upgrade, say) must not answer it: they are dropped first. Input from a pipe
# or a file is left alone.
input_flush() {
  local REPLY
  [[ -t 0 ]] || return 0
  while read -r -t 0.05 -n 1024; do :; done 2>/dev/null
}

confirm() {
  local question="$1" expected="$2" answer=''
  [[ -t 0 ]] || return 1
  input_flush
  read -r -p "$question 请输入 [$expected]: " answer || true
  [[ "$answer" == "$expected" ]] && return 0
  # Say why instead of silently treating a near miss as "no".
  if [[ -n "$answer" ]]; then
    if [[ "${answer^^}" == "$expected" ]]; then printf '确认词要用大写 %s（区分大小写），这次按取消处理。\n' "$expected"
    else printf '输入的不是 %s，这次按取消处理。\n' "$expected"; fi
  fi
  return 1
}
# Low-risk choices accept y/yes; anything else, including Enter, means no.
confirm_yes() {
  local question="$1" answer=''
  [[ -t 0 ]] || return 1
  input_flush
  read -r -p "$question [y/N]: " answer || true
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}
# Recommended choices: Enter means yes, n/no means no. No terminal means no.
confirm_default_yes() {
  local question="$1" answer=''
  [[ -t 0 ]] || return 1
  input_flush
  read -r -p "$question [Y/n]: " answer || true
  [[ -z "$answer" || "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
ufw_active() {
  local state
  state="$(ufw status 2>/dev/null)" || return 1
  grep -Fxq 'Status: active' <<< "$state"
}
installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }
available() { installed "$1" || apt-cache policy "$1" 2>/dev/null | awk '$1=="Candidate:" && $2!="(none)" {ok=1} END {exit !ok}'; }
# True when lslocks output (stdin) lists an APT/dpkg lock.
apt_lock_listed() {
  grep -Eq '^[[:space:]]*/var/(lib/(dpkg/(lock|lock-frontend)|apt/lists/lock)|cache/apt/archives/lock)([[:space:]]|$)'
}

# True while another program holds an APT/dpkg lock (unknown without lslocks).
apt_locks_held() {
  local locks
  command -v lslocks >/dev/null || return 1
  locks="$(lslocks --noheadings --raw --output PATH 2>/dev/null || true)"
  apt_lock_listed <<< "$locks"
}

# A fresh VPS usually runs its automatic update right after first boot. APT
# does not wait for its locks (apt-get update never; dpkg only with
# DPkg::Lock::Timeout), so every APT step waits here first, up to 10 minutes.
apt_wait_idle() {
  local i shown=0
  for ((i = 0; i < 120; i++)); do
    if ! apt_locks_held; then return 0; fi
    if ((shown == 0)); then echo '其他程序（通常是开机后的自动更新）正在安装或更新软件：等它结束后继续，最多等 10 分钟……'; shown=1; fi
    sleep 5
  done
  warn '等了 10 分钟，软件包锁仍被占用；接下来的软件操作可能失败。不要删除锁文件或强行结束它。'
}

# Every apt-get that changes the system. Neither apt nor dpkg sets a umask, so
# package scripts would inherit this tool's 077: a file one writes without
# setting its mode (cat or touch; ucf copies keep theirs) would be readable by
# root only. They get the 022 of an ordinary root shell instead.
# During a logged run apt's whole output goes to the log only: the screen gets
# what runs, one progress line, and apt's last lines when it fails.
apt_run() {
  local mask rc=0 start arg skip=0
  local -a words=()
  mask="$(umask)"
  umask 022
  if [[ -n "${RUN_LOG:-}" && -f "$RUN_LOG" && ! -L "$RUN_LOG" ]]; then
    for arg in "$@"; do
      if ((skip)); then skip=0; continue; fi
      case "$arg" in -o) skip=1 ;; -*) ;; *) words+=("$arg") ;; esac
    done
    printf '  %s apt-get %s（完整输出写进日志）\n' "${SYM_NEXT-›}" "${words[*]}"
    start="$(stat -c %s -- "$RUN_LOG" 2>/dev/null || echo 0)"
    { apt-get -o APT::Status-Fd=3 "$@" 3>&1 >> "$RUN_LOG" 2>&1 < /dev/null; } | apt_progress || rc=$?
    if ((rc)); then
      printf '%s%s apt-get 没有成功（退出码 %s），它最后的输出：%s\n' "${C_FAIL-}" "${SYM_FAIL-✖}" "$rc" "${C_RESET-}"
      { tail -c +"$((start + 1))" -- "$RUN_LOG" | tail -n 15 | sed 's/^/    /'; } || true
      printf '  完整输出：%s\n' "$RUN_LOG"
    fi
  else
    apt-get "$@" || rc=$?
  fi
  umask "$mask"
  return "$rc"
}

# APT::Status-Fd lines in, one changing line on the terminal out: downloading
# or setting up, how far, and which package. Without a terminal, only drained.
apt_progress() {
  local kind item pct line=''
  while IFS=: read -r kind item pct _; do
    [[ -n "${UI_TTY_FD:-}" ]] || continue
    pct="${pct%%.*}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    case "$kind" in
      dlstatus) line="下载软件包 $pct%" ;;
      pmstatus) line="安装和配置 $pct% $item" ;;
      *) continue ;;
    esac
    printf '\r\033[K    %s' "$line" >&"$UI_TTY_FD"
  done
  if [[ -n "$line" ]]; then printf '\r\033[K' >&"$UI_TTY_FD"; fi
}

# Packages absent before this call are recorded so rollback can offer removal.
# apt waits for the package lock itself (DPkg::Lock::Timeout, 15 minutes): an
# automatic update can take its lock right after apt_wait_idle looked, and on a
# small or long-unpatched machine it often runs for more than a few minutes.
install_pkgs() {
  local pkg new=() rc=0
  for pkg in "$@"; do installed "$pkg" || new+=("$pkg"); done
  apt_wait_idle
  apt_run -y -q -o DPkg::Lock::Timeout=900 install --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" || rc=$?
  if declare -F restore_record_packages >/dev/null && ((${#new[@]})); then
    restore_record_packages "${new[@]}" || warn '无法记录本次新装的软件包；回退时不会提供卸载它们的选项。'
  fi
  return "$rc"
}

validate_vm() {
  [[ $EUID -eq 0 ]] || die '修改系统需要 root：请用 root 登录或 sudo vps。'
  [[ -t 0 ]] || die '需要在交互式 SSH 终端里运行。'
  [[ -d /run/systemd/system ]] || die '系统没有使用 systemd 管理服务，无法运行。'
  if systemd-detect-virt --container >/dev/null 2>&1; then die "检测到容器环境（$VIRT），不做系统级修改。"; fi
  case "$VIRT" in docker|lxc|lxc-libvirt|openvz|podman|container|systemd-nspawn|wsl) die "不支持的虚拟化环境：$VIRT";; esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) die '没有验证过的 CPU 架构，已停止。';; esac
  command -v flock >/dev/null || die '缺少 flock 命令。'
  coreutils_selfcheck || die '本工具依赖的基础命令（coreutils）行为和预期不一致，已停止，没有做任何修改。如果是 Ubuntu 26.04 默认的 Rust 版 coreutils 造成的，可以安装 coreutils-from-gnu 切换回 GNU 版（步骤见 Ubuntu 官方说明）后再试。'
}

# Exercises the exact command behaviour this tool relies on. Ubuntu 26.04 ships
# Rust coreutils by default, so any difference stops the run before a change.
coreutils_selfcheck() {
  local dir rc=0
  dir="$(mktemp -d)" || return 1
  {
    [[ "$(stat -c '%a' -- "$dir")" == 700 ]] &&
    install -d -m 750 -- "$dir/sub" && [[ "$(stat -c '%a' -- "$dir/sub")" == 750 ]] &&
    printf 'x\n' > "$dir/f" && [[ "$(stat -c '%s' -- "$dir/f")" == 2 ]] &&
    [[ "$(stat -c '%a:%u:%g' -- "$dir/f")" =~ ^[0-7]{3,4}:[0-9]+:[0-9]+$ ]] &&
    [[ "$(stat -c '%U' -- "$dir/f")" == "$(id -un)" ]] &&
    [[ "$(printf '%s\n' 6.1.0-9 6.1.0-10 | sort -V | tail -n 1)" == 6.1.0-10 ]] &&
    [[ "$(sha256sum -- "$dir/f" | cut -d' ' -f1)" =~ ^[a-f0-9]{64}$ ]] &&
    (($(tail -c 1 -- "$dir/f" | wc -l) == 1)) &&
    df -Pk / | awk 'NR == 2 && NF >= 6 {ok = 1} END {exit !ok}' &&
    df -Pi / | awk 'NR == 2 && ($5 ~ /%$/ || $5 == "-") {ok = 1} END {exit !ok}' &&
    [[ "$(readlink -f -- "$dir/f")" == "$(cd -- "$dir" && pwd -P)/f" ]] &&
    cp -p -- "$dir/f" "$dir/g" && mv -fT -- "$dir/g" "$dir/h" && [[ -f "$dir/h" && ! -e "$dir/g" ]] &&
    [[ "$(date -u +%Y%m%d)" =~ ^[0-9]{8}$ ]]
  } || rc=1
  rm -rf -- "$dir"
  return "$rc"
}

start_logging() {
  tool_prepare_data
  # Private state directory keeps the lock path out of shared writable folders.
  state_secure_dir "$STATE_ROOT"
  state_secure_dir "$LOG_DIR"
  local lock="$STATE_ROOT/optimizer.lock"
  [[ ! -L "$lock" && ( ! -e "$lock" || ( -f "$lock" && -O "$lock" ) ) ]] || die '运行锁文件不安全（不是本工具的普通文件），已停止。'
  exec 9>"$lock"
  flock -n 9 || die "$(lock_holder_text)"
  # Frequent port operations get their own prefix so they never push out the
  # setup/rollback logs.
  local prefix=run keep=9
  if [[ "$MODE" == port ]]; then prefix=port; keep=20; fi
  log_rotate "$prefix-*.log" "$keep"
  RUN_LOG="$LOG_DIR/$prefix-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  : >> "$RUN_LOG"
  # The screen gets the colours, the log the plain text.
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$RUN_LOG")) 2>&1
  say "VPS 机器管家 v$SCRIPT_VERSION | $PRETTY_NAME"
}

# Keeps the newest KEEP-1 files matching PATTERN in the log directory.
log_rotate() {
  local pattern="$1" keep="$2" old
  find "$LOG_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' | sort -nr | tail -n +"$keep" | cut -d' ' -f2- |
    while IFS= read -r old; do
      if [[ -n "$old" ]]; then rm -f -- "$old"; fi
    done
}

# Never overwrite an existing file. Result: 0=matches or created, 1=conflict.
put_file() {
  local dest="$1" contents="$2" temp parent actual missing dir
  local -a created=()
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -f "$dest" && ! -L "$dest" ]] && actual="$(cat -- "$dest")" && [[ "$actual" == "$contents" ]]; then
      ok "已经配置好：$dest"; return 0
    fi
    warn "已有内容不同的文件或链接：$dest（保持不变，不覆盖）"; return 1
  fi
  backup_config_path "$dest" || die "无法备份原配置：$dest"
  parent="$(dirname -- "$dest")" || return 1
  if [[ ! -d "$parent" ]]; then
    # Every level created here goes again with the rollback once it is empty.
    missing="$parent"
    while [[ ! -e "$missing" && ! -L "$missing" && "$missing" != / ]]; do created+=("$missing"); missing="$(dirname -- "$missing")"; done
    install -d -m 755 -- "$parent" || { warn "无法创建配置目录：$parent"; return 1; }
    for dir in "${created[@]}"; do
      restore_record_dir "$dir" || warn "无法记录新建的目录：$dir（撤销后可能留下空目录）"
    done
  fi
  temp="$(mktemp "$dest.tmp.XXXXXX")" || { warn "无法创建临时配置文件：$dest"; return 1; }
  if ! printf '%s\n' "$contents" > "$temp" || ! chmod 644 -- "$temp"; then
    rm -f -- "$temp"; warn "无法完整写入配置：$dest"; return 1
  fi
  if ! actual="$(cat -- "$temp")" || [[ "$actual" != "$contents" ]]; then
    rm -f -- "$temp"; warn "临时配置文件校验失败：$dest"; return 1
  fi
  if ! mv -n -- "$temp" "$dest"; then
    rm -f -- "$temp"; warn "无法写入配置：$dest"; return 1
  fi
  rm -f -- "$temp"
  if ! actual="$(cat -- "$dest" 2>/dev/null)" || [[ -L "$dest" || "$actual" != "$contents" ]]; then
    warn "写入时配置被同时修改：$dest"; return 1
  fi
  record_config_change "$dest" created || die '无法记录这次配置变更。'
  ok "已配置：$dest"
}

# Where systemd starts sshd from its socket (Ubuntu 24.04 and later), the
# privilege separation directory exists only while ssh.service runs, and every
# OpenSSH update stops the service until the next login: sshd -t and -T then
# fail ("Missing privilege separation directory") although SSH works. Create it
# as the service does; no configuration changes, and /run is gone at reboot.
sshd_runtime_dir() {
  local dir="${1:-/run/sshd}"
  [[ -e "$dir" || -L "$dir" ]] && return 0
  [[ -d "${dir%/*}" ]] || return 0
  command -v sshd >/dev/null || return 0
  install -d -m 0755 -- "$dir" 2>/dev/null || true
}

ssh_candidates() {
  local bin
  bin="$(command -v sshd || true)"
  sshd_runtime_dir
  if [[ -n "$bin" ]]; then "$bin" -T 2>/dev/null | awk '$1=="port" && $2~/^[0-9]+$/ && $2>=1 && $2<=65535 {print $2}' || true; fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then awk 'NF==4 && $4~/^[0-9]+$/ && $4>=1 && $4<=65535 {print $4}' <<< "$SSH_CONNECTION"; fi
}

port_listening() {
  local port="$1" line addr socket_listen
  socket_listen="$(systemctl show ssh.socket --property=Listen --value 2>/dev/null || true)"
  command -v ss >/dev/null || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    addr="$(awk '{print $4}' <<< "$line")"
    case "$addr" in 127.*|\[::1\]:*|::1:*|localhost:*) continue ;; esac
    if [[ "$line" == *'"sshd"'* ]]; then return 0; fi
    if active ssh.socket && [[ "$line" == *'"systemd"'* ]] && [[ "$socket_listen" =~ (^|[^0-9])${port}([^0-9]|$) ]]; then return 0; fi
  done < <(ss -H -lntp "( sport = :$port )" 2>/dev/null)
  return 1
}

SSH_PORTS=()
ssh_detect() {
  SSH_PORTS=()
  command -v sshd >/dev/null || return 1
  sshd_runtime_dir
  sshd -t >/dev/null 2>&1 || return 1
  local port
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    port_listening "$port" && SSH_PORTS+=("$port")
  done < <(ssh_candidates | sort -n -u)
  ((${#SSH_PORTS[@]}>0 && ${#SSH_PORTS[@]}<=8))
}

# iptables-nft and `ufw disable` leave empty base chains with an accept policy,
# empty ufw chains and plain jumps into them (seen on Debian 13). Those are
# inert and ignored, as are "#" comment lines (newer nft prints notes there);
# any other rule, set, map or non-accept policy counts and is printed.
nft_ruleset_has_policy() {
  awk '
    {line=$0; sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)}
    line=="" || line=="}" || line ~ /^#/ {next}
    line ~ /^table [a-z0-9]+ [A-Za-z0-9_.-]+ \{$/ {next}
    line ~ /^chain [A-Za-z0-9_.-]+ \{$/ {next}
    line ~ /^type [a-z]+ hook [a-z]+ (device "?[A-Za-z0-9_.-]+"? )?priority [A-Za-z0-9_+-]+; policy accept;$/ {next}
    line ~ /^(counter( packets [0-9]+ bytes [0-9]+)? )?jump ufw6?-[a-z0-9-]+$/ {next}
    {print line; found=1; exit}
    END {exit !found}'
}

# The same for iptables-save: what `ufw disable` leaves is empty ufw chains and
# plain "-j ufw-..." jumps with ACCEPT policies. Any other rule (Docker, other
# tools, a rule inside a ufw chain) or a DROP/REJECT policy counts and is printed.
iptables_save_has_policy() {
  awk '
    /^-A [A-Za-z0-9_-]+ -j ufw6?-[a-z0-9-]+$/ {next}
    /^-A[ \t]/ || /^:[^ \t]+[ \t]+(DROP|REJECT)/ {print; found=1; exit}
    END {exit !found}'
}

# Each finding names the service or the exact line, so a refusal can be checked.
firewall_conflict() {
  if active firewalld; then warn '检测到 firewalld 正在运行。'; return 0; fi
  if active nftables; then warn '检测到 nftables 服务正在运行（它会加载自己的防火墙规则）。'; return 0; fi
  local rules bin offender inspected=0
  if command -v nft >/dev/null; then
    inspected=1
    if ! rules="$(nft list ruleset 2>/dev/null)"; then
      warn '无法读取 nftables 规则，不自动接管防火墙。'; return 0
    fi
    if offender="$(nft_ruleset_has_policy <<< "$rules")"; then
      warn "nftables 里有其他防火墙规则：${offender:0:160}"; return 0
    fi
  fi
  for bin in iptables-save ip6tables-save; do
    command -v "$bin" >/dev/null || continue
    inspected=1
    if ! rules="$("$bin" 2>/dev/null)"; then
      warn "无法读取 $bin 的规则，不自动接管防火墙。"; return 0
    fi
    if offender="$(iptables_save_has_policy <<< "$rules")"; then
      warn "$bin 里有其他防火墙规则：${offender:0:160}"; return 0
    fi
  done
  if (( !inspected )); then
    warn '没有可用的防火墙检查工具，不自动接管防火墙。'; return 0
  fi
  return 1
}

# Raw status listing shown on request after the acceptance summary. It does not
# repeat the preflight/DNS probes; use plan for a full read-only audit.
details_report() {
  say '详细状态（只读）'
  printf '系统：%s | 内核：%s | 虚拟化：%s | 内存：%s MiB | 系统盘：%s GiB\n' "$PRETTY_NAME" "$(uname -r)" "$VIRT" "$MEM_MIB" "$ROOT_GIB"
  printf '根分区：%s（%s）\n' "$ROOT_DEV" "$ROOT_FS"
  echo '-- 内存与 Swap --'; free -h; swapon --show || true
  bbr_report
  echo '-- SSH 端口与服务 --'; ssh_candidates | sort -n -u || true; systemctl is-active ssh sshd 2>/dev/null || true
  echo '-- 防火墙（UFW） --'; if command -v ufw >/dev/null; then ufw status numbered || true; else echo '未安装'; fi
  echo '-- Fail2ban --'; if command -v fail2ban-client >/dev/null && active fail2ban; then fail2ban-client status sshd || true; else echo '未运行'; fi
  echo '-- 时间同步 --'; timedatectl show -p Timezone -p NTPSynchronized 2>/dev/null || true
  echo '-- 自动更新与自动重启策略 --'
  apt-config dump 2>/dev/null | grep -E '^(APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|Unattended-Upgrade::(Automatic-Reboot|Automatic-Reboot-WithUsers|Automatic-Reboot-Time|Allowed-Origins|Origins-Pattern))' || true
  echo '没有设置 Automatic-Reboot 时默认不自动重启；更新来源沿用发行版原有策略。'
  systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true
  echo '-- ZRAM 与 TRIM --'; zramctl 2>/dev/null || true; systemctl is-enabled fstrim.timer 2>/dev/null || true
  echo '-- 日志上限 --'; systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^(SystemMaxUse|RuntimeMaxUse|MaxRetentionSec)=' || true
  echo '-- 默认路由 --'; ip -4 route show default 2>/dev/null || true; ip -6 route show default 2>/dev/null || true
  echo '-- SSH 实际生效的登录设置 --'
  sshd_runtime_dir
  if command -v sshd >/dev/null && sshd -T 2>/dev/null | audit_sshd_values; then :; else echo '无法执行 sshd -T'; fi
  restart_report
  state_report
}

plan() {
  say '给机器做体检（只检查，不修改）'
  printf '系统：%s | 内核：%s | 虚拟化：%s | 内存：%s MiB | 系统盘：%s GiB\n' "$PRETTY_NAME" "$(uname -r)" "$VIRT" "$MEM_MIB" "$ROOT_GIB"
  # Menus 8 and 9 change one thing only: the full setup plan would mislead there.
  case "$MODE" in
    ssh) echo '这次只做 SSH 登录加固：先体检，再按提示一步步确认。' ;;
    firewall) echo '这次只设置防火墙和 SSH 防爆破：先体检，再按提示一步步确认。' ;;
    *)
      echo '选择“一键开荒”时，会重新读取机器状态并检查，不沿用旧报告直接修改。'
      echo '系统更新、自动更新、常用工具、时区、SSH 加固、防火墙分别确认；BBR/ZRAM 等按检测结果决定。'
      echo '默认保留 SSH 端口、root 登录、IPv6、MTU、DNS；不重装系统、不换第三方内核；硬盘 Swap 只在内存不到 2GiB、又用不了 ZRAM 时才建。' ;;
  esac
  preflight_report
  security_audit
  health_report
  state_report
  case "$MODE" in
    ssh|firewall) ;;
    *) decision_report "$PREFLIGHT_BLOCKERS" "$SOURCE_REVIEW_REQUIRED" ;;
  esac
}

# Matches APT's own upgrade simulation: a new linux-image/modules package means
# a new kernel will be installed and becomes active only after a reboot.
upgrade_has_kernel() {
  grep -Eq '^Inst linux-(image|modules)-[^ ]+' <<< "$1"
}

UPGRADE_APPROVED=0
UPGRADE_COUNT=0
apt_index_stage() {
  step 2 '软件索引与升级计划'
  local free_mb simulation count
  local -a names=()
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  [[ "$free_mb" =~ ^[0-9]+$ ]] || die '无法确定磁盘剩余空间。'
  ((free_mb >= 650)) || die "磁盘只剩 ${free_mb}MiB，至少需要 650MiB。"
  apt_wait_idle
  if ! apt_run update -o APT::Update::Error-Mode=any; then
    warn '软件索引更新失败，关闭增量下载后再试一次。'
    apt_wait_idle
    apt_run update -o APT::Update::Error-Mode=any -o Acquire::PDiffs=false || die 'APT 软件索引更新失败：请检查软件源；如提示 "not valid yet"，说明系统时间不准，请先校准时间。'
  fi
  APT_INDEX_READY=1
  echo '-- 当前系统版本内的升级模拟（不修改软件源，不跨大版本） --'
  # --with-new-pkgs lets new kernel ABI packages install; nothing is ever removed.
  if ! simulation="$(apt-get -s upgrade --with-new-pkgs 2>&1)"; then
    die '系统升级模拟失败；请人工检查软件包和软件源，未执行升级。'
  fi
  printf '%s\n' "$simulation" > "$RUN_BACKUP_DIR/upgrade-simulation.txt"
  count="$(grep -c '^Inst ' <<< "$simulation" || true)"
  UPGRADE_COUNT="$count"
  printf '计划升级或新装的软件包：%s 个（完整清单保存在本次备份目录）。\n' "$count"
  # Only the package names on screen; APT's raw Inst/Conf lines run to hundreds.
  mapfile -t names < <(awk '$1 == "Inst" {print $2}' <<< "$simulation")
  if ((${#names[@]})); then
    # fold -s breaks after a space and leaves it at the end of the line.
    printf '%s\n' "${names[@]:0:60}" | paste -sd ' ' - | fold -s -w 76 | sed 's/^/  /; s/[[:space:]]*$//'
    if ((${#names[@]} > 60)); then echo "  ……共 ${#names[@]} 个，其余见备份目录里的 upgrade-simulation.txt"; fi
  fi
  KERNEL_UPDATE=0
  if upgrade_has_kernel "$simulation"; then
    KERNEL_UPDATE=1
    echo '本次升级包含新内核：需要重启后才生效；旧内核会保留，开机菜单里仍可选回。'
  fi
  echo '只在当前大版本内升级（不会升到新的系统大版本，例如 Debian 12 → 13、Ubuntu 24.04 → 26.04），也不会删除任何已安装的软件包。'
  echo
  printf '推荐设置：升级系统、开启自动安全更新、安装常用工具、启用内核网络安全参数%s、SSH 保活、登录记录和提醒、升级后清理旧内核、主机名无法解析时补上；IPv6 连不通外网时改成优先使用 IPv4。\n' \
    "$(if ((${MEM_MIB:-0} >= 1024)); then echo '、TCP 调优'; fi)"
  echo '（SSH 加固、防火墙和 Fail2ban 白名单不在推荐设置里，后面会单独问你。）'
  if confirm_default_yes '使用推荐设置吗？'; then
    RECOMMENDED=1
    if ((count > 0)); then UPGRADE_APPROVED=1; fi
    AUTO_UPDATES=1
    return 0
  fi
  RECOMMENDED=0
  if ((count > 0)) && confirm_default_yes '现在执行系统软件升级吗？（升级可能重启部分服务）'; then
    UPGRADE_APPROVED=1
  fi
  if confirm_default_yes '开启自动安全更新吗？（沿用系统原有的更新来源）'; then
    AUTO_UPDATES=1
  else
    ok '保持原有的自动更新策略，不新开启自动更新。'
  fi
}

hostname_resolves() {
  getent hosts "$(hostname 2>/dev/null || echo localhost)" >/dev/null 2>&1
}

# A hostname this tool sets: lowercase letters, digits and hyphens, dots
# between labels, at most 63 characters (the kernel keeps 64).
hostname_valid() {
  local re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
  ((${#1} <= 63)) && [[ "$1" =~ $re ]]
}

# Asks for the new hostname; sets HOSTNAME_CHOICE.
hostname_ask() {
  local answer old
  old="$(hostname 2>/dev/null || true)"
  printf '现在的主机名：%s\n' "${old:-未知}"
  echo '主机名只能用小写字母、数字和连字符（-），最长 63 位。改名不会断开 SSH；监控面板之类按主机名认机器的，要自己同步。'
  while :; do
    read -r -p '新的主机名（直接回车取消）: ' answer || return 1
    [[ -n "$answer" ]] || { ok '已取消。'; return 1; }
    answer="${answer,,}"
    if ! hostname_valid "$answer"; then echo '格式不对：只能用小写字母、数字和连字符，开头结尾不能是连字符。'; continue; fi
    if [[ "$answer" == "$old" ]]; then ok "主机名已经是 $old。"; return 1; fi
    confirm_yes "把主机名从 ${old:-未知} 改成 $answer 吗？" || { ok '已取消。'; return 1; }
    HOSTNAME_CHOICE="$answer"
    return 0
  done
}

# OLD NEW: the line this tool added for the old name goes, and the new name
# gets one (127.0.1.1, as on Debian) when it does not resolve.
hostname_hosts_update() {
  local from="$1" to="$2" drop="$RESTORE_ROOT/.hostname-drop" record="$RESTORE_ROOT/hostname_hosts_line" temp
  if [[ -n "$from" && -f "$record" && ! -L "$record" ]] && grep -Fxq -- "127.0.1.1"$'\t'"$from" "$record"; then
    printf '%s\n' "127.0.1.1"$'\t'"$from" > "$drop" && chmod 600 -- "$drop"
    if restore_hosts_lines_apply .hostname-drop && temp="$(mktemp "$RESTORE_ROOT/.hostname-record.XXXXXX")"; then
      { grep -vxF -- "127.0.1.1"$'\t'"$from" "$record" > "$temp" || true; }
      if ! chmod 600 -- "$temp" || ! mv -fT -- "$temp" "$record"; then rm -f -- "$temp"; fi
    fi
    rm -f -- "$drop"
  fi
  if hostname_resolves; then return 0; fi
  if [[ ! -f /etc/hosts || -L /etc/hosts ]]; then warn "/etc/hosts 不是普通文件：新主机名 $to 解析不了，sudo 会报 unable to resolve host。"; return 0; fi
  backup_config_path /etc/hosts || die '无法备份 /etc/hosts'
  if append_line_safely /etc/hosts "127.0.1.1"$'\t'"$to" && hostname_resolves; then
    record_config_change /etc/hosts line-appended || die '无法记录 /etc/hosts 变更。'
    restore_record_hosts_line "127.0.1.1"$'\t'"$to" hostname_hosts_line || warn '无法记录为新主机名加的 /etc/hosts 行；撤销时请人工删掉它。'
    ok "已在 /etc/hosts 加入：127.0.1.1 $to"
  else
    warn "新主机名 $to 加进 /etc/hosts 后仍解析不了，请人工检查。"
  fi
}

# On some images (Debian's) cloud-init writes /etc/hosts from its template at
# every boot, with the hostname it is configured with; the file says so.
cloud_hosts_managed() {
  command -v cloud-init >/dev/null && grep -qsF "configured 'manage_etc_hosts' as True" /etc/hosts
}

# Has cloud-init write /etc/hosts again now, from its configuration as it is.
cloud_hosts_refresh() {
  cloud-init single --name update_etc_hosts --frequency always >/dev/null 2>&1
}

# Renames this machine: the static and the running name, cloud-init told to
# keep it (and to write /etc/hosts with it, where it does that), and a line in
# /etc/hosts when the new name still does not resolve.
hostname_stage() {
  say '修改主机名'
  local from to content
  from="$(hostname 2>/dev/null || true)" to="${HOSTNAME_CHOICE:-}"
  if ! hostname_valid "$to"; then warn "主机名格式不对：$to，没有修改。"; module_result hostname failed 'invalid name'; return 0; fi
  if ! hostnamectl --static --transient set-hostname "$to"; then
    warn '修改主机名失败（hostnamectl），保持原样。'; module_result hostname failed 'hostnamectl failed'; return 0
  fi
  # Most provider images run cloud-init, which sets the provider's name at
  # every boot unless told to keep this one.
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    content="# VPS Stable Optimizer v2.8: keep the hostname set with vps (cloud-init would set the provider's name again at boot)"$'\n'"preserve_hostname: true"$'\n'"hostname: $to"$'\n'"fqdn: $to"
    if [[ -f "$CLOUD_HOSTNAME_FILE" && "$(cat -- "$CLOUD_HOSTNAME_FILE" 2>/dev/null || true)" != "$content" ]] && restore_file_ours cloud_hostname_file; then
      rm -f -- "$CLOUD_HOSTNAME_FILE"
    fi
    if ! put_file "$CLOUD_HOSTNAME_FILE" "$content"; then
      warn "没能写入 $CLOUD_HOSTNAME_FILE：重启后 cloud-init 可能把主机名改回服务商设置的名字。"
    elif cloud_hosts_managed && ! cloud_hosts_refresh; then
      warn 'cloud-init 没能马上按新名字重写 /etc/hosts；下次开机时会写好。'
    fi
  fi
  hostname_hosts_update "$from" "$to"
  ok "主机名已改成 $to（原来是 ${from:-未知}）。新开的 SSH 窗口里，提示符会显示新名字。"
  module_result hostname applied "$to"
}

# The display name: free text (Chinese too), at most 24 columns, for the menu
# and notifications; a per-machine setting, never exported.
display_name_get() {
  local value
  [[ -f "$PARAMS_FILE" && ! -L "$PARAMS_FILE" ]] || return 1
  value="$(awk -F= '$1 == "display_name" {v = substr($0, 14)} END {print v}' "$PARAMS_FILE" | LC_ALL=C tr -d '\000-\037\177')"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

display_name_ask() {
  local answer width
  printf '现在的显示名：%s\n' "$(display_name_get || echo '没有设置（菜单里显示主机名）')"
  echo '显示名只用在本工具的菜单和通知里，可以写中文，例如「东京-1」；不会改系统的主机名。'
  while :; do
    read -r -p '新的显示名（直接回车不改，输入 - 删除）: ' answer || return 0
    answer="$(LC_ALL=C tr -d '\000-\037\177' <<< "$answer")"
    answer="${answer#"${answer%%[! ]*}"}" answer="${answer%"${answer##*[! ]}"}"
    [[ -n "$answer" ]] || { ok '显示名没有改动。'; return 0; }
    if [[ "$answer" == - ]]; then param_store display_name '' || die '无法保存设置。'; ok '显示名已删除，菜单里显示主机名。'; return 0; fi
    ui_width width "$answer"
    if ((width > 24)); then echo "太长了（$width 列）：最多 24 列，一个汉字算两列。"; continue; fi
    param_store display_name "$answer" || die '无法保存设置。'
    ok "显示名已改成：$answer"
    return 0
  done
}

# Prints the canonical zone for an exact or case-insensitive name.
timezone_resolve() {
  local answer="$1" list match
  [[ "$answer" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  list="$(timedatectl list-timezones 2>/dev/null)" || return 1
  if grep -Fxq -- "$answer" <<< "$list"; then printf '%s\n' "$answer"; return 0; fi
  match="$(grep -Fxi -- "$answer" <<< "$list" | head -n 1 || true)"
  [[ -n "$match" ]] || return 1
  printf '%s\n' "$match"
}

# Common zones are offered by number; any other zone name can still be typed.
timezone_ask() {
  local current answer zone suggestions tries i
  local -a common=(Asia/Shanghai Asia/Hong_Kong Asia/Taipei Asia/Tokyo Asia/Singapore
    America/Los_Angeles America/New_York Europe/London Europe/Berlin Etc/UTC)
  local -a labels=('中国（北京时间）' '香港' '台北' '日本' '新加坡'
    '美国西部（洛杉矶）' '美国东部（纽约）' '英国（伦敦）' '德国等中欧国家' '世界协调时 UTC')
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  TZ_CHOICE=''
  echo "时区（当前 ${current:-未知}），常用的有："
  for i in "${!common[@]}"; do printf '  %2d. %-20s %s\n' "$((i + 1))" "${common[i]}" "${labels[i]}"; done
  echo '  也可以直接输入其他时区名（格式 地区/城市，例如 Asia/Seoul）。'
  for ((tries = 0; tries < 3; tries++)); do
    read -r -p "请选择 [1-${#common[@]}，或输入时区名；直接回车保持不变]: " answer || answer=''
    if [[ "$answer" =~ ^[0-9]{1,2}$ ]] && ((10#$answer >= 1 && 10#$answer <= ${#common[@]})); then
      answer="${common[10#$answer - 1]}"
    fi
    if [[ -z "$answer" || "$answer" == "$current" ]]; then return 0; fi
    if zone="$(timezone_resolve "$answer")"; then TZ_CHOICE="$zone"; return 0; fi
    suggestions=''
    if [[ "$answer" =~ ^[A-Za-z0-9_+/-]+$ ]]; then
      suggestions="$(timedatectl list-timezones 2>/dev/null | grep -Fi -- "$answer" | head -n 5 | tr '\n' ' ' || true)"
    fi
    if [[ -n "$suggestions" ]]; then warn "没有这个时区：$answer。你是不是想输入：$suggestions"
    else warn "没有这个时区：$answer（格式是 地区/城市，例如 Asia/Shanghai、Europe/London）。"; fi
  done
}

# Every choice for the rest of setup is asked here, so the long automatic part
# runs unattended; only the SSH/firewall confirmations at the end need the user.
setup_questions() {
  step 3 '开荒选项（一次问完，之后自动执行）'
  local login ip question
  if [[ "${RECOMMENDED:-0}" == 1 ]]; then
    # Recommended set: low-risk items only. Everything else stays off and can
    # be turned on later from the single-item menu.
    INSTALL_TOOLS=1 SYSCTL_CHOICE=1 TCP_BUFFER_CHOICE=0 VNSTAT_CHOICE=0 ZRAM_CHOICE=0 AUTO_REBOOT_TIME=''
    # Only raised ceilings and two safe switches: in the set from 1 GiB of RAM.
    if ((MEM_MIB >= 1024)); then TCP_BUFFER_CHOICE=1; fi
    KERNEL_CLEAN_CHOICE="$UPGRADE_APPROVED" HOSTS_CHOICE=1 TZ_CHOICE='' TZ_ASKED=1 KEEPALIVE_CHOICE=1 IPV4_CHOICE=0 LOGIN_CHOICE=1
    # Preferring IPv4 only where IPv6 is broken here.
    if ipv6_broken; then IPV4_CHOICE=1; fi
    printf '已按推荐设置记下：安装常用工具、启用内核网络安全参数%s、SSH 保活、登录记录和提醒%s、升级后清理旧内核、需要时修复主机名；时区保持不变。\n' \
      "$(if ((TCP_BUFFER_CHOICE)); then echo '、TCP 调优'; fi)" "$(if ((IPV4_CHOICE)); then echo '、优先使用 IPv4（这里的 IPv6 连不通）'; fi)"
  else
    if confirm_yes "安装常用工具（${TOOLS_PACKAGES[*]}）吗？"; then INSTALL_TOOLS=1; fi
    if confirm_yes '安装 vnStat 流量统计吗？（按流量计费的 VPS 推荐，之后用 vnstat 命令查看用量）'; then VNSTAT_CHOICE=1; else VNSTAT_CHOICE=0; fi
    if ((UPGRADE_APPROVED)); then
      if confirm_yes '升级后清理不再需要的旧内核吗？（保留正在运行的和最新的内核，先模拟确认；删除后无法撤销）'; then KERNEL_CLEAN_CHOICE=1; else KERNEL_CLEAN_CHOICE=0; fi
    fi
    if ((AUTO_UPDATES)); then
      read -r -p '自动安全更新需要重启时，允许每天几点自动重启？输入服务器时间（例如 04:00），直接回车表示不自动重启: ' AUTO_REBOOT_TIME || AUTO_REBOOT_TIME=''
      if [[ -n "$AUTO_REBOOT_TIME" ]] && ! AUTO_REBOOT_TIME="$(reboot_time_normalize "$AUTO_REBOOT_TIME")"; then
        warn '时间格式不对，按不自动重启处理。'; AUTO_REBOOT_TIME=''
      fi
    fi
    if ((MEM_MIB >= 2048)) && ! swap_exists; then
      if confirm_yes '没有 Swap：要配一个约 1/4 内存大小的 ZRAM 作为应急缓冲吗？（防止内存突然用尽时进程被杀）'; then ZRAM_CHOICE=1; else ZRAM_CHOICE=0; fi
    fi
    if confirm_default_yes '启用内核网络安全参数吗？（不接受 ICMP 重定向和源路由、开启 SYN Cookies 等；不影响代理和 Docker）'; then SYSCTL_CHOICE=1; else SYSCTL_CHOICE=0; fi
    question="把 TCP 缓冲区上限加大到 $(param_value tcp_buffer_mib) MiB 吗？（并且空闲后不重新慢启动、自动探测被丢的大包：跨洲代理、远距离传大文件时单个连接更快；只提高上限，空闲连接不会多占内存）"
    if ((MEM_MIB >= 1024)); then
      if confirm_default_yes "$question"; then TCP_BUFFER_CHOICE=1; else TCP_BUFFER_CHOICE=0; fi
    elif confirm_yes "$question"; then TCP_BUFFER_CHOICE=1; else TCP_BUFFER_CHOICE=0; fi
    if ! hostname_resolves; then
      if confirm_default_yes "主机名 $(hostname) 无法解析（sudo 会提示 unable to resolve host）。在 /etc/hosts 里补上吗？"; then HOSTS_CHOICE=1; else HOSTS_CHOICE=0; fi
    fi
    if confirm_default_yes "开启 SSH 保活吗？（SSH 连接放着不动时每 $(param_value ssh_keepalive_seconds) 秒检测一次，不会因为路由器丢掉空闲连接而卡死）"; then KEEPALIVE_CHOICE=1; else KEEPALIVE_CHOICE=0; fi
    IPV4_CHOICE=0
    if ipv6_broken && confirm_default_yes '这台机器的 IPv6 连不通外网（IPv4 正常）：改成优先使用 IPv4 吗？（不关闭 IPv6，只是先试 IPv4，免得程序卡在 IPv6 上）'; then IPV4_CHOICE=1; fi
    if confirm_default_yes '开启登录记录和提醒吗？（每次登录记一行、保存一年，包括服务商控制台的登录；登录时显示上次登录，第一次出现的 IP 标红）'; then LOGIN_CHOICE=1; else LOGIN_CHOICE=0; fi
    timezone_ask
    TZ_ASKED=1
  fi
  if confirm_yes '加固 SSH 登录吗？（只允许密钥登录，带防失联保护）（推荐）'; then
    SSH_CHOICE=1
    login="${SUDO_USER:-}"
    [[ -n "$login" && "$login" != root ]] || login="$(logname 2>/dev/null || id -un)"
    if [[ "$login" == root ]]; then
      if confirm_yes '同时新建一个普通管理员账户（带 sudo），以后用它登录，并禁止 root 直接 SSH 登录吗？（推荐）'; then
        ADMIN_CHOICE=1
        until admin_name_valid "${ADMIN_NAME:-}"; do
          read -r -p '管理员账户名（小写字母开头，例如 ops）: ' ADMIN_NAME || { ADMIN_NAME=''; ADMIN_CHOICE=0; break; }
        done
      else ADMIN_CHOICE=0; fi
    elif confirm_yes "同时禁止 root 直接 SSH 登录吗？以后用 $login 登录再 sudo。（推荐）"; then ADMIN_CHOICE=1
    else ADMIN_CHOICE=0; fi
  else
    SSH_CHOICE=0
  fi
  if confirm_yes '防火墙同时放行网站端口 TCP 80、443 吗？（只做代理或跳板可以不开，以后可用端口管理再放行）'; then WEB_CHOICE=1; else WEB_CHOICE=0; fi
  F2B_CHOICE=1
  if f2b_optional "$SSH_CHOICE"; then
    if [[ "${RECOMMENDED:-0}" == 1 ]]; then
      F2B_CHOICE=0
      echo '只允许密钥登录、内存不到 1 GiB：Fail2ban 防的是猜密码，这里猜不中，按推荐不装（省约 30 MB 内存；以后可在单项设置里开启）。'
    elif ! confirm_yes '只允许密钥登录、内存不到 1 GiB：Fail2ban 防的是猜密码，这里猜不中。仍然装 Fail2ban 吗？（约占 30 MB 内存；不装的话扫描请求照样打过来，日志会多一些）'; then
      F2B_CHOICE=0
    fi
  fi
  F2B_IGNORE_CHOICE=none
  ip="${SSH_CONNECTION:-}"; ip="${ip%% *}"
  # Asked in the recommended set too: a mistyped password must not lock the
  # administrator out (bans start at one hour and double on repeat).
  if ((F2B_CHOICE)) && [[ -n "$ip" ]] && port_source_valid "$ip" &&
     confirm_default_yes "把你当前的 IP $ip 加入 Fail2ban 白名单吗？（输错密码也不会被封，连 SSH 也不限速；家庭宽带 IP 常会变化，换了就失效）"; then
    F2B_IGNORE_CHOICE="$ip"
  fi
  echo
  echo '选项已记下。接下来自动执行，期间不需要操作（系统升级可能要几分钟到十几分钟）。'
  echo '最后的 SSH 加固和防火墙确认需要你在场，大约 5 分钟，到时会响铃提醒。'
}

# Long runs are cut off when the SSH connection drops; tmux/screen keeps them
# alive. sudo drops $TMUX, so the process ancestry is checked as well.
in_terminal_multiplexer() {
  local pid=$$ comm stat i
  [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0
  for ((i = 0; i < 20 && pid > 1; i++)); do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
    case "$comm" in tmux*|screen*|SCREEN*) return 0 ;; esac
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*) }"
    pid="${stat#* }"; pid="${pid%% *}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  done
  return 1
}

# The setup that setup_tmux_launch started is still there: running, or showing
# its result until Enter is pressed.
setup_tmux_running() {
  command -v tmux >/dev/null && tmux has-session -t '=vps-setup' 2>/dev/null
}

# -u: this tool runs with LC_ALL=C, from which tmux would conclude that the
# terminal cannot show UTF-8 and print every Chinese character as "_".
setup_tmux_attach() {
  tmux -u attach-session -t '=vps-setup' 8<&- 9>&- || true
  if setup_tmux_running; then ok '一键开荒还在后台的 tmux 里继续运行；要回去时，再输入 vps 选 2。'; fi
}

# Installs tmux when missing (recorded like every package of this tool, so a
# full rollback can offer to remove it), starts the setup in a detached session
# that keeps the SSH address and the sudo user, and attaches to it. The window
# stays open after the end until Enter, so a reconnect does not lose the result.
setup_tmux_launch() {
  local self
  self="$(readlink -f -- "${BASH_SOURCE[0]}")" || return 1
  if ! command -v tmux >/dev/null; then
    tool_prepare_data
    restore_prepare
    apt_index_ready || return 1
    if ! available tmux; then warn '软件源里找不到 tmux。'; return 1; fi
    install_pkgs tmux || return 1
    command -v tmux >/dev/null || return 1
  fi
  # The run inside tmux takes the tool's lock itself, and the tmux server
  # outlives this process: neither may keep the lock descriptors.
  tool_lock_release
  # shellcheck disable=SC2016
  tmux -u new-session -d -s vps-setup /usr/bin/env SSH_CONNECTION="${SSH_CONNECTION:-}" SUDO_USER="${SUDO_USER:-}" \
    /bin/bash -c '/bin/bash "$1" setup; code=$?; printf "\n一键开荒已结束（退出码 %s）。按回车关闭这个窗口……" "$code"; read -r _; exit "$code"' \
    bash "$self" 8<&- 9>&- || return 1
  setup_tmux_attach
}

# Long runs are cut off when the SSH connection drops: the setup offers to run
# in tmux, where a dropped connection only detaches it. Asked before the plan,
# so a setup handed to tmux shows its plan there, once.
# 0 = run the setup in this window; 1 = not here (it runs in tmux, or stopped).
session_resilience_check() {
  if in_terminal_multiplexer; then ok '正在 tmux/screen 中运行：SSH 断线后脚本会继续执行。'; return 0; fi
  if setup_tmux_running; then
    echo '一键开荒已经在 tmux 里运行（可能是之前 SSH 断线了）。'
    if confirm_default_yes '回到那个界面吗？'; then setup_tmux_attach
    else ok '没有重复开始一键开荒；要回去时，再输入 vps 选 2。'; fi
    return 1
  fi
  warn '当前不在 tmux 或 screen 里：如果 SSH 中途断开，脚本会被中断，系统升级可能停在一半。'
  if [[ -n "${TERM:-}" && "$TERM" != dumb ]]; then
    confirm_default_yes '在 tmux 里运行一键开荒吗？（推荐：断线也不会中断，重新登录输入 vps 就能回来；没有 tmux 会先自动装上）' || return 0
    if setup_tmux_launch; then return 1; fi
    warn '没能在 tmux 里启动一键开荒（原因见上方）。'
  fi
  if confirm_yes '仍然在当前窗口继续吗？'; then return 0; fi
  ok '已取消，没有开始一键开荒。'
  return 1
}

attention_banner() {
  printf '\a'
  say '需要你在场：SSH 加固与防火墙确认'
  echo '接下来会请你新开一个 SSH 窗口登录，证明修改后仍能登录：登录成功后会自动确认；没有自动确认时，回到这个窗口输入 CONNECTED。每次确认有 180 秒，超时会自动撤销对应的修改。'
}

# Removes the old kernels APT itself would autoremove, by name, never the
# running one (APT also keeps the newest and the previous kernel). Other
# leftovers of an upgrade (Ubuntu's libfwupd2, say) are not this step's
# business and no longer block it; the purge is simulated first and must remove
# exactly those kernel packages. With --ask the list is confirmed first.
kernel_cleanup() {
  local ask="${1:-}" sim pkg running
  local -a removed=() kernels=() others=() purged=()
  running="$(uname -r)"
  sim="$(apt-get -s autoremove --purge 2>&1)" || { warn '旧内核清理模拟失败，跳过。'; return 0; }
  mapfile -t removed < <(awk '$1 == "Purg" || $1 == "Remv" {sub(/:.*/, "", $2); print $2}' <<< "$sim" | sort -u)
  for pkg in "${removed[@]}"; do
    if [[ "$pkg" =~ ^linux-(image|modules|modules-extra|headers)-[0-9] && "$pkg" != *"$running"* ]]; then kernels+=("$pkg")
    elif [[ -n "$pkg" ]]; then others+=("$pkg"); fi
  done
  if ((${#kernels[@]} == 0)); then
    ok '没有需要清理的旧内核：系统会保留正在用的内核和上一个版本备用（新内核启动不了时还能选回），更旧的才会清理。'
    if ((${#others[@]})); then echo "（另有不再需要的软件包：${others[*]}，不属于内核，本工具不动，需要时可以手动运行 apt autoremove。）"; fi
    return 0
  fi
  sim="$(apt-get -s purge "${kernels[@]}" 2>&1)" || { warn '旧内核清理模拟失败，跳过。'; return 0; }
  mapfile -t purged < <(awk '$1 == "Purg" || $1 == "Remv" {sub(/:.*/, "", $2); print $2}' <<< "$sim" | sort -u)
  if [[ "$(printf '%s\n' "${purged[@]}")" != "$(printf '%s\n' "${kernels[@]}")" ]]; then
    warn '删除这些旧内核还会连带删除其他软件包，为安全起见跳过；需要时请人工处理。'; return 0
  fi
  printf '将清理旧内核：%s\n' "${kernels[*]}"
  if ((${#others[@]})); then echo "（另有不再需要的软件包：${others[*]}，不属于内核，这一步不动。）"; fi
  if [[ "$ask" == --ask ]] && ! confirm_yes '确认删除这些旧内核吗？（删除后无法撤销）'; then ok '保留旧内核。'; return 0; fi
  apt_wait_idle
  if apt_run -y -q -o DPkg::Lock::Timeout=900 purge "${kernels[@]}"; then ok "已清理 ${#kernels[@]} 个旧内核包。"
  else warn '旧内核清理失败，请人工检查。'; fi
}

# A failed APT step stops with the next step to take: a dpkg left half-way
# needs "dpkg --configure -a" first; otherwise it is usually the network or a
# mirror, and running the same step again later is safe.
apt_failure_stop() {
  local what="$1" audit
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "$audit" ]]; then
    warn "${what}没有完成，有软件包停在半安装状态（常见于中途断线或断网）。"
    echo '修复：运行 dpkg --configure -a，等它结束（再用 dpkg --audit 确认没有输出），然后重新运行刚才的操作。'
  else
    warn "${what}没有完成：通常是网络或软件源暂时有问题，具体原因见上方 APT 的英文提示。"
    echo '过几分钟重新运行刚才的操作即可，已经做好的设置会自动跳过；一直失败的话，检查 /etc/apt 里的软件源。'
  fi
  die "${what}失败，已停止；前面已经完成的设置保持不变。"
}

apt_upgrade_stage() {
  step 5 '系统升级与组件安装'
  local packages=() pkg tools=()
  if ((UPGRADE_APPROVED)); then
    apt_wait_idle
    if ! apt_run -y -q -o DPkg::Lock::Timeout=900 upgrade --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
      module_result upgrade failed 'apt-get upgrade failed'
      apt_failure_stop '系统升级'
    fi
    if ((KERNEL_UPDATE)); then module_result upgrade applied 'upgraded; new kernel needs reboot'
    else module_result upgrade applied 'upgraded'; fi
    ok '系统软件已升级；服务和内核是否生效，可用 vps check 验收。'
  elif ((UPGRADE_COUNT == 0)); then
    module_result upgrade present 'already up to date'
    ok '系统软件已经是最新的。'
  else
    module_result upgrade declined 'system upgrade not requested'
    ok '按你的选择，没有升级系统软件。'
  fi
  for pkg in ufw iproute2 procps util-linux; do
    if available "$pkg"; then packages+=("$pkg"); else warn "找不到软件包：$pkg"; fi
  done
  if (( AUTO_UPDATES )); then
    if available unattended-upgrades; then packages+=(unattended-upgrades)
    else warn '找不到 unattended-upgrades 软件包。'; fi
  fi
  if (( NEED_TIMESYNCD )); then
    if available systemd-timesyncd; then packages+=(systemd-timesyncd)
    else warn '没有可用的时间同步软件包。'; module_result ntp unsupported 'no NTP client package'; fi
  fi
  if (( INSTALL_TOOLS )); then
    for pkg in "${TOOLS_PACKAGES[@]}"; do
      if installed "$pkg"; then continue; fi
      if available "$pkg"; then tools+=("$pkg"); else warn "找不到工具软件包：$pkg"; fi
    done
    packages+=("${tools[@]}")
  fi
  if [[ "$VNSTAT_CHOICE" == 1 ]]; then
    if available vnstat; then packages+=(vnstat); else warn '找不到 vnstat 软件包。'; fi
  fi
  if ((${#packages[@]})) && ! install_pkgs "${packages[@]}"; then apt_failure_stop '安装组件（防火墙、自动更新、常用工具等）'; fi
  if (( INSTALL_TOOLS )); then module_result tools applied "${TOOLS_PACKAGES[*]}"
  else module_result tools declined 'not requested'; fi
  if [[ "$VNSTAT_CHOICE" == 1 ]]; then
    if installed vnstat && systemctl enable --now vnstat >/dev/null 2>&1; then module_result traffic applied 'vnstat'
    else warn 'vnStat 没有启动。'; module_result traffic failed 'vnstat not running'; fi
  else
    module_result traffic declined 'not requested'
  fi
  if (( NEED_TIMESYNCD )) && installed systemd-timesyncd; then timesyncd_enable; fi
  if [[ "$KERNEL_CLEAN_CHOICE" == 1 ]]; then kernel_cleanup; fi
}

timesyncd_enable() {
  systemctl enable --now systemd-timesyncd || warn '无法启用 systemd-timesyncd。'
  if timedatectl set-ntp true; then module_result ntp applied 'systemd-timesyncd installed'
  else warn '安装 systemd-timesyncd 后仍无法开启时间同步。'; module_result ntp failed 'set-ntp failed'; fi
}

# Installs the given packages for the single-item menu (tracked for optional
# removal on rollback); packages already present are left alone.
packages_stage() {
  local pkg
  local -a wanted=()
  for pkg in "$@"; do
    installed "$pkg" && continue
    if available "$pkg"; then wanted+=("$pkg"); else warn "找不到软件包：$pkg"; fi
  done
  if ((${#wanted[@]})); then install_pkgs "${wanted[@]}" || apt_failure_stop '安装软件包'; else ok '需要的软件包都已经安装好了。'; fi
}

# A one-off upgrade inside the current release, outside the full setup.
upgrade_only_stage() {
  local simulation count
  say '系统升级（只在当前大版本内）'
  simulation="$(apt-get -s upgrade --with-new-pkgs 2>&1)" || die '系统升级模拟失败；请人工检查软件包和软件源，没有执行升级。'
  count="$(grep -c '^Inst ' <<< "$simulation" || true)"
  if ((count == 0)); then ok '系统软件已经是最新的。'; module_result upgrade present 'already up to date'; return 0; fi
  grep '^Inst ' <<< "$simulation" | sed -n '1,60p' || true
  KERNEL_UPDATE=0
  if upgrade_has_kernel "$simulation"; then KERNEL_UPDATE=1; echo '本次升级包含新内核：重启后才生效，旧内核会保留。'; fi
  if ! confirm_default_yes "升级这 $count 个软件包吗？（可能重启部分服务）"; then ok '没有升级。'; return 0; fi
  apt_wait_idle
  if ! apt_run -y -q -o DPkg::Lock::Timeout=900 upgrade --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
    module_result upgrade failed 'apt-get upgrade failed'
    apt_failure_stop '系统升级'
  fi
  UPGRADE_APPROVED=1
  if ((KERNEL_UPDATE)); then module_result upgrade applied 'upgraded; new kernel needs reboot'
  else module_result upgrade applied 'upgraded'; fi
  ok '系统软件已升级。'
  echo '检查是否有可以清理的旧内核（保留正在运行的和最新的内核）：'
  kernel_cleanup --ask
}

APT_INDEX_READY=0
apt_index_ready() {
  if ((APT_INDEX_READY)); then return 0; fi
  apt_wait_idle
  echo '正在更新软件索引……'
  if apt_run update -o APT::Update::Error-Mode=any >/dev/null; then APT_INDEX_READY=1; return 0; fi
  warn '软件索引更新失败：请检查网络和软件源；如提示 "not valid yet"，先校准系统时间。'
  return 1
}

# Conservative BBR configuration checks.
# sysctl.d only guarantees whole-line # / ; comments. Do not silently remove
# trailing text from values: systemd-sysctl can treat it as part of the value.
# Scan every file conservatively, even files shadowed by a higher-priority name.
# A wildcard that could cover either target, or a targeted exclusion, also
# causes a skip. All '/' separators normalize to dots here only for detection;
# ambiguous mixed notation may cause an extra skip, never an override.
# Distribution defaults are not an administrator policy (see sysctl_vendor_default).
# Every sysctl configuration location systemd-sysctl reads (glob patterns that
# match nothing stay literal; callers skip anything that is not a file).
sysctl_config_files() {
  printf '%s\n' /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
    /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf
}

bbr_config_conflict() {
  local f line k v has_value
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if sysctl_vendor_default "$f"; then continue; fi
    if [[ ! -r "$f" ]]; then
      warn "无法读取内核参数配置 $f，跳过 BBR。"
      return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in ''|'#'*|';'*) continue ;; esac
      has_value=0
      if [[ "$line" == *=* ]]; then
        has_value=1
        k="${line%%=*}"; v="${line#*=}"
      elif [[ "$line" == -* ]]; then
        k="$line"; v=''
      else continue
      fi
      k="${k#-}"
      k="${k#"${k%%[![:space:]]*}"}"
      k="${k%"${k##*[![:space:]]}"}"
      k="${k//\//.}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      # Match sysctl glob keys intentionally, so administrator wildcard policies are preserved.
      # shellcheck disable=SC2053
      if [[ net.core.default_qdisc == $k ]]; then
        if (( !has_value )) || [[ "$v" != fq ]]; then
          warn "$f 里已有队列算法设置（$line），跳过 BBR，保持不变。"
          return 0
        fi
      fi
      # shellcheck disable=SC2053
      if [[ net.ipv4.tcp_congestion_control == $k ]]; then
        if (( !has_value )) || [[ "$v" != bbr ]]; then
          warn "$f 里已有 TCP 拥塞算法设置（$line），跳过 BBR，保持不变。"
          return 0
        fi
      fi
    done < "$f"
  done
  return 1
}

# A packaged file that systemd-sysctl applies before this tool's file (files
# run in name order, so ours wins). Ubuntu 22.04 ships 50-default.conf with
# "-net.core.default_qdisc = fq_codel" in /usr/lib/sysctl.d; Ubuntu 24.04 ships
# the same line as /etc/sysctl.d/10-bufferbloat.conf (procps), which counts
# only while it is unchanged: an edited copy is the administrator's policy.
sysctl_vendor_default() {
  local file="$1"
  [[ "${file##*/}" < "${BBR_FILE##*/}" ]] || return 1
  case "${file%/*}" in
    /usr/lib/sysctl.d|/lib/sysctl.d) return 0 ;;
    /etc/sysctl.d) conffile_unchanged "$file" ;;
    *) return 1 ;;
  esac
}

# FILE is one package's configuration file and still matches the checksum
# dpkg recorded when it was installed.
conffile_unchanged() {
  local file="$1" owner expected sum
  owner="$(dpkg-query -S -- "$file" 2>/dev/null)" || return 1
  owner="${owner%%: /*}"
  # Exactly one owning package ("a, b: path" means several).
  [[ "$owner" =~ ^[a-z0-9][a-z0-9+.:-]*$ ]] || return 1
  expected="$(dpkg-query -W -f='${Conffiles}\n' "$owner" 2>/dev/null | awk -v f="$file" '$1 == f {print $2}')" || return 1
  [[ "$expected" =~ ^[0-9a-f]{32}$ ]] || return 1
  sum="$(md5sum -- "$file" 2>/dev/null)" || return 1
  [[ "${sum%% *}" == "$expected" ]]
}

# The value systemd-sysctl gives KEY at the next boot from files other than
# this tool's: files run in name order and the last assignment wins; a name in
# /etc masks the same name further down (a /dev/null link masks it entirely).
# /run is left out (gone after a reboot), and so is /etc/sysctl.conf unless a
# sysctl.d file links to it: Debian 13 no longer reads it, while Debian 12 and
# Ubuntu do through /etc/sysctl.d/99-sysctl.conf. ROOT is for isolated tests.
sysctl_boot_value() {
  local key="$1" root="${2:-}" dir f name line k v value=''
  local -A listed=()
  local -a entries=()
  for dir in /etc/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    for f in "$root$dir"/*.conf; do
      [[ -e "$f" || -L "$f" ]] || continue
      name="${f##*/}"
      [[ -z "${listed[$name]:-}" ]] || continue
      listed[$name]=1
      entries+=("$name"$'\t'"$f")
    done
  done
  ((${#entries[@]})) || return 0
  while IFS=$'\t' read -r name f; do
    [[ "$f" != "$BBR_FILE" && -f "$f" && -r "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in ''|'#'*|';'*) continue ;; esac
      [[ "$line" == *=* ]] || continue
      k="${line%%=*}"; v="${line#*=}"
      k="${k#-}"; k="${k//[[:space:]]/}"; k="${k//\//.}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      if [[ "$k" == "$key" ]]; then value="$v"; fi
    done < "$f"
  done < <(printf '%s\n' "${entries[@]}" | sort -t $'\t' -k1,1)
  printf '%s\n' "$value"
}

# BBR and fq are in force now and another file sets them at every boot (a
# provider image, for example): this tool's own copy would only duplicate it.
bbr_set_elsewhere() {
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == bbr &&
     "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == fq &&
     "$(sysctl_boot_value net.ipv4.tcp_congestion_control "${1:-}")" == bbr &&
     "$(sysctl_boot_value net.core.default_qdisc "${1:-}")" == fq ]]
}

bbr_stage() {
  step 6 'BBR 与默认 fq 队列配置'
  local was_present=0
  local -a files=()
  mapfile -t files < <(sysctl_config_files)
  if bbr_config_conflict "${files[@]}"; then
    module_result bbr preserved 'existing TCP/qdisc policy'; return 0
  fi
  if ! modprobe tcp_bbr >/dev/null 2>&1 &&
     ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn '当前内核不支持 BBR；不会更换内核。'
    module_result bbr unsupported 'kernel has no BBR'; return 0
  fi
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn '加载模块后 BBR 仍不可用。'
    module_result bbr unsupported 'BBR unavailable after modprobe'; return 0
  fi
  if [[ ! -e "$BBR_FILE" ]]; then
    # Setting the algorithm loads tcp_bbr by itself, so no module file either.
    if bbr_set_elsewhere; then
      ok '系统已经开启 BBR 和 fq，开机时也会由别的配置文件设置，不再重复写入。'
      module_result bbr present 'set at boot by another sysctl.d file'; return 0
    fi
    if grep -Eqs '^[[:space:]]*-?net[./]ipv4[./]tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' /etc/sysctl.conf &&
       [[ "$(sysctl_boot_value net.ipv4.tcp_congestion_control)" != bbr ]]; then
      echo '/etc/sysctl.conf 里已有 BBR 设置，但这个系统开机时不会读取它（Debian 13 起不再读取），所以写入本工具的配置，保证重启后仍然生效。'
    fi
  fi
  if [[ -f "$BBR_FILE" && "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == bbr ]]; then was_present=1; fi
  if ! grep -RqsE '^[[:space:]]*tcp_bbr([[:space:]]|$)' /etc/modules-load.d/ 2>/dev/null; then
    if ! put_file "$MODULE_FILE" 'tcp_bbr'; then
      warn 'BBR 模块的开机加载配置没有写成功，运行参数保持不变。'
      module_result bbr preserved 'module file conflict'; return 0
    fi
  fi
  # Unless sysctl_boot_value showed that another file wins at boot (masking and
  # order included), this tool's own complete file is written: /run/sysctl.d
  # and an unlinked /etc/sysctl.conf are no boot persistence for systemd-sysctl.
  # put_file never overwrites an existing file.
  if ! put_file "$BBR_FILE" $'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'; then
    warn 'BBR 的持久配置没有写成功，运行参数保持不变。'
    module_result bbr preserved 'sysctl file conflict'; return 0
  fi
  if sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr; then
    if ((was_present)); then module_result bbr present 'bbr + fq'; else module_result bbr applied 'bbr + fq'; fi
  else
    warn '无法把运行中的默认算法设为 BBR + fq。'
    module_result bbr failed 'sysctl -w failed'
  fi
}

bbr_report() {
  echo '-- TCP 拥塞算法与默认队列 --'
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  echo '这里是默认值，不代表已有的连接正在用哪种算法。'
  echo '-- 网卡实际使用的队列（只读） --'
  if command -v tc >/dev/null; then
    tc -s qdisc show 2>/dev/null || warn '无法读取网卡队列。'
  else warn '缺少 tc 命令，没有检查网卡实际队列。'; fi
  echo 'default_qdisc=fq 不会替换网卡已有的队列；本工具不修改 tc 配置。'
}

# --other: this tool's own disk swap does not count.
swap_exists() {
  local own=''
  if [[ "${1:-}" == --other ]]; then own="$SWAP_FILE"; fi
  swapon --noheadings 2>/dev/null | awk -v own="$own" '$1 != own {found = 1} END {exit !found}' && return 0
  [[ -e "$ZRAM_FILE" || -d /etc/systemd/zram-generator.conf.d || -f /etc/default/zramswap ]] && return 0
  systemctl is-enabled zramswap.service >/dev/null 2>&1 && return 0
  awk '$1 !~ /^#/ && $3=="swap" {found=1} END{exit !found}' /etc/fstab 2>/dev/null && return 0
  return 1
}

# The default "[zram0]" that Debian 12 and Ubuntu's zram-generator install as
# ZRAM_FILE itself, still unchanged (Debian 13 ships it in /usr/lib instead).
zram_file_packaged() {
  [[ -f "$ZRAM_FILE" && ! -L "$ZRAM_FILE" ]] && conffile_unchanged "$ZRAM_FILE"
}

# A zram swap that only the zram-generator package's own default creates
# (/usr/lib/systemd/zram-generator.conf, or the packaged ZRAM_FILE above): no
# administrator or tool configuration and no other swap. After a rollback it
# comes back at every boot.
zram_vendor_default_only() {
  local f
  [[ -f "$ZRAM_VENDOR_FILE" ]] || zram_file_packaged || return 1
  for f in "$ZRAM_FILE" /etc/systemd/zram-generator.conf.d /run/systemd/zram-generator.conf /run/systemd/zram-generator.conf.d \
      /usr/local/lib/systemd/zram-generator.conf /usr/local/lib/systemd/zram-generator.conf.d /etc/default/zramswap; do
    if [[ "$f" == "$ZRAM_FILE" ]] && zram_file_packaged; then continue; fi
    [[ ! -e "$f" ]] || return 1
  done
  if systemctl is-enabled zramswap.service >/dev/null 2>&1; then return 1; fi
  if awk '$1 !~ /^#/ && $3=="swap" {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then return 1; fi
  ! swapon --noheadings --show=NAME 2>/dev/null | grep -qv '^/dev/zram'
}

# Ubuntu's cloud kernels leave zram out (it is in linux-modules-extra); every
# Debian kernel, the cloud one included, has it.
zram_module_available() {
  [[ -d /sys/module/zram || -d /sys/block/zram0 ]] || modinfo zram >/dev/null 2>&1
}

zram_swap_active() {
  awk 'NR > 1 && $1 == "/dev/zram0" {found = 1} END {exit !found}' /proc/swaps 2>/dev/null
}

# zram0 still set up but carrying no swap (stopped after its unit file was
# already gone, so nothing reset it) refuses a new size: it is reset here. A
# device in use or mounted is left alone; the kernel would refuse anyway.
zram_reset_idle() {
  local dev="${1:-/sys/block/zram0}"
  [[ "$(cat -- "$dev/initstate" 2>/dev/null || true)" == 1 ]] || return 0
  if zram_swap_active || grep -q '^/dev/zram0 ' /proc/mounts 2>/dev/null; then return 0; fi
  printf '1\n' > "$dev/reset" 2>/dev/null
}

# Starts the generated swap; a leftover set-up device or an earlier failed
# attempt would make the start fail again.
zram_start() {
  systemctl daemon-reload || return 1
  zram_reset_idle || true
  systemctl reset-failed systemd-zram-setup@zram0.service dev-zram0.swap >/dev/null 2>&1 || true
  systemctl start dev-zram0.swap
}

# The file of tracked resource ID is still exactly what this tool last wrote.
restore_file_ours() {
  local id="$1" fp
  [[ "$RESTORE_READY" == 1 ]] || return 1
  [[ "$(restore_read "$id" state 2>/dev/null || true)" == applied ]] || return 1
  fp="$(restore_fingerprint "$id" 2>/dev/null)" || return 1
  [[ "$fp" == "$(restore_read "$id" last_fp 2>/dev/null || true)" ]]
}

# For a swap that lives only in compressed RAM: reading neighbouring pages
# ahead (page-cluster) gains nothing there, and moving idle program memory into
# ZRAM is cheaper than dropping file cache that must be read back from disk.
zram_sysctl_pairs() {
  printf '%s\n' vm.swappiness=100 vm.page-cluster=0
}

zram_tune() {
  local pair key value current text='' existed=0
  local -a originals=() kept=()
  # A disk swap next to ZRAM would be slowed down by both values.
  if swapon --noheadings --show=NAME 2>/dev/null | grep -qv '^/dev/zram'; then return 0; fi
  while IFS= read -r pair; do
    key="${pair%%=*}"; value="${pair#*=}"
    current="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$current" ]] || continue
    if sysctl_key_configured "$key" "$ZRAM_SYSCTL_FILE"; then kept+=("$key"); continue; fi
    text+="$key = $value"$'\n'
    originals+=("$key=$current")
  done < <(zram_sysctl_pairs)
  if ((${#kept[@]})); then ok "已有其他配置的内存参数保持不变：${kept[*]}"; fi
  [[ -n "$text" ]] || return 0
  if [[ -e "$ZRAM_SYSCTL_FILE" ]]; then existed=1; fi
  put_file "$ZRAM_SYSCTL_FILE" "# VPS Stable Optimizer v2.6: ZRAM swap tuning"$'\n'"${text%$'\n'}" || return 0
  # Values read while an existing file was already in force are not originals.
  if ((existed == 0)); then
    for pair in "${originals[@]}"; do
      restore_record_sysctl "${pair%%=*}" "${pair#*=}" zram_sysctl_runtime || warn "无法记录 ${pair%%=*} 的原值；回退后要重启才会恢复默认。"
    done
  fi
  text="${text%$'\n'}"
  if sysctl -e -p "$ZRAM_SYSCTL_FILE" >/dev/null; then ok "ZRAM 配套内存参数已生效：${text//$'\n'/，}"
  else warn 'ZRAM 配套内存参数没有生效，请查看日志。'; fi
}

# The zram-generator size expression for the zram_percent parameter (the two
# usual values keep the form earlier versions wrote).
zram_size_expr() {
  case "$(param_value zram_percent)" in
    50) echo 'ram / 2' ;; 25) echo 'ram / 4' ;; 100) echo ram ;;
    *) echo "ram * $(param_value zram_percent) / 100" ;;
  esac
}

# This tool's zram-generator configuration, from the parameters.
zram_config_text() {
  printf '%s\n' '[zram0]' "zram-size = $(zram_size_expr)" "compression-algorithm = $(param_value zram_algorithm)" 'swap-priority = 100'
}

# NAME: true when swapping NAME off now is safe: what it holds fits into the
# available memory with a tenth of the RAM (at least 64 MiB) to spare.
swapoff_safe() {
  local used available total margin
  used="$(awk -v n="$1" 'NR > 1 && $1 == n {print $4}' /proc/swaps)"
  [[ -n "$used" ]] || return 0
  available="$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)"
  total="$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)"
  [[ "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
  margin=$((total / 10)); ((margin >= 65536)) || margin=65536
  ((available > used + margin))
}

swap_file_active() {
  awk -v n="$SWAP_FILE" 'NR > 1 && $1 == n {found = 1} END {exit !found}' /proc/swaps 2>/dev/null
}

# This tool's swap unit: used after ZRAM (priority 10 against 100), pulled in
# by swap.target at boot; fstab is left alone.
swap_unit_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.8: disk swap, used after ZRAM' '[Unit]' 'Description=Disk swap (VPS Stable Optimizer)' \
    '[Swap]' "What=$SWAP_FILE" 'Priority=10' '[Install]' 'WantedBy=swap.target'
}

# MIB: writes the swap file (allocated, without holes), formats and starts it.
swap_create() {
  local mib="$1"
  if ! fallocate -l "${mib}M" -- "$SWAP_FILE" 2>/dev/null; then
    rm -f -- "$SWAP_FILE"
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$mib" status=none || { rm -f -- "$SWAP_FILE"; return 1; }
  fi
  if ! chmod 600 -- "$SWAP_FILE" || ! mkswap -- "$SWAP_FILE" >/dev/null; then rm -f -- "$SWAP_FILE"; return 1; fi
}

# Disk swap: where there is no other swap (on its own when RAM is under 2 GiB
# and ZRAM cannot be used, or when asked for), on ext4 or xfs only, never
# leaving less than 3 GB free on the system disk.
swap_stage() {
  step 4 '硬盘 Swap（没有别的 Swap 时的应急）'
  local mib free current
  if [[ "${SWAP_CHOICE:-}" != 1 ]]; then
    if ((MEM_MIB >= 2048)); then ok '内存不少于 2GiB，不需要硬盘 Swap。'; module_result swap skipped 'RAM >= 2GiB'; return 0; fi
    # A setup run again finds this tool's own swap: that one is checked below.
    if swap_exists --other; then
      ok '已有 Swap 或 ZRAM，不需要硬盘 Swap。'; module_result swap skipped 'other swap present'; return 0
    fi
  fi
  case "$VIRT" in openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman|wsl)
    warn "容器类虚拟化（$VIRT）不允许自己开 Swap，跳过。"; module_result swap unsupported "$VIRT"; return 0 ;;
  esac
  case "$ROOT_FS" in ext4|xfs) ;; *)
    warn "系统盘是 $ROOT_FS 文件系统：本工具只在 ext4、xfs 上建硬盘 Swap，跳过。"; module_result swap unsupported "$ROOT_FS"; return 0 ;;
  esac
  mib="$(param_value swap_mib)"
  if [[ -e "$SWAP_UNIT_FILE" || -e "$SWAP_FILE" ]]; then
    if ! restore_file_ours swap_unit || [[ ! -f "$SWAP_FILE" ]]; then
      warn "$SWAP_FILE 或 $SWAP_UNIT_FILE 已经存在，不是本工具上次建的，保持不变。"; module_result swap preserved 'swap file exists'; return 0
    fi
    current="$(($(stat -c %s -- "$SWAP_FILE") / 1048576))"
    if ((current == mib)) && swap_file_active; then
      ok "硬盘 Swap 已经是 ${mib} MiB。"; module_result swap applied "$mib MiB"; return 0
    fi
    # A new size: the file is made again, its contents first back into RAM.
    if swap_file_active && ! swapoff_safe "$SWAP_FILE"; then
      warn "可用内存不够，现在不能停用硬盘 Swap 来改大小（保持 ${current} MiB）；内存空一些时再试。"; module_result swap applied "$current MiB"; return 0
    fi
    systemctl stop swapfile.swap 2>/dev/null || swapoff -- "$SWAP_FILE" 2>/dev/null || true
    rm -f -- "$SWAP_FILE"
  elif swapon --noheadings 2>/dev/null | grep . > /dev/null; then
    ok '已有其他 Swap：这个硬盘 Swap 排在它们后面用。'
  fi
  free="$(df -Pm / | awk 'NR == 2 {print $4}')"
  [[ "$free" =~ ^[0-9]+$ ]] || { warn '读不到系统盘的剩余空间，跳过。'; module_result swap failed 'free space unknown'; return 0; }
  if ((free - mib < 3072)); then
    if ((free - 3072 < 128)); then
      warn "系统盘只剩 ${free} MiB：建了 Swap 就不够 3 GB 了，跳过。"; module_result swap unsupported 'not enough disk space'; return 0
    fi
    mib=$(((free - 3072) / 64 * 64))
    ok "系统盘只剩 ${free} MiB，为了留够 3 GB，Swap 缩小到 ${mib} MiB。"
  fi
  if ! swap_create "$mib"; then warn '建硬盘 Swap 文件失败，已删除。'; module_result swap failed 'swap file not created'; return 0; fi
  if [[ ! -f "$SWAP_UNIT_FILE" ]] && ! put_file "$SWAP_UNIT_FILE" "$(swap_unit_text)"; then
    rm -f -- "$SWAP_FILE"; module_result swap preserved 'swap unit conflict'; return 0
  fi
  if systemctl daemon-reload && systemctl enable --now swapfile.swap >/dev/null 2>&1 && swap_file_active; then
    ok "硬盘 Swap 已开启：${mib} MiB（$SWAP_FILE，排在 ZRAM 后面用）。"
    # Next to a disk swap the ZRAM values (swappiness 100, page-cluster 0) would
    # slow the disk down: this tool's own go back.
    if restore_file_ours zram_sysctl_file; then
      restore_resource zram_sysctl_file
      restore_sysctl_runtime zram_sysctl_runtime
      ok '有了硬盘 Swap，ZRAM 的配套内存参数恢复成默认值。'
    fi
    module_result swap applied "$mib MiB"
  else
    warn '硬盘 Swap 没有启动，请运行 systemctl status swapfile.swap 查看原因。'; module_result swap failed 'swapfile.swap did not start'
  fi
}

zram_stage() {
  step 4 '内存与 ZRAM（在系统升级前配置）'
  local size vendor=0
  # Without the module nothing below applies, whatever swap there is.
  if ! zram_module_available; then
    if restore_file_ours zram_file; then
      warn '本工具的 ZRAM 配置还在，但这个内核没有 zram 模块，ZRAM 无法启动；可以在撤销里撤销 ZRAM。'
    else
      warn '这个内核没有 zram 模块，跳过 ZRAM（Ubuntu 云镜像的精简内核把它放在 linux-modules-extra 包里，占几百 MB，且每次升级内核都要跟着装，本工具不自动安装）。'
    fi
    module_result zram unsupported 'kernel has no zram module'; return 0
  fi
  if swap_exists; then
    # The package default is replaced by this tool's own file when asked for
    # explicitly, or when it runs no swap at all (Ubuntu installs it unstarted).
    if zram_vendor_default_only && { [[ "${ZRAM_CHOICE:-}" == 1 ]] || ! swapon --noheadings 2>/dev/null | grep -q .; }; then
      vendor=1
      echo '现在只有 systemd-zram-generator 软件包自带的默认 ZRAM 配置（约内存一半），改用本工具的配置。'
    elif restore_file_ours zram_file && ! swapon --noheadings 2>/dev/null | grep -q .; then
      echo '本工具的 ZRAM 配置还在，但 ZRAM 没有运行（可能上次启动失败）：重新启动它。'
      if zram_start; then zram_tune; module_result zram applied 'zram0 restarted'
      else warn 'ZRAM 仍然没有启动，请运行 systemctl status systemd-zram-setup@zram0 查看原因。'; module_result zram failed 'dev-zram0.swap did not start'; fi
      swapon --show || true
      return 0
    elif restore_file_ours zram_file && zram_swap_active && [[ "$(cat -- "$ZRAM_FILE" 2>/dev/null || true)" != "$(zram_config_text)" ]]; then
      # New parameters for this tool's ZRAM: a swap in use cannot be resized
      # safely, so the new configuration applies from the next boot.
      rm -f -- "$ZRAM_FILE"
      if put_file "$ZRAM_FILE" "$(zram_config_text)"; then
        systemctl daemon-reload || true
        ok "ZRAM 设置已改成 $(zram_size_expr)、$(param_value zram_algorithm) 压缩，重启后生效（正在使用的 ZRAM 不能直接改）。"
        zram_tune; module_result zram applied "zram0 = $(zram_size_expr) (from next boot)"
      else module_result zram preserved 'zram config conflict'; fi
      return 0
    else
      ok '已有 Swap/ZRAM，保持不变。'; swapon --show || true
      # A ZRAM this tool set up earlier also gets the tuning added later.
      if restore_file_ours zram_file && zram_swap_active; then
        zram_tune; module_result zram present 'zram0 (this tool)'
      else module_result zram preserved 'existing swap/zram'; fi
      return 0
    fi
  fi
  if ((MEM_MIB >= 2048)) && [[ "${ZRAM_CHOICE:-}" != 1 ]]; then
    ok '内存不少于 2GiB：按你的选择不新增 ZRAM。'
    module_result zram skipped 'RAM >= 2GiB'; return 0
  fi
  size="$(zram_size_expr)"
  if ! available systemd-zram-generator; then
    warn '软件源里没有 systemd-zram-generator，跳过 ZRAM。'
    module_result zram unsupported 'package unavailable'; return 0
  fi
  install_pkgs systemd-zram-generator || apt_failure_stop '安装 ZRAM 组件'
  # Debian 12 and Ubuntu install their default "[zram0]" right at ZRAM_FILE; an
  # unchanged copy is replaced (Debian 13 keeps that default in /usr/lib).
  if zram_file_packaged; then rm -f -- "$ZRAM_FILE"; fi
  # zstd packs about a third more into the same RAM than the kernel default;
  # zram-generator only warns and keeps the default if the kernel lacks it.
  if put_file "$ZRAM_FILE" "$(zram_config_text)"; then
    if ((vendor)) && zram_swap_active; then
      systemctl daemon-reload
      # Resizing a zram swap in use is not safe: the new size applies from the next boot.
      ok "已写入本工具的 ZRAM 配置（$size），重启后按这个大小生效；现在先保留正在使用的 ZRAM。"
      zram_tune
      module_result zram applied "zram0 = $size (from next boot)"
    elif zram_start; then zram_tune; module_result zram applied "zram0 = $size"
    else warn 'ZRAM 没有启动，请检查服务。'; module_result zram failed 'dev-zram0.swap did not start'; fi
  else
    module_result zram preserved 'zram config conflict'
  fi
  swapon --show || true
}

# Runs before APT: a clock that is days off makes Release files "not valid yet".
ntp_synced() {
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]
}
ntp_stage() {
  step 1 '时间同步（不修改时区，先于软件更新）'
  local pkg i
  if ntp_synced; then ok '时间已经同步。'; module_result ntp present 'synchronized'; return 0; fi
  if timedatectl set-ntp true >/dev/null 2>&1; then
    for ((i = 0; i < 15; i++)); do ntp_synced && break; sleep 2; done
    if ntp_synced; then ok '已通过现有的时间同步服务校准时间。'; module_result ntp applied 'synchronized'
    else warn '已开启时间同步，但暂未完成同步，继续执行。'; module_result ntp applied 'requested; not yet synchronized'; fi
    return 0
  fi
  for pkg in chrony ntpsec openntpd ntp; do
    if installed "$pkg"; then
      warn "已装有其他时间同步软件 $pkg，但没有同步，保持不变，请人工检查。"
      module_result ntp preserved "$pkg"; return 0
    fi
  done
  # Installation needs a fresh package index, so it happens in the upgrade stage.
  NEED_TIMESYNCD=1
  echo '未找到可用的时间同步服务：将在软件索引更新后安装 systemd-timesyncd。'
  module_result ntp skipped 'timesyncd install pending'
}

# This tool's journald drop-in, from the parameters (runtime journal: half the
# persistent cap, at least 16 MiB).
journal_config_text() {
  local max days runtime
  max="$(param_value journal_max_mb)" days="$(param_value journal_days)"
  runtime=$((max / 2)); ((runtime >= 16)) || runtime=16
  printf '%s\n' '[Journal]' "SystemMaxUse=${max}M" "RuntimeMaxUse=${runtime}M" "MaxRetentionSec=${days}day"
}

journal_stage() {
  step 8 '日志空间（仅小硬盘）'
  # The single-item menu may ask for the limit on a larger disk too.
  if ((ROOT_GIB>JOURNAL_LIMIT_GB)) && [[ "${JOURNAL_FORCE:-0}" != 1 ]]; then
    ok "系统盘 ${ROOT_GIB}GiB，大于 ${JOURNAL_LIMIT_GB}GiB，保持日志默认设置。"
    module_result journal skipped "root disk > ${JOURNAL_LIMIT_GB}GiB"; return 0
  fi
  local f
  while IFS= read -r f; do
    [[ -f "$f" && "$f" != "$JOURNAL_FILE" ]] || continue
    if [[ ! -r "$f" ]]; then warn "无法读取已有日志策略 $f，保持不变。"; module_result journal preserved 'unreadable policy'; return 0; fi
    if grep -Eq '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|MaxRetentionSec)[[:space:]]*=' "$f"; then
      ok "$f 里已有日志限制，保持不变。"; module_result journal preserved "$f"; return 0
    fi
  done < <(journal_policy_paths)
  # New parameters (or the 14 days of earlier versions): this tool's own file
  # is written again.
  if [[ -f "$JOURNAL_FILE" && "$(cat -- "$JOURNAL_FILE" 2>/dev/null || true)" != "$(journal_config_text)" ]] && restore_file_ours journal_file; then
    rm -f -- "$JOURNAL_FILE"
  fi
  if put_file "$JOURNAL_FILE" "$(journal_config_text)"; then
    if systemctl restart systemd-journald; then
      ok "日志上限 $(param_value journal_max_mb) MiB、保留 $(param_value journal_days) 天（$(param_mode journal_days)）。"
      module_result journal applied "SystemMaxUse=$(param_value journal_max_mb)M"
    else warn '日志服务重启失败。'; module_result journal failed 'journald restart failed'; fi
  else
    module_result journal preserved 'journal config conflict'
  fi
}

# Fails only when the root device reports no discard support (DISC-MAX 0B);
# anything unreadable counts as supported and fstrim decides.
trim_support() {
  local dev="${ROOT_DEV%%\[*}" max
  [[ "$dev" == /dev/* ]] || return 0
  command -v lsblk >/dev/null || return 0
  max="$(lsblk -dn -o DISC-MAX "$dev" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$max" != 0B && "$max" != 0 ]]
}

trim_stage() {
  step 9 'TRIM 支持检测'
  case "$ROOT_FS" in ext4|xfs|btrfs) ;; *) ok "系统盘文件系统是 $ROOT_FS，跳过 TRIM。"; module_result trim skipped "filesystem $ROOT_FS"; return 0 ;; esac
  [[ "$ROOT_DEV" == /dev/* ]] || { ok '系统盘不是可直接识别的块设备，跳过 TRIM。'; module_result trim skipped 'not a block device'; return 0; }
  # Checked before the timer: images often ship fstrim.timer enabled on disks without discard.
  if ! trim_support; then
    ok '系统盘不支持 TRIM（DISC-MAX 为 0），跳过；fstrim.timer 保持原样。'
    module_result trim unsupported 'disk reports no discard support'; return 0
  fi
  if systemctl is-enabled -q fstrim.timer 2>/dev/null; then ok '定期 TRIM 已经启用。'; module_result trim present 'fstrim.timer'; return 0; fi
  command -v fstrim >/dev/null || { warn '没有安装 fstrim。'; module_result trim unsupported 'fstrim missing'; return 0; }
  if fstrim -v /; then
    if systemctl enable --now fstrim.timer; then module_result trim applied 'fstrim.timer'
    else warn '无法启用定期 TRIM。'; module_result trim failed 'timer not enabled'; fi
  else ok '磁盘不支持 TRIM，跳过。'; module_result trim unsupported 'device rejects TRIM'; fi
}

# A stopped APT timer catches up at once when started again (Persistent=true):
# the automatic update then holds the package lock while the setup goes on
# installing packages, for well over its 15 minutes on a long-unpatched
# machine. Marking the last run as now leaves the first one for the timer's
# usual time; a timer that already runs is left as it is.
apt_timers_postpone() {
  local dir="${1:-/var/lib/systemd/timers}" t
  for t in apt-daily apt-daily-upgrade; do
    if ! active "$t.timer" && [[ -f "$dir/stamp-$t.timer" && ! -L "$dir/stamp-$t.timer" ]]; then
      touch -- "$dir/stamp-$t.timer" 2>/dev/null || true
    fi
  done
}

# APT's parsed configuration covers every syntax (including blocks) and file.
# A key it does not report is filled in with this tool's file (some images set
# only Update-Package-Lists, which leaves security updates off); a key set to
# anything but "1" was chosen by someone, and the policy is kept as it is.
updates_stage() {
  step 10 '自动安全更新'
  if (( !AUTO_UPDATES )); then ok '自动更新策略保持不变。'; module_result updates declined 'not requested'; return 0; fi
  installed unattended-upgrades || { warn '没有安装 unattended-upgrades。'; module_result updates unsupported 'package missing'; return 0; }
  local periodic key value text='' custom='' off=0 files result=applied detail='periodic updates'
  periodic="$(apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) ' || true)"
  for key in Update-Package-Lists Unattended-Upgrade; do
    value="$(awk -v k="APT::Periodic::$key" '$1 == k {v = $2} END {gsub(/^"|";?$/, "", v); print v}' <<< "$periodic")"
    if [[ -z "$value" ]]; then text+="APT::Periodic::$key \"1\";"$'\n'
    elif [[ "$value" != 1 ]]; then
      custom+="APT::Periodic::$key \"$value\"; "
      if [[ "$value" =~ ^0+$ ]]; then off=1; fi
    fi
  done
  if [[ -n "$custom" ]] && ((off)); then
    files="$(grep -lsE 'Periodic' /etc/apt/apt.conf /etc/apt/apt.conf.d/* 2>/dev/null | tr '\n' ' ' || true)"
    warn "已有的更新策略关闭了自动更新（${custom% }），按原样保留：自动安全更新现在没有开启。要开启，先把这一项改成 \"1\"（可能在：${files:-/etc/apt/apt.conf.d}），再选开启。"
    result=preserved detail='原有策略关闭了自动安全更新，没有开启'
  elif [[ -n "$custom" ]]; then
    warn "已有自定义的定期更新策略（${custom% }），不覆盖。"; result=preserved
  elif [[ -z "$text" ]]; then ok '自动安全更新原本就已开启。'; result=present
  elif ! put_file "$APT_FILE" "${text%$'\n'}"; then result=preserved
  elif [[ -n "$periodic" ]]; then
    ok "原有策略里缺少的设置已补上：$(tr '\n' ' ' <<< "${text%$'\n'}")"
  fi
  apt_timers_postpone
  if systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then
    apt_time_apply
    module_result updates "$result" "$detail"
  else warn '无法启用 APT 定时器。'; module_result updates failed 'timers not enabled'; fi
}

# Optional reboot window for updates that need one (new kernels). An existing
# Automatic-Reboot policy in any other APT file is kept.
auto_reboot_configure() {
  local policy
  if [[ -z "${AUTO_REBOOT_TIME:-}" ]]; then module_result autoreboot declined 'no automatic reboot'; return 0; fi
  [[ "$AUTO_REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { module_result autoreboot failed 'invalid time'; return 0; }
  # Without this tool's own file, any value APT reports was set by someone else
  # (in any syntax); with it, put_file below keeps a differing file as it is.
  if [[ ! -e "$APT_REBOOT_FILE" ]]; then
    policy="$(apt-config dump 2>/dev/null | grep -E '^Unattended-Upgrade::Automatic-Reboot(-Time)? ' || true)"
    if [[ -n "$policy" ]]; then
      warn "已有自动重启策略（$(tr '\n' ' ' <<< "$policy")），保持不变。"; module_result autoreboot preserved 'existing policy'; return 0
    fi
  fi
  if put_file "$APT_REBOOT_FILE" "Unattended-Upgrade::Automatic-Reboot \"true\";"$'\n'"Unattended-Upgrade::Automatic-Reboot-Time \"$AUTO_REBOOT_TIME\";"; then
    ok "需要重启的安全更新会在每天 $AUTO_REBOOT_TIME 自动重启生效。"
    module_result autoreboot applied "$AUTO_REBOOT_TIME"
  else
    module_result autoreboot preserved 'reboot policy file conflict'
  fi
}

timezone_stage() {
  step 11 '时区'
  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "${TZ_ASKED:-0}" != 1 ]]; then timezone_ask; fi
  if [[ -z "${TZ_CHOICE:-}" || "$TZ_CHOICE" == "$current" ]]; then
    ok "时区保持不变：${current:-未知}"; module_result timezone declined "${current:-unknown}"; return 0
  fi
  if ! timezone_resolve "$TZ_CHOICE" >/dev/null; then
    warn "没有这个时区：$TZ_CHOICE，保持不变。"; module_result timezone failed 'unknown timezone'; return 0
  fi
  if timedatectl set-timezone "$TZ_CHOICE"; then ok "时区已设为 $TZ_CHOICE"; module_result timezone applied "$TZ_CHOICE"
  else warn '无法设置时区。'; module_result timezone failed 'set-timezone failed'; fi
}

# Level-1 style network hardening that leaves forwarding alone (Docker,
# WireGuard and proxies need it). A key already set anywhere else keeps its
# value; the running values before the change are recorded for rollback.
sysctl_hardening_pairs() {
  printf '%s\n' \
    net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.default.accept_redirects=0 \
    net.ipv6.conf.all.accept_redirects=0 net.ipv6.conf.default.accept_redirects=0 \
    net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.default.send_redirects=0 \
    net.ipv4.conf.all.accept_source_route=0 net.ipv4.conf.default.accept_source_route=0 \
    net.ipv6.conf.all.accept_source_route=0 net.ipv4.tcp_syncookies=1 \
    net.ipv4.icmp_echo_ignore_broadcasts=1 net.ipv4.icmp_ignore_bogus_error_responses=1 \
    kernel.kptr_restrict=2 kernel.dmesg_restrict=1
}

# True when KEY is assigned in any sysctl configuration file other than ours
# (OWN, the hardening file by default).
sysctl_key_configured() {
  local key="$1" own="${2:-$SYSCTL_HARDENING_FILE}" f line k
  while IFS= read -r f; do
    [[ -f "$f" && "$f" != "$own" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in ''|'#'*|';'*) continue ;; esac
      k="${line%%=*}"; k="${k#-}"; k="${k//[[:space:]]/}"; k="${k//\//.}"
      [[ -n "$k" ]] || continue
      # Glob keys (net.ipv4.conf.*.accept_redirects) count as well.
      # shellcheck disable=SC2053
      if [[ "$key" == $k ]]; then return 0; fi
    done < "$f"
  done < <(sysctl_config_files)
  return 1
}

# IPv6 reads accept_redirects only from each interface: all/default never reach
# an interface that already exists (eth0 comes up before systemd-sysctl at
# boot). Prints "key=value" for every existing interface (not all/default).
# The running net.ipv4.conf.<interface>.KEY of every interface, as KEY=VALUE.
sysctl_ipv4_iface_values() {
  local key="$1" f iface
  for f in "${2:-/proc/sys/net/ipv4/conf}"/*/"$key"; do
    [[ -f "$f" ]] || continue
    iface="${f%/"$key"}"; iface="${iface##*/}"
    [[ "$iface" =~ ^[A-Za-z0-9_-]+$ && "$iface" != all && "$iface" != default ]] || continue
    printf 'net.ipv4.conf.%s.%s=%s\n' "$iface" "$key" "$(cat -- "$f" 2>/dev/null || true)"
  done
}

sysctl_ipv6_iface_redirects() {
  local f iface
  for f in "${1:-/proc/sys/net/ipv6/conf}"/*/accept_redirects; do
    [[ -f "$f" ]] || continue
    iface="${f%/accept_redirects}"; iface="${iface##*/}"
    # Dotted names (VLANs) cannot be written in sysctl's dotted key notation.
    [[ "$iface" =~ ^[A-Za-z0-9_-]+$ && "$iface" != all && "$iface" != default ]] || continue
    printf 'net.ipv6.conf.%s.accept_redirects=%s\n' "$iface" "$(cat -- "$f" 2>/dev/null || true)"
  done
}

sysctl_hardening_stage() {
  step 7 '内核网络安全参数（可选）'
  local pair key value current text='' content
  local -a kept=() originals=() ifaces=()
  if [[ "${SYSCTL_CHOICE:-}" != 1 ]]; then ok '按你的选择不修改内核网络参数。'; module_result sysctl declined 'not requested'; return 0; fi
  while IFS= read -r pair; do
    key="${pair%%=*}"; value="${pair#*=}"
    current="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$current" ]] || continue
    if sysctl_key_configured "$key"; then kept+=("$key"); continue; fi
    text+="$key = $value"$'\n'
    originals+=("$key=$current")
  done < <(sysctl_hardening_pairs)
  # The glob reaches every interface at boot and on hotplug (udev runs
  # systemd-sysctl for each new interface); existing ones are written below.
  if [[ "$text" == *'net.ipv6.conf.all.accept_redirects = 0'* ]]; then
    text+='net.ipv6.conf.*.accept_redirects = 0'$'\n'
    while IFS= read -r pair; do
      [[ "${pair#*=}" =~ ^[0-9]+$ ]] || continue
      ifaces+=("${pair%%=*}"); originals+=("$pair")
    done < <(sysctl_ipv6_iface_redirects)
  fi
  # After a reboot every interface comes up with the file's default values;
  # their running values now are recorded too (not changed: "all" already
  # applies), so a rollback after a reboot needs no second reboot.
  for key in accept_redirects send_redirects accept_source_route; do
    [[ "$text" == *"net.ipv4.conf.default.$key = 0"* ]] || continue
    while IFS= read -r pair; do
      if [[ "${pair#*=}" =~ ^[0-9]+$ ]]; then originals+=("$pair"); fi
    done < <(sysctl_ipv4_iface_values "$key")
  done
  if ((${#kept[@]})); then ok "已有其他配置的参数保持不变：${kept[*]}"; fi
  if [[ -z "$text" ]]; then module_result sysctl preserved 'all keys configured elsewhere'; return 0; fi
  content="# VPS Stable Optimizer v2.6: network hardening"$'\n'"${text%$'\n'}"
  # The file an earlier version of this tool wrote (without the IPv6 glob line)
  # is replaced; anything else in its place is still left alone by put_file.
  if [[ -f "$SYSCTL_HARDENING_FILE" && "$(cat -- "$SYSCTL_HARDENING_FILE" 2>/dev/null || true)" != "$content" ]] &&
     restore_file_ours sysctl_file; then
    rm -f -- "$SYSCTL_HARDENING_FILE"
  fi
  if ! put_file "$SYSCTL_HARDENING_FILE" "$content"; then
    module_result sysctl preserved 'sysctl file conflict'; return 0
  fi
  for pair in "${originals[@]}"; do
    restore_record_sysctl "${pair%%=*}" "${pair#*=}" || warn "无法记录 ${pair%%=*} 的原值；回退后要重启才会恢复默认。"
  done
  if sysctl -e -p "$SYSCTL_HARDENING_FILE" >/dev/null; then
    # Older procps ignores glob keys: each existing interface is set directly.
    for key in "${ifaces[@]}"; do sysctl -w "$key=0" >/dev/null 2>&1 || true; done
    ok '内核网络安全参数已生效。'; module_result sysctl applied "$(grep -c ' = ' "$SYSCTL_HARDENING_FILE") keys"
  else warn '部分内核参数没有生效，请查看日志。'; module_result sysctl failed 'sysctl -p failed'; fi
}

# Socket buffer ceiling by RAM. A fast long-distance single flow (a proxy
# across continents) needs a window of bandwidth x round trip, e.g. 1 Gbit/s
# x 200 ms = 25 MB, while the kernels of Debian 12/13 and Ubuntu 22.04/24.04
# stop at 6 MiB (receive) and 4 MiB (send). Kernels from mid-2025 on allow
# 32 MiB for receiving.
# Tunable parameters. Each one is either automatic, the value recommended for
# this machine, worked out again whenever it is used (so it follows a RAM or
# disk upgrade), or a value the user set, kept in PARAMS_FILE until reset and
# kept by a new setup too. The file holds "name=value" lines; only known names
# with valid values count, anything else in it is ignored.
# Lines: name, single item it belongs to, label, unit.
param_list() {
  printf '%s\t%s\t%s\t%s\n' \
    tcp_buffer_mib tcp 'TCP 缓冲区上限' MiB \
    zram_percent zram 'ZRAM 大小（占内存）' % \
    zram_algorithm zram 'ZRAM 压缩算法' '' \
    swap_mib swap '硬盘 Swap 大小' MiB \
    journal_max_mb journal '日志空间上限' MiB \
    journal_days journal '日志保留天数' 天 \
    conntrack_max conntrack '连接跟踪上限' 条 \
    conntrack_hours conntrack '已建立连接的保留时间' 小时 \
    ssh_keepalive_seconds keepalive 'SSH 保活间隔' 秒 \
    apt_upgrade_time updates '每天自动安全更新的时间' '' \
    tools_list tools '常用工具清单' '' \
    f2b_maxretry fail2ban 'Fail2ban 允许输错的次数' 次 \
    f2b_findtime_min fail2ban 'Fail2ban 统计输错的时间窗口' 分钟 \
    f2b_bantime_min fail2ban 'Fail2ban 首次封禁时长' 分钟 \
    f2b_increment fail2ban 'Fail2ban 再犯加倍' '' \
    f2b_maxtime_days fail2ban 'Fail2ban 最长封禁时长' 天 \
    notify_summary_time notify 'TG 每日汇总的时间' '' \
    notify_disk_percent notify '系统盘用到多少时提醒' % \
    notify_sudo_args notify 'sudo 通知里显示整条命令' '' \
    notify_services notify '停了要提醒的服务' '' \
    quota_alerts quota '流量到额度的百分之几时提醒' '' \
    docker_log_max_mb dockerlog '每个容器日志文件的上限' MiB \
    docker_log_files dockerlog '每个容器保留的日志文件数' 个
}

# NAME: "int" (a whole number) or "word" (one of a few names).
param_kind() {
  case "$1" in
    zram_algorithm|apt_upgrade_time|tools_list|f2b_increment|notify_summary_time|notify_sudo_args|notify_services|quota_alerts) echo word ;;
    *) echo int ;;
  esac
}

# NAME: the value recommended for this machine.
param_recommended() {
  case "$1" in
    tcp_buffer_mib)
      if ((${MEM_MIB:-0} < 1024)); then echo 16
      elif ((MEM_MIB < 4096)); then echo 32
      else echo 64; fi ;;
    # Small machines lean on it; larger ones keep it as an emergency buffer.
    zram_percent) if ((${MEM_MIB:-0} < 2048)); then echo 50; else echo 25; fi ;;
    zram_algorithm) echo zstd ;;
    # About the RAM, at most 2 GiB, in whole 64 MiB.
    swap_mib)
      if ((${MEM_MIB:-0} >= 2048)); then echo 2048
      elif ((${MEM_MIB:-0} >= 256)); then echo $((MEM_MIB / 64 * 64))
      else echo 256; fi ;;
    journal_max_mb) echo 100 ;;
    journal_days) echo 90 ;;
    # 64 entries per MiB of RAM (about 2% of it when full), 16384 to 1048576.
    conntrack_max)
      local n=$((${MEM_MIB:-0} * 64))
      ((n >= 16384)) || n=16384; ((n <= 1048576)) || n=1048576
      echo "$n" ;;
    # The kernel's own 5 days.
    conntrack_hours) echo 120 ;;
    ssh_keepalive_seconds) echo 60 ;;
    # The distribution's own time (apt-daily-upgrade.timer: 06:00, up to an hour later).
    apt_upgrade_time) echo 06:00 ;;
    tools_list) echo 'curl wget ca-certificates vim htop unzip lsof tmux' ;;
    f2b_maxretry) echo 5 ;;
    f2b_findtime_min) echo 10 ;;
    f2b_bantime_min) echo 60 ;;
    f2b_increment) echo yes ;;
    f2b_maxtime_days) echo 7 ;;
    notify_summary_time) echo 09:00 ;;
    notify_disk_percent) echo 90 ;;
    notify_sudo_args) echo no ;;
    notify_services) echo none ;;
    quota_alerts) echo '80 90 100' ;;
    docker_log_max_mb) echo 10 ;;
    docker_log_files) echo 3 ;;
    *) return 1 ;;
  esac
}

# NAME: why that value, in a sentence.
param_reason() {
  local mib
  case "$1" in
    tcp_buffer_mib)
      mib="$(param_recommended tcp_buffer_mib)"
      printf '内存 %s MiB：%s MiB 能让一个连接在 200 ms 延迟的线路上跑到约 %s Mbps，连接多时也不会占太多内存（内存小于 1 GiB 用 16，1–4 GiB 用 32，更大用 64）。\n' \
        "${MEM_MIB:-?}" "$mib" "$((mib * 1048576 * 8 / 200000))" ;;
    zram_percent)
      printf '内存 %s MiB：%s%%。内存小于 2 GiB 的机器常要用到它，配内存的一半；更大的机器只作应急，配四分之一。ZRAM 按需占内存，不用时几乎不占。\n' \
        "${MEM_MIB:-?}" "$(param_recommended zram_percent)" ;;
    zram_algorithm) echo 'zstd 压缩率最高，同样的内存能多装约三分之一；lz4 更快、更省 CPU，CPU 很弱又经常用到 ZRAM 时可以改用它。' ;;
    swap_mib)
      printf '内存 %s MiB：硬盘 Swap 只在没有 ZRAM 时作应急，约等于内存、最多 2 GiB；建好后系统盘至少还要剩 3 GB，不够时会自动缩小。\n' "${MEM_MIB:-?}" ;;
    journal_max_mb) echo '100 MiB 够一台普通服务器存几个月的系统日志，小硬盘也不会被日志占满（临时日志用它的一半）。' ;;
    journal_days) echo '90 天：出了问题（包括可能的入侵）能往回查一个季度；有大小上限兜底，天数长也不会占满硬盘。' ;;
    conntrack_max)
      printf '内存 %s MiB：每条连接记录约 320 字节，%s 条满载时约 %s MiB；不用时不占。只调大不调小：内核原来的值更大时保持不变。\n' \
        "${MEM_MIB:-?}" "$(param_recommended conntrack_max)" "$(($(param_recommended conntrack_max) * 320 / 1048576))" ;;
    conntrack_hours) echo '内核默认 5 天。只有连接跟踪表经常接近满时才需要缩短；最短 2 小时：TCP 保活每 2 小时一次，再短会误删还活着的空闲连接。' ;;
    ssh_keepalive_seconds) echo '60 秒：比常见的路由器和防火墙丢掉空闲连接的时间（几分钟）短，连接放着不动也不会卡死；断网后约 3 分钟服务器会清掉死连接。' ;;
    apt_upgrade_time) echo '系统默认每天 06:00（服务器时间）左右，随机推迟最多一小时；改到业务最闲的时候，可以避开高峰。' ;;
    tools_list) echo '装几个排查问题时常用的小工具：下载（curl、wget）、编辑（vim）、看进程（htop）、解压（unzip）、看端口（lsof）、防断线（tmux）。' ;;
    f2b_maxretry) echo '10 分钟里输错 5 次才封：自己偶尔输错不会被封，猜密码的程序试几次就被挡住。' ;;
    f2b_findtime_min) echo '只数最近 10 分钟的输错：几天前的输错不会算上，连着猜的程序很快就数满。' ;;
    f2b_bantime_min) echo '首次封 1 小时：自己输错了等一会儿还能登录，猜密码的程序多半就换别的目标了。' ;;
    f2b_increment) echo 'yes：同一个 IP 再犯，封禁时间加倍（1 小时、2 小时、4 小时……），反复来的越封越久。封禁历史至少保留 7 天，才认得出再犯。' ;;
    f2b_maxtime_days) echo '最长封 7 天：反复来的扫描基本挡住了，又不会把以后分给别人的 IP 一直封着。' ;;
    notify_summary_time) echo '每天 09:00（服务器时间）发前一天的汇总：登录、失败的登录、封禁、硬盘、内存、流量。' ;;
    notify_disk_percent) echo '用到 90% 提醒：还来得及清理；再晚满了会出各种奇怪的错误。' ;;
    notify_sudo_args) echo 'no：只说运行了哪个程序。整条命令里可能有密码，发到 Telegram 就收不回来了。' ;;
    notify_services) echo 'none：不盯任何服务。写上你自己的服务名（例如 xray nginx，用空格隔开），它们停了、恢复了都会提醒。' ;;
    quota_alerts) echo '用到 80%、90%、100% 各提醒一次：有时间换套餐或者省着用。数字以服务商面板为准。' ;;
    docker_log_max_mb) echo '每个文件 10 MiB、留 3 个：一个容器的日志最多 30 MiB，Docker 默认不设上限，日志多的容器能把硬盘写满。' ;;
    docker_log_files) echo '3 个：轮换时留下最近的几个，出了问题还能往回看一点。' ;;
  esac
}

# NAME VALUE: true when VALUE is allowed; otherwise says what is.
param_check() {
  case "$1" in
    tcp_buffer_mib)
      if [[ "$2" =~ ^[0-9]{1,3}$ ]] && ((10#$2 >= 4 && 10#$2 <= 256)); then return 0; fi
      echo '请输入 4 到 256 之间的整数（单位 MiB）。' ;;
    zram_percent)
      if [[ "$2" =~ ^[0-9]{1,3}$ ]] && ((10#$2 >= 10 && 10#$2 <= 150)); then return 0; fi
      echo '请输入 10 到 150 之间的整数（占内存的百分比）。' ;;
    zram_algorithm)
      case "$2" in zstd|lz4|lzo-rle) return 0 ;; esac
      echo '请输入 zstd、lz4 或 lzo-rle。' ;;
    swap_mib)
      if [[ "$2" =~ ^[0-9]{1,5}$ ]] && ((10#$2 >= 128 && 10#$2 <= 8192)); then return 0; fi
      echo '请输入 128 到 8192 之间的整数（单位 MiB）。' ;;
    journal_max_mb)
      if [[ "$2" =~ ^[0-9]{1,4}$ ]] && ((10#$2 >= 16 && 10#$2 <= 4096)); then return 0; fi
      echo '请输入 16 到 4096 之间的整数（单位 MiB）。' ;;
    journal_days)
      if [[ "$2" =~ ^[0-9]{1,4}$ ]] && ((10#$2 >= 1 && 10#$2 <= 3650)); then return 0; fi
      echo '请输入 1 到 3650 之间的整数（天）。' ;;
    conntrack_max)
      if [[ "$2" =~ ^[0-9]{1,7}$ ]] && ((10#$2 >= 16384 && 10#$2 <= 4194304)); then return 0; fi
      echo '请输入 16384 到 4194304 之间的整数（条）。' ;;
    conntrack_hours)
      if [[ "$2" =~ ^[0-9]{1,3}$ ]] && ((10#$2 >= 2 && 10#$2 <= 720)); then return 0; fi
      echo '请输入 2 到 720 之间的整数（小时）。' ;;
    ssh_keepalive_seconds)
      if [[ "$2" =~ ^[0-9]{1,3}$ ]] && ((10#$2 >= 15 && 10#$2 <= 600)); then return 0; fi
      echo '请输入 15 到 600 之间的整数（秒）。' ;;
    apt_upgrade_time)
      if [[ "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then return 0; fi
      echo '请输入 24 小时制的时间，例如 03:30。' ;;
    tools_list)
      local pkg n=0
      for pkg in $2; do
        n=$((n + 1))
        [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]{1,62}$ ]] || { echo "软件包名不对：$pkg"; return 1; }
      done
      if ((n >= 1 && n <= 30)); then return 0; fi
      echo '请输入 1 到 30 个软件包名，用空格隔开。' ;;
    f2b_maxretry)
      if [[ "$2" =~ ^[0-9]{1,2}$ ]] && ((10#$2 >= 2 && 10#$2 <= 20)); then return 0; fi
      echo '请输入 2 到 20 之间的整数（次）。' ;;
    f2b_findtime_min)
      if [[ "$2" =~ ^[0-9]{1,4}$ ]] && ((10#$2 >= 1 && 10#$2 <= 1440)); then return 0; fi
      echo '请输入 1 到 1440 之间的整数（分钟）。' ;;
    f2b_bantime_min)
      if [[ "$2" =~ ^[0-9]{1,5}$ ]] && ((10#$2 >= 1 && 10#$2 <= 10080)); then return 0; fi
      echo '请输入 1 到 10080 之间的整数（分钟，最多 7 天）。' ;;
    f2b_increment)
      case "$2" in yes|no) return 0 ;; esac
      echo '请输入 yes（再犯加倍）或 no（每次都封首次那么久）。' ;;
    f2b_maxtime_days)
      if [[ "$2" =~ ^[0-9]{1,3}$ ]] && ((10#$2 >= 1 && 10#$2 <= 365)); then return 0; fi
      echo '请输入 1 到 365 之间的整数（天）。' ;;
    notify_summary_time)
      if [[ "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then return 0; fi
      echo '请输入 24 小时制的时间，例如 09:00。' ;;
    notify_disk_percent)
      if [[ "$2" =~ ^[0-9]{2}$ ]] && ((10#$2 >= 50 && 10#$2 <= 99)); then return 0; fi
      echo '请输入 50 到 99 之间的整数（%）。' ;;
    notify_sudo_args)
      case "$2" in yes|no) return 0 ;; esac
      echo '请输入 yes（显示整条命令）或 no（只显示程序）。' ;;
    notify_services)
      local unit count=0
      [[ "$2" == none ]] && return 0
      for unit in $2; do
        count=$((count + 1))
        [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9@._-]{0,63}$ ]] || { echo "服务名不对：$unit"; return 1; }
      done
      if ((count >= 1 && count <= 20)); then return 0; fi
      echo '请输入 1 到 20 个服务名（用空格隔开），或者 none。' ;;
    quota_alerts)
      local pct count=0
      for pct in $2; do
        count=$((count + 1))
        if [[ ! "$pct" =~ ^[0-9]{1,3}$ ]] || ((10#$pct < 1 || 10#$pct > 100)); then echo "百分比不对：$pct"; return 1; fi
      done
      if ((count >= 1 && count <= 5)); then return 0; fi
      echo '请输入 1 到 5 个 1–100 的数（用空格隔开），例如 80 90 100。' ;;
    docker_log_max_mb)
      if [[ "$2" =~ ^[0-9]{1,4}$ ]] && ((10#$2 >= 1 && 10#$2 <= 1024)); then return 0; fi
      echo '请输入 1 到 1024 之间的整数（MiB）。' ;;
    docker_log_files)
      if [[ "$2" =~ ^[0-9]{1,2}$ ]] && ((10#$2 >= 1 && 10#$2 <= 20)); then return 0; fi
      echo '请输入 1 到 20 之间的整数（个）。' ;;
    *) echo "没有这个参数：$1" ;;
  esac
  return 1
}

# NAME VALUE: what an unusual value costs; nothing when it is a sensible one.
param_caution() {
  local recommended
  recommended="$(param_recommended "$1" 2>/dev/null || echo 0)"
  case "$1" in
    tcp_buffer_mib)
      if ((10#$2 > recommended * 2)); then
        echo "比本机推荐的 $recommended MiB 大很多：只有少数连接要跑很高带宽时才用得上；连接多又同时跑满时，内核按总的 TCP 内存限制收紧，网速反而可能变慢。"
      elif ((10#$2 < 8)); then
        echo '比 Linux 默认的接收上限（6 MiB）大不了多少：本工具不会调低系统已有的值，这一项基本不起作用。'
      fi ;;
    zram_percent)
      if ((10#$2 > 100)); then echo '超过内存大小：只有数据很好压缩时才装得满，内存很紧时还会多占 CPU；一般不超过 100。'
      elif ((10#$2 < 20)); then echo '这么小的 ZRAM 应急作用有限。'; fi ;;
    swap_mib)
      if ((10#$2 > ${MEM_MIB:-0} * 2)); then echo '比内存大一倍以上：硬盘 Swap 很慢，太大只会让机器在内存不够时卡很久，而不是及时报错。'; fi ;;
    journal_max_mb)
      if ((10#$2 * 50 > ${ROOT_GIB:-0} * 1024)); then echo "超过系统盘（${ROOT_GIB:-?} GiB）的 2%：日志会占掉不少空间。"; fi ;;
    journal_days)
      if ((10#$2 < 7)); then echo '不到一周：出了问题回头查的时候，当时的日志可能已经删了。'; fi ;;
    conntrack_max)
      if ((10#$2 * 320 > ${MEM_MIB:-0} * 1048576 / 16)); then echo "满载时约 $((10#$2 * 320 / 1048576)) MiB，超过内存的十六分之一：连接很多时会挤占内存。"; fi ;;
    conntrack_hours)
      if ((10#$2 < 6)); then echo '和 TCP 保活的 2 小时差不多：长时间不动的连接（例如挂着的 SSH）可能被当成已断开。'; fi ;;
    ssh_keepalive_seconds)
      if ((10#$2 > 300)); then echo '超过 5 分钟：有些路由器会先把空闲连接丢掉，连接还是可能卡死。'; fi ;;
    tools_list)
      if [[ " $2 " != *' tmux '* ]]; then echo '去掉了 tmux：一键开荒防断线要用它，开荒时仍会单独问你装不装。'; fi ;;
    f2b_maxretry)
      if ((10#$2 < 3)); then echo '少于 3 次：自己输错一两次就会被封（白名单里的 IP 不受影响）。'
      elif ((10#$2 > 10)); then echo '超过 10 次：猜密码的程序每轮能多试不少密码。'; fi ;;
    f2b_findtime_min)
      if ((10#$2 < 5)); then echo '不到 5 分钟：放慢速度猜密码的程序很难数满次数，基本不会被封。'; fi ;;
    f2b_bantime_min)
      if ((10#$2 < 10)); then echo '不到 10 分钟：猜密码的程序等一会儿就能接着试。'; fi ;;
    f2b_increment)
      if [[ "$2" == no ]]; then echo '不加倍：反复来的扫描每次只封首次那么久。'; fi ;;
    f2b_maxtime_days)
      if ((10#$2 > 30)); then echo '超过 30 天：这个 IP 以后分给别人，别人也连不上；封禁历史也要保留这么久，数据库会大一些。'; fi ;;
    notify_sudo_args)
      if [[ "$2" == yes ]]; then echo '整条命令会发到 Telegram：命令里带密码或 Token 时（例如 mysql -p密码），它们也会发出去，而且收不回来。'; fi ;;
    docker_log_max_mb)
      if ((10#$2 < 2)); then echo '太小：日志轮换得很快，出了问题往回看不到多少。'; fi ;;
  esac
}

# NAME: the value the user set, when there is a valid one.
param_read() {
  local value
  [[ -f "$PARAMS_FILE" && ! -L "$PARAMS_FILE" ]] || return 1
  value="$(awk -F= -v k="$1" '$1 == k {v = substr($0, length(k) + 2)} END {if (v == "") exit 1; print v}' "$PARAMS_FILE")" || return 1
  param_check "$1" "$value" > /dev/null || return 1
  printf '%s\n' "$value"
}

# NAME: the value in force, the user's or the recommended one.
param_value() {
  param_read "$1" || param_recommended "$1"
}

# NAME: "你调过" or "自动".
param_mode() {
  if param_read "$1" > /dev/null; then echo '你调过'; else echo '自动'; fi
}

# NAME VALUE: keeps VALUE for NAME; an empty VALUE goes back to automatic.
param_store() {
  local name="$1" value="$2" temp
  [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
  state_secure_dir "$STATE_ROOT"
  temp="$(mktemp "$STATE_ROOT/.params.XXXXXX")" || return 1
  if [[ -f "$PARAMS_FILE" && ! -L "$PARAMS_FILE" ]] && ! awk -F= -v k="$name" '$1 != k' "$PARAMS_FILE" > "$temp"; then
    rm -f -- "$temp"; return 1
  fi
  if [[ -n "$value" ]] && ! printf '%s=%s\n' "$name" "$value" >> "$temp"; then rm -f -- "$temp"; return 1; fi
  if ! chmod 600 -- "$temp" || ! mv -fT -- "$temp" "$PARAMS_FILE"; then rm -f -- "$temp"; return 1; fi
}

# KEY: the parameters of one single item.
param_names() {
  local name item _label _unit
  while IFS=$'\t' read -r name item _label _unit; do
    if [[ "$item" == "$1" ]]; then printf '%s\n' "$name"; fi
  done < <(param_list)
}

# NAME: label<TAB>unit.
param_info() {
  local name item label unit
  while IFS=$'\t' read -r name item label unit; do
    if [[ "$name" == "$1" ]]; then printf '%s\t%s\n' "$label" "$unit"; return 0; fi
  done < <(param_list)
  return 1
}

# KEY: true when the single item is on (its last result was applied).
param_item_on() {
  local info
  info="$(module_expect "$1" 2>/dev/null)" || return 1
  [[ "${info%%$'\t'*}" == applied || "${info%%$'\t'*}" == present ]]
}

# KEY: asks for each parameter of a single item. When the item is on it is
# applied again; otherwise the next "开启" uses the new values.
param_adjust() {
  local key="$1" name label unit value answer note changed=0
  local -a names=()
  # Read first: inside the loop, read must get the user's answers.
  mapfile -t names < <(param_names "$key")
  for name in "${names[@]}"; do
    IFS=$'\t' read -r label unit <<< "$(param_info "$name")"
    value="$(param_value "$name")"
    printf '%s：现在 %s%s（%s），本机推荐 %s%s。\n' "$label" "$value" "${unit:+ $unit}" "$(param_mode "$name")" "$(param_recommended "$name")" "${unit:+ $unit}"
    param_reason "$name"
    while :; do
      read -r -p '新的值（直接回车不改，输入 auto 用推荐值）: ' answer || return 0
      answer="$(tr -s ' \t' ' ' <<< "$answer")" answer="${answer# }" answer="${answer% }"
      if [[ -z "$answer" ]]; then break; fi
      if [[ "$answer" == auto ]]; then param_store "$name" '' || die '无法保存参数。'; changed=1; break; fi
      if ! note="$(param_check "$name" "$answer")"; then echo "$note"; continue; fi
      if [[ "$(param_kind "$name")" == int ]]; then answer="$((10#$answer))"; fi
      note="$(param_caution "$name" "$answer")"
      if [[ -n "$note" ]]; then
        warn "$note"
        confirm_yes "仍然用 $answer${unit:+ $unit} 吗？" || continue
      fi
      param_store "$name" "$answer" || die '无法保存参数。'
      changed=1; break
    done
  done
  ((changed)) || { ok '参数没有改动。'; return 0; }
  param_apply "$key"
}

# KEY: the parameters of a single item back to automatic.
param_reset() {
  local key="$1" name
  while IFS= read -r name; do param_store "$name" '' || die '无法保存参数。'; done < <(param_names "$key")
  ok "「$(item_label "$key")」的参数已恢复成本机推荐值。"
  param_apply "$key"
}

# KEY: applies the item again with its current parameters when it is on.
# KEY: an item whose parameters the check reads each time it runs (TG, the
# traffic alert): nothing to apply, and turning it on again would ask its
# questions again.
param_live() {
  [[ "$1" == notify || "$1" == quota ]]
}

param_apply() {
  if param_live "$1"; then
    ok '新的参数下次检查时（几分钟内）就会用上。'
  elif param_item_on "$1"; then
    echo '这一项已经开启：按新的参数重新应用。'
    item_turn_on "$1"
  else
    ok '这一项还没开启：开启时就会用新的参数。'
  fi
}

# Every parameter on one screen: the value in force, the recommendation and why.
params_overview() {
  local name item label unit value recommended note
  say '参数总览'
  while IFS=$'\t' read -r name item label unit; do
    value="$(param_value "$name")" recommended="$(param_recommended "$name")"
    printf ' %s%s%s（单项设置：%s）\n' "${C_BOLD-}" "$label" "${C_RESET-}" "$(item_label "$item")"
    printf '   现在用 %s%s（%s）· 本机推荐 %s%s\n' "$value" "${unit:+ $unit}" "$(param_mode "$name")" "$recommended" "${unit:+ $unit}"
    printf '   %s\n' "$(param_reason "$name")"
    note="$(param_caution "$name" "$value")"
    if [[ -n "$note" ]]; then printf '   %s%s %s%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" "$note" "${C_RESET-}"; fi
  done < <(param_list)
  echo '要改哪一项：单项设置里选那一项，再选「调整参数」或「恢复推荐值」。'
}

# The parameters as lines to paste on another machine (vps params import).
params_export() {
  local name _item _label _unit value
  printf '# VPS 机器管家 %s 的参数，来自 %s，%s\n' "${SCRIPT_VERSION:-}" "$(hostname -s 2>/dev/null || echo 本机)" "$(date +%F)"
  echo '# 在另一台机器上运行 vps params import（或单项设置里选 i），把下面几行粘贴进去。auto 表示用那台机器自己的推荐值。'
  while IFS=$'\t' read -r name _item _label _unit; do
    value="$(param_read "$name" || echo auto)"
    printf '%s=%s\n' "$name" "$value"
  done < <(param_list)
}

# [FILE]: lines from params_export, read from FILE or pasted (up to an empty
# line); checked one by one, shown, then kept on a yes. The items that are on
# are applied again with the new values on request.
params_import() {
  local file="${1:-}" line name value label unit
  local -a names=() values=() items=() lines=()
  if [[ -n "$file" ]]; then
    [[ -f "$file" && -r "$file" ]] || die "读不到文件：$file"
    mapfile -t lines < "$file"
  else
    echo '把另一台机器导出的几行粘贴进来，最后输入一个空行结束：'
    while IFS= read -r line; do
      [[ -n "${line%$'\r'}" ]] || break
      lines+=("$line")
    done
  fi
  for line in "${lines[@]}"; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    [[ "$line" == '#'* ]] && continue
    name="${line%%=*}" value="${line#*=}"
    if [[ "$line" != *=* ]] || ! param_info "$name" > /dev/null; then warn "不认识这一行，跳过：$line"; continue; fi
    if [[ "$value" != auto ]] && ! param_check "$name" "$value" > /dev/null; then warn "值不在允许范围内，跳过：$line"; continue; fi
    names+=("$name") values+=("$value")
  done
  ((${#names[@]})) || { ok '没有可以导入的参数。'; return 0; }
  echo '将改成：'
  for ((line = 0; line < ${#names[@]}; line++)); do
    IFS=$'\t' read -r label unit <<< "$(param_info "${names[line]}")"
    if [[ "${values[line]}" == auto ]]; then printf '  %s：自动（本机推荐 %s%s）\n' "$label" "$(param_recommended "${names[line]}")" "${unit:+ $unit}"
    else printf '  %s：%s%s\n' "$label" "${values[line]}" "${unit:+ $unit}"; fi
  done
  confirm_yes '确认导入吗？' || { ok '已取消。'; return 0; }
  for ((line = 0; line < ${#names[@]}; line++)); do
    value="${values[line]}"
    if [[ "$value" == auto ]]; then value=''
    elif [[ "$(param_kind "${names[line]}")" == int ]]; then value="$((10#$value))"; fi
    # Only an item whose values change is offered to be applied again.
    [[ "$value" != "$(param_read "${names[line]}" 2>/dev/null || true)" ]] || continue
    param_store "${names[line]}" "$value" || die '无法保存参数。'
    while IFS=$'\t' read -r name label _ _; do
      if [[ "$name" == "${names[line]}" && " ${items[*]} " != *" $label "* ]]; then items+=("$label"); fi
    done < <(param_list)
  done
  ok '参数已导入。'
  for line in "${items[@]}"; do
    if param_live "$line"; then
      if param_item_on "$line"; then ok "「$(item_label "$line")」下次检查时就会用新的参数。"; fi
      continue
    fi
    if param_item_on "$line" && confirm_default_yes "「$(item_label "$line")」已经开启，现在就按新的参数重新应用吗？"; then item_turn_on "$line"; fi
  done
}

# vps params [show|export|import [FILE]]
params_main() {
  [[ $EUID -eq 0 ]] || die '参数保存在 root 的目录里：请用 sudo vps params。'
  case "${MODE_ARGS[0]:-show}" in
    show) params_overview ;;
    export) params_export ;;
    import)
      validate_vm
      start_logging
      prepare_run_state
      stage_run backup backup_configs
      restore_prepare
      params_import "${MODE_ARGS[1]:-}"
      finish_run_state ;;
    *) die '用法：vps params [show|export|import [文件]]' ;;
  esac
}

# Only the maxima grow, never shrink: buffers are still allocated on demand and
# the kernel's total TCP memory limit (tcp_mem) is left alone, so idle
# connections cost nothing more. A key set in any other file keeps its value.
# MODULE ID FILE RUNTIME [KEY=VALUE...]: this tool's sysctl FILE with these
# values. A key set in another file stays; the running value before the first
# write is recorded in RUNTIME for the rollback. This tool's own file is
# written again when the values change, and what it no longer sets goes back
# to its value from before (all of it when nothing is left). Fails, with the
# result recorded, when FILE is not this tool's or cannot be applied.
sysctl_owned_apply() {
  local module="$1" id="$2" file="$3" runtime="$4" pair key value current text='' old='' ours=0 content
  local -a originals=() kept=()
  shift 4
  if [[ -e "$file" || -L "$file" ]]; then
    if ! restore_file_ours "$id"; then
      warn "$file 已经存在，不是本工具上次写入的内容，保持不变。"; module_result "$module" preserved 'file differs'; return 1
    fi
    ours=1 old="$(cat -- "$file")"
  fi
  for pair in "$@"; do
    key="${pair%%=*}" value="${pair#*=}"
    if ((ours == 0)) || ! current="$(restore_sysctl_original "$key" "$runtime")"; then
      current="$(sysctl -n "$key" 2>/dev/null || true)"
    fi
    [[ "$current" =~ ^-?[0-9]+$ ]] || continue
    if sysctl_key_configured "$key" "$file"; then kept+=("$key"); continue; fi
    text+="$key = $value"$'\n'
    originals+=("$key=$current")
  done
  if ((${#kept[@]})); then ok "已有其他配置的参数保持不变：${kept[*]}"; fi
  content="# VPS Stable Optimizer v2.8: $module"$'\n'"${text%$'\n'}"
  if ((ours)) && [[ "$old" == "$content" ]]; then
    sysctl -e -p "$file" >/dev/null && return 0
    warn '参数没有生效，请查看日志。'; module_result "$module" failed 'sysctl -p failed'; return 1
  fi
  if ((ours)); then
    rm -f -- "$file"
    while IFS= read -r key; do
      [[ -n "$key" && "$text" != *"$key = "* ]] || continue
      if current="$(restore_sysctl_original "$key" "$runtime")"; then
        sysctl -w "$key=$current" >/dev/null 2>&1 || warn "无法把 $key 恢复成原来的 $current；重启后会恢复。"
      fi
    done < <(awk '/ = / {print $1}' <<< "$old")
  fi
  [[ -n "$text" ]] || return 0
  if ! put_file "$file" "$content"; then module_result "$module" preserved 'sysctl file conflict'; return 1; fi
  for pair in "${originals[@]}"; do
    restore_record_sysctl "${pair%%=*}" "${pair#*=}" "$runtime" || warn "无法记录 ${pair%%=*} 的原值；回退后要重启才会恢复默认。"
  done
  if ! sysctl -e -p "$file" >/dev/null; then warn '参数没有生效，请查看日志。'; module_result "$module" failed 'sysctl -p failed'; return 1; fi
}

# SSH keepalive: the server checks an idle session every N seconds and drops
# it after 3 answers missing. Only this tool's file; sshd checks it first.
keepalive_stage() {
  step 12 'SSH 保活'
  local seconds content current
  if [[ "${KEEPALIVE_CHOICE:-}" != 1 ]]; then ok '按你的选择不修改 SSH 保活。'; module_result keepalive declined 'not requested'; return 0; fi
  seconds="$(param_value ssh_keepalive_seconds)"
  content="# VPS Stable Optimizer v2.8: SSH keepalive"$'\n'"ClientAliveInterval $seconds"$'\n'"ClientAliveCountMax 3"
  if [[ -e "$KEEPALIVE_FILE" || -L "$KEEPALIVE_FILE" ]]; then
    if [[ "$(cat -- "$KEEPALIVE_FILE" 2>/dev/null || true)" != "$content" ]]; then
      restore_file_ours keepalive_file || { warn "$KEEPALIVE_FILE 不是本工具写的，保持不变。"; module_result keepalive preserved 'file differs'; return 0; }
      rm -f -- "$KEEPALIVE_FILE"
    fi
  fi
  sshd_runtime_dir
  current="$(sshd -T 2>/dev/null | awk '$1 == "clientaliveinterval" {print $2}')"
  # Set elsewhere: not by this tool's own SSH hardening of earlier versions.
  if [[ ! -e "$KEEPALIVE_FILE" && -n "$current" && "$current" != 0 ]] &&
     grep -REiq --exclude="${SSH_DROPIN##*/}" '^[[:space:]]*ClientAliveInterval' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
    ok "SSH 已经有保活设置（每 $current 秒），保持不变。"; module_result keepalive preserved "ClientAliveInterval $current"; return 0
  fi
  put_file "$KEEPALIVE_FILE" "$content" || { module_result keepalive preserved 'drop-in path conflict'; return 0; }
  # Never a configuration sshd refuses: tested first, taken back if it fails.
  if ! sshd -t; then
    rm -f -- "$KEEPALIVE_FILE"; warn 'SSH 配置检查没通过，保活设置已撤回，SSH 保持原样。'; module_result keepalive failed 'sshd -t failed'; return 0
  fi
  ssh_reload || warn 'SSH 服务没能重新加载：新连接要等 SSH 重启后才有保活。'
  current="$(sshd -T 2>/dev/null | awk '$1 == "clientaliveinterval" {print $2}')"
  if [[ "$current" == "$seconds" ]]; then ok "SSH 保活：每 $seconds 秒检测一次空闲连接（新连接生效）。"; module_result keepalive applied "$seconds s"
  else warn "SSH 实际生效的保活间隔是 ${current:-0} 秒（别的配置先设置了它）。"; module_result keepalive preserved "ClientAliveInterval ${current:-0}"; fi
}

# A host that has public IPv6 but cannot reach the distribution's mirror over
# it, while IPv4 works: programs that try IPv6 first then hang for a while.
ipv6_broken() {
  local host addr6 addr4
  host_has_global_ipv6 || return 1
  if [[ "$OS" == ubuntu ]]; then host=archive.ubuntu.com; else host=deb.debian.org; fi
  addr6="$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')"
  addr4="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ -n "$addr6" && -n "$addr4" ]] || return 1
  if timeout 5 bash -c "exec 3<>/dev/tcp/$addr6/80" 2>/dev/null; then return 1; fi
  timeout 5 bash -c "exec 3<>/dev/tcp/$addr4/80" 2>/dev/null
}

# Prefers IPv4 in getaddrinfo (/etc/gai.conf; glibc programs only, IPv6 stays
# on). A precedence policy set by someone else is kept.
ipv4_stage() {
  step 12 '优先使用 IPv4'
  local line='precedence ::ffff:0:0/96  100'
  if [[ "${IPV4_CHOICE:-}" != 1 ]]; then ok '按你的选择不修改地址优先顺序。'; module_result ipv4 declined 'not requested'; return 0; fi
  if [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]' "$GAI_FILE"; then
    if grep -Fxq "$line" "$GAI_FILE"; then ok '已经优先使用 IPv4。'; module_result ipv4 present 'precedence set'
    else ok "$GAI_FILE 里已有别的地址优先设置，保持不变。"; module_result ipv4 preserved 'own precedence policy'; fi
    return 0
  fi
  if [[ -L "$GAI_FILE" ]]; then warn "$GAI_FILE 是链接，保持不变。"; module_result ipv4 preserved 'gai.conf is a link'; return 0; fi
  backup_config_path "$GAI_FILE" || die "无法备份 $GAI_FILE"
  if [[ ! -e "$GAI_FILE" ]]; then
    put_file "$GAI_FILE" "# VPS Stable Optimizer v2.8: prefer IPv4 (IPv6 stays on)"$'\n'"$line" || { module_result ipv4 preserved 'gai.conf conflict'; return 0; }
  elif ! append_line_safely "$GAI_FILE" '# VPS Stable Optimizer v2.8: prefer IPv4 (IPv6 stays on)' || ! append_line_safely "$GAI_FILE" "$line"; then
    warn "没能写入 $GAI_FILE。"; module_result ipv4 failed 'gai.conf not written'; return 0
  fi
  record_config_change "$GAI_FILE" line-appended || die '无法记录这次配置变更。'
  ok '已改成优先使用 IPv4（IPv6 照常可用）。xray、sing-box 这类用 Go 写的程序不读这个设置，要在它们自己的配置里指定。'
  module_result ipv4 applied 'precedence set'
}

# Login record and note. PAM runs the hook as root when a session opens, through
# a profile of pam-auth-update (Debian's own way to add a line to
# common-session, so no file of a package is edited). The line is "optional":
# a missing or failing hook never stops a login, and timeout ends it after 3 s.
# sshd shows nothing a session module prints: the note goes into a file of the
# account, and its shell shows it (LOGIN_PROFILE_FILE).
login_pam_text() {
  printf '%s\n' 'Name: VPS Stable Optimizer: login record and note' 'Default: yes' 'Priority: 0' \
    'Session-Interactive-Only: yes' 'Session-Type: Additional' 'Session:' \
    "	optional	pam_exec.so quiet /usr/bin/timeout 3 /bin/bash $STATE_ROOT/login-hook"
}

# Run by every login shell: the note once, then emptied.
login_profile_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.8: the login note left by the login record.' \
    "if [ -t 1 ] && [ -s \"$LOGIN_NOTE_DIR/\$(id -un)\" ] && [ -O \"$LOGIN_NOTE_DIR/\$(id -un)\" ]; then" \
    "  cat \"$LOGIN_NOTE_DIR/\$(id -un)\"; : > \"$LOGIN_NOTE_DIR/\$(id -un)\"" \
    'fi'
}

# The hook: one line per login in logins (time, account, address or console
# line, method, ssh or console, 1 for an address never seen before), a year
# and at most 20000 lines. sshd's own lines of the last 10 minutes are read
# too, so a login that opened no PAM session is not missed. The note for the
# account (the previous login, the others of the last 10 minutes and, in red,
# an address that logs in for the first time) is left in NOTE_DIR/ACCOUNT,
# owned by the account, for its shell to show.
login_hook_text() {
  sed -e "s#@STATE@#$STATE_ROOT#g" -e "s#@NOTES@#$LOGIN_NOTE_DIR#g" <<'HOOK'
#!/bin/bash
# VPS Stable Optimizer v2.8: login record and note (run by PAM as root).
[ "${PAM_TYPE:-}" = open_session ] || exit 0
case "${PAM_SERVICE:-}" in sshd) kind=ssh ;; login) kind=console ;; *) exit 0 ;; esac
state='@STATE@'
[ -d "$state" ] && [ ! -L "$state" ] || exit 0
umask 077
export LC_ALL=C.UTF-8
record="$state/logins" known="$state/known"
exec 7>> "$state/logins.lock" && flock -w 1 7 || exit 0
now="$(date +%s)"
user="$(printf '%s' "${PAM_USER:-}" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)"
if [ "$kind" = ssh ]; then from="$(printf '%s' "${PAM_RHOST:-}" | tr -cd 'A-Za-z0-9.:-' | cut -c1-64)"
else from="console:$(printf '%s' "${PAM_TTY:-}" | tr -cd 'A-Za-z0-9/_-' | cut -c1-20)"; fi
[ -n "$user" ] && [ -n "$from" ] || exit 0
# sshd's successful logins of the last 10 minutes: time, method, account, address.
recent="$(journalctl -q --since=-600s _UID=0 -t sshd -t sshd-session -o short-unix --no-pager 2>/dev/null |
  awk '$4 == "Accepted" && $6 == "for" && $8 == "from" {sub(/\..*/, "", $1); print $1, $5, $7, $9}' | tail -n 50)"
method=console
if [ "$kind" = ssh ]; then
  method="$(printf '%s\n' "$recent" | awk -v u="$user" -v ip="$from" '$3 == u && $4 == ip {m = $2} END {print m}' | tr -cd 'a-z-')"
  [ -n "$method" ] || method=unknown
fi
is_new() {
  [ "${1#console:}" = "$1" ] || return 1
  if [ -f "$record" ] && awk -F'\t' -v ip="$1" '$3 == ip {f = 1} END {exit !f}' "$record"; then return 1; fi
  if [ -f "$known" ] && grep -Fxq "ip $1" "$known"; then return 1; fi
  return 0; }
previous="$(tail -n 1 "$record" 2>/dev/null)"
# Logins sshd wrote that are not in the record (and are not this one).
missed="$( { tail -n 300 "$record" 2>/dev/null; printf '%s\n' "--"; printf '%s\n' "$recent"; } | awk -F'\t' -v u="$user" -v ip="$from" -v now="$now" '
  $0 == "--" {r = 1; next}
  !r {t[NR] = $1; who[NR] = $2 " " $3; next}
  {split($0, f, " "); if (f[3] == u && f[4] == ip && now - f[1] <= 120) next
   for (i in t) if (who[i] == f[3] " " f[4] && (t[i] - f[1] <= 5 && f[1] - t[i] <= 5)) next
   print f[1] "\t" f[3] "\t" f[4] "\t" f[2]}')"
while IFS="$(printf '\t')" read -r t u ip m; do
  [ -n "$t" ] || continue
  u="$(printf '%s' "$u" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)" ip="$(printf '%s' "$ip" | tr -cd 'A-Za-z0-9.:-' | cut -c1-64)"
  m="$(printf '%s' "$m" | tr -cd 'a-z-')"
  n=0; if is_new "$ip"; then n=1; fi
  printf '%s\t%s\t%s\t%s\tssh\t%s\n' "$t" "$u" "$ip" "${m:-unknown}" "$n" >> "$record"
done <<EOF
$missed
EOF
new=0; if is_new "$from"; then new=1; fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$user" "$from" "$method" "$kind" "$new" >> "$record"
# A year, at most 20000 lines.
first="$(head -n 1 "$record" | cut -f1)"
if [ "$(wc -l < "$record")" -gt 20000 ] || [ "${first:-$now}" -lt $((now - 31622400)) ] 2>/dev/null; then
  awk -F'\t' -v cut=$((now - 31622400)) '$1 >= cut' "$record" | tail -n 20000 > "$record.new" && mv -f "$record.new" "$record"
fi
# The note, for the account's shell to show.
notes='@NOTES@'
# Every account must reach its own file (umask 077 above would shut them out).
[ ! -L "$notes" ] || exit 0
mkdir -p "$notes" 2>/dev/null; chmod 755 "$notes" 2>/dev/null
[ -d "$notes" ] || exit 0
note="$notes/$user"
[ ! -L "$note" ] || rm -f "$note"
say_method() { case "$1" in publickey) echo 密钥 ;; password) echo 密码 ;; keyboard-interactive) echo 密码 ;; console) echo 控制台 ;; *) echo 其他方式 ;; esac; }
show() {
  when="$(date -d "@$1" '+%m-%d %H:%M' 2>/dev/null)"
  case "$3" in console:*) where="服务商控制台（${3#console:}）" ;; *) where="来自 $3" ;; esac
  if [ "$6" = 1 ]; then printf '\033[31m%s  %s %s（%s）  ← 第一次从这个 IP 登录\033[0m\n' "$when" "$2" "$where" "$(say_method "$4")"
  else printf '%s  %s %s（%s）\n' "$when" "$2" "$where" "$(say_method "$4")"; fi; }
{
echo '—— VPS 机器管家：登录记录 ——'
if [ -n "$previous" ]; then
  IFS="$(printf '\t')" read -r t u ip m k n <<EOF
$previous
EOF
  printf '上次登录：'; show "$t" "$u" "$ip" "$m" "$k" 0
else echo '这是本工具记下的第一次登录。'; fi
# The others of the last 10 minutes (not this one, not the previous one shown
# above); red for a first-time address other than this login's own.
others="$(awk -F'\t' -v cut=$((now - 600)) '$1 >= cut' "$record" | head -n -1 | grep -vFx -- "$previous")"
if [ -n "$others" ]; then
  echo '最近 10 分钟还有：'
  printf '%s\n' "$others" | while IFS="$(printf '\t')" read -r t u ip m k n; do
    [ "$ip" != "$from" ] || n=0
    printf '  '; show "$t" "$u" "$ip" "$m" "$k" "$n"
  done
fi
if [ "$new" = 1 ]; then
  printf '\033[31m这是第一次从 %s 登录。不是你自己的话：马上改密码、删掉不认识的公钥，再用 vps 选 7 安全排查。是你自己就不用管，下次不再标红。\033[0m\n' "$from"
fi
} > "$note"
chown -- "$user" "$note" 2>/dev/null || rm -f "$note"
exit 0
HOOK
}

# Enabled: common-session has this tool's line.
login_pam_enabled() {
  grep -Fq "$STATE_ROOT/login-hook" "$PAM_COMMON_SESSION" 2>/dev/null
}

login_stage() {
  step 12 '登录记录和提醒'
  local hook pam profile
  if [[ "${LOGIN_CHOICE:-}" != 1 ]]; then ok '按你的选择不开启登录记录。'; module_result login declined 'not requested'; return 0; fi
  if ! command -v pam-auth-update >/dev/null; then warn '找不到 pam-auth-update，不能开启登录记录。'; module_result login unsupported 'no pam-auth-update'; return 0; fi
  hook="$(login_hook_text)" pam="$(login_pam_text)" profile="$(login_profile_text)"
  # Written again when this tool has a newer text.
  if [[ -f "$STATE_ROOT/login-hook" && "$(cat -- "$STATE_ROOT/login-hook" 2>/dev/null || true)" != "$hook" ]] && restore_file_ours login_hook_file; then
    rm -f -- "$STATE_ROOT/login-hook"
  fi
  if [[ -f "$LOGIN_PAM_FILE" && "$(cat -- "$LOGIN_PAM_FILE" 2>/dev/null || true)" != "$pam" ]] && restore_file_ours login_pam_file; then
    rm -f -- "$LOGIN_PAM_FILE"
  fi
  put_file "$STATE_ROOT/login-hook" "$hook" || { module_result login preserved 'hook path conflict'; return 0; }
  chmod 600 -- "$STATE_ROOT/login-hook" || true
  if [[ -f "$LOGIN_PROFILE_FILE" && "$(cat -- "$LOGIN_PROFILE_FILE" 2>/dev/null || true)" != "$profile" ]] && restore_file_ours login_profile_file; then
    rm -f -- "$LOGIN_PROFILE_FILE"
  fi
  put_file "$LOGIN_PROFILE_FILE" "$profile" || { module_result login preserved 'profile script conflict'; return 0; }
  put_file "$LOGIN_PAM_FILE" "$pam" || { module_result login preserved 'PAM profile conflict'; return 0; }
  if ! login_pam_enabled; then
    # A common-session edited by hand is not touched (pam-auth-update refuses).
    pam-auth-update --package --enable vps-stable-login || true
  fi
  if login_pam_enabled; then
    ok '登录记录和提醒已开启：下次登录起每次记一行（vps 选 7 安全排查里能看到），登录时显示上次登录。'
    module_result login applied 'pam_exec in common-session'
  else
    warn "$PAM_COMMON_SESSION 被手动改过，pam-auth-update 不会再修改它：登录记录没有开启。"
    module_result login failed 'common-session not updated'
  fi
}

# NUMBER of the last logins in the record, newest last, as "time account
# address method kind new" (tab-separated); nothing when there is no record.
login_recent() {
  [[ -f "$STATE_ROOT/logins" && ! -L "$STATE_ROOT/logins" ]] || return 0
  tail -n "${1:-20}" -- "$STATE_ROOT/logins" | awk -F'\t' 'NF == 6 && $1 ~ /^[0-9]+$/'
}

# The menu's red line: first-time addresses of the last 3 days that were not
# marked as normal since.
menu_login_alert() {
  local now when user ip
  now="$(date +%s)"
  while IFS=$'\t' read -r when user ip; do
    [[ -n "$ip" ]] || continue
    if [[ -f "$STATE_ROOT/known" ]] && grep -Fxq "ip $ip" "$STATE_ROOT/known"; then continue; fi
    printf '%s%s 陌生 IP 登录过：%s（%s，%s）。不是你的话马上处理；是你自己就在 7 安全排查里标记为正常。%s\n' \
      "${C_FAIL-}" "${SYM_WARN-⚠}" "$ip" "$user" "$(date -d "@$when" '+%m-%d %H:%M' 2>/dev/null || echo '?')" "${C_RESET-}"
  done < <(login_recent 2000 | awk -F'\t' -v cut=$((now - 259200)) '$1 >= cut && $6 == 1 {print $1 "\t" $2 "\t" $3}' | tail -n 3)
}

# The daily security upgrade at the time asked for (a timer drop-in), or the
# distribution's own time (no drop-in).
apt_time_apply() {
  local time content
  time="$(param_value apt_upgrade_time)"
  content="# VPS Stable Optimizer v2.8: time of the daily security upgrade"$'\n'"[Timer]"$'\n'"OnCalendar="$'\n'"OnCalendar=*-*-* $time:00"$'\n'"RandomizedDelaySec=15m"
  if [[ -e "$APT_TIME_FILE" && "$(cat -- "$APT_TIME_FILE" 2>/dev/null || true)" != "$content" ]]; then
    restore_file_ours apt_time_file || { warn "$APT_TIME_FILE 不是本工具写的，更新时间保持不变。"; return 0; }
    rm -f -- "$APT_TIME_FILE"
  fi
  if [[ "$time" == "$(param_recommended apt_upgrade_time)" ]] && ! param_read apt_upgrade_time > /dev/null; then
    ok '每天自动安全更新的时间：系统默认（06:00 左右）。'
  elif put_file "$APT_TIME_FILE" "$content"; then
    ok "每天自动安全更新改在 $time 左右（随机推迟最多 15 分钟）。"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if active apt-daily-upgrade.timer; then systemctl restart apt-daily-upgrade.timer >/dev/null 2>&1 || true; fi
}

# Connection tracking: every connection through the firewall has an entry; a
# full table drops new connections. The limit is only ever raised (from the
# value before this tool), the established timeout set when it differs, and
# the table itself is never flushed.
conntrack_stage() {
  say '连接跟踪容量'
  local max hours original
  local -a pairs=()
  if ! sysctl -n net.netfilter.nf_conntrack_max >/dev/null 2>&1; then
    ok '现在没有用到连接跟踪（通常防火墙开着才会用到），不需要调整。'; module_result conntrack skipped 'nf_conntrack not loaded'; return 0
  fi
  max="$(param_value conntrack_max)" hours="$(param_value conntrack_hours)"
  original="$(restore_sysctl_original net.netfilter.nf_conntrack_max conntrack_sysctl_runtime || sysctl -n net.netfilter.nf_conntrack_max)"
  if ((max > original)); then pairs+=("net.netfilter.nf_conntrack_max=$max"); fi
  original="$(restore_sysctl_original net.netfilter.nf_conntrack_tcp_timeout_established conntrack_sysctl_runtime ||
    sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established)"
  if ((hours * 3600 != original)); then pairs+=("net.netfilter.nf_conntrack_tcp_timeout_established=$((hours * 3600))"); fi
  sysctl_owned_apply conntrack conntrack_file "$CONNTRACK_FILE" conntrack_sysctl_runtime "${pairs[@]}" || return 0
  if [[ ! -f "$CONNTRACK_FILE" ]]; then
    if [[ -f "$CONNTRACK_MODULE_FILE" ]] && restore_file_ours conntrack_module; then rm -f -- "$CONNTRACK_MODULE_FILE"; fi
    ok "上限 $max 条、保留 $hours 小时，都不比系统原来的大：不需要本工具的设置。"; module_result conntrack preserved 'system values already enough'; return 0
  fi
  # Loaded before systemd-sysctl at boot, or the values would never apply.
  put_file "$CONNTRACK_MODULE_FILE" nf_conntrack || warn "没能写入 $CONNTRACK_MODULE_FILE：重启后这些值可能不生效。"
  ok "连接跟踪：上限 $(sysctl -n net.netfilter.nf_conntrack_max) 条、已建立连接保留 $(($(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established) / 3600)) 小时。"
  module_result conntrack applied "max $max, $hours h"
}

# Not answering ping, IPv4 and (where the kernel has it) IPv6.
ping_stage() {
  say '禁止 ping'
  local -a pairs=(net.ipv4.icmp_echo_ignore_all=1)
  if sysctl -n net.ipv6.icmp.echo_ignore_all >/dev/null 2>&1; then pairs+=(net.ipv6.icmp.echo_ignore_all=1); fi
  sysctl_owned_apply ping ping_file "$PING_FILE" ping_sysctl_runtime "${pairs[@]}" || return 0
  if [[ -f "$PING_FILE" ]]; then ok '已经不回应 ping 了。'; module_result ping applied 'echo ignored'
  else ok '本来就不回应 ping，保持不变。'; module_result ping present 'echo ignored already'; fi
}

# The value KEY had before this tool first changed it, as recorded in FILE.
restore_sysctl_original() {
  local file="$RESTORE_ROOT/${2:-sysctl_runtime}"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2); found = 1; exit} END {exit !found}' "$file"
}

tcp_buffer_stage() {
  step 7 'TCP 缓冲区上限和调优（可选）'
  local mib max key current text='' min def top content old='' ours=0 pair value
  local -a kept=() originals=()
  if [[ "${TCP_BUFFER_CHOICE:-}" != 1 ]]; then ok '按你的选择不修改 TCP 缓冲区。'; module_result tcp declined 'not requested'; return 0; fi
  mib="$(param_value tcp_buffer_mib)"
  max=$((mib * 1048576))
  if [[ -e "$TCP_BUFFER_FILE" || -L "$TCP_BUFFER_FILE" ]]; then
    if ! restore_file_ours tcp_file; then
      warn "$TCP_BUFFER_FILE 已经存在，不是本工具上次写入的内容，保持不变。"; module_result tcp preserved 'file differs'; return 0
    fi
    ours=1 old="$(cat -- "$TCP_BUFFER_FILE")"
  fi
  for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    # While this tool's file is in force the running values are its own: the
    # new cap is compared with the values from before the tool instead.
    if ((ours == 0)) || ! current="$(restore_sysctl_original "$key" tcp_sysctl_runtime)"; then
      current="$(sysctl -n "$key" 2>/dev/null || true)"
    fi
    read -r min def top <<< "$current"
    if sysctl_key_configured "$key" "$TCP_BUFFER_FILE"; then kept+=("$key"); continue; fi
    if [[ "$key" == net.core.* ]]; then
      [[ "$min" =~ ^[0-9]+$ && -z "$def" ]] || continue
      ((min < max)) || continue
      text+="$key = $max"$'\n'; current="$min"
    else
      [[ "$min" =~ ^[0-9]+$ && "$def" =~ ^[0-9]+$ && "$top" =~ ^[0-9]+$ ]] || continue
      ((top < max)) || continue
      text+="$key = $min $def $max"$'\n'; current="$min $def $top"
    fi
    originals+=("$key=$current")
  done
  # A connection idle for a while keeps its speed (no slow start again), and
  # MTU probing starts when large packets are lost without any ICMP reply.
  # Both only ever go one way: an administrator's stricter value stays.
  for pair in net.ipv4.tcp_slow_start_after_idle=0 net.ipv4.tcp_mtu_probing=1; do
    key="${pair%%=*}" value="${pair#*=}"
    if ((ours == 0)) || ! current="$(restore_sysctl_original "$key" tcp_sysctl_runtime)"; then
      current="$(sysctl -n "$key" 2>/dev/null || true)"
    fi
    [[ "$current" =~ ^[0-9]+$ ]] || continue
    if sysctl_key_configured "$key" "$TCP_BUFFER_FILE"; then kept+=("$key"); continue; fi
    case "$key" in
      *slow_start_after_idle) ((current != 0)) || continue ;;
      *mtu_probing) ((current < 1)) || continue ;;
    esac
    text+="$key = $value"$'\n'
    originals+=("$key=$current")
  done
  if ((${#kept[@]})); then ok "已有其他配置的参数保持不变：${kept[*]}"; fi
  content="# VPS Stable Optimizer v2.7: larger socket buffer ceilings"$'\n'"${text%$'\n'}"
  if ((ours)) && [[ "$old" == "$content" ]]; then
    if sysctl -e -p "$TCP_BUFFER_FILE" >/dev/null; then
      ok "TCP 缓冲区上限已经是 $mib MiB（$(param_mode tcp_buffer_mib)），已重新加载。"; module_result tcp applied "$mib MiB"
    else warn 'TCP 缓冲区参数没有生效，请查看日志。'; module_result tcp failed 'sysctl -p failed'; fi
    return 0
  fi
  # The new cap changes this tool's own file: it is written again, and what
  # the new one no longer raises goes back to its value from before the tool.
  if ((ours)); then
    rm -f -- "$TCP_BUFFER_FILE"
    while IFS= read -r key; do
      [[ -n "$key" && "$text" != *"$key = "* ]] || continue
      if current="$(restore_sysctl_original "$key" tcp_sysctl_runtime)"; then
        sysctl -w "$key=$current" >/dev/null 2>&1 || warn "无法把 $key 恢复成原来的 $current；重启后会恢复。"
      fi
    done < <(awk '/ = / {print $1}' <<< "$old")
  fi
  if [[ -z "$text" ]]; then
    if ((ours)); then
      ok "上限 $mib MiB 不比系统原来的值大：本工具的设置不再需要，已恢复成系统原来的值。"
      module_result tcp preserved 'system values already large enough'
    else
      if ((${#kept[@]} == 0)); then ok "TCP 缓冲区上限已经不小于 $mib MiB，不用修改。"; fi
      module_result tcp preserved 'already large enough or set elsewhere'
    fi
    return 0
  fi
  if ! put_file "$TCP_BUFFER_FILE" "$content"; then
    module_result tcp preserved 'sysctl file conflict'; return 0
  fi
  # Only a key seen for the first time is recorded (the first value is kept).
  for key in "${originals[@]}"; do
    restore_record_sysctl "${key%%=*}" "${key#*=}" tcp_sysctl_runtime || warn "无法记录 ${key%%=*} 的原值；回退后要重启才会恢复默认。"
  done
  if sysctl -e -p "$TCP_BUFFER_FILE" >/dev/null; then
    ok "TCP 调优已生效：缓冲区上限 $mib MiB（$(param_mode tcp_buffer_mib)，内存 ${MEM_MIB} MiB）$(if [[ "$text" == *slow_start_after_idle* ]]; then echo '，空闲后不重新慢启动'; fi)$(if [[ "$text" == *mtu_probing* ]]; then echo '，自动探测被丢的大包'; fi)。"; module_result tcp applied "$mib MiB"
  else warn 'TCP 缓冲区参数没有生效，请查看日志。'; module_result tcp failed 'sysctl -p failed'; fi
}

# Appends LINE to FILE; an unterminated last line is ended first, so the two
# never merge into one.
append_line_safely() {
  local file="$1" line="$2"
  if [[ -s "$file" && "$(tail -c 1 -- "$file" | wc -l)" -eq 0 ]]; then printf '\n' >> "$file" || return 1; fi
  printf '%s\n' "$line" >> "$file"
}

# Adds "127.0.1.1 <hostname>" (the Debian convention) when the name does not resolve.
hosts_stage() {
  step 12 '主机名解析'
  local name
  name="$(hostname 2>/dev/null || true)"
  if hostname_resolves; then ok "主机名 $name 可以正常解析。"; module_result hosts present "$name"; return 0; fi
  if [[ "${HOSTS_CHOICE:-}" != 1 ]]; then ok '按你的选择不修改 /etc/hosts。'; module_result hosts declined 'not requested'; return 0; fi
  if [[ ! "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$ ]]; then warn "主机名格式异常：$name，不修改 /etc/hosts。"; module_result hosts skipped 'unusual hostname'; return 0; fi
  if [[ ! -f /etc/hosts || -L /etc/hosts ]]; then warn '/etc/hosts 不是普通文件，不修改。'; module_result hosts skipped 'hosts not a regular file'; return 0; fi
  backup_config_path /etc/hosts || die '无法备份 /etc/hosts'
  if append_line_safely /etc/hosts "127.0.1.1"$'\t'"$name" && hostname_resolves; then
    record_config_change /etc/hosts line-appended || die '无法记录 /etc/hosts 变更。'
    restore_record_hosts_line "127.0.1.1"$'\t'"$name" || warn '无法记录添加的主机名行；撤销时会把整个 /etc/hosts 恢复成原来的样子。'
    ok "已在 /etc/hosts 加入：127.0.1.1 $name"; module_result hosts applied "$name"
  else
    warn '修改 /etc/hosts 后主机名仍无法解析，请人工检查。'; module_result hosts failed 'still unresolved'
  fi
}

# Preserve administrator jail files; manage only the exact v2.6 installation guard.
F2B_DIR=/etc/fail2ban

# Only untouched conffiles recorded by the installed/config-files package are
# distribution defaults. Unknown files, obsolete records and links are custom.
f2b_distribution_config() {
  local file="$1" digest actual
  [[ -f "$file" && ! -L "$file" ]] || return 1
  digest="$(dpkg-query -W -f='${Conffiles}\n' fail2ban 2>/dev/null |
    awk -v path="$file" '$1 == path && NF == 2 {print $2}')" || return 1
  [[ "$digest" =~ ^[0-9a-f]{32}$ ]] || return 1
  actual="$(md5sum -- "$file")" || return 1
  [[ "${actual%% *}" == "$digest" ]]
}

foreign_f2b_config() {
  local f
  [[ -L "$F2B_DIR" || -L "$F2B_DIR/jail.d" || -L "$F2B_DIR/action.d" ]] && return 0
  [[ -e "$F2B_DIR/jail.local" || -L "$F2B_DIR/jail.local" ]] && return 0
  [[ -e "${F2B_ACTION_FILE%.conf}.local" || -L "${F2B_ACTION_FILE%.conf}.local" ]] && return 0
  for f in "$F2B_DIR"/jail.d/*.local; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "$f" == "$F2B_FILE" ]] || return 0
  done
  for f in "$F2B_DIR/jail.conf" "$F2B_DIR"/jail.d/*.conf; do
    [[ -e "$f" || -L "$f" ]] || continue
    f2b_distribution_config "$f" || return 0
  done
  return 1
}

f2b_bootstrap_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.6 installation guard' \
    '# Keep sshd disabled until the managed configuration passes its test.' \
    '[sshd]' 'enabled = false'
}

# PORTS [IGNORE]: the jail from the parameters. Bans start at the first ban
# time (an hour) and, with the doubling on, double for an address banned again
# (Fail2ban 0.11+ looks up earlier bans in its database), up to the longest
# (a week). A mistyped password costs the administrator an hour; persistent
# scanners stay out.
f2b_jail_text() {
  local ban max increment=false
  ban=$(($(param_value f2b_bantime_min) * 60)) max=$(($(param_value f2b_maxtime_days) * 86400))
  ((max >= ban)) || max="$ban"
  if [[ "$(param_value f2b_increment)" == yes ]]; then increment=true; fi
  f2b_jail_values_text "$1" "$(param_value f2b_maxretry)" $(($(param_value f2b_findtime_min) * 60)) "$ban" "$increment" "$max" "${2:-}"
}

# PORTS MAXRETRY FINDTIME BANTIME INCREMENT MAXTIME [IGNORE]: times in seconds,
# INCREMENT true or false.
f2b_jail_values_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.6 managed SSH jail' \
    '[sshd]' 'enabled = true' "port = $1" 'backend = systemd' \
    'action = vps-stable-ufw-sshd[port="%(port)s"]' \
    "maxretry = $2" "findtime = $3" "bantime = $4" \
    "bantime.increment = $5" "bantime.maxtime = $6"
  if [[ -n "${7:-}" ]]; then printf 'ignoreip = 127.0.0.1/8 ::1 %s\n' "$7"; fi
}

# What the parameters say, in words: "输错 5 次（10 分钟内）封 1 小时，再犯加倍，最长 7 天".
f2b_policy_text() {
  local ban
  ban="$(param_value f2b_bantime_min)"
  if ((ban % 60 == 0)); then ban="$((ban / 60)) 小时"; else ban="$ban 分钟"; fi
  printf '输错 %s 次（%s 分钟内）封 %s' "$(param_value f2b_maxretry)" "$(param_value f2b_findtime_min)" "$ban"
  if [[ "$(param_value f2b_increment)" == yes ]]; then printf '，同一 IP 再犯时间加倍，最长 %s 天' "$(param_value f2b_maxtime_days)"; fi
}

# Fail2ban keeps bans in its database for a day by default: an address banned
# again later starts over at the first ban time. Kept for the longest ban, at
# least a week.
f2b_db_text() {
  local age=604800 max
  max=$(($(param_value f2b_maxtime_days) * 86400))
  ((max <= age)) || age="$max"
  printf '%s\n' '# VPS Stable Optimizer v2.8: how long bans are remembered ("banned again" doubles)' '[DEFAULT]' "dbpurgeage = $age"
}

# Writes (or writes again, after a parameter change) this tool's file; a
# history length set in another file is kept.
f2b_db_apply() {
  local f text
  text="$(f2b_db_text)"
  for f in "$F2B_DIR/fail2ban.local" "$F2B_DIR"/fail2ban.d/*.conf "$F2B_DIR"/fail2ban.d/*.local; do
    [[ -f "$f" && "$f" != "$F2B_DB_FILE" ]] || continue
    if grep -Eq '^[[:space:]]*dbpurgeage[[:space:]]*=' "$f"; then ok "$f 里已经设置了封禁历史的保留时间，保持不变。"; return 0; fi
  done
  if [[ -e "$F2B_DB_FILE" || -L "$F2B_DB_FILE" ]]; then
    [[ "$(cat -- "$F2B_DB_FILE" 2>/dev/null || true)" != "$text" ]] || return 0
    restore_file_ours f2b_db_file || { warn "$F2B_DB_FILE 不是本工具写的，保持不变。"; return 0; }
    rm -f -- "$F2B_DB_FILE"
  fi
  put_file "$F2B_DB_FILE" "$text" || warn "没能写入 $F2B_DB_FILE：再犯加倍只认得最近 1 天里封过的 IP。"
}

# Fail2ban only guards against guessed passwords: with key-only login on a
# machine under 1 GiB it is offered, not recommended (it takes about 30 MB).
# HARDEN: 1 when this setup is about to make the login key-only.
f2b_optional() {
  local effective
  ((${MEM_MIB:-0} < 1024)) || return 1
  [[ "${1:-0}" == 1 ]] && return 0
  effective="$(ssh_effective root)" || return 1
  [[ "$(ssh_effective_value "$effective" passwordauthentication)" == no &&
     "$(ssh_effective_value "$effective" kbdinteractiveauthentication)" != yes ]]
}

# Up to 2.7.5 every ban lasted 12 hours. Such a jail is upgraded in place.
f2b_jail_legacy_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.6 managed SSH jail' \
    '[sshd]' 'enabled = true' "port = $1" 'backend = systemd' \
    'action = vps-stable-ufw-sshd[port="%(port)s"]' \
    'maxretry = 5' 'findtime = 600' 'bantime = 43200'
}

# The managed jail (current or earlier, with any parameters) with or without
# an ignoreip line still belongs to this tool: its values are read back, and
# the jail made from them must be the same text.
f2b_jail_is_ours() {
  local body
  local -a values=()
  body="$(grep -v '^ignoreip = ' <<< "$1" || true)"
  [[ "$body" == "$(f2b_jail_legacy_text "$2")" ]] && return 0
  read -r -a values < <(awk -F' = ' '$1 == "maxretry" || $1 == "findtime" || $1 == "bantime" || $1 == "bantime.increment" || $1 == "bantime.maxtime" {v[$1] = $2}
    END {print v["maxretry"], v["findtime"], v["bantime"], v["bantime.increment"], v["bantime.maxtime"]}' <<< "$body") || return 1
  ((${#values[@]} == 5)) || return 1
  [[ "$body" == "$(f2b_jail_values_text "$2" "${values[@]}")" ]]
}

# The allowlist: the addresses on this tool's jail ignoreip line, one per line
# (the loopback ones every jail has are left out).
f2b_allowlist() {
  [[ -f "$F2B_FILE" && ! -L "$F2B_FILE" ]] || return 0
  awk '$1 == "ignoreip" && $2 == "=" {for (i = 3; i <= NF; i++) if ($i != "127.0.0.1/8" && $i != "::1") print $i}' "$F2B_FILE"
}

# ADDRESS: an IP, or a network no larger than /16 (IPv4) or /32 (IPv6); a
# larger one would take too many strangers off Fail2ban.
f2b_allow_valid() {
  local bits
  port_source_valid "$1" || { echo '格式不对：请输入一个 IP（例如 203.0.113.5）或网段（例如 203.0.113.0/24）。'; return 1; }
  [[ "$1" == */* ]] || return 0
  bits="${1##*/}"
  if [[ "$1" == *:* ]] && ((10#$bits < 32)); then echo '网段太大：IPv6 至少要 /32。'; return 1; fi
  if [[ "$1" != *:* ]] && ((10#$bits < 16)); then echo '网段太大：IPv4 至少要 /16。'; return 1; fi
}

# Writes F2B_ALLOW (space-separated) into this tool's jail and into the
# running jail, and keeps the SSH rate-limit exemptions in step.
f2b_allowlist_stage() {
  say 'Fail2ban 白名单'
  local current port body jail ip
  local -a was=() now=()
  if [[ ! -f "$F2B_FILE" || -L "$F2B_FILE" ]]; then warn '还没有本工具的 Fail2ban 规则：先在单项设置里开启 Fail2ban。'; return 0; fi
  current="$(cat -- "$F2B_FILE")"
  port="$(awk '$1 == "port" && $2 == "=" {print $3; exit}' <<< "$current")"
  if ! f2b_jail_is_ours "$current" "$port"; then
    warn "$F2B_FILE 不是本工具写的内容（或被改过），白名单没有改动。"; return 0
  fi
  mapfile -t was < <(f2b_allowlist)
  read -r -a now <<< "${F2B_ALLOW:-}"
  body="$(grep -v '^ignoreip = ' <<< "$current" || true)" jail="$body"
  if ((${#now[@]})); then jail+=$'\n'"ignoreip = 127.0.0.1/8 ::1 ${now[*]}"; fi
  if [[ "$jail" != "$current" ]] && ! f2b_replace_owned_file "$F2B_FILE" "$current" "$jail"; then
    warn '规则文件被同时改动，白名单没有改动。'; return 0
  fi
  # The running jail too, without a reload (bans stay as they are).
  if active fail2ban; then
    for ip in "${was[@]}"; do
      if [[ " ${now[*]} " != *" $ip "* ]]; then fail2ban-client set sshd delignoreip "$ip" >/dev/null 2>&1 || warn "正在运行的 Fail2ban 没能删掉 $ip，重启 Fail2ban 后生效。"; fi
    done
    for ip in "${now[@]}"; do
      if [[ " ${was[*]} " != *" $ip "* ]]; then fail2ban-client set sshd addignoreip "$ip" >/dev/null 2>&1 || warn "正在运行的 Fail2ban 没能加上 $ip，重启 Fail2ban 后生效。"; fi
    done
  fi
  if ufw_active; then
    for ip in "${was[@]}"; do
      if [[ " ${now[*]} " != *" $ip "* ]]; then ssh_limit_unexempt "$ip"; fi
    done
    for ip in "${now[@]}"; do ssh_limit_exempt_one "$ip"; done
  fi
  if ((${#now[@]})); then ok "白名单现在是：${now[*]}"; else ok '白名单已清空。'; fi
}

# The single item's allowlist menu: list, add (your current IP by default),
# delete; each change is applied right away.
f2b_allowlist_menu() {
  local choice me entry i msg bits
  local -a list=()
  me="${SSH_CONNECTION:-}" me="${me%% *}"
  while :; do
    say 'Fail2ban 白名单'
    echo '白名单里的地址输错密码也不会被封；单个 IP 在防火墙对 SSH 限速时连 SSH 也不限速，网段只防封。'
    mapfile -t list < <(f2b_allowlist)
    if ((${#list[@]} == 0)); then echo '  （现在是空的）'; fi
    for ((i = 0; i < ${#list[@]}; i++)); do
      entry="${list[i]}" msg=''
      if [[ "$entry" == "$me" ]]; then msg='  你现在的 IP'; fi
      if [[ "$entry" == */* ]]; then msg+='  网段：只防封'; fi
      printf '%3s. %s%s\n' "$((i + 1))" "$entry" "$msg"
    done
    if [[ -n "$me" && " ${list[*]} " != *" $me "* ]] && port_source_valid "$me"; then echo "你现在的 IP 是 $me，还不在白名单里。"; fi
    read -r -p 'a 添加，d 删除，0 返回: ' choice || return 0
    case "$choice" in
      a|A)
        if ((${#list[@]} >= 20)); then warn '白名单最多 20 个地址，先删掉不用的。'; continue; fi
        read -r -p "要加的 IP 或网段（直接回车加你现在的 IP ${me:-（读不到）}）: " entry || return 0
        entry="${entry:-$me}"
        [[ -n "$entry" ]] || continue
        if ! msg="$(f2b_allow_valid "$entry")"; then echo "$msg"; continue; fi
        if [[ " ${list[*]} " == *" $entry "* ]]; then ok "$entry 已经在白名单里。"; continue; fi
        if [[ "$entry" == */* ]]; then
          bits="${entry##*/}"
          if { [[ "$entry" == *:* ]] && ((10#$bits < 48)); } || { [[ "$entry" != *:* ]] && ((10#$bits < 24)); }; then
            confirm_yes "网段 $entry 很大：里面任何人输错密码都不会被封。仍然加入吗？" || continue
          fi
        fi
        F2B_ALLOW="${list[*]} $entry" F2B_ALLOW="${F2B_ALLOW# }"
        stage_run fail2ban f2b_allowlist_stage
        if [[ "$entry" != */* ]] && fail2ban-client status sshd 2>/dev/null | grep -F 'Banned IP list' | grep -w -- "$entry" > /dev/null &&
           confirm_default_yes "$entry 现在正被封禁，顺便解封吗？"; then
          fail2ban-client set sshd unbanip "$entry" >/dev/null && ok "已解封 $entry。"
        fi ;;
      d|D)
        ((${#list[@]})) || continue
        read -r -p "要删除第几个？[1-${#list[@]}，直接回车取消]: " i || return 0
        if [[ ! "$i" =~ ^[0-9]+$ ]] || ((i < 1 || i > ${#list[@]})); then continue; fi
        entry="${list[i - 1]}"
        if [[ "$entry" == "$me" ]]; then
          confirm_yes "$entry 是你现在的 IP：删掉后输错密码会被封，连 SSH 也会限速。仍然删除吗？" || continue
        fi
        F2B_ALLOW="$(printf '%s\n' "${list[@]}" | grep -vxF -- "$entry" | tr '\n' ' ' || true)" F2B_ALLOW="${F2B_ALLOW% }"
        stage_run fail2ban f2b_allowlist_stage ;;
      *) return 0 ;;
    esac
  done
}

# '' = ask now, none = no allowlist entry, otherwise the address to allow.
f2b_ignore_address() {
  local ip="${SSH_CONNECTION:-}"
  ip="${ip%% *}"
  case "${F2B_IGNORE_CHOICE:-}" in
    none) return 0 ;;
    '') [[ -n "$ip" ]] && port_source_valid "$ip" || return 0
        confirm_default_yes "把你当前的 IP $ip 加入 Fail2ban 白名单吗？（输错密码也不会被封，连 SSH 也不限速；家庭宽带 IP 常会变化，换了就失效）" || return 0
        printf '%s\n' "$ip" ;;
    *) port_source_valid "$F2B_IGNORE_CHOICE" && printf '%s\n' "$F2B_IGNORE_CHOICE" ;;
  esac
}

# `ufw prepend` places each ban first within its own IPv4 or IPv6 rule list;
# `insert 1` fails for an IPv6 address while rule 1 is an IPv4 rule.
f2b_action_text() {
  cat <<'F2B_ACTION'
# VPS Stable Optimizer v2.6: ban new TCP connections to SSH ports only.
# UFW must be active. Existing established connections are not killed.
[Definition]
actionstart =
actionstop =
actioncheck = LC_ALL=C /usr/sbin/ufw status | /usr/bin/grep -qx 'Status: active'
actionban = /usr/sbin/ufw prepend deny proto tcp from <ip> to any port <port>
actionunban = /usr/sbin/ufw delete deny proto tcp from <ip> to any port <port>

[Init]
port = 22
F2B_ACTION
}

# The only permitted replacement is an exact, known v2.6 state transition.
# In particular this never converts or overwrites an administrator jail.
f2b_replace_owned_file() {
  local file="$1" expected="$2" contents="$3" temp
  [[ -f "$file" && ! -L "$file" && "$(cat "$file")" == "$expected" ]] || return 1
  backup_config_path "$file" || die "无法备份配置：$file"
  temp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$contents" > "$temp" || ! chmod 644 "$temp"; then
    rm -f -- "$temp"; return 1
  fi
  if [[ ! -f "$file" || -L "$file" || "$(cat "$file")" != "$expected" ]]; then
    rm -f -- "$temp"; return 1
  fi
  if ! mv -f -- "$temp" "$file"; then rm -f -- "$temp"; return 1; fi
  record_config_change "$file" managed-transition || die '无法记录这次配置变更。'
}

# fail2ban.service is Type=simple: systemctl returns before the server's socket
# exists, so the jail is polled for up to 15 seconds and its status printed.
f2b_jail_ready() {
  local i out
  for ((i = 0; i < 15; i++)); do
    if out="$(fail2ban-client status sshd 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi
    sleep 1
  done
  return 1
}

fail2ban_stage() {
  step 15 'Fail2ban（防火墙生效后，只封 SSH 端口）'
  # Not chosen (key-only login under 1 GiB), unless password login is still
  # on after all (the SSH hardening was not done).
  if [[ "${F2B_CHOICE:-1}" == 0 ]]; then
    if f2b_optional; then
      ok '只允许密钥登录、内存不到 1 GiB：按你的选择不装 Fail2ban（以后可在单项设置里开启）。'
      module_result fail2ban declined 'key-only login, RAM < 1 GiB'; return 0
    fi
    ok 'SSH 仍允许密码登录：Fail2ban 还是要装。'
  fi
  if [[ "${FIREWALL_READY:-0}" != 1 ]]; then
    warn '防火墙没有确认生效，跳过 Fail2ban。'
    module_result fail2ban skipped 'firewall not ready'; return 0
  fi
  if ! ufw_active; then
    warn '防火墙没有开启，Fail2ban 保持不变。'
    module_result fail2ban skipped 'UFW inactive'; return 0
  fi
  if foreign_f2b_config; then
    ok '已有自定义的 Fail2ban 配置，保持不变。'
    module_result fail2ban preserved 'administrator jail configuration'; return 0
  fi
  if ! ssh_detect; then
    warn '无法确认 SSH 实际监听的端口，跳过 Fail2ban。'
    module_result fail2ban skipped 'SSH ports not verified'; return 0
  fi
  # Every early return below leaves Fail2ban unconfigured.
  module_result fail2ban failed 'setup incomplete; see run log'
  local joined guard jail action current='' previous='' ignore='' pkg
  local needed=()
  joined="$(IFS=,; echo "${SSH_PORTS[*]}")"
  guard="$(f2b_bootstrap_text)"
  action="$(f2b_action_text)"
  if [[ -e "$F2B_FILE" || -L "$F2B_FILE" ]]; then
    if [[ ! -f "$F2B_FILE" || -L "$F2B_FILE" ]]; then
      warn "Fail2ban 规则文件是链接或特殊文件，保持不变：$F2B_FILE"; return 0
    fi
    current="$(cat "$F2B_FILE")"
    # This tool's jail for the ports it names: it follows a changed SSH port.
    if [[ "$current" != "$guard" ]] && ! f2b_jail_is_ours "$current" "$(sed -n 's/^port = //p' <<< "$current" | head -n 1)"; then
      warn "已有自定义规则：$F2B_FILE。保持不变，请人工迁移后再试。"
      module_result fail2ban preserved 'jail file differs'; return 0
    fi
  fi
  # An existing managed jail keeps its allowlist line (also when an earlier
  # version's jail is upgraded); without one, the allowlist choice applies.
  if [[ "$current" != "$guard" ]]; then ignore="$(grep '^ignoreip = ' <<< "$current" || true)"; fi
  if [[ -n "$ignore" ]]; then jail="$(f2b_jail_text "$joined")"$'\n'"$ignore"
  else jail="$(f2b_jail_text "$joined" "$(f2b_ignore_address)")"; fi
  for pkg in fail2ban python3-systemd; do
    installed "$pkg" && continue
    # A fresh image may have no package index yet: refresh it once first.
    available "$pkg" || apt_index_ready || true
    if ! available "$pkg"; then warn "找不到软件包 $pkg，跳过 Fail2ban。"; return 0; fi
    needed+=("$pkg")
  done
  if ! installed fail2ban && [[ "$current" == "$jail" ]]; then
    warn 'Fail2ban 已被卸载但规则文件还在，保持不变，请人工处理。'; return 0
  fi
  # Install the action and disabled guard BEFORE apt can invoke package postinst.
  # put_file preserves every differing file; no distribution ufw action is edited.
  if [[ -L "$F2B_ACTION_FILE" ]]; then warn "封禁动作文件是链接，保持不变：$F2B_ACTION_FILE"; return 0; fi
  put_file "$F2B_ACTION_FILE" "$action" || return 0
  if [[ -z "$current" ]]; then
    put_file "$F2B_FILE" "$guard" || return 0
    current="$guard"
  fi
  if ((${#needed[@]})) && ! install_pkgs "${needed[@]}"; then
    warn 'Fail2ban 安装失败，SSH 规则保持停用状态。'; return 0
  fi
  if ! command -v fail2ban-client >/dev/null || ! installed python3-systemd; then
    warn '缺少 Fail2ban 或它读取系统日志的组件，不启用规则。'; return 0
  fi
  f2b_db_apply
  if foreign_f2b_config; then
    warn '安装过程中出现了其他 Fail2ban 配置，保持不变，规则保持停用。'; return 0
  fi
  # The disabled guard, or an earlier version's jail, becomes the current jail.
  if [[ "$current" != "$jail" ]]; then
    if ! f2b_replace_owned_file "$F2B_FILE" "$current" "$jail"; then
      warn '规则文件在安装时被改动，没有替换。'; return 0
    fi
    previous="$current"
  fi
  if [[ -L "$F2B_FILE" || "$(cat "$F2B_FILE" 2>/dev/null)" != "$jail" ||
        -L "$F2B_ACTION_FILE" || "$(cat "$F2B_ACTION_FILE" 2>/dev/null)" != "$action" ]]; then
    warn 'Fail2ban 配置在设置过程中被改动，不启动服务。'; return 0
  fi
  if ! fail2ban-client -t; then
    if [[ -n "$previous" ]]; then
      f2b_replace_owned_file "$F2B_FILE" "$jail" "$previous" || warn '无法恢复原来的规则文件，重启前请检查。'
    fi
    warn 'Fail2ban 配置检查没通过，不启用服务。'; return 0
  fi
  if ! systemctl enable fail2ban; then warn '无法设置 Fail2ban 开机启动。'; return 0; fi
  if active fail2ban; then
    if ! systemctl restart fail2ban; then warn '无法重启 Fail2ban。'; return 0; fi
  else
    if ! systemctl start fail2ban; then warn '无法启动 Fail2ban。'; return 0; fi
  fi
  if f2b_jail_ready; then
    ok "Fail2ban 已就绪：只封禁 SSH 端口 $joined 的 TCP 连接；$(f2b_policy_text)。"
    module_result fail2ban applied "sshd jail on $joined"
  else
    warn 'Fail2ban 已启动，但 SSH 规则没有加载，请查看状态和日志。'
  fi
}


# Only `ufw add`-style rules this tool created are recorded; rollback deletes
# exactly those and never touches later port rules or Fail2ban bans.
ufw_rule() {
  local verb="$1" port="$2" proto="${3:-tcp}" expected rules
  expected="ufw $verb $port/$proto"
  rules="$(ufw show added)" || return 1
  grep -Fxq "$expected" <<< "$rules" && return 0
  ufw "$verb" "$port/$proto" || return 1
  if declare -F restore_record_fw_rule >/dev/null; then
    restore_record_fw_rule "$expected" || warn "无法记录规则 $expected，回退时它会被保留。"
  fi
}

# An inactive UFW may still contain rules. Allow rules only widen access and
# cannot lock the SSH session out; anything else requires administrator review.
# Allowed: allow rules, the SSH rate limit, and Fail2ban-style SSH bans (one
# address denied on SSH ports only, e.g. "port 22,2222"). Bans pile up while
# the firewall is paused.
ufw_stored_rules_safe() {
  local rules line port allowed src
  local -a listed=()
  local ban='^ufw (prepend |insert [0-9]+ )?deny (proto tcp )?from ([0-9A-Fa-f:./]+) to any port ([0-9]+(,[0-9]+)*)( proto tcp)?$'
  rules="$(ufw show added)" || { warn '无法读取已保存的 UFW 规则。'; return 1; }
  while IFS= read -r line; do
    [[ "$line" == "ufw "* ]] || continue
    [[ "$line" == 'ufw allow '* ]] && continue
    allowed=0
    for port in "${SSH_PORTS[@]}"; do
      if [[ "$line" == "ufw limit $port/tcp" ]]; then allowed=1; break; fi
    done
    if (( !allowed )) && [[ "$line" =~ $ban ]] && [[ -n "${BASH_REMATCH[2]}" || -n "${BASH_REMATCH[6]}" ]]; then
      src="${BASH_REMATCH[3]}"
      IFS=, read -r -a listed <<< "${BASH_REMATCH[4]}"
      allowed=1
      for port in "${listed[@]}"; do [[ " ${SSH_PORTS[*]} " == *" $port "* ]] || allowed=0; done
      # Fail2ban bans one address; a network may cover the admin's own address.
      if [[ "$src" == */* ]] || ! port_source_valid "$src"; then allowed=0; fi
    fi
    if (( !allowed )); then
      warn "未开启的 UFW 里有需要人工核对的规则：$line。保持不变，不自动开启。"
      return 1
    fi
  done <<< "$rules"
  return 0
}

# SSH anti-lockout guards: a transient timer undoes a change after 240 seconds
# unless a second SSH login is confirmed. RemainAfterElapse=no lets a fired
# guard unload itself instead of blocking later retries and uninstall.
guard_leftovers() {
  local units
  if ! units="$(systemctl list-units --type=timer --all --no-legend --full --no-pager 'vps-stable-ufw-rollback-*' 'vps-stable-ssh-revert-*' 2>/dev/null)"; then
    warn '无法检查之前的防失联计时器，跳过这次修改。'; return 0
  fi
  units="$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^vps-stable-(ufw-rollback|ssh-revert)-[A-Za-z0-9-]+\.timer$/) print $i}' <<< "$units")"
  [[ -n "$units" ]] || return 1
  warn "上一次的防失联计时器还没结束：$(tr '\n' ' ' <<< "$units")"
  echo '它会在到期时撤销上一次未确认的修改。查看：systemctl list-timers --all "vps-stable-*"'
  echo '确认上一次的修改已安全处理后，可执行 systemctl stop <上面的单元名> 再重试。'
  return 0
}

# The start of a confirmation window. The journal is searched from a whole
# second on, so a login made just before the change, in the same second, would
# count as one that went through it: start at the next second instead.
guard_since() {
  sleep 1
  date +%s
}

guard_arm() {
  local unit="$1"
  shift
  systemd-run --quiet --unit="$unit" --on-active=240s --timer-property=AccuracySec=1s \
    --timer-property=RemainAfterElapse=no "$@" || return 1
  active "$unit.timer"
}

# An SSH login accepted since SINCE (epoch seconds), optionally only for USER
# and only by METHOD (publickey). Only entries written by sshd as root count:
# any local user can log a fake "sshd" line with logger, but not as root.
ssh_login_seen() {
  local since="$1" user="${2:-}" method="${3:-}"
  command -v journalctl >/dev/null || return 1
  journalctl -q --since "@$since" _UID=0 -t sshd -t sshd-session -o cat --no-pager 2>/dev/null |
    awk -v u="$user" -v m="$method" '$1 == "Accepted" && (m == "" || $2 == m) && $3 == "for" && (u == "" || $4 == u) {found = 1} END {exit !found}'
}

# Success means the confirmation arrived in time and the still-pending guard
# was cancelled before its job ran; callers must re-verify the protected state.
# Confirmed by the optional CHECK command (a new SSH login in the journal,
# polled every 2 seconds) or by CONNECTED typed in THIS window. A typo asks
# again until the deadline; n, timeout or end of input restore.
guard_confirm() {
  local unit="$1" deadline="$2" remaining answer started rc prompt=1
  shift 2
  # An "n" typed ahead would undo the change at once.
  input_flush
  while :; do
    remaining=$((deadline - SECONDS))
    # prompt=0 means the prompt is on screen without a newline yet.
    if ((remaining <= 0)); then
      if ((prompt == 0)); then printf '\n'; fi
      return 1
    fi
    if (($#)) && "$@"; then
      if ((prompt == 0)); then printf '\n'; fi
      ok '已在系统日志里看到新窗口登录成功，自动确认。'; break
    fi
    if ((prompt)); then
      printf '等待确认（剩余 %s 秒）：新窗口登录成功后这里会自动确认；没有自动确认时，在【这个窗口】输入 CONNECTED 并回车；新窗口登录失败就在这里输入 n，立即恢复: ' "$remaining"
      prompt=0
    fi
    answer=''
    # Short reads let the journal check run in between; a half-typed line stays
    # in the terminal's line buffer until Enter, so typing is never lost.
    if read -r -t 2 answer; then
      case "$answer" in
        CONNECTED) break ;;
        n|N) return 1 ;;
      esac
      if [[ "${answer^^}" == CONNECTED ]]; then echo '要用大写：CONNECTED（区分大小写），请再输入一次。'
      else echo '输入的不是 CONNECTED。在新窗口登录成功后，回到这个窗口输入 CONNECTED（新窗口里不用输入）；登录失败输入 n 立即恢复，或等计时结束自动恢复。'; fi
      prompt=1
    else
      rc=$?
      if ((rc <= 128)); then printf '\n'; return 1; fi
    fi
  done
  # Confirmed: cancel the timer and any start job it already queued for its
  # service. Each failure says why, so it is not mistaken for "no CONNECTED".
  if ! active "$unit.timer"; then
    warn "已收到确认，但自动撤销计时器已经到期（$unit.timer），撤销可能已经执行。"; return 1
  fi
  # A transient service that never ran may already be unloaded once its timer
  # stops; "not loaded" is not an error here.
  systemctl stop "$unit.timer" >/dev/null 2>&1 || true
  systemctl stop "$unit.service" >/dev/null 2>&1 || true
  if active "$unit.timer"; then warn "已收到确认，但无法停止自动撤销计时器（$unit.timer）。"; return 1; fi
  # An unloaded unit reports 0 or nothing; a start time means the undo ran.
  started="$(systemctl show "$unit.service" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)"
  if [[ -n "$started" && "$started" != 0 ]]; then warn '已收到确认，但自动撤销已经执行过。'; return 1; fi
  return 0
}

web_ports_wanted() {
  case "${WEB_CHOICE:-}" in 1) return 0 ;; 0) return 1 ;; esac
  confirm_yes "$1"
}

docker_present() {
  command -v docker >/dev/null 2>&1 || command -v dockerd >/dev/null 2>&1 || [[ -S /var/run/docker.sock ]]
}

# Docker publishes container ports through its own iptables chains (FORWARD),
# so UFW's INPUT rules never see that traffic.
docker_firewall_note() {
  docker_present || return 0
  warn '检测到 Docker：用 -p 发布的容器端口会绕过 UFW，防火墙挡不住它们。'
  echo '对策：只在本机使用的容器端口绑定到 127.0.0.1（例如 -p 127.0.0.1:8080:80）；需要对外的，在服务商安全组限制来源，或使用 DOCKER-USER 链（例如 ufw-docker）。'
}

# Services reachable from outside right now that turning UFW on would block,
# one "port/proto<TAB>program" per line (IPv4 and IPv6 may repeat: sort -u).
# Left out: SSH, TCP 80/443 (the web-port question decides those), ports a
# stored rule already mentions (also source-limited ones, which must stay
# limited), loopback and link-local listeners, Docker's published ports
# (they bypass UFW anyway) and system helpers that should not face the
# internet (LLMNR/mDNS, DHCP, rpcbind, time sync, libvirt's dnsmasq).
firewall_blocked_listeners() {
  local rules netid local_addr proc port addr p skip
  command -v ss >/dev/null || return 0
  rules="$(ufw show added 2>/dev/null || true)"
  while read -r netid _ _ _ local_addr _ proc; do
    [[ "$netid" == tcp || "$netid" == udp ]] || continue
    port="${local_addr##*:}"; addr="${local_addr%:*}"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    case "$addr" in 127.*|'[::1]'|::1|*%lo|'[::ffff:127.'*|'[fe80:'*|fe80:*) continue ;; esac
    proc="$(sed -n 's/^users:(("\([^"]*\)".*/\1/p' <<< "${proc:-}")"
    case "$proc" in
      sshd|systemd-resolve*|systemd-network*|systemd-timesyn*|dhclient|dhcpcd|avahi-daemon|rpcbind|rpc.statd|chronyd|ntpd|cupsd|docker-proxy|dnsmasq|NetworkManager) continue ;;
    esac
    skip=0
    if [[ "$netid" == tcp ]]; then
      for p in "${SSH_PORTS[@]}"; do if [[ "$p" == "$port" ]]; then skip=1; fi; done
      if [[ "$port" == 80 || "$port" == 443 ]]; then skip=1; fi
    fi
    if grep -Eq "^ufw (allow|limit) (.* )?${port}(/${netid})?( .*)?$" <<< "$rules"; then skip=1; fi
    if ((skip == 0)); then printf '%s/%s\t%s\n' "$port" "$netid" "$proc"; fi
  done < <(ss -H -lntup 2>/dev/null || true)
}

# The allowlist choice for Fail2ban also decides who skips the SSH rate limit.
# Still open (a firewall turned on from the menus): the address in this tool's
# jail counts; otherwise the question is asked now, for both, unless --no-ask.
ssh_allowlist_decide() {
  local line
  [[ -z "${F2B_IGNORE_CHOICE:-}" ]] || return 0
  line="$(grep -m1 '^ignoreip = 127\.0\.0\.1/8 ::1 ' "$F2B_FILE" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then F2B_IGNORE_CHOICE="${line##* }"; return 0; fi
  [[ "${1:-}" != --no-ask ]] || return 0
  F2B_IGNORE_CHOICE="$(f2b_ignore_address)"
  [[ -n "$F2B_IGNORE_CHOICE" ]] || F2B_IGNORE_CHOICE=none
}

# Allowlisted administrator addresses skip the SSH rate limit, so several
# connections at once (file transfer tools, editors, reconnects) are not
# refused: the setup's choice and every single address on the Fail2ban
# allowlist (a network only keeps its addresses from being banned).
ssh_limit_exempt() {
  local ip
  local -a ips=()
  if [[ "${F2B_IGNORE_CHOICE:-none}" != none ]]; then ips+=("$F2B_IGNORE_CHOICE"); fi
  while IFS= read -r ip; do
    if [[ " ${ips[*]} " != *" $ip "* ]]; then ips+=("$ip"); fi
  done < <(f2b_allowlist)
  for ip in "${ips[@]}"; do ssh_limit_exempt_one "$ip"; done
}

# IP: placed before the limit rules (prepend), one rule per limited SSH port,
# recorded for rollback like the other rules of this tool.
ssh_limit_exempt_one() {
  local ip="$1" rules p rule
  [[ "$ip" != */* ]] && port_source_valid "$ip" || return 0
  rules="$(ufw show added 2>/dev/null || true)"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    rule="ufw allow from $ip to any port $p proto tcp"
    if grep -Fxq -- "$rule" <<< "$rules"; then continue; fi
    if ufw prepend allow proto tcp from "$ip" to any port "$p" >/dev/null; then
      ok "白名单 IP $ip 连 SSH 端口 $p 不限速。"
      if declare -F restore_record_fw_rule >/dev/null; then
        restore_record_fw_rule "$rule" || warn "无法记录规则 $rule，回退时它会被保留。"
      fi
    else
      warn "没能让 $ip 免于 SSH 限速（端口 $p），它照常限速。"
    fi
  done < <(sed -n 's/^ufw limit \([0-9]*\)\/tcp$/\1/p' <<< "$rules")
}

host_has_global_ipv6() {
  command -v ip >/dev/null && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# IP: the exemption rules this tool added for IP go again (only those it
# recorded: the same rule added by hand stays).
ssh_limit_unexempt() {
  local ip="$1" rule p record="$RESTORE_ROOT/fw_rules" temp
  [[ -f "$record" && ! -L "$record" ]] || return 0
  while IFS= read -r rule; do
    [[ "$rule" =~ ^ufw\ allow\ from\ ([0-9A-Fa-f:.]+)\ to\ any\ port\ ([0-9]{1,5})\ proto\ tcp$ && "${BASH_REMATCH[1]}" == "$ip" ]] || continue
    p="${BASH_REMATCH[2]}"
    if ufw --force delete allow proto tcp from "$ip" to any port "$p" >/dev/null 2>&1; then ok "$ip 连 SSH 端口 $p 恢复限速。"
    else warn "没能删掉 $ip 的免限速规则（端口 $p），请用 ufw status numbered 检查。"; continue; fi
    temp="$(mktemp "$RESTORE_ROOT/.write.XXXXXX")" || continue
    { grep -vxF -- "$rule" "$record" > "$temp" || true; }
    if ! chmod 600 -- "$temp" || ! mv -fT -- "$temp" "$record"; then rm -f -- "$temp"; fi
  done < <(cat -- "$record")
}

# Rewrites the single IPV6= assignment of /etc/default/ufw.
ufw_set_ipv6() {
  local value="$1" file=/etc/default/ufw temp
  [[ "$value" == yes || "$value" == no ]] || return 1
  [[ -f "$file" && ! -L "$file" ]] || return 1
  case "$(audit_ufw_ipv6 < "$file")" in yes|no) ;; *) return 1 ;; esac
  temp="$(mktemp "$file.tmp.XXXXXX")" || return 1
  if ! cp -p -- "$file" "$temp" || ! sed -E -i "s/^([[:space:]]*IPV6[[:space:]]*=).*/\\1$value/" "$temp" ||
     [[ "$(audit_ufw_ipv6 < "$temp")" != "$value" ]] || ! mv -f -- "$temp" "$file"; then
    rm -f -- "$temp"; return 1
  fi
}

# Only called before UFW is enabled: with IPV6=no a host with a public IPv6
# address is completely unfiltered over IPv6.
IPV6_FLIPPED=0
ufw_ipv6_check() {
  [[ -r /etc/default/ufw && "$(audit_ufw_ipv6 < /etc/default/ufw)" == no ]] || return 0
  host_has_global_ipv6 || return 0
  warn '本机有公网 IPv6 地址，但 UFW 设置了 IPV6=no：IPv6 入口完全不受防火墙保护。'
  confirm_yes '开启 UFW 的 IPv6 防护吗？（把 /etc/default/ufw 里的 IPV6=no 改为 yes）（推荐）' || return 0
  backup_config_path /etc/default/ufw || die '无法备份 /etc/default/ufw'
  if ufw_set_ipv6 yes; then
    record_config_change /etc/default/ufw ipv6-enabled || die '无法记录 /etc/default/ufw 的变更。'
    IPV6_FLIPPED=1
    ok '已开启 UFW 的 IPv6 防护。'
  else
    warn '修改 IPV6 设置失败，保持不变。'
  fi
}

ssh_password_disabled() {
  local values
  command -v sshd >/dev/null || return 1
  sshd_runtime_dir
  values="$(sshd -T 2>/dev/null | audit_sshd_values)" || return 1
  grep -Fxq 'passwordauthentication=no' <<< "$values" && grep -Fxq 'kbdinteractiveauthentication=no' <<< "$values"
}

# `ufw enable` does not touch ufw.service. After a rollback disabled it, the
# firewall would stay off after the next reboot, so it is enabled whenever the
# firewall is kept on (seen on a real Debian 13 VPS).
ufw_boot_enable() {
  local state
  state="$(systemctl is-enabled ufw.service 2>/dev/null || true)"
  case "$state" in
    enabled) ;;
    static|indirect|generated|alias)
      warn "ufw.service 的启用方式比较特殊（$state），无法确认开机时会不会加载防火墙，请人工检查。"; return 0 ;;
    *)
      # enabled-runtime lasts only until the next reboot; enable makes it persistent.
      if systemctl enable ufw.service >/dev/null 2>&1 && [[ "$(systemctl is-enabled ufw.service 2>/dev/null || true)" == enabled ]]; then
        ok '已设置防火墙开机自动加载（ufw.service）。'
      else warn '无法设置 ufw.service 开机启动：重启后防火墙可能不会加载，请手动运行 systemctl enable ufw。'; return 0; fi ;;
  esac
  # "ufw enable" loads the rules without starting ufw.service. Starting it now
  # only reports "already started" (rules untouched), and the service state
  # matches the one after a reboot, so later runs see no change from outside.
  if ufw_active && ! active ufw.service; then systemctl start ufw.service >/dev/null 2>&1 || true; fi
}

# Existing UFW active: preserve current policies, no automatic edits except confirmed web ALLOW.
# The kernel settings UFW applies whenever it starts: the IPT_SYSCTL file of
# /etc/default/ufw (normally /etc/ufw/sysctl.conf), as sysctl key names.
ufw_sysctl_keys() {
  local defaults="${1:-/etc/default/ufw}" file
  file="$(awk -F= '$1 == "IPT_SYSCTL" {gsub(/["\047[:space:]]/, "", $2); path = $2} END {print path}' "$defaults" 2>/dev/null || true)"
  [[ -n "$file" ]] || file=/etc/ufw/sysctl.conf
  [[ -f "$file" && ! -L "$file" ]] || return 0
  awk -F= '/^[[:space:]]*[a-z]/ && NF >= 2 {key = $1; gsub(/[[:space:]]/, "", key); gsub(/\//, ".", key); print key}' "$file"
}

firewall_stage() {
  step 14 '防火墙（需要新 SSH 窗口确认）'
  FIREWALL_READY=0
  command -v ufw >/dev/null || { warn '还没有安装 ufw，请先运行一键开荒。'; module_result firewall skipped 'ufw missing'; return 0; }
  local state rules p ip unit deadline since ssh_verb=limit web=0 line key value
  local -a listeners=() extra=()
  if ! state="$(ufw status 2>/dev/null)"; then
    warn '无法确定防火墙状态，跳过。'; module_result firewall failed 'UFW state unknown'; return 0
  fi
  if guard_leftovers; then module_result firewall skipped 'earlier protection timer pending'; return 0; fi
  if grep -Fxq 'Status: active' <<< "$state"; then
    ok 'UFW 已经开启：保留现有的 SSH 规则和默认策略。'
    docker_firewall_note
    if [[ -r /etc/default/ufw && "$(audit_ufw_ipv6 < /etc/default/ufw)" == no ]] && host_has_global_ipv6; then
      # Flipping IPV6 on a live firewall would drop IPv6 SSH until v6 rules exist.
      warn '本机有公网 IPv6 地址，但 UFW 设置了 IPV6=no：IPv6 入口不受防火墙保护。'
      echo '防火墙正在运行，为免断开 IPv6 上的 SSH，这里不直接修改。可先 ufw disable，再运行 vps firewall 按提示开启 IPv6 防护。'
    fi
    rules="$(ufw show added)" || { warn '无法读取 UFW 规则，保持现状。'; module_result firewall preserved 'UFW active; rules unreadable'; return 0; }
    if ! grep -Fxq 'ufw allow 80/tcp' <<< "$rules" || ! grep -Fxq 'ufw allow 443/tcp' <<< "$rules"; then
      if web_ports_wanted 'UFW 已开启，要另外放行网站端口 TCP 80、443 吗？'; then
        ufw_rule allow 80; ufw_rule allow 443
      else ok '网站端口规则保持不变。'; fi
    fi
    if grep -Eq '^ufw limit [0-9]+/tcp$' <<< "$rules"; then ssh_allowlist_decide --no-ask; ssh_limit_exempt; fi
    ufw status numbered
    ufw_boot_enable
    FIREWALL_READY=1
    module_result firewall present 'UFW already active'
    return 0
  fi
  if ! grep -Fxq 'Status: inactive' <<< "$state"; then
    warn '无法识别防火墙状态，不开启。'; module_result firewall failed 'unrecognized UFW state'; return 0
  fi
  if firewall_conflict; then
    warn '检测到其他防火墙规则或无法读取规则，不自动接管。'
    module_result firewall preserved 'other firewall rules present'; return 0
  fi
  if ! ssh_detect; then
    warn '无法确认 SSH 配置和实际监听的端口，不开启防火墙。'
    module_result firewall skipped 'SSH ports not verified'; return 0
  fi
  ufw_stored_rules_safe || { module_result firewall preserved 'unreviewed stored UFW rules'; return 0; }
  ip="${SSH_CONNECTION:-}"
  ip="${ip%% *}"
  if [[ -n "$ip" ]] && active fail2ban && command -v fail2ban-client >/dev/null; then
    if ! rules="$(fail2ban-client get sshd banip 2>/dev/null)"; then
      warn '无法读取 Fail2ban 的封禁列表，不开启防火墙。'; module_result firewall skipped 'Fail2ban state unknown'; return 0
    fi
    if grep -Fxq "$ip" <<< "$(tr ' ' '\n' <<< "$rules")"; then
      warn "你当前的 IP（$ip）正被 Fail2ban 封禁，不开启防火墙。"; module_result firewall skipped 'current IP banned'; return 0
    fi
  fi
  if ssh_password_disabled; then ssh_verb=allow; fi
  printf '已确认 SSH 端口：%s\n' "${SSH_PORTS[*]}"
  if [[ "$ssh_verb" == limit ]]; then
    echo 'SSH 仍允许密码登录：SSH 端口使用限速放行（同一 IP 30 秒内连接 6 次会被暂时拒绝；白名单 IP 不受限）。'
    ssh_allowlist_decide
  else
    echo 'SSH 已关闭密码登录：SSH 端口使用普通放行，防爆破交给 Fail2ban。'
  fi
  if web_ports_wanted '同时放行网站端口 TCP 80、443 吗？（只做代理或跳板可以不开）'; then web=1; fi
  docker_firewall_note
  mapfile -t listeners < <(firewall_blocked_listeners | sort -u)
  if ((${#listeners[@]})); then
    warn '下面这些服务现在能从外网访问，开启防火墙后会被挡住：'
    for line in "${listeners[@]}"; do
      p="${line#*$'\t'}"
      printf '  %-12s %s\n' "${line%%$'\t'*}" "${p:-（程序未知）}"
    done
    if confirm_default_yes '一并放行这些端口，让它们照常能访问吗？（不认识或只在本机用的，输入 n）'; then
      for line in "${listeners[@]}"; do extra+=("${line%%$'\t'*}"); done
    else
      ok '这些端口不放行；以后需要时可用「端口管理」放行。'
    fi
  fi
  echo '其他入站默认拒绝；以后需要的端口可用菜单里的「端口管理」放行。'
  echo '请确保商家 Console/VNC/救援可用，并保留原 SSH 窗口。'
  if ! confirm_yes '已确认服务商的控制台（Console/VNC）可以登录，正式开启防火墙吗？'; then
    ok '你选择了暂不开启防火墙。'; module_result firewall declined 'activation declined'; return 0
  fi
  command -v systemd-run >/dev/null || die '缺少 systemd-run，无法安全开启防火墙。'
  if guard_leftovers; then module_result firewall skipped 'earlier protection timer pending'; return 0; fi
  IPV6_FLIPPED=0
  ufw_ipv6_check
  for p in "${SSH_PORTS[@]}"; do ufw_rule "$ssh_verb" "$p"; done
  if [[ "$ssh_verb" == limit ]]; then ssh_limit_exempt; fi
  if ((web)); then ufw_rule allow 80; ufw_rule allow 443; fi
  for p in "${extra[@]}"; do
    ufw_rule allow "${p%/*}" "${p#*/}" || warn "放行 $p 失败，开启后它会被挡住。"
  done
  # Rules stored while IPV6=no exist for IPv4 only; re-adding lets UFW add the
  # missing IPv6 copies (it skips the existing IPv4 ones).
  if ((IPV6_FLIPPED)); then
    for p in "${SSH_PORTS[@]}"; do ufw "$ssh_verb" "$p/tcp" >/dev/null; done
    if ((web)); then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
    for p in "${extra[@]}"; do ufw allow "$p" >/dev/null || true; done
  fi
  ufw default deny incoming
  ufw default allow outgoing
  rules="$(ufw show added)" || die '无法核对已保存的规则，防火墙保持关闭。'
  for p in "${SSH_PORTS[@]}"; do
    grep -Fxq "ufw $ssh_verb $p/tcp" <<< "$rules" || die "SSH 端口 $p 没有成功放行，已停止。"
  done
  unit="vps-stable-ufw-rollback-$(date +%s)-$$"
  guard_arm "$unit" /usr/sbin/ufw --force disable || die '无法启用自动撤销计时器，防火墙保持关闭。'
  # Count the confirmation window from arming, not from completion of ufw enable.
  deadline=$((SECONDS + 180))
  ok "已启用 240 秒自动撤销计时器：$unit.timer"
  # UFW changes these when it starts and leaves them when it stops: keep the
  # running values, so that turning the firewall off again puts them back.
  if ! ufw_active; then
    while IFS= read -r key; do
      value="$(sysctl -n "$key" 2>/dev/null)" || continue
      restore_record_sysctl "$key" "$value" ufw_sysctl_runtime || warn "无法记录 $key 的原值；撤销防火墙后要重启才会恢复。"
    done < <(ufw_sysctl_keys)
  fi
  if ! ufw --force enable; then
    warn '开启防火墙失败，自动撤销计时器保持启用。'; module_result firewall failed 'ufw enable failed'; return 0
  fi
  # Only logins after this moment went through the enabled firewall.
  since="$(guard_since)"
  ufw status numbered
  echo '请保留这个窗口不要关。现在新开一个 SSH 窗口登录服务器：登录成功后，这里通常几秒内就会自动确认，新窗口里什么都不用输入。'
  echo '如果没有自动确认，就回到这个窗口输入 CONNECTED；180 秒内没有确认，会自动关闭防火墙恢复原样。'
  if guard_confirm "$unit" "$deadline" ssh_login_seen "$since"; then
    if ufw_active; then
      ok '防火墙已保留，自动撤销计时器已取消。'
      ufw_boot_enable
      FIREWALL_READY=1
      ufw status verbose
      module_result firewall applied "SSH ${SSH_PORTS[*]} ($ssh_verb)"
      return 0
    fi
    warn '已收到确认，但防火墙现在不是开启状态（可能已被自动撤销，或被其他程序关闭）。'
  fi
  warn '这次没有确认成功，正在关闭防火墙恢复原样；可以稍后重试。'
  module_result firewall failed 'second SSH login not confirmed; UFW disabled'
  if ufw --force disable; then
    systemctl stop "$unit.timer" || true
  else
    warn '立即关闭防火墙失败，保留或重新启用自动撤销计时器。'
    if ! active "$unit.timer"; then
      guard_arm "$unit-retry" /usr/sbin/ufw --force disable || warn '无法重新启用自动撤销计时器，请用服务商控制台检查防火墙。'
    fi
  fi
  ufw status verbose || true
}

# SSH login hardening. Password login is disabled only after a key login has
# been observed; root SSH login only after a sudo-capable account has logged in
# with a key and used sudo. The drop-in removes itself after 240 seconds unless
# a new login is confirmed. Keys and accounts are never removed, not even by rollback.
ssh_dropin_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.6: key-only SSH login and session limits' \
    'PasswordAuthentication no' 'KbdInteractiveAuthentication no'
  if [[ "${1:-0}" == 1 ]]; then printf '%s\n' 'PermitRootLogin no'; fi
  # MaxAuthTries 4 leaves room for a few ssh-agent keys before the right one.
  # Idle connections are the SSH keepalive item's (its own drop-in).
  printf '%s\n' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no'
}

ssh_pubkey_valid() {
  local key="$1" temp rc=0
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+={0,3}(\ [^[:cntrl:]]*)?$ ]] || return 1
  command -v ssh-keygen >/dev/null || return 1
  temp="$(mktemp)" || return 1
  printf '%s\n' "$key" > "$temp" || rc=1
  ((rc)) || ssh-keygen -l -f "$temp" >/dev/null 2>&1 || rc=1
  rm -f -- "$temp"
  return "$rc"
}

# ssh-keygen fails on a file without any valid key (an empty or comment-only
# authorized_keys is common on VPS images); that simply counts as 0 keys.
ssh_key_count() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || { echo 0; return 0; }
  ssh-keygen -l -f "$file" 2>/dev/null | awk 'NF >= 2 {n++} END {print n+0}' || true
}

# Effective settings for the target account, including Match blocks.
ssh_effective() {
  local user="$1" addr="${SSH_CONNECTION:-}"
  addr="${addr%% *}"
  [[ -n "$addr" ]] || addr=127.0.0.1
  sshd_runtime_dir
  sshd -T -C "user=$user,host=$(hostname 2>/dev/null || echo localhost),addr=$addr" 2>/dev/null
}

ssh_effective_value() {
  awk -v key="$2" 'tolower($1) == key {sub(/^[^ ]+ /, ""); print; exit}' <<< "$1"
}

# sudo's success record "USER : TTY=... ; USER=root ; COMMAND=/usr/bin/true",
# written as root. Failed attempts put text before TTY= ("3 incorrect password
# attempts", "user NOT in sudoers") and a line from `logger -t sudo` by a local
# user is not written as root: neither counts.
# sudo logs under the real UID of the account that ran it, so lines from that
# account (or root) count; a line another local user writes with
# `logger -t sudo` carries that user's UID and is ignored.
ssh_sudo_seen() {
  local user="$1" since="$2" uid
  command -v journalctl >/dev/null || return 1
  uid="$(getent passwd "$user" | cut -d: -f3)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  journalctl -q --since "@$since" _UID=0 "_UID=$uid" -t sudo -o cat --no-pager 2>/dev/null |
    awk -v u="$user" '$1 == u && $2 == ":" && $3 ~ /^TTY=/ && $0 ~ /USER=root ; COMMAND=(\/usr)?\/bin\/true$/ {found = 1} END {exit !found}'
}

ssh_reload() {
  systemctl try-reload-or-restart ssh.service 2>/dev/null || systemctl try-reload-or-restart sshd.service 2>/dev/null
}

# P = usable password, L = locked, NP = empty. The provider's VNC/console is a
# local password login: without P there, a lost key means no way back in.
console_password_state() {
  local raw state
  raw="$(passwd -S "$1" 2>/dev/null)" || { echo unknown; return 0; }
  state="$(audit_passwd_state <<< "$raw")" || state=unknown
  printf '%s\n' "$state"
}

# The account (or root) owns its home and nobody else can write to it; sshd's
# StrictModes would ignore keys there otherwise.
ssh_home_safe() {
  local user="$1" home="$2" owner mode
  [[ "$home" == /* && -d "$home" && ! -L "$home" ]] || return 1
  owner="$(stat -c '%U' -- "$home")" || return 1
  mode="$(stat -c '%a' -- "$home")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$owner" == "$user" || "$owner" == root ]] && (( (8#$mode & 8#022) == 0 ))
}

# Appends a public key as the account itself, so a link planted in its home
# can only ever reach files that account could already write.
ssh_append_key() {
  local user="$1" home="$2" key="$3"
  # The inner script is single-quoted on purpose: its "$1" is the home folder.
  # shellcheck disable=SC2016
  printf '%s\n' "$key" | runuser -u "$user" -- /bin/sh -c '
    umask 077
    d="$1/.ssh"; f="$d/authorized_keys"
    [ ! -L "$d" ] && mkdir -p "$d" && [ ! -L "$f" ] || exit 3
    chmod 700 "$d" || exit 3
    IFS= read -r key || exit 4
    if [ -f "$f" ] && grep -Fxq -- "$key" "$f"; then exit 0; fi
    if [ -s "$f" ] && [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then printf "\n" >> "$f" || exit 5; fi
    printf "%s\n" "$key" >> "$f" && chmod 600 "$f"
  ' sh "$home"
}

admin_name_valid() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ && "$1" != root ]]
}

# Creates the account, or reuses a regular one, makes it a sudo member and
# makes sure it has a password (needed for sudo and for console logins).
admin_prepare() {
  local name="$1" uid tries
  if getent passwd "$name" >/dev/null; then
    uid="$(getent passwd "$name" | cut -d: -f3)"
    if [[ ! "$uid" =~ ^[0-9]+$ ]] || ((uid < 1000)); then warn "账户 $name 是系统账户，不能用作管理员。"; return 1; fi
    ok "使用已有账户：$name"
  else
    useradd -m -s /bin/bash -- "$name" || { warn "创建账户 $name 失败。"; return 1; }
    ok "已创建账户：$name"
  fi
  if ! command -v sudo >/dev/null; then
    available sudo || apt_index_ready || true
    if available sudo; then install_pkgs sudo || { warn '安装 sudo 失败。'; return 1; }
    else warn '没有可用的 sudo 软件包，无法创建管理员。'; return 1; fi
  fi
  if [[ " $(id -nG "$name" 2>/dev/null) " != *' sudo '* ]]; then
    usermod -aG sudo -- "$name" || { warn "无法把 $name 加入 sudo 组。"; return 1; }
  fi
  for ((tries = 0; tries < 3; tries++)); do
    [[ "$(console_password_state "$name")" == P ]] && break
    echo "请为 $name 设置密码：sudo 提权和服务商控制台（VNC）登录都要用它；SSH 之后不再接受密码。"
    passwd -- "$name" || true
  done
  [[ "$(console_password_state "$name")" == P ]] || { warn "$name 没有可用的密码，sudo 无法使用。"; return 1; }
}

# Without any password login on the console, a lost SSH key locks the owner
# out for good. Offers to set one; otherwise needs an explicit NOCONSOLE.
ssh_console_guard() {
  local user="$1" target state
  for target in "$user" root; do
    state="$(console_password_state "$target")"
    if [[ "$state" == P ]]; then ok "服务商控制台（VNC）可以用 $target 的密码登录。"; return 0; fi
  done
  warn "$user 和 root 都没有可用的登录密码：关闭 SSH 密码登录后，一旦密钥丢失，服务商控制台（VNC）也登不进去。"
  if confirm_yes "现在为 $user 设置一个密码（只用于控制台和 sudo，SSH 不接受）吗？"; then
    passwd -- "$user" || true
    [[ "$(console_password_state "$user")" == P ]] && { ok '密码已设置。'; return 0; }
  fi
  confirm '没有可用的控制台密码，仍要关闭 SSH 密码登录吗？' NOCONSOLE
}

# Some provider images ship "PubkeyAuthentication no". A drop-in that sshd
# reads before the main file turns key login on; password login is untouched,
# so this step cannot lock anyone out and needs no guard timer.
ssh_enable_pubkey() {
  local user="$1" effective
  put_file "$SSH_PUBKEY_DROPIN" $'# VPS Stable Optimizer v2.6: allow SSH public key login\nPubkeyAuthentication yes' || return 1
  sshd_runtime_dir
  if ! sshd -t; then
    rm -f -- "$SSH_PUBKEY_DROPIN"; warn 'sshd -t 不接受开启公钥登录的配置，已删除。'; return 1
  fi
  effective="$(ssh_effective "$user")" || effective=''
  if [[ "$(ssh_effective_value "$effective" pubkeyauthentication)" != yes ]]; then
    rm -f -- "$SSH_PUBKEY_DROPIN"
    warn '开启公钥登录的设置被更早读取的配置覆盖，没有生效，已撤销（请检查 /etc/ssh/sshd_config 开头是否有 Include /etc/ssh/sshd_config.d/*.conf）。'
    return 1
  fi
  if ! ssh_reload; then warn 'sshd 重新加载失败；公钥登录还没有生效。'; return 1; fi
  ok "已开启 SSH 公钥登录：$SSH_PUBKEY_DROPIN（密码登录照常可用）。"
}

ssh_harden_stage() {
  step 13 'SSH 登录加固（可选）'
  local user answer='' home effective auth_file count key since unit deadline want_admin=0 tries detail
  local -a overridden=()
  if [[ -z "${SSH_CHOICE:-}" ]]; then
    if [[ "$MODE" == ssh ]] || confirm_yes '加固 SSH 登录（只允许密钥登录，可选新建管理员并禁止 root 直接登录）吗？（推荐）'; then SSH_CHOICE=1; else SSH_CHOICE=0; fi
  fi
  if [[ "$SSH_CHOICE" != 1 ]]; then ok 'SSH 登录设置保持不变。'; module_result ssh declined 'not requested'; return 0; fi
  if ! command -v sshd >/dev/null || ! command -v ssh-keygen >/dev/null || ! command -v runuser >/dev/null; then
    warn '缺少 sshd、ssh-keygen 或 runuser，无法加固 SSH。'; module_result ssh unsupported 'OpenSSH tools missing'; return 0
  fi
  sshd_runtime_dir
  sshd -t || { warn 'sshd -t 检查失败：请先修好 SSH 配置。'; module_result ssh skipped 'sshd -t failed'; return 0; }
  command -v systemd-run >/dev/null || { warn '缺少 systemd-run，无法提供防失联保护。'; module_result ssh unsupported 'systemd-run missing'; return 0; }
  if guard_leftovers; then module_result ssh skipped 'earlier protection timer pending'; return 0; fi
  user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != root ]] || user="$(logname 2>/dev/null || id -un)"
  if [[ "$user" == root ]]; then
    if [[ -z "${ADMIN_CHOICE:-}" ]]; then
      if confirm_yes '新建一个普通管理员账户（带 sudo），以后用它登录，并禁止 root 直接 SSH 登录吗？（推荐）'; then ADMIN_CHOICE=1; else ADMIN_CHOICE=0; fi
    fi
    if [[ "$ADMIN_CHOICE" == 1 ]]; then
      for ((tries = 0; tries < 3; tries++)); do
        if [[ -n "${ADMIN_NAME:-}" ]] && admin_name_valid "$ADMIN_NAME"; then break; fi
        read -r -p '管理员账户名（小写字母开头，例如 ops）: ' ADMIN_NAME || ADMIN_NAME=''
      done
      if ! admin_name_valid "${ADMIN_NAME:-}" || ! admin_prepare "$ADMIN_NAME"; then
        warn '管理员账户没有准备好；SSH 设置保持不变。'; module_result ssh failed 'admin account not ready'; return 0
      fi
      user="$ADMIN_NAME"; want_admin=1
    fi
  else
    # Already working through a sudo account: root SSH login can be turned off too.
    if [[ -z "${ADMIN_CHOICE:-}" ]]; then
      if confirm_yes "同时禁止 root 直接 SSH 登录吗？以后用 $user 登录再 sudo。（推荐）"; then ADMIN_CHOICE=1; else ADMIN_CHOICE=0; fi
    fi
    [[ "$ADMIN_CHOICE" != 1 ]] || want_admin=1
  fi
  if ((want_admin == 0)); then
    read -r -p "要为哪个登录账户配置密钥？直接回车使用 $user: " answer || true
    [[ -z "$answer" ]] || user="$answer"
  fi
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_.-]*$ ]] || ! getent passwd "$user" >/dev/null; then
    warn "账户不存在：$user"; module_result ssh failed 'unknown account'; return 0
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"
  if ! ssh_home_safe "$user" "$home"; then
    warn "$home 的归属或权限不安全（应归 $user 或 root 所有，且其他人不可写）；SSH 设置保持不变。"
    module_result ssh failed 'home directory unsafe'; return 0
  fi
  effective="$(ssh_effective "$user")" || { warn 'sshd -T -C 执行失败。'; module_result ssh failed 'sshd -T failed'; return 0; }
  if [[ "$(ssh_effective_value "$effective" passwordauthentication)" == no &&
        "$(ssh_effective_value "$effective" kbdinteractiveauthentication)" == no ]] &&
     { ((want_admin == 0)) || [[ "$(ssh_effective_value "$(ssh_effective root)" permitrootlogin)" == no ]]; }; then
    ok "$user 的 SSH 已经只允许密钥登录。"; module_result ssh present 'password login already disabled'; return 0
  fi
  if [[ "$(ssh_effective_value "$effective" pubkeyauthentication)" != yes ]]; then
    # Some provider images ship password-only SSH: show where, then offer to
    # turn key login on first (password login stays as it is).
    detail="$(ssh_effective_value "$effective" pubkeyauthentication || true)"
    warn "这台服务器关闭了 SSH 公钥登录（当前生效：PubkeyAuthentication ${detail:-未知}）。"
    detail="$(grep -RHin '^[[:space:]]*PubkeyAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -n 5 || true)"
    if [[ -n "$detail" ]]; then printf '设置它的位置：\n%s\n' "$detail"; fi
    echo '只允许密钥登录之前，要先开启公钥登录。这一步只是多一种登录方式，密码登录照常可用，不会把你锁在外面；原来的配置文件不改。'
    if ! confirm_default_yes '现在开启 SSH 公钥登录吗？'; then
      ok '保持原来的设置，SSH 加固没有继续。'; module_result ssh declined 'pubkey auth left disabled'; return 0
    fi
    if ! ssh_enable_pubkey "$user"; then module_result ssh failed 'could not enable pubkey auth'; return 0; fi
    effective="$(ssh_effective "$user")" || { warn 'sshd -T -C 执行失败。'; module_result ssh failed 'sshd -T failed'; return 0; }
  fi
  if [[ "$(ssh_effective_value "$effective" authenticationmethods)" != any ]]; then
    warn '检测到自定义的 AuthenticationMethods（例如两步验证）；请人工配置 SSH。'; module_result ssh preserved 'custom AuthenticationMethods'; return 0
  fi
  case "$(ssh_effective_value "$effective" authorizedkeysfile)" in
    '.ssh/authorized_keys'*|'%h/.ssh/authorized_keys'*) auth_file="$home/.ssh/authorized_keys" ;;
    *) warn '检测到自定义的 AuthorizedKeysFile；请人工导入公钥。'; module_result ssh preserved 'custom AuthorizedKeysFile'; return 0 ;;
  esac
  count="$(ssh_key_count "$auth_file")"
  printf '%s 当前已有 %s 个公钥。\n' "$user" "$count"
  if ((count == 0)) || confirm_yes '要再添加一个公钥吗？'; then
    echo '还没有密钥？在你自己的电脑上运行 ssh-keygen -t ed25519（Windows 10/11 的 PowerShell、macOS、Linux 都自带），'
    echo '然后打开生成的 .pub 文件（默认在用户目录的 .ssh 文件夹里），复制整行内容粘贴到这里。私钥不要发给任何人。'
    # A long key pasted incompletely is common: ask again instead of ending
    # the whole hardening, and an empty answer skips adding a key.
    local tries
    for tries in 1 2 3; do
      read -r -p '公钥（直接回车跳过）: ' key || key=''
      if [[ -z "$key" ]] || ssh_pubkey_valid "$key"; then break; fi
      warn '这不是有效的 OpenSSH 公钥：要粘贴 .pub 文件里以 ssh-ed25519、ssh-rsa 等开头的一整行。'
      key=''
    done
    if [[ -n "$key" ]]; then
      backup_config_path "$auth_file" || die "无法备份 $auth_file"
      if ! ssh_append_key "$user" "$home" "$key"; then
        warn "写入 $auth_file 失败（可能是符号链接或权限问题）；SSH 设置保持不变。"; module_result ssh failed 'key import failed'; return 0
      fi
      record_config_change "$auth_file" key-appended || die '无法记录公钥变更。'
      ok "公钥已就绪：$auth_file（回退时也会保留）"
    elif ((count == 0)); then
      # Nothing changed: not a failure, just no key to log in with.
      ok '没有添加公钥；没有公钥就不能只用密钥登录，SSH 设置保持不变。'
      module_result ssh declined 'no public key given'; return 0
    else
      ok "不添加新的公钥，继续使用已有的 $count 个。"
    fi
  fi
  since="$(date +%s)"
  echo "请保持当前窗口不要关闭，新开一个终端，用密钥登录：ssh $user@服务器IP"
  if ((want_admin)); then echo "登录后在新窗口里运行一次：sudo true（输入 $user 的密码），确认 sudo 可用。"; fi
  read -r -p '完成后回到这里按回车继续: ' answer || true
  if ssh_login_seen "$since" "$user" publickey; then
    ok "系统日志确认 $user 已用密钥登录成功。"
  elif ! confirm_yes "系统日志里没有找到 $user 的密钥登录记录。你确定已经用密钥登录成功了吗？"; then
    ok '保留密码登录；SSH 设置没有改动。'; module_result ssh declined 'key login not confirmed'; return 0
  fi
  if ((want_admin)); then
    if ssh_sudo_seen "$user" "$since"; then
      ok "系统日志确认 $user 可以使用 sudo。"
    elif ! confirm_yes "系统日志里没有找到 $user 执行 sudo 的记录。你确定 sudo 可用吗？"; then
      warn '没有确认 sudo 可用：这次不禁止 root 直接登录，只关闭密码登录。'
      want_admin=0
    fi
  fi
  ssh_console_guard "$user" || { ok '保留密码登录；SSH 设置没有改动。'; module_result ssh declined 'no console password'; return 0; }
  put_file "$SSH_DROPIN" "$(ssh_dropin_text "$want_admin")" || { module_result ssh preserved 'drop-in path conflict'; return 0; }
  sshd_runtime_dir
  if ! sshd -t; then
    rm -f -- "$SSH_DROPIN"; warn 'sshd -t 不接受新配置，已删除。'; module_result ssh failed 'sshd -t failed'; return 0
  fi
  effective="$(ssh_effective "$user")" || effective=''
  [[ "$(ssh_effective_value "$effective" passwordauthentication)" == no ]] || overridden+=(PasswordAuthentication)
  [[ "$(ssh_effective_value "$effective" kbdinteractiveauthentication)" == no ]] || overridden+=(KbdInteractiveAuthentication)
  if ((want_admin)) && [[ "$(ssh_effective_value "$(ssh_effective root)" permitrootlogin)" != no ]]; then overridden+=(PermitRootLogin); fi
  if ((${#overridden[@]})); then
    rm -f -- "$SSH_DROPIN"
    warn "这些设置被更早的配置覆盖，没有生效：${overridden[*]}（检查 /etc/ssh/sshd_config 和编号更小的 sshd_config.d 文件）。已撤销。"
    module_result ssh preserved 'earlier sshd setting wins'; return 0
  fi
  unit="vps-stable-ssh-revert-$(date +%s)-$$"
  guard_arm "$unit" /bin/sh -c "rm -f -- '$SSH_DROPIN'; systemctl try-reload-or-restart ssh.service" || {
    rm -f -- "$SSH_DROPIN"; warn '无法启用 SSH 自动撤销计时器；没有做任何修改。'; module_result ssh failed 'guard not armed'; return 0
  }
  deadline=$((SECONDS + 180))
  if ! ssh_reload; then warn 'sshd 重新加载失败；自动撤销计时器保持启用。'; module_result ssh failed 'sshd reload failed'; return 0; fi
  # Only a key login after the reload proves the new settings work.
  since="$(guard_since)"
  echo '已关闭 SSH 密码登录。请保留这个窗口不要关，再新开一个终端，用密钥登录一次：'
  echo "  ssh $user@服务器IP"
  if ((want_admin)); then echo '现在 root 直接登录应该被拒绝，这是正常的。'; fi
  echo "用密钥登录成功后，这里通常几秒内就会自动确认，新窗口里什么都不用输入。"
  echo '如果没有自动确认，就回到这个窗口输入 CONNECTED；180 秒内没有确认，会自动恢复原来的设置。'
  if guard_confirm "$unit" "$deadline" ssh_login_seen "$since" "$user" publickey; then
    if [[ -f "$SSH_DROPIN" ]]; then
      detail="key-only user=$user"
      if ((want_admin)); then detail+=' root-ssh=off'; fi
      ok '新的 SSH 登录设置已保留，自动撤销计时器已取消。'
      module_result ssh applied "$detail"
      return 0
    fi
    warn '已收到确认，但新的 SSH 配置文件已经不在了（可能已被自动撤销）。'
  fi
  warn '这次没有确认成功：正在恢复原来的 SSH 设置；可以稍后重试。'
  rm -f -- "$SSH_DROPIN"
  # The guard reloads sshd again when it fires: keep it unless this reload worked.
  if ssh_reload; then systemctl stop "$unit.timer" 2>/dev/null || true
  else warn 'sshd 重新加载失败：自动撤销计时器保留，到期时会再重新加载一次。'; fi
  module_result ssh failed 'second login not confirmed; reverted'
}

# Changing the SSH port: the firewall lets the new port in first, then sshd
# listens on both, under a timer that puts the old setting back. Only after a
# new login on the new port is the old one closed (sshd, this tool's firewall
# rules, Fail2ban). A port set anywhere else is not touched.
ssh_port_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.8: SSH port'
  printf 'Port %s\n' "$@"
}

# Where a port is set apart from this tool's file (sshd_config, another
# drop-in, an override of ssh.socket); nothing when nowhere.
ssh_port_elsewhere() {
  local found
  found="$(grep -REin --exclude="${SSH_PORT_DROPIN##*/}" '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | head -n 1 || true)"
  [[ -n "$found" ]] || found="$(grep -Rls '^[[:space:]]*ListenStream' /etc/systemd/system/ssh.socket.d 2>/dev/null | head -n 1 || true)"
  printf '%s' "$found"
}

# The ports in force: where systemd listens for sshd (ssh.socket, Ubuntu 24.04
# and later) it makes the socket from sshd's configuration at daemon-reload.
ssh_port_reload() {
  if systemctl is-active -q ssh.socket 2>/dev/null; then systemctl daemon-reload && systemctl restart ssh.socket
  else ssh_reload; fi
}

# PORT: a connection to sshd on it now (a new window logged in there).
ssh_port_established() {
  [[ -n "$(ss -Htn state established "( sport = :$1 )" 2>/dev/null)" ]]
}

# The setting before this change, back (the timer does the same if this run dies).
ssh_port_restore_previous() {
  if [[ -s "$STATE_ROOT/sshport-previous" ]]; then cp -f -- "$STATE_ROOT/sshport-previous" "$SSH_PORT_DROPIN"
  else rm -f -- "$SSH_PORT_DROPIN"; fi
  chmod 644 -- "$SSH_PORT_DROPIN" 2>/dev/null || true
}

# Fail2ban watches the ports sshd listens on now (its own jail only).
ssh_port_follow() {
  [[ -f "$F2B_FILE" ]] && grep -Fq vps-stable-ufw-sshd "$F2B_FILE" && active fail2ban || return 0
  FIREWALL_READY=1 F2B_IGNORE_CHOICE=none fail2ban_stage > /dev/null || true
  if ssh_detect; then ok "Fail2ban 改为盯 SSH 端口 $(IFS=,; echo "${SSH_PORTS[*]}")。"; fi
}

# PORT: this tool's firewall rules for PORT go (rules someone else added stay).
ssh_port_fw_close() {
  local port="$1" rule record="$RESTORE_ROOT/fw_rules" temp left=1
  local -a words=()
  [[ -f "$record" && ! -L "$record" ]] || return 1
  while IFS= read -r rule; do
    [[ "$rule" =~ ^ufw\ (allow|limit)\ $port/tcp$ || "$rule" =~ ^ufw\ allow\ from\ [0-9A-Fa-f:.]+\ to\ any\ port\ $port\ proto\ tcp$ ]] || continue
    read -r -a words <<< "${rule#ufw }"
    if [[ "${words[1]}" == from ]]; then words=(allow proto tcp from "${words[2]}" to any port "$port"); fi
    if ufw --force delete "${words[@]}" >/dev/null 2>&1; then
      left=0
      temp="$(mktemp "$RESTORE_ROOT/.write.XXXXXX")" || continue
      { grep -vxF -- "$rule" "$record" > "$temp" || true; }
      if ! chmod 600 -- "$temp" || ! mv -fT -- "$temp" "$record"; then rm -f -- "$temp"; fi
    else warn "没能删掉防火墙规则：${rule#ufw }"; fi
  done < <(cat -- "$record")
  return "$left"
}

ssh_port_stage() {
  say '修改 SSH 端口'
  local old new verb=allow previous='' unit deadline where fw=0
  if [[ "${SSHPORT_CHOICE:-}" != 1 ]]; then module_result sshport declined 'not requested'; return 0; fi
  if ! ssh_detect || ((${#SSH_PORTS[@]} != 1)); then
    warn '没能确认 SSH 正在监听的唯一端口（没在运行，或者同时监听了几个），不改。'; module_result sshport skipped 'SSH port not clear'; return 0
  fi
  old="${SSH_PORTS[0]}"
  where="$(ssh_port_elsewhere)"
  if [[ -n "$where" ]]; then
    warn "SSH 端口在别处设置了（$(audit_clean_text <<< "$where" | cut -c1-120)）：本工具不改那里。要改的话先把那一行注释掉。"
    module_result sshport preserved 'port set elsewhere'; return 0
  fi
  if guard_leftovers; then module_result sshport skipped 'earlier protection timer pending'; return 0; fi
  echo "现在的 SSH 端口：$old。换端口挡不住真正的攻击者，但能少掉绝大多数自动扫描（日志清净，Fail2ban 也轻松）。"
  read -r -p '新的端口（1024–65535，直接回车取消）: ' new || new=''
  if [[ -z "$new" ]]; then ok '已取消。'; module_result sshport declined 'cancelled'; return 0; fi
  if [[ ! "$new" =~ ^[0-9]{4,5}$ ]] || ((10#$new < 1024 || 10#$new > 65535 || 10#$new == old)); then
    warn '端口要在 1024 到 65535 之间，而且和现在的不一样。'; module_result sshport declined 'bad port'; return 0
  fi
  new=$((10#$new))
  if [[ -n "$(ss -H -ltn "( sport = :$new )" 2>/dev/null)" ]]; then warn "端口 $new 已经有程序在用。"; module_result sshport declined 'port in use'; return 0; fi
  echo "很多服务商还有自己的安全组（云防火墙）：先在那里放行 TCP $new，不然改完从外面连不上。"
  if ! confirm_yes "服务商那边已经放行 TCP $new 了吗？"; then ok '已取消：放行以后再来。'; module_result sshport declined 'provider firewall'; return 0; fi
  if [[ -e "$SSH_PORT_DROPIN" ]] && ! restore_file_ours sshport_dropin; then
    warn "$SSH_PORT_DROPIN 不是本工具写的，保持不变。"; module_result sshport preserved 'drop-in differs'; return 0
  fi
  [[ ! -f "$SSH_PORT_DROPIN" ]] || previous="$(cat -- "$SSH_PORT_DROPIN")"
  printf '%s' "${previous:+$previous$'\n'}" > "$STATE_ROOT/sshport-previous"
  # 1. The firewall lets the new port in first, the way it lets the old one in.
  if ufw_active; then
    fw=1
    if ufw show added 2>/dev/null | grep -Fx "ufw limit $old/tcp" > /dev/null; then verb=limit; fi
    if ! ufw_rule "$verb" "$new"; then warn "防火墙没能放行 $new，什么都没改。"; module_result sshport failed 'firewall'; return 0; fi
    if [[ "$verb" == limit ]]; then ssh_limit_exempt; fi
  fi
  # The port to go back to (kept from the first change on).
  if [[ ! -s "$RESTORE_ROOT/sshport" ]]; then printf 'port=%s\nverb=%s\n' "$old" "$verb" > "$RESTORE_ROOT/sshport"; chmod 600 -- "$RESTORE_ROOT/sshport"; fi
  # 2. sshd on both ports, under a timer that puts the old setting back.
  rm -f -- "$SSH_PORT_DROPIN"
  if ! put_file "$SSH_PORT_DROPIN" "$(ssh_port_text "$old" "$new")" || ! { sshd_runtime_dir; sshd -t; }; then
    ssh_port_restore_previous; if ((fw)); then ssh_port_fw_close "$new" || true; fi
    warn 'sshd 不接受新的端口设置，已撤回。'; module_result sshport failed 'sshd -t failed'; return 0
  fi
  unit="vps-stable-ssh-revert-$(date +%s)-$$"
  if ! guard_arm "$unit" /bin/sh -c "if [ -s '$STATE_ROOT/sshport-previous' ]; then cp -f '$STATE_ROOT/sshport-previous' '$SSH_PORT_DROPIN'; else rm -f '$SSH_PORT_DROPIN'; fi; if systemctl is-active -q ssh.socket; then systemctl daemon-reload; systemctl restart ssh.socket; else systemctl try-reload-or-restart ssh.service; fi"; then
    ssh_port_restore_previous; if ((fw)); then ssh_port_fw_close "$new" || true; fi
    warn '无法启用自动撤销计时器；什么都没改。'; module_result sshport failed 'guard not armed'; return 0
  fi
  deadline=$((SECONDS + 180))
  ssh_port_reload || true
  if ! port_listening "$new" || ! port_listening "$old"; then
    ssh_port_restore_previous; ssh_port_reload || true
    if ((fw)); then ssh_port_fw_close "$new" || true; fi
    systemctl stop "$unit.timer" 2>/dev/null || true
    warn "SSH 没能同时在 $old 和 $new 上监听，已恢复原样。"; module_result sshport failed 'not listening'; return 0
  fi
  ssh_port_follow
  echo "SSH 现在同时在 $old 和 $new 上。请保留这个窗口，再新开一个终端，用新端口登录：
  ssh -p $new 账户名@服务器IP
新端口上一有登录，这里几秒内就会自动确认；没有自动确认时回到这个窗口输入 CONNECTED。180 秒内没有确认就恢复原样。"
  if guard_confirm "$unit" "$deadline" ssh_port_established "$new"; then
    # 3. Only the new port: sshd, then this tool's rules for the old one.
    rm -f -- "$SSH_PORT_DROPIN"
    if put_file "$SSH_PORT_DROPIN" "$(ssh_port_text "$new")" && sshd -t && ssh_port_reload && port_listening "$new"; then
      if ((fw)) && ! ssh_port_fw_close "$old"; then
        warn "防火墙里放行旧端口 $old 的规则不是本工具加的，保持不变：不需要的话用 vps port 或 ufw 删掉。"
      fi
      ssh_port_follow
      ok "SSH 端口已改成 $new。以后登录用 ssh -p $new；记得到服务商的安全组里把旧端口 $old 关掉。"
      module_result sshport applied "port $new"
      return 0
    fi
    warn "只留新端口时出了问题：SSH 保持同时监听 $old 和 $new，请检查后再试。"
    rm -f -- "$SSH_PORT_DROPIN"; put_file "$SSH_PORT_DROPIN" "$(ssh_port_text "$old" "$new")" || true; ssh_port_reload || true
    module_result sshport failed 'old port not closed'; return 0
  fi
  warn '这次没有确认：正在恢复原来的 SSH 端口。'
  ssh_port_restore_previous
  if ssh_port_reload; then systemctl stop "$unit.timer" 2>/dev/null || true
  else warn 'SSH 重新加载失败：自动撤销计时器保留，到期时会再试一次。'; fi
  if ((fw)); then ssh_port_fw_close "$new" || true; fi
  ssh_port_follow
  module_result sshport failed 'new port not confirmed; reverted'
}

# Rollback only widens access: the port SSH goes back to is let in first.
restore_sshport_group() {
  local port verb
  restore_needed sshport_dropin || return 0
  port="$(sed -n 's/^port=//p' "$RESTORE_ROOT/sshport" 2>/dev/null || true)" verb="$(sed -n 's/^verb=//p' "$RESTORE_ROOT/sshport" 2>/dev/null || true)"
  if [[ "$port" =~ ^[0-9]{1,5}$ ]] && ufw_active; then
    if ! ufw_rule "${verb:-allow}" "$port"; then warn "防火墙没能放行原来的 SSH 端口 $port：SSH 端口保持不变。"; RESTORE_PARTIAL=1; return 0; fi
    # The change took the old port's exemptions away with its rules.
    if [[ "$verb" == limit ]]; then ssh_limit_exempt; fi
  fi
  restore_resource sshport_dropin
  if ! ssh_port_reload; then warn 'SSH 重新加载失败：重启 SSH 后才回到原来的端口。'; RESTORE_PARTIAL=1; fi
  ssh_port_follow
  if [[ "$port" =~ ^[0-9]+$ ]]; then ok "SSH 回到端口 $port（新端口的防火墙规则在撤销防火墙时一起删掉）。"; fi
}

# Read-only preflight. A blocking finding is enforced only after APPLY.
preflight_block() {
  PREFLIGHT_BLOCKERS=$((PREFLIGHT_BLOCKERS + 1))
  warn "$*"
}

# The single reviewed release table: codename, support end (YYYYMMDD), label.
# Update it here when a release gains or loses support (reviewed 2026-10-25).
release_info() {
  case "$OS:$OS_VERSION" in
    debian:12) printf '%s\t%s\t%s\n' bookworm 20280630 'Debian 12 LTS' ;;
    debian:13) printf '%s\t%s\t%s\n' trixie 20300630 'Debian 13 including LTS' ;;
    ubuntu:22.04) printf '%s\t%s\t%s\n' jammy 20270531 'Ubuntu 22.04 standard maintenance' ;;
    ubuntu:24.04) printf '%s\t%s\t%s\n' noble 20290531 'Ubuntu 24.04 standard maintenance' ;;
    ubuntu:26.04) printf '%s\t%s\t%s\n' resolute 20310531 'Ubuntu 26.04 standard maintenance' ;;
    *) return 1 ;;
  esac
}

# Days since 1970-01-01 for YYYYMMDD, in pure Bash (civil-from-days inverse).
ymd_days() {
  local y=$((10#${1:0:4})) m=$((10#${1:4:2})) d=$((10#${1:6:2})) era yoe doy
  if ((m <= 2)); then y=$((y - 1)); fi
  era=$((y / 400))
  yoe=$((y - era * 400))
  if ((m > 2)); then doy=$(((153 * (m - 3) + 2) / 5 + d - 1)); else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
  echo $((era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468))
}

support_lifecycle_report() {
  local today info end label left
  today="$(date -u +%Y%m%d)"
  if ! info="$(release_info)"; then preflight_block '这个系统版本不在支持列表里。'; return 0; fi
  IFS=$'\t' read -r _ end label <<< "$info"
  printf '维护期参考（2026-10-25 核对）：%s，截止 %s。\n' "$label" "$end"
  echo '这是按系统版本整理的维护期参考，不代表每个软件包都在维护范围内。'
  if [[ ! "$today" =~ ^[0-9]{8}$ ]]; then
    preflight_block '系统日期明显不对，请先校准时间。'
  elif ((10#$today < 20200101)); then
    preflight_block '系统日期明显不对，请先校准时间。'
  elif ((10#$today > 10#$end)); then
    preflight_block '这个系统版本的官方维护期已经结束，请升级到新的大版本后再使用。'
  else
    left=$(($(ymd_days "$end") - $(ymd_days "$today")))
    if ((left <= 180)); then warn "该系统版本的官方维护期还剩约 ${left} 天，请尽早规划升级到新的大版本。"; fi
  fi
}

# Emit only sanitized host, suite, and policy flags; never echo repository URLs.
# Handles the standard one-line and deb822 forms. It is an audit parser, not APT.
apt_source_records() {
  local file="$1" style="$2"
  awk -v style="$style" '
    function emit(uri, suite, insecure, replay, host) {
      host=uri
      # Debian cloud images: the mirrors are listed in a local file.
      if (uri ~ /^mirror\+file:\/\/\/etc\/apt\/mirrors\/[A-Za-z0-9._-]+$/) host="mirror-file:" substr(uri,15)
      else if (host !~ /^https?:\/\//) host="[non-http-source]"
      else {
        sub(/^https?:\/\//,"",host); sub(/[\/?#].*$/,"",host)
        sub(/^.*@/,"",host)
        if (host ~ /^\[/) {sub(/^\[/,"",host); sub(/\].*$/,"",host)}
        else sub(/:[0-9]+$/,"",host)
        host=tolower(host)
        if (host !~ /^[a-z0-9.:-]+$/) host="[unrecognized-host]"
      }
      if (suite !~ /^[A-Za-z0-9_.\/-]+$/) suite="[custom-suite]"
      print host "\t" suite "\t" insecure "\t" replay
    }
    function flush(    a,b,n,m,i,j,trust,replay) {
      if (enabled~/^(no|false|0)$/ || types !~ /(^|[ \t])deb([ \t]|$)/) return
      trust=(tolower(trusted)~/^(yes|true|1)$/ || tolower(allowinsecure)~/^(yes|true|1)$/ || tolower(allowweak)~/^(yes|true|1)$/ || tolower(allowdowngrade)~/^(yes|true|1)$/) ? 1 : 0
      replay=(tolower(validuntil)~/^(no|false|0)$/ || tolower(checkdate)~/^(no|false|0)$/) ? 1 : 0
      n=split(uris,a,/[ \t]+/); m=split(suites,b,/[ \t]+/)
      for(i=1;i<=n;i++) for(j=1;j<=m;j++) if(a[i]!="" && b[j]!="") emit(a[i],b[j],trust,replay)
    }
    function reset() {types=""; uris=""; suites=""; enabled=""; trusted=""; allowinsecure=""; allowweak=""; allowdowngrade=""; validuntil=""; checkdate=""; field=""}
    BEGIN {reset()}
    style=="list" {
      line=$0; sub(/#.*/,"",line); sub(/^[ \t]+/,"",line)
      if(line !~ /^deb[ \t]+/) next
      sub(/^deb[ \t]+/,"",line); options=""
      if(line ~ /^\[/) {
        if(!match(line,/\]/)) next
        closing=RSTART
        options=tolower(substr(line,1,closing)); line=substr(line,closing+1)
      }
      sub(/^[ \t]+/,"",line); n=split(line,a,/[ \t]+/)
      if(n>=2) emit(a[1],a[2],options ~ /(trusted|allow-insecure|allow-weak|allow-downgrade-to-insecure)=(yes|true|1)/ ? 1 : 0,options ~ /(check-valid-until|check-date)=(no|false|0)/ ? 1 : 0)
      next
    }
    style=="sources" {
      if($0 ~ /^[ \t]*#/) next
      if($0 ~ /^[ \t]*$/) {flush(); reset(); next}
      if($0 ~ /^[ \t]+/) value=$0
      else {
        colon=index($0,":"); if(!colon) {field=""; next}
        field=tolower(substr($0,1,colon-1)); value=substr($0,colon+1)
      }
      sub(/^[ \t]+/,"",value); sub(/[ \t]+$/,"",value)
      if(field=="types") types=types " " value
      else if(field=="uris") uris=uris " " value
      else if(field=="suites") suites=suites " " value
      else if(field=="enabled") enabled=tolower(value)
      else if(field=="trusted") trusted=value
      else if(field=="allow-insecure") allowinsecure=value
      else if(field=="allow-weak") allowweak=value
      else if(field=="allow-downgrade-to-insecure") allowdowngrade=value
      else if(field=="check-valid-until") validuntil=value
      else if(field=="check-date") checkdate=value
    }
    END {if(style=="sources") flush()}
  ' "$file"
}

# Hosts of the mirrors in an APT mirror list (the file behind a mirror+file source).
apt_mirror_list_hosts() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 1
  awk '
    {line=$0; sub(/#.*/,"",line); sub(/^[ \t]+/,"",line)}
    line == "" {next}
    {
      split(line,a,/[ \t]+/); host=a[1]
      if (host !~ /^https?:\/\//) {print "[non-http-source]"; next}
      sub(/^https?:\/\//,"",host); sub(/[\/?#].*$/,"",host); sub(/^.*@/,"",host)
      if (host ~ /^\[/) {sub(/^\[/,"",host); sub(/\].*$/,"",host)}
      else sub(/:[0-9]+$/,"",host)
      host=tolower(host)
      if (host !~ /^[a-z0-9.:-]+$/) host="[unrecognized-host]"
      print host
    }' "$file"
}

apt_host_official() {
  case "$OS:$1" in
    debian:debian.org|debian:*.debian.org|ubuntu:archive.ubuntu.com|ubuntu:*.archive.ubuntu.com|ubuntu:security.ubuntu.com|ubuntu:ports.ubuntu.com) return 0 ;;
  esac
  return 1
}

apt_sources_report() {
  local f records host suite insecure replay base security expected official known=0 found_security=0
  local mirrors mirror target
  local config config_path config_value hosts='' resolve_count=0 info
  if ! info="$(release_info)"; then preflight_block '无法确定本系统应使用的软件源版本代号。'; return 0; fi
  base="${info%%$'\t'*}"
  security="$base-security"
  if ! config="$(apt-config dump 2>/dev/null)"; then
    preflight_block '无法读取 APT 配置。'; return 0
  fi
  # APT supports custom source locations. Do not claim default-path coverage
  # when those are redirected. Values are inspected but are never printed.
  while IFS=$'\t' read -r config_path config_value; do
    case "$config_path:$config_value" in
      'Dir:/'|'RootDir:'|'Dir::Etc:etc/apt'|'Dir::Etc:etc/apt/'|'Dir::Etc:/etc/apt'|'Dir::Etc:/etc/apt/'|\
      'Dir::Etc::sourcelist:sources.list'|'Dir::Etc::sourcelist:/etc/apt/sources.list'|\
      'Dir::Etc::sourceparts:sources.list.d'|'Dir::Etc::sourceparts:/etc/apt/sources.list.d'|'Dir::Etc::sourceparts:/etc/apt/sources.list.d/') ;;
      *) preflight_block '软件源放在自定义位置，本工具无法检查，请人工核对。' ;;
    esac
  done < <(awk '$1=="Dir" || $1=="RootDir" || $1=="Dir::Etc" || $1=="Dir::Etc::sourcelist" || $1=="Dir::Etc::sourceparts" {v=$2; sub(/^\"/,"",v); sub(/\";$/,"",v); print $1 "\t" v}' <<< "$config")
  if grep -Ei '^(Acquire::Allow(InsecureRepositories|WeakRepositories|DowngradeToInsecureRepositories)|APT::Get::AllowUnauthenticated)[[:space:]]+"(true|1|yes)"' <<< "$config" >/dev/null; then
    preflight_block 'APT 全局允许不安全或未签名的软件源，请先人工检查。'
  fi
  if grep -Ei '^Acquire::Check-(Valid-Until|Date)[[:space:]]+"(false|0|no)"' <<< "$config" >/dev/null; then
    SOURCE_REVIEW_REQUIRED=1
    warn 'APT 全局关闭了软件源的过期检查，需要人工核对软件源。'
  fi
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    case "${f##*/}" in *[!A-Za-z0-9_.-]*) continue ;; esac
    if [[ ! -r "$f" ]]; then preflight_block "无法读取软件源文件：$f"; continue; fi
    case "$f" in *.sources) expected=sources ;; *) expected=list ;; esac
    if ! records="$(apt_source_records "$f" "$expected")"; then preflight_block "无法解析软件源文件：$f"; continue; fi
    [[ -n "$records" ]] || continue
    printf '软件源文件：%s\n' "$f"
    while IFS=$'\t' read -r host suite insecure replay; do
      [[ -n "$host" ]] || continue
      known=$((known+1)); official=0; target="$host"
      if [[ "$host" == mirror-file:* ]]; then
        # Official only when every mirror in the list is official.
        mirrors="$(apt_mirror_list_hosts "${host#mirror-file:}" || true)"
        if [[ -n "$mirrors" ]]; then
          official=1
          while IFS= read -r mirror; do apt_host_official "$mirror" || official=0; done <<< "$mirrors"
        fi
        target="${mirrors%%$'\n'*}"
      elif apt_host_official "$host"; then
        official=1
      fi
      printf '  host=%s suite=%s\n' "$host" "$suite"
      if [[ "$host" == mirror-file:* ]]; then printf '    镜像列表中的地址：%s\n' "$(tr '\n' ' ' <<< "${mirrors:-（读不到）}")"; fi
      if [[ "$insecure" == 1 ]]; then preflight_block '有软件源关闭了签名校验（trusted 或 allow-insecure）。'; fi
      if [[ "$replay" == 1 ]]; then SOURCE_REVIEW_REQUIRED=1; warn '有软件源关闭了过期检查，需要人工核对。'; fi
      if ((official)); then
        case "$suite" in "$base"|"$base-updates"|"$security"|"$base-backports") ;;
          stable|stable-*|oldstable|oldstable-*|oldoldstable|oldoldstable-*|testing|testing-*|unstable|sid|experimental)
            preflight_block "软件源使用了别名 $suite：它会随 Debian 新版本发布自动指向新的大版本，升级时可能把系统混成两个版本。请在 $f 中把 $suite 改成 ${base}（例如 stable-updates 改成 ${base}-updates），然后重新体检。" ;;
          *) preflight_block "官方软件源的版本 $suite 与本系统（$base）不一致。" ;;
        esac
      else
        SOURCE_REVIEW_REQUIRED=1
        warn '有镜像源或第三方源，无法自动判断：请确认来源可靠、签名密钥正确、版本代号一致。'
      fi
      [[ "$suite" != "$security" ]] || found_security=1
      case "$target" in *'['*|*']'*|'') continue ;; esac
      if [[ " $hosts " != *" $target "* ]] && ((resolve_count<3)); then
        hosts+=" $target"; resolve_count=$((resolve_count+1))
        if command -v timeout >/dev/null && command -v getent >/dev/null; then
          if ! timeout 8s getent ahosts "$target" >/dev/null 2>&1; then
            preflight_block "软件源域名无法解析或超时：$target"
          fi
        else warn '缺少 getent 或 timeout，没有检查软件源域名能否解析。'; fi
      fi
    done <<< "$records"
  done
  ((known>0)) || preflight_block '没有找到可用的软件源。'
  if (( !found_security )); then
    SOURCE_REVIEW_REQUIRED=1
    warn "没有找到 $security 安全更新源，请确认安全更新从哪里获取。"
  fi
  echo '这里只是初步检查，软件源是否可信仍以 APT 更新时的签名校验为准。'
}

preflight_report() {
  say '执行前体检（只读）'
  PREFLIGHT_BLOCKERS=0
  SOURCE_REVIEW_REQUIRED=0
  local path target free_mb total_inodes free_inodes percent options audit locks
  support_lifecycle_report
  for path in / /var /boot; do
    [[ -d "$path" ]] || continue
    target="$(findmnt -n -o TARGET --target "$path" 2>/dev/null || true)"
    if [[ "$path" == /boot && "$target" != /boot ]]; then continue; fi
    free_mb="$(df -Pm -- "$path" | awk 'NR==2 {print $4}')"
    if [[ ! "$free_mb" =~ ^[0-9]+$ ]]; then preflight_block "无法确定 $path 的剩余空间。"
    elif [[ "$path" == /boot ]]; then
      ((free_mb>=100)) || preflight_block '/boot 剩余空间不足 100MiB，请先清理旧内核。'
    else
      ((free_mb>=650)) || preflight_block "$path 剩余空间不足 650MiB。"
    fi
    total_inodes='' free_inodes='' percent=''
    read -r total_inodes free_inodes percent < <(df -Pi -- "$path" | awk 'NR==2 {print $2, $4, $5}') || true
    # btrfs and other dynamic-inode filesystems report 0 inodes: no inode limit.
    if [[ "$total_inodes" == 0 ]]; then
      free_inodes='不限（动态分配）'
    elif [[ "$free_inodes" =~ ^[0-9]+$ ]]; then
      ((free_inodes>=1000)) || preflight_block "$path 剩余 inode 不足 1000 个。"
    else warn "无法确定 $path 的 inode 剩余量。"; fi
    printf '%s：剩余 %s MiB，剩余 inode %s，inode 使用率 %s\n' "$path" "$free_mb" "$free_inodes" "$percent"
    options="$(findmnt -n -o OPTIONS --target "$path" 2>/dev/null || true)"
    if [[ ",$options," != *,rw,* ]]; then preflight_block "$path 是只读的，或无法读取挂载选项。"; fi
  done
  if ! audit="$(dpkg --audit 2>/dev/null)"; then
    preflight_block 'dpkg 检查失败，请人工检查软件包状态。'
  elif [[ -n "$audit" ]]; then
    preflight_block '软件包处于安装中断或损坏状态（常见于升级时断线）。请先运行 dpkg --configure -a 修复，再用 dpkg --audit 确认没有输出；本工具不会自动修复。'
  else ok '软件包状态正常。'; fi
  if command -v lslocks >/dev/null; then
    if locks="$(lslocks --noheadings --raw --output PATH 2>/dev/null)"; then
      if apt_lock_listed <<< "$locks"; then
        warn '有其他程序正在安装或更新软件（常见于开机后的自动更新）：开始修改时会先等它结束（最多 10 分钟）；不要删除锁文件或强行结束它。'
      fi
    else warn '无法检查软件包锁，以 APT 自身的锁为准。'; fi
  else warn '缺少 lslocks，没有检查软件包锁。'; fi
  apt_sources_report
  printf '阻断项：%s 个\n' "$PREFLIGHT_BLOCKERS"
  echo '空间检查只是初步判断，不保证所有升级都放得下。'
  PREFLIGHT_DONE=1
}

# The plan shown right before APPLY already ran this process's preflight, so
# its findings are enforced as-is instead of repeating every probe and DNS query.
preflight_gate() {
  ((${PREFLIGHT_DONE:-0})) || preflight_report
  ((PREFLIGHT_BLOCKERS == 0)) || die '执行前体检有阻断项；请处理后重新运行。尚未进入优化阶段。'
  if ((SOURCE_REVIEW_REQUIRED)); then
    confirm_yes '有需要人工核对的软件源：已确认来源可靠、签名和版本代号都正确，继续吗？' || die '软件源未确认，停止；尚未进入优化阶段。'
  fi
}

restart_report() {
  echo '-- 更新后的服务/内核检查 --'
  printf '正在运行的内核：%s\n' "$(uname -r)"
  if [[ -e /var/run/reboot-required ]]; then
    warn '系统报告需要重启；请在维护时间重启并再次运行 check。'
  else echo '未发现 reboot-required 标记；缺少该标记不能证明无需重启。'; fi
  if command -v needrestart >/dev/null && command -v timeout >/dev/null && ((EUID==0)); then
    local status
    if status="$(timeout 30s needrestart -b -r l 2>&1)"; then
      printf '%s\n' "$status" | sed -n '1,80p'
    else warn 'needrestart 检查失败/超时，服务与内核更新状态未验证。'; fi
  else echo 'needrestart 未安装或权限不足：请人工确认需要重启的服务，未自动安装检查工具。'; fi
  echo '本项只列出状态，不重启服务或整机；现有更新工具仍遵循其自身策略。'
}

# Read-only audit functions. Safe to source: no top-level commands.
# Depends on the caller's say/ok/warn functions; warn may increment WARNINGS.
# Never source configuration files, inspect shadow/private keys, or change services.

audit_clean_text() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

audit_bounded_lines() {
  local limit="${1:-40}"
  audit_clean_text | awk -v limit="$limit" '
    NR<=limit {print substr($0,1,300)}
    END {if(NR>limit) printf "[仅显示前 %d 行，其余已省略]\n",limit}'
}

# Only this explicit whitelist may leave sshd -T output.
audit_sshd_values() {
  awk '
    BEGIN {
      n=split("passwordauthentication kbdinteractiveauthentication permitemptypasswords permitrootlogin pubkeyauthentication maxauthtries",keys," ")
      for(i=1;i<=n;i++) wanted[keys[i]]=1
    }
    wanted[tolower($1)] {values[tolower($1)]=$2}
    END {
      for(i=1;i<=n;i++) printf "%s=%s\n",keys[i],(keys[i] in values ? values[keys[i]] : "UNKNOWN")
    }'
}

audit_uid0_names() {
  awk -F: '$3=="0" && $1!="" {print $1}'
}

audit_passwd_state() {
  awk 'NR==1 && NF>=2 && $2~/^(L|P|NP)$/ {print $2; found=1} END {exit !found}'
}

# Input is ss -H -lntup, which includes Netid as its first column.
# A non-loopback binding is a candidate only: routes and firewalls affect reachability.
audit_listener_rows() {
  awk '
    NF>=6 {
      addr=$5
      scope="非回环绑定"
      if(addr~/^127\./ || addr~/^\[::1\]:/ || addr~/^::1:/ || addr~/^localhost:/) scope="回环绑定"
      printf "[%s] %s\n",scope,substr($0,1,260)
    }'
}

# Parse a simple, unique assignment without executing /etc/default/ufw.
# Complex shell expressions or duplicate assignments are deliberately UNKNOWN.
audit_ufw_ipv6() {
  awk '
    /^[[:space:]]*IPV6[[:space:]]*=/ {
      count++; value=$0
      sub(/^[^=]*=[[:space:]]*/,"",value)
      sub(/[[:space:]]+#.*$/,"",value)
      sub(/[[:space:]]+$/,"",value)
      if(value=="yes" || value=="\"yes\"" || value=="\047yes\047") result="yes"
      else if(value=="no" || value=="\"no\"" || value=="\047no\047") result="no"
      else result="UNKNOWN"
    }
    END {if(count==1) print result; else print "UNKNOWN"}'
}

audit_mem_values() {
  awk '
    BEGIN {n=split("MemTotal MemAvailable SwapTotal SwapFree",keys," ")}
    $1~/^(MemTotal|MemAvailable|SwapTotal|SwapFree):$/ && $2~/^[0-9]+$/ && $3=="kB" {
      key=$1; sub(/:$/,"",key); values[key]=$2
    }
    END {
      for(i=1;i<=n;i++) printf "%s=%s\n",keys[i],(keys[i] in values ? values[keys[i]] : "UNKNOWN")
    }'
}

# Input is POSIX df -Pk / -Pi output. Messages contain no file contents.
audit_disk_risks() {
  awk -v kind="${1:-磁盘}" '
    NR>1 && $5=="-" && $2=="0" {seen++; next}
    NR>1 && $5~/^[0-9]+%$/ {
      seen++; used=$5; sub(/%$/,"",used)
      if(used>=90) printf "%s: %s 已用 %s（达到 90%% 提醒线）\n",kind,$6,$5
    }
    END {if(!seen) printf "%s使用率无法解析，状态未知。\n",kind}'
}

# Only counters leave this parser. Raw journal messages are never printed.
# n=1000 limits records upstream; cap scanned lines and per-line text as well.
# Not counted: the kernel command line (its parameters, such as
# nvme_core.io_timeout, read like errors) and reads from an empty floppy or
# CD drive (fd0, sr0), which KVM machines often have and which always fail.
# Access hints are journalctl's own wording; services log "Failed to open
# ..." too (systemd-networkd does at every boot on Ubuntu 26.04).
audit_journal_counts() {
  awk '
    NR>3000 {limited=1; next}
    {
      line=tolower(substr($0,1,1024)); scanned++
      if(line~/^(kernel )?command line:/) next
      if(line~/^hint:|^no journal files|^-- no entries --$|^failed to open (journal|files)|^you are currently not seeing|^insufficient permissions|^no entries were found/) access_issue++
      if(line~/out of memory:|oom-kill:|oom_reaper:|memory cgroup out of memory|killed process [0-9]+|invoked oom-killer/) oom++
      if(line~/dev (fd|sr)[0-9]/) next
      if(line~/i\/o error|buffer i\/o|blk_update_request:.*error|blk_print_req_error:|ext4-fs error|xfs.*(corrupt|i\/o error)|btrfs.*(error|corrupt)|nvme[0-9].*(i\/o|timeout)/) io++
      if(line~/kernel panic|not syncing:|watchdog.*(lockup|locked up)|soft lockup|hard lockup|unclean shutdown|uncleanly shut down|not cleanly shut down/) crash++
    }
    END {printf "%d %d %d %d %d %d\n",scanned,oom,io,crash,access_issue,limited}'
}

audit_accounts() {
  local users='' user current='' state='' raw='' seen_root=0
  local account_names=(root)
  echo '-- 账户状态（只读） --'
  if command -v getent >/dev/null; then
    if raw="$(getent passwd 2>/dev/null)" && [[ -n "$raw" ]]; then
      users="$(audit_uid0_names <<< "$raw")"
      if [[ -n "$users" ]]; then
        printf 'UID 0 账户：\n'; audit_bounded_lines 20 <<< "$users"
        while IFS= read -r user; do
          [[ "$user" == root ]] && seen_root=1
          [[ "$user" == root ]] || warn "发现额外 UID 0 账户：$(audit_clean_text <<< "$user")；请确认其用途，不自动删除。"
        done <<< "$users"
        (( seen_root )) || warn 'UID 0 列表未出现 root；请人工确认账户配置。'
      else
        warn '账户枚举未返回 UID 0 记录，状态未知。'
      fi
    else
      warn 'getent passwd 失败或返回空结果，账户状态未知。'
    fi
  else
    warn 'getent 不可用，无法枚举 UID 0 账户。'
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
      current="$SUDO_USER"
      echo '使用 SUDO_USER 识别 SSH 管理员；经 su/多层跳转时原始登录用户需人工确认。'
    elif command -v logname >/dev/null && current="$(logname 2>/dev/null)" && [[ -n "$current" ]]; then
      echo '使用登录终端账户识别 SSH 管理员；经 su/多层跳转时需人工确认。'
    elif command -v id >/dev/null && current="$(id -un 2>/dev/null)" && [[ -n "$current" ]]; then
      warn '无法取得终端原始登录账户，仅检查当前执行用户；SSH 原始用户名需人工确认。'
    else
      warn '无法识别当前 SSH 管理员账户。'
    fi
  else
    warn '未检测到 SSH_CONNECTION；当前 SSH 登录用户名未知，仅检查 root。'
  fi
  if [[ -n "$current" && "$current" != root ]]; then account_names+=("$current"); fi
  if ! command -v passwd >/dev/null; then warn 'passwd 不可用，密码状态未知。'; return 0; fi
  for user in "${account_names[@]}"; do
    if [[ ! "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*[$]?$ ]]; then
      warn '账户名格式无法安全验证，跳过其密码状态查询。'; continue
    fi
    if raw="$(passwd -S "$user" 2>/dev/null)" && state="$(audit_passwd_state <<< "$raw")"; then
      case "$state" in
        NP) warn "$user 的 passwd 状态为 NP：没有密码，存在空密码风险；实际登录仍受 SSH/PAM 等配置影响。" ;;
        L) printf '%s: L（密码被锁定，不代表其他认证方式也被禁用）\n' "$user" ;;
        P) printf '%s: P（有可用密码；不代表强度足够，也不等于允许 SSH 密码登录）\n' "$user" ;;
      esac
    else
      warn "无法取得 $user 的 passwd -S 状态，可能权限不足；不推断密码状态。"
    fi
  done
  echo '脚本不读取密码哈希，不评估密码强度，不修改密码或登录方式。请使用独立长密码。'
}

# Lists every public key that can log in as root or a regular account, so a
# key preinstalled by an image or provider gets noticed.
audit_authorized_keys() {
  local raw name uid home file lines found=0
  echo '-- 可以登录本机的 SSH 公钥（只读） --'
  command -v ssh-keygen >/dev/null || { warn 'ssh-keygen 不可用，无法列出公钥。'; return 0; }
  raw="$(getent passwd 2>/dev/null)" || { warn '无法枚举账户，公钥情况未知。'; return 0; }
  while IFS=: read -r name _ uid _ _ home _; do
    [[ "$uid" =~ ^[0-9]+$ && "$home" == /* ]] || continue
    [[ "$name" == root ]] || { ((uid >= 1000 && uid < 60000)) || continue; }
    for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      found=1
      lines="$(ssh-keygen -l -f "$file" 2>/dev/null | audit_bounded_lines 20 || true)"
      if [[ -n "$lines" ]]; then
        printf '%s（%s）：\n' "$(audit_clean_text <<< "$name")" "$file"
        printf '%s\n' "$lines" | sed 's/^/  /'
      else
        printf '%s（%s）：没有有效公钥\n' "$(audit_clean_text <<< "$name")" "$file"
      fi
    done
  done <<< "$raw"
  if ((found)); then echo '请确认每个公钥都是你自己的；不认识的公钥可能是镜像或服务商预置的，可在对应文件里删掉那一行。'
  else echo '没有找到 authorized_keys 文件。'; fi
}

audit_network() {
  local data='' family ipv6='UNKNOWN'
  echo '-- 本机监听与网络（只读，无端口扫描） --'
  if command -v ss >/dev/null; then
    if data="$(ss -H -lntup 2>/dev/null)"; then
      if [[ -n "$data" ]]; then audit_listener_rows <<< "$data" | audit_bounded_lines 60
      else warn 'ss 未返回监听记录，仅代表当前可见网络命名空间；不能据此判定没有公网服务。'; fi
      if (( EUID != 0 )); then warn '非 root 查询可能缺少监听进程信息。'; fi
    else warn 'ss 查询失败，监听状态未知。'; fi
  else warn 'ss 不可用，监听状态未知。'; fi
  echo '非回环监听不等于公网可达；回环监听也不能排除代理转发等其他暴露方式。'
  if command -v ip >/dev/null; then
    for family in 4 6; do
      printf 'IPv%s 地址：\n' "$family"
      if ! data="$(ip -br "-$family" address show 2>/dev/null)"; then warn "IPv$family 地址查询失败，状态未知。"
      elif [[ -n "$data" ]]; then
        audit_bounded_lines 30 <<< "$data"
        # Link-local (fe80::) and ::1 alone do not reach the internet: no route to ask about.
        if [[ "$family" == 6 ]] && ! awk '{for (i = 3; i <= NF; i++) if ($i !~ /^(fe80:|::1\/)/) found = 1} END {exit !found}' <<< "$data"; then
          echo '上面只有本机或链路本地地址，没有公网 IPv6 地址（只用 IPv4）。'; continue
        fi
      # Many VPSs are IPv4-only: an empty answer is a fact, not an unknown.
      elif [[ "$family" == 6 ]]; then echo '本机没有 IPv6 地址（只用 IPv4）。'; continue
      else warn 'IPv4 查询没有返回地址，状态未知。'; fi
      printf 'IPv%s 默认路由：\n' "$family"
      if data="$(ip "-$family" route show default 2>/dev/null)"; then
        if [[ -n "$data" ]]; then audit_bounded_lines 12 <<< "$data"
        else warn "IPv$family 查询未返回默认路由；不能据此确认连通性。"; fi
      else warn "IPv$family 默认路由查询失败，状态未知。"; fi
    done
  else warn 'ip 不可用，IPv4/IPv6 地址与路由状态未知。'; fi
  echo '-- UFW IPv4/IPv6 配置 --'
  if command -v ufw >/dev/null; then
    if data="$(ufw status verbose 2>/dev/null)" && [[ -n "$data" ]]; then audit_bounded_lines 60 <<< "$data"
    else warn '无法取得 UFW 状态，可能权限不足；状态未知。'; fi
    if [[ -r /etc/default/ufw ]]; then ipv6="$(audit_ufw_ipv6 < /etc/default/ufw)"; fi
    case "$ipv6" in
      yes) echo 'UFW IPV6=yes：配置允许管理 IPv6；仍需核对实际 v6 规则与监听。' ;;
      no) warn 'UFW IPV6=no：不要假设 UFW 已保护 IPv6 入口；请人工核对 IPv6 与上游防火墙。' ;;
      *) warn 'UFW IPV6 配置未知（缺失、不可读、重复或复杂赋值），不执行该配置文件。' ;;
    esac
  else warn 'UFW 未安装；其他防火墙和商家规则需另外确认。'; fi
  echo '商家安全组、上游防火墙和公网实际可达性无法仅从本机验证，请在服务商控制台与另一台机器确认。'
}

security_audit() {
  local data='' values=''
  say '登录与网络安全审计（只读，不改变登录入口）'
  if command -v sshd >/dev/null; then
    sshd_runtime_dir
    if sshd -t >/dev/null 2>&1; then ok 'sshd -t 配置检查通过（不验证真实登录）。'
    else warn 'sshd -t 未通过或权限不足，SSH 配置有效性未知；保留现状。'; fi
    if data="$(sshd -T 2>/dev/null)" && [[ -n "$data" ]]; then
      values="$(audit_sshd_values <<< "$data")"
      audit_clean_text <<< "$values"
      if [[ "$values" == *'=UNKNOWN'* ]]; then warn '部分 SSH 配置项未返回，不能推断其默认值。'; fi
      if grep -Fxq 'permitemptypasswords=yes' <<< "$values"; then warn 'SSH 默认配置允许空密码认证；需结合账户及 PAM 检查风险。'; fi
    else warn 'sshd -T 失败或返回空结果，SSH 实际配置未知。'; fi
    echo '上述为默认 sshd -T 输出；没有提供连接条件 -C，不能代表所有 Match 条件、启动参数或现有连接。'
  else warn 'sshd 不可用，SSH 配置状态未知。'; fi
  audit_accounts
  audit_authorized_keys
  audit_network
  docker_firewall_note
  echo '-- AppArmor --'
  if command -v aa-status >/dev/null; then
    if aa-status --enabled >/dev/null 2>&1; then echo 'aa-status 确认 AppArmor 已启用；未逐个验收应用配置。'
    else warn 'aa-status 无法确认 AppArmor 已启用，可能未启用或权限不足；不安装、不更改。'; fi
  else warn 'aa-status 不可用，AppArmor 状态未知；不安装、不更改。'; fi
}

audit_journal_health() {
  local stats='' scanned=0 oom=0 io=0 crash=0 access_issue=0 limited=0
  echo '-- 最近内核/异常关机线索（只输出计数） --'
  if ! command -v journalctl >/dev/null; then warn 'journalctl 不可用，日志健康状态未知。'; return 0; fi
  if (( EUID != 0 )); then warn '非 root，无法保证可读取完整系统日志；日志健康状态未知。'; return 0; fi
  if stats="$(journalctl --system -b 0 --since '-24 hours' -n 1000 --no-pager -o cat 2>&1 | audit_journal_counts)"; then
    read -r scanned oom io crash access_issue limited <<< "$stats"
    if (( !scanned || access_issue )); then
      warn '当前启动的系统日志为空或出现访问提示，日志健康状态未知。'; return 0
    fi
    printf '范围：本次启动近 24 小时，最近最多 1000 条记录；已扫描 %s 行，每行最多匹配前 1024 字符。\n' "$scanned"
    printf '匹配行数：OOM=%s，存储 I/O/文件系统错误=%s，内核崩溃/未正常关机线索=%s。\n' "$oom" "$io" "$crash"
    if (( oom || io || crash )); then warn '发现需人工核对的日志线索；行数不等于故障次数，脚本不回显原始日志。'; fi
    if (( limited )); then warn '多行日志达到 3000 行扫描上限，其余未分析。'; fi
    echo '零匹配不代表没有故障；该窗口无法完整判断此前重启是否异常，也不覆盖历史启动。'
  else
    warn '系统日志查询失败或权限不足，日志健康状态未知；不回显日志错误内容。'
  fi
}

health_report() {
  local data='' inode='' risks='' line='' total='' available_mem='' swap_total='' swap_free=''
  say '磁盘、内存与服务健康检查（只读）'
  echo '-- 根分区与 /boot 容量（KiB） --'
  if command -v df >/dev/null; then
    # Without a separate /boot, df prints the root line twice.
    if data="$(df -Pk / /boot 2>/dev/null | awk '!seen[$0]++')" && [[ -n "$data" ]]; then
      audit_bounded_lines 12 <<< "$data"
      risks="$(audit_disk_risks 磁盘 <<< "$data")"
      if [[ -n "$risks" ]]; then while IFS= read -r line; do warn "$(audit_clean_text <<< "$line")"; done <<< "$risks"; fi
    else warn '根分区或 /boot 容量查询失败或为空，状态未知。'; fi
    echo '-- inode 使用量 --'
    if inode="$(df -Pi / /boot 2>/dev/null | awk '!seen[$0]++')" && [[ -n "$inode" ]]; then
      audit_bounded_lines 12 <<< "$inode"
      risks="$(audit_disk_risks inode <<< "$inode")"
      if [[ -n "$risks" ]]; then while IFS= read -r line; do warn "$(audit_clean_text <<< "$line")"; done <<< "$risks"; fi
    else warn '根分区或 /boot inode 查询失败或为空，状态未知。'; fi
  else warn 'df 不可用，磁盘与 inode 状态未知。'; fi
  echo '-- MemAvailable 与 Swap --'
  if [[ -r /proc/meminfo ]]; then
    data="$(audit_mem_values < /proc/meminfo)"
    printf '%s\n' "$data"
    echo '以上数值单位为 KiB；UNKNOWN 表示内核未返回可解析字段。'
    if [[ "$data" == *'=UNKNOWN'* ]]; then
      warn '部分内存字段未知，不据此判断内存健康。'
    else
      total="$(awk -F= '$1=="MemTotal" {print $2}' <<< "$data")"
      available_mem="$(awk -F= '$1=="MemAvailable" {print $2}' <<< "$data")"
      swap_total="$(awk -F= '$1=="SwapTotal" {print $2}' <<< "$data")"
      swap_free="$(awk -F= '$1=="SwapFree" {print $2}' <<< "$data")"
      if (( total>0 && available_mem*100<total*5 )); then warn 'MemAvailable 低于总内存 5%；这是瞬时值，请结合业务与 OOM 记录确认。'; fi
      if (( swap_total==0 )); then echo '当前没有 Swap；是否需要取决于内存与业务，不自动判为故障。'
      else printf 'Swap 已用：%s KiB（不能据此判断是否持续发生换页）。\n' "$((swap_total-swap_free))"; fi
    fi
  else warn '/proc/meminfo 不可读，内存状态未知。'; fi
  echo '-- failed 服务（不自动禁用或修复） --'
  if command -v systemctl >/dev/null; then
    if data="$(systemctl list-units --state=failed --type=service --no-legend --no-pager --plain 2>/dev/null)"; then
      if [[ -n "$data" ]]; then audit_bounded_lines 20 <<< "$data"; warn '存在 failed 服务，请核对用途与失败原因。'
      else echo '查询未返回 failed 服务；这不代表所有服务功能正常。'; fi
    else warn 'failed 服务查询失败，可能权限不足或 systemd 不可用，状态未知。'; fi
  else warn 'systemctl 不可用，failed 服务状态未知。'; fi
  audit_journal_health
}

# Per-run configuration snapshots and plain-text execution state.
# BACKUP_ROOT and STATE_ROOT are fixed by the caller; no state is sourced.
RUN_ID=''
RUN_STATE_DIR=''
RUN_BACKUP_DIR=''
CURRENT_STAGE=''
BACKUP_ITEM_COUNT=0
declare -A BACKED_UP_PATHS=()

state_path_safe() {
  local path="$1" part current=''
  local -a parts=()
  [[ "$path" == /* && "$path" != / && "$path" != */ && "$path" != *'//'* && "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 1
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    [[ "$part" != . && "$part" != .. ]] || return 1
    current="$current/$part"
    [[ ! -L "$current" ]] || return 1
  done
}

state_secure_dir() {
  local path="$1"
  state_path_safe "$path" || die "状态或备份目录不安全（是链接或路径异常）：$path"
  [[ ! -e "$path" || ( -d "$path" && -O "$path" ) ]] || die "状态或备份目录不归当前用户所有：$path"
  install -d -m 700 -- "$path"
  chmod 700 -- "$path"
}

state_write() {
  local key="$1" value="$2" target temp
  [[ "$key" =~ ^[a-z_][a-z0-9_.-]*$ && -n "$RUN_STATE_DIR" ]] || die '状态记录参数异常。'
  target="$RUN_STATE_DIR/$key"
  [[ ! -L "$target" && ( ! -e "$target" || ( -f "$target" && -O "$target" ) ) ]] || die "状态文件不安全：$target"
  temp="$(mktemp "$RUN_STATE_DIR/.state.XXXXXX")"
  printf '%s\n' "$value" > "$temp"
  chmod 600 -- "$temp"
  mv -fT -- "$temp" "$target"
}

state_event() {
  local stage="$1" result="$2" code="$3"
  [[ -n "$RUN_STATE_DIR" && -f "$RUN_STATE_DIR/stages.tsv" && ! -L "$RUN_STATE_DIR/stages.tsv" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$stage" "$result" "$code" >> "$RUN_STATE_DIR/stages.tsv"
}

prepare_run_state() {
  local latest temp
  state_secure_dir "$STATE_ROOT"
  state_secure_dir "$BACKUP_ROOT"
  latest="$STATE_ROOT/latest"
  [[ ! -L "$latest" && ( ! -e "$latest" || ( -f "$latest" && -O "$latest" ) ) ]] || die "最近运行记录的指针文件不安全：$latest"
  RUN_STATE_DIR="$(mktemp -d "$STATE_ROOT/run-$(date -u +%Y%m%dT%H%M%SZ)-$$-XXXXXX")"
  chmod 700 -- "$RUN_STATE_DIR"
  RUN_ID="${RUN_STATE_DIR##*/}"
  RUN_BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
  [[ ! -e "$RUN_BACKUP_DIR" && ! -L "$RUN_BACKUP_DIR" ]] || die '本次备份目录已存在。'
  mkdir -m 700 -- "$RUN_BACKUP_DIR"
  CURRENT_STAGE='initialization'
  BACKUP_ITEM_COUNT=0
  BACKED_UP_PATHS=()
  state_write status running
  state_write active_stage "$CURRENT_STAGE"
  state_write started_at "$(date -u +%FT%TZ)"
  state_write version "$SCRIPT_VERSION"
  state_write mode "$MODE"
  state_write boot_id "$(cat /proc/sys/kernel/random/boot_id)"
  state_write running_kernel "$(uname -r)"
  state_write os "$OS:$OS_VERSION"
  state_write backup_dir "$RUN_BACKUP_DIR"
  printf 'timestamp_utc\tstage\tresult\texit_code\n' > "$RUN_STATE_DIR/stages.tsv"
  printf 'original_path\toriginal_state\tbackup_path\n' > "$RUN_BACKUP_DIR/manifest.tsv"
  printf 'timestamp_utc\tpath\taction\n' > "$RUN_STATE_DIR/changes.tsv"
  chmod 600 -- "$RUN_STATE_DIR/stages.tsv" "$RUN_STATE_DIR/changes.tsv" "$RUN_BACKUP_DIR/manifest.tsv"
  temp="$(mktemp "$STATE_ROOT/.latest.XXXXXX")"
  printf '%s\n' "$RUN_ID" > "$temp"
  chmod 600 -- "$temp"
  mv -fT -- "$temp" "$latest"
  ok "运行记录：$RUN_STATE_DIR"
  ok "配置备份目录：$RUN_BACKUP_DIR"
  run_records_prune
}

# Every run adds a run record and a configuration backup. The first run (the
# configuration before this tool) and the newest 20 runs are kept; the
# rollback baseline lives in restore-v2 and is never touched here.
run_records_prune() {
  local dir id root pruned=0 newest=20 keep=' '
  local -a ids=()
  mapfile -t ids < <(for dir in "$STATE_ROOT"/run-* "$BACKUP_ROOT"/run-*; do printf '%s\n' "${dir##*/}"; done |
    grep -E '^run-[0-9]{8}T[0-9]{6}Z-[0-9]+-[A-Za-z0-9]{6}$' | LC_ALL=C sort -u)
  ((${#ids[@]} > newest + 1)) || return 0
  # The current run always stays, even when wrong clocks left later names.
  keep+="${ids[0]} ${RUN_ID:-} "
  for id in "${ids[@]: -newest}"; do keep+="$id "; done
  for id in "${ids[@]}"; do
    [[ "$keep" != *" $id "* ]] || continue
    for root in "$STATE_ROOT" "$BACKUP_ROOT"; do
      dir="$root/$id"
      [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || continue
      rm -rf --one-file-system -- "$dir" || { warn "无法清理旧记录：$dir"; continue; }
    done
    pruned=$((pruned + 1))
  done
  ok "已清理 $pruned 次较早的运行记录和配置备份（保留第一次和最近 $newest 次）。"
}

backup_config_path() {
  local source="$1" target kind
  [[ -n "$RUN_BACKUP_DIR" && "$source" == /* && "$source" != *$'\n'* && "$source" != *$'\t'* && "$source" != *'/../'* && "$source" != */.. ]] || die '备份路径异常。'
  [[ -z "${BACKED_UP_PATHS[$source]+x}" ]] || return 0
  if [[ -L "$source" ]]; then
    kind='symlink'
  elif [[ -f "$source" ]]; then
    kind='file'
  elif [[ ! -e "$source" ]]; then
    printf '%s\tmissing\t-\n' "$source" >> "$RUN_BACKUP_DIR/manifest.tsv" || die '无法记录不存在的配置路径。'
    BACKED_UP_PATHS["$source"]=1
    return 0
  else
    die "这里应该是配置文件，拒绝备份目录或特殊文件：$source"
  fi
  BACKUP_ITEM_COUNT=$((BACKUP_ITEM_COUNT+1))
  target="$RUN_BACKUP_DIR/files/$(printf '%06d' "$BACKUP_ITEM_COUNT")"
  install -d -m 700 -- "$RUN_BACKUP_DIR/files" || die '无法创建配置备份目录。'
  [[ ! -e "$target" && ! -L "$target" ]] || die '备份目标已存在。'
  cp -aT -- "$source" "$target" || die "配置备份失败：$source"
  printf '%s\t%s\t%s\n' "$source" "$kind" "$target" >> "$RUN_BACKUP_DIR/manifest.tsv" || die '无法写入备份清单。'
  BACKED_UP_PATHS["$source"]=1
}

# Snapshot the link itself when a configuration directory is a symlink.
# Never recurse into an arbitrary /etc tree or copy SSH host private keys.
backup_config_group() {
  local directory="$1" pattern file
  shift
  if [[ -L "$directory" ]]; then backup_config_path "$directory"; return 0; fi
  [[ -d "$directory" ]] || return 0
  for pattern in "$@"; do
    for file in "$directory"/$pattern; do
      [[ -e "$file" || -L "$file" ]] || continue
      backup_config_path "$file"
    done
  done
}

backup_configs() {
  local file unit
  say '保存配置快照与优化前状态'
  for file in "$BBR_FILE" "$MODULE_FILE" "$ZRAM_FILE" "$ZRAM_SYSCTL_FILE" "$JOURNAL_FILE" "$F2B_FILE" "$APT_FILE" "$F2B_ACTION_FILE" "$F2B_DB_FILE" "$LOGIN_PAM_FILE" "$LOGIN_PROFILE_FILE" "$PAM_COMMON_SESSION" "$CHECK_SERVICE_FILE" "$CHECK_TIMER_FILE" "$DOCKER_DAEMON_FILE" "$SSH_PORT_DROPIN" "$SSH_DROPIN" "$SSH_PUBKEY_DROPIN" \
      /etc/ssh/sshd_config /etc/default/ssh /etc/default/ufw \
      /etc/ufw/ufw.conf /etc/ufw/sysctl.conf /etc/ufw/before.rules /etc/ufw/before6.rules \
      /etc/ufw/after.rules /etc/ufw/after6.rules /etc/ufw/user.rules /etc/ufw/user6.rules \
      /etc/sysctl.conf /etc/systemd/journald.conf /etc/default/zramswap \
      /etc/apt/apt.conf /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/sources.list /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
      /etc/systemd/timesyncd.conf /etc/hostname "$CLOUD_HOSTNAME_FILE" "$SWAP_UNIT_FILE" "$CONNTRACK_FILE" "$CONNTRACK_MODULE_FILE" "$PING_FILE" \
      "$KEEPALIVE_FILE" "$GAI_FILE" "$APT_TIME_FILE"; do
    backup_config_path "$file"
  done
  backup_config_group /etc/ssh/sshd_config.d '*.conf'
  backup_config_group /etc/sysctl.d '*.conf'
  backup_config_group /etc/systemd/journald.conf.d '*.conf'
  backup_config_group /etc/systemd/zram-generator.conf.d '*.conf'
  backup_config_group /etc/systemd/timesyncd.conf.d '*.conf'
  backup_config_group /etc/apt/sources.list.d '*.list' '*.sources'
  backup_config_group /etc/apt/apt.conf.d '*'
  backup_config_group /etc/fail2ban/jail.d '*.conf' '*.local'
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem > "$RUN_BACKUP_DIR/runtime-sysctl.txt" 2>&1 || true
  if command -v ufw >/dev/null; then
    ufw status verbose > "$RUN_BACKUP_DIR/runtime-ufw.txt" 2>&1 || true
    ufw show added > "$RUN_BACKUP_DIR/stored-ufw-rules.txt" 2>&1 || true
  fi
  for unit in ssh.service ssh.socket ufw.service fail2ban.service systemd-timesyncd.service fstrim.timer apt-daily.timer apt-daily-upgrade.timer; do
    printf '%s\tactive=%s\tenabled=%s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)" "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  done > "$RUN_BACKUP_DIR/services-before.tsv"
  cat > "$RUN_BACKUP_DIR/recovery-notes.txt" <<'RECOVERY_NOTES'
本目录保存本次修改之前的有限系统配置，不是整机快照或业务数据备份。
manifest.tsv 将原路径映射到 files/数字文件；missing 表示原先不存在。
files 中的符号链接只保存链接本身，不保证其外部目标内容被保存。
运行记录中的 changes.tsv 仅记录本脚本直接发布的配置文件，不覆盖 APT 或其他程序的全部改动。
恢复前先保存当前状态，人工核对路径、内容、权限和现有服务，再逐项恢复。
不要整批覆盖 /etc，不要盲目删除 missing 项；先确认确为本次新建且仍未被其他程序修改。
恢复 SSH/防火墙前保留原会话，并确认服务商 Console/VNC 可用。
修改 SSH 配置后先运行 sshd -t，并从第二个会话验证登录。
APT 更新、依赖、内核、运行中的服务以及数据库不由本目录自动还原；必要时使用服务商快照。
脚本不会执行本目录内的恢复指令，也不会自动恢复或重启整机。
配置与日志可能包含环境信息或凭据，应保持本目录私有，不要直接公开分享。
RECOVERY_NOTES
  chmod 600 -- "$RUN_BACKUP_DIR"/*.txt "$RUN_BACKUP_DIR"/*.tsv
  echo '配置快照仅用于人工核对/恢复；不自动恢复软件包、运行时参数或整机状态。'
}

# Invoke directly at top level, never as an if/!/&& condition: those contexts
# disable Bash errexit in the called stage. ERR/EXIT traps record failures.
stage_run() {
  local stage="$1"
  shift
  [[ "$stage" =~ ^[a-z][a-z0-9_-]*$ && $# -gt 0 ]] || die '阶段名称异常。'
  CURRENT_STAGE="$stage"
  state_write active_stage "$stage"
  state_event "$stage" running 0
  if ! restore_before_stage "$stage"; then
    state_event "$stage" skipped 0
    warn "本模块的回退记录无法安全保存或读取，已跳过：$stage"
    CURRENT_STAGE=''
    state_write active_stage none
    return 0
  fi
  "$@"
  restore_after_stage "$stage"
  state_event "$stage" success 0
  CURRENT_STAGE=''
  state_write active_stage none
}

record_failure() {
  local line="$1" code="$2"
  [[ -n "$RUN_STATE_DIR" && -d "$RUN_STATE_DIR" && ! -L "$RUN_STATE_DIR" ]] || return 0
  [[ "$line" =~ ^[0-9]+$ && "$code" =~ ^[0-9]+$ ]] || return 0
  state_write status failed || true
  state_write failed_line "$line" || true
  state_write exit_code "$code" || true
  state_write finished_at "$(date -u +%FT%TZ)" || true
  state_event "${CURRENT_STAGE:-unknown}" failed "$code" || true
}

record_exit() {
  local code="$1" status
  [[ -n "$RUN_STATE_DIR" && -f "$RUN_STATE_DIR/status" && ! -L "$RUN_STATE_DIR/status" ]] || return 0
  status="$(cat "$RUN_STATE_DIR/status")"
  if [[ "$status" == running ]]; then
    if [[ "$code" != 0 ]]; then record_failure 0 "$code"
    else state_write status incomplete || true; fi
  fi
}

finish_run_state() {
  state_write finished_at "$(date -u +%FT%TZ)"
  state_write warning_count "${WARNINGS:-0}"
  state_write active_stage none
  state_write status completed
}

state_report() {
  local latest id directory status old_boot current_boot old_kernel file
  echo '-- 上一次运行记录 --'
  latest="$STATE_ROOT/latest"
  if [[ ! -e "$latest" && ! -L "$latest" ]]; then echo '还没有运行记录。'; return 0; fi
  if ! state_path_safe "$STATE_ROOT" || [[ ! -d "$STATE_ROOT" || ! -O "$STATE_ROOT" || ! -f "$latest" || -L "$latest" || ! -O "$latest" ]]; then
    warn '状态目录不安全或无法读取，没有检查上一次运行记录。'; return 0
  fi
  id="$(cat "$latest" 2>/dev/null)" || { warn '需要 root 才能读取上一次运行记录。'; return 0; }
  if [[ ! "$id" =~ ^run-[0-9]{8}T[0-9]{6}Z-[0-9]+-[A-Za-z0-9]{6}$ ]]; then warn '上一次运行编号格式异常，已忽略。'; return 0; fi
  directory="$STATE_ROOT/$id"
  if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ]]; then warn '上一次运行的记录目录不存在或不安全。'; return 0; fi
  for file in status boot_id running_kernel; do
    if [[ ! -f "$directory/$file" || -L "$directory/$file" || ! -O "$directory/$file" || ! -r "$directory/$file" ]]; then warn "无法安全读取上一次运行的记录：$file"; return 0; fi
  done
  status="$(cat "$directory/status")"
  old_boot="$(cat "$directory/boot_id")"
  old_kernel="$(cat "$directory/running_kernel")"
  [[ "$status" =~ ^(running|failed|incomplete|completed)$ && "$old_boot" =~ ^[a-f0-9-]{36}$ && "$old_kernel" =~ ^[A-Za-z0-9._+-]+$ ]] || { warn '上一次运行的记录格式异常，已忽略。'; return 0; }
  printf '运行编号：%s | 状态：%s\n' "$id" "$status"
  if [[ "$id" == "${RUN_ID:-}" && "$status" == running ]]; then
    echo '本次运行仍在进行，完成记录会在报告之后写入。'
  elif [[ "$status" != completed ]]; then
    warn '上一次运行没有完成，请先查看 stages.tsv 和日志再重试。'
  fi
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  printf '那次运行时的内核：%s | 现在的内核：%s\n' "$old_kernel" "$(uname -r)"
  if [[ -z "$current_boot" ]]; then warn '无法读取当前启动 ID，不能判断是否重启过。'
  elif [[ "$old_boot" == "$current_boot" ]]; then echo '那次运行之后还没有重启过（启动 ID 没变）。'
  else echo '那次运行之后已经重启过（启动 ID 已变），可用 vps check 验收。'; fi
  local key value
  for key in active_stage failed_line exit_code; do
    if [[ -f "$directory/$key" && ! -L "$directory/$key" && -O "$directory/$key" && -r "$directory/$key" ]]; then
      value="$(cat "$directory/$key")" || continue
      if [[ "$value" =~ ^[a-z0-9_-]+$ ]]; then printf '%s=%s\n' "$key" "$value"; fi
    fi
  done
  echo "运行记录目录：$directory（只读）。"
}

record_config_change() {
  local target="$1" action="$2"
  [[ -n "$RUN_STATE_DIR" && -f "$RUN_STATE_DIR/changes.tsv" && ! -L "$RUN_STATE_DIR/changes.tsv" ]] || return 1
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$target" "$action" >> "$RUN_STATE_DIR/changes.tsv"
}

# Menu actions run in a fresh interpreter. A conditional around a Bash function
# would suppress errexit inside that function; a separate /bin/bash avoids it.
menu_action() {
  local self="$1" action="$2" code
  case "$action" in plan|perf|resources|audit|setup|item|firewall|ssh|port|check|records|uninstall|rollback|reboot|update|bans) ;; *) die '无效的菜单操作。' ;; esac
  # The new interpreter keeps its own errexit even inside the parent's if.
  if /bin/bash -- "$self" "$action"; then
    echo '本项已结束；请查看上方结果、跳过项和注意事项。'
  else
    code=$?
    if [[ "$action" == rollback && "$code" == 2 ]]; then
      printf '撤销只完成了一部分（退出码 2）；请按上方提示处理没能恢复的项目后再重试。\n' >&2
    elif [[ "$action" == check && "$code" == 3 ]]; then
      printf '验收发现有项目未生效（退出码 3）；请按上方说明处理后再验收。\n' >&2
    else
      printf '本项已停止（退出码 %s）；请先查看错误和记录，再决定是否重试。\n' "$code" >&2
    fi
  fi
}

# Read-only performance check: a 3-second sample of the CPU (stolen by the
# host, waiting for the disk), the pressure the kernel reports, memory and
# paging, TCP retransmissions, connection tracking and the system disk.
perf_main() {
  local -a a=() b=()
  local total steal iowait pin pout pin2 pout2 cores load line some retrans out pct avail
  say '性能体检（只读，约 3 秒）'
  VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_NOTICE=0 VERIFY_ISSUES=()
  read -r -a a < <(awk '$1 == "cpu"' /proc/stat)
  pin="$(awk '$1 == "pswpin" {print $2}' /proc/vmstat)" pout="$(awk '$1 == "pswpout" {print $2}' /proc/vmstat)"
  sleep 3
  read -r -a b < <(awk '$1 == "cpu"' /proc/stat)
  pin2="$(awk '$1 == "pswpin" {print $2}' /proc/vmstat)" pout2="$(awk '$1 == "pswpout" {print $2}' /proc/vmstat)"
  total=0
  for ((line = 1; line <= 8 && line < ${#b[@]}; line++)); do total=$((total + b[line] - a[line])); done
  ((total > 0)) || total=1
  steal=$(((b[8] - a[8]) * 100 / total)) iowait=$(((b[5] - a[5]) * 100 / total))
  if ((steal >= 5)); then verify_line notice 'CPU 被抢' "${steal}%：同一台宿主机上的别的机器在抢 CPU（超卖），程序会时快时慢；长期这样可以找服务商"
  else verify_line healthy 'CPU 被抢' "${steal}%"; fi
  if ((iowait >= 20)); then verify_line notice '等硬盘' "${iowait}%：CPU 有很多时间在等硬盘读写，硬盘慢或者正在大量读写"
  else verify_line healthy '等硬盘' "${iowait}%"; fi
  cores="$(nproc 2>/dev/null || echo 1)" load="$(awk '{print $1}' /proc/loadavg)"
  if awk -v l="$load" -v c="$cores" 'BEGIN {exit !(l > c * 1.5)}'; then verify_line notice '负载' "最近 1 分钟 $load（$cores 核）：要处理的任务比 CPU 多不少"
  else verify_line healthy '负载' "最近 1 分钟 $load（$cores 核）"; fi
  for line in cpu memory io; do
    some="$(awk '$1 == "some" {sub(/avg60=/, "", $3); print $3}' "/proc/pressure/$line" 2>/dev/null || true)"
    [[ -n "$some" ]] || continue
    if awk -v s="$some" 'BEGIN {exit !(s >= 10)}'; then verify_line notice "压力（$line）" "过去 1 分钟有 ${some}% 的时间有任务在等 $line：这一项是瓶颈"
    else verify_line healthy "压力（$line）" "${some}%"; fi
  done
  avail="$(awk '$1 == "MemAvailable:" {a = $2} $1 == "MemTotal:" {t = $2} END {printf "%d", a * 100 / t}' /proc/meminfo)"
  if ((avail < 10)); then verify_line notice '可用内存' "只剩 ${avail}%：再多一点就可能有进程被杀"
  else verify_line healthy '可用内存' "${avail}%"; fi
  if [[ "$pin" =~ ^[0-9]+$ && "$pin2" =~ ^[0-9]+$ ]]; then
    line=$(((pin2 - pin + pout2 - pout) / 3))
    if ((line >= 100)); then verify_line notice '换页' "每秒约 $line 页：内存不够，正在频繁用 Swap，会明显变慢"
    else verify_line healthy '换页' "每秒约 $line 页"; fi
  fi
  read -r retrans out < <(awk '$1 == "Tcp:" && $2 ~ /^[0-9]+$/ {print $13, $12}' /proc/net/snmp 2>/dev/null) || true
  if [[ "$retrans" =~ ^[0-9]+$ && "$out" =~ ^[1-9][0-9]*$ ]]; then
    pct=$((retrans * 1000 / out))
    if ((pct >= 20)); then verify_line notice 'TCP 重传' "开机以来 $((pct / 10)).$((pct % 10))% 的包要重发：线路丢包比较多"
    else verify_line healthy 'TCP 重传' "开机以来 $((pct / 10)).$((pct % 10))%"; fi
  fi
  verify_conntrack_usage
  read -r pct line < <(df -P / 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5, $4}') || true
  if [[ "$pct" =~ ^[0-9]+$ ]] && ((pct >= 90)); then verify_line notice '系统盘' "用了 ${pct}%：快满了，满了会出各种奇怪的错误"
  elif [[ "$pct" =~ ^[0-9]+$ ]]; then verify_line healthy '系统盘' "用了 ${pct}%"; fi
  pct="$(df -Pi / 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}' || true)"
  if [[ "$pct" =~ ^[0-9]+$ ]] && ((pct >= 90)); then verify_line notice '系统盘文件数（inode）' "用了 ${pct}%：小文件太多，满了就写不了新文件"; fi
  echo
  if ((${#VERIFY_ISSUES[@]})); then printf '有 %s 项要留意（见上面的 %s）。这是这 3 秒和开机以来的情况，偶尔一次不代表有问题。\n' "${#VERIFY_ISSUES[@]}" "${SYM_WARN-⚠}"
  else printf '%s%s 都正常。%s这是这 3 秒和开机以来的情况。\n' "${C_OK-}" "${SYM_OK-✔}" "${C_RESET-}"; fi
}

# KEY UNIT LABEL CAN: one resident service: its memory and CPU time (from its
# cgroup), and whether it can be turned off and what that costs.
resources_line() {
  local unit="$2" mem cpu state
  state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
  [[ "$state" == active ]] || return 0
  mem="$(systemctl show -p MemoryCurrent --value "$unit" 2>/dev/null || true)"
  cpu="$(systemctl show -p CPUUsageNSec --value "$unit" 2>/dev/null || true)"
  if [[ "$mem" =~ ^[0-9]+$ ]]; then mem="$((mem / 1048576)) MiB"; else mem='未知'; fi
  if [[ "$cpu" =~ ^[0-9]+$ ]]; then cpu="$((cpu / 1000000000)) 秒"; else cpu='未知'; fi
  printf '  %s%s%s：内存 %s，开机以来 CPU %s。%s\n' "${C_BOLD-}" "$3" "${C_RESET-}" "$mem" "$cpu" "$4"
}

# Read-only: what keeps running, what it costs, what turning it off loses.
resources_main() {
  local rules size
  say '资源占用一览（只读）'
  echo '常驻的服务（只列在运行的）：'
  resources_line ssh ssh.service 'SSH' '不能关：远程登录靠它。'
  resources_line ssh sshd.service 'SSH' '不能关：远程登录靠它。'
  resources_line fail2ban fail2ban.service 'Fail2ban' '可以关（单项设置 16）：关了就没有防爆破，扫描请求照样打过来，日志会多一些。'
  resources_line vnstat vnstat.service 'vnStat' '可以关（单项设置 13）：关了就没有流量统计。'
  resources_line updates unattended-upgrades.service '自动安全更新' '常驻部分只是关机时收尾用的；真正升级时（每天一次）才多占内存。可以关（单项设置 2）。'
  resources_line ntp systemd-timesyncd.service '时间同步' '很小，建议保留：时间不准会让证书校验和日志出错。'
  resources_line ntp chrony.service '时间同步（chrony）' '建议保留：时间不准会让证书校验和日志出错。'
  resources_line journal systemd-journald.service '系统日志' '不能关：系统和程序的日志都靠它；大小有上限。'
  resources_line docker docker.service 'Docker' '你自己装的服务。'
  echo '内核里的功能（BBR、内核参数、TCP 调优、防火墙）几乎不占内存，也不常驻进程。'
  if [[ -r /sys/block/zram0/mm_stat ]] && size="$(awk '{printf "%d %d", $1 / 1048576, $3 / 1048576}' /sys/block/zram0/mm_stat)" && [[ -n "$size" ]]; then
    printf 'ZRAM：存了 %s MiB 的数据，实际占内存 %s MiB（压缩后）。\n' "${size% *}" "${size#* }"
  fi
  if command -v ufw >/dev/null; then
    rules="$(ufw show added 2>/dev/null | grep -cE '^ufw (prepend |insert [0-9]+ )?deny ' || true)"
    if ((rules > 300)); then
      printf '%s%s Fail2ban 的封禁规则有 %s 条：每次封禁、解封都要让 UFW 重新加载规则，攻击很多时会占不少 CPU。可以缩短封禁时间，或者让来源 IP 多的服务只对需要的人开放。%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" "$rules" "${C_RESET-}"
    else printf '防火墙里的封禁规则：%s 条。\n' "$rules"; fi
  fi
}

# TG notifications and the monthly traffic alert share one check: a script
# this tool writes (STATE_ROOT/notify-check) that a systemd timer runs every
# minute (with TG; logins arrive within a minute) or every 5 minutes, and that
# exits when done. It is gone when neither is on.
notify_check_text() {
  sed -e "s#@STATE@#$STATE_ROOT#g" -e 's#@MAIN@#/usr/local/lib/vps-stable-opt/vps-stable-opt.sh#g' <<'CHECK'
#!/bin/bash
# VPS Stable Optimizer v2.8: the check behind TG notifications and the traffic
# alert. A systemd timer runs it (every minute with TG, else every 5 minutes);
# it reads what changed since its last run, sends what is due, and exits.
state='@STATE@'
# The tool is gone (uninstalled without taking this away): stop quietly.
[ -f '@MAIN@' ] && [ -d "$state" ] && [ ! -L "$state" ] || exit 0
umask 077
export LC_ALL=C.UTF-8
dir="$state/notify"
mkdir -p "$dir" || exit 0
# A run still busy (a send that hangs): this one is skipped, never stacked.
exec 8> "$dir/lock"
flock -n 8 || exit 0
now="$(date +%s)"
conf="$state/notify.conf" tconf="$state/quota.conf"
tab="$(printf '\t')" us="$(printf '\037')"
first=0; [ -f "$dir/last-run" ] || first=1
setting() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
param() {
  v="$(awk -F= -v k="$1" '$1 == k {v = substr($0, length(k) + 2)} END {print v}' "$state/params" 2>/dev/null)"
  printf '%s' "${v:-$2}"; }
# Anything read from a log or a file: no control characters, not too long.
clean() { LC_ALL=C tr -d '\000-\037\177' | cut -c1-"${1:-120}"; }
when() { date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || echo '?'; }
tg=0; [ -s "$conf" ] && tg=1
# TEXT: queued for TG (newlines kept as one line), at most 200 waiting.
queue() {
  [ "$tg" = 1 ] || return 0
  { printf '%s' "$1" | tr '\n' "$us"; echo; } >> "$dir/queue"
  if [ "$(wc -l < "$dir/queue")" -gt 200 ]; then tail -n 200 "$dir/queue" > "$dir/queue.new" && mv -f "$dir/queue.new" "$dir/queue"; fi; }
# Each message one request; the token goes in through stdin, never on the
# command line. Sent ones leave the queue at once, so a run cut short never
# sends one twice; a failure keeps the rest for the next run (offline).
send_queue() {
  [ "$tg" = 1 ] && [ -s "$dir/queue" ] || return 0
  token="$(setting token "$conf")" chat="$(setting chat "$conf")" api="$(setting api "$conf")"
  head="【$(param display_name "$(hostname -s 2>/dev/null)" | clean 40) · $(setting ip "$conf")】"
  n=0
  while [ -s "$dir/queue" ] && [ "$n" -lt 10 ]; do
    { echo "$head"; head -n 1 "$dir/queue" | tr "$us" '\n'; } > "$dir/message"
    printf 'url = "%s/bot%s/sendMessage"\n' "${api:-https://api.telegram.org}" "$token" |
      curl -fsS --max-time 15 -o /dev/null -K - --data-urlencode "chat_id=$chat" --data-urlencode "text@$dir/message" \
        --data disable_web_page_preview=true 2>/dev/null || break
    sed -i '1d' "$dir/queue"
    n=$((n + 1))
  done; }
# NAME FILTER...: journal lines since NAME's cursor, as "time ident message".
# The first time it starts from now; a cursor the journal no longer has
# (cleared) falls back to the time of the last run.
journal_new() {
  name="$1"; shift
  cur="$(cat "$dir/$name.cursor" 2>/dev/null)"
  if [ -z "$cur" ]; then
    journalctl -q -n 1 --show-cursor -o cat --no-pager 2>/dev/null | sed -n 's/^-- cursor: //p' > "$dir/$name.cursor"; return 0
  fi
  out="$(journalctl -q --after-cursor="$cur" --show-cursor -o short-unix --no-pager "$@" 2>/dev/null)" ||
    out="$(journalctl -q --since="@$(cat "$dir/last-run" 2>/dev/null || echo "$now")" --show-cursor -o short-unix --no-pager "$@" 2>/dev/null)"
  new="$(printf '%s\n' "$out" | sed -n 's/^-- cursor: //p' | tail -n 1)"
  [ -z "$new" ] || printf '%s\n' "$new" > "$dir/$name.cursor"
  printf '%s\n' "$out" | grep -v '^-- cursor: ' | awk '{t = $1; sub(/\..*/, "", t); id = $3; sub(/\[.*/, "", id); sub(/:$/, "", id); $1 = $2 = $3 = ""; sub(/^ +/, ""); print t "\t" id "\t" $0}'; }
# NAME: the lines of a list (made by the command after it) that were not in
# it last time; the first time only remembered.
new_lines() {
  name="$1"; shift
  "$@" 2>/dev/null | LC_ALL=C sort -u > "$dir/$name.now"
  if [ -f "$dir/$name" ]; then LC_ALL=C comm -13 "$dir/$name" "$dir/$name.now"; fi
  mv -f "$dir/$name.now" "$dir/$name"; }
# FLAG CONDITION...: true once when CONDITION becomes true (FLAG remembers).
once() {
  flag="$dir/flag-$1"; shift
  if "$@"; then [ -f "$flag" ] && return 1; : > "$flag"; return 0; fi
  rm -f "$flag"; return 1; }
say_method() { case "$1" in publickey) echo 密钥 ;; password|keyboard-interactive) echo 密码 ;; console) echo 控制台 ;; *) echo 其他方式 ;; esac; }

# Started again since the last run.
boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
if [ -f "$dir/boot" ] && [ "$(cat "$dir/boot")" != "$boot" ]; then
  queue "开机了：上次检查在 $(when "$(cat "$dir/last-run" 2>/dev/null || echo 0)")，之后关机或重启过。"
fi
printf '%s\n' "$boot" > "$dir/boot"

# Logins, every run: from the login record (it knows first-time addresses
# and console logins), or from sshd's own lines.
if [ "$tg" = 1 ]; then
  if [ -s "$state/logins" ] || [ -f "$dir/login-last" ]; then
    # Read on from the last line handled, so a login in the same second as the
    # last run is not lost (by time only when that line was pruned); the first
    # time from the end of the record.
    if [ ! -f "$dir/login-last" ]; then
      tail -n 1 "$state/logins" > "$dir/login-last" 2>/dev/null; : > "$dir/logins.new"
    else
      awk -F'\t' -v L="$(cat "$dir/login-last")" -v out="$dir/login-last" '
        BEGIN {split(L, f, "\t"); t0 = f[1] + 0}
        NF == 6 {n++; line[n] = $0; ts[n] = $1; if ($0 == L) at = n}
        END {if (n) print line[n] > out
          for (i = 1; i <= n; i++) if ((at && i > at) || (!at && ts[i] > t0)) print line[i]}' "$state/logins" 2>/dev/null | tail -n 20 > "$dir/logins.new"
    fi
    while IFS="$tab" read -r t u from m _ n; do
      u="$(printf '%s' "$u" | clean 32)" from="$(printf '%s' "$from" | clean 64)"
      case "$from" in
        console:*) queue "服务商控制台登录：$u（${from#console:}，$(when "$t")）。不是你登录的，先改服务商面板的密码。" ;;
        *) if [ "$n" = 1 ]; then queue "登录：$u 来自 $from（$(say_method "$m")，$(when "$t")）
⚠ 第一次从这个 IP 登录。不是你自己的话：马上改密码、删掉不认识的公钥，再用 vps 选 7 安全排查。"
           else queue "登录：$u 来自 $from（$(say_method "$m")，$(when "$t")）"; fi ;;
      esac
    done < "$dir/logins.new"
  else
    journal_new logins -t sshd -t sshd-session | awk -F'\t' '{split($3, f, " "); if (f[1] == "Accepted" && f[3] == "for" && f[5] == "from") print f[4] "\t" f[6] "\t" f[2]}' |
      while IFS="$tab" read -r u from m; do
        queue "登录：$(printf '%s' "$u" | clean 32) 来自 $(printf '%s' "$from" | clean 64)（$(say_method "$m")）"
      done
  fi
fi

# Every 5 minutes: what was done on the machine and how it is.
five="$(cat "$dir/five" 2>/dev/null || echo 0)"
if [ "$tg" = 1 ] && [ $((now - five)) -ge 290 ]; then
  printf '%s\n' "$now" > "$dir/five"
  journal_new events -t useradd -t passwd -t chpasswd -t sudo -t kernel -t sshd -t sshd-session > "$dir/events"
  awk -F'\t' '$2 == "useradd" && $3 ~ /^new user: name=/ {s = $3; sub(/^new user: name=/, "", s); sub(/,.*/, "", s); print s}' "$dir/events" | sort -u |
    while read -r u; do queue "新建了账户：$(printf '%s' "$u" | clean 32)"; done
  awk -F'\t' '($2 == "passwd" || $2 == "chpasswd") && $3 ~ /password changed for/ {s = $3; sub(/.*password changed for /, "", s); sub(/ .*/, "", s); print s}' "$dir/events" | sort -u |
    while read -r u; do queue "改了密码：账户 $(printf '%s' "$u" | clean 32)"; done
  # sudo: the program only, unless asked for the whole command (it can hold a password).
  awk -F'\t' -v full="$(param notify_sudo_args no)" '$2 == "sudo" && index($3, "COMMAND=") {u = $3; sub(/ *:.*/, "", u); c = substr($3, index($3, "COMMAND=") + 8); if (full != "yes") sub(/ .*/, "", c); n[u " 运行了 " c]++}
    END {for (k in n) print k (n[k] > 1 ? "（" n[k] " 次）" : "")}' "$dir/events" | head -n 10 |
    while IFS= read -r line; do queue "sudo：$(printf '%s' "$line" | clean 200)"; done
  awk -F'\t' '$2 == "kernel" && $3 ~ /Out of memory: Killed process/ {s = $3; sub(/.*Killed process [0-9]+ \(/, "", s); sub(/\).*/, "", s); print s}' "$dir/events" | sort -u |
    while read -r p; do queue "内存不够：系统杀掉了进程 $(printf '%s' "$p" | clean 40)。"; done
  failed="$(awk -F'\t' '($2 == "sshd" || $2 == "sshd-session") && $3 ~ /^(Failed password|Invalid user)/' "$dir/events" | wc -l)"
  printf '%s\n' $(($(cat "$dir/failed" 2>/dev/null || echo 0) + failed)) > "$dir/failed"
  # Packages put on or taken off.
  size="$(stat -c %s /var/log/dpkg.log 2>/dev/null || echo 0)" off="$(cat "$dir/dpkg.off" 2>/dev/null || echo "$size")"
  [ "$size" -ge "$off" ] || off=0
  tail -c +$((off + 1)) /var/log/dpkg.log 2>/dev/null | awk '$3 == "install" || $3 == "remove" || $3 == "purge" {sub(/:.*/, "", $4); w[$3] = w[$3] " " $4}
    END {if (w["install"] != "") print "装了软件包：" substr(w["install"], 2); if (w["remove"] w["purge"] != "") print "删了软件包：" substr(w["remove"] w["purge"], 2)}' |
    while IFS= read -r line; do queue "$(printf '%s' "$line" | clean 300)"; done
  printf '%s\n' "$size" > "$dir/dpkg.off"
  # Keys that can log in, listening ports, things that start by themselves.
  keys() {
    getent passwd | while IFS=: read -r name _ uid _ _ home _; do
      [ "$name" = root ] || { [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 60000 ]; } || continue
      for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
        [ -f "$f" ] && ssh-keygen -l -f "$f" 2>/dev/null | awk -v a="$name" '$2 ~ /^SHA256:/ {c = $3; print a " " $2 " " c}'
      done
    done; }
  new_lines keys keys | while read -r a fp c; do queue "加了公钥：账户 $(printf '%s' "$a" | clean 32)，$fp（$(printf '%s' "$c" | clean 60)）"; done
  ports() { ss -H -tulpn | awk '$5 !~ /^(127\.|\[::1\]|::1)/ {n = split($5, a, ":"); match($0, /\("[^"]*"/); p = substr($0, RSTART + 2, RLENGTH - 3); print a[n] "/" $1 (p != "" ? "（" p "）" : "")}'; }
  new_lines ports ports | while read -r p; do queue "新开了端口：$(printf '%s' "$p" | clean 60)"; done
  autostart() {
    find /etc/systemd/system -maxdepth 2 \( -name '*.service' -o -name '*.timer' \) ! -name 'vps-stable-*' -printf '%p\n'
    find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs -maxdepth 1 -type f -printf '%p\n'; }
  new_lines autostart autostart | head -n 10 | while read -r p; do queue "新加了开机自启或定时任务：$(printf '%s' "$p" | clean 120)"; done
  # The CPU busy for 10 minutes and more (two checks in a row).
  set -- $(awk '$1 == "cpu" {print $2 + $3 + $4 + $6 + $7 + $8 + $9, $5}' /proc/stat)
  busy="$1" idle="$2"
  if read -r b0 i0 2>/dev/null < "$dir/cpu" && [ $((busy + idle - b0 - i0)) -gt 0 ]; then
    pct=$(((busy - b0) * 100 / (busy + idle - b0 - i0)))
    hot="$(cat "$dir/cpu-hot" 2>/dev/null || echo 0)"
    if [ "$pct" -ge 90 ]; then hot=$((hot + 1)); elif [ "$pct" -lt 70 ]; then hot=0; fi
    printf '%s\n' "$hot" > "$dir/cpu-hot"
    if once cpu [ "$hot" -ge 2 ]; then
      queue "CPU 已经连续 10 分钟以上被吃满（${pct}%）。最忙的进程：$(ps -eo comm=,pid= --sort=-pcpu | head -n 1 | clean 40)"
    fi
  fi
  printf '%s %s\n' "$busy" "$idle" > "$dir/cpu"
  # The system disk, memory, a reboot that updates wait for.
  limit="$(param notify_disk_percent 90)"
  disk="$(df -P / | awk 'NR == 2 {sub(/%/, "", $5); print $5}')"
  # Told once; again only after it went well below the line (no repeats while it hovers).
  if [ "${disk:-0}" -ge "$limit" ] && [ ! -f "$dir/flag-disk" ]; then
    : > "$dir/flag-disk"; queue "系统盘快满了：已用 ${disk}%。满了会出各种奇怪的错误，先清理日志、备份和不用的文件。"
  elif [ "${disk:-0}" -lt $((limit - 5)) ]; then rm -f "$dir/flag-disk"; fi
  mem="$(awk '$1 == "MemTotal:" {t = $2} $1 == "MemAvailable:" {a = $2} END {printf "%d", a * 100 / t}' /proc/meminfo)"
  if [ "${mem:-100}" -lt 5 ] && [ ! -f "$dir/flag-memory" ]; then
    : > "$dir/flag-memory"; queue "内存快不够了：只剩 ${mem}% 可用，再多一点就可能有进程被杀。"
  elif [ "${mem:-100}" -ge 15 ]; then rm -f "$dir/flag-memory"; fi
  if once reboot [ -f /var/run/reboot-required ]; then
    queue "有更新要重启才生效：$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | clean 120)。方便时 vps 选 8 重启。"
  fi
  # The services you named.
  for unit in $(param notify_services none); do
    [ "$unit" != none ] || continue
    unit="$(printf '%s' "$unit" | tr -cd 'A-Za-z0-9@._-')"
    st="$(systemctl is-active "$unit" 2>/dev/null)"
    was="$(cat "$dir/service-$unit" 2>/dev/null || echo "$st")"
    if [ "$was" = active ] && [ "$st" != active ]; then queue "服务停了：$unit（现在是 ${st:-unknown}）"; fi
    if [ "$was" != active ] && [ "$st" = active ]; then queue "服务恢复了：$unit"; fi
    printf '%s\n' "$st" > "$dir/service-$unit"
  done
fi

# Monthly traffic: the interface's counters added up between runs (they
# start again from 0 after a reboot); a new period starts on the reset day.
# MB and GB are decimal (10^6 and 10^9 bytes), as traffic is usually billed:
# where a provider counts in 2^30 instead, the alerts only come a little early.
if [ -s "$tconf" ]; then
  iface="$(setting iface "$tconf")" quota="$(setting quota_mb "$tconf")" day="$(setting reset_day "$tconf")" mode="$(setting mode "$tconf")"
  set -- $(awk -v i="$iface:" '$1 == i {print $2, $10}' /proc/net/dev)
  rx="${1:-0}" tx="${2:-0}"
  # This period's first day: the reset day of this month or of the month before.
  y="$(date +%Y)" m="$(date +%m)" d="$(date +%d)"
  last_day() { date -d "$1-$2-01 +1 month -1 day" +%d; }
  rd="$day"; [ "$rd" -le "$(last_day "$y" "$m")" ] || rd="$(last_day "$y" "$m")"
  if [ "${d#0}" -ge "$rd" ]; then period="$y-$m-$(printf '%02d' "$rd")"
  else
    py="$(date -d "$y-$m-01 -1 month" +%Y)" pm="$(date -d "$y-$m-01 -1 month" +%m)"
    rd="$day"; [ "$rd" -le "$(last_day "$py" "$pm")" ] || rd="$(last_day "$py" "$pm")"
    period="$py-$pm-$(printf '%02d' "$rd")"
  fi
  if read -r p0 lrx ltx arx atx 2>/dev/null < "$dir/traffic"; then
    drx=$((rx - lrx)) dtx=$((tx - ltx))
    [ "$drx" -ge 0 ] || drx="$rx"; [ "$dtx" -ge 0 ] || dtx="$tx"
    arx=$((arx + drx)) atx=$((atx + dtx))
    if [ "$p0" != "$period" ]; then
      queue "新的流量周期从 $period 开始；上个周期用了 $(cat "$dir/traffic-used" 2>/dev/null || echo '?') MB。"
      arx=0 atx=0; rm -f "$dir"/flag-traffic-*; sed -i '/^used_mb=/d' "$tconf"
    fi
  else p0="$period" arx=0 atx=0; fi
  printf '%s %s %s %s %s\n' "$period" "$rx" "$tx" "$arx" "$atx" > "$dir/traffic"
  case "$mode" in both) used=$((arx + atx)) ;; max) if [ "$arx" -gt "$atx" ]; then used="$arx"; else used="$atx"; fi ;; *) used="$atx" ;; esac
  base="$(setting used_mb "$tconf")"
  used=$((used / 1000000 + ${base:-0}))
  printf '%s\n' "$used" > "$dir/traffic-used"
  for p in $(param quota_alerts '80 90 100' | tr -cd '0-9 '); do
    if [ $((used * 100)) -ge $((quota * p)) ] && once "traffic-$p" true; then
      queue "流量提醒：这个周期（从 $period 起）已用 $used MB，到了额度 $quota MB 的 ${p}%。数字以服务商面板为准。"
    fi
  done
fi

# Once a day: the summary, with the failed logins (never sent one by one).
at="$(param notify_summary_time 09:00)"
today="$(date +%F)"
if [ "$tg" = 1 ] && [ "$(cat "$dir/summary-date" 2>/dev/null)" != "$today" ] && [[ ! "$(date +%H:%M)" < "$at" ]]; then
  if [ "$first" = 0 ] && [ -f "$dir/summary-date" ]; then
    logins="$(awk -F'\t' -v t=$((now - 86400)) 'NF == 6 && $1 > t {n++; ip[$3] = 1} END {c = 0; for (i in ip) c++; printf "%d 次（%d 个 IP）", n, c}' "$state/logins" 2>/dev/null)"
    bans="$(fail2ban-client get sshd banip 2>/dev/null | wc -w)"
    disk="$(df -P / | awk 'NR == 2 {print $5}')"
    mem="$(awk '$1 == "MemTotal:" {t = $2} $1 == "MemAvailable:" {a = $2} END {printf "%d%%", (t - a) * 100 / t}' /proc/meminfo)"
    line="每日汇总（过去 24 小时）
登录：${logins:-没有登录记录}
失败的登录：$(cat "$dir/failed" 2>/dev/null || echo 0) 次；Fail2ban 正在封禁 ${bans:-0} 个 IP
系统盘已用 $disk，内存已用 $mem，已运行 $(awk '{printf "%d", $1 / 86400}' /proc/uptime) 天"
    if [ -s "$dir/traffic-used" ]; then line="$line
本周期流量：$(cat "$dir/traffic-used") MB / $(setting quota_mb "$tconf") MB"; fi
    queue "$line"
  fi
  printf '0\n' > "$dir/failed"
  printf '%s\n' "$today" > "$dir/summary-date"
fi

send_queue
printf '%s\n' "$now" > "$dir/last-run"
exit 0
CHECK
}

check_service_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.8: the notification and traffic check' '[Unit]' 'Description=VPS Stable Optimizer check' '[Service]' 'Type=oneshot' \
    "ExecStart=/usr/bin/timeout 50 /bin/bash $STATE_ROOT/notify-check" 'Nice=10' 'IOSchedulingClass=idle' \
    '# It runs every minute or five: nothing of it in the journal.' 'LogLevelMax=notice'
}

# MINUTES: how often.
check_timer_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.8: the notification and traffic check' '[Unit]' 'Description=VPS Stable Optimizer check' '[Timer]' \
    "OnCalendar=*:0/$1" 'AccuracySec=5s' '[Install]' 'WantedBy=timers.target'
}

# ID PATH TEXT: this tool's file written (again when its text changed); one
# that is not this tool's stays.
check_file_write() {
  if [[ -f "$2" && "$(cat -- "$2" 2>/dev/null || true)" != "$3" ]] && restore_file_ours "$1"; then rm -f -- "$2"; fi
  put_file "$2" "$3"
}

# The timer as TG and the traffic alert need it now: on (every minute with
# TG, else every 5), or taken away.
check_reconcile() {
  local interval=5 id
  if [[ ! -s "$STATE_ROOT/notify.conf" && ! -s "$STATE_ROOT/quota.conf" ]]; then check_remove; return; fi
  [[ ! -s "$STATE_ROOT/notify.conf" ]] || interval=1
  check_file_write check_script_file "$STATE_ROOT/notify-check" "$(notify_check_text)" || return 1
  chmod 600 -- "$STATE_ROOT/notify-check" || true
  check_file_write check_service_file "$CHECK_SERVICE_FILE" "$(check_service_text)" || return 1
  check_file_write check_timer_file "$CHECK_TIMER_FILE" "$(check_timer_text "$interval")" || return 1
  systemctl daemon-reload || true
  if ! systemctl enable --now vps-stable-check.timer >/dev/null 2>&1; then warn '检查定时任务没能启动。'; return 1; fi
  # Changed outside a stage (an item turned off): still this tool's own.
  if [[ -z "${RESTORE_STAGE:-}" ]]; then
    for id in check_timer check_service_file check_timer_file check_script_file; do restore_adopt "$id" || true; done
  fi
}

check_remove() {
  local file id
  if [[ "$(systemctl is-enabled vps-stable-check.timer 2>/dev/null || true)" == enabled ]] || systemctl is-active -q vps-stable-check.timer 2>/dev/null; then
    systemctl disable --now vps-stable-check.timer >/dev/null 2>&1 || warn '检查定时任务没能停下。'
  fi
  for file in "$CHECK_TIMER_FILE" "$CHECK_SERVICE_FILE" "$STATE_ROOT/notify-check"; do
    [[ -f "$file" ]] || continue
    case "$(cat -- "$file")" in
      "$(check_timer_text 1)"|"$(check_timer_text 5)"|"$(check_service_text)"|"$(notify_check_text)") rm -f -- "$file" ;;
      *) warn "$file 被改过，保持不变。" ;;
    esac
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf --one-file-system -- "${STATE_ROOT:?}/notify"
  if [[ -z "${RESTORE_STAGE:-}" ]]; then
    for id in check_timer check_service_file check_timer_file check_script_file; do restore_adopt "$id" || true; done
  fi
}

# API TOKEN METHOD [CURL ARGS...]: a call to the Bot API; the token reaches
# curl through stdin, never on its command line (other users could read it).
tg_call() {
  local api="$1" token="$2" method="$3"
  shift 3
  printf 'url = "%s/bot%s/%s"\n' "$api" "$token" "$method" | curl -fsS --max-time 15 -K - "$@"
}

notify_stage() {
  say 'TG 通知'
  local token chat updates api="${VPS_TG_API:-https://api.telegram.org}" conf="$STATE_ROOT/notify.conf" temp
  if [[ "${NOTIFY_CHOICE:-}" != 1 ]]; then ok '按你的选择不开启 TG 通知。'; module_result notify declined 'not requested'; return 0; fi
  if ! command -v curl >/dev/null; then warn '没有 curl，发不了 TG 消息：先在单项设置里装常用工具。'; module_result notify unsupported 'no curl'; return 0; fi
  if [[ -s "$conf" ]] && ! confirm_yes '已经设置过 TG 通知：要换一个机器人或者聊天吗？'; then
    check_reconcile && { ok 'TG 通知保持原来的设置。'; module_result notify applied 'telegram'; }; return 0
  fi
  echo '1. 在 Telegram 里找 @BotFather，发 /newbot，按提示起名字，最后它会给你一串 Token（像 123456789:AA…）。'
  echo '2. 打开你的新机器人，随便发一句话给它（这样它才能给你发消息）。'
  echo '只发通知，不接收命令；多台机器可以用同一个机器人，每条消息都带显示名和 IP。'
  read -r -s -p 'Bot Token（输入时不显示，直接回车取消）: ' token || token=''
  echo
  if [[ -z "$token" ]]; then ok '已取消。'; module_result notify declined 'cancelled'; return 0; fi
  if [[ ! "$token" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,64}$ ]]; then warn 'Token 的格式不对（应该像 123456789:AA… 这样）。'; module_result notify failed 'bad token'; return 0; fi
  read -r -p '给机器人发过一句话了吗？发好了按回车: ' _ || true
  updates="$(tg_call "$api" "$token" getUpdates 2>/dev/null || true)"
  chat="$(tr -d ' \n\t' <<< "$updates" | grep -o '"chat":{"id":-\{0,1\}[0-9]\{1,20\}' | tail -n 1 | grep -o -- '-\{0,1\}[0-9]*$' || true)"
  if [[ -z "$chat" ]]; then
    warn '没找到你发给机器人的消息（Token 不对，或者还没发）。'
    read -r -p '直接输入 chat id（不知道就回车取消）: ' chat || chat=''
  fi
  if [[ ! "$chat" =~ ^-?[0-9]{1,20}$ ]]; then ok '已取消。'; module_result notify declined 'no chat'; return 0; fi
  if ! tg_call "$api" "$token" sendMessage -o /dev/null --data-urlencode "chat_id=$chat" \
       --data-urlencode "text=【$(display_name_get || hostname -s) · $(menu_ip)】TG 通知已开启：以后登录、重要操作和异常会发到这里。" 2>/dev/null; then
    warn '测试消息没发出去：检查 Token、网络（这台机器能不能连上 api.telegram.org）。'; module_result notify failed 'test message failed'; return 0
  fi
  temp="$(mktemp "$STATE_ROOT/.notify.XXXXXX")" || return 0
  if ! printf 'token=%s\nchat=%s\napi=%s\nip=%s\n' "$token" "$chat" "$api" "$(menu_ip)" > "$temp" || ! chmod 600 -- "$temp" || ! mv -f -- "$temp" "$conf"; then
    rm -f -- "$temp"; warn '没能保存 TG 的设置。'; module_result notify failed 'config not written'; return 0
  fi
  if check_reconcile; then
    ok '测试消息已发出，TG 通知已开启（每分钟检查一次）。Token 只有 root 能读；万一泄露，在 @BotFather 里发 /revoke 作废它，再回这里重新开启。'
    module_result notify applied 'telegram'
  else module_result notify failed 'check timer'; fi
}

quota_stage() {
  say '月流量提醒'
  local iface quota day mode used temp conf="$STATE_ROOT/quota.conf"
  if [[ "${QUOTA_CHOICE:-}" != 1 ]]; then ok '按你的选择不开启流量提醒。'; module_result quota declined 'not requested'; return 0; fi
  iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' || true)"
  if [[ ! "$iface" =~ ^[A-Za-z0-9._-]+$ ]] || ! grep -q "^ *$iface:" /proc/net/dev; then warn '找不到上网用的网卡，不能统计流量。'; module_result quota unsupported 'no interface'; return 0; fi
  echo "统计网卡 $iface 的流量（每 5 分钟累计一次，重启后接着算）。只提醒，不断网；数字以服务商面板为准。"
  read -r -p '每月流量额度（GB，例如 1000）: ' quota || return 0
  if [[ ! "$quota" =~ ^[0-9]{1,7}$ ]] || ((10#$quota < 1)); then warn '额度要写整数（GB）。'; module_result quota declined 'bad quota'; return 0; fi
  read -r -p '每月几号重置（1–31，月份没这一天就算最后一天）: ' day || return 0
  if [[ ! "$day" =~ ^[0-9]{1,2}$ ]] || ((10#$day < 1 || 10#$day > 31)); then warn '重置日要写 1 到 31。'; module_result quota declined 'bad day'; return 0; fi
  read -r -p '计费方式：1) 只算出站   2) 进出都算   3) 进、出取大的那个 [1]: ' mode || mode=1
  case "${mode:-1}" in 1) mode=out ;; 2) mode=both ;; 3) mode=max ;; *) warn '只能选 1、2、3。'; module_result quota declined 'bad mode'; return 0 ;; esac
  read -r -p '这个周期已经用了多少 GB（看服务商面板，不知道就回车）: ' used || used=''
  if [[ -n "$used" ]]; then
    [[ "$used" =~ ^[0-9]{1,7}(\.[0-9]{1,2})?$ ]] || { warn '已用量要写数字（GB）。'; module_result quota declined 'bad used'; return 0; }
    used="$(awk -v g="$used" 'BEGIN {printf "%d", g * 1000}')"
  fi
  temp="$(mktemp "$STATE_ROOT/.quota.XXXXXX")" || return 0
  if ! printf 'iface=%s\nquota_mb=%s\nreset_day=%s\nmode=%s\nused_mb=%s\n' "$iface" "$((10#$quota * 1000))" "$((10#$day))" "$mode" "${used:-0}" > "$temp" ||
     ! chmod 600 -- "$temp" || ! mv -f -- "$temp" "$conf"; then
    rm -f -- "$temp"; warn '没能保存流量提醒的设置。'; module_result quota failed 'config not written'; return 0
  fi
  # A new setting: counted again from this period.
  rm -f -- "$STATE_ROOT/notify/traffic" "$STATE_ROOT/notify/traffic-used" "$STATE_ROOT"/notify/flag-traffic-*
  if check_reconcile; then
    ok "流量提醒已开启：额度 ${quota} GB、每月 ${day} 号重置，到 $(param_value quota_alerts | sed 's/ /%、/g')% 时提醒$(if [[ -s "$STATE_ROOT/notify.conf" ]]; then echo '（发到 TG，菜单顶部也显示）'; else echo '（显示在菜单顶部；开了 TG 通知还会发到 TG）'; fi)。"
    module_result quota applied "$quota GB"
  else module_result quota failed 'check timer'; fi
}

# This period's use, "USED QUOTA" in MB, when the alert is on; nothing (and
# no failure: it is read through < <(...), where the error trap would report a
# function that returns 1) when not.
quota_status() {
  [[ -s "$STATE_ROOT/quota.conf" && -s "$STATE_ROOT/notify/traffic-used" ]] || return 0
  printf '%s %s\n' "$(cat -- "$STATE_ROOT/notify/traffic-used")" "$(sed -n 's/^quota_mb=//p' "$STATE_ROOT/quota.conf")"
}

# The menu's yellow line: past the lowest alert.
menu_quota_alert() {
  local used quota low
  read -r used quota < <(quota_status 2>/dev/null) || return 0
  [[ "$used" =~ ^[0-9]+$ && "$quota" =~ ^[1-9][0-9]*$ ]] || return 0
  low="$(param_value quota_alerts 2>/dev/null | tr ' ' '\n' | sort -n | head -n 1)"
  ((used * 100 >= quota * ${low:-80})) || return 0
  printf '%s%s 这个周期的流量已用 %s GB，是额度 %s GB 的 %s%%（数字以服务商面板为准）。%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" \
    "$((used / 1000))" "$((quota / 1000))" "$((used * 100 / quota))" "${C_RESET-}"
}

# Docker's default keeps every line a container writes: a size per log file
# and a number of files, for containers made from now on.
dockerlog_text() {
  printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "%sm",\n    "max-file": "%s"\n  }\n}\n' "$(param_value docker_log_max_mb)" "$(param_value docker_log_files)"
}

dockerlog_stage() {
  say 'Docker 容器日志上限'
  local mb files current file name size total=0
  if [[ "${DOCKERLOG_CHOICE:-}" != 1 ]]; then module_result dockerlog declined 'not requested'; return 0; fi
  if ! command -v dockerd >/dev/null; then ok '没有装 Docker，不需要。'; module_result dockerlog skipped 'no docker'; return 0; fi
  mb="$(param_value docker_log_max_mb)" files="$(param_value docker_log_files)"
  echo '各容器的日志现在有多大：'
  for file in /var/lib/docker/containers/*/*-json.log; do
    [[ -f "$file" ]] || continue
    name="$(sed -n 's/.*"Name":"\/\([^"]*\)".*/\1/p' "${file%/*}/config.v2.json" 2>/dev/null | head -n 1 | audit_clean_text | cut -c1-40)"
    size="$(stat -c %s -- "$file")"; total=$((total + size))
    printf '  %s：%s MiB\n' "${name:-${file%/*}}" "$((size / 1048576))"
  done
  printf '  合计 %s MiB\n' "$((total / 1048576))"
  if [[ -e "$DOCKER_DAEMON_FILE" || -L "$DOCKER_DAEMON_FILE" ]]; then
    current="$(cat -- "$DOCKER_DAEMON_FILE" 2>/dev/null || true)"
    if restore_file_ours dockerlog_file || [[ "$current" == "$(dockerlog_text)" ]]; then
      dockerlog_merge || { module_result dockerlog failed 'daemon.json not written'; return 0; }
    elif grep -Eq '"log-(driver|opts)"' <<< "$current"; then
      ok "$DOCKER_DAEMON_FILE 里已经有日志设置，保持不变。"; module_result dockerlog preserved 'own log settings'; return 0
    else
      dockerlog_merge || { module_result dockerlog preserved 'daemon.json not merged'; return 0; }
    fi
  else
    put_file "$DOCKER_DAEMON_FILE" "$(dockerlog_text)" || { module_result dockerlog preserved 'daemon.json conflict'; return 0; }
  fi
  # grep reads all of the help: with -q it would stop early, and under pipefail
  # dockerd's SIGPIPE would read as "no --validate".
  if dockerd --help 2>&1 | grep -- '--validate' > /dev/null && ! dockerd --validate --config-file "$DOCKER_DAEMON_FILE" >/dev/null 2>&1; then
    warn "Docker 不认这个配置，已经撤回：$DOCKER_DAEMON_FILE。"
    restore_resource dockerlog_file || true
    module_result dockerlog failed 'dockerd --validate'; return 0
  fi
  ok "已设置：每个容器的日志文件最多 ${mb} MiB、留 ${files} 个。"
  echo '只对新建的容器生效：已有的容器要重建才会用上（docker compose up -d --force-recreate，或者删掉再 docker run）。'
  if active docker && confirm_yes '现在重启 Docker 让设置生效吗？（所有容器会停一下；设了 restart 策略的会自动起来）'; then
    if systemctl restart docker; then ok 'Docker 已重启。'; else warn 'Docker 重启失败，请看 systemctl status docker。'; fi
  else echo 'Docker 下次重启（或者重启服务器）后生效。'; fi
  module_result dockerlog applied "${mb}m x $files"
}

# Writes the two log settings into daemon.json, keeping everything else in it
# (python3 reads and writes the JSON; without it an existing file stays).
dockerlog_merge() {
  local temp
  if [[ ! -s "$DOCKER_DAEMON_FILE" ]]; then
    rm -f -- "$DOCKER_DAEMON_FILE"; put_file "$DOCKER_DAEMON_FILE" "$(dockerlog_text)"; return
  fi
  if ! command -v python3 >/dev/null; then warn "没有 python3，不能安全地改 $DOCKER_DAEMON_FILE，保持不变。"; return 1; fi
  backup_config_path "$DOCKER_DAEMON_FILE" || return 1
  temp="$(mktemp "$DOCKER_DAEMON_FILE.tmp.XXXXXX")" || return 1
  if ! python3 -I -c 'import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d["log-driver"] = "json-file"
d["log-opts"] = {"max-size": sys.argv[2] + "m", "max-file": sys.argv[3]}
with open(sys.argv[4], "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")' "$DOCKER_DAEMON_FILE" "$(param_value docker_log_max_mb)" "$(param_value docker_log_files)" "$temp" 2>/dev/null; then
    rm -f -- "$temp"; warn "$DOCKER_DAEMON_FILE 不是有效的 JSON，保持不变。"; return 1
  fi
  chmod 644 -- "$temp" && mv -f -- "$temp" "$DOCKER_DAEMON_FILE"
}

# Security audit (vps audit, menu 7): read-only. Six parts, each line ✔, ⚠ or
# ✖; a deep check of every package's files only when asked. What the user marks
# as normal ("KIND VALUE" lines in STATE_ROOT/known: ip, key, exe, file; the
# login note reads the ip lines too) is not reported again.
AUDIT_MARKS=()
AUDIT_IPS=()
AUDIT_CONFIGS=()
AUDIT_OWNED=''

audit_known() {
  [[ -f "$STATE_ROOT/known" && ! -L "$STATE_ROOT/known" ]] && grep -Fxq -- "$1 $2" "$STATE_ROOT/known"
}

# STATUS LABEL TEXT [KIND VALUE]: a line of the report; with KIND, one that can
# be marked as normal.
audit_flag() {
  verify_line "$1" "$2" "$3"
  if [[ -n "${4:-}" && "$1" != healthy ]]; then AUDIT_MARKS+=("$4"$'\t'"$5"$'\t'"$2：$3"); fi
}

audit_heading() {
  printf '\n%s%s%s\n' "${C_BOLD-}" "$1" "${C_RESET-}"
}

# Every path a package owns, /bin and /usr/bin alike (merged /usr), sorted.
audit_owned_paths() {
  cat /var/lib/dpkg/info/*.list 2>/dev/null | sed -E 's#^/(bin|sbin|lib|lib32|lib64|libx32)/#/usr/\1/#' | LC_ALL=C sort -u
}

# PATH...: the ones no package owns (against AUDIT_OWNED).
audit_unowned() {
  (($#)) || return 0
  printf '%s\n' "$@" | sed -E 's#^/(bin|sbin|lib|lib32|lib64|libx32)/#/usr/\1/#' | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$AUDIT_OWNED"
}

audit_when() {
  date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || echo '?'
}

# 1. Who logged in during the last 30 days: from the login record (or, without
# it, what the journal still has).
audit_logins() {
  local now lines source kind ip count last users methods new known=0 failed banned
  audit_heading '一、谁登录过（最近 30 天）'
  now="$(date +%s)"
  if [[ -s "$STATE_ROOT/logins" ]]; then
    lines="$(login_recent 20000 | awk -F'\t' -v cut=$((now - 2592000)) '$1 >= cut')" source='登录记录'
  else
    lines="$(journalctl -q --since=-30d _UID=0 -t sshd -t sshd-session -o short-unix --no-pager 2>/dev/null |
      awk '$4 == "Accepted" && $6 == "for" && $8 == "from" {sub(/\..*/, "", $1); print $1 "\t" $7 "\t" $9 "\t" $5 "\tssh\t0"}' || true)"
    source='系统日志（登录记录没开，只查得到日志还在的部分）'
  fi
  if [[ -z "$lines" ]]; then verify_line healthy '登录' "最近 30 天没有登录（来源：$source）"
  else
    while IFS=$'\t' read -r kind ip count last users methods new; do
      if [[ "$kind" == console ]]; then
        audit_flag notice '服务商控制台' "登录过 ${count} 次（${users}），最后一次 $(audit_when "$last")：不是你登录的，说明服务商面板的账户可能泄露了，先改面板密码"
        continue
      fi
      ((${#AUDIT_IPS[@]} >= 20)) || AUDIT_IPS+=("$ip")
      if [[ "$new" == 1 ]] && ! audit_known ip "$ip"; then
        audit_flag notice "IP $ip" "最近 30 天第一次出现，登录 ${count} 次（${users}，${methods}），最后一次 $(audit_when "$last")" ip "$ip"
      else known=$((known + 1)); fi
    done < <(awk -F'\t' '
      $5 == "ssh" {ip = $3; c[ip]++; if ($1 > l[ip]) l[ip] = $1
        if (index(" " u[ip] " ", " " $2 " ") == 0) u[ip] = u[ip] " " $2
        if (index(" " m[ip] " ", " " $4 " ") == 0) m[ip] = m[ip] " " $4
        if ($6 == 1) n[ip] = 1}
      $5 == "console" {cc++; if ($1 > cl) cl = $1; if (index(" " cu " ", " " $2 " ") == 0) cu = cu " " $2}
      END {for (ip in c) print "ssh\t" ip "\t" c[ip] "\t" l[ip] "\t" substr(u[ip], 2) "\t" substr(m[ip], 2) "\t" (n[ip] + 0)
        if (cc) print "console\t-\t" cc "\t" cl "\t" substr(cu, 2) "\t-\t0"}' <<< "$lines" |
      sed 's/publickey/密钥/g; s/keyboard-interactive/密码/g; s/password/密码/g')
    if ((known)); then verify_line healthy '登录' "${known} 个 IP 以前就登录过或标记过正常（来源：$source）"; fi
  fi
  failed="$(journalctl -q --since=-24h _UID=0 -t sshd -t sshd-session -o cat --no-pager 2>/dev/null | grep -cE '^(Failed password|Invalid user|Connection closed by authenticating user)' || true)"
  banned="$(fail2ban-client get sshd banip 2>/dev/null | wc -w || true)"
  verify_line healthy '失败的登录' "过去 24 小时 ${failed:-0} 次（扫描密码的程序一直都有）；Fail2ban 正在封禁 ${banned:-0} 个 IP"
}

# 2. Accounts and keys.
audit_accounts_keys() {
  local raw name uid shell home uid0_names='' can='' state file line fp rest days created changed sudoers
  audit_heading '二、账户和公钥'
  raw="$(getent passwd 2>/dev/null)" || { verify_line unknown '账户' '读不到账户列表'; return 0; }
  while IFS=: read -r name _ uid _ _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    name="$(audit_clean_text <<< "$name")"
    if ((uid == 0)) && [[ "$name" != root ]]; then uid0_names+=" $name"; fi
    case "$shell" in */nologin|*/false|'') continue ;; esac
    ((uid == 0 || (uid >= 1000 && uid < 60000))) || continue
    can+=" $name"
    state="$(audit_passwd_state <<< "$(passwd -S "$name" 2>/dev/null)" 2>/dev/null || true)"
    if [[ "$state" == NP ]]; then audit_flag suspect "账户 $name" '没有密码（空密码）：谁都能用它登录控制台，马上用 passwd 设置密码'; fi
    for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      days=$((($(date +%s) - $(stat -c %Y -- "$file")) / 86400))
      while read -r _ fp rest; do
        [[ "$fp" == SHA256:* ]] || continue
        rest="$(audit_clean_text <<< "$rest" | cut -c1-80)"
        if audit_known key "$fp"; then continue; fi
        audit_flag notice "账户 $name 的公钥" "$fp（$rest）$(if ((days < 7)); then echo "，这个文件 ${days} 天内改过"; fi)：确认是你自己的；不认识的就在 $file 里删掉那一行" key "$fp"
      done < <(ssh-keygen -l -f "$file" 2>/dev/null || true)
    done
  done <<< "$raw"
  if [[ -n "$uid0_names" ]]; then audit_flag suspect 'UID 0 账户' "除了 root 还有：${uid0_names# }。这样的账户和 root 权限一样，不是你建的就是被人留了后门"; fi
  verify_line healthy '能登录的账户' "${can# }"
  created="$(journalctl -q --since=-30d -t useradd -o cat --no-pager 2>/dev/null | sed -n 's/^new user: name=\([^,]*\),.*/\1/p' | audit_clean_text | sort -u | tr '\n' ' ' || true)"
  if [[ -n "${created// /}" ]]; then audit_flag notice '新建的账户' "最近 30 天：${created% }。不是你建的要查一下"; fi
  changed="$(journalctl -q --since=-30d -t passwd -t chpasswd -o cat --no-pager 2>/dev/null | sed -n 's/.*password changed for \([^ ]*\).*/\1/p' | audit_clean_text | sort -u | tr '\n' ' ' || true)"
  if [[ -n "${changed// /}" ]]; then audit_flag notice '改过密码的账户' "最近 30 天：${changed% }。不是你改的要查一下"; fi
  for sudoers in /etc/sudoers /etc/sudoers.d/*; do
    [[ -f "$sudoers" && ! -L "$sudoers" ]] || continue
    line="$(grep -E '^[^#]*NOPASSWD' "$sudoers" 2>/dev/null | head -n 1 | audit_clean_text | cut -c1-80 || true)"
    if [[ -n "$line" ]] && ! audit_known file "$sudoers"; then
      audit_flag notice 'sudo 免密码' "$sudoers：$line（云镜像常给默认账户这样设；不认识的账户要查）" file "$sudoers"
    fi
  done
}

# 3. Software: new packages, and programs that belong to no package.
audit_software() {
  local cutoff list ours='' others_pkgs='' pkg file
  local -a audit_files=()
  audit_heading '三、装过什么'
  cutoff="$(date -d '30 days ago' +%F)"
  list="$(cat /var/log/dpkg.log.1 /var/log/dpkg.log 2>/dev/null | awk -v c="$cutoff" '$3 == "install" && $1 >= c {sub(/:.*/, "", $4); print $4}' | sort -u || true)"
  for pkg in $list; do
    if [[ -f "$STATE_ROOT/restore-v2/packages/installed" ]] && grep -Fxq -- "$pkg" "$STATE_ROOT/restore-v2/packages/installed"; then ours+=" $pkg"
    else others_pkgs+=" $pkg"; fi
  done
  if [[ -n "$others_pkgs" ]]; then audit_flag notice '新装的软件包' "最近 30 天（不算本工具装的）：$(cut -c2-400 <<< "$others_pkgs")"
  else verify_line healthy '新装的软件包' "最近 30 天只有本工具装的${ours:+：${ours# }}"; fi
  # Somebody's own programs (xray and the like) and programs in system directories
  # that no package owns.
  mapfile -t audit_files < <(find /usr/local/bin /usr/local/sbin /opt -maxdepth 3 -type f -perm /111 2>/dev/null | grep -vx /usr/local/bin/vps | head -n 50)
  for file in "${audit_files[@]}"; do
    audit_known file "$file" || audit_flag notice '自己装的程序' "$(audit_clean_text <<< "$file")：是你装的就标记为正常" file "$file"
  done
  mapfile -t audit_files < <(find /usr/bin /usr/sbin -maxdepth 1 -type f 2>/dev/null)
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    audit_known file "$file" || audit_flag suspect '系统目录里的程序' "$(audit_clean_text <<< "$file") 不属于任何软件包：系统命令被换掉或藏了程序时会这样" file "$file"
  done < <(audit_unowned "${audit_files[@]}" | head -n 30)
  mapfile -t audit_files < <(find /tmp /var/tmp /dev/shm -xdev -maxdepth 4 -type f -perm /111 2>/dev/null | head -n 30)
  for file in "${audit_files[@]}"; do
    audit_known file "$file" || audit_flag suspect '临时目录里的程序' "$(audit_clean_text <<< "$file")：恶意程序常放在这里" file "$file"
  done
}

# 4. What runs: deleted or temporary programs, programs of no package, CPU hogs.
audit_running() {
  local own d exe comm pid pcpu secs ports base
  local -A seen_exe=()
  local -a plain=()
  audit_heading '四、正在运行什么'
  own="$(readlink /proc/1/ns/mnt 2>/dev/null || true)"
  for d in /proc/[0-9]*; do
    # Containers have programs of their own: only this system's processes.
    [[ "$(readlink "$d/ns/mnt" 2>/dev/null || true)" == "$own" ]] || continue
    exe="$(readlink "$d/exe" 2>/dev/null)" || continue
    [[ -n "${seen_exe[$exe]:-}" ]] && continue
    seen_exe[$exe]=1
    comm="$(audit_clean_text < "$d/comm" 2>/dev/null || true)" pid="${d#/proc/}"
    if [[ "$exe" == *' (deleted)' ]]; then
      base="${exe% (deleted)}"
      if [[ -e "$base" ]]; then verify_line notice "进程 $comm" "$(audit_clean_text <<< "$base") 已被换成新文件（多半是升级后这个服务还没重启；重启服务器就好）"
      else audit_flag suspect "进程 $comm（$pid）" "程序文件 $(audit_clean_text <<< "$base") 已被删掉，进程还在运行：恶意程序常这样藏起来" exe "$base"; fi
      continue
    fi
    case "$exe" in
      /tmp/*|/var/tmp/*|/dev/shm/*) audit_known exe "$exe" || audit_flag suspect "进程 $comm（$pid）" "从临时目录运行：$(audit_clean_text <<< "$exe")" exe "$exe"; continue ;;
    esac
    plain+=("$exe")
  done
  while IFS= read -r exe; do
    [[ -n "$exe" ]] || continue
    audit_known exe "$exe" || audit_flag notice '不属于软件包的程序在运行' "$(audit_clean_text <<< "$exe")：是你装的就标记为正常" exe "$exe"
  done < <(audit_unowned "${plain[@]}" | head -n 30)
  while read -r pid pcpu secs comm; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || echo "$comm")"
    audit_known exe "$exe" && continue
    audit_flag notice "进程 $(audit_clean_text <<< "$comm")（$pid）" "运行 $((secs / 60)) 分钟，平均占 ${pcpu}% CPU：一直吃满 CPU 的陌生程序多半是挖矿的" exe "$exe"
  done < <(ps -eo pid=,pcpu=,etimes=,comm= 2>/dev/null | awk '$2 >= 80 && $3 >= 600' | head -n 5)
  ports="$(ss -H -tulpn 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\]|::1)/ {n = split($5, a, ":"); p = a[n]; match($0, /\("[^"]*"/); prog = substr($0, RSTART + 2, RLENGTH - 3); k = p "/" $1 (prog != "" ? "(" prog ")" : ""); if (!(k in s)) {s[k] = 1; printf "%s ", k}}' || true)"
  verify_line healthy '对外监听的端口' "$(if [[ -n "${ports// /}" ]]; then echo "${ports% }"; else echo 没有; fi)"
}

# 5. What starts by itself: units and cron jobs of no package, preload.
audit_autostart() {
  local file line
  local -a audit_files=()
  audit_heading '五、开机自启和定时任务'
  mapfile -t audit_files < <(find /etc/systemd/system /usr/local/lib/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.path' \) ! -name 'vps-stable-*' 2>/dev/null)
  for file in "${audit_files[@]}"; do
    audit_known file "$file" && continue
    line="$(grep -m1 -E '^(ExecStart|OnCalendar|OnBootSec|ListenStream)=' "$file" 2>/dev/null | audit_clean_text | cut -c1-100 || true)"
    audit_flag notice '自己加的服务' "$(audit_clean_text <<< "$file")（${line:-没有 ExecStart}）：是你装的就标记为正常" file "$file"
  done
  mapfile -t audit_files < <(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -maxdepth 1 -type f ! -name .placeholder 2>/dev/null)
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    audit_known file "$file" || audit_flag notice '定时任务' "$(audit_clean_text <<< "$file") 不属于任何软件包：是你加的就标记为正常" file "$file"
  done < <(audit_unowned "${audit_files[@]}")
  for file in /var/spool/cron/crontabs/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    audit_known file "$file" && continue
    line="$(grep -m1 -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null | audit_clean_text | cut -c1-100 || true)"
    audit_flag notice "账户 ${file##*/} 的定时任务" "${line:-（空）}：是你加的就标记为正常" file "$file"
  done
  if [[ -s /etc/ld.so.preload ]]; then
    audit_flag suspect '/etc/ld.so.preload' "让每个程序先加载：$(head -n 3 /etc/ld.so.preload | audit_clean_text | tr '\n' ' ')。正常系统没有这个文件，隐藏自己的恶意程序常用它"
  fi
  if [[ -x /etc/rc.local ]] && ! audit_known file /etc/rc.local; then audit_flag notice '/etc/rc.local' '开机会运行它：确认里面的命令是你写的' file /etc/rc.local; fi
  mapfile -t audit_files < <(find /etc/profile.d -maxdepth 1 -type f ! -name zz-vps-stable-login.sh 2>/dev/null)
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    audit_known file "$file" || audit_flag notice '登录时运行的脚本' "$(audit_clean_text <<< "$file") 不属于任何软件包：每次登录都会运行，确认是你加的" file "$file"
  done < <(audit_unowned "${audit_files[@]}")
  verify_line healthy '检查过的位置' 'systemd 服务、cron、各账户的 crontab、ld.so.preload、rc.local、profile.d'
}

# 6. System files against the checksums of their packages: the programs a
# break-in replaces first (quick), or every package (deep). Changed
# configuration files are only listed (usually you or this tool changed them).
audit_integrity() {
  local -a pkgs=() changed_files=() missing_files=()
  local pkg flags rest
  if [[ "$1" == all ]]; then audit_heading '六（深度）、所有软件包的文件'
  else
    audit_heading '六、系统文件有没有被换过（关键软件包）'
    for pkg in openssh-server openssh-client sudo passwd login util-linux coreutils procps bash systemd libpam-modules libpam-runtime cron iproute2 findutils; do
      installed "$pkg" && pkgs+=("$pkg")
    done
  fi
  while read -r flags rest; do
    case "$flags" in
      missing) missing_files+=("${rest#c }") ;;
      ??5*)
        if [[ "$rest" == 'c '* ]]; then AUDIT_CONFIGS+=("${rest#c }")
        else changed_files+=("$rest"); fi ;;
    esac
  done < <(dpkg --verify "${pkgs[@]}" 2>/dev/null | audit_clean_text || true)
  for rest in "${changed_files[@]}"; do
    audit_known file "$rest" || audit_flag suspect '被改过的系统文件' "$rest 和软件包里的不一样：系统程序被替换时会这样（重装那个软件包能换回来）" file "$rest"
  done
  if ((${#missing_files[@]})); then verify_line notice '缺少的文件' "$(printf '%s ' "${missing_files[@]:0:5}")$(if ((${#missing_files[@]} > 5)); then echo "等 ${#missing_files[@]} 个"; fi)"; fi
  if ((${#changed_files[@]} == 0)); then
    if [[ "$1" == all ]]; then verify_line healthy '软件包的文件' '所有软件包的程序都和安装时一样'
    else verify_line healthy '关键程序' "${#pkgs[@]} 个关键软件包的程序都和安装时一样"; fi
  fi
}

audit_sections() {
  audit_logins
  audit_accounts_keys
  audit_software
  audit_running
  audit_autostart
  audit_integrity quick
}

# Numbers to mark as normal; u lists what is marked and takes some back.
audit_mark_menu() {
  local answer n entry kind value i known="$STATE_ROOT/known"
  local -a lines=()
  if ((${#AUDIT_MARKS[@]})); then
    echo
    echo '可以标记为正常的（标记后不再提醒，确认是你自己的再标）：'
    for i in "${!AUDIT_MARKS[@]}"; do printf '  %s. %s\n' "$((i + 1))" "$(cut -f3- <<< "${AUDIT_MARKS[i]}")"; done
  fi
  [[ -s "$known" ]] && echo '  u. 查看已标记的，取消其中几项'
  ((${#AUDIT_MARKS[@]})) || [[ -s "$known" ]] || return 0
  read -r -p '要标记哪几项？输入编号（多个用空格隔开，a 是全部），直接回车跳过: ' answer || return 0
  if [[ "$answer" == u ]]; then
    mapfile -t lines < "$known"
    for i in "${!lines[@]}"; do printf '  %s. %s\n' "$((i + 1))" "$(audit_clean_text <<< "${lines[i]}")"; done
    read -r -p '要取消哪几项？输入编号，直接回车跳过: ' answer || return 0
    for n in $answer; do [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#lines[@]})) && lines[n - 1]=''; done
    printf '%s\n' "${lines[@]}" | grep . > "$known.new" || true
    chmod 600 -- "$known.new" && mv -f -- "$known.new" "$known" && ok '已取消。'
    return 0
  fi
  [[ "$answer" != a ]] || answer="$(seq 1 "${#AUDIT_MARKS[@]}" | tr '\n' ' ')"
  for n in $answer; do
    if [[ ! "$n" =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#AUDIT_MARKS[@]})); then continue; fi
    entry="${AUDIT_MARKS[n - 1]}" kind="${entry%%$'\t'*}" value="${entry#*$'\t'}" value="${value%%$'\t'*}"
    if ! audit_known "$kind" "$value"; then printf '%s %s\n' "$kind" "$value" >> "$known"; fi
  done
  chmod 600 -- "$known" 2>/dev/null || true
  # At most 1000: the oldest go first.
  if [[ -f "$known" ]] && (($(wc -l < "$known") > 1000)); then tail -n 1000 -- "$known" > "$known.new" && mv -f -- "$known.new" "$known"; fi
  ok '已标记为正常，下次不再提醒。'
}

# Where the addresses are, only when asked (they go to ipinfo.io).
audit_geo() {
  local ip info
  if ((${#AUDIT_IPS[@]} == 0)) || ! command -v curl >/dev/null; then return 0; fi
  confirm_yes "要查这 ${#AUDIT_IPS[@]} 个登录过的 IP 的归属地吗？（会把这些 IP 发给 ipinfo.io 查询）" || return 0
  for ip in "${AUDIT_IPS[@]}"; do
    port_source_valid "$ip" || continue
    info="$(curl -fsS --max-time 5 "https://ipinfo.io/$ip/json" 2>/dev/null |
      sed -n 's/^ *"\(country\|region\|city\|org\)": *"\([^"]*\)".*/\2/p' | audit_clean_text | cut -c1-60 | tr '\n' ' ' || true)"
    printf '  %s：%s\n' "$ip" "${info:-查不到}"
  done
}

audit_main() {
  local tmp part file='' config
  if ((EUID != 0)); then warn '安全排查需要 root：请用 sudo vps audit。'; return 0; fi
  VERIFY_PASS=0 VERIFY_FAIL=0 VERIFY_NA=0 VERIFY_UNKNOWN=0 VERIFY_NOTICE=0 VERIFY_ISSUES=() AUDIT_MARKS=() AUDIT_IPS=() AUDIT_CONFIGS=()
  if ! tmp="$(mktemp)" || ! part="$(mktemp)" || ! AUDIT_OWNED="$(mktemp)"; then die '无法创建临时文件。'; fi
  say '安全排查（只读）'
  echo '正在快速检查（几秒钟）：谁登录过、账户和公钥、装过什么、正在运行什么、开机自启和定时任务、关键系统文件……'
  audit_owned_paths > "$AUDIT_OWNED"
  # No pipe: the counts and the lists must stay in this shell.
  audit_sections > "$tmp"
  cat -- "$tmp"
  if [[ -t 0 ]] && confirm_yes '要做深度检查吗？（逐个核对所有软件包的文件有没有被换过，要读一遍硬盘，一般 1–5 分钟）'; then
    echo '正在深度检查……'
    AUDIT_CONFIGS=()
    audit_integrity all > "$part"
    cat -- "$part"; cat -- "$part" >> "$tmp"
  fi
  {
    if ((${#AUDIT_CONFIGS[@]})); then
      audit_heading '改动过的配置文件（多半是你或本工具改的，只列出来供核对）'
      for config in "${AUDIT_CONFIGS[@]:0:40}"; do printf '  %s\n' "$config"; done
    fi
    echo
    printf '%s结论：%s 项正常，%s 项要留意，%s 项可疑。%s\n' "${C_BOLD-}" "$VERIFY_PASS" "${VERIFY_NOTICE:-0}" "$VERIFY_FAIL" "${C_RESET-}"
    if ((VERIFY_FAIL)); then echo '有可疑项时：先拍快照保留现场，改 root 和所有账户的密码，删掉不认识的公钥；被替换的系统文件说明入侵很深，最稳妥的是备份数据后重装系统。'; fi
    echo '局限：查到可疑基本说明出过事；没查到不能证明没出事（高明的入侵会抹掉痕迹，或者替换掉用来检查的程序）。'
  } > "$part"
  cat -- "$part"; cat -- "$part" >> "$tmp"
  if [[ -d "$LOG_DIR" && ! -L "$LOG_DIR" ]] && tool_data_owned "$LOG_DIR" 2>/dev/null; then
    log_rotate 'audit-*.txt' 10
    file="$LOG_DIR/audit-$(date -u +%Y%m%dT%H%M%SZ).txt"
    sed 's/\x1b\[[0-9;]*m//g' -- "$tmp" > "$file" && chmod 600 -- "$file" && printf '报告已保存：%s\n' "$file"
  fi
  rm -f -- "$tmp" "$part" "$AUDIT_OWNED"
  if [[ -t 0 ]]; then audit_mark_menu; audit_geo; fi
}

# Main menu entries: group, number, label (menu below maps numbers to actions).
menu_entries() {
  printf '%s\t%s\t%s\n' \
    开荒 1 '体检（只检查，不修改）' \
    开荒 2 '一键开荒' \
    开荒 3 '开荒验收（重启后做一次）' \
    日常管理 4 '端口管理' \
    日常管理 5 '单项设置' \
    日常管理 6 'Fail2ban 封禁记录' \
    日常管理 7 '安全排查（只读）' \
    日常管理 8 '重启服务器' \
    安全加固 9 '防火墙和 SSH 防爆破' \
    安全加固 10 'SSH 登录加固' \
    记录与撤销 11 '操作记录和配置备份' \
    记录与撤销 12 '撤销本工具的设置' \
    本工具 13 '卸载本工具（保留优化效果）' \
    本工具 14 '检查更新'
}

# The menu for a terminal WIDTH columns wide: the groups in pairs side by side
# when both columns fit, otherwise one under another (a phone, a narrow window).
# Widths are measured on the plain text; colours are added after the padding.
menu_render() {
  local width="$1" group key label cell w left_w=0 right_w=0 i n pad
  local -a order=() left=() right=()
  local -A body=()
  while IFS=$'\t' read -r group key label; do
    if [[ -z "${body[$group]+set}" ]]; then order+=("$group"); body[$group]=''; fi
    printf -v cell '%3s. %s' "$key" "$label"
    body[$group]+="$cell"$'\n'
  done < <(menu_entries)
  for ((i = 0; i < ${#order[@]}; i++)); do
    while IFS= read -r cell; do
      ui_width w "$cell"
      if ((i % 2 == 0 && w > left_w)); then left_w=$w; fi
      if ((i % 2 == 1 && w > right_w)); then right_w=$w; fi
    done <<< " ${order[i]}"$'\n'"${body[${order[i]}]%$'\n'}"
  done
  if ((width < left_w + 4 + right_w)); then
    for group in "${order[@]}"; do
      printf '%s %s%s\n%s\n' "${C_BOLD-}" "$group" "${C_RESET-}" "${body[$group]%$'\n'}"
    done
  else
    for ((i = 0; i < ${#order[@]}; i += 2)); do
      mapfile -t left <<< " ${order[i]}"$'\n'"${body[${order[i]}]%$'\n'}"
      right=()
      if ((i + 1 < ${#order[@]})); then mapfile -t right <<< " ${order[i + 1]}"$'\n'"${body[${order[i + 1]}]%$'\n'}"; fi
      n=${#left[@]}
      if ((${#right[@]} > n)); then n=${#right[@]}; fi
      for ((w = 0; w < n; w++)); do
        cell="${left[w]:-}"
        ui_width pad "$cell"
        pad=$((left_w + 4 - pad))
        if [[ -z "${right[w]:-}" ]]; then pad=0; fi
        if ((w == 0)); then
          printf '%s%s%*s%s%s\n' "${C_BOLD-}" "$cell" "$pad" '' "${right[w]:-}" "${C_RESET-}"
        else
          printf '%s%*s%s\n' "$cell" "$pad" '' "${right[w]:-}"
        fi
      done
    done
  fi
  printf '%3s. %s      %s. %s\n' h 使用说明 0 退出
}

# The address the user reached this machine on (the SSH session's), or the one
# the default route would leave from; nothing is sent anywhere.
menu_ip() {
  local addr=''
  read -r _ _ addr _ <<< "${SSH_CONNECTION:-}" || true
  if [[ -z "$addr" ]]; then
    addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
  fi
  printf '%s\n' "${addr:-IP 未知}"
}

# Who this machine is and how it stands: the title, a machine line and a
# status line. Only cheap reads, since it is drawn before every choice.
menu_header() {
  local name display ram cores report='' file conclusion setup check fw f2b
  name="$(hostname -s 2>/dev/null || true)"
  if display="$(display_name_get)"; then name="$display（${name:-?}）"; fi
  ram="$(awk '/^MemTotal:/ {printf "%.1f", $2 / 1048576}' /proc/meminfo 2>/dev/null || true)"
  cores="$(nproc 2>/dev/null || echo '?')"
  printf '\n%s%sVPS 机器管家 %s%s%s\n' "${C_TITLE-}" "${UI_OPEN-【}" "${SCRIPT_VERSION:-}" "${UI_CLOSE-】}" "${C_RESET-}"
  printf ' %s · %s · %s %s · %s 核 · %s GiB 内存 · %s GB 硬盘\n' "${name:-本机}" "$(menu_ip)" "${OS^}" "${OS_VERSION:-}" "$cores" "${ram:-?}" "${ROOT_GIB:-?}"
  setup="${C_DIM-}${SYM_SKIP-○} 还没开荒${C_RESET-}"
  for file in "${STATE_ROOT:-/nonexistent}"/modules/*; do
    if [[ -f "$file" && ! -L "$file" ]]; then setup="${C_OK-}${SYM_OK-✔}${C_RESET-} 已开荒"; break; fi
  done
  check="${C_DIM-}${SYM_SKIP-○} 还没验收${C_RESET-}"
  for file in "${LOG_DIR:-/nonexistent}"/verify-*.txt; do
    if [[ -f "$file" && ! -L "$file" ]]; then report="$file"; fi
  done
  if [[ -n "$report" ]]; then
    conclusion="$(sed -n 's/\x1b\[[0-9;]*m//g; s/^结论：//p' -- "$report" 2>/dev/null | head -n 1)"
    if [[ "$conclusion" =~ ([0-9]+)\ 项未生效 ]] && ((BASH_REMATCH[1] > 0)); then
      check="${C_FAIL-}${SYM_FAIL-✖}${C_RESET-} 验收：${BASH_REMATCH[1]} 项未生效"
    elif [[ "$conclusion" =~ ^([0-9]+)\ 项正常 ]]; then
      check="${C_OK-}${SYM_OK-✔}${C_RESET-} 验收：${BASH_REMATCH[1]} 项正常"
    fi
  fi
  fw='防火墙 关'
  if ! command -v ufw >/dev/null; then fw='防火墙 没装'
  elif grep -qsx 'ENABLED=yes' "${UFW_CONF:-/etc/ufw/ufw.conf}"; then fw='防火墙 开'; fi
  f2b='Fail2ban 关'
  if systemctl is-active -q fail2ban 2>/dev/null; then f2b='Fail2ban 开'; fi
  printf ' %s · %s · %s · %s\n' "$setup" "$check" "$fw" "$f2b"
}

menu() {
  local self choice action before='' width
  [[ -t 0 ]] || die '菜单需要交互终端；请登录 SSH 后输入 vps。'
  self="$(readlink -f -- "${BASH_SOURCE[0]}")" || die '无法确定本工具所在位置。'
  [[ -f "$self" && -r "$self" ]] || die '无法读取本工具的脚本文件。'
  while :; do
    menu_header
    # The alerts: what is waiting for the user.
    menu_reboot_hint
    menu_pending_reboot_hint
    menu_login_alert
    menu_quota_alert
    if setup_tmux_running; then printf '%s%s %s%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" '一键开荒正在 tmux 里运行（可能是之前 SSH 断线了）：选 2 回到那个界面。' "${C_RESET-}"; fi
    echo
    width="$(stty size 2>/dev/null < /dev/tty | awk '{print $2}' || true)"
    [[ "$width" =~ ^[0-9]+$ ]] || width="${COLUMNS:-80}"
    menu_render "$width"
    if [[ ! -d "$STATE_ROOT/modules" ]]; then
      printf '\n第一次用：先选 1 体检，再选 2 一键开荒，重启后选 3 验收。以后单独改哪一项选 5。\n'
    fi
    if ! read -r -p $'\n请输入选项 [0-14 或 h]: ' choice; then printf '\n'; return 0; fi
    case "$choice" in
      0) return 0 ;;
      1)
        read -r -p '1) 开荒前体检（只检查）   2) 性能体检   3) 资源占用一览   回车返回: ' choice || choice=''
        case "$choice" in 1) action=plan ;; 2) action=perf ;; 3) action=resources ;; *) continue ;; esac ;;
      2) action=setup ;;
      3) action=check ;;
      4) action=port ;;
      5) action=item ;;
      6) action=bans ;;
      7) action=audit ;;
      8) action=reboot ;;
      9) action=firewall ;;
      10) action=ssh ;;
      11) action=records ;;
      12) action=rollback ;;
      13) action=uninstall ;;
      14) action=update ;;
      h|H) /bin/bash -- "$self" help; action='' ;;
      *) echo '无效选项，请输入 0 至 14 或 h。'; continue ;;
    esac
    if [[ "$action" == update ]]; then before="$(sha256sum -- "$self" 2>/dev/null || true)"; fi
    if [[ -n "$action" ]]; then menu_action "$self" "$action"; fi
    # Uninstall may remove the installed source and launcher in its child.
    if [[ ! -f "$self" ]]; then echo '本工具已卸载，菜单退出。'; return 0; fi
    # This menu is still the old version in memory: the new one replaces it.
    if [[ "$action" == update && "$(sha256sum -- "$self" 2>/dev/null || true)" != "$before" ]]; then
      if bash -n -- "$self" 2>/dev/null; then
        echo '本工具已更新，正在打开新版本的菜单……'
        exec /bin/bash -- "$self" menu
      fi
      warn '更新后的脚本读不通，菜单先退出：请重新运行安装命令。'; return 0
    fi
    if [[ "$action" == uninstall ]]; then
      # Uploaded source copies are user files and are intentionally not removed.
      echo '卸载操作结束；如从上传的脚本副本运行，副本由你自行保留或删除。'
    fi
    if ! read -r -p '按回车返回菜单（或 Ctrl+D 退出）…' choice; then printf '\n'; return 0; fi
  done
}

records_report() {
  local directory id i shown=0
  local -a directories=()
  say '查看操作记录和配置备份（只读）'
  [[ $EUID -eq 0 ]] || { warn '配置备份属于 root，请用 sudo vps records 查看。'; return 0; }
  state_report
  printf '操作日志目录：%s（如已运行，含优化/回退输出）\n' "$LOG_DIR"
  if [[ -d "$LEGACY_LOG_DIR" ]]; then printf '旧版本的操作日志：%s（卸载本工具时一起删除）\n' "$LEGACY_LOG_DIR"; fi
  printf '本版回退资料：%s/restore-v2（如存在，回退前逐项核验）\n' "$STATE_ROOT"
  printf '开荒结果记录：%s/modules（开荒验收据此逐项核对）\n' "$STATE_ROOT"
  if [[ ! -e "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]]; then
    echo '还没有配置备份；完成第一次确认后的运行才会创建。'; return 0
  fi
  if ! state_path_safe "$BACKUP_ROOT" || [[ ! -d "$BACKUP_ROOT" || ! -O "$BACKUP_ROOT" ]]; then
    warn '备份目录路径或所有权异常，未继续读取。'; return 0
  fi
  directories=("$BACKUP_ROOT"/run-*)
  echo '最近最多 20 个配置备份目录：'
  for ((i=${#directories[@]}-1; i>=0 && shown<20; i--)); do
    directory="${directories[i]}"
    id="${directory##*/}"
    [[ "$id" =~ ^run-[0-9]{8}T[0-9]{6}Z-[0-9]+-[A-Za-z0-9]{6}$ ]] || continue
    [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || continue
    printf '  %s\n' "$directory"
    shown=$((shown+1))
  done
  if ((shown==0)); then echo '没有找到可安全列出的配置备份目录。'; fi
  echo '每个目录内有 recovery-notes.txt 和 manifest.tsv；请人工核对，不会自动恢复。'
  echo '卸载本工具会删除配置备份和回退资料；软件与优化效果保留。'
}

# All supported system-wide journal policy locations; a conservative scan keeps
# vendor and runtime policies even where a higher-priority file might mask one.
journal_policy_paths() {
  printf '%s\n' /etc/systemd/journald.conf /run/systemd/journald.conf \
    /usr/local/lib/systemd/journald.conf /usr/lib/systemd/journald.conf /lib/systemd/journald.conf \
    /etc/systemd/journald.conf.d/*.conf /run/systemd/journald.conf.d/*.conf \
    /usr/local/lib/systemd/journald.conf.d/*.conf /usr/lib/systemd/journald.conf.d/*.conf \
    /lib/systemd/journald.conf.d/*.conf
}


# Read-only decisions for the next optimization run. The two arguments must be
# the findings from the immediately preceding preflight_report invocation.
# No argument means unknown; stale globals are intentionally not consulted.
decision_line() {
  printf '[%s] %s：%s\n' "$1" "$2" "$3"
}

decision_file_state() {
  local path="$1" expected="$2" actual
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then printf '%s\n' conflict; return 0; fi
  if [[ ! -e "$path" ]]; then printf '%s\n' missing; return 0; fi
  if ! actual="$(cat -- "$path" 2>/dev/null)"; then printf '%s\n' unknown; return 0; fi
  if [[ "$actual" == "$expected" ]]; then printf '%s\n' match
  else printf '%s\n' conflict; fi
}

# Arguments are overridable file paths solely to allow isolated tests. Normal
# calls inspect the same local files as journal_stage, without changing them.
decision_journal_state() {
  local file own_state
  local -a paths=()
  if [[ "${1:-}" == --system ]]; then mapfile -t paths < <(journal_policy_paths); else paths=("$@"); fi
  for file in "${paths[@]}"; do
    [[ -f "$file" && "$file" != "$JOURNAL_FILE" ]] || continue
    if [[ ! -r "$file" ]]; then printf '%s\n' unknown; return 0; fi
    if grep -Eq '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|MaxRetentionSec)[[:space:]]*=' "$file"; then
      printf '%s\n' custom; return 0
    fi
  done
  own_state="$(decision_file_state "$JOURNAL_FILE" "$(journal_config_text)")"
  # The 14-day file of versions before 2.8.0 is this tool's too (the setup
  # brings it to the current parameters).
  if [[ "$own_state" == conflict && "$(decision_file_state "$JOURNAL_FILE" $'[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\nMaxRetentionSec=14day')" == match ]]; then
    own_state=match
  fi
  printf '%s\n' "$own_state"
}

decision_report() {
  local blockers="${1:-unknown}" sources="${2:-unknown}" current available_cc file_state module_state
  local synchronized provider='' pkg state
  local -a files=()
  say '根据本次体检，接下来准备怎么做'
  echo '以下是下一次优化的处理计划；此处只检查。开始执行时会重新检测，并保留升级和防火墙等确认。'
  if [[ "$blockers" =~ ^[0-9]+$ ]]; then
    if ((blockers>0)); then
      decision_line '需要先处理' '开始条件' "本次执行前体检发现 ${blockers} 项阻断问题，处理前不会进入调优阶段。"
    else
      decision_line '准备调整' '开始条件' '本次执行前体检未发现阻断项；仍需执行阶段再次检查和确认。'
    fi
  else
    decision_line '需要先处理' '开始条件' '没有提供本次执行前体检结果，不能判断能否开始；请重新做体检。'
  fi
  case "$sources" in
    1) decision_line '需要先处理' '软件源' '存在需要人工核对的软件源，执行前必须确认来源、签名和发行版匹配。' ;;
    0) decision_line '准备调整' '软件更新' '执行时更新软件索引并展示升级清单（含新内核会标出），由你确认是否升级；自动更新、常用工具也会单独询问。' ;;
    *) decision_line '需要先处理' '软件源' '本次软件源检查结果未知，请重新做体检。' ;;
  esac

  # bbr_config_conflict can warn/increment WARNINGS. The subshell keeps those
  # effects local, and suppresses raw administrator configuration in this view.
  mapfile -t files < <(sysctl_config_files)
  if ( bbr_config_conflict "${files[@]}" ) >/dev/null 2>&1; then
    decision_line '保留现状' 'BBR 网络优化' '发现已有或无法读取的 TCP/队列策略，按现有规则跳过 BBR 配置，避免覆盖。'
  else
    file_state="$(decision_file_state "$BBR_FILE" $'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr')"
    module_state="$(decision_file_state "$MODULE_FILE" 'tcp_bbr')"
    if [[ "$file_state" == conflict || "$file_state" == unknown ]]; then
      decision_line '保留现状' 'BBR 网络优化' '本工具使用的配置路径已有不同内容或无法检查，执行时不会覆盖。'
    elif [[ "$module_state" == conflict || "$module_state" == unknown ]]; then
      decision_line '保留现状' 'BBR 网络优化' '模块持久配置路径已有不同内容或无法检查；若已有其他 tcp_bbr 加载配置，执行阶段会再次核对。'
    else
      current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
      available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
      if [[ "$current" == bbr && "$file_state" == match && "$module_state" == match && "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == fq ]]; then
        decision_line '保留现状' 'BBR 网络优化' '当前默认算法和本工具的持久配置已经匹配，执行时仍会核验。'
      elif [[ "$file_state" == missing ]] && bbr_set_elsewhere; then
        decision_line '保留现状' 'BBR 网络优化' '系统已经开启 BBR 和 fq，开机时也会由别的配置文件设置，不再重复写入。'
      elif [[ " $available_cc " == *' bbr '* ]]; then
        decision_line '准备调整' 'BBR 网络优化' '内核当前提供 BBR，执行时核验持久配置后设置 BBR 和默认 fq 队列。'
      else
        decision_line '准备调整' 'BBR 网络优化' '当前未确认 BBR 可用；执行阶段才尝试加载模块并再次检查，不支持就跳过，不更换内核。'
      fi
    fi
  fi

  if swap_exists; then
    decision_line '保留现状' '内存缓冲（ZRAM）' '已发现 Swap/ZRAM 或相关配置，不再新增。'
  elif [[ ! "${MEM_MIB:-}" =~ ^[0-9]+$ ]]; then
    decision_line '需要先处理' '内存缓冲（ZRAM）' '内存容量未知，请重新检查，不能据此确定方案。'
  elif ((MEM_MIB>=2048)); then
    decision_line '保留现状' '内存缓冲（ZRAM）' '内存不少于 2GiB，默认不新增 ZRAM。'
  elif ! zram_module_available; then
    decision_line '保留现状' '内存缓冲（ZRAM）' '这个内核没有 zram 模块（Ubuntu 云镜像的精简内核把它放在 linux-modules-extra 包里），不配置 ZRAM。'
  elif available systemd-zram-generator; then
    decision_line '准备调整' '内存缓冲（ZRAM）' '内存低于 2GiB，未发现 Swap/ZRAM；计划配置约内存一半大小的 ZRAM（zstd 压缩，并配好适合 ZRAM 的 swappiness 和 page-cluster），不创建硬盘 Swap。'
  else
    decision_line '准备调整' '内存缓冲（ZRAM）' '内存低于 2GiB，未发现 Swap/ZRAM；当前软件索引未确认组件可用，更新索引后再检查，不可用就跳过。'
  fi
  # Without ZRAM a small machine gets a disk swap instead.
  if [[ "${MEM_MIB:-}" =~ ^[0-9]+$ ]] && ((MEM_MIB < 2048)) && ! swap_exists && ! zram_module_available; then
    case "$ROOT_FS" in
      ext4|xfs) decision_line '准备调整' '硬盘 Swap' "用不了 ZRAM：建约 $(param_value swap_mib) MiB 的硬盘 Swap（$SWAP_FILE），系统盘至少留 3 GB。" ;;
      *) decision_line '保留现状' '硬盘 Swap' "用不了 ZRAM，系统盘是 $ROOT_FS：本工具只在 ext4、xfs 上建硬盘 Swap。" ;;
    esac
  fi

  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$synchronized" == yes ]]; then
    decision_line '保留现状' '时间同步' '系统时间已经同步，不修改时区。'
  else
    for pkg in chrony ntpsec openntpd ntp; do
      if installed "$pkg"; then provider="$pkg"; break; fi
    done
    if [[ -n "$provider" ]]; then
      decision_line '准备调整' '时间同步' "最先执行：请求现有时间同步服务；若仍不可用，保留已有 ${provider} 并提示人工检查。"
    else
      decision_line '准备调整' '时间同步' '最先执行：请求现有时间同步服务；不可用时在软件索引更新后安装系统时间同步组件。'
    fi
  fi

  if ( ssh_password_disabled ) >/dev/null 2>&1; then
    decision_line '保留现状' 'SSH 登录' '已经只允许密钥登录。'
  else
    decision_line '准备调整' 'SSH 登录' '会询问是否只允许密钥登录、是否新建管理员并禁止 root 直接登录：先确认密钥能登录、sudo 可用、控制台有密码，带防失联保护（180 秒内没有确认就自动恢复）；默认不改。'
  fi

  if [[ ! "${ROOT_GIB:-}" =~ ^[0-9]+$ ]]; then
    decision_line '需要先处理' '日志空间' '系统盘容量未知，不能据此确定小硬盘方案。'
  elif ((ROOT_GIB>JOURNAL_LIMIT_GB)); then
    decision_line '保留现状' '日志空间' "系统盘大于 ${JOURNAL_LIMIT_GB}GiB，保留现有日志策略。"
  else
    case "$(decision_journal_state --system)" in
      custom) decision_line '保留现状' '日志空间' '已有日志容量或保留时间策略，不再新增限制。' ;;
      match) decision_line '保留现状' '日志空间' '本工具的日志容量和保留时间限制已经存在。' ;;
      conflict) decision_line '保留现状' '日志空间' '目标日志配置已有不同内容，不会覆盖。' ;;
      unknown) decision_line '需要先处理' '日志空间' '已有日志配置无法读取，计划未确认，需人工检查。' ;;
      *) decision_line '准备调整' '日志空间' "系统盘不大于 20GiB，计划限制日志：持久日志 $(param_value journal_max_mb)MiB、保留 $(param_value journal_days) 天。" ;;
    esac
  fi

  case "${ROOT_FS:-unknown}" in
    ext4|xfs|btrfs)
      if [[ "${ROOT_DEV:-unknown}" != /dev/* ]]; then
        decision_line '保留现状' '磁盘 TRIM' '系统盘不是可直接识别的块设备路径，跳过。'
      elif ! trim_support; then
        decision_line '保留现状' '磁盘 TRIM' '系统盘不支持 TRIM（DISC-MAX 为 0），跳过；定时任务保持原样。'
      elif systemctl is-enabled -q fstrim.timer >/dev/null 2>&1; then
        decision_line '保留现状' '磁盘 TRIM' '定期 TRIM 已启用。'
      elif command -v fstrim >/dev/null; then
        decision_line '准备调整' '磁盘 TRIM' '执行阶段才尝试 TRIM；成功后启用定期任务，不支持就跳过。'
      else
        decision_line '保留现状' '磁盘 TRIM' '未找到 TRIM 工具，跳过。'
      fi ;;
    *) decision_line '保留现状' '磁盘 TRIM' '当前文件系统不在自动处理范围内，跳过。' ;;
  esac

  if command -v ufw >/dev/null; then
    state="$(ufw status 2>/dev/null || true)"
    if grep -Fxq 'Status: active' <<< "$state"; then
      decision_line '保留现状' '防火墙' 'UFW 已开启，保留已有规则和默认策略；如缺少 TCP 80/443，将另行询问是否开放。'
    elif grep -Fxq 'Status: inactive' <<< "$state"; then
      if ( firewall_conflict ) >/dev/null 2>&1; then
        decision_line '需要先处理' '防火墙' '发现其他防火墙规则，或无法检查规则；执行时保留现状，不自动接管。'
      elif ! ( ssh_detect ) >/dev/null 2>&1; then
        decision_line '需要先处理' '防火墙' '未验证到实际 SSH 监听端口；执行时不会自动开启防火墙。'
      elif ! ( ssh_detect && ufw_stored_rules_safe ) >/dev/null 2>&1; then
        decision_line '需要先处理' '防火墙' 'UFW 留有需要人工核对的规则；执行时不会自动开启。'
      else
        decision_line '准备调整' '防火墙' '确认救援入口后放行 SSH（80/443 会单独询问），再开启防火墙；必须通过新 SSH 窗口验证。'
      fi
    else
      decision_line '需要先处理' '防火墙' 'UFW 状态无法确认，执行时将跳过相关修改。'
    fi
  else
    decision_line '准备调整' '防火墙' '完整优化流程会先检查并安装 UFW；安装后重新核对规则和 SSH 端口，再由你确认是否开启。'
  fi
  if ( foreign_f2b_config ) >/dev/null 2>&1; then
    decision_line '保留现状' 'SSH 防爆破' '已有其他 Fail2ban 管理配置，保留并提示，不接管。'
  elif [[ -f "$F2B_FILE" && ! -L "$F2B_FILE" ]] && grep -Fxq 'bantime = 43200' "$F2B_FILE" && grep -Fq 'vps-stable-ufw-sshd' "$F2B_FILE"; then
    decision_line '准备调整' 'SSH 防爆破' '本工具旧版的 Fail2ban 规则每次封 12 小时：改为首次 1 小时、同一 IP 再犯加倍（最长 7 天）；已有的白名单保持不变，没有的会问你。'
  elif [[ -f "$F2B_FILE" && ! -L "$F2B_FILE" ]] && active fail2ban; then
    decision_line '保留现状' 'SSH 防爆破' '本工具的 Fail2ban 规则已经在运行，执行时仍会核验。'
  else
    decision_line '准备调整' 'SSH 防爆破' '仅在防火墙生效并确认后，再检查组件和配置，配置 SSH 防爆破；不改变密码登录方式。'
  fi
  echo '“需要先处理”中的开始条件会阻止整套调优；单项问题通常只跳过对应项目，详情以上方执行前体检为准。'
  echo 'SSH 登录方式、服务故障等体检提示仍需人工判断；本工具不会据此自动关闭密码登录或重启故障业务。'
}

# Tool lifecycle helpers. They remove only the V2.6-owned tool/data, never /etc
# configuration, APT packages, system journal/APT history, or uploaded copies.
# "/" is accepted here only as a parent whose owner and mode are checked;
# state_path_safe never accepts it, so it can never be a removal target.
tool_secure_dir() {
  local path="$1" owner mode
  if [[ "$path" != / ]]; then state_path_safe "$path" || return 1; fi
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(stat -c '%u' -- "$path")" || return 1
  mode="$(stat -c '%a' -- "$path")" || return 1
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

tool_secure_file() {
  local path="$1" owner mode
  state_path_safe "$path" && [[ -f "$path" ]] || return 1
  owner="$(stat -c '%u' -- "$path")" || return 1
  mode="$(stat -c '%a' -- "$path")" || return 1
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

tool_expected_launcher() {
  cat <<'LAUNCHER'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if (( $# == 0 )); then set -- menu; fi
exec /bin/bash /usr/local/lib/vps-stable-opt/vps-stable-opt.sh "$@"
LAUNCHER
}

tool_fixed_paths() {
  [[ "$STATE_ROOT" == /var/lib/vps-stable-opt && "$BACKUP_ROOT" == /var/backups/vps-stable-opt &&
     "$LOG_DIR" == /var/lib/vps-stable-opt/logs && "$LEGACY_LOG_DIR" == /var/log/vps-stable-opt ]]
}

tool_lifecycle_lock() {
  [[ $EUID -eq 0 ]] || die '请使用 root 或 sudo vps。'
  tool_fixed_paths || die '工具数据路径不是预定固定目录，已停止。'
  tool_secure_dir /var/lib || die '/var/lib 的路径、归属或权限异常，已停止。'
  command -v flock >/dev/null || die '缺少 flock，无法防止运行和卸载同时发生。'
  if [[ "${TOOL_LIFECYCLE_PID:-}" == "$BASHPID" ]]; then
    [[ "$(readlink -- /proc/self/fd/8 2>/dev/null)" == /var/lib ]] || die '已持有的生命周期锁异常。'
    flock -n -x 8 || die '无法重新确认生命周期锁。'
    return 0
  fi
  # An existing parent directory is a stable inode: removing the state folder
  # cannot unlink this lock, and no residual tool-specific lock file is created.
  exec 8</var/lib
  flock -n -x 8 || die "$(lock_holder_text)"
  TOOL_LIFECYCLE_PID="$BASHPID"
  # Informational only (the lock itself is the flock above): names the holder.
  { printf '%s %s\n' "$MODE" "$BASHPID" > "$LOCK_OWNER_FILE"; } 2>/dev/null || true
}

# Gives the lifecycle lock up before another process takes over the work.
tool_lock_release() {
  [[ -n "${TOOL_LIFECYCLE_PID:-}" && "$TOOL_LIFECYCLE_PID" == "$BASHPID" ]] || return 0
  exec 8<&-
  rm -f -- "$LOCK_OWNER_FILE" 2>/dev/null || true
  TOOL_LIFECYCLE_PID=''
}

LOCK_OWNER_FILE=/run/vps-stable-opt.owner
lock_holder_text() {
  local mode='' pid='' name='另一个任务'
  if read -r mode pid 2>/dev/null < "$LOCK_OWNER_FILE" && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    case "$mode" in
      setup) name='一键开荒' ;; firewall) name='防火墙设置' ;; ssh) name='SSH 登录加固' ;;
      port) name='端口管理' ;; rollback) name='撤销设置' ;; uninstall) name='卸载' ;; check) name='Fail2ban 实弹测试' ;;
      item) name='单项设置' ;; reboot) name='重启' ;; bans) name='Fail2ban 解封' ;;
    esac
    printf '%s正在运行（PID %s）：请等它结束，或回到那个窗口退出后再试。' "$name" "$pid"
  else
    printf '另一个开荒、回退、端口管理或卸载任务正在运行，请等它结束。'
  fi
}

tool_data_owned() {
  local directory="$1" marker actual
  case "$directory" in /var/lib/vps-stable-opt|/var/lib/vps-stable-opt/logs|/var/backups/vps-stable-opt|/var/log/vps-stable-opt) ;; *) return 1 ;; esac
  tool_secure_dir "$directory" || return 1
  marker="$directory/.tool-owner"
  tool_secure_file "$marker" || return 1
  actual="$(cat -- "$marker")" || return 1
  [[ "$actual" == 'vps-stable-opt-data:2.6' ]] && [[ "$(stat -c '%s' -- "$marker")" == 24 ]]
}

tool_prepare_data() {
  local directory parent stage
  tool_lifecycle_lock
  # LOG_DIR lives in STATE_ROOT, so /var/log is not a parent of anything written.
  for parent in /var /var/lib /var/backups; do
    if [[ "$parent" == /var/backups && ! -e "$parent" && ! -L "$parent" ]]; then continue; fi
    tool_secure_dir "$parent" || die "工具数据父目录不安全：$parent"
  done
  # Validate every existing directory before creating or changing any data.
  for directory in "$STATE_ROOT" "$BACKUP_ROOT" "$LOG_DIR"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      tool_data_owned "$directory" || die "目录没有本版归属标记或不安全：$directory。旧版资料已保留；请先在别处保存并人工迁移，不会自动接管。"
    fi
  done
  if [[ ! -d /var/backups ]]; then mkdir -m 755 -- /var/backups || die '无法创建 /var/backups。'; fi
  for directory in "$STATE_ROOT" "$BACKUP_ROOT" "$LOG_DIR"; do
    if [[ ! -d "$directory" ]]; then
      mkdir -m 700 -- "$directory" || die "无法创建工具数据目录：$directory"
      stage="$(mktemp "$directory/.owner.XXXXXXXX")" || die '无法创建归属标记。'
      printf '%s\n' 'vps-stable-opt-data:2.6' > "$stage" || die '写入归属标记失败。'
      chmod 600 -- "$stage" || die '设置归属标记权限失败。'
      ln -- "$stage" "$directory/.tool-owner" || die '无法安全发布归属标记。'
      rm -f -- "$stage" || die '无法清理归属标记临时文件。'
    fi
    tool_data_owned "$directory" || die "归属标记验收失败：$directory"
  done
}

tool_install_owned() {
  local directory=/usr/local/lib/vps-stable-opt marker actual expected entries
  tool_secure_dir "$directory" || return 1
  for marker in "$directory/.installer-owner" "$directory/.installed-sha256" "$directory/vps-stable-opt.sh" /usr/local/bin/vps; do
    tool_secure_file "$marker" || return 1
  done
  actual="$(cat -- "$directory/.installer-owner")" || return 1
  [[ "$actual" == 'vps-stable-opt-installer:2.6' && "$(stat -c '%s' -- "$directory/.installer-owner")" == 29 ]] || return 1
  expected="$(cat -- "$directory/.installed-sha256")" || return 1
  [[ "$expected" =~ ^[a-f0-9]{64}$ && "$(stat -c '%s' -- "$directory/.installed-sha256")" == 65 ]] || return 1
  actual="$(sha256sum -- "$directory/vps-stable-opt.sh")" || return 1
  [[ "${actual%% *}" == "$expected" ]] || return 1
  actual="$(cat -- /usr/local/bin/vps)" || return 1
  expected="$(tool_expected_launcher)" || return 1
  [[ "$actual" == "$expected" && "$(stat -c '%s' -- /usr/local/bin/vps)" == "$((${#expected}+1))" ]] || return 1
  entries="$(find -P "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" || return 1
  [[ "$entries" == $'.installed-sha256\n.installer-owner\nvps-stable-opt.sh' ]]
}

tool_tree_safe() {
  local directory="$1" unsafe mounts mount
  tool_data_owned "$directory" || return 1
  command -v findmnt >/dev/null || return 1
  mounts="$(findmnt --raw --noheadings --output TARGET)" || return 1
  while IFS= read -r mount; do
    [[ "$mount" != "$directory" && "$mount" != "$directory/"* ]] || return 1
  done <<< "$mounts"
  # Backup symlinks are allowed as links: find -P and rm do not follow them.
  # Refuse mounted trees, special files, other owners, and writable contents.
  unsafe="$(find -P "$directory" -xdev \( ! -uid 0 -o \( ! -type d -a ! -type f -a ! -type l \) -o \( -type d -perm /022 \) -o \( -type f -perm /022 \) \) -printf x)" || return 1
  [[ -z "$unsafe" ]]
}

tool_no_pending_firewall() {
  local units
  units="$(systemctl list-units --type=timer --state=active,activating,deactivating --no-legend --full --no-pager 'vps-stable-ufw-rollback-*' 'vps-stable-ssh-revert-*' 2>/dev/null)" || return 1
  [[ "$units" != *vps-stable-ufw-rollback-* && "$units" != *vps-stable-ssh-revert-* ]] || return 1
  units="$(systemctl list-units --type=service --state=active,activating,deactivating --no-legend --full --no-pager 'vps-stable-ufw-rollback-*' 'vps-stable-ssh-revert-*' 2>/dev/null)" || return 1
  [[ "$units" != *vps-stable-ufw-rollback-* && "$units" != *vps-stable-ssh-revert-* ]]
}

tool_uninstall_validate() {
  local directory
  tool_fixed_paths || die '数据路径不是预定固定目录，拒绝卸载。'
  for directory in / /usr /usr/local /usr/local/lib /usr/local/bin /var /var/lib /var/backups /var/log; do
    if [[ "$directory" == /var/backups && ! -e "$directory" && ! -L "$directory" ]]; then continue; fi
    # /var/log matters only for an older version's log directory in it.
    if [[ "$directory" == /var/log && ! -e "$LEGACY_LOG_DIR" && ! -L "$LEGACY_LOG_DIR" ]]; then continue; fi
    tool_secure_dir "$directory" || die "父目录归属或权限不安全：$directory"
  done
  if [[ -e /usr/local/lib/vps-stable-opt || -L /usr/local/lib/vps-stable-opt || -e /usr/local/bin/vps || -L /usr/local/bin/vps ]]; then
    tool_install_owned || die '已有程序或 vps 命令归属、校验值、内容异常，未删除。'
  fi
  for directory in "$STATE_ROOT" "$BACKUP_ROOT" "$LOG_DIR" "$LEGACY_LOG_DIR"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      tool_tree_safe "$directory" || die "数据目录归属、内容或挂载状态不安全：$directory。旧版无标记数据不会删除。"
    fi
  done
  tool_no_pending_firewall || die '仍有 SSH 防火墙保护任务，或无法确认其状态；请等保护流程结束后再卸载。'
}

tool_uninstall() {
  local directory
  [[ $EUID -eq 0 && -t 0 ]] || die '卸载需要 root 权限和 SSH 交互终端。'
  tool_lifecycle_lock
  tool_uninstall_validate
  # Also honour an optimizer.lock held by an earlier process/version.
  if [[ -e "$STATE_ROOT/optimizer.lock" || -L "$STATE_ROOT/optimizer.lock" ]]; then
    tool_secure_file "$STATE_ROOT/optimizer.lock" || die '已有运行锁不安全，停止卸载。'
    exec 9<"$STATE_ROOT/optimizer.lock"
    flock -n -x 9 || die '仍有优化任务在运行，停止卸载。'
  fi
  say '卸载本工具，保留优化效果'
  echo '将删除安装的程序、vps 命令、工具操作日志、运行记录和配置备份（含回退资料）。'
  echo '已安装的软件、/etc 下的优化配置和当前调优效果保留；系统自身日志保留。'
  echo '删除回退资料后，重新安装工具也不能找回机器原来的设置；需要时先自行保存备份。'
  echo '你手工上传或下载的脚本、压缩包、安装器副本不属于安装目录，不会被删除。'
  if ! confirm '确认卸载本工具及其数据？' UNINSTALL; then
    ok '已取消卸载。'; return 0
  fi
  tool_uninstall_validate
  # The login hook goes with the tool's data: PAM must stop calling it first.
  if login_pam_enabled; then
    pam-auth-update --package --remove vps-stable-login || true
    login_pam_enabled && die "$PAM_COMMON_SESSION 里的登录记录那一行去不掉，停止卸载：请先在单项设置里关闭登录记录。"
    ok '登录记录和提醒已关闭（它的脚本和记录随本工具一起删除）。'
  fi
  if [[ -f "$LOGIN_PAM_FILE" ]] && grep -Fq "$STATE_ROOT/login-hook" "$LOGIN_PAM_FILE"; then rm -f -- "$LOGIN_PAM_FILE"; fi
  if [[ -f "$LOGIN_PROFILE_FILE" && "$(cat -- "$LOGIN_PROFILE_FILE")" == "$(login_profile_text)" ]]; then rm -f -- "$LOGIN_PROFILE_FILE"; fi
  rm -rf --one-file-system -- "$LOGIN_NOTE_DIR"
  if [[ -e "$CHECK_TIMER_FILE" ]]; then check_remove; ok 'TG 通知和流量提醒已停止（它们的脚本随本工具一起删除）。'; fi
  # Each recursive target is a literal member of the fixed allowlist and was
  # validated twice. --one-file-system adds protection if a mount races us.
  for directory in /var/log/vps-stable-opt /var/backups/vps-stable-opt /var/lib/vps-stable-opt; do
    if [[ -d "$directory" ]]; then
      tool_tree_safe "$directory" || die "删除前复核失败：$directory"
      rm -rf --one-file-system -- "$directory" || die "无法完整清理：$directory"
      [[ ! -e "$directory" && ! -L "$directory" ]] || die "目录未完全清理：$directory"
    fi
  done
  if [[ -d /usr/local/lib/vps-stable-opt ]]; then
    tool_install_owned || die '删除程序前归属复核失败。'
    rm -f -- /usr/local/bin/vps /usr/local/lib/vps-stable-opt/vps-stable-opt.sh /usr/local/lib/vps-stable-opt/.installed-sha256 /usr/local/lib/vps-stable-opt/.installer-owner || die '无法删除工具程序或入口。'
    rmdir -- /usr/local/lib/vps-stable-opt || die '安装目录仍有文件，未递归删除，请人工检查。'
  fi
  rm -f -- "$LOCK_OWNER_FILE" || true
  ok '本工具及其安装数据已卸载；软件和优化效果已保留。'
}

# Persistent, allowlisted configuration recovery. Never source recovery data.
# Rule (chosen by the owner): rollback returns every tracked setting to its
# state before this tool's first run (origin_fp), also after hand-made changes.
# Invariant: rollback only ever widens access (turns UFW off, deletes rules this
# tool added, restores password login). It never enables UFW or removes an SSH
# allowance while UFW stays on, so it needs no SSH anti-lockout timer.
RESTORE_ROOT=''
RESTORE_READY=0
RESTORE_STAGE=''
RESTORE_PARTIAL=0
# Set once this run removed systemd-zram-generator (see restore_zram_settle).
ZRAM_PACKAGE_REMOVED=0

restore_ids() {
  case "$1" in
    # Package installation can create UFW defaults, so the stage tracks them too.
    apt_upgrade) printf '%s\n' apt_auto_file svc_timesync svc_trim svc_apt_daily svc_apt_upgrade svc_ufw svc_fail2ban ntp ufw_policy_in ufw_policy_out ufw_runtime ;;
    bbr) printf '%s\n' bbr_file bbr_module cc qdisc ;;
    zram) printf '%s\n' zram_file zram_swap zram_sysctl_file ;;
    swap) printf '%s\n' swap_unit swap_file zram_sysctl_file ;;
    conntrack) printf '%s\n' conntrack_file conntrack_module ;;
    ping) printf '%s\n' ping_file ;;
    keepalive) printf '%s\n' keepalive_file ;;
    ipv4) printf '%s\n' gai_file ;;
    login) printf '%s\n' login_pam login_pam_file login_hook_file login_profile_file ;;
    notify) printf '%s\n' notify_conf check_timer check_service_file check_timer_file check_script_file ;;
    quota) printf '%s\n' quota_conf check_timer check_service_file check_timer_file check_script_file ;;
    dockerlog) printf '%s\n' dockerlog_file ;;
    sshport) printf '%s\n' sshport_dropin ;;
    ntp) printf '%s\n' ntp svc_timesync ;;
    journal) printf '%s\n' journal_file ;;
    trim) printf '%s\n' svc_trim ;;
    updates) printf '%s\n' apt_file apt_time_file svc_apt_daily svc_apt_upgrade ;;
    autoreboot) printf '%s\n' apt_reboot_file ;;
    timezone) printf '%s\n' tz ;;
    sysctl) printf '%s\n' sysctl_file ;;
    tcp) printf '%s\n' tcp_file ;;
    hosts) printf '%s\n' hosts_file ;;
    hostname) printf '%s\n' hostname cloud_hostname_file ;;
    ssh) printf '%s\n' ssh_dropin ssh_pubkey_dropin ;;
    firewall) printf '%s\n' ufw_policy_in ufw_policy_out ufw_ipv6 ufw_runtime svc_ufw ;;
    fail2ban) printf '%s\n' f2b_jail f2b_action f2b_db_file svc_fail2ban ;;
  esac
  return 0
}

restore_all_ids() {
  printf '%s\n' bbr_file bbr_module cc qdisc sysctl_file tcp_file zram_file zram_swap zram_sysctl_file swap_unit swap_file conntrack_file conntrack_module ping_file keepalive_file gai_file apt_time_file journal_file apt_auto_file apt_file apt_reboot_file ntp svc_timesync svc_trim svc_apt_daily svc_apt_upgrade tz hosts_file hostname cloud_hostname_file ssh_dropin ssh_pubkey_dropin ufw_policy_in ufw_policy_out ufw_ipv6 ufw_runtime svc_ufw f2b_jail f2b_action f2b_db_file svc_fail2ban login_pam login_pam_file login_hook_file login_profile_file notify_conf quota_conf check_timer check_service_file check_timer_file check_script_file dockerlog_file sshport_dropin
}

restore_label() {
  case "$1" in
    bbr_file) echo 'BBR 配置文件' ;; bbr_module) echo 'BBR 模块加载配置' ;;
    cc) echo 'TCP 拥塞算法' ;; qdisc) echo '默认队列算法' ;;
    zram_file) echo 'ZRAM 配置' ;; zram_swap) echo 'ZRAM 交换空间' ;; zram_sysctl_file) echo 'ZRAM 配套内存参数' ;;
    swap_unit) echo '硬盘 Swap 的启动配置' ;; swap_file) echo '硬盘 Swap 文件' ;;
    conntrack_file) echo '连接跟踪参数' ;; conntrack_module) echo '连接跟踪模块的开机加载' ;; ping_file) echo '禁止 ping 的参数' ;;
    keepalive_file) echo 'SSH 保活配置' ;; gai_file) echo '地址优先顺序（/etc/gai.conf）' ;; apt_time_file) echo '每天自动更新的时间' ;;
    login_pam) echo '登录记录（common-session 里的那一行）' ;; login_pam_file) echo '登录记录的 PAM 设置' ;; login_hook_file) echo '登录记录脚本' ;; login_profile_file) echo '登录时显示提示的脚本' ;;
    notify_conf) echo 'TG 通知的设置' ;; quota_conf) echo '月流量提醒的设置' ;; check_timer) echo '检查定时任务（开关）' ;;
    check_service_file) echo '检查定时任务的服务' ;; check_timer_file) echo '检查定时任务的时间' ;; check_script_file) echo '检查脚本' ;;
    dockerlog_file) echo 'Docker 的 daemon.json' ;; sshport_dropin) echo 'SSH 端口' ;;
    journal_file) echo '日志限制配置' ;; apt_auto_file) echo '自动更新开关（20auto-upgrades）' ;;
    apt_file) echo '自动更新策略文件' ;; ntp) echo '时间同步开关' ;;
    svc_timesync) echo '时间同步服务' ;; svc_trim) echo 'TRIM 定时任务' ;;
    svc_apt_daily) echo 'APT 每日更新定时器' ;; svc_apt_upgrade) echo 'APT 每日升级定时器' ;;
    tz) echo '时区' ;; ssh_dropin) echo 'SSH 仅密钥登录配置' ;; ssh_pubkey_dropin) echo 'SSH 公钥登录开关' ;;
    ufw_policy_in) echo '防火墙入站默认策略' ;; ufw_policy_out) echo '防火墙出站默认策略' ;;
    ufw_runtime) echo '防火墙开关' ;; svc_ufw) echo '防火墙服务' ;;
    f2b_jail) echo 'Fail2ban SSH 规则' ;; f2b_action) echo 'Fail2ban 封禁动作' ;; f2b_db_file) echo 'Fail2ban 封禁历史的保留时间' ;;
    svc_fail2ban) echo 'Fail2ban 服务' ;; sysctl_file) echo '内核网络安全参数' ;;
    tcp_file) echo 'TCP 缓冲区上限' ;;
    apt_reboot_file) echo '自动更新的重启时间' ;; hosts_file) echo '/etc/hosts 主机名' ;;
    hostname) echo '主机名' ;; cloud_hostname_file) echo 'cloud-init 的主机名设置' ;;
    ufw_ipv6) echo '防火墙 IPv6 防护开关' ;; *) printf '%s\n' "$1" ;;
  esac
}

restore_path() {
  case "$1" in
    bbr_file) printf '%s\n' "$BBR_FILE" ;; bbr_module) printf '%s\n' "$MODULE_FILE" ;;
    zram_file) printf '%s\n' "$ZRAM_FILE" ;; journal_file) printf '%s\n' "$JOURNAL_FILE" ;;
    zram_sysctl_file) printf '%s\n' "$ZRAM_SYSCTL_FILE" ;;
    apt_file) printf '%s\n' "$APT_FILE" ;; f2b_jail) printf '%s\n' "$F2B_FILE" ;;
    apt_auto_file) echo /etc/apt/apt.conf.d/20auto-upgrades ;;
    f2b_action) printf '%s\n' "$F2B_ACTION_FILE" ;;
    f2b_db_file) printf '%s\n' "$F2B_DB_FILE" ;;
    ssh_dropin) printf '%s\n' "$SSH_DROPIN" ;;
    ssh_pubkey_dropin) printf '%s\n' "$SSH_PUBKEY_DROPIN" ;;
    sysctl_file) printf '%s\n' "$SYSCTL_HARDENING_FILE" ;;
    tcp_file) printf '%s\n' "$TCP_BUFFER_FILE" ;;
    apt_reboot_file) printf '%s\n' "$APT_REBOOT_FILE" ;;
    hosts_file) echo /etc/hosts ;;
    cloud_hostname_file) printf '%s\n' "$CLOUD_HOSTNAME_FILE" ;;
    swap_unit) printf '%s\n' "$SWAP_UNIT_FILE" ;;
    conntrack_file) printf '%s\n' "$CONNTRACK_FILE" ;; conntrack_module) printf '%s\n' "$CONNTRACK_MODULE_FILE" ;;
    ping_file) printf '%s\n' "$PING_FILE" ;;
    keepalive_file) printf '%s\n' "$KEEPALIVE_FILE" ;; gai_file) printf '%s\n' "$GAI_FILE" ;;
    login_pam_file) printf '%s\n' "$LOGIN_PAM_FILE" ;; login_hook_file) printf '%s\n' "$STATE_ROOT/login-hook" ;;
    login_profile_file) printf '%s\n' "$LOGIN_PROFILE_FILE" ;;
    notify_conf) printf '%s\n' "$STATE_ROOT/notify.conf" ;; quota_conf) printf '%s\n' "$STATE_ROOT/quota.conf" ;;
    check_service_file) printf '%s\n' "$CHECK_SERVICE_FILE" ;; check_timer_file) printf '%s\n' "$CHECK_TIMER_FILE" ;;
    check_script_file) printf '%s\n' "$STATE_ROOT/notify-check" ;; dockerlog_file) printf '%s\n' "$DOCKER_DAEMON_FILE" ;;
    sshport_dropin) printf '%s\n' "$SSH_PORT_DROPIN" ;;
    apt_time_file) printf '%s\n' "$APT_TIME_FILE" ;;
    *) return 1 ;;
  esac
}

restore_unit() {
  case "$1" in
    svc_timesync) echo systemd-timesyncd.service ;; svc_trim) echo fstrim.timer ;;
    svc_apt_daily) echo apt-daily.timer ;; svc_apt_upgrade) echo apt-daily-upgrade.timer ;;
    svc_ufw) echo ufw.service ;; svc_fail2ban) echo fail2ban.service ;;
    *) return 1 ;;
  esac
}

restore_data_safe() {
  [[ "$1" == "$RESTORE_ROOT/"* && -f "$1" && ! -L "$1" && -O "$1" ]] && state_path_safe "$1"
}

restore_write() {
  local dir="$1" key="$2" value="$3" temp
  [[ "$dir" == "$RESTORE_ROOT/"* && "$key" =~ ^(origin_fp|last_fp|origin_value|state)$ ]] || return 1
  state_path_safe "$dir/$key" || return 1
  [[ ! -e "$dir/$key" || ( -f "$dir/$key" && -O "$dir/$key" ) ]] || return 1
  temp="$(mktemp "$dir/.write.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$temp" || ! chmod 600 "$temp" || ! mv -fT -- "$temp" "$dir/$key"; then
    rm -f -- "$temp"; return 1
  fi
}

restore_read() {
  local file="$RESTORE_ROOT/$1/$2"
  [[ "$2" =~ ^(origin_fp|last_fp|origin_value|state)$ ]] || return 1
  restore_data_safe "$file" || return 1
  cat -- "$file"
}

restore_service_value() {
  local unit load enabled running
  unit="$(restore_unit "$1")" || return 1
  load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null)" || return 1
  if [[ "$load" == not-found ]]; then echo absent; return 0; fi
  [[ "$load" == loaded || "$load" == masked ]] || return 1
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  running="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$enabled" in enabled|disabled|static|indirect|generated|masked|masked-runtime|enabled-runtime|linked|linked-runtime|alias|transient) ;; *) return 1 ;; esac
  case "$running" in active|inactive|failed) ;; *) return 1 ;; esac
  printf '%s:%s\n' "$enabled" "$running"
}

# DEFAULT_<INPUT|OUTPUT>_POLICY from /etc/default/ufw, parsed as data and
# accepted only as one simple assignment of DROP, ACCEPT or REJECT.
ufw_policy_value() {
  local file=/etc/default/ufw value
  [[ -e "$file" ]] || { echo absent; return 0; }
  [[ -f "$file" && -r "$file" ]] || return 1
  value="$(awk -v key="DEFAULT_$1_POLICY" '
    {line = $0; sub(/^[ \t]+/, "", line)}
    index(line, key "=") == 1 || index(line, key " =") == 1 {
      count++; v = line; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/"/, "", v); sub(/[ \t]+$/, "", v)
    }
    END {if (count == 1) print v}' "$file")"
  case "$value" in DROP|ACCEPT|REJECT) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

restore_value() {
  local value
  case "$1" in
    cc) value="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || return 1
        [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1; printf '%s\n' "$value" ;;
    qdisc) value="$(sysctl -n net.core.default_qdisc 2>/dev/null)" || return 1
        [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1; printf '%s\n' "$value" ;;
    ntp) value="$(timedatectl show -p NTP --value 2>/dev/null)" || return 1
        case "$value" in yes|no) printf '%s\n' "$value" ;; *) return 1 ;; esac ;;
    tz) value="$(timedatectl show -p Timezone --value 2>/dev/null)" || return 1
        [[ "$value" =~ ^[A-Za-z0-9_+/-]+$ ]] || return 1; printf '%s\n' "$value" ;;
    # The static name (what a reboot comes back with).
    hostname) value="$(head -n 1 /etc/hostname 2>/dev/null)" || return 1
        [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$ ]] || return 1; printf '%s\n' "$value" ;;
    login_pam) if login_pam_enabled; then echo enabled; else echo absent; fi ;;
    check_timer) if [[ "$(systemctl is-enabled vps-stable-check.timer 2>/dev/null || true)" == enabled ]]; then echo enabled; else echo absent; fi ;;
    ufw_policy_in) ufw_policy_value INPUT ;;
    ufw_policy_out) ufw_policy_value OUTPUT ;;
    ufw_ipv6)
      if [[ ! -e /etc/default/ufw ]]; then echo absent; return 0; fi
      [[ -f /etc/default/ufw && -r /etc/default/ufw ]] || return 1
      case "$(audit_ufw_ipv6 < /etc/default/ufw)" in yes) echo yes ;; no) echo no ;; *) echo unknown ;; esac ;;
    svc_*) restore_service_value "$1" ;;
    ufw_runtime)
      if ! command -v ufw >/dev/null; then echo absent; return 0; fi
      value="$(ufw status 2>/dev/null)" || return 1
      if grep -Fxq 'Status: active' <<< "$value"; then echo active
      elif grep -Fxq 'Status: inactive' <<< "$value"; then echo inactive
      else return 1; fi ;;
    # The swap file by size and whether it is in use (its contents change
    # all the time, so they are never hashed).
    swap_file)
      if [[ ! -e "$SWAP_FILE" && ! -L "$SWAP_FILE" ]]; then echo absent; return 0; fi
      [[ -f "$SWAP_FILE" && ! -L "$SWAP_FILE" ]] || return 1
      if swap_file_active; then printf 'file:%s:on\n' "$(stat -c %s -- "$SWAP_FILE")"
      else printf 'file:%s:off\n' "$(stat -c %s -- "$SWAP_FILE")"; fi ;;
    zram_swap)
      # Usage changes continuously, so only identity/size/priority are compared.
      awk 'NR>1 && $1=="/dev/zram0" { if ($2!="partition" || $3!~/^[0-9]+$/ || $5!~/^-?[0-9]+$/) exit 2; print $1 ":" $3 ":" $5; found=1 } END {if (!found) print "absent"}' /proc/swaps ;;
    *) return 1 ;;
  esac
}

restore_fingerprint() {
  local id="$1" path value digest metadata
  if path="$(restore_path "$id")"; then
    state_path_safe "$path" || return 1
    if [[ ! -e "$path" ]]; then echo absent; return 0; fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata="$(stat -c '%a:%u:%g' -- "$path")" || return 1
    digest="$(sha256sum -- "$path")" || return 1
    digest="${digest%% *}"
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf 'file:%s:%s\n' "$metadata" "$digest"
  else
    value="$(restore_value "$id")" || return 1
    printf 'value:%s\n' "$value"
  fi
}

restore_snapshot() {
  local id="$1" dir="$RESTORE_ROOT/$1" path fp tmp
  fp="$(restore_fingerprint "$id")" || return 1
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && -O "$dir" && ! -L "$dir" ]] || return 1
    restore_read "$id" origin_fp >/dev/null && restore_read "$id" last_fp >/dev/null && restore_read "$id" state >/dev/null
    return "$?"
  fi
  tmp="$(mktemp -d "$RESTORE_ROOT/.capture.XXXXXX")" || return 1
  chmod 700 "$tmp" || { rm -rf -- "$tmp"; return 1; }
  if path="$(restore_path "$id")"; then
    if [[ "$fp" != absent ]]; then
      if ! cp -p -- "$path" "$tmp/origin" || [[ "$(sha256sum "$tmp/origin" | awk '{print $1}')" != "${fp##*:}" ]]; then
        rm -rf -- "$tmp"; return 1
      fi
    fi
  else
    restore_value "$id" > "$tmp/origin_value" || { rm -rf -- "$tmp"; return 1; }
  fi
  # The saved original keeps its own mode; only the metadata files are 600.
  if ! printf '%s\n' "$fp" > "$tmp/origin_fp" || ! printf '%s\n' "$fp" > "$tmp/last_fp" ||
     ! printf 'clean\n' > "$tmp/state" || ! chmod 600 "$tmp/origin_fp" "$tmp/last_fp" "$tmp/state"; then
    rm -rf -- "$tmp"; return 1
  fi
  if [[ -f "$tmp/origin_value" ]] && ! chmod 600 "$tmp/origin_value"; then rm -rf -- "$tmp"; return 1; fi
  mv -T -- "$tmp" "$dir" || { rm -rf -- "$tmp"; return 1; }
}

# The first package inventory is the reference for "installed by this tool":
# a package present before the first recorded run is never offered for removal.
# Packages whose configuration was left behind then ("rc") are listed too: a
# later removal keeps that configuration (it predates the tool).
restore_prepare() {
  local tmp
  [[ "${EUID:-$(id -u)}" == 0 ]] || die '回退记录需要 root 权限。'
  RESTORE_ROOT="$STATE_ROOT/restore-v2"
  state_secure_dir "$RESTORE_ROOT"
  if [[ ! -e "$RESTORE_ROOT/packages" && ! -L "$RESTORE_ROOT/packages" ]]; then
    tmp="$(mktemp -d "$RESTORE_ROOT/.capture.XXXXXX")"
    chmod 700 -- "$tmp"
    if dpkg-query -W -f='${db:Status-Status}\t${Package}\n' 2>/dev/null > "$tmp/status" &&
       awk -F'\t' '$1 == "installed" {print $2}' "$tmp/status" | sort -u > "$tmp/before" &&
       awk -F'\t' '$1 == "config-files" {print $2}' "$tmp/status" | sort -u > "$tmp/before-rc" &&
       rm -f -- "$tmp/status" && [[ -s "$tmp/before" ]] && chmod 600 -- "$tmp/before" "$tmp/before-rc"; then
      mv -T -- "$tmp" "$RESTORE_ROOT/packages"
    else
      rm -rf -- "$tmp"
      warn '无法记录已安装软件包清单；回退时不会提供卸载软件包的选项。'
    fi
  fi
  RESTORE_READY=1
  RESTORE_STAGE=''
}

restore_record_packages() {
  local dir="$RESTORE_ROOT/packages" list pkg
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
  list="$dir/installed"
  [[ ! -L "$list" ]] || return 1
  for pkg in "$@"; do
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || continue
    installed "$pkg" || continue
    if [[ -f "$list" ]] && grep -Fxq -- "$pkg" "$list"; then continue; fi
    printf '%s\n' "$pkg" >> "$list" || return 1
  done
  if [[ -f "$list" ]]; then chmod 600 -- "$list"; fi
}

restore_record_fw_rule() {
  local rule="$1" file="$RESTORE_ROOT/fw_rules"
  [[ "$RESTORE_READY" == 1 ]] || return 0
  # A port rule, or the SSH rate-limit exemption of one allowlisted address.
  if [[ "$rule" =~ ^ufw\ allow\ from\ ([0-9A-Fa-f:.]+)\ to\ any\ port\ [0-9]{1,5}\ proto\ tcp$ ]]; then
    port_source_valid "${BASH_REMATCH[1]}" || return 1
  elif [[ ! "$rule" =~ ^ufw\ (allow|limit)\ [0-9]{1,5}/(tcp|udp)$ ]]; then
    return 1
  fi
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && grep -Fxq -- "$rule" "$file"; then return 0; fi
  printf '%s\n' "$rule" >> "$file" && chmod 600 -- "$file"
}

# A directory this tool created for one of its files: removed again by
# restore_created_dirs once it is empty.
restore_record_dir() {
  local dir="$1" file="$RESTORE_ROOT/created_dirs"
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ "$dir" == /?* && "$dir" != *$'\n'* && "/$dir/" != */../* ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && grep -Fxq -- "$dir" "$file"; then return 0; fi
  printf '%s\n' "$dir" >> "$file" && chmod 600 -- "$file"
}

# Removes the recorded directories that are empty now, deepest first. One with
# anything in it (a file of the user or of a package) stays recorded.
restore_created_dirs() {
  local file="$RESTORE_ROOT/created_dirs" dir temp
  local -a remaining=()
  [[ -e "$file" || -L "$file" ]] || return 0
  restore_data_safe "$file" || { warn '新建目录的记录不安全，已跳过。'; return 0; }
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ -d "$dir" && ! -L "$dir" && -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] &&
       rmdir -- "$dir" 2>/dev/null; then
      ok "已删除本工具创建的空目录：$dir"; continue
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then remaining+=("$dir"); fi
  done < <(sort -r -- "$file")
  if ((${#remaining[@]} == 0)); then rm -f -- "$file"; return 0; fi
  temp="$(mktemp "$RESTORE_ROOT/.write.XXXXXX")" || return 0
  if ! { printf '%s\n' "${remaining[@]}" > "$temp" && chmod 600 -- "$temp" && mv -fT -- "$temp" "$file"; }; then
    rm -f -- "$temp"
  fi
}

# Running sysctl values before this tool first changed them (first value wins).
# NAME is the record (sysctl_runtime for the hardening, zram_sysctl_runtime for
# ZRAM, tcp_sysctl_runtime for the buffers). tcp_rmem holds three numbers.
restore_record_sysctl() {
  local key="$1" value="$2" file="$RESTORE_ROOT/${3:-sysctl_runtime}"
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ "$key" =~ ^[a-z][A-Za-z0-9_.-]*$ && "$value" =~ ^-?[0-9]+(\ [0-9]+)*$ ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && awk -F= -v k="$key" '$1 == k {found = 1} END {exit !found}' "$file"; then return 0; fi
  printf '%s=%s\n' "$key" "$value" >> "$file" && chmod 600 -- "$file"
}

# Applied after the configuration file itself was removed. An interface that
# no longer exists (a container's veth) has nothing left to restore. Keys set
# by one of the FILEs (this tool's settings that stay) keep their value.
# Usage: restore_sysctl_runtime [NAME [FILE...]]
restore_sysctl_runtime() {
  local file="$RESTORE_ROOT/${1:-sysctl_runtime}" line key value failed=0 keep='' f
  if (($#)); then shift; fi
  for f in "$@"; do
    if [[ -f "$f" ]]; then keep+=" $(awk -F= '/^[[:space:]]*[a-z]/ {k = $1; gsub(/[[:space:]]/, "", k); printf "%s ", k}' "$f")"; fi
  done
  [[ -e "$file" || -L "$file" ]] || return 0
  restore_data_safe "$file" || { warn '内核参数原值记录不安全，跳过。'; RESTORE_PARTIAL=1; return 0; }
  while IFS= read -r line; do
    key="${line%%=*}"; value="${line#*=}"
    if [[ ! "$key" =~ ^[a-z][A-Za-z0-9_.-]*$ || ! "$value" =~ ^-?[0-9]+(\ [0-9]+)*$ ]]; then warn "忽略格式异常的记录：$line"; failed=1; continue; fi
    if [[ "$key" =~ ^net\.ipv([46])\.conf\.([^.]+)\.[a-z_]+$ && "${BASH_REMATCH[2]}" != all && "${BASH_REMATCH[2]}" != default &&
          ! -d "/proc/sys/net/ipv${BASH_REMATCH[1]}/conf/${BASH_REMATCH[2]}" ]]; then continue; fi
    if [[ "$keep " == *" $key "* ]]; then continue; fi
    sysctl -w "$key=$value" >/dev/null || { warn "无法恢复 $key=$value"; failed=1; }
  done < "$file"
  if ((failed)); then RESTORE_PARTIAL=1; else rm -f -- "$file"; ok '内核参数已恢复为原来的运行值。'; fi
}

restore_before_stage() {
  local stage="$1" id fp last status bad=0
  RESTORE_STAGE=''
  [[ "$RESTORE_READY" == 1 ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! restore_snapshot "$id"; then warn "无法安全保存回退基线（$id），跳过这一步：$stage。"; bad=1; continue; fi
    fp="$(restore_fingerprint "$id")" || { warn "无法读取跟踪的设置（$id），跳过这一步：$stage。"; bad=1; continue; }
    last="$(restore_read "$id" last_fp)" || { bad=1; continue; }
    status="$(restore_read "$id" state)" || { bad=1; continue; }
    case "$status" in clean|applied|restored) ;; *) bad=1; continue ;; esac
    # A hand-made change does not block the step: rollback always returns a
    # setting to its state before this tool's first run (origin_fp).
    if [[ "$fp" != "$last" ]]; then
      ok "$(restore_label "$id") 和本工具上次记下的状态不同（手动改过，或重启后系统自动变化）：按这次的选择继续。"
    fi
  done < <(restore_ids "$stage")
  ((bad == 0)) || return 1
  RESTORE_STAGE="$stage"
}

restore_after_stage() {
  local stage="$1" id fp last original status
  [[ "$RESTORE_READY" == 1 && "$RESTORE_STAGE" == "$stage" ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! fp="$(restore_fingerprint "$id")"; then
      warn "无法记录 $id 修改后的状态，回退前需要人工核对。"
      restore_write "$RESTORE_ROOT/$id" last_fp unreadable || return 1
      restore_write "$RESTORE_ROOT/$id" state applied || return 1
      continue
    fi
    original="$(restore_read "$id" origin_fp)" || return 1
    last="$(restore_read "$id" last_fp)" || return 1
    status="$(restore_read "$id" state)" || return 1
    if [[ "$fp" != "$last" ]]; then
      if [[ "$fp" == "$original" ]]; then status=clean; else status=applied; fi
    fi
    restore_write "$RESTORE_ROOT/$id" last_fp "$fp" || return 1
    restore_write "$RESTORE_ROOT/$id" state "$status" || return 1
  done < <(restore_ids "$stage")
  RESTORE_STAGE=''
}

restore_capture_failure() {
  [[ "$RESTORE_READY" == 1 && -n "$RESTORE_STAGE" ]] || return 0
  restore_after_stage "$RESTORE_STAGE"
}

# /etc/hosts is shared with the administrator and cloud-init, so only the lines
# this tool appended are recorded and removed; nothing else in it is touched.
# LINE [RECORD]: RECORD is hosts_line (the setup's) or hostname_hosts_line (a rename's).
restore_record_hosts_line() {
  local line="$1" file="$RESTORE_ROOT/${2:-hosts_line}" re=$'^127\\.0\\.1\\.1\t[A-Za-z0-9.-]+$'
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ "$line" =~ $re ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file"; then return 0; fi
  printf '%s\n' "$line" >> "$file" && chmod 600 -- "$file"
}

restore_hosts_line_present() {
  local record="$RESTORE_ROOT/${1:-hosts_line}" file
  file="$(restore_path hosts_file)" || return 1
  restore_data_safe "$record" && [[ -f "$file" ]] && grep -qxF -f "$record" -- "$file"
}

restore_hosts_lines_apply() {
  local record="$RESTORE_ROOT/${1:-hosts_line}" file temp rc=0
  file="$(restore_path hosts_file)" || return 1
  restore_data_safe "$record" && [[ -f "$file" && ! -L "$file" ]] || return 1
  temp="$(mktemp "${file%/*}/.vps-restore.XXXXXX")" || return 1
  # The copy keeps the original mode and owner; grep exits 1 when no line remains.
  cp -p -- "$file" "$temp" || rc=1
  if ((rc == 0)); then grep -vxF -f "$record" -- "$file" > "$temp" || (($? == 1)) || rc=1; fi
  if ((rc == 0)); then mv -fT -- "$temp" "$file" || rc=1; fi
  rm -f -- "$temp"
  return "$rc"
}

# True when a tracked setting differs from its state before this tool's first
# run, whoever changed it since (the agreed rollback rule).
restore_needed() {
  local id="$1"
  [[ -d "$RESTORE_ROOT/$id" ]] || return 1
  if [[ "$id" == hosts_file && -e "$RESTORE_ROOT/hosts_line" ]]; then restore_hosts_line_present; return; fi
  ! restore_at_origin "$id"
}

restore_file_apply() {
  local id="$1" path original snapshot fp dir temp
  path="$(restore_path "$id")" || return 1
  original="$(restore_read "$id" origin_fp)" || return 1
  state_path_safe "$path" || return 1
  [[ ! -e "$path" || ( -f "$path" && ! -L "$path" ) ]] || return 1
  if [[ "$original" == absent ]]; then rm -f -- "$path"; return "$?"; fi
  snapshot="$RESTORE_ROOT/$id/origin"
  restore_data_safe "$snapshot" || return 1
  [[ "$original" =~ ^file:[0-7]+:[0-9]+:[0-9]+:[a-f0-9]{64}$ ]] || return 1
  fp="$(sha256sum "$snapshot")" || return 1
  [[ "${fp%% *}" == "${original##*:}" ]] || return 1
  dir="${path%/*}"
  [[ -d "$dir" ]] || return 1
  temp="$(mktemp "$dir/.vps-restore.XXXXXX")" || return 1
  if ! cp -p -- "$snapshot" "$temp" || ! mv -fT -- "$temp" "$path"; then rm -f -- "$temp"; return 1; fi
  [[ "$(restore_fingerprint "$id")" == "$original" ]]
}

restore_service_apply() {
  local id="$1" unit original enabled running current
  unit="$(restore_unit "$id")" || return 1
  original="$(restore_read "$id" origin_value)" || return 1
  current="$(restore_service_value "$id")" || return 1
  [[ "$original" != "$current" ]] || return 0
  if [[ "$original" == absent ]]; then
    [[ "$current" != absent ]] || return 0
    systemctl stop "$unit" || return 1
    case "${current%%:*}" in enabled|disabled) systemctl disable "$unit" || return 1 ;; static|indirect|generated) ;; *) return 1 ;; esac
    [[ "$(systemctl is-active "$unit" 2>/dev/null || true)" == inactive ]]
    return "$?"
  fi
  [[ "$original" =~ ^(enabled|disabled|static|indirect|generated):(active|inactive)$ ]] || return 1
  [[ "$current" != absent ]] || return 1
  enabled="${original%%:*}"; running="${original##*:}"
  case "$enabled" in
    enabled) systemctl enable "$unit" || return 1 ;;
    disabled) systemctl disable "$unit" || return 1 ;;
    static|indirect|generated) [[ "${current%%:*}" == "$enabled" ]] || return 1 ;;
  esac
  if [[ "$running" == active ]]; then systemctl start "$unit" || return 1
  else systemctl stop "$unit" || return 1; fi
  [[ "$(restore_service_value "$id")" == "$original" ]]
}

restore_zram_safe() {
  local original used available total margin
  original="$(restore_read zram_swap origin_value)" || return 1
  [[ "$original" == absent ]] || return 1
  if ! awk 'NR>1 && $1=="/dev/zram0" {found=1} END{exit !found}' /proc/swaps; then return 0; fi
  used="$(awk 'NR>1 && $1=="/dev/zram0" {print $4}' /proc/swaps)"
  available="$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)"
  total="$(awk '$1=="MemTotal:" {print $2}' /proc/meminfo)"
  [[ "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
  margin=$((total / 10)); ((margin >= 65536)) || margin=65536
  ((available > used + margin)) || { warn '可用内存不够，现在关闭 ZRAM 不安全；先保留，稍后再试。'; return 1; }
}

restore_apply_one() {
  local id="$1" value verb
  if [[ "$id" == hosts_file && -e "$RESTORE_ROOT/hosts_line" ]]; then restore_hosts_lines_apply; return "$?"; fi
  if restore_path "$id" >/dev/null; then restore_file_apply "$id"; return "$?"; fi
  value="$(restore_read "$id" origin_value)" || return 1
  case "$id" in
    cc) [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1; sysctl -w "net.ipv4.tcp_congestion_control=$value" ;;
    qdisc) [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1; sysctl -w "net.core.default_qdisc=$value" ;;
    ntp) case "$value" in yes) timedatectl set-ntp true ;; no) timedatectl set-ntp false ;; *) return 1 ;; esac ;;
    # Taken out the way it went in (the profile file is still there for it).
    check_timer)
      [[ "$value" == absent ]] || return 1
      systemctl disable --now vps-stable-check.timer >/dev/null 2>&1 || return 1 ;;
    login_pam)
      [[ "$value" == absent ]] || return 1
      pam-auth-update --package --remove vps-stable-login || return 1
      ! login_pam_enabled ;;
    tz) [[ "$value" =~ ^[A-Za-z0-9_+/-]+$ ]] || return 1; timedatectl set-timezone "$value" ;;
    hostname) [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$ ]] || return 1
      hostnamectl --static --transient set-hostname "$value" ;;
    svc_ufw)
      # Starting ufw.service loads the firewall when ufw.conf says ENABLED=yes;
      # like the firewall switch, rollback never turns it on (now or at boot).
      if [[ "$value" == enabled:* || "$value" == *:active ]] && ! ufw_active &&
         grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*"?yes"?[[:space:]]*$' "$UFW_CONF" 2>/dev/null; then
        warn '防火墙现在没有开启：回退不会重新启动 ufw.service，也不会把它设成开机启动（那样会重新打开防火墙）。如需要，请手动处理。'
        return 1
      fi
      restore_service_apply "$id" ;;
    svc_*) restore_service_apply "$id" ;;
    ufw_policy_in|ufw_policy_out)
      [[ "$value" != absent ]] || return 0
      # Only an inactive firewall's defaults are restored; this never narrows live access.
      if ufw_active; then warn '防火墙仍处于开启状态，不自动修改默认策略。'; return 1; fi
      case "$value" in DROP) verb=deny ;; ACCEPT) verb=allow ;; REJECT) verb=reject ;; *) return 1 ;; esac
      if [[ "$id" == ufw_policy_in ]]; then ufw default "$verb" incoming >/dev/null
      else ufw default "$verb" outgoing >/dev/null; fi ;;
    ufw_ipv6)
      # Turning IPv6 filtering back off only widens access.
      case "$value" in
        absent) return 0 ;;
        yes|no) ufw_set_ipv6 "$value" || return 1
          if ufw_active; then ufw reload >/dev/null || return 1; fi ;;
        *) return 1 ;;
      esac ;;
    ufw_runtime)
      case "$value" in
        inactive|absent) if ufw_active; then ufw --force disable >/dev/null || return 1; fi ;;
        active) warn '回退不会自动重新开启防火墙；如需要，请手动执行 ufw enable。'; return 1 ;;
        *) return 1 ;;
      esac
      [[ "$(restore_value ufw_runtime)" != active ]] ;;
    # Only a swap file this tool made (none before) goes.
    swap_file)
      [[ "$value" == absent ]] || return 1
      if swap_file_active; then
        swapoff_safe "$SWAP_FILE" || { warn '可用内存不够，现在停用硬盘 Swap 不安全；先保留，稍后再试。'; return 1; }
        swapoff -- "$SWAP_FILE" || return 1
      fi
      rm -f -- "$SWAP_FILE" ;;
    zram_swap)
      restore_zram_safe || return 1
      if active dev-zram0.swap; then systemctl stop dev-zram0.swap || return 1; fi
      if [[ "$(restore_value zram_swap)" != absent ]]; then swapoff /dev/zram0 || return 1; fi
      [[ "$(restore_value zram_swap)" == absent ]] || return 1
      if active systemd-zram-setup@zram0.service; then systemctl stop systemd-zram-setup@zram0.service || return 1; fi
      # Once the package is gone that stop no longer resets the device.
      zram_reset_idle || warn '/dev/zram0 暂时无法释放，重启后会自动释放。'
      ! active dev-zram0.swap ;;
    *) return 1 ;;
  esac
}

restore_mark() {
  local id="$1" state="$2" fp
  fp="$(restore_fingerprint "$id")" || return 1
  restore_write "$RESTORE_ROOT/$id" last_fp "$fp" && restore_write "$RESTORE_ROOT/$id" state "$state"
}

restore_at_origin() {
  local id="$1" fp origin
  fp="$(restore_fingerprint "$id")" || return 1
  origin="$(restore_read "$id" origin_fp 2>/dev/null)" || return 1
  [[ "$fp" == "$origin" ]] && return 0
  [[ "$origin" == value:absent ]] || return 1
  # Not installed before: installed but switched off is equivalent (packages stay).
  case "$id" in
    ufw_runtime) [[ "$fp" == value:inactive ]] ;;
    svc_*) [[ "$fp" =~ ^value:(disabled|static|indirect|generated|masked):(inactive|failed)$ ]] ;;
    # UFW's defaults file only matters while the firewall runs.
    ufw_policy_in|ufw_policy_out|ufw_ipv6)
      case "$(restore_value ufw_runtime 2>/dev/null || true)" in inactive|absent) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Returns a setting to its state before this tool's first run, also when it was
# changed by hand since; the safety limits live in restore_apply_one.
restore_resource() {
  local id="$1" status
  [[ -d "$RESTORE_ROOT/$id" ]] || return 0
  status="$(restore_read "$id" state)" || { RESTORE_PARTIAL=1; return 0; }
  if ! restore_needed "$id"; then
    # Already back at its original state (for example undone by hand): just record it.
    if [[ "$status" == applied ]]; then
      restore_mark "$id" restored || die "无法记录回退结果：$id"
      ok "已是原始状态：$(restore_label "$id")"
    fi
    return 0
  fi
  if restore_apply_one "$id"; then
    restore_mark "$id" restored || die "无法记录回退结果：$id"
    ok "已恢复：$(restore_label "$id")"
  else
    warn "未能完整恢复：$(restore_label "$id")；恢复基线已保留，可处理后重试。"
    restore_mark "$id" applied || true
    RESTORE_PARTIAL=1
  fi
}

f2b_action_referenced_elsewhere() {
  local f
  for f in "$F2B_DIR/jail.conf" "$F2B_DIR/jail.local" "$F2B_DIR"/jail.d/*.conf "$F2B_DIR"/jail.d/*.local; do
    [[ -f "$f" && "$f" != "$F2B_FILE" ]] || continue
    grep -Fq 'vps-stable-ufw-sshd' "$f" && return 0
  done
  return 1
}

# Removes only this tool's jail and action. A Fail2ban that existed before keeps
# running with its own configuration; bans made through this tool's UFW action
# are lifted first because the action has no stop hook that would clear them.
restore_fail2ban_group() {
  local id ips ip pending=0
  local -a banned=()
  for id in f2b_jail f2b_action f2b_db_file svc_fail2ban; do
    if restore_needed "$id"; then pending=1; fi
  done
  ((pending)) || return 0
  # Deleting an action another jail still uses would break that jail.
  if restore_needed f2b_action && f2b_action_referenced_elsewhere; then
    warn '其他 Fail2ban 规则也在使用本工具的封禁动作；Fail2ban 部分整体保留，请人工检查。'
    RESTORE_PARTIAL=1; return 0
  fi
  if active fail2ban && command -v fail2ban-client >/dev/null && [[ -f "$F2B_FILE" ]] && grep -Fq 'vps-stable-ufw-sshd' "$F2B_FILE"; then
    if ips="$(fail2ban-client get sshd banip 2>/dev/null)"; then
      read -r -a banned <<< "$ips"
      for ip in "${banned[@]}"; do
        [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || continue
        fail2ban-client set sshd unbanip "$ip" >/dev/null || { warn "未能解封 $ip，对应的 UFW 拦截规则可能残留。"; RESTORE_PARTIAL=1; }
      done
      if ((${#banned[@]})); then ok "已解除本工具封禁的 ${#banned[@]} 个 IP。"; fi
    else
      warn '无法读取当前封禁列表，UFW 中的封禁规则可能残留。'; RESTORE_PARTIAL=1
    fi
  fi
  restore_resource svc_fail2ban
  restore_resource f2b_jail
  restore_resource f2b_action
  restore_resource f2b_db_file
  # Still running after its service state was restored: it ran before this tool.
  if active fail2ban; then
    if systemctl restart fail2ban; then ok '原有 Fail2ban 已按它自己的配置重新加载。'
    else warn 'Fail2ban 重新加载失败，请人工检查。'; RESTORE_PARTIAL=1; fi
  fi
}

# Deletes exactly the rules this tool added. While UFW stays on, an SSH
# allowance is never removed, so rollback cannot lock the session out.
restore_fw_rules_apply() {
  local file="$RESTORE_ROOT/fw_rules" rule verb port proto src current ufw_on=0 ssh_ports temp
  local -a remaining=() spec=()
  [[ -e "$file" || -L "$file" ]] || return 0
  restore_data_safe "$file" || { warn '防火墙规则记录不安全，已跳过。'; RESTORE_PARTIAL=1; return 0; }
  command -v ufw >/dev/null || { warn '找不到 ufw，无法删除本工具添加的规则。'; RESTORE_PARTIAL=1; return 0; }
  current="$(ufw show added)" || { warn '无法读取 UFW 规则。'; RESTORE_PARTIAL=1; return 0; }
  if ufw_active; then ufw_on=1; fi
  ssh_ports=" 22 $(ssh_candidates | sort -n -u | tr '\n' ' ') "
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    src=''
    if [[ "$rule" =~ ^ufw\ allow\ from\ ([0-9A-Fa-f:.]+)\ to\ any\ port\ ([0-9]{1,5})\ proto\ tcp$ ]]; then
      verb=allow; src="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; proto=tcp
      spec=(allow from "$src" to any port "$port" proto tcp)
    elif [[ "$rule" =~ ^ufw\ (allow|limit)\ ([0-9]{1,5})/(tcp|udp)$ ]]; then
      verb="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; proto="${BASH_REMATCH[3]}"
      spec=("$verb" "$port/$proto")
    else
      warn "忽略格式异常的规则记录：$rule"; RESTORE_PARTIAL=1; continue
    fi
    if ! grep -Fxq -- "$rule" <<< "$current"; then ok "规则已不存在：$rule"; continue; fi
    # One address's exemption from the rate limit is not the SSH access itself.
    if ((ufw_on)) && [[ -z "$src" && "$proto" == tcp && "$ssh_ports" == *" $port "* ]]; then
      warn "防火墙仍处于开启状态，保留 SSH 端口规则：$rule"; remaining+=("$rule"); RESTORE_PARTIAL=1; continue
    fi
    if ufw --force delete "${spec[@]}" >/dev/null; then ok "已删除本工具添加的规则：$rule"
    else warn "删除规则失败：$rule"; remaining+=("$rule"); RESTORE_PARTIAL=1; fi
  done < "$file"
  if ((${#remaining[@]})); then
    temp="$(mktemp "$RESTORE_ROOT/.write.XXXXXX")" || return 0
    if ! { printf '%s\n' "${remaining[@]}" > "$temp" && chmod 600 -- "$temp" && mv -fT -- "$temp" "$file"; }; then
      rm -f -- "$temp"
    fi
  else
    rm -f -- "$file"
  fi
}

# Order matters for access: turn UFW off first, then defaults and rules.
restore_firewall_group() {
  restore_resource ufw_runtime
  restore_resource ufw_policy_in
  restore_resource ufw_policy_out
  restore_resource ufw_ipv6
  restore_fw_rules_apply
  restore_resource svc_ufw
  # The kernel settings UFW applied stay after it stops; the security
  # parameters, when kept, still set some of the same keys themselves.
  if ! ufw_active; then restore_sysctl_runtime ufw_sysctl_runtime "$SYSCTL_HARDENING_FILE" "$TCP_BUFFER_FILE"; fi
}

# Both SSH drop-ins (key-only, and the key-login switch for images that had it
# off) go back to their original state, then sshd reloads once.
restore_ssh_group() {
  local id pending=0 failed=0
  for id in ssh_dropin ssh_pubkey_dropin; do
    if restore_needed "$id"; then pending=1; fi
    # "applied" with the drop-in already gone: an earlier sshd reload failed.
    if [[ "$(restore_read "$id" state 2>/dev/null || true)" == applied ]]; then pending=1; fi
  done
  ((pending)) || return 0
  if restore_needed ssh_pubkey_dropin; then
    warn 'SSH 公钥登录会恢复成原来的关闭状态，之后只能用密码登录；请确认你记得密码。'
  fi
  for id in ssh_dropin ssh_pubkey_dropin; do
    [[ -d "$RESTORE_ROOT/$id" ]] || continue
    restore_resource "$id"
    # Still "applied" means this restore failed; "clean" was never changed.
    if [[ "$(restore_read "$id" state 2>/dev/null || true)" == applied ]]; then failed=1; fi
  done
  ((failed == 0)) || return 0
  if ssh_reload; then ok '已恢复 SSH 原来的登录设置；已导入的公钥保留。'
  else
    warn 'SSH 配置已恢复，但 sshd 重新加载失败；重启 ssh 服务后生效。'
    for id in ssh_dropin ssh_pubkey_dropin; do
      if [[ -d "$RESTORE_ROOT/$id" ]]; then restore_mark "$id" applied || true; fi
    done
    RESTORE_PARTIAL=1
  fi
}

restore_zram_group() {
  local file_needed=0 swap_needed=0 tune_needed=0 origin
  if restore_needed zram_file; then file_needed=1; fi
  if restore_needed zram_swap; then swap_needed=1; fi
  if restore_needed zram_sysctl_file || [[ -s "$RESTORE_ROOT/zram_sysctl_runtime" ]]; then tune_needed=1; fi
  ((file_needed || swap_needed || tune_needed)) || return 0
  origin="$(restore_read zram_swap origin_value 2>/dev/null || true)"
  if ((swap_needed)) && [[ -n "$origin" && "$origin" != absent ]]; then
    # A swap existed before (for example the package's own default): only the
    # configuration goes back; the running swap returns to it at the next boot.
    swap_needed=0
    echo 'ZRAM 在本工具之前就有：只恢复配置文件，重启后按原来的设置生效。'
  fi
  if ((swap_needed)) && ! restore_zram_safe; then RESTORE_PARTIAL=1; return 0; fi
  if ((swap_needed)); then
    restore_resource zram_swap
    if [[ "$(restore_read zram_swap state 2>/dev/null || true)" == applied ]]; then return 0; fi
  fi
  restore_resource zram_file
  if ((file_needed)) && ! systemctl daemon-reload; then
    warn '无法重新加载 ZRAM 服务，留待下次重试。'
    restore_mark zram_file applied || die '无法记录待重试的 ZRAM 回退。'
    RESTORE_PARTIAL=1
  fi
  # A start that failed earlier would stay listed as a failed service until reboot.
  systemctl reset-failed systemd-zram-setup@zram0.service dev-zram0.swap >/dev/null 2>&1 || true
  restore_resource zram_sysctl_file
  if [[ "$(restore_read zram_sysctl_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime zram_sysctl_runtime; fi
  # The package's own default turns ZRAM on again (see restore_zram_settle).
  if [[ "$origin" == absent ]] && installed systemd-zram-generator && grep -q '^[[:space:]]*\[zram' "$ZRAM_VENDOR_FILE" 2>/dev/null; then
    warn 'systemd-zram-generator 软件包自带默认配置：它会让 ZRAM 按约一半内存重新开启（不用等重启，系统下次启动任何服务时就会开启）。要保持关闭，需要卸载这个本工具装的软件包。'
    if [[ "${RESTORE_ALL:-0}" == 1 ]]; then echo '稍后询问是否卸载本工具新装的软件包时，把它一起卸载即可。'
    else restore_packages_offer systemd-zram-generator; restore_zram_settle; fi
  elif [[ "$origin" == absent && "${RESTORE_ALL:-0}" != 1 ]] && restore_tool_package systemd-zram-generator; then
    # Without any configuration left (Debian 12, Ubuntu) the package does
    # nothing: offered for removal like vnStat.
    restore_packages_offer systemd-zram-generator
  fi
}

# The package default is read again at every daemon-reload, and swap.target
# then starts that ZRAM along with the next unit any service start pulls in:
# it is back within moments, not only after a reboot. Once the package is gone
# such a ZRAM is switched off for good; while the package stays, its ZRAM is
# started now, so what is shown is what the next boot will have.
# The swap goes off and its file away first (the unit is still there to be
# disabled), then the unit itself.
restore_swap_group() {
  if [[ -f "$SWAP_UNIT_FILE" ]] && restore_needed swap_unit; then
    if swap_file_active && ! swapoff_safe "$SWAP_FILE"; then
      warn '可用内存不够，现在停用硬盘 Swap 不安全；先保留，稍后再试。'; RESTORE_PARTIAL=1; return 0
    fi
    systemctl disable --now swapfile.swap >/dev/null 2>&1 || true
  fi
  restore_resource swap_file
  restore_resource swap_unit
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# The rename goes: cloud-init's setting, the old name, and the /etc/hosts line
# added for the new one (the setup's own hosts line stays with the hosts group).
restore_hostname_group() {
  restore_resource cloud_hostname_file
  restore_resource hostname
  # Where cloud-init writes /etc/hosts, it writes it again with the old name.
  if cloud_hosts_managed && ! cloud_hosts_refresh; then
    warn 'cloud-init 没能马上按原来的名字重写 /etc/hosts；下次开机时会恢复。'
  fi
  if [[ -s "$RESTORE_ROOT/hostname_hosts_line" ]]; then
    if restore_hosts_lines_apply hostname_hosts_line; then rm -f -- "$RESTORE_ROOT/hostname_hosts_line"
    else warn '无法从 /etc/hosts 删掉本工具为新主机名加的那一行，请人工检查。'; RESTORE_PARTIAL=1; fi
  fi
}

restore_zram_settle() {
  [[ -d "$RESTORE_ROOT/zram_swap" && ! -e "$ZRAM_FILE" ]] || return 0
  [[ "$(restore_read zram_swap origin_value 2>/dev/null || true)" == absent ]] || return 0
  if installed systemd-zram-generator; then
    grep -q '^[[:space:]]*\[zram' "$ZRAM_VENDOR_FILE" 2>/dev/null || return 0
    # Only a package this tool installed; an administrator's own stays as it is.
    restore_tool_package systemd-zram-generator || return 0
    if zram_swap_active || systemctl start dev-zram0.swap >/dev/null 2>&1; then
      warn '保留了 systemd-zram-generator：ZRAM 按它自带的默认配置（约内存一半）继续开启。要彻底关闭，以后在撤销里选「卸载本工具新装的软件包」。'
      module_result zram present 'package default'
    fi
    return 0
  fi
  # Only right after this run removed the package: a ZRAM set up some other way
  # later (zram-tools, for example) is not this step's business.
  [[ "${ZRAM_PACKAGE_REMOVED:-0}" == 1 ]] || return 0
  if restore_needed zram_swap; then restore_resource zram_swap; fi
  zram_reset_idle || true
}

# Packages this tool installed, minus anything present before its first run.
restore_tool_packages() {
  local dir="$RESTORE_ROOT/packages" pkg
  [[ -f "$dir/installed" && -f "$dir/before" ]] || return 0
  restore_data_safe "$dir/installed" && restore_data_safe "$dir/before" || return 0
  while IFS= read -r pkg; do
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || continue
    installed "$pkg" || continue
    grep -Fxq -- "$pkg" "$dir/before" && continue
    printf '%s\n' "$pkg"
  done < "$dir/installed"
}

# True when PKG is in that list. Read to the end on purpose: "| grep -q" would
# stop reading early, and under pipefail the writer's SIGPIPE makes a match fail.
restore_tool_package() {
  local pkg found=1
  while IFS= read -r pkg; do
    if [[ "$pkg" == "$1" ]]; then found=0; fi
  done < <(restore_tool_packages)
  return "$found"
}

# True when FILE is missing (nothing to keep) or matches the MD5 its package recorded.
pkg_file_unchanged() {
  local actual
  [[ -e "$1" || -L "$1" ]] || return 0
  [[ -f "$1" && ! -L "$1" ]] || return 1
  read -r actual _ < <(md5sum < "$1" 2>/dev/null || true) || actual=''
  [[ "$actual" == "$2" ]]
}

# What a purge of these packages would delete that differs from what they
# installed, as "path<TAB>package": dpkg's conffiles, files kept with ucf
# (unattended-upgrades, UFW, chrony) and the rules stored in UFW, whose
# user.rules its purge deletes without checking.
pkg_changed_configs() {
  local pkg path sum rules registry="${UCF_DIR:-/var/lib/ucf}/registry" hashfile="${UCF_DIR:-/var/lib/ucf}/hashfile"
  for pkg in "$@"; do
    while read -r path sum _; do
      [[ "$path" == /* && "$sum" =~ ^[0-9a-f]{32}$ ]] || continue
      if ! pkg_file_unchanged "$path" "$sum"; then printf '%s\t%s\n' "$path" "$pkg"; fi
    done < <(dpkg-query -W -f='${Conffiles}\n' -- "$pkg" 2>/dev/null || true)
    if [[ -f "$registry" && -f "$hashfile" ]]; then
      while read -r path; do
        sum="$(awk -v p="$path" '$2 == p {s = $1} END {print s}' "$hashfile")"
        [[ "$sum" =~ ^[0-9a-f]{32}$ ]] || continue
        if ! pkg_file_unchanged "$path" "$sum"; then printf '%s\t%s\n' "$path" "$pkg"; fi
      done < <(awk -v p="$pkg" '$1 == p && $2 ~ /^\// {print $2}' "$registry")
    fi
    if [[ "$pkg" == ufw ]] && command -v ufw >/dev/null; then
      rules="$(ufw show added 2>/dev/null | grep -c '^ufw ' || true)"
      if ((rules > 0)); then printf '%s\t%s\n' "/etc/ufw/user.rules（保存着 $rules 条规则）" "$pkg"; fi
    fi
  done
}

# Simulates first. Removal proceeds only when APT would remove nothing that
# existed before this tool's first run. With arguments, only those packages
# (of the ones this tool installed) are considered. What was removed is then
# purged, so its configuration goes too, except configuration that predates
# the tool ("rc" before its first run, or not known: recorded by an older
# version) and changed configuration the user chooses to keep.
restore_packages_offer() {
  local dir="$RESTORE_ROOT/packages" sim pkg mode chosen='' bad changed path owner
  local -a ours=() removed=() flags=() all=() purge=() kept=() old_rc=()
  mapfile -t all < <(restore_tool_packages)
  if (($#)); then
    for pkg in "${all[@]}"; do
      if [[ " $* " == *" $pkg "* ]]; then ours+=("$pkg"); fi
    done
  else
    ours=("${all[@]}")
  fi
  if ((${#ours[@]} == 0)); then
    if (($#)); then ok '没有可卸载的软件包：它们不是本工具装的，或已经卸载了。'; fi
    return 0
  fi
  say '可选：卸载本工具新装的软件包'
  printf '本工具新装、目前仍在的软件包：%s\n' "${ours[*]}"
  for mode in autoremove plain; do
    flags=()
    [[ "$mode" == autoremove ]] && flags=(--autoremove)
    sim="$(apt-get -s remove "${flags[@]}" "${ours[@]}" 2>&1)" || continue
    mapfile -t removed < <(awk '$1 == "Remv" {sub(/:.*/, "", $2); print $2}' <<< "$sim")
    bad=0
    for pkg in "${removed[@]}"; do
      if [[ "$mode" == autoremove ]]; then
        if grep -Fxq -- "$pkg" "$dir/before"; then bad=1; break; fi
      elif [[ " ${ours[*]} " != *" $pkg "* ]]; then bad=1; break; fi
    done
    if ((bad == 0 && ${#removed[@]} > 0)); then chosen="$mode"; break; fi
  done
  if [[ -z "$chosen" ]]; then
    warn '卸载这些软件包会连带删除本工具运行前就有的软件，已跳过；如需卸载请人工处理。'
    return 0
  fi
  printf '将卸载：%s\n' "${removed[*]}"
  if restore_data_safe "$dir/before-rc"; then
    for pkg in "${removed[@]}"; do
      if grep -Fxq -- "$pkg" "$dir/before-rc"; then old_rc+=("$pkg"); else purge+=("$pkg"); fi
    done
    if ((${#purge[@]})); then echo '会连同配置文件一起删除（purge），回到装之前的样子；系统升级和内核不受影响。'; fi
    if ((${#old_rc[@]})); then echo "这些软件包在本工具第一次运行前就留有配置，只卸载程序、配置留在原处：${old_rc[*]}"; fi
  else
    echo '只卸载程序（remove），配置留在原处：本工具的旧版本没有记录装之前哪些软件留有配置，为稳妥不删。系统升级和内核不受影响。'
  fi
  if [[ " ${purge[*]} " == *' fail2ban '* ]]; then echo 'Fail2ban 的封禁记录也会一起删除。'; fi
  changed="$(pkg_changed_configs "${purge[@]}")"
  if [[ -n "$changed" ]]; then
    echo '下面这些配置和软件包装上时不一样（可能是你改过的）：'
    while IFS=$'\t' read -r path owner; do printf '  %s（%s）\n' "$path" "$owner"; done <<< "$changed"
  fi
  if ! confirm_yes '确认卸载上述软件包吗？'; then ok '保留这些软件包。'; return 0; fi
  if [[ -n "$changed" ]] && ! confirm_yes '改过的这些配置也一起删除吗？选 n：这些软件包只卸载程序，配置留在原处'; then
    while IFS=$'\t' read -r _ owner; do kept+=("$owner"); done <<< "$changed"
    for pkg in "${!purge[@]}"; do
      if [[ " ${kept[*]} " == *" ${purge[pkg]} "* ]]; then unset 'purge[pkg]'; fi
    done
    purge=("${purge[@]}")
  fi
  flags=()
  [[ "$chosen" == autoremove ]] && flags=(--autoremove)
  apt_wait_idle
  if apt_run -y -q -o DPkg::Lock::Timeout=900 remove "${flags[@]}" "${ours[@]}"; then
    ok '已卸载本工具新装的软件包。'
    if [[ " ${ours[*]} " == *' systemd-zram-generator '* ]]; then ZRAM_PACKAGE_REMOVED=1; fi
    restore_packages_record
    # The packages are gone now: the purge only deletes what they left behind.
    if ((${#purge[@]})); then
      if apt_run -y -q -o DPkg::Lock::Timeout=900 purge "${purge[@]}"; then ok "已删除它们留下的配置：${purge[*]}"
      else warn "删除配置文件（purge）失败，程序已经卸载，配置留在原处：${purge[*]}"; fi
    fi
  else warn 'APT 卸载失败，请人工检查。'; RESTORE_PARTIAL=1; fi
}

# Removed tool packages would make vps check report "missing": record them as undone.
restore_packages_record() {
  local pkg
  if module_expect tools >/dev/null; then
    for pkg in "${TOOLS_PACKAGES[@]}"; do
      if ! installed "$pkg"; then module_result tools reverted '卸载了本工具装的软件包'; break; fi
    done
  fi
  if module_expect traffic >/dev/null && ! installed vnstat; then
    module_result traffic reverted '卸载了本工具装的 vnStat'
  fi
}

# Rollback groups, shared by the full rollback, per-item rollback and the
# single-item menu. Each group lists the tracked resources it restores.
# Order matters: Fail2ban lifts its UFW bans before the firewall is undone.
restore_groups() {
  printf '%s\n' fail2ban sshport firewall ssh keepalive login notify quota check dockerlog zram swap bbr sysctl tcp conntrack ping ipv4 journal updates autoreboot ntp trim timezone hostname hosts
}

restore_group_label() {
  case "$1" in
    firewall) echo '防火墙（本工具加的规则、默认策略、开关）' ;; fail2ban) echo 'Fail2ban 防爆破' ;;
    ssh) echo 'SSH 登录加固（恢复密码和 root 登录）' ;; zram) echo 'ZRAM 内存缓冲' ;; swap) echo '硬盘 Swap' ;;
    conntrack) echo '连接跟踪容量' ;; ping) echo '禁止 ping' ;;
    keepalive) echo 'SSH 保活' ;; ipv4) echo '优先使用 IPv4' ;; login) echo '登录记录和提醒（记录本身保留）' ;;
    notify) echo 'TG 通知' ;; quota) echo '月流量提醒' ;; check) echo '检查定时任务（TG 通知和流量提醒共用）' ;;
    dockerlog) echo 'Docker 容器日志上限（重启 Docker 后恢复）' ;;
    sshport) echo 'SSH 端口（回到原来的端口）' ;;
    bbr) echo 'BBR 网络加速' ;; sysctl) echo '内核网络安全参数' ;; tcp) echo 'TCP 缓冲区上限' ;;
    journal) echo '日志空间限制' ;;
    updates) echo '自动安全更新' ;; autoreboot) echo '更新后自动重启时间' ;; ntp) echo '时间同步' ;;
    trim) echo '定期 TRIM' ;; timezone) echo '时区' ;; hosts) echo '/etc/hosts 主机名' ;;
    hostname) echo '主机名（恢复原来的名字）' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

restore_group_ids() {
  case "$1" in
    firewall) printf '%s\n' ufw_runtime ufw_policy_in ufw_policy_out ufw_ipv6 svc_ufw ;;
    fail2ban) printf '%s\n' f2b_jail f2b_action f2b_db_file svc_fail2ban ;;
    ssh) printf '%s\n' ssh_dropin ssh_pubkey_dropin ;;
    zram) printf '%s\n' zram_file zram_swap zram_sysctl_file ;;
    swap) printf '%s\n' swap_unit swap_file ;;
    conntrack) printf '%s\n' conntrack_file conntrack_module ;;
    ping) printf '%s\n' ping_file ;;
    keepalive) printf '%s\n' keepalive_file ;;
    ipv4) printf '%s\n' gai_file ;;
    login) printf '%s\n' login_pam login_pam_file login_hook_file login_profile_file ;;
    notify) printf '%s\n' notify_conf ;;
    quota) printf '%s\n' quota_conf ;;
    check) printf '%s\n' check_timer check_service_file check_timer_file check_script_file ;;
    dockerlog) printf '%s\n' dockerlog_file ;;
    sshport) printf '%s\n' sshport_dropin ;;
    bbr) printf '%s\n' bbr_file bbr_module cc qdisc ;;
    sysctl) printf '%s\n' sysctl_file ;;
    tcp) printf '%s\n' tcp_file ;;
    journal) printf '%s\n' journal_file ;;
    updates) printf '%s\n' apt_auto_file apt_file apt_time_file svc_apt_daily svc_apt_upgrade ;;
    autoreboot) printf '%s\n' apt_reboot_file ;;
    ntp) printf '%s\n' ntp svc_timesync ;;
    trim) printf '%s\n' svc_trim ;;
    timezone) printf '%s\n' tz ;;
    hosts) printf '%s\n' hosts_file ;;
    hostname) printf '%s\n' hostname cloud_hostname_file ;;
  esac
}

# True when something in the group differs from its state before this tool's
# first run, or this tool's firewall rules / sysctl originals are still recorded.
restore_group_pending() {
  local group="$1" id
  while IFS= read -r id; do
    if restore_needed "$id"; then return 0; fi
    # "applied" while already at the original: a service reload is still due.
    if [[ "$(restore_read "$id" state 2>/dev/null || true)" == applied ]]; then return 0; fi
  done < <(restore_group_ids "$group")
  case "$group" in
    firewall) [[ -s "$RESTORE_ROOT/fw_rules" ]] && return 0 ;;
    sysctl) [[ -s "$RESTORE_ROOT/sysctl_runtime" ]] && return 0 ;;
    tcp) [[ -s "$RESTORE_ROOT/tcp_sysctl_runtime" ]] && return 0 ;;
    conntrack) [[ -s "$RESTORE_ROOT/conntrack_sysctl_runtime" ]] && return 0 ;;
    ping) [[ -s "$RESTORE_ROOT/ping_sysctl_runtime" ]] && return 0 ;;
    zram) [[ -s "$RESTORE_ROOT/zram_sysctl_runtime" ]] && return 0 ;;
    hostname) [[ -s "$RESTORE_ROOT/hostname_hosts_line" ]] && return 0 ;;
  esac
  return 1
}

restore_group_apply() {
  local group="$1" id pending was_pending=0 partial="${RESTORE_PARTIAL:-0}"
  RESTORE_PARTIAL=0
  if restore_group_pending "$group"; then was_pending=1; fi
  case "$group" in
    firewall) restore_firewall_group ;;
    fail2ban) restore_fail2ban_group ;;
    sshport) restore_sshport_group ;;
    ssh) restore_ssh_group ;;
    zram) restore_zram_group ;;
    hostname) restore_hostname_group ;;
    swap) restore_swap_group ;;
    sysctl)
      restore_resource sysctl_file
      if [[ "$(restore_read sysctl_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime; fi ;;
    tcp)
      restore_resource tcp_file
      if [[ "$(restore_read tcp_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime tcp_sysctl_runtime; fi ;;
    conntrack)
      restore_resource conntrack_file
      restore_resource conntrack_module
      if [[ "$(restore_read conntrack_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime conntrack_sysctl_runtime; fi ;;
    notify|quota)
      restore_resource "${group}_conf"
      check_reconcile || RESTORE_PARTIAL=1 ;;
    check)
      check_remove
      while IFS= read -r id; do restore_resource "$id"; done < <(restore_group_ids check) ;;
    dockerlog)
      restore_resource dockerlog_file
      if active docker; then warn 'Docker 重启后才会回到原来的日志设置（systemctl restart docker，容器会停一下）。'; fi ;;
    keepalive)
      restore_resource keepalive_file
      ssh_reload || warn 'SSH 服务没能重新加载：新连接要等 SSH 重启后才恢复原来的保活设置。' ;;
    updates)
      while IFS= read -r id; do restore_resource "$id"; done < <(restore_group_ids updates)
      systemctl daemon-reload >/dev/null 2>&1 || true ;;
    ping)
      restore_resource ping_file
      if [[ "$(restore_read ping_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime ping_sysctl_runtime; fi ;;
    journal)
      # "applied" while already at the original: an earlier journald restart failed.
      pending=0
      if restore_needed journal_file || [[ "$(restore_read journal_file state 2>/dev/null || true)" == applied ]]; then pending=1; fi
      restore_resource journal_file
      if ((pending)) && [[ "$(restore_read journal_file state 2>/dev/null || true)" == restored ]] &&
         ! systemctl restart systemd-journald; then
        warn '日志配置已恢复，但日志服务重启失败，留待下次重试。'
        restore_mark journal_file applied || die '无法记录待重试的日志回退。'
        RESTORE_PARTIAL=1
      fi ;;
    *)
      # Restore NTP policy before its service state, timers after APT policy.
      while IFS= read -r id; do restore_resource "$id"; done < <(restore_group_ids "$group") ;;
  esac
  restore_created_dirs
  # Group names are module names: vps check then reports it as undone, not broken.
  if ((was_pending && RESTORE_PARTIAL == 0)) && ! restore_group_pending "$group"; then
    module_result "$group" reverted '由撤销功能恢复'
  fi
  if ((partial)); then RESTORE_PARTIAL=1; fi
}

# Records the current state as this tool's own latest change (used when the
# tool itself turns something off from the single-item menu).
restore_adopt() {
  local id="$1" fp origin
  [[ "$RESTORE_READY" == 1 && -d "$RESTORE_ROOT/$id" ]] || return 0
  fp="$(restore_fingerprint "$id")" || return 1
  origin="$(restore_read "$id" origin_fp)" || return 1
  restore_write "$RESTORE_ROOT/$id" last_fp "$fp" || return 1
  if [[ "$fp" == "$origin" ]]; then restore_write "$RESTORE_ROOT/$id" state clean
  else restore_write "$RESTORE_ROOT/$id" state applied; fi
}

restore_firewall_warning() {
  if [[ "$1" == active && "$(restore_value ufw_runtime 2>/dev/null || true)" != active ]]; then
    warn '防火墙已关闭：机器上所有正在监听的端口现在都直接暴露在公网。不需要对外的服务请停掉，或在服务商安全组里限制。'
  fi
}

restore_all_groups() {
  local group firewall_before RESTORE_ALL=1
  firewall_before="$(restore_value ufw_runtime 2>/dev/null || true)"
  # Fail2ban first (its bans live in UFW), then the firewall itself.
  while IFS= read -r group; do restore_group_apply "$group"; done < <(restore_groups)
  restore_packages_offer
  restore_zram_settle
  restore_firewall_warning "$firewall_before"
}

restore_pick_group() {
  local group choice i=0 firewall_before
  local -a pending=()
  while IFS= read -r group; do
    if restore_group_pending "$group"; then pending+=("$group"); fi
  done < <(restore_groups)
  if [[ -n "$(restore_tool_packages)" ]]; then pending+=(packages); fi
  ((${#pending[@]})) || { ok '没有可以单独撤销的项目。'; return 0; }
  for group in "${pending[@]}"; do
    i=$((i + 1))
    if [[ "$group" == packages ]]; then printf '  %s. 卸载本工具新装的软件包\n' "$i"
    else printf '  %s. %s\n' "$i" "$(restore_group_label "$group")"; fi
  done
  read -r -p "要撤销哪一项？[1-$i，回车取消]: " choice || choice=''
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > i)); then ok '已取消。'; return 0; fi
  group="${pending[choice - 1]}"
  if [[ "$group" == packages ]]; then restore_packages_offer; restore_zram_settle; return 0; fi
  confirm_yes "确定撤销「$(restore_group_label "$group")」吗？" || { ok '已取消。'; return 0; }
  firewall_before="$(restore_value ufw_runtime 2>/dev/null || true)"
  restore_group_apply "$group"
  restore_firewall_warning "$firewall_before"
}

restore_main() {
  local id status count=0 rules=0 choice
  local -a pkgs=()
  [[ "${EUID:-$(id -u)}" == 0 ]] || die '撤销优化需要 root 权限。'
  [[ -t 0 ]] || die '撤销优化需要交互终端。'
  validate_vm
  RESTORE_ROOT="$STATE_ROOT/restore-v2"
  state_path_safe "$RESTORE_ROOT" || die '回退记录目录不安全。'
  [[ -d "$RESTORE_ROOT" && -O "$RESTORE_ROOT" ]] || { warn '没有本工具记录的恢复基线；无法推断运行前设置。'; return 0; }
  start_logging
  say '撤销本工具的设置'
  while IFS= read -r id; do
    [[ -d "$RESTORE_ROOT/$id" ]] || continue
    status="$(restore_read "$id" state)" || die "无法读取回退记录：$id"
    case "$status" in clean|applied|restored) ;; *) die "回退记录格式异常：$id" ;; esac
    if restore_needed "$id"; then printf '待恢复：%s\n' "$(restore_label "$id")"; count=$((count + 1))
    elif [[ "$status" == applied ]]; then printf '待收尾（已经是原来的设置，撤销时只更新记录；上次服务没能重新加载的会再加载一次）：%s\n' "$(restore_label "$id")"; count=$((count + 1)); fi
  done < <(restore_all_ids)
  if [[ -f "$RESTORE_ROOT/fw_rules" ]]; then
    rules="$(grep -c . "$RESTORE_ROOT/fw_rules" || true)"
    if ((rules)); then printf '待删除：本工具添加的 %s 条防火墙规则\n' "$rules"; fi
  fi
  mapfile -t pkgs < <(restore_tool_packages)
  if ((${#pkgs[@]})); then printf '可选卸载：本工具新装的 %s 个软件包\n' "${#pkgs[@]}"; fi
  ((count + rules + ${#pkgs[@]})) || { ok '没有待撤销的已记录设置。'; return 0; }
  echo '会把本工具记录过的配置、运行参数和服务开关恢复成本工具第一次运行前的样子（你后来手动改过的也一样），并删除本工具添加的防火墙规则。'
  echo '保留：你用端口管理放行的端口、导入的 SSH 公钥、新建的管理员账户、系统升级和新内核、已执行过的 TRIM 和时间校准、已清理的旧内核。'
  echo '回退只会放宽访问（关闭防火墙、恢复密码和 root 登录），不会把你锁在外面，也不会自动重新开启防火墙。'
  echo '需要整机还原请使用服务商快照。'
  read -r -p '1) 全部撤销   2) 只撤销某一项   回车取消: ' choice || choice=''
  RESTORE_PARTIAL=0
  case "$choice" in
    1)
      confirm_yes '已备份重要业务数据，确定全部撤销吗？' || { ok '已取消撤销。'; return 0; }
      restore_all_groups ;;
    2) restore_pick_group ;;
    *) ok '已取消撤销。'; return 0 ;;
  esac
  if ((RESTORE_PARTIAL)); then
    warn "撤销只完成了一部分；没能恢复的项目及恢复基线保留在 $RESTORE_ROOT。请按上方提示处理后重试，勿先卸载工具。"
    RESTORE_EXIT_CODE=2
    return 0
  fi
  ok '撤销完成。建议检查业务状态，按需手动重启。'
  echo "恢复基线继续保留：$RESTORE_ROOT"
}

# Per-module outcome of the latest run that touched each module. vps check
# compares these expectations with the live system, typically after a reboot.
module_result() {
  local module="$1" result="$2" detail="${3:-}" dir="$STATE_ROOT/modules" temp boot
  [[ "$module" =~ ^[a-z0-9_]+$ ]] || return 0
  case "$result" in applied|present|preserved|unsupported|declined|skipped|failed|reverted) ;; *) return 0 ;; esac
  detail="$(printf '%s' "$detail" | tr -d '\000-\037\177' | cut -c1-160)"
  boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
  if [[ -n "${RUN_STATE_DIR:-}" && -d "$RUN_STATE_DIR" && ! -L "$RUN_STATE_DIR" ]]; then
    printf '%s\t%s\t%s\n' "$module" "$result" "$detail" >> "$RUN_STATE_DIR/modules.tsv" || return 0
  elif [[ "$result" != reverted ]]; then
    return 0
  else
    # Rollback runs outside a setup run: only the per-module record is updated.
    [[ -d "$STATE_ROOT" && ! -L "$STATE_ROOT" && -O "$STATE_ROOT" ]] || return 0
  fi
  state_secure_dir "$dir"
  temp="$(mktemp "$dir/.m.XXXXXX")" || return 0
  if ! printf '%s\t%s\t%s\t%s\n' "$result" "$(date -u +%FT%TZ)" "$boot" "$detail" > "$temp" ||
     ! chmod 600 -- "$temp" || ! mv -fT -- "$temp" "$dir/$module"; then
    rm -f -- "$temp"
  fi
}

# Prints "result<TAB>boot<TAB>detail" for a module, or fails when unrecorded.
# The possibly empty detail stays last: `read` merges consecutive tab separators.
module_expect() {
  local file="$STATE_ROOT/modules/$1" result boot detail
  [[ "$1" =~ ^[a-z0-9_]+$ && -f "$file" && ! -L "$file" && -O "$file" ]] || return 1
  IFS=$'\t' read -r result _ boot detail < "$file" || return 1
  case "$result" in applied|present|preserved|unsupported|declined|skipped|failed|reverted) ;; *) return 1 ;; esac
  printf '%s\t%s\t%s\n' "$result" "$boot" "$detail"
}

module_result_label() {
  case "$1" in
    applied) echo '已配置' ;; present) echo '原本就已配置好' ;; preserved) echo '保留了已有配置' ;;
    unsupported) echo '系统不支持' ;; declined) echo '你选择了不处理' ;; skipped) echo '按条件跳过' ;;
    failed) echo '开荒时没有成功' ;; reverted) echo '已撤销，恢复成本工具运行前的样子' ;; *) echo '未知' ;;
  esac
}

VERIFY_PASS=0
VERIFY_FAIL=0
VERIFY_EXIT=0
VERIFY_NA=0
VERIFY_UNKNOWN=0
VERIFY_REBOOT=0
VERIFY_UPDATE=0
VERIFY_NOTICE=0
VERIFY_ISSUES=()
# STATUS LABEL TEXT: one line of the acceptance report. What needs a look
# (failed, waiting for a reboot, unknown) is also kept for the conclusion.
verify_line() {
  local mark color='' word
  case "$1" in
    pass) VERIFY_PASS=$((VERIFY_PASS + 1)) mark="${SYM_OK-✔}" color="${C_OK-}" word='生效' ;;
    healthy) VERIFY_PASS=$((VERIFY_PASS + 1)) mark="${SYM_OK-✔}" color="${C_OK-}" word='正常' ;;
    fail) VERIFY_FAIL=$((VERIFY_FAIL + 1)) mark="${SYM_FAIL-✖}" color="${C_FAIL-}" word='未生效' ;;
    # The security audit: a sign that someone got in.
    suspect) VERIFY_FAIL=$((VERIFY_FAIL + 1)) mark="${SYM_FAIL-✖}" color="${C_FAIL-}" word='可疑' ;;
    na) VERIFY_NA=$((VERIFY_NA + 1)) mark="${SYM_SKIP-○}" word='未处理' ;;
    # Something to look at that is not this tool's (another service failing).
    notice) VERIFY_NOTICE=$((${VERIFY_NOTICE:-0} + 1)) mark="${SYM_WARN-⚠}" color="${C_WARN-}" word='注意' ;;
    # In force, but a parameter now asks for another value: not a failure.
    update) VERIFY_UPDATE=$((${VERIFY_UPDATE:-0} + 1)) mark="${SYM_WARN-⚠}" color="${C_WARN-}" word='可更新' ;;
    # Expected to take effect with the next boot: not a failure.
    reboot) VERIFY_REBOOT=$((${VERIFY_REBOOT:-0} + 1)) mark="${SYM_WARN-⚠}" color="${C_WARN-}" word='待重启' ;;
    *) VERIFY_UNKNOWN=$((VERIFY_UNKNOWN + 1)) mark="${SYM_WARN-⚠}" color="${C_WARN-}" word='无法确认' ;;
  esac
  printf '%s%s %s%s  %s：%s\n' "$color" "$mark" "$word" "${C_RESET-}" "$2" "$3"
  case "$1" in fail|suspect|reboot|unknown|update|notice) VERIFY_ISSUES+=("$color$mark $word${C_RESET-}  $2：$3") ;; esac
}

# Applies the recorded expectation: only applied/present results are checked
# against the live state; every other result is reported as intentionally unhandled.
VERIFY_STATUS=''
VERIFY_TEXT=''
verify_module() {
  local module="$1" label="$2" check="$3" info result boot detail
  if ! info="$(module_expect "$module")"; then
    verify_line na "$label" '没有开荒记录（还没运行过一键开荒或对应功能）'; return 0
  fi
  IFS=$'\t' read -r result boot detail <<< "$info"
  case "$result" in
    applied|present)
      VERIFY_STATUS=unknown VERIFY_TEXT='检查未返回结果'
      "$check" "$detail" "$boot"
      verify_line "$VERIFY_STATUS" "$label" "$VERIFY_TEXT" ;;
    failed) verify_line fail "$label" "开荒时没有成功（$detail），请查看运行日志后重试" ;;
    *) verify_line na "$label" "$(module_result_label "$result")（$detail）" ;;
  esac
}

verify_set() {
  VERIFY_STATUS="$1"
  VERIFY_TEXT="$2"
}

verify_ssh_connection_cc() {
  local rport lport
  read -r _ rport _ lport <<< "${SSH_CONNECTION:-}"
  [[ "$lport" =~ ^[0-9]+$ && "$rport" =~ ^[0-9]+$ ]] || return 1
  command -v ss >/dev/null || return 1
  ss -tinH state established "( sport = :$lport and dport = :$rport )" 2>/dev/null | grep -qw bbr
}

check_keepalive() {
  local current
  sshd_runtime_dir
  current="$(sshd -T 2>/dev/null | awk '$1 == "clientaliveinterval" {print $2}')"
  if [[ "$current" == "${1% s}" ]]; then verify_set pass "每 $current 秒检测一次空闲连接"
  elif [[ -z "$current" ]]; then verify_set unknown '读不到 sshd 实际生效的配置'
  else verify_set fail "生效的保活间隔是 ${current} 秒，不是 ${1% s} 秒"; fi
}

check_sshport() {
  local ports p rules
  ports="$(sed -n 's/^Port //p' "$SSH_PORT_DROPIN" 2>/dev/null | tr '\n' ' ')"
  [[ -n "${ports// /}" ]] || { verify_set fail "$SSH_PORT_DROPIN 不见了：SSH 回到了默认端口"; return 0; }
  for p in $ports; do port_listening "$p" || { verify_set fail "SSH 没有在端口 $p 上监听"; return 0; }; done
  if ufw_active; then
    rules="$(ufw show added 2>/dev/null || true)"
    for p in $ports; do grep -Eq "^ufw (allow|limit) $p/tcp$" <<< "$rules" || { verify_set fail "防火墙没有放行 SSH 端口 $p"; return 0; }; done
  fi
  verify_set pass "SSH 在端口 ${ports% } 上$(if ufw_active; then echo '，防火墙已放行'; fi)"
}

# The timer runs and the script is this version's.
check_timer_ok() {
  if ! systemctl is-active -q vps-stable-check.timer 2>/dev/null; then verify_set fail '检查定时任务没有运行'; return 1; fi
  if [[ "$(cat -- "$STATE_ROOT/notify-check" 2>/dev/null)" != "$(notify_check_text)" ]]; then
    verify_set update '检查脚本不是这个版本的：选 5 单项设置里这一项 → 1 开启，就会更新'; return 1
  fi
}

check_notify() {
  local last waiting
  [[ -s "$STATE_ROOT/notify.conf" ]] || { verify_set fail 'TG 的设置不见了'; return 0; }
  check_timer_ok || return 0
  last="$(cat -- "$STATE_ROOT/notify/last-run" 2>/dev/null || echo 0)"
  waiting="$(grep -c . "$STATE_ROOT/notify/queue" 2>/dev/null || true)"
  if (($(date +%s) - last > 600)); then verify_set fail "检查已经超过 10 分钟没跑了（上次：$(audit_when "$last")）"
  elif ((${waiting:-0} > 20)); then verify_set fail "有 ${waiting} 条消息发不出去：检查网络，或者 Token 是不是被作废了"
  else verify_set pass "每分钟检查一次，上次在 $(audit_when "$last")$(if ((${waiting:-0})); then echo "，${waiting} 条等着发"; fi)"; fi
}

check_quota() {
  local used quota
  [[ -s "$STATE_ROOT/quota.conf" ]] || { verify_set fail '流量提醒的设置不见了'; return 0; }
  check_timer_ok || return 0
  if read -r used quota < <(quota_status); then verify_set pass "这个周期已用 $((used / 1000)) GB / 额度 $((quota / 1000)) GB"
  else verify_set pass '已开启，还没统计（每 5 分钟累计一次）'; fi
}

# Docker reads daemon.json only when it starts, so the limits are in force once
# it started after the file was written. Its log driver says nothing: json-file
# is Docker's default whether or not it read the file.
check_dockerlog() {
  local limits mono up changed started
  [[ "$(cat -- "$DOCKER_DAEMON_FILE" 2>/dev/null)" == *"\"max-size\": \"$(param_value docker_log_max_mb)m\""* ]] ||
    { verify_set update "$DOCKER_DAEMON_FILE 里的上限和参数不一样：选 5 单项设置 → Docker 容器日志上限 → 1 开启，就会更新"; return 0; }
  limits="每个容器的日志最多 $(param_value docker_log_max_mb) MiB × $(param_value docker_log_files) 个（只对新建的容器生效）"
  if ! active docker; then verify_set pass "$limits；Docker 现在没在运行，启动时就会用上"; return 0; fi
  mono="$(systemctl show docker -p ActiveEnterTimestampMonotonic --value 2>/dev/null || true)"
  read -r up _ 2>/dev/null < /proc/uptime || up=''
  up="${up%%.*}"
  changed="$(stat -c %Y -- "$DOCKER_DAEMON_FILE" 2>/dev/null || true)"
  if [[ ! "$mono" =~ ^[1-9][0-9]*$ || ! "$up" =~ ^[0-9]+$ || ! "$changed" =~ ^[0-9]+$ ]]; then
    verify_set unknown "$limits；读不到 Docker 是什么时候启动的，无法确认它读到了这个设置"; return 0
  fi
  # Seconds since the epoch; uptime is whole seconds, hence the margin.
  started=$(($(date +%s) - up + mono / 1000000))
  if ((changed > started + 2)); then verify_set update 'Docker 在改了设置之后还没重启，设置还没生效：systemctl restart docker（容器会停一下）'
  else verify_set pass "$limits"; fi
}

check_login() {
  local count
  if ! login_pam_enabled; then verify_set fail "$PAM_COMMON_SESSION 里没有本工具的那一行了：登录不会再记录"; return 0; fi
  if [[ ! -f "$STATE_ROOT/login-hook" || "$(cat -- "$STATE_ROOT/login-hook" 2>/dev/null)" != "$(login_hook_text)" ||
        "$(cat -- "$LOGIN_PROFILE_FILE" 2>/dev/null)" != "$(login_profile_text)" ]]; then
    verify_set update '登录记录脚本不是这个版本的：选 5 单项设置 → 登录记录和提醒 → 1 开启，就会更新'; return 0
  fi
  count="$(login_recent 20000 | grep -c . || true)"
  verify_set pass "已开启，记下了 ${count} 次登录"
}

check_ipv4() {
  local first
  if ! grep -Fxq 'precedence ::ffff:0:0/96  100' "$GAI_FILE" 2>/dev/null; then verify_set fail "$GAI_FILE 里没有优先 IPv4 的设置了"; return 0; fi
  if [[ "$OS" == ubuntu ]]; then first=archive.ubuntu.com; else first=deb.debian.org; fi
  first="$(getent ahosts "$first" 2>/dev/null | awk 'NR == 1 {print $1}')"
  if [[ "$first" == *:* ]]; then verify_set fail "设置在，但解析结果仍是 IPv6 在前（$first）"
  else verify_set pass "解析时 IPv4 排在前面${first:+（例如 $first）}"; fi
}

check_conntrack() {
  local line bad=''
  [[ -f "$CONNTRACK_FILE" ]] || { verify_set fail "配置文件不在了：$CONNTRACK_FILE"; return 0; }
  while IFS= read -r line; do
    case "$line" in 'bad '*|'missing '*) bad+=" ${line#* }" ;; esac
  done < <(sysctl_file_mismatch "$CONNTRACK_FILE")
  if [[ -n "$bad" ]]; then verify_set fail "这些参数的当前值和配置不一致（开机时连接跟踪模块可能加载晚了）：${bad# }"
  else verify_set pass "上限 $(sysctl -n net.netfilter.nf_conntrack_max) 条、已建立连接保留 $(($(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established) / 3600)) 小时"; fi
}

check_ping() {
  if [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == 1 ]]; then verify_set pass '不回应 ping'
  else verify_set fail '又在回应 ping 了（net.ipv4.icmp_echo_ignore_all 不是 1）'; fi
}

# How full the connection tracking table is (a full one drops new connections).
verify_conntrack_usage() {
  local count max pct
  count="$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || true)"
  max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ && "$max" =~ ^[1-9][0-9]*$ ]] || return 0
  pct=$((count * 100 / max))
  if ((pct >= 70)); then
    verify_line notice '连接跟踪' "用了 ${pct}%（${count}/${max}）：满了以后新连接会被丢弃。可以在单项设置 → 连接跟踪容量 里加大上限，或缩短已建立连接的保留时间"
  else verify_line healthy '连接跟踪' "用了 ${pct}%（${count}/${max}）"; fi
}

# SIZE: this tool's disk swap in use, at that size, started at boot.
check_swap() {
  local size
  size="$(awk -v n="$SWAP_FILE" 'NR > 1 && $1 == n {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
  if [[ -z "$size" ]]; then verify_set fail "$SWAP_FILE 没有在用"
  elif ! systemctl is-enabled -q swapfile.swap 2>/dev/null; then verify_set fail "$SWAP_FILE 在用，但开机不会启用（swapfile.swap 没有启用）"
  else verify_set pass "$SWAP_FILE，约 ${size} MiB，排在 ZRAM 后面"; fi
}

# NAME: the hostname this tool set, still in force (after a reboot too) and resolving.
check_hostname() {
  local now static=''
  now="$(hostname 2>/dev/null || true)"
  static="$(head -n 1 /etc/hostname 2>/dev/null || true)"
  if [[ "$now" != "$1" || "$static" != "$1" ]]; then
    verify_set fail "主机名现在是 ${now:-未知}（/etc/hostname：${static:-未知}），不是改好的 $1：可能被服务商的初始化程序改回去了"
  elif ! hostname_resolves; then verify_set fail "主机名 $1 解析不了：sudo 会报 unable to resolve host"
  elif [[ -f "$CLOUD_HOSTNAME_FILE" ]]; then verify_set pass "$1（能解析；cloud-init 开机时不会改回）"
  else verify_set pass "$1（能解析）"; fi
}

check_bbr() {
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [[ "$cc" == bbr && "$qd" == fq ]]; then
    if verify_ssh_connection_cc; then verify_set pass '默认算法 bbr、默认队列 fq；当前 SSH 连接实际在用 bbr'
    else verify_set pass '默认算法 bbr、默认队列 fq'; fi
  else verify_set fail "当前拥塞算法 ${cc:-未知}、默认队列 ${qd:-未知}（重启后配置没有加载）"; fi
}

check_zram() {
  local size line bad='' algorithm want
  size="$(awk 'NR > 1 && $1 == "/dev/zram0" {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
  [[ -n "$size" ]] || { verify_set fail '没有找到正在使用的 /dev/zram0'; return 0; }
  if [[ -f "$ZRAM_SYSCTL_FILE" ]]; then
    while IFS= read -r line; do
      case "$line" in 'bad '*) bad+=" ${line#bad }" ;; esac
    done < <(sysctl_file_mismatch "$ZRAM_SYSCTL_FILE")
  fi
  # The selected algorithm is the bracketed one: "lzo [lz4] zstd".
  algorithm="$(sed -n 's/.*\[\([a-z0-9-]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null || true)"
  want="$(awk -F' *= *' '$1 == "compression-algorithm" {print $2}' "$ZRAM_FILE" 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then verify_set fail "/dev/zram0 已启用，但配套内存参数和配置不一致：${bad# }"
  elif [[ "$1" == *'(from next boot)'* && "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" == "${2:-}" ]] ||
       [[ -n "$want" && -n "$algorithm" && "$want" != "$algorithm" ]]; then
    verify_set reboot "改过的 ZRAM 设置（${1% (from next boot)}${want:+，$want}）重启后生效；现在是约 ${size} MiB${algorithm:+，$algorithm}"
  else verify_set pass "/dev/zram0 已启用，约 ${size} MiB${algorithm:+，压缩算法 $algorithm}"; fi
}

check_ntp() {
  local up
  if ntp_synced; then verify_set pass '系统时间已同步'; return 0; fi
  up="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 9999)"
  if ((up < 180)); then verify_set unknown '刚开机不久，时间同步可能还在进行，过几分钟再查'
  else verify_set fail '时间尚未同步，请检查时间同步服务'; fi
}

check_journal() {
  local value days usage want want_days
  value="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '$1 == "SystemMaxUse" {v = $2} END {print v}' || true)"
  days="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '$1 == "MaxRetentionSec" {v = $2} END {print v}' || true)"
  usage="$(journalctl --disk-usage 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)?[KMGT]?B?' | head -n 1 || true)"
  want="$(param_value journal_max_mb)M" want_days="$(param_value journal_days)day"
  if [[ "$value" != "$1" && "$value" != "${1#SystemMaxUse=}" ]]; then verify_set fail "当前生效的日志上限是 ${value:-默认值}，不是 ${1#SystemMaxUse=}"
  elif [[ "${1#SystemMaxUse=}" != "$want" || "$days" != "$want_days" ]]; then
    verify_set update "生效的是上限 ${value}、保留 ${days:-不限}，现在应是 ${want}、${want_days}：选 5 单项设置 → 日志空间限制 → 开启，就会更新"
  else verify_set pass "日志上限 ${value}、保留 ${days} 已生效，当前占用 ${usage:-未知}"; fi
}

check_trim() {
  local next
  if ! trim_support; then verify_set na '系统盘不支持 TRIM（DISC-MAX 为 0），定期 TRIM 不起作用'; return 0; fi
  if systemctl is-enabled -q fstrim.timer 2>/dev/null && active fstrim.timer; then
    next="$(systemctl show fstrim.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
    verify_set pass "定期 TRIM 已启用${next:+，下次执行 $next}"
  else verify_set fail 'fstrim.timer 没有启用或没有运行'; fi
}

check_updates() {
  local periodic
  periodic="$(apt-config dump 2>/dev/null || true)"
  if grep -Fq 'APT::Periodic::Update-Package-Lists "1";' <<< "$periodic" &&
     grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' <<< "$periodic" && active apt-daily-upgrade.timer; then
    verify_set pass '自动安全更新已开启，定时器在运行'
  else verify_set fail '自动更新策略或 apt-daily-upgrade.timer 不完整'; fi
}

check_tools() {
  local pkg absent=''
  for pkg in "${TOOLS_PACKAGES[@]}"; do installed "$pkg" || absent+=" $pkg"; done
  if [[ -z "$absent" ]]; then verify_set pass "${TOOLS_PACKAGES[*]}"
  else verify_set fail "缺少：${absent# }"; fi
}

check_timezone() {
  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ -n "$1" && "$current" == "$1" ]]; then verify_set pass "当前时区 $current"
  else verify_set fail "当前时区 ${current:-未知}，预期 $1"; fi
}

check_ssh() {
  local root_value
  if ! ssh_password_disabled; then verify_set fail '当前生效的 SSH 配置仍允许密码登录'; return 0; fi
  if [[ "$1" == *root-ssh=off* ]]; then
    root_value="$(ssh_effective_value "$(ssh_effective root || true)" permitrootlogin)"
    if [[ "$root_value" != no ]]; then verify_set fail "密码登录已关闭，但 root 仍可直接 SSH 登录（PermitRootLogin=${root_value:-未知}）"; return 0; fi
    local who="${1#*user=}"
    verify_set pass "只允许密钥登录，root 不能直接 SSH 登录（管理员：${who%% *}）"
  else
    verify_set pass '只允许密钥登录（密码登录已关闭）'
  fi
}

# How UFW treats new SSH connections to PORT, from `ufw status` (IPv4 rules in
# order): the first rule for every source decides; an earlier allow for some
# sources only (an admin address) makes it "restricted"; earlier denies for
# single sources (Fail2ban bans) do not matter. Prints allow, restricted, deny
# or missing.
ufw_ssh_access() {
  local status="$1" port="$2" line to action dir from spec proto item covered restricted=0
  local -a list=()
  while IFS= read -r line; do
    [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+(ALLOW|DENY|REJECT|LIMIT)(\ (IN|OUT|FWD))?[[:space:]]+(.*[^[:space:]])[[:space:]]*$ ]] || continue
    to="${BASH_REMATCH[1]}" action="${BASH_REMATCH[2]}" dir="${BASH_REMATCH[4]}" from="${BASH_REMATCH[5]}"
    [[ -z "$dir" || "$dir" == IN ]] || continue
    # A rule comment (ufw ... comment 'x') is shown after the source as "# x".
    from="${from%%#*}"; from="${from%"${from##*[![:space:]]}"}"

    if [[ "$to" == OpenSSH ]]; then spec=22 proto=tcp
    elif [[ "$to" =~ ^([0-9:,]+)(/(tcp|udp))?$ ]]; then spec="${BASH_REMATCH[1]}" proto="${BASH_REMATCH[3]:-both}"
    else continue; fi
    [[ "$proto" != udp ]] || continue
    covered=0
    IFS=, read -r -a list <<< "$spec"
    for item in "${list[@]}"; do if port_item_covers "$item" "$port"; then covered=1; fi; done
    ((covered)) || continue
    if [[ "$from" == Anywhere ]]; then
      case "$action" in
        ALLOW|LIMIT) echo allow ;;
        *) if ((restricted)); then echo restricted; else echo deny; fi ;;
      esac
      return 0
    fi
    if [[ "$action" == ALLOW || "$action" == LIMIT ]]; then restricted=1; fi
  done <<< "$status"
  if ((restricted)); then echo restricted; else echo missing; fi
}

check_firewall() {
  local status verbose p missing='' blocked='' limited='' boot ipv6='UNKNOWN'
  command -v ufw >/dev/null || { verify_set fail 'ufw 未安装'; return 0; }
  if ! ufw_active; then verify_set fail '防火墙没有开启（重启后未生效或被关闭）'; return 0; fi
  status="$(ufw status 2>/dev/null || true)"
  verbose="$(ufw status verbose 2>/dev/null || true)"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$(ufw_ssh_access "$status" "$p")" in
      allow) ;;
      restricted) limited+=" $p" ;;
      deny) blocked+=" $p" ;;
      *) missing+=" $p" ;;
    esac
  done < <(ssh_candidates | sort -n -u)
  if [[ -r /etc/default/ufw ]]; then ipv6="$(audit_ufw_ipv6 < /etc/default/ufw)"; fi
  boot="$(systemctl is-enabled ufw.service 2>/dev/null || true)"
  if [[ -n "$blocked" ]]; then verify_set fail "SSH 端口${blocked} 被排在前面的拒绝规则挡住了（运行 ufw status numbered 查看顺序）"
  elif [[ -n "$missing" ]]; then verify_set fail "没有找到 SSH 端口${missing} 的放行规则"
  elif ! grep -Eq 'Default: (deny|reject) \(incoming\)' <<< "$verbose"; then verify_set fail '入站默认策略不是拒绝'
  elif [[ "$boot" == enabled-runtime ]]; then
    verify_set fail 'ufw.service 只在本次开机期间设为启动（enabled-runtime），重启后不会加载（运行 systemctl enable ufw 修复）'
  elif [[ "$boot" =~ ^(static|indirect|generated|alias)$ ]]; then
    verify_set unknown "防火墙现在开着；ufw.service 的启用方式比较特殊（$boot），无法确认开机时会不会加载"
  elif [[ "$boot" != enabled ]]; then
    verify_set fail '防火墙现在开着，但 ufw.service 没有设为开机启动，重启后不会加载（运行 systemctl enable ufw 修复）'
  else
    verify_set pass "已开启，开机自动加载；SSH 端口已放行${limited:+（端口${limited} 只允许指定来源连接）}；入站默认拒绝；IPv6 管理：$ipv6"
  fi
}

check_fail2ban() {
  local status failed banned actions want have key
  if ! active fail2ban || ! command -v fail2ban-client >/dev/null; then verify_set fail 'Fail2ban 服务没有运行'; return 0; fi
  # This tool's ban action is a UFW rule: without a running UFW nothing is blocked.
  if ! ufw_active; then verify_set fail '防火墙没有运行：Fail2ban 的封禁要靠防火墙执行，现在封不住任何 IP'; return 0; fi
  if ! status="$(fail2ban-client status sshd 2>/dev/null)"; then verify_set fail 'sshd 规则没有加载'; return 0; fi
  failed="$(awk -F: '/Total failed/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  banned="$(awk -F: '/Total banned/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  actions="$(fail2ban-client get sshd actions 2>/dev/null || true)"
  if [[ "$actions" != *vps-stable-ufw-sshd* ]]; then verify_set fail 'sshd 规则没有使用本工具的 UFW 封禁动作'; return 0; fi
  # The values in force against the parameters (changed and not applied yet).
  want="$(f2b_jail_text x | awk -F' = ' '$1 == "maxretry" || $1 == "findtime" || $1 == "bantime" {printf "%s ", $2}')"
  have="$(for key in maxretry findtime bantime; do printf '%s ' "$(fail2ban-client get sshd "$key" 2>/dev/null | tr -d '[:space:]')"; done)"
  if [[ "$have" != "$want" ]]; then
    verify_set update "生效的是（次数 时间窗口 封禁秒数）${have% }，参数要求 ${want% }：选 5 单项设置 → Fail2ban 防爆破 → 1 开启，就会按新值应用"; return 0
  fi
  if [[ "${failed:-0}" == 0 ]]; then
    verify_set pass '规则已加载；暂无失败登录记录（刚开机或还没被扫描，过一阵再查）'
  else
    verify_set pass "规则已加载；累计识别失败登录 ${failed} 次，累计封禁 ${banned:-0} 次"
  fi
}

# Compares each "key = value" line of FILE with the running value and prints
# "bad key=current" or "missing key". A glob key (net.ipv6.conf.*.x) is checked
# on every interface it covers (under PROC, /proc/sys by default).
sysctl_file_mismatch() {
  local proc="${2:-/proc/sys}" key value current path
  while IFS='=' read -r key value; do
    key="${key//[[:space:]]/}"; value="${value//[[:space:]]/}"
    [[ -n "$value" ]] || continue
    if [[ "$key" =~ ^[a-z0-9_.-]+$ ]]; then
      current="$(sysctl -n "$key" 2>/dev/null || true)"
      # Whitespace inside multi-value keys (tabs vs spaces) is not a mismatch.
      current="${current//[[:space:]]/}"
      if [[ -z "$current" ]]; then echo "missing $key"
      elif [[ "$current" != "$value" ]]; then echo "bad $key=$current"; fi
    elif [[ "$key" =~ ^[a-z0-9_.-]+\*[a-z0-9_.-]*$ ]]; then
      for path in "$proc"/${key//.//}; do
        [[ -f "$path" ]] || continue
        current="$(cat -- "$path" 2>/dev/null || true)"
        if [[ "$current" != "$value" ]]; then path="${path#"$proc"/}"; echo "bad ${path//\//.}=$current"; fi
      done
    fi
  done < "$1"
}

check_sysctl() {
  local line bad='' missing=''
  [[ -f "$SYSCTL_HARDENING_FILE" ]] || { verify_set fail "配置文件不在了：$SYSCTL_HARDENING_FILE"; return 0; }
  while IFS= read -r line; do
    case "$line" in 'bad '*) bad+=" ${line#bad }" ;; 'missing '*) missing+=" ${line#missing }" ;; esac
  done < <(sysctl_file_mismatch "$SYSCTL_HARDENING_FILE")
  if [[ -n "$bad" ]]; then verify_set fail "这些参数的当前值和配置不一致：${bad# }"
  elif [[ -n "$missing" ]]; then verify_set unknown "其余已生效；这些参数读不到（内核或容器不提供），无法确认：${missing# }"
  else verify_set pass "已生效（$1）"; fi
}

check_tcp() {
  local line bad='' missing=''
  [[ -f "$TCP_BUFFER_FILE" ]] || { verify_set fail "配置文件不在了：$TCP_BUFFER_FILE"; return 0; }
  while IFS= read -r line; do
    case "$line" in 'bad '*) bad+=" ${line#bad }" ;; 'missing '*) missing+=" ${line#missing }" ;; esac
  done < <(sysctl_file_mismatch "$TCP_BUFFER_FILE")
  if [[ -n "$bad" ]]; then verify_set fail "这些参数的当前值和配置不一致：${bad# }"
  elif [[ -n "$missing" ]]; then verify_set unknown "其余已生效；这些参数读不到，无法确认：${missing# }"
  elif [[ "$1" != "$(param_value tcp_buffer_mib) MiB" ]]; then
    if param_read tcp_buffer_mib > /dev/null; then verify_set update "生效的上限是 $1，你设置的是 $(param_value tcp_buffer_mib) MiB：选 5 单项设置 → TCP 缓冲区上限 → 开启，就会按新值应用"
    else verify_set update "生效的上限是 $1，本机现在推荐 $(param_value tcp_buffer_mib) MiB（内存 ${MEM_MIB:-?} MiB）：选 5 单项设置 → TCP 缓冲区上限 → 开启，就会更新"; fi
  else verify_set pass "已生效（上限 $1，$(param_mode tcp_buffer_mib)）"; fi
}

check_autoreboot() {
  local dump
  dump="$(apt-config dump 2>/dev/null || true)"
  if grep -Fq 'Unattended-Upgrade::Automatic-Reboot "true";' <<< "$dump" &&
     grep -Fq "Unattended-Upgrade::Automatic-Reboot-Time \"$1\";" <<< "$dump"; then
    verify_set pass "需要重启的更新会在每天 $1 自动重启"
  else verify_set fail '自动重启策略没有生效'; fi
}

check_traffic() {
  if active vnstat; then verify_set pass 'vnStat 正在统计流量，用 vnstat 命令查看'
  else verify_set fail 'vnStat 服务没有运行'; fi
}

check_hosts() {
  if hostname_resolves; then verify_set pass "主机名 $(hostname) 可以正常解析"
  else verify_set fail "主机名 $(hostname) 仍无法解析"; fi
}

# Installed kernel versions from /boot (or DIR), oldest first.
boot_kernels() {
  local f
  for f in "${1:-/boot}"/vmlinuz-*; do
    if [[ -f "$f" ]]; then printf '%s\n' "${f##*/vmlinuz-}"; fi
  done | sort -V
}

# Arguments allow isolated tests (boot directory, reboot-required flag).
verify_kernel() {
  local boot="${1:-/boot}" flag="${2:-/var/run/reboot-required}" running newest installed uptime=''
  local -a kernels=()
  running="$(uname -r)"
  mapfile -t kernels < <(boot_kernels "$boot")
  if ((${#kernels[@]} == 0)); then verify_line unknown '内核' "正在运行 $running；/boot 中没有内核文件（服务商可能使用外部内核）"; return 0; fi
  newest="${kernels[-1]}"
  if [[ "$running" != "$newest" ]]; then
    # dpkg sets the change time when it installs a file (mtime is the build date).
    installed="$(stat -c %Z -- "$boot/vmlinuz-$newest" 2>/dev/null || echo 0)"
    read -r uptime _ 2>/dev/null < /proc/uptime || uptime=''
    uptime="${uptime%%.*}"
    if [[ "$uptime" =~ ^[0-9]+$ && "$installed" =~ ^[0-9]+$ ]] && ((installed > $(date +%s) - uptime)); then
      verify_line reboot '内核' "新内核 $newest 是这次开机后才装的，重启后才会使用（现在运行 $running）"
    else
      verify_line fail '内核' "已安装更新的内核 $newest，但正在运行 $running：需要重启（已重启仍如此，可能是服务商外部内核或开机默认项不同）"
    fi
  elif [[ -e "$flag" ]]; then
    verify_line reboot '内核' "正在运行最新内核 $running；有其他软件包的更新要重启后才完全生效"
  else
    verify_line pass '内核' "正在运行已安装的最新内核 $running"
  fi
}

# Failed services are named (found on a real VPS: a system upgrade restarted
# systemd-networkd and its wait-online unit timed out until the next boot).
# Services this tool sets up or that keep the machine reachable: one of them
# failing is a failure here; any other failed service is a notice.
verify_health_units() {
  printf '%s\n' ssh.service sshd.service ufw.service fail2ban.service systemd-timesyncd.service chrony.service \
    vnstat.service unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
    systemd-zram-setup@zram0.service systemd-journald.service
}

verify_health() {
  local failed host units names failed_tool='' failed_other='' unit count=0 out
  units="$(systemctl list-units --state=failed --type=service --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' || true)"
  failed="$(grep -c . <<< "$units" || true)"
  if [[ "$failed" == 0 ]]; then verify_line healthy '系统服务' '本次启动没有失败的服务'
  else
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      if grep -Fxq -- "$unit" <(verify_health_units); then failed_tool+=" $unit"; else failed_other+=" $unit"; count=$((count + 1)); fi
    done <<< "$units"
    if [[ -n "$failed_tool" ]]; then
      verify_line fail '系统服务' "失败的服务：${failed_tool# }。它们和本工具的设置或远程登录有关：用 systemctl status 加服务名查看原因"
    fi
    if [[ -n "$failed_other" ]]; then
      names="$(tr ' ' '\n' <<< "${failed_other# }" | head -n 3 | tr '\n' ' ')"; names="${names% }"
      if ((count > 3)); then names+=' 等'; fi
      verify_line notice '系统服务' "有 ${count} 个其他服务失败：${names}。不是本工具设置的，不影响上面的结论；用 systemctl status 加服务名查看原因（系统升级时被重启过的服务偶尔会这样，重启后再看一次）"
    fi
  fi
  # A running sshd keeps working with a configuration it would now refuse (an
  # option dropped by a major upgrade, a typo): found here, not at the next
  # restart, when SSH would not come up.
  if command -v sshd >/dev/null; then
    sshd_runtime_dir
    if out="$(sshd -t 2>&1)"; then verify_line healthy 'SSH 配置' 'sshd -t 检查通过，SSH 服务重启后能正常起来'
    else
      out="$(head -n 1 <<< "$out" | audit_clean_text | cut -c1-200)"
      verify_line fail 'SSH 配置' "sshd -t 没有通过（${out:-没有说明}）：现在的连接不受影响，但 SSH 服务下次重启（包括重启服务器）时会起不来。先改好配置，再用 sshd -t 确认"
    fi
  fi
  if [[ "$OS" == ubuntu ]]; then host=archive.ubuntu.com; else host=deb.debian.org; fi
  if command -v timeout >/dev/null && timeout 6s getent ahosts "$host" >/dev/null 2>&1; then
    verify_line healthy '网络与 DNS' "可以解析 $host"
  else verify_line fail '网络与 DNS' "无法解析 $host，请检查网络或 DNS"; fi
}

verify_reboot_state() {
  local current newest_boot='' file boot
  current="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  for file in "$STATE_ROOT"/modules/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    IFS=$'\t' read -r _ _ boot _ < "$file" || continue
    [[ "$boot" == "$current" ]] && newest_boot=same
    [[ -n "$newest_boot" ]] || newest_boot=other
  done
  case "$newest_boot" in
    same) printf '%s %s\n' "${SYM_WARN-⚠}" '有设置是本次开机后才做的，还没有经过重启验证：以下结果只代表当前运行状态。' ;;
    other) printf '%s %s\n' "${SYM_OK-✔}" '开荒之后已经重启过（启动 ID 已变化），以下结果代表重启后的真实状态。' ;;
    *) echo '没有找到开荒记录，只检查系统当前状态。' ;;
  esac
}

# Every acceptance line, in order (verify_summary shows them under the conclusion).
verify_checks() {
  verify_reboot_state
  verify_kernel
  verify_module bbr 'BBR 网络优化' check_bbr
  verify_module sysctl '内核网络安全参数' check_sysctl
  verify_module tcp 'TCP 缓冲区上限' check_tcp
  verify_module zram 'ZRAM 内存缓冲' check_zram
  verify_module swap '硬盘 Swap' check_swap
  verify_module conntrack '连接跟踪容量' check_conntrack
  verify_module ping '禁止 ping' check_ping
  verify_module keepalive 'SSH 保活' check_keepalive
  verify_module ipv4 '优先使用 IPv4' check_ipv4
  verify_module login '登录记录和提醒' check_login
  verify_module notify 'TG 通知' check_notify
  verify_module quota '月流量提醒' check_quota
  verify_module dockerlog 'Docker 容器日志上限' check_dockerlog
  verify_module sshport 'SSH 端口' check_sshport
  verify_module ntp '时间同步' check_ntp
  verify_module journal '日志限制' check_journal
  verify_module trim '磁盘 TRIM' check_trim
  verify_module updates '自动安全更新' check_updates
  verify_module autoreboot '更新后自动重启' check_autoreboot
  verify_module tools '常用工具' check_tools
  verify_module traffic '流量统计' check_traffic
  verify_module timezone '时区' check_timezone
  verify_module hosts '主机名解析' check_hosts
  verify_module hostname '主机名' check_hostname
  verify_module ssh 'SSH 登录加固' check_ssh
  verify_module firewall '防火墙' check_firewall
  verify_module fail2ban 'Fail2ban 防爆破' check_fail2ban
  if docker_present; then verify_line unknown 'Docker' '已安装：用 -p 发布的容器端口会绕过防火墙，请确认这些端口确实需要对外'; fi
  verify_conntrack_usage
  verify_health
}

# The acceptance report, conclusion first: the counts and what needs a look,
# then every line under "详细".
verify_summary() {
  local details issue
  VERIFY_ISSUES=()
  details="$(mktemp)" || die '无法创建临时文件。'
  verify_checks > "$details"
  say '开荒验收（只读）'
  printf '结论：%s 项正常，%s 项未生效，%s 项按计划未处理，%s 项无法确认' "$VERIFY_PASS" "$VERIFY_FAIL" "$VERIFY_NA" "$VERIFY_UNKNOWN"
  if ((${VERIFY_REBOOT:-0})); then printf '，%s 项等重启后生效' "$VERIFY_REBOOT"; fi
  if ((${VERIFY_UPDATE:-0})); then printf '，%s 项可以按新的参数更新' "$VERIFY_UPDATE"; fi
  if ((${VERIFY_NOTICE:-0})); then printf '；另有 %s 条提醒' "$VERIFY_NOTICE"; fi
  echo '。'
  if ((${#VERIFY_ISSUES[@]})); then
    echo '需要你看一下：'
    for issue in "${VERIFY_ISSUES[@]}"; do printf '  %s\n' "$issue"; done
  else
    printf '%s%s 没有需要处理的项目。%s\n' "${C_OK-}" "${SYM_OK-✔}" "${C_RESET-}"
  fi
  if ((VERIFY_FAIL)); then echo '“未生效”的项目请按说明处理；处理后可再次运行 vps check。'; fi
  if ((${VERIFY_REBOOT:-0})); then echo '“待重启”的项目重启后自动生效：选菜单 8 重启，重启后再选 3 验收。'; fi
  printf '\n%s详细：%s\n' "${C_BOLD-}" "${C_RESET-}"
  cat -- "$details"
  rm -f -- "$details"
}

ufw_mentions() {
  local out
  out="$(ufw status 2>/dev/null)" || return 1
  grep -Fq -- "$1" <<< "$out"
}

# Optional end-to-end ban test with documentation-only addresses (RFC 5737 /
# RFC 3849). It bans, verifies the UFW rule, unbans and verifies removal.
verify_f2b_live_test() {
  local ip i lines matched
  local -a ips=(192.0.2.123)
  if [[ -r /etc/default/ufw && "$(audit_ufw_ipv6 < /etc/default/ufw)" == yes ]]; then ips+=(2001:db8::123); fi
  say 'Fail2ban 实弹测试'
  tool_lifecycle_lock
  for ip in "${ips[@]}"; do
    if ! fail2ban-client set sshd banip "$ip" >/dev/null 2>&1; then verify_line fail "封禁 $ip" 'Fail2ban 拒绝执行封禁'; continue; fi
    for ((i = 0; i < 10; i++)); do ufw_mentions "$ip" && break; sleep 1; done
    if ufw_mentions "$ip"; then verify_line pass "封禁 $ip" 'UFW 中出现了对应的拦截规则'
    else verify_line fail "封禁 $ip" 'UFW 中没有出现拦截规则（封禁动作执行失败）'; fi
    fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1 || true
    for ((i = 0; i < 10; i++)); do ufw_mentions "$ip" || break; sleep 1; done
    if ufw_mentions "$ip"; then verify_line fail "解封 $ip" "规则仍在，请手动删除：ufw delete deny from $ip"
    else verify_line pass "解封 $ip" '拦截规则已删除，恢复原样'; fi
  done
  if command -v fail2ban-regex >/dev/null && command -v timeout >/dev/null; then
    lines="$(timeout 120s fail2ban-regex systemd-journal sshd 2>/dev/null | grep -E '^Lines:' || true)"
    matched="$(grep -Eo '[0-9]+ matched' <<< "$lines" | grep -Eo '[0-9]+' || true)"
    if [[ -n "$matched" ]]; then verify_line pass '识别规则' "在系统日志里识别出 ${matched} 条 SSH 登录失败记录"
    else verify_line unknown '识别规则' 'fail2ban-regex 没有返回结果'; fi
  fi
}

verify_main() {
  local file='' answer
  if ((EUID != 0)); then warn '开荒验收需要 root：请用 sudo vps check。'; return 0; fi
  if [[ -d "$LOG_DIR" && ! -L "$LOG_DIR" ]] && tool_data_owned "$LOG_DIR" 2>/dev/null; then
    log_rotate 'verify-*.txt' 10
    file="$LOG_DIR/verify-$(date -u +%Y%m%dT%H%M%SZ).txt"
  fi
  # No pipe: the counters must survive in this shell for the exit code.
  if [[ -n "$file" ]]; then
    echo '正在逐项检查，大约需要几秒……'
    verify_summary > "$file"
    chmod 600 -- "$file" 2>/dev/null || true
    cat -- "$file"
    sed -i 's/\x1b\[[0-9;]*m//g' -- "$file" 2>/dev/null || true
    printf '验收报告已保存：%s\n' "$file"
  else
    verify_summary
  fi
  if [[ -d "$STATE_ROOT" && ! -L "$STATE_ROOT" && -O "$STATE_ROOT" ]]; then
    printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$STATE_ROOT/verified_boot" 2>/dev/null || true
  fi
  if [[ -t 0 ]]; then
    if confirm_yes '显示详细状态吗？'; then details_report; fi
    if active fail2ban && [[ -f "$F2B_FILE" ]] && grep -Fq vps-stable-ufw-sshd "$F2B_FILE" &&
       confirm_yes '做一次 Fail2ban 实弹测试吗？（用测试保留地址模拟封禁再解封，约 30 秒）'; then
      verify_f2b_live_test
    fi
  fi
  # Last, so a failure in the optional live test counts too.
  if ((VERIFY_FAIL)); then VERIFY_EXIT=3; fi
}

# Menu banner: a completed setup was followed by a reboot that is not verified yet.
menu_reboot_hint() {
  local current verified='' file boot seen=0
  ((EUID == 0)) || return 0
  [[ -d "$STATE_ROOT/modules" && ! -L "$STATE_ROOT/modules" ]] || return 0
  current="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  [[ -n "$current" ]] || return 0
  for file in "$STATE_ROOT"/modules/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    IFS=$'\t' read -r _ _ boot _ < "$file" || continue
    [[ "$boot" == "$current" ]] && return 0
    seen=1
  done
  ((seen)) || return 0
  if [[ -f "$STATE_ROOT/verified_boot" ]]; then verified="$(cat "$STATE_ROOT/verified_boot" 2>/dev/null || true)"; fi
  [[ "$verified" != "$current" ]] || return 0
  printf '%s%s %s%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" '检测到开荒后已经重启，建议选 3 做开荒验收，确认优化真的生效。' "${C_RESET-}"
}

# Menu banner: an update waits for a reboot (a kernel installed after this
# boot, or the system's reboot-required flag), and for how long. A newer kernel
# that was already there at boot (a provider's own kernel, another boot
# default) is left to vps check. Arguments allow isolated tests.
menu_pending_reboot_hint() {
  local boot="${1:-/boot}" flag="${2:-/var/run/reboot-required}" uptime_file="${3:-/proc/uptime}"
  local newest up='' since='' text days=''
  newest="$(boot_kernels "$boot" | tail -n 1)"
  read -r up _ 2>/dev/null < "$uptime_file" || up=''
  up="${up%%.*}"
  if [[ -n "$newest" && "$newest" != "$(uname -r)" && "$up" =~ ^[0-9]+$ ]] &&
     since="$(stat -c %Z -- "$boot/vmlinuz-$newest" 2>/dev/null)" && [[ "$since" =~ ^[0-9]+$ ]] &&
     ((since > $(date +%s) - up)); then
    text="新内核 $newest 已经装好，重启后才会用上"
  elif [[ -e "$flag" ]]; then
    text='有系统更新要重启后才完全生效'; since="$(stat -c %Y -- "$flag" 2>/dev/null || true)"
  else
    return 0
  fi
  if [[ "$since" =~ ^[0-9]+$ ]] && (( $(date +%s) - since >= 86400 )); then
    days="（已等 $(( ($(date +%s) - since) / 86400 )) 天）"
  fi
  printf '%s%s %s%s：方便时选 8 重启。%s\n' "${C_WARN-}" "${SYM_WARN-⚠}" "$text" "$days" "${C_RESET-}"
}

# ---- Port management ------------------------------------------------------
# Input: 8080 | 443-600 | 8080,9000-9100. Output: one UFW port item per line
# (8080 or 443:600). Anything else, including 1-65535, is rejected.
port_parse_spec() {
  local spec="$1" item a b
  local -a items=()
  # Spaces are tidied only around separators; "80 90" must not become 8090.
  spec="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*([,-])[[:space:]]*/\1/g' <<< "$spec")"
  [[ -n "$spec" && "$spec" =~ ^[0-9,-]+$ ]] || return 1
  IFS=, read -r -a items <<< "$spec"
  ((${#items[@]})) || return 1
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([0-9]{1,5})$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$a
    elif [[ "$item" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    else return 1; fi
    ((a >= 1 && b <= 65535 && a <= b)) || return 1
    ((a == 1 && b == 65535)) && return 1
    if ((a == b)); then echo "$a"; else echo "$a:$b"; fi
  done
}

port_item_count() {
  local item="$1"
  if [[ "$item" == *:* ]]; then echo $((${item#*:} - ${item%%:*} + 1)); else echo 1; fi
}

port_item_text() {
  printf '%s\n' "${1/:/-}"
}

port_item_covers() {
  local item="$1" port="$2" a b
  a="${item%%:*}"; b="${item#*:}"
  ((port >= a && port <= b))
}

port_protocols() {
  case "${1:-both}" in tcp) echo tcp ;; udp) echo udp ;; both) printf '%s\n' tcp udp ;; *) return 1 ;; esac
}

port_source_valid() {
  local src="$1" o addr parts
  local -a octets=() groups=()
  if [[ "$src" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
    IFS=. read -r -a octets <<< "${src%%/*}"
    for o in "${octets[@]}"; do ((10#$o <= 255)) || return 1; done
    return 0
  fi
  [[ "$src" == *:* && "$src" =~ ^[0-9A-Fa-f:]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]] || return 1
  # IPv6: at most one "::", 1-4 hex digits per group, 8 groups unless "::"
  # stands for the missing ones, no stray colon at either end.
  addr="${src%%/*}"
  [[ "$addr" != *:::* && "$addr" != *::*::* ]] || return 1
  [[ "$addr" != :* || "$addr" == ::* ]] || return 1
  [[ "$addr" != *: || "$addr" == *:: ]] || return 1
  parts="${addr/::/:}"; parts="${parts#:}"; parts="${parts%:}"
  if [[ -n "$parts" ]]; then
    IFS=: read -r -a groups <<< "$parts"
    for o in "${groups[@]}"; do [[ "$o" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
  fi
  if [[ "$addr" == *::* ]]; then ((${#groups[@]} <= 7)); else ((${#groups[@]} == 8)); fi
}

port_ssh_ports() {
  local ports
  ports="$(ssh_candidates | sort -n -u)"
  [[ -n "$ports" ]] || ports=22
  printf '%s\n' "$ports"
}

# Exact `ufw show added` text for an allow rule (UFW's own canonical form).
port_rule_text() {
  local item="$1" proto="$2" src="${3:-}"
  if [[ -z "$src" ]]; then printf 'ufw allow %s/%s\n' "$item" "$proto"
  else printf 'ufw allow from %s to any port %s proto %s\n' "$src" "$item" "$proto"; fi
}

port_listen_note() {
  local item="$1" proto="$2" flag=t out
  [[ "$proto" == udp ]] && flag=u
  [[ "$item" != *:* ]] || return 0
  command -v ss >/dev/null || return 0
  out="$(ss -Hln"$flag" "( sport = :$item )" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then printf '  %s/%s：有程序正在监听\n' "$item" "$proto"
  else printf '  %s/%s：当前没有程序监听（服务启动后才能连上）\n' "$item" "$proto"; fi
}

# Names the well-known database/admin ports that the given items cover.
port_risky_names() {
  local item entry out=''
  local -a risky=(21:FTP 23:Telnet 25:SMTP 110:POP3 135:Windows-RPC 139:NetBIOS 445:SMB 1433:SQL-Server
    1521:Oracle 2375:Docker-API 2376:Docker-API 3306:MySQL 3389:RDP 5432:PostgreSQL 5900:VNC
    5984:CouchDB 6379:Redis 9200:Elasticsearch 11211:Memcached 27017:MongoDB)
  for item in "$@"; do
    for entry in "${risky[@]}"; do
      if port_item_covers "$item" "${entry%%:*}"; then out+=" ${entry%%:*}(${entry#*:})"; fi
    done
  done
  printf '%s\n' "${out# }"
}

port_open() {
  local spec="$1" proto_choice="${2:-}" src="${3:-}" item proto rule total=0 added=0 rules risky list
  local -a items=() protos=()
  # Parsed through "$(...)": a failing function inside "< <(...)" runs outside
  # this condition and set off the error trap ("[出错] line=…") on a mere typo.
  if ! list="$(port_parse_spec "$spec")" || [[ -z "$list" ]]; then
    warn "端口格式不对：$spec（例：8080、443-600、8080,9000-9100；范围 1-65535，且不能一次放行全部端口）"; return 0
  fi
  mapfile -t items <<< "$list"
  if [[ -z "$proto_choice" && -t 0 ]]; then
    read -r -p '协议：1) TCP  2) UDP  3) TCP+UDP  [回车默认 3]: ' proto_choice || true
    case "$proto_choice" in 1) proto_choice=tcp ;; 2) proto_choice=udp ;; *) proto_choice=both ;; esac
  fi
  if ! list="$(port_protocols "${proto_choice:-both}")" || [[ -z "$list" ]]; then warn "协议只能是 tcp、udp 或 both：$proto_choice"; return 0; fi
  mapfile -t protos <<< "$list"
  if [[ -n "$src" ]] && ! port_source_valid "$src"; then warn "来源地址格式不对：$src"; return 0; fi
  for item in "${items[@]}"; do total=$((total + $(port_item_count "$item") * ${#protos[@]})); done
  echo '即将放行：'
  for item in "${items[@]}"; do
    for proto in "${protos[@]}"; do
      printf '  %s/%s  来源：%s\n' "$(port_item_text "$item")" "$proto" "${src:-所有人}"
    done
  done
  printf '共 %s 个端口/协议组合。\n' "$total"
  for item in "${items[@]}"; do for proto in "${protos[@]}"; do port_listen_note "$item" "$proto"; done; done
  if ! ufw_active; then warn '防火墙当前没有开启：规则会保存，但要等防火墙开启后才生效。'; fi
  echo '提醒：服务商的安全组（云防火墙）也要放行同样的端口，否则外网仍然连不上。'
  if docker_present; then echo '注意：Docker 用 -p 发布的容器端口不受这里的规则控制（会绕过 UFW）。'; fi
  risky="$(port_risky_names "${items[@]}")"
  if [[ -n "$risky" && -z "$src" ]]; then
    warn "这些端口通常不应该对整个公网开放：$risky"
    echo "更安全的做法是只允许你自己的 IP，例如：vps port open $spec ${proto_choice:-tcp} from 你的IP"
    if ! confirm_yes '仍然对所有人开放吗？'; then ok '已取消。'; return 0; fi
  fi
  if ((total > 1000)) && ! confirm_yes "一次放行 ${total} 个端口范围较大，确定吗？"; then ok '已取消。'; return 0; fi
  confirm_yes '确认放行？' || { ok '已取消。'; return 0; }
  rules="$(ufw show added)" || { warn '无法读取 UFW 规则。'; return 0; }
  for item in "${items[@]}"; do
    for proto in "${protos[@]}"; do
      rule="$(port_rule_text "$item" "$proto" "$src")"
      if grep -Fxq -- "$rule" <<< "$rules"; then ok "已放行过，跳过：$(port_item_text "$item")/$proto"; continue; fi
      if [[ -z "$src" ]]; then ufw allow "$item/$proto" >/dev/null || { warn "放行失败：$item/$proto"; continue; }
      else ufw allow proto "$proto" from "$src" to any port "$item" >/dev/null || { warn "放行失败：$item/$proto"; continue; }; fi
      ok "已放行 $(port_item_text "$item")/$proto${src:+（仅 $src）}"
      added=$((added + 1))
    done
  done
  printf '本次新增 %s 条放行规则。回退本工具的设置时，这些业务端口会保留。\n' "$added"
}

# Parses an allow rule from `ufw show added` into "item<TAB>proto<TAB>source".
port_rule_parse() {
  local line="$1"
  if [[ "$line" =~ ^ufw\ allow\ ([0-9]+(:[0-9]+)?)/(tcp|udp)$ ]]; then
    printf '%s\t%s\t\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "$line" =~ ^ufw\ allow\ ([0-9]+(:[0-9]+)?)$ ]]; then
    printf '%s\tboth\t\n' "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^ufw\ allow\ from\ ([0-9A-Fa-f:./]+)\ to\ any\ port\ ([0-9]+(:[0-9]+)?)\ proto\ (tcp|udp)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^ufw\ allow\ from\ ([0-9A-Fa-f:./]+)\ to\ any\ port\ ([0-9]+(:[0-9]+)?)$ ]]; then
    printf '%s\tboth\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# `ufw show added` lists rules in the order UFW applies them. A split appends
# the kept protocol at the end, which is only equivalent when no rule after the
# combined one could block it: prints the first later deny/reject/limit rule
# that may match PORT for PROTO (a rule naming no port matches every port).
port_split_blocker() {
  local rules="$1" target="$2" port="$3" proto="$4" line body spec item after=0
  local -a list=()
  while IFS= read -r line; do
    if ((after == 0)); then
      if [[ "$line" == "$target" ]]; then after=1; fi
      continue
    fi
    [[ "$line" == 'ufw '* ]] || continue
    body="${line#ufw }"; body="${body#prepend }"
    if [[ "$body" =~ ^insert\ [0-9]+\ (.*)$ ]]; then body="${BASH_REMATCH[1]}"; fi
    [[ "$body" =~ ^(deny|reject|limit)\  ]] || continue
    [[ " $body " != *' out '* ]] || continue
    # A rule for the other protocol only cannot block the kept one.
    if [[ "$body" =~ (/|proto\ )(tcp|udp)(\ |$) && "${BASH_REMATCH[2]}" != "$proto" ]]; then continue; fi
    if [[ "$body" =~ \ port\ ([0-9:,]+) ]]; then spec="${BASH_REMATCH[1]}"
    elif [[ "$body" =~ ^(deny|reject|limit)\ (in\ )?([0-9:,]+)(/(tcp|udp))?$ ]]; then spec="${BASH_REMATCH[3]}"
    else printf '%s\n' "$line"; return 0; fi
    IFS=, read -r -a list <<< "$spec"
    for item in "${list[@]}"; do
      if port_item_covers "$item" "$port"; then printf '%s\n' "$line"; return 0; fi
    done
  done <<< "$rules"
  return 1
}

# A rule for TCP and UDP together (e.g. "ufw allow 22") closed for one protocol
# is split: the other protocol is allowed on its own first, then the combined
# rule goes, so nothing is ever briefly closed. No TCP access to an SSH port is
# ever removed, checked against each rule that would actually be deleted.
port_close() {
  local spec="$1" proto_choice="${2:-both}" item rules line parsed r_item r_proto r_src p hit keep i blocker list
  local -a items=() protos=() targets=() keeps=() srcs=() words=() ssh=()
  if ! list="$(port_parse_spec "$spec")" || [[ -z "$list" ]]; then
    warn "端口格式不对：$spec"; return 0
  fi
  mapfile -t items <<< "$list"
  if ! list="$(port_protocols "$proto_choice")" || [[ -z "$list" ]]; then warn "协议只能是 tcp、udp 或 both：$proto_choice"; return 0; fi
  mapfile -t protos <<< "$list"
  mapfile -t ssh < <(port_ssh_ports)
  for item in "${items[@]}"; do
    for p in "${ssh[@]}"; do
      if [[ " ${protos[*]} " == *' tcp '* ]] && port_item_covers "$item" "$p"; then
        warn "拒绝关闭：$(port_item_text "$item") 包含 SSH 端口 $p，关闭会把你锁在外面。"; return 0
      fi
    done
  done
  rules="$(ufw show added)" || { warn '无法读取 UFW 规则。'; return 0; }
  for item in "${items[@]}"; do
    hit=0
    while IFS= read -r line; do
      parsed="$(port_rule_parse "$line")" || continue
      IFS=$'\t' read -r r_item r_proto r_src <<< "$parsed"
      [[ "$r_item" == "$item" ]] || continue
      [[ "$r_proto" == both || " ${protos[*]} " == *" $r_proto "* ]] || continue
      keep='-'
      if [[ "$r_proto" == both && ${#protos[@]} == 1 ]]; then
        if [[ "${protos[0]}" == tcp ]]; then keep=udp; else keep=tcp; fi
        if blocker="$(port_split_blocker "$rules" "$line" "$r_item" "$keep")"; then
          warn "不能只关闭 $(port_item_text "$r_item")/${protos[0]}：${line#ufw } 同时放行 TCP 和 UDP，它后面还有可能挡住 $keep 的规则（${blocker#ufw }）。拆分后单独放行的 $keep 会排到那条规则后面，原来能连上的可能被挡住，所以没有改动。"
          echo "可以先关闭两种协议（vps port close $(port_item_text "$r_item") both），再按需要重新放行 $keep；需要保持规则顺序时，用 ufw insert 手动调整。"
          return 0
        fi
      fi
      if [[ "$keep" != tcp && ( "$r_proto" == tcp || "$r_proto" == both ) ]]; then
        for p in "${ssh[@]}"; do
          if port_item_covers "$r_item" "$p"; then
            warn "拒绝关闭：${line#ufw } 放行着 SSH 端口 $p 的 TCP，删除会把你锁在外面。"; return 0
          fi
        done
      fi
      targets+=("$line"); keeps+=("$keep"); srcs+=("$r_src"); hit=1
    done <<< "$rules"
    if ((hit == 0)); then
      while IFS= read -r line; do
        parsed="$(port_rule_parse "$line")" || continue
        IFS=$'\t' read -r r_item _ _ <<< "$parsed"
        if [[ "$r_item" == *:* && "$item" != "$r_item" ]] && port_item_covers "$r_item" "${item%%:*}"; then
          warn "$(port_item_text "$item") 包含在已放行的 $(port_item_text "$r_item") 里：UFW 不能单独关闭其中一部分，可以先关闭整段 $(port_item_text "$r_item")，再重新放行需要的部分。"
        fi
      done <<< "$rules"
      ok "没有找到 $(port_item_text "$item") 的放行规则。"
    fi
  done
  ((${#targets[@]})) || return 0
  echo '将删除以下放行规则：'
  for i in "${!targets[@]}"; do
    if [[ "${keeps[i]}" == - ]]; then printf '  %s\n' "${targets[i]#ufw }"
    else printf '  %s（这条同时放行 TCP 和 UDP：先单独放行 %s，再删除它，只关闭你要关的协议）\n' "${targets[i]#ufw }" "${keeps[i]}"; fi
  done
  confirm_yes '确认关闭这些端口吗？' || { ok '已取消。'; return 0; }
  for i in "${!targets[@]}"; do
    line="${targets[i]}"
    parsed="$(port_rule_parse "$line")" || continue
    IFS=$'\t' read -r r_item _ _ <<< "$parsed"
    if [[ "${keeps[i]}" != - ]]; then
      if [[ -z "${srcs[i]}" ]]; then ufw allow "$r_item/${keeps[i]}" >/dev/null || { warn "无法单独放行 $(port_item_text "$r_item")/${keeps[i]}，这条规则保持不变：${line#ufw }"; continue; }
      else ufw allow proto "${keeps[i]}" from "${srcs[i]}" to any port "$r_item" >/dev/null || { warn "无法单独放行 $(port_item_text "$r_item")/${keeps[i]}，这条规则保持不变：${line#ufw }"; continue; }; fi
      ok "已单独放行 $(port_item_text "$r_item")/${keeps[i]}${srcs[i]:+（仅 ${srcs[i]}）}"
    fi
    read -r -a words <<< "${line#ufw }"
    if ufw --force delete "${words[@]}" >/dev/null; then ok "已关闭：${line#ufw }"
    else warn "关闭失败：${line#ufw }"; fi
  done
}

port_list() {
  local rules line parsed item proto src tag p
  local -a ssh=() others=()
  rules="$(ufw show added)" || { warn '无法读取 UFW 规则。'; return 0; }
  mapfile -t ssh < <(port_ssh_ports)
  if ufw_active; then echo '防火墙状态：开启'; else echo '防火墙状态：未开启（以下规则暂不生效）'; fi
  # printf pads by bytes, and a Chinese character is 3 bytes but 2 columns
  # wide: the header is spaced by hand to line up with the rows below.
  echo '端口           协议     来源'
  while IFS= read -r line; do
    [[ "$line" == 'ufw '* ]] || continue
    if parsed="$(port_rule_parse "$line")"; then
      IFS=$'\t' read -r item proto src <<< "$parsed"
      tag=''
      for p in "${ssh[@]}"; do
        if [[ "$proto" != udp ]] && port_item_covers "$item" "$p"; then tag='（SSH）'; fi
      done
      printf '%-14s %-8s %s%s\n' "$(port_item_text "$item")" "$proto" "${src:-所有人}" "$tag"
    else
      others+=("${line#ufw }")
    fi
  done <<< "$rules"
  if ((${#others[@]})); then echo '其他规则（SSH 限速、封禁等）：'; printf '  %s\n' "${others[@]}"; fi
}

port_menu() {
  local choice spec proto src
  while :; do
    say '端口管理'
    echo '1. 放行端口   2. 关闭端口   3. 查看已放行端口   0. 返回'
    read -r -p '请选择: ' choice || return 0
    case "$choice" in
      1) read -r -p '请输入端口（例：8080 或 443-600 或 8080,9000-9100）: ' spec || return 0
         read -r -p '只允许某个 IP 访问吗？输入 IP 或网段，直接回车表示所有人: ' src || src=''
         port_open "$spec" '' "$src" ;;
      2) read -r -p '请输入要关闭的端口（格式同上）: ' spec || return 0
         read -r -p '协议：1) TCP  2) UDP  3) TCP+UDP  [回车默认 3]: ' proto || proto=''
         case "$proto" in 1) proto=tcp ;; 2) proto=udp ;; *) proto=both ;; esac
         port_close "$spec" "$proto" ;;
      3) port_list ;;
      0|'') return 0 ;;
      *) echo '无效选项。' ;;
    esac
  done
}

# vps port open SPEC [tcp|udp|both] [from IP] | close SPEC [tcp|udp|both] | list.
# A missing, misspelt or extra argument stops with an error instead of falling
# back to a wider default (such as "from" without an address meaning everyone).
port_main() {
  local action="${MODE_ARGS[0]:-}" spec='' proto=both src='' usage
  local -a rest=("${MODE_ARGS[@]:1}")
  usage='用法：vps port open 端口 [tcp|udp|both] [from IP] ｜ vps port close 端口 [tcp|udp|both] ｜ vps port list'
  [[ $EUID -eq 0 ]] || die '端口管理需要 root：请用 sudo vps port。'
  case "$action" in
    open|close)
      spec="${rest[0]:-}"
      [[ -n "$spec" ]] || die "没有写端口。$usage"
      rest=("${rest[@]:1}")
      if [[ "${rest[0]:-}" =~ ^(tcp|udp|both)$ ]]; then proto="${rest[0]}"; rest=("${rest[@]:1}"); fi
      if [[ "$action" == open && "${rest[0]:-}" == from ]]; then
        src="${rest[1]:-}"
        port_source_valid "$src" || die "from 后面要写一个 IP 地址或网段：${src:-（没有写）}"
        rest=("${rest[@]:2}")
      fi
      ((${#rest[@]} == 0)) || die "看不懂的参数：${rest[*]}。$usage" ;;
    ''|list) ((${#rest[@]} == 0)) || die "看不懂的参数：${rest[*]}。$usage" ;;
    *) die "$usage" ;;
  esac
  validate_vm
  command -v ufw >/dev/null || die '还没有安装 UFW：请先运行一键开荒或安装 ufw。'
  start_logging
  case "$action" in
    '') port_menu ;;
    open) port_open "$spec" "$proto" "$src" ;;
    close) port_close "$spec" "$proto" ;;
    list) port_list ;;
  esac
}

# ---- Single-item settings ---------------------------------------------------
# Every item can be turned on on its own (the same stage as in setup, with
# backups and rollback tracking) or have this tool's own changes undone.
# "Off" never touches a setting the system already had before this tool.
item_keys() {
  printf '%s\n' upgrade updates autoreboot bbr sysctl zram journal trim ntp timezone hosts tools vnstat kernel firewall fail2ban ssh ports tcp hostname swap conntrack ping keepalive ipv4 login notify quota dockerlog sshport
}

item_label() {
  case "$1" in
    upgrade) echo '系统升级（立即升级一次）' ;; updates) echo '自动安全更新' ;; autoreboot) echo '更新后自动重启' ;;
    bbr) echo 'BBR 网络加速' ;; sysctl) echo '内核网络安全参数' ;; zram) echo 'ZRAM 内存缓冲' ;;
    journal) echo '日志空间限制' ;; trim) echo '定期 TRIM' ;; ntp) echo '时间同步' ;; timezone) echo '时区' ;;
    hosts) echo '主机名解析' ;; hostname) echo '主机名和显示名' ;; swap) echo '硬盘 Swap' ;; tools) echo '常用工具' ;;
    conntrack) echo '连接跟踪容量' ;; ping) echo '禁止 ping' ;; keepalive) echo 'SSH 保活' ;; ipv4) echo '优先使用 IPv4' ;; vnstat) echo 'vnStat 流量统计' ;; kernel) echo '清理旧内核' ;;
    login) echo '登录记录和提醒' ;;
    notify) echo 'TG 通知' ;; quota) echo '月流量提醒' ;; dockerlog) echo 'Docker 容器日志上限' ;; sshport) echo 'SSH 端口' ;;
    firewall) echo '防火墙' ;; fail2ban) echo 'Fail2ban 防爆破' ;; ssh) echo 'SSH 登录加固' ;; ports) echo '端口管理' ;;
    tcp) echo 'TCP 缓冲区上限（跨洲代理提速）' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Read-only, one line per item.
item_status() {
  local value count=0 total=0 pkg dump
  case "$1" in
    upgrade)
      value="$(apt-get -s upgrade --with-new-pkgs 2>/dev/null | grep -c '^Inst ' || true)"
      if [[ "${value:-0}" == 0 ]]; then echo '已是最新（按当前软件索引）'; else echo "有 $value 个可升级"; fi ;;
    updates)
      dump="$(apt-config dump 2>/dev/null || true)"
      if grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' <<< "$dump" && active apt-daily-upgrade.timer; then echo '已开启'; else echo '未开启'; fi ;;
    autoreboot)
      dump="$(apt-config dump 2>/dev/null || true)"
      value="$(awk -F'"' '$1 ~ /^Unattended-Upgrade::Automatic-Reboot-Time / {print $2}' <<< "$dump" | tail -n 1)"
      if grep -Fq 'Unattended-Upgrade::Automatic-Reboot "true";' <<< "$dump"; then echo "每天 ${value:-02:00} 自动重启"; else echo '不自动重启'; fi ;;
    bbr)
      value="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
      if [[ "$value" == bbr ]]; then echo '已开启'; else echo "未开启（当前 ${value:-未知}）"; fi ;;
    sysctl) if [[ -f "$SYSCTL_HARDENING_FILE" ]]; then echo '已开启'; else echo '未开启'; fi ;;
    tcp)
      value="$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{printf "%d", $3 / 1048576}' || true)"
      if [[ -f "$TCP_BUFFER_FILE" ]]; then echo "已开启（接收上限 ${value:-?} MiB）"; else echo "未开启（系统接收上限 ${value:-?} MiB）"; fi ;;
    zram)
      value="$(awk 'NR > 1 && $1 == "/dev/zram0" {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
      if [[ -n "$value" ]]; then echo "已开启，约 ${value} MiB"
      elif swapon --noheadings 2>/dev/null | grep -q .; then echo '已有其他 Swap'
      elif ! zram_module_available; then echo '内核不支持（没有 zram 模块）'
      else echo '未开启'; fi ;;
    journal)
      if [[ -f "$JOURNAL_FILE" ]]; then
        echo "已限制（$(awk -F= '$1 == "SystemMaxUse" {print $2}' "$JOURNAL_FILE" 2>/dev/null)，$(awk -F= '$1 == "MaxRetentionSec" {print $2}' "$JOURNAL_FILE" 2>/dev/null)）"
      else echo '默认设置'; fi ;;
    trim) if ! trim_support; then echo '系统盘不支持'; elif systemctl is-enabled -q fstrim.timer 2>/dev/null; then echo '已开启'; else echo '未开启'; fi ;;
    ntp) if ntp_synced; then echo '已同步'; else echo '未同步'; fi ;;
    timezone) timedatectl show -p Timezone --value 2>/dev/null || echo '未知' ;;
    hosts) if hostname_resolves; then echo '正常'; else echo '无法解析'; fi ;;
    conntrack)
      value="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"
      if [[ -z "$value" ]]; then echo '没用到（防火墙没开）'
      elif [[ -f "$CONNTRACK_FILE" ]]; then echo "已调整（上限 $value 条，用了 $(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo ?) 条）"
      else echo "默认（上限 $value 条，用了 $(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo ?) 条）"; fi ;;
    ping) if [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == 1 ]]; then echo '不回应 ping'; else echo '回应 ping（默认）'; fi ;;
    keepalive)
      sshd_runtime_dir
      value="$(sshd -T 2>/dev/null | awk '$1 == "clientaliveinterval" {print $2}')"
      if [[ -n "$value" && "$value" != 0 ]]; then echo "每 $value 秒"; else echo '未开启'; fi ;;
    ipv4) if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$GAI_FILE" 2>/dev/null; then echo '已优先 IPv4'; else echo '默认（IPv6 优先）'; fi ;;
    login) if login_pam_enabled; then echo "已开启，记下了 $(login_recent 20000 | grep -c . || true) 次登录"; else echo '未开启'; fi ;;
    notify) if [[ -s "$STATE_ROOT/notify.conf" ]]; then echo '已开启'; else echo '未开启'; fi ;;
    quota)
      if read -r value total < <(quota_status); then echo "本周期已用 $((value / 1000)) GB / $((total / 1000)) GB"
      elif [[ -s "$STATE_ROOT/quota.conf" ]]; then echo '已开启，还没统计'; else echo '未开启'; fi ;;
    sshport)
      if [[ -f "$SSH_PORT_DROPIN" ]]; then echo "$(sed -n 's/^Port //p' "$SSH_PORT_DROPIN" | tr '\n' ' ')（原来是 $(sed -n 's/^port=//p' "$STATE_ROOT/restore-v2/sshport" 2>/dev/null || echo '?')）"
      else echo "$(ssh_candidates | sort -n -u | tr '\n' ' ')（默认）"; fi ;;
    dockerlog)
      if ! command -v dockerd >/dev/null; then echo '没装 Docker'
      elif grep -q '"max-size"' "$DOCKER_DAEMON_FILE" 2>/dev/null; then echo "已设置（$(sed -n 's/.*"max-size": *"\([^"]*\)".*/\1/p' "$DOCKER_DAEMON_FILE" | head -n 1)）"
      else echo '未设置（Docker 默认不限）'; fi ;;
    swap)
      value="$(awk -v n="$SWAP_FILE" 'NR > 1 && $1 == n {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
      if [[ -n "$value" ]]; then echo "已开启，${value} MiB"; else echo '未开启'; fi ;;
    hostname)
      value="$(hostname 2>/dev/null || echo 未知)"
      if dump="$(display_name_get)"; then echo "$value，显示名 $dump"; else echo "$value，没设显示名"; fi ;;
    tools)
      for pkg in "${TOOLS_PACKAGES[@]}"; do total=$((total + 1)); if installed "$pkg"; then count=$((count + 1)); fi; done
      echo "已安装 $count/$total" ;;
    vnstat)
      if active vnstat; then echo '已开启'; elif installed vnstat; then echo '已安装，未运行'; else echo '未安装'; fi ;;
    kernel)
      count="$(boot_kernels | grep -c . || true)"
      echo "已安装 $count 个内核" ;;
    firewall)
      if ! command -v ufw >/dev/null; then echo '未安装'; elif ufw_active; then echo '已开启'; else echo '未开启'; fi ;;
    fail2ban) if active fail2ban; then echo '已开启'; else echo '未开启'; fi ;;
    ssh)
      if ssh_password_disabled; then
        value="$(ssh_effective_value "$(ssh_effective root || true)" permitrootlogin)"
        if [[ "$value" == no ]]; then echo '只允许密钥登录，root 不能直接登录'; else echo '只允许密钥登录'; fi
      else echo '允许密码登录'; fi ;;
    ports) echo '放行或关闭端口' ;;
    *) echo '未知' ;;
  esac
}

# 24-hour H:MM or HH:MM, printed as HH:MM (the form unattended-upgrades expects).
reboot_time_normalize() {
  [[ "$1" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
  printf '%02d:%s\n' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# The time is the server's own clock, which may differ from the user's.
item_ask_reboot_time() {
  local zone answer=''
  zone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  read -r -p "每天几点自动重启？（按服务器时区${zone:+ $zone}，例如 04:00）: " answer || answer=''
  if AUTO_REBOOT_TIME="$(reboot_time_normalize "$answer")"; then return 0; fi
  AUTO_REBOOT_TIME=''
  warn "时间格式不对：${answer:-空}（要写成 04:00 这种格式）。"
  return 1
}

tools_item_stage() {
  packages_stage "${TOOLS_PACKAGES[@]}"
  module_result tools applied "${TOOLS_PACKAGES[*]}"
}

vnstat_item_stage() {
  packages_stage vnstat
  if installed vnstat && systemctl enable --now vnstat >/dev/null 2>&1; then ok 'vnStat 已开始统计流量，用 vnstat 命令查看。'; module_result traffic applied 'vnstat'
  else warn 'vnStat 没有启动。'; module_result traffic failed 'vnstat not running'; fi
}

item_turn_on() {
  case "$1" in
    upgrade) apt_index_ready || return 0
      stage_run apt_upgrade upgrade_only_stage ;;
    updates) AUTO_UPDATES=1
      if ! installed unattended-upgrades; then
        apt_index_ready || return 0
        stage_run apt_upgrade packages_stage unattended-upgrades
      fi
      stage_run updates updates_stage ;;
    autoreboot) item_ask_reboot_time || return 0
      stage_run autoreboot auto_reboot_configure ;;
    bbr) stage_run bbr bbr_stage ;;
    sysctl) SYSCTL_CHOICE=1
      stage_run sysctl sysctl_hardening_stage ;;
    tcp) TCP_BUFFER_CHOICE=1
      stage_run tcp tcp_buffer_stage ;;
    zram) ZRAM_CHOICE=1
      # Without the kernel module the stage only explains why: no index update.
      if zram_module_available; then apt_index_ready || return 0; fi
      stage_run zram zram_stage ;;
    journal) JOURNAL_FORCE=1
      stage_run journal journal_stage ;;
    trim) stage_run trim trim_stage ;;
    ntp) NEED_TIMESYNCD=0
      stage_run ntp ntp_stage
      if ((NEED_TIMESYNCD)); then
        apt_index_ready || return 0
        stage_run apt_upgrade packages_stage systemd-timesyncd
        if installed systemd-timesyncd; then stage_run ntp timesyncd_enable; fi
      fi ;;
    timezone) TZ_ASKED=0
      stage_run timezone timezone_stage ;;
    hosts) HOSTS_CHOICE=1
      stage_run hosts hosts_stage ;;
    hostname) hostname_ask || return 0
      stage_run hostname hostname_stage ;;
    conntrack) stage_run conntrack conntrack_stage ;;
    keepalive) KEEPALIVE_CHOICE=1
      stage_run keepalive keepalive_stage ;;
    ipv4)
      if ! ipv6_broken; then echo '这台机器的 IPv6 正常（或没有 IPv6）：一般不需要改，改了只是先试 IPv4。'; fi
      echo 'xray、sing-box 这类用 Go 写的程序不读这个设置，要在它们自己的配置里指定。'
      confirm_yes '改成优先使用 IPv4 吗？' || return 0
      IPV4_CHOICE=1
      stage_run ipv4 ipv4_stage ;;
    login) LOGIN_CHOICE=1
      stage_run login login_stage ;;
    notify) NOTIFY_CHOICE=1
      stage_run notify notify_stage ;;
    quota) QUOTA_CHOICE=1
      stage_run quota quota_stage ;;
    dockerlog) DOCKERLOG_CHOICE=1
      stage_run dockerlog dockerlog_stage ;;
    sshport) SSHPORT_CHOICE=1
      stage_run sshport ssh_port_stage ;;
    ping)
      echo '禁止 ping 只挡最基础的扫描（真正的攻击者不靠 ping 找机器）。代价：服务商或你自己用 ping 做的监控会把机器当成宕机，排查网络时也看不到 ping 的结果。'
      confirm_yes '仍然禁止 ping 吗？' || return 0
      stage_run ping ping_stage ;;
    swap)
      if swapon --noheadings 2>/dev/null | grep -v "^$SWAP_FILE " | grep . > /dev/null &&
         ! confirm_yes '已经有别的 Swap 或 ZRAM：通常不需要再加硬盘 Swap。仍然加一个吗？'; then return 0; fi
      SWAP_CHOICE=1
      stage_run swap swap_stage ;;
    tools) apt_index_ready || return 0
      stage_run tools tools_item_stage ;;
    vnstat) apt_index_ready || return 0
      stage_run tools vnstat_item_stage ;;
    kernel) kernel_cleanup --ask ;;
    firewall)
      if ! command -v ufw >/dev/null; then
        apt_index_ready || return 0
        stage_run apt_upgrade packages_stage ufw
      fi
      WEB_CHOICE=''
      stage_run firewall firewall_stage
      if ((FIREWALL_READY)) && ! active fail2ban && confirm_default_yes '防火墙已开启，同时配置 Fail2ban 防爆破吗？'; then item_turn_on fail2ban; fi ;;
    fail2ban)
      if ! ufw_active; then warn '要先开启防火墙，Fail2ban 才能封禁。'; return 0; fi
      FIREWALL_READY=1
      apt_index_ready || return 0
      stage_run fail2ban fail2ban_stage ;;
    ssh) SSH_CHOICE=1 ADMIN_CHOICE='' ADMIN_NAME=''
      stage_run ssh ssh_harden_stage ;;
    ports) port_menu ;;
  esac
}

# Undoes this tool's own change for one item; a setting the system already had
# is left alone. Tool-installed packages can be removed instead.
item_turn_off() {
  local key="$1" before
  case "$key" in
    tools) restore_packages_offer "${TOOLS_PACKAGES[@]}"; return 0 ;;
    vnstat) restore_packages_offer vnstat; return 0 ;;
  esac
  if ! restore_group_pending "$key"; then
    ok "本工具没有改过「$(item_label "$key")」，或者已经撤销过：现在是系统原来的设置，保持不变。"
    return 0
  fi
  if ! confirm_yes "撤销本工具对「$(item_label "$key")」的修改吗？"; then ok '已取消。'; return 0; fi
  before="$(restore_value ufw_runtime 2>/dev/null || true)"
  RESTORE_PARTIAL=0
  restore_group_apply "$key"
  restore_firewall_warning "$before"
  if ((RESTORE_PARTIAL)); then warn '没有完全撤销，详情见上方提示。'
  else
    ok "已撤销本工具对「$(item_label "$key")」的修改。"
    # Without the policy the package only keeps a shutdown helper running.
    # Asked only when this tool installed it (Ubuntu ships it preinstalled).
    if [[ "$key" == updates ]] && restore_tool_package unattended-upgrades; then
      restore_packages_offer unattended-upgrades
    fi
  fi
}

# A temporary switch-off for troubleshooting; turning it on again goes through
# the normal firewall stage with its SSH confirmation.
item_firewall_pause() {
  if ! ufw_active; then ok '防火墙现在没有开启。'; return 0; fi
  echo '临时关闭后，所有正在监听的端口都会直接暴露在公网，Fail2ban 的封禁也不起作用；重启后也保持关闭，排查完记得回到这里重新开启。'
  if ! confirm_yes '临时关闭防火墙吗？'; then ok '已取消。'; return 0; fi
  ufw --force disable >/dev/null
  restore_adopt ufw_runtime || warn '无法更新防火墙的回退记录。'
  ok '防火墙已临时关闭。重新开启：单项设置 → 防火墙 → 开启。'
}

item_action() {
  local key="$1" choice=''
  if [[ "$key" == ports ]]; then port_menu; return 0; fi
  say "$(item_label "$key")"
  printf '当前状态：%s\n' "$(item_status "$key")"
  case "$key" in
    upgrade|kernel) echo '1. 立即执行   0. 返回' ;;
    tools|vnstat) echo '1. 安装   2. 卸载（只卸载本工具装的）   0. 返回' ;;
    firewall) echo '1. 开启（需要新开 SSH 窗口确认）   2. 临时关闭   3. 撤销本工具的防火墙设置   0. 返回' ;;
    timezone) echo '1. 修改时区   2. 恢复成原来的时区   0. 返回' ;;
    hostname) echo '1. 修改显示名   2. 修改主机名   3. 撤销主机名修改（恢复原来的名字）   0. 返回' ;;
    fail2ban) echo '1. 开启   2. 关闭（撤销本工具的修改）   3. 管理白名单（不会被封的 IP）   4. 调整参数   5. 恢复推荐值   0. 返回' ;;
    autoreboot) echo '1. 设置自动重启时间   2. 取消（撤销本工具的设置）   0. 返回' ;;
    ssh) echo '1. 加固（只允许密钥登录，可选禁止 root）   2. 撤销（恢复密码和 root 登录）   0. 返回' ;;
    sshport) echo '1. 修改端口（新旧端口先同时开着，新端口能登录才关旧的）   2. 恢复原来的端口   0. 返回' ;;
    *) if [[ -n "$(param_names "$key")" ]]; then echo '1. 开启   2. 关闭（撤销本工具的修改）   3. 调整参数   4. 恢复推荐值   0. 返回'
       else echo '1. 开启   2. 关闭（撤销本工具的修改）   0. 返回'; fi ;;
  esac
  read -r -p '请选择: ' choice || return 0
  # Fail2ban's 3 is the allowlist: its parameters are 4 and 5.
  if [[ "$key" == fail2ban ]]; then
    case "$choice" in 4) choice=3 ;; 5) choice=4 ;; 3) f2b_allowlist_menu; return 0 ;; esac
  fi
  if [[ ( "$choice" == 3 || "$choice" == 4 ) && -n "$(param_names "$key")" ]]; then
    if [[ "$choice" == 3 ]]; then param_adjust "$key"; else param_reset "$key"; fi
    return 0
  fi
  case "$key:$choice" in
    hostname:1) display_name_ask ;;
    hostname:2) item_turn_on hostname ;;
    hostname:3) item_turn_off hostname ;;
    hostname:*) return 0 ;;
    firewall:2) item_firewall_pause ;;
    firewall:3) item_turn_off firewall ;;
    upgrade:1|kernel:1) item_turn_on "$key" ;;
    upgrade:*|kernel:*) return 0 ;;
    *:1) item_turn_on "$key" ;;
    *:2) item_turn_off "$key" ;;
    *) return 0 ;;
  esac
}

# The symbols for terminals that cannot draw them: a saved setting (VPS_ASCII
# on the command line still wins), in force from the next start.
item_symbols() {
  if grep -qsx 'ui_ascii=1' "$PARAMS_FILE"; then
    confirm_yes '改回 ✔ ⚠ ✖ ○ 这套符号吗？' || return 0
    param_store ui_ascii '' || die '无法保存设置。'
  else
    confirm_yes '改用纯 ASCII 符号（[OK] [!] [X] [-]）吗？终端把 ✔ ⚠ 显示成乱码或方框时用。' || return 0
    param_store ui_ascii 1 || die '无法保存设置。'
  fi
  ok '已保存，下次打开时生效。'
}

item_menu() {
  local choice i key
  local -a keys=()
  mapfile -t keys < <(item_keys)
  while :; do
    say '单项设置（逐项开启或关闭）'
    i=0
    for key in "${keys[@]}"; do
      i=$((i + 1))
      printf '%3s. %s  [%s]\n' "$i" "$(item_label "$key")" "$(item_status "$key")"
    done
    printf '  p. 参数总览（现在的值、推荐值和理由）   e. 导出参数   i. 导入参数\n'
    printf '  u. 界面符号（现在：%s）   0. 返回\n' "$(if [[ "${SYM_OK-}" == '[OK]' ]]; then echo '纯 ASCII'; else echo '✔ ⚠ ✖ ○'; fi)"
    read -r -p "请选择要修改的项目 [1-$i，p/e/i/u，0 返回]: " choice || return 0
    if [[ -z "$choice" || "$choice" == 0 ]]; then return 0; fi
    case "$choice" in
      p|P) params_overview; continue ;;
      e|E) say '导出参数'; params_export; continue ;;
      i|I) say '导入参数'; params_import; continue ;;
      u|U) item_symbols; continue ;;
    esac
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= i)); then
      item_action "${keys[choice - 1]}"
    else
      echo '无效选项。'
    fi
  done
}

item_main() {
  [[ $EUID -eq 0 ]] || die '单项设置需要 root：请用 sudo vps item。'
  validate_vm
  start_logging
  prepare_run_state
  stage_run backup backup_configs
  restore_prepare
  item_menu
  finish_run_state
  # Offer a reboot only for an upgrade made in this session; an older pending
  # reboot is just mentioned.
  if ((UPGRADE_APPROVED)) && { ((KERNEL_UPDATE)) || [[ -e /var/run/reboot-required ]]; }; then offer_reboot
  elif [[ -e /var/run/reboot-required ]]; then echo '提示：系统之前的更新还在等待重启，方便时运行 systemctl reboot。'; fi
}

# Why a reboot is (or is not) needed: an installed kernel newer than the running
# one, or the system's reboot-required flag. Arguments allow isolated tests.
reboot_reason() {
  local boot="${1:-/boot}" flag="${2:-/var/run/reboot-required}" running newest
  running="$(uname -r)"
  newest="$(boot_kernels "$boot" | tail -n 1)"
  if [[ -n "$newest" && "$newest" != "$running" ]]; then echo "已安装新内核 $newest，正在运行的是 $running：重启后新内核才生效。"
  elif [[ -e "$flag" ]]; then echo '系统提示需要重启，部分更新要重启后才完全生效。'
  else echo '目前没有需要重启才能生效的更新，不重启也可以。'; fi
}

# Menu 8 / vps reboot. Refuses while an SSH protection timer is pending (a
# reboot would drop the timer and keep an unconfirmed change) or APT is busy.
reboot_main() {
  [[ $EUID -eq 0 ]] || die '重启需要 root：请用 sudo vps reboot。'
  [[ -t 0 ]] || die '需要在交互式 SSH 终端里运行。'
  tool_lifecycle_lock
  say '重启服务器'
  reboot_reason
  if ! tool_no_pending_firewall; then
    die '防火墙或 SSH 加固的防失联确认还没结束（或无法确认它的状态）。现在重启会让保护计时器失效，没确认的修改会被永久保留；请先回到那个窗口完成确认，或等计时结束后再重启。'
  fi
  apt_wait_idle
  if apt_locks_held; then die '仍有程序在安装或更新软件，现在重启可能损坏软件包；请等它结束后再重启。'; fi
  echo '重启会断开所有 SSH 连接，通常一两分钟后可以重新登录。'
  echo '重启后输入 vps 选 3「开荒验收」，确认各项设置在重启后仍然生效。'
  if ! confirm_yes '现在重启服务器吗？'; then ok '已取消，没有重启。'; return 0; fi
  sync
  systemctl reboot
}

# ---- Update (menu 14 / vps update) -------------------------------------------------
# Same source and checks as the one-line install in the README: install.sh and
# the main script from the repository's main branch over HTTPS; the script must
# match the hash pinned in that install.sh, which then installs it in place
# (records, backups and rollback data stay). No system setting is changed.
UPDATE_BASE_URL='https://raw.githubusercontent.com/ehrenfelssotiris553-ops/vps-stable-optimizer/main'

update_fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null; then
    curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --silent --show-error --output "$out" "$url"
  elif command -v wget >/dev/null && command -v timeout >/dev/null; then
    # No redirects: wget's --https-only alone does not constrain every redirect.
    timeout 120s wget --https-only --max-redirect=0 --timeout=15 --tries=2 --no-verbose --output-document="$out" "$url"
  else
    warn '缺少 curl 或 wget，无法下载更新。'; return 1
  fi
}

# The SCRIPT_VERSION assigned in a script file, read without running it.
script_version_of() {
  awk -F= '$1 == "SCRIPT_VERSION" && $2 ~ /^[0-9]+(\.[0-9]+)+$/ {print $2; exit}' "$1"
}

# True when version A is newer than version B (2.6.10 is newer than 2.6.9).
version_newer() {
  [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

update_install() {
  /bin/bash "$1" --local-file "$2" --no-run
}

update_main() {
  local tmp latest expected actual rc=0
  [[ $EUID -eq 0 ]] || die '检查更新需要 root：请用 sudo vps update。'
  say '检查更新'
  printf '本机版本：%s\n' "$SCRIPT_VERSION"
  tmp="$(mktemp -d)" || die '无法创建临时目录。'
  if ! update_fetch "$UPDATE_BASE_URL/install.sh" "$tmp/install.sh" ||
     ! update_fetch "$UPDATE_BASE_URL/vps-stable-opt.sh" "$tmp/vps-stable-opt.sh"; then
    rm -rf -- "$tmp"
    warn '连不上 GitHub，暂时无法检查更新；稍后再试，或按 README 手动上传新版本。'; return 0
  fi
  expected="$(sed -n "s/^EXPECTED_SHA256='\([0-9a-f]\{64\}\)'$/\1/p" "$tmp/install.sh" | head -n 1)"
  actual="$(sha256sum -- "$tmp/vps-stable-opt.sh")"; actual="${actual%% *}"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    rm -rf -- "$tmp"
    warn 'GitHub 上的安装器和主脚本对不上（可能刚发布、文件还在同步），这次没有更新；过几分钟再试。'; return 0
  fi
  latest="$(script_version_of "$tmp/vps-stable-opt.sh" || true)"
  if [[ -z "$latest" ]]; then rm -rf -- "$tmp"; warn '读不出 GitHub 上的版本号，这次没有更新。'; return 0; fi
  printf 'GitHub 上的最新版本：%s\n' "$latest"
  if ! version_newer "$latest" "$SCRIPT_VERSION"; then
    rm -rf -- "$tmp"
    if [[ "$latest" == "$SCRIPT_VERSION" ]]; then ok '已经是最新版本，不需要更新。'
    else ok '本机的版本比 GitHub 上的还新，不做改动。'; fi
    return 0
  fi
  echo '更新只替换本工具自己的程序，不改动任何系统设置；运行记录、配置备份和回退资料都会保留。'
  echo '各版本改了什么，见仓库里的「优化记录.md」：https://github.com/ehrenfelssotiris553-ops/vps-stable-optimizer'
  if [[ ! -e /usr/local/bin/vps ]]; then echo '本机还没有安装 vps 命令：更新会把它安装到 /usr/local/bin/vps。'; fi
  if ! confirm_default_yes "现在更新到 $latest 吗？"; then rm -rf -- "$tmp"; ok '没有更新。'; return 0; fi
  update_install "$tmp/install.sh" "$tmp/vps-stable-opt.sh" || rc=$?
  rm -rf -- "$tmp"
  if ((rc)); then warn "更新没有完成（安装器退出码 $rc），本机仍是 $SCRIPT_VERSION，请看上面的提示。"; return 0; fi
  ok "已更新到 $latest。重新输入 vps 打开新版本。"
}

# ---- Fail2ban ban records (menu 6 / vps bans) --------------------------------------
# Recent sshd-jail ban and unban events from Fail2ban's log file (the current
# and the previous one), or from the journal when Fail2ban logs there, oldest
# first, as "time<TAB>event<TAB>address".
f2b_ban_events() {
  local log="${1:-/var/log/fail2ban.log}" limit="${2:-20}" f
  local -a files=()
  for f in "$log.1" "$log"; do
    if [[ -f "$f" && -r "$f" ]]; then files+=("$f"); fi
  done
  {
    if ((${#files[@]})); then cat -- "${files[@]}"
    elif command -v journalctl >/dev/null; then journalctl -q -u fail2ban -o short-iso -n 5000 --no-pager 2>/dev/null || true
    fi
  } | awk '
    / \[sshd\] (Restore )?Ban [0-9A-Fa-f:.]+$/ || / \[sshd\] Unban [0-9A-Fa-f:.]+$/ {
      if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) t = $1 " " substr($2, 1, 8)
      else { t = substr($1, 1, 19); sub(/T/, " ", t) }
      if ($0 ~ / Unban /) e = "解封"; else if ($0 ~ / Restore Ban /) e = "重启后恢复封禁"; else e = "封禁"
      print t "\t" e "\t" $NF
    }' | tail -n "$limit"
}

# Whole days, hours or minutes for a ban length in seconds.
f2b_duration_text() {
  local s="$1"
  if ((s >= 86400 && s % 86400 == 0)); then printf '%s 天' "$((s / 86400))"
  elif ((s >= 3600)); then printf '%s 小时' "$((s / 3600))"
  else printf '%s 分钟' "$((s / 60))"; fi
}

bans_main() {
  local status failed banned total list bantime increment maxtime times ignore me ip line
  [[ $EUID -eq 0 ]] || die '查看封禁记录需要 root：请用 sudo vps bans。'
  say 'Fail2ban 封禁记录'
  if ! command -v fail2ban-client >/dev/null || ! active fail2ban; then
    ok 'Fail2ban 没有运行，没有封禁记录可看（可以在单项设置里开启 Fail2ban）。'; return 0
  fi
  if ! status="$(fail2ban-client status sshd 2>/dev/null)"; then
    warn '读不到 SSH 防爆破规则（sshd）的状态：可能没有启用这条规则。'; return 0
  fi
  failed="$(awk -F: '/Total failed/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  banned="$(awk -F: '/Currently banned/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  total="$(awk -F: '/Total banned/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  # IPv6 addresses contain ":", so the list is cut after its label instead.
  list="$(awk '/Banned IP list:/ {sub(/^.*Banned IP list:[ \t]*/, ""); print}' <<< "$status")"
  bantime="$(fail2ban-client get sshd bantime 2>/dev/null || true)"
  increment="$(fail2ban-client get sshd bantime.increment 2>/dev/null || true)"
  maxtime="$(fail2ban-client get sshd bantime.maxtime 2>/dev/null || true)"
  printf '正在封禁：%s 个 IP' "${banned:-0}"
  if [[ "$bantime" =~ ^[0-9]+$ && "$increment" =~ ^[Tt]rue$ ]]; then
    printf '（首次封 %s，同一 IP 再犯时间加倍' "$(f2b_duration_text "$bantime")"
    if [[ "$maxtime" =~ ^[0-9]+$ ]]; then printf '，最长 %s' "$(f2b_duration_text "$maxtime")"; fi
    printf '）'
  elif [[ "$bantime" =~ ^[0-9]+$ ]]; then printf '（每次封 %s）' "$(f2b_duration_text "$bantime")"; fi
  printf '\nFail2ban 这次启动以来：识别出 %s 次失败登录，封禁过 %s 次。\n' "${failed:-0}" "${total:-0}"
  if [[ -n "$list" ]]; then
    echo '当前被封禁的 IP：'
    if times="$(fail2ban-client get sshd banip --with-time 2>/dev/null)" && [[ "$times" == *' + '* ]]; then
      awk 'NF >= 8 {printf "  %-40s 封禁于 %s %s，到 %s %s 解封\n", $1, $2, $3, $7, $8}' <<< "$times"
    else
      tr ' ' '\n' <<< "$list" | sed '/^$/d; s/^/  /'
    fi
  fi
  me="${SSH_CONNECTION:-}"; me="${me%% *}"
  if [[ -n "$me" ]]; then
    if [[ " $list " == *" $me "* ]]; then warn "你当前的 IP $me 在封禁列表里（已经连着的会话不受影响）。"
    else echo "你当前的 IP $me 没有被封禁。"; fi
  fi
  ignore="$(fail2ban-client get sshd ignoreip 2>/dev/null | sed -n 's/^[|`]- *//p' | tr '\n' ' ' || true)"
  if [[ -n "$ignore" ]]; then echo "白名单（不会被封）：$ignore"; fi
  echo '管理白名单：选 5 单项设置 → Fail2ban 防爆破 → 3。'

  echo '最近的封禁和解封记录（最多 20 条，时间按服务器时区）：'
  line="$(f2b_ban_events)"
  if [[ -n "$line" ]]; then awk -F'\t' '{printf "  %s  %-14s %s\n", $1, $2, $3}' <<< "$line"
  else echo '  没有找到记录（日志可能已经轮换或清理）。'; fi
  [[ -n "$list" && -t 0 ]] || return 0
  read -r -p '要解封某个 IP 吗？输入 IP（直接回车返回）: ' ip || ip=''
  [[ -n "$ip" ]] || return 0
  # One address, exactly as listed (no partial match, no several at once).
  if [[ ! "$ip" =~ ^[0-9A-Fa-f:.]+$ || " $list " != *" $ip "* ]]; then warn "$ip 不在当前的封禁列表里，没有改动。"; return 0; fi
  confirm_yes "解封 $ip 吗？（它可以马上重新尝试登录；再次输错达到次数还会被封）" || { ok '没有解封。'; return 0; }
  tool_lifecycle_lock
  if fail2ban-client set sshd unbanip "$ip" >/dev/null; then ok "已解封 $ip。"
  else warn "解封 $ip 失败，请运行 fail2ban-client set sshd unbanip $ip 查看原因。"; fi
}

# A reboot happens only after the user agrees, once the run is recorded complete.
offer_reboot() {
  if ((UPGRADE_APPROVED && KERNEL_UPDATE)) || [[ -e /var/run/reboot-required ]]; then
    if ((UPGRADE_APPROVED && KERNEL_UPDATE)); then echo '本次更新包含新内核，需要重启才能生效。'
    else echo '系统提示需要重启，更新才能完全生效（可能来自本次或之前的更新）。'; fi
    echo '重启后重新登录，输入 vps 选 3「开荒验收」，确认各项优化真的生效。'
    if confirm_yes '现在重启吗？'; then
      sync
      systemctl reboot
      return 0
    fi
    echo '稍后请在合适的时间手动重启：systemctl reboot，然后运行 vps check。'
  elif [[ "$MODE" == setup ]]; then
    echo '建议找合适的时间重启一次，再运行 vps check，确认重启后各项仍然生效。'
  fi
}

main() {
  # The tools list is a parameter (root only can read it; others get the default).
  read -r -a TOOLS_PACKAGES <<< "$(param_value tools_list 2>/dev/null || echo "${TOOLS_PACKAGES[*]}")"
  case "$MODE" in
    menu) menu; return 0 ;;
    uninstall) tool_uninstall; return 0 ;;
    rollback) restore_main; exit "$RESTORE_EXIT_CODE" ;;
    records) records_report; return 0 ;;
    check) verify_main; exit "$VERIFY_EXIT" ;;
    plan) plan; return 0 ;;
    perf) perf_main; return 0 ;;
    resources) resources_main; return 0 ;;
    audit) audit_main; return 0 ;;
    port) port_main; return 0 ;;
    item) item_main; return 0 ;;
    params) params_main; return 0 ;;
    reboot) reboot_main; return 0 ;;
    update) update_main; return 0 ;;
    bans) bans_main; return 0 ;;
  esac
  validate_vm
  # Before the plan: a setup handed to tmux shows its plan there.
  if [[ "$MODE" == setup ]] && ! session_resilience_check; then return 0; fi
  plan
  if ! confirm_yes '已拍好快照、确认服务商控制台可用，开始本次修改吗？'; then
    ok '已取消；未创建本次运行日志/备份，未执行优化。'
    return 0
  fi
  preflight_gate
  start_logging
  prepare_run_state
  stage_run backup backup_configs
  restore_prepare
  if [[ "$MODE" == ssh ]]; then
    stage_run ssh ssh_harden_stage
  elif [[ "$MODE" == firewall ]]; then
    stage_run firewall firewall_stage
    if ((FIREWALL_READY)); then
      stage_run fail2ban fail2ban_stage
    else
      state_event fail2ban skipped 0
      warn '防火墙没有确认生效，跳过 Fail2ban。'
    fi
  else
    UI_STEPS=15
    # Time first (APT validates Release dates), every question next, ZRAM
    # before a large upgrade; the steps that need the user come last.
    stage_run ntp ntp_stage
    stage_run apt_index apt_index_stage
    stage_run questions setup_questions
    stage_run zram zram_stage
    stage_run swap swap_stage
    stage_run apt_upgrade apt_upgrade_stage
    stage_run bbr bbr_stage
    stage_run sysctl sysctl_hardening_stage
    stage_run tcp tcp_buffer_stage
    stage_run journal journal_stage
    stage_run trim trim_stage
    stage_run updates updates_stage
    stage_run autoreboot auto_reboot_configure
    stage_run timezone timezone_stage
    stage_run hosts hosts_stage
    stage_run keepalive keepalive_stage
    stage_run ipv4 ipv4_stage
    stage_run login login_stage
    attention_banner
    stage_run ssh ssh_harden_stage
    stage_run firewall firewall_stage
    if ((FIREWALL_READY)); then
      stage_run fail2ban fail2ban_stage
    else
      state_event fail2ban skipped 0
      warn '防火墙没有确认生效，跳过 Fail2ban。'
    fi
  fi
  stage_run verification verify_summary
  finish_run_state
  say '本次流程已完成，请逐项处理上方的注意事项。'
  printf '注意/跳过/未知提示累计：%s（不等于故障数量）\n' "$WARNINGS"
  printf '配置快照：%s\n运行记录：%s\n' "$RUN_BACKUP_DIR" "$RUN_STATE_DIR"
  echo '备份建议：服务商快照只能整机还原；重要数据另外做异地备份（例如用 restic 或 borg 备份到另一台机器或对象存储），并定期试着恢复一次。'
  echo '本工具的配置备份只保存系统配置，不包含业务数据。'
  offer_reboot
}

# Main entry point.
main "$@"
