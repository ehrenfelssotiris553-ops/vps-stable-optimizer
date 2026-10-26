#!/usr/bin/env bash
# VPS Stable Optimizer v2.7.5 — tracked configuration restore and tool cleanup
# Supports Debian 12/13, Ubuntu 22.04/24.04/26.04 on systemd VMs.
# Review locally before running as root. Opening the menu does not apply optimization.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none LC_ALL=C
umask 077

SCRIPT_VERSION=2.7.5
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
F2B_ACTION_FILE=/etc/fail2ban/action.d/vps-stable-ufw-sshd.conf
# sshd keeps the FIRST value it reads; 01- sorts before cloud-init's 50- file.
SSH_DROPIN=/etc/ssh/sshd_config.d/01-vps-stable-keyonly.conf
# Only written when a provider image ships "PubkeyAuthentication no".
SSH_PUBKEY_DROPIN=/etc/ssh/sshd_config.d/00-vps-stable-pubkey.conf
WARNINGS=0
AUTO_UPDATES=0
INSTALL_TOOLS=0
NEED_TIMESYNCD=0
KERNEL_UPDATE=0
FIREWALL_READY=0
RESTORE_EXIT_CODE=0
STATE_ROOT=/var/lib/vps-stable-opt
BACKUP_ROOT=/var/backups/vps-stable-opt
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
SYSCTL_CHOICE=''
AUTO_REBOOT_TIME=''
KERNEL_CLEAN_CHOICE=''
VNSTAT_CHOICE=''
ZRAM_CHOICE=''
HOSTS_CHOICE=''

case "$MODE" in menu|records|uninstall|rollback|setup|plan|check|firewall|ssh|port|item|reboot|update|bans|help|-h|--help|--version) ;; *) echo '用法：bash vps-stable-opt.sh [menu|plan|setup|item|firewall|ssh|port|check|records|rollback|uninstall|reboot|update|bans|help]' >&2; exit 2 ;; esac
[[ "$MODE" == --version ]] && { echo "$SCRIPT_VERSION"; exit 0; }
if [[ "$MODE" == help || "$MODE" == -h || "$MODE" == --help ]]; then
  cat <<'HELP'
VPS 机器管家 V2.7.1 — Debian 12/13、Ubuntu 22.04/24.04/26.04
安装后输入 vps 打开菜单；也可直接运行 bash vps-stable-opt.sh。
  vps plan       给机器做体检（只检查）
  vps setup      一键开荒：更新系统并优化机器（可选推荐设置，一次问完）
  vps check      开荒验收：逐项检查优化是否真的生效（适合重启后运行）
  vps port       端口管理；也可直接用：
                   vps port open 8080 | 443-600 | 8080,9000-9100 [tcp|udp|both] [from IP]
                   vps port close 8080 [tcp|udp|both]
                   vps port list
  vps item       单项设置：逐项开启或关闭某一项，不用重跑整个开荒
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
开荒建议在 tmux 或 screen 里运行，SSH 断线时不会中断。
默认保留 SSH 端口、root 登录、DNS、IPv6、MTU；不自动重启整机。
回退只会放宽访问（关防火墙、恢复密码登录），不会把你锁在外面。
系统升级和新内核无法回退；需要整机还原请使用服务商快照。
卸载清掉备份后，即使重新安装也无法可靠回退；卸载不会删除用户上传副本。
HELP
  exit 0
fi

say() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[停止]\033[0m %s\n' "$*" >&2; exit 1; }
on_error() {
  local code="$1" line="$2"
  trap - ERR
  if declare -F restore_capture_failure >/dev/null; then restore_capture_failure || true; fi
  if declare -F record_failure >/dev/null; then record_failure "$line" "$code" || true; fi
  printf '[出错] line=%s exit=%s；请查看运行记录，不要盲目重跑。\n' "$line" "$code" >&2
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

confirm() {
  local question="$1" expected="$2" answer=''
  [[ -t 0 ]] || return 1
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
  read -r -p "$question [y/N]: " answer || true
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}
# Recommended choices: Enter means yes, n/no means no. No terminal means no.
confirm_default_yes() {
  local question="$1" answer=''
  [[ -t 0 ]] || return 1
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

# Packages absent before this call are recorded so rollback can offer removal.
install_pkgs() {
  local pkg new=() rc=0
  for pkg in "$@"; do installed "$pkg" || new+=("$pkg"); done
  apt_wait_idle
  apt-get -y -q -o DPkg::Lock::Timeout=120 install --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" || rc=$?
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
  exec > >(tee -a "$LOG_DIR/$prefix-$(date -u +%Y%m%dT%H%M%SZ)-$$.log") 2>&1
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
  local dest="$1" contents="$2" temp parent actual
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -f "$dest" && ! -L "$dest" ]] && actual="$(cat -- "$dest")" && [[ "$actual" == "$contents" ]]; then
      ok "已经配置好：$dest"; return 0
    fi
    warn "已有内容不同的文件或链接：$dest（保持不变，不覆盖）"; return 1
  fi
  backup_config_path "$dest" || die "无法备份原配置：$dest"
  parent="$(dirname -- "$dest")" || return 1
  if [[ ! -d "$parent" ]]; then
    install -d -m 755 -- "$parent" || { warn "无法创建配置目录：$parent"; return 1; }
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

ssh_candidates() {
  local bin
  bin="$(command -v sshd || true)"
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
      echo '默认保留 SSH 端口、root 登录、IPv6、MTU、DNS；不重装系统、不建磁盘 Swap、不换第三方内核。' ;;
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
  say '第2步：软件索引与升级计划'
  local free_mb simulation count
  local -a names=()
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  [[ "$free_mb" =~ ^[0-9]+$ ]] || die '无法确定磁盘剩余空间。'
  ((free_mb >= 650)) || die "磁盘只剩 ${free_mb}MiB，至少需要 650MiB。"
  apt_wait_idle
  if ! apt-get update -o APT::Update::Error-Mode=any; then
    warn '软件索引更新失败，关闭增量下载后再试一次。'
    apt_wait_idle
    apt-get update -o APT::Update::Error-Mode=any -o Acquire::PDiffs=false || die 'APT 软件索引更新失败：请检查软件源；如提示 "not valid yet"，说明系统时间不准，请先校准时间。'
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
  echo '推荐设置：升级系统、开启自动安全更新、安装常用工具、启用内核网络安全参数、升级后清理旧内核、主机名无法解析时补上。'
  echo '（SSH 加固和防火墙不在推荐设置里，后面会单独问你。）'
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
  say '第3步：开荒选项（一次问完，之后自动执行）'
  local login ip
  if [[ "${RECOMMENDED:-0}" == 1 ]]; then
    # Recommended set: low-risk items only. Everything else stays off and can
    # be turned on later from the single-item menu.
    INSTALL_TOOLS=1 SYSCTL_CHOICE=1 VNSTAT_CHOICE=0 ZRAM_CHOICE=0 AUTO_REBOOT_TIME=''
    KERNEL_CLEAN_CHOICE="$UPGRADE_APPROVED" HOSTS_CHOICE=1 TZ_CHOICE='' TZ_ASKED=1 F2B_IGNORE_CHOICE=none
    echo '已按推荐设置记下：安装常用工具、启用内核网络安全参数、升级后清理旧内核、需要时修复主机名；时区保持不变。'
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
    if ! hostname_resolves; then
      if confirm_default_yes "主机名 $(hostname) 无法解析（sudo 会提示 unable to resolve host）。在 /etc/hosts 里补上吗？"; then HOSTS_CHOICE=1; else HOSTS_CHOICE=0; fi
    fi
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
  F2B_IGNORE_CHOICE=none
  ip="${SSH_CONNECTION:-}"; ip="${ip%% *}"
  if [[ "${RECOMMENDED:-0}" != 1 && -n "$ip" ]] && port_source_valid "$ip" &&
     confirm_yes "把你当前的 IP $ip 加入 Fail2ban 白名单，避免输错几次就把自己封掉吗？（家庭宽带 IP 常会变化，换了就失效）"; then
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

session_resilience_check() {
  if in_terminal_multiplexer; then ok '正在 tmux/screen 中运行：SSH 断线后脚本会继续执行。'; return 0; fi
  warn '当前不在 tmux 或 screen 里：如果 SSH 中途断开，脚本会被中断，系统升级可能停在一半。'
  if command -v tmux >/dev/null; then
    echo '建议先输入 tmux new -s vps 进入 tmux，再运行 vps；断线后重新登录，输入 tmux attach -t vps 就能回到原来的界面。'
  else
    echo '建议先安装 tmux（apt-get install tmux），再在 tmux 里运行。'
  fi
  confirm_yes '仍然在当前窗口继续吗？'
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
  if apt-get -y -q -o DPkg::Lock::Timeout=120 purge "${kernels[@]}"; then ok "已清理 ${#kernels[@]} 个旧内核包。"
  else warn '旧内核清理失败，请人工检查。'; fi
}

apt_upgrade_stage() {
  say '第5步：系统升级与组件安装'
  local packages=() pkg tools=()
  if ((UPGRADE_APPROVED)); then
    apt_wait_idle
    apt-get -y -q -o DPkg::Lock::Timeout=120 upgrade --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
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
  if ((${#packages[@]})); then install_pkgs "${packages[@]}"; fi
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
  if ((${#wanted[@]})); then install_pkgs "${wanted[@]}"; else ok '需要的软件包都已经安装好了。'; fi
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
  apt-get -y -q -o DPkg::Lock::Timeout=120 upgrade --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
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
  if apt-get update -o APT::Update::Error-Mode=any >/dev/null; then APT_INDEX_READY=1; return 0; fi
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
  say '第6步：BBR 与默认 fq 队列配置'
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

swap_exists() {
  swapon --noheadings 2>/dev/null | grep -q . && return 0
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

zram_stage() {
  say '第4步：内存与 ZRAM（在系统升级前配置）'
  local size='ram / 2' vendor=0
  if swap_exists; then
    # The package default is replaced by this tool's own file when asked for
    # explicitly, or when it runs no swap at all (Ubuntu installs it unstarted).
    if zram_vendor_default_only && { [[ "${ZRAM_CHOICE:-}" == 1 ]] || ! swapon --noheadings 2>/dev/null | grep -q .; }; then
      vendor=1
      echo '现在只有 systemd-zram-generator 软件包自带的默认 ZRAM 配置（约内存一半），改用本工具的配置。'
    elif restore_file_ours zram_file && ! swapon --noheadings 2>/dev/null | grep -q .; then
      if ! zram_module_available; then
        warn '本工具的 ZRAM 配置还在，但这个内核没有 zram 模块，ZRAM 无法启动；可以在撤销里撤销 ZRAM。'
        module_result zram unsupported 'kernel has no zram module'; return 0
      fi
      echo '本工具的 ZRAM 配置还在，但 ZRAM 没有运行（可能上次启动失败）：重新启动它。'
      if zram_start; then zram_tune; module_result zram applied 'zram0 restarted'
      else warn 'ZRAM 仍然没有启动，请运行 systemctl status systemd-zram-setup@zram0 查看原因。'; module_result zram failed 'dev-zram0.swap did not start'; fi
      swapon --show || true
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
  if ((MEM_MIB >= 2048)); then
    if [[ "${ZRAM_CHOICE:-}" != 1 ]]; then
      ok '内存不少于 2GiB：按你的选择不新增 ZRAM。'
      module_result zram skipped 'RAM >= 2GiB'; return 0
    fi
    # Larger machines get a smaller emergency buffer.
    size='ram / 4'
  fi
  if ! zram_module_available; then
    warn '这个内核没有 zram 模块，跳过 ZRAM（Ubuntu 云镜像的精简内核把它放在 linux-modules-extra 包里，占几百 MB，且每次升级内核都要跟着装，本工具不自动安装）。'
    module_result zram unsupported 'kernel has no zram module'; return 0
  fi
  if ! available systemd-zram-generator; then
    warn '软件源里没有 systemd-zram-generator，跳过 ZRAM。'
    module_result zram unsupported 'package unavailable'; return 0
  fi
  install_pkgs systemd-zram-generator
  # Debian 12 and Ubuntu install their default "[zram0]" right at ZRAM_FILE; an
  # unchanged copy is replaced (Debian 13 keeps that default in /usr/lib).
  if zram_file_packaged; then rm -f -- "$ZRAM_FILE"; fi
  # zstd packs about a third more into the same RAM than the kernel default;
  # zram-generator only warns and keeps the default if the kernel lacks it.
  if put_file "$ZRAM_FILE" "[zram0]"$'\n'"zram-size = $size"$'\n''compression-algorithm = zstd'$'\n''swap-priority = 100'; then
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
  say '第1步：时间同步（不修改时区，先于软件更新）'
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

journal_stage() {
  say '第8步：日志空间（仅小硬盘）'
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
  if put_file "$JOURNAL_FILE" $'[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\nMaxRetentionSec=14day'; then
    if systemctl restart systemd-journald; then module_result journal applied 'SystemMaxUse=100M'
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
  say '第9步：TRIM 支持检测'
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

updates_stage() {
  say '第10步：自动安全更新'
  if (( !AUTO_UPDATES )); then ok '自动更新策略保持不变。'; module_result updates declined 'not requested'; return 0; fi
  installed unattended-upgrades || { warn '没有安装 unattended-upgrades。'; module_result updates unsupported 'package missing'; return 0; }
  local periodic result=applied
  periodic="$(apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) ' || true)"
  if grep -Fq 'APT::Periodic::Update-Package-Lists "1";' <<< "$periodic" &&
     grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' <<< "$periodic"; then ok '自动安全更新原本就已开启。'; result=present
  elif [[ -n "$periodic" ]]; then
    # APT's parsed configuration covers every syntax (including blocks) and file.
    warn "已有自定义的定期更新策略（$(tr '\n' ' ' <<< "$periodic")），不覆盖。"; result=preserved
  elif ! put_file "$APT_FILE" $'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";'; then result=preserved
  fi
  if systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then module_result updates "$result" 'periodic updates'
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
  say '第11步：时区'
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
  say '第7步：内核网络安全参数（可选）'
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

# Appends LINE to FILE; an unterminated last line is ended first, so the two
# never merge into one.
append_line_safely() {
  local file="$1" line="$2"
  if [[ -s "$file" && "$(tail -c 1 -- "$file" | wc -l)" -eq 0 ]]; then printf '\n' >> "$file" || return 1; fi
  printf '%s\n' "$line" >> "$file"
}

# Adds "127.0.1.1 <hostname>" (the Debian convention) when the name does not resolve.
hosts_stage() {
  say '第12步：主机名解析'
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

f2b_jail_text() {
  printf '%s\n' '# VPS Stable Optimizer v2.6 managed SSH jail' \
    '[sshd]' 'enabled = true' "port = $1" 'backend = systemd' \
    'action = vps-stable-ufw-sshd[port="%(port)s"]' \
    'maxretry = 5' 'findtime = 600' 'bantime = 43200'
  if [[ -n "${2:-}" ]]; then printf 'ignoreip = 127.0.0.1/8 ::1 %s\n' "$2"; fi
}

# The managed jail with or without an ignoreip line still belongs to this tool.
f2b_jail_is_ours() {
  [[ "$(grep -v '^ignoreip = ' <<< "$1")" == "$(f2b_jail_text "$2")" ]]
}

# '' = ask now, none = no allowlist entry, otherwise the address to allow.
f2b_ignore_address() {
  local ip="${SSH_CONNECTION:-}"
  ip="${ip%% *}"
  case "${F2B_IGNORE_CHOICE:-}" in
    none) return 0 ;;
    '') [[ -n "$ip" ]] && port_source_valid "$ip" || return 0
        confirm_yes "把你当前的 IP $ip 加入 Fail2ban 白名单，避免输错几次就把自己封掉吗？（家庭宽带 IP 常会变化，换了就失效）" || return 0
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
  say '第15步：Fail2ban（防火墙生效后，只封 SSH 端口）'
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
  local joined guard jail action current='' transitioned=0 pkg
  local needed=()
  joined="$(IFS=,; echo "${SSH_PORTS[*]}")"
  guard="$(f2b_bootstrap_text)"
  action="$(f2b_action_text)"
  if [[ -e "$F2B_FILE" || -L "$F2B_FILE" ]]; then
    if [[ ! -f "$F2B_FILE" || -L "$F2B_FILE" ]]; then
      warn "Fail2ban 规则文件是链接或特殊文件，保持不变：$F2B_FILE"; return 0
    fi
    current="$(cat "$F2B_FILE")"
    if [[ "$current" != "$guard" ]] && ! f2b_jail_is_ours "$current" "$joined"; then
      warn "已有自定义规则，或 SSH 端口变了：$F2B_FILE。保持不变，请人工迁移后再试。"
      module_result fail2ban preserved 'jail file differs'; return 0
    fi
  fi
  # An existing managed jail keeps its allowlist choice.
  if [[ -n "$current" && "$current" != "$guard" ]]; then jail="$current"
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
  if foreign_f2b_config; then
    warn '安装过程中出现了其他 Fail2ban 配置，保持不变，规则保持停用。'; return 0
  fi
  if [[ "$current" == "$guard" ]]; then
    if ! f2b_replace_owned_file "$F2B_FILE" "$guard" "$jail"; then
      warn '规则文件在安装时被改动，没有替换。'; return 0
    fi
    transitioned=1
  fi
  if [[ -L "$F2B_FILE" || "$(cat "$F2B_FILE" 2>/dev/null)" != "$jail" ||
        -L "$F2B_ACTION_FILE" || "$(cat "$F2B_ACTION_FILE" 2>/dev/null)" != "$action" ]]; then
    warn 'Fail2ban 配置在设置过程中被改动，不启动服务。'; return 0
  fi
  if ! fail2ban-client -t; then
    if ((transitioned)); then
      f2b_replace_owned_file "$F2B_FILE" "$jail" "$guard" || warn '无法恢复停用状态的规则文件，重启前请检查。'
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
    ok "Fail2ban 已就绪：只封禁 SSH 端口 $joined 的 TCP 连接，每次封 12 小时。"
    module_result fail2ban applied "sshd jail on $joined"
  else
    warn 'Fail2ban 已启动，但 SSH 规则没有加载，请查看状态和日志。'
  fi
}


# Only `ufw add`-style rules this tool created are recorded; rollback deletes
# exactly those and never touches later port rules or Fail2ban bans.
ufw_rule() {
  local verb="$1" port="$2" expected rules
  expected="ufw $verb $port/tcp"
  rules="$(ufw show added)" || return 1
  grep -Fxq "$expected" <<< "$rules" && return 0
  ufw "$verb" "$port/tcp" || return 1
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

host_has_global_ipv6() {
  command -v ip >/dev/null && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
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
firewall_stage() {
  say '第14步：防火墙（需要新 SSH 窗口确认）'
  FIREWALL_READY=0
  command -v ufw >/dev/null || { warn '还没有安装 ufw，请先运行一键开荒。'; module_result firewall skipped 'ufw missing'; return 0; }
  local state rules p ip unit deadline since ssh_verb=limit web=0
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
    echo 'SSH 仍允许密码登录：SSH 端口使用限速放行（同一 IP 30 秒内连接 6 次会被暂时拒绝）。'
  else
    echo 'SSH 已关闭密码登录：SSH 端口使用普通放行，防爆破交给 Fail2ban。'
  fi
  if web_ports_wanted '同时放行网站端口 TCP 80、443 吗？（只做代理或跳板可以不开）'; then web=1; fi
  docker_firewall_note
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
  if ((web)); then ufw_rule allow 80; ufw_rule allow 443; fi
  # Rules stored while IPV6=no exist for IPv4 only; re-adding lets UFW add the
  # missing IPv6 copies (it skips the existing IPv4 ones).
  if ((IPV6_FLIPPED)); then
    for p in "${SSH_PORTS[@]}"; do ufw "$ssh_verb" "$p/tcp" >/dev/null; done
    if ((web)); then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
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
  if ! ufw --force enable; then
    warn '开启防火墙失败，自动撤销计时器保持启用。'; module_result firewall failed 'ufw enable failed'; return 0
  fi
  # Only logins after this moment went through the enabled firewall.
  since="$(date +%s)"
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
  printf '%s\n' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no' \
    'ClientAliveInterval 300' 'ClientAliveCountMax 2'
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
  sshd -T -C "user=$user,host=$(hostname 2>/dev/null || echo localhost),addr=$addr" 2>/dev/null
}

ssh_effective_value() {
  awk -v key="$2" 'tolower($1) == key {sub(/^[^ ]+ /, ""); print; exit}' <<< "$1"
}

# sudo's success record "USER : TTY=... ; USER=root ; COMMAND=/usr/bin/true",
# written as root. Failed attempts put text before TTY= ("3 incorrect password
# attempts", "user NOT in sudoers") and a line from `logger -t sudo` by a local
# user is not written as root: neither counts.
ssh_sudo_seen() {
  local user="$1" since="$2"
  command -v journalctl >/dev/null || return 1
  journalctl -q --since "@$since" _UID=0 -t sudo -o cat --no-pager 2>/dev/null |
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
  say '第13步：SSH 登录加固（可选）'
  local user answer='' home effective auth_file count key since unit deadline want_admin=0 tries detail
  local -a missing=()
  if [[ -z "${SSH_CHOICE:-}" ]]; then
    if [[ "$MODE" == ssh ]] || confirm_yes '加固 SSH 登录（只允许密钥登录，可选新建管理员并禁止 root 直接登录）吗？（推荐）'; then SSH_CHOICE=1; else SSH_CHOICE=0; fi
  fi
  if [[ "$SSH_CHOICE" != 1 ]]; then ok 'SSH 登录设置保持不变。'; module_result ssh declined 'not requested'; return 0; fi
  if ! command -v sshd >/dev/null || ! command -v ssh-keygen >/dev/null || ! command -v runuser >/dev/null; then
    warn '缺少 sshd、ssh-keygen 或 runuser，无法加固 SSH。'; module_result ssh unsupported 'OpenSSH tools missing'; return 0
  fi
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
  if ! sshd -t; then
    rm -f -- "$SSH_DROPIN"; warn 'sshd -t 不接受新配置，已删除。'; module_result ssh failed 'sshd -t failed'; return 0
  fi
  effective="$(ssh_effective "$user")" || effective=''
  [[ "$(ssh_effective_value "$effective" passwordauthentication)" == no ]] || missing+=(PasswordAuthentication)
  [[ "$(ssh_effective_value "$effective" kbdinteractiveauthentication)" == no ]] || missing+=(KbdInteractiveAuthentication)
  if ((want_admin)) && [[ "$(ssh_effective_value "$(ssh_effective root)" permitrootlogin)" != no ]]; then missing+=(PermitRootLogin); fi
  if ((${#missing[@]})); then
    rm -f -- "$SSH_DROPIN"
    warn "这些设置被更早的配置覆盖，没有生效：${missing[*]}（检查 /etc/ssh/sshd_config 和编号更小的 sshd_config.d 文件）。已撤销。"
    module_result ssh preserved 'earlier sshd setting wins'; return 0
  fi
  unit="vps-stable-ssh-revert-$(date +%s)-$$"
  guard_arm "$unit" /bin/sh -c "rm -f -- '$SSH_DROPIN'; systemctl try-reload-or-restart ssh.service" || {
    rm -f -- "$SSH_DROPIN"; warn '无法启用 SSH 自动撤销计时器；没有做任何修改。'; module_result ssh failed 'guard not armed'; return 0
  }
  deadline=$((SECONDS + 180))
  if ! ssh_reload; then warn 'sshd 重新加载失败；自动撤销计时器保持启用。'; module_result ssh failed 'sshd reload failed'; return 0; fi
  # Only a key login after the reload proves the new settings work.
  since="$(date +%s)"
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
audit_journal_counts() {
  awk '
    NR>3000 {limited=1; next}
    {
      line=tolower(substr($0,1,1024)); scanned++
      if(line~/^hint:|^no journal files|^-- no entries --$|^failed to open|^you are currently not seeing|^insufficient permissions|^no entries were found/) access_issue++
      if(line~/out of memory:|oom-kill:|oom_reaper:|memory cgroup out of memory|killed process [0-9]+|invoked oom-killer/) oom++
      if(line~/i\/o error|buffer i\/o|blk_update_request:.*error|blk_print_req_error:|ext4-fs error|xfs.*(corrupt|i\/o error)|btrfs.*(error|corrupt)|nvme.*(i\/o|timeout)/) io++
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
  for file in "$BBR_FILE" "$MODULE_FILE" "$ZRAM_FILE" "$ZRAM_SYSCTL_FILE" "$JOURNAL_FILE" "$F2B_FILE" "$APT_FILE" "$F2B_ACTION_FILE" "$SSH_DROPIN" "$SSH_PUBKEY_DROPIN" \
      /etc/ssh/sshd_config /etc/default/ssh /etc/default/ufw \
      /etc/ufw/ufw.conf /etc/ufw/sysctl.conf /etc/ufw/before.rules /etc/ufw/before6.rules \
      /etc/ufw/after.rules /etc/ufw/after6.rules /etc/ufw/user.rules /etc/ufw/user6.rules \
      /etc/sysctl.conf /etc/systemd/journald.conf /etc/default/zramswap \
      /etc/apt/apt.conf /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/sources.list /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
      /etc/systemd/timesyncd.conf; do
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
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc > "$RUN_BACKUP_DIR/runtime-sysctl.txt" 2>&1 || true
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
  case "$action" in plan|setup|item|firewall|ssh|port|check|records|uninstall|rollback|reboot|update|bans) ;; *) die '无效的菜单操作。' ;; esac
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

menu() {
  local self choice action before=''
  [[ -t 0 ]] || die '菜单需要交互终端；请登录 SSH 后输入 vps。'
  self="$(readlink -f -- "${BASH_SOURCE[0]}")" || die '无法确定本工具所在位置。'
  [[ -f "$self" && -r "$self" ]] || die '无法读取本工具的脚本文件。'
  while :; do
    say "VPS 机器管家 V$SCRIPT_VERSION"
    menu_reboot_hint
    cat <<'MENU_TEXT'
 开荒
   1. 给机器做体检（只检查，不修改）
   2. 一键开荒（更新系统并优化机器）
   3. 开荒验收（检查优化是否真的生效，适合重启后）
 日常管理
   4. 端口管理（放行 / 关闭端口）
   5. 单项设置（逐项开启或关闭某一项）
   6. 查看 Fail2ban 封禁记录（可以解封某个 IP）
   7. 重启服务器（先说明是否需要重启，确认后才重启）
 安全加固（一键开荒里已经包含，这里可以单独再做）
   8. 设置防火墙和 SSH 防爆破
   9. SSH 登录加固（只允许密钥登录，可选新建管理员并禁止 root 直接登录）
 记录与撤销
  10. 查看操作记录和配置备份
  11. 撤销本工具的设置（全部或只撤销某一项）
 本工具
  12. 卸载本工具，保留优化效果
  13. 检查更新（有新版本时直接更新本工具）
   h. 查看使用说明
   0. 退出

第一次用：先选 1 体检，再选 2 一键开荒；重启后选 3 验收。以后想单独改哪一项选 5，需要重启选 7。
撤销设置会保留已安装/升级的软件（可选卸载本工具新装的包），不会还原整台机器。
卸载会删除工具、记录和备份；删除备份后无法可靠回退。
MENU_TEXT
    if ! read -r -p '请输入选项 [0-13 或 h]: ' choice; then printf '\n'; return 0; fi
    case "$choice" in
      0) return 0 ;;
      1) action=plan ;;
      2) action=setup ;;
      3) action=check ;;
      4) action=port ;;
      5) action=item ;;
      6) action=bans ;;
      7) action=reboot ;;
      8) action=firewall ;;
      9) action=ssh ;;
      10) action=records ;;
      11) action=rollback ;;
      12) action=uninstall ;;
      13) action=update ;;
      h|H) /bin/bash -- "$self" help; action='' ;;
      *) echo '无效选项，请输入 0 至 13 或 h。'; continue ;;
    esac
    if [[ "$action" == update ]]; then before="$(sha256sum -- "$self" 2>/dev/null || true)"; fi
    if [[ -n "$action" ]]; then menu_action "$self" "$action"; fi
    # Uninstall may remove the installed source and launcher in its child.
    if [[ ! -f "$self" ]]; then echo '本工具已卸载，菜单退出。'; return 0; fi
    # This menu is still the old version in memory: start the new one fresh.
    if [[ "$action" == update && "$(sha256sum -- "$self" 2>/dev/null || true)" != "$before" ]]; then
      echo '本工具已更新，菜单先退出；重新输入 vps 打开新版本。'; return 0
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
  own_state="$(decision_file_state "$JOURNAL_FILE" $'[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\nMaxRetentionSec=14day')"
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
      *) decision_line '准备调整' '日志空间' '系统盘不大于 20GiB，计划限制日志：持久日志 100MiB、临时日志 50MiB、保留 14 天。' ;;
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
    ntp) printf '%s\n' ntp svc_timesync ;;
    journal) printf '%s\n' journal_file ;;
    trim) printf '%s\n' svc_trim ;;
    updates) printf '%s\n' apt_file svc_apt_daily svc_apt_upgrade ;;
    autoreboot) printf '%s\n' apt_reboot_file ;;
    timezone) printf '%s\n' tz ;;
    sysctl) printf '%s\n' sysctl_file ;;
    hosts) printf '%s\n' hosts_file ;;
    ssh) printf '%s\n' ssh_dropin ssh_pubkey_dropin ;;
    firewall) printf '%s\n' ufw_policy_in ufw_policy_out ufw_ipv6 ufw_runtime svc_ufw ;;
    fail2ban) printf '%s\n' f2b_jail f2b_action svc_fail2ban ;;
  esac
  return 0
}

restore_all_ids() {
  printf '%s\n' bbr_file bbr_module cc qdisc sysctl_file zram_file zram_swap zram_sysctl_file journal_file apt_auto_file apt_file apt_reboot_file ntp svc_timesync svc_trim svc_apt_daily svc_apt_upgrade tz hosts_file ssh_dropin ssh_pubkey_dropin ufw_policy_in ufw_policy_out ufw_ipv6 ufw_runtime svc_ufw f2b_jail f2b_action svc_fail2ban
}

restore_label() {
  case "$1" in
    bbr_file) echo 'BBR 配置文件' ;; bbr_module) echo 'BBR 模块加载配置' ;;
    cc) echo 'TCP 拥塞算法' ;; qdisc) echo '默认队列算法' ;;
    zram_file) echo 'ZRAM 配置' ;; zram_swap) echo 'ZRAM 交换空间' ;; zram_sysctl_file) echo 'ZRAM 配套内存参数' ;;
    journal_file) echo '日志限制配置' ;; apt_auto_file) echo '自动更新开关（20auto-upgrades）' ;;
    apt_file) echo '自动更新策略文件' ;; ntp) echo '时间同步开关' ;;
    svc_timesync) echo '时间同步服务' ;; svc_trim) echo 'TRIM 定时任务' ;;
    svc_apt_daily) echo 'APT 每日更新定时器' ;; svc_apt_upgrade) echo 'APT 每日升级定时器' ;;
    tz) echo '时区' ;; ssh_dropin) echo 'SSH 仅密钥登录配置' ;; ssh_pubkey_dropin) echo 'SSH 公钥登录开关' ;;
    ufw_policy_in) echo '防火墙入站默认策略' ;; ufw_policy_out) echo '防火墙出站默认策略' ;;
    ufw_runtime) echo '防火墙开关' ;; svc_ufw) echo '防火墙服务' ;;
    f2b_jail) echo 'Fail2ban SSH 规则' ;; f2b_action) echo 'Fail2ban 封禁动作' ;;
    svc_fail2ban) echo 'Fail2ban 服务' ;; sysctl_file) echo '内核网络安全参数' ;;
    apt_reboot_file) echo '自动更新的重启时间' ;; hosts_file) echo '/etc/hosts 主机名' ;;
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
    ssh_dropin) printf '%s\n' "$SSH_DROPIN" ;;
    ssh_pubkey_dropin) printf '%s\n' "$SSH_PUBKEY_DROPIN" ;;
    sysctl_file) printf '%s\n' "$SYSCTL_HARDENING_FILE" ;;
    apt_reboot_file) printf '%s\n' "$APT_REBOOT_FILE" ;;
    hosts_file) echo /etc/hosts ;;
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
restore_prepare() {
  local tmp
  [[ "${EUID:-$(id -u)}" == 0 ]] || die '回退记录需要 root 权限。'
  RESTORE_ROOT="$STATE_ROOT/restore-v2"
  state_secure_dir "$RESTORE_ROOT"
  if [[ ! -e "$RESTORE_ROOT/packages" && ! -L "$RESTORE_ROOT/packages" ]]; then
    tmp="$(mktemp -d "$RESTORE_ROOT/.capture.XXXXXX")"
    chmod 700 -- "$tmp"
    if dpkg-query -W -f='${db:Status-Status}\t${Package}\n' 2>/dev/null | awk -F'\t' '$1 == "installed" {print $2}' | sort -u > "$tmp/before" &&
       [[ -s "$tmp/before" ]] && chmod 600 -- "$tmp/before"; then
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
  [[ "$rule" =~ ^ufw\ (allow|limit)\ [0-9]{1,5}/tcp$ ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && grep -Fxq -- "$rule" "$file"; then return 0; fi
  printf '%s\n' "$rule" >> "$file" && chmod 600 -- "$file"
}

# Running sysctl values before this tool first changed them (first value wins).
# NAME is the record (sysctl_runtime for the hardening, zram_sysctl_runtime for ZRAM).
restore_record_sysctl() {
  local key="$1" value="$2" file="$RESTORE_ROOT/${3:-sysctl_runtime}"
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ "$key" =~ ^[a-z][A-Za-z0-9_.-]*$ && "$value" =~ ^-?[0-9]+$ ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && awk -F= -v k="$key" '$1 == k {found = 1} END {exit !found}' "$file"; then return 0; fi
  printf '%s=%s\n' "$key" "$value" >> "$file" && chmod 600 -- "$file"
}

# Applied after the configuration file itself was removed. An interface that
# no longer exists (a container's veth) has nothing left to restore.
restore_sysctl_runtime() {
  local file="$RESTORE_ROOT/${1:-sysctl_runtime}" line key value failed=0
  [[ -e "$file" || -L "$file" ]] || return 0
  restore_data_safe "$file" || { warn '内核参数原值记录不安全，跳过。'; RESTORE_PARTIAL=1; return 0; }
  while IFS= read -r line; do
    key="${line%%=*}"; value="${line#*=}"
    if [[ ! "$key" =~ ^[a-z][A-Za-z0-9_.-]*$ || ! "$value" =~ ^-?[0-9]+$ ]]; then warn "忽略格式异常的记录：$line"; failed=1; continue; fi
    if [[ "$key" =~ ^net\.ipv6\.conf\.([^.]+)\.accept_redirects$ && "${BASH_REMATCH[1]}" != all && "${BASH_REMATCH[1]}" != default &&
          ! -d "/proc/sys/net/ipv6/conf/${BASH_REMATCH[1]}" ]]; then continue; fi
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
restore_record_hosts_line() {
  local line="$1" file="$RESTORE_ROOT/hosts_line" re=$'^127\\.0\\.1\\.1\t[A-Za-z0-9.-]+$'
  [[ "$RESTORE_READY" == 1 ]] || return 0
  [[ "$line" =~ $re ]] || return 1
  [[ ! -L "$file" && ( ! -e "$file" || ( -f "$file" && -O "$file" ) ) ]] || return 1
  if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file"; then return 0; fi
  printf '%s\n' "$line" >> "$file" && chmod 600 -- "$file"
}

restore_hosts_line_present() {
  local record="$RESTORE_ROOT/hosts_line" file
  file="$(restore_path hosts_file)" || return 1
  restore_data_safe "$record" && [[ -f "$file" ]] && grep -qxF -f "$record" -- "$file"
}

restore_hosts_lines_apply() {
  local record="$RESTORE_ROOT/hosts_line" file temp rc=0
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
    tz) [[ "$value" =~ ^[A-Za-z0-9_+/-]+$ ]] || return 1; timedatectl set-timezone "$value" ;;
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
  for id in f2b_jail f2b_action svc_fail2ban; do
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
  # Still running after its service state was restored: it ran before this tool.
  if active fail2ban; then
    if systemctl restart fail2ban; then ok '原有 Fail2ban 已按它自己的配置重新加载。'
    else warn 'Fail2ban 重新加载失败，请人工检查。'; RESTORE_PARTIAL=1; fi
  fi
}

# Deletes exactly the rules this tool added. While UFW stays on, an SSH
# allowance is never removed, so rollback cannot lock the session out.
restore_fw_rules_apply() {
  local file="$RESTORE_ROOT/fw_rules" rule verb port current ufw_on=0 ssh_ports temp
  local -a remaining=()
  [[ -e "$file" || -L "$file" ]] || return 0
  restore_data_safe "$file" || { warn '防火墙规则记录不安全，已跳过。'; RESTORE_PARTIAL=1; return 0; }
  command -v ufw >/dev/null || { warn '找不到 ufw，无法删除本工具添加的规则。'; RESTORE_PARTIAL=1; return 0; }
  current="$(ufw show added)" || { warn '无法读取 UFW 规则。'; RESTORE_PARTIAL=1; return 0; }
  if ufw_active; then ufw_on=1; fi
  ssh_ports=" 22 $(ssh_candidates | sort -n -u | tr '\n' ' ') "
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if [[ ! "$rule" =~ ^ufw\ (allow|limit)\ ([0-9]{1,5})/tcp$ ]]; then
      warn "忽略格式异常的规则记录：$rule"; RESTORE_PARTIAL=1; continue
    fi
    verb="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    if ! grep -Fxq -- "$rule" <<< "$current"; then ok "规则已不存在：$rule"; continue; fi
    if ((ufw_on)) && [[ "$ssh_ports" == *" $port "* ]]; then
      warn "防火墙仍处于开启状态，保留 SSH 端口规则：$rule"; remaining+=("$rule"); RESTORE_PARTIAL=1; continue
    fi
    if ufw --force delete "$verb" "$port/tcp" >/dev/null; then ok "已删除本工具添加的规则：$rule"
    else warn "删除规则失败：$rule"; remaining+=("$rule"); RESTORE_PARTIAL=1; fi
  done < "$file"
  if ((${#remaining[@]})); then
    temp="$(mktemp "$RESTORE_ROOT/.write.XXXXXX")" || return 0
    printf '%s\n' "${remaining[@]}" > "$temp" && chmod 600 -- "$temp" && mv -fT -- "$temp" "$file" || rm -f -- "$temp"
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

# Simulates first. Removal (never purge) proceeds only when APT would remove
# nothing that existed before this tool's first run. With arguments, only
# those packages (of the ones this tool installed) are considered.
restore_packages_offer() {
  local dir="$RESTORE_ROOT/packages" sim pkg mode chosen='' bad
  local -a ours=() removed=() flags=() all=()
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
  echo '只用 apt remove（不是 purge），配置文件会留在 /etc；系统升级和内核不受影响。'
  if ! confirm_yes '确认卸载上述软件包吗？'; then ok '保留这些软件包。'; return 0; fi
  flags=()
  [[ "$chosen" == autoremove ]] && flags=(--autoremove)
  apt_wait_idle
  if apt-get -y -q -o DPkg::Lock::Timeout=120 remove "${flags[@]}" "${ours[@]}"; then
    ok '已卸载本工具新装的软件包。'
    if [[ " ${ours[*]} " == *' systemd-zram-generator '* ]]; then ZRAM_PACKAGE_REMOVED=1; fi
    restore_packages_record
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
  printf '%s\n' fail2ban firewall ssh zram bbr sysctl journal updates autoreboot ntp trim timezone hosts
}

restore_group_label() {
  case "$1" in
    firewall) echo '防火墙（本工具加的规则、默认策略、开关）' ;; fail2ban) echo 'Fail2ban 防爆破' ;;
    ssh) echo 'SSH 登录加固（恢复密码和 root 登录）' ;; zram) echo 'ZRAM 内存缓冲' ;;
    bbr) echo 'BBR 网络加速' ;; sysctl) echo '内核网络安全参数' ;; journal) echo '日志空间限制' ;;
    updates) echo '自动安全更新' ;; autoreboot) echo '更新后自动重启时间' ;; ntp) echo '时间同步' ;;
    trim) echo '定期 TRIM' ;; timezone) echo '时区' ;; hosts) echo '/etc/hosts 主机名' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

restore_group_ids() {
  case "$1" in
    firewall) printf '%s\n' ufw_runtime ufw_policy_in ufw_policy_out ufw_ipv6 svc_ufw ;;
    fail2ban) printf '%s\n' f2b_jail f2b_action svc_fail2ban ;;
    ssh) printf '%s\n' ssh_dropin ssh_pubkey_dropin ;;
    zram) printf '%s\n' zram_file zram_swap zram_sysctl_file ;;
    bbr) printf '%s\n' bbr_file bbr_module cc qdisc ;;
    sysctl) printf '%s\n' sysctl_file ;;
    journal) printf '%s\n' journal_file ;;
    updates) printf '%s\n' apt_auto_file apt_file svc_apt_daily svc_apt_upgrade ;;
    autoreboot) printf '%s\n' apt_reboot_file ;;
    ntp) printf '%s\n' ntp svc_timesync ;;
    trim) printf '%s\n' svc_trim ;;
    timezone) printf '%s\n' tz ;;
    hosts) printf '%s\n' hosts_file ;;
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
    zram) [[ -s "$RESTORE_ROOT/zram_sysctl_runtime" ]] && return 0 ;;
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
    ssh) restore_ssh_group ;;
    zram) restore_zram_group ;;
    sysctl)
      restore_resource sysctl_file
      if [[ "$(restore_read sysctl_file state 2>/dev/null || true)" != applied ]]; then restore_sysctl_runtime; fi ;;
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
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= i)) || { ok '已取消。'; return 0; }
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
  local file="$STATE_ROOT/modules/$1" result ts boot detail
  [[ "$1" =~ ^[a-z0-9_]+$ && -f "$file" && ! -L "$file" && -O "$file" ]] || return 1
  IFS=$'\t' read -r result ts boot detail < "$file" || return 1
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
verify_line() {
  case "$1" in
    pass) VERIFY_PASS=$((VERIFY_PASS + 1)); printf '\033[1;32m[✅ 生效]\033[0m   %s：%s\n' "$2" "$3" ;;
    healthy) VERIFY_PASS=$((VERIFY_PASS + 1)); printf '\033[1;32m[✅ 正常]\033[0m   %s：%s\n' "$2" "$3" ;;
    fail) VERIFY_FAIL=$((VERIFY_FAIL + 1)); printf '\033[1;31m[❌ 未生效]\033[0m %s：%s\n' "$2" "$3" ;;
    na) VERIFY_NA=$((VERIFY_NA + 1)); printf '[➖ 未处理] %s：%s\n' "$2" "$3" ;;
    # Expected to take effect with the next boot: not a failure.
    reboot) VERIFY_REBOOT=$((${VERIFY_REBOOT:-0} + 1)); printf '\033[1;33m[⏳ 待重启]\033[0m %s：%s\n' "$2" "$3" ;;
    *) VERIFY_UNKNOWN=$((VERIFY_UNKNOWN + 1)); printf '\033[1;33m[❓ 无法确认]\033[0m %s：%s\n' "$2" "$3" ;;
  esac
}

# Applies the recorded expectation: only applied/present results are checked
# against the live state; every other result is reported as intentionally unhandled.
VERIFY_STATUS=''
VERIFY_TEXT=''
verify_module() {
  local module="$1" label="$2" check="$3" info result detail
  if ! info="$(module_expect "$module")"; then
    verify_line na "$label" '没有开荒记录（还没运行过一键开荒或对应功能）'; return 0
  fi
  IFS=$'\t' read -r result _ detail <<< "$info"
  case "$result" in
    applied|present)
      VERIFY_STATUS=unknown VERIFY_TEXT='检查未返回结果'
      "$check" "$detail"
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
  local rip rport lip lport
  read -r rip rport lip lport <<< "${SSH_CONNECTION:-}"
  [[ "$lport" =~ ^[0-9]+$ && "$rport" =~ ^[0-9]+$ ]] || return 1
  command -v ss >/dev/null || return 1
  ss -tinH state established "( sport = :$lport and dport = :$rport )" 2>/dev/null | grep -qw bbr
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
  local size line bad='' algorithm
  size="$(awk 'NR > 1 && $1 == "/dev/zram0" {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
  [[ -n "$size" ]] || { verify_set fail '没有找到正在使用的 /dev/zram0'; return 0; }
  if [[ -f "$ZRAM_SYSCTL_FILE" ]]; then
    while IFS= read -r line; do
      case "$line" in 'bad '*) bad+=" ${line#bad }" ;; esac
    done < <(sysctl_file_mismatch "$ZRAM_SYSCTL_FILE")
  fi
  # The selected algorithm is the bracketed one: "lzo [lz4] zstd".
  algorithm="$(sed -n 's/.*\[\([a-z0-9-]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then verify_set fail "/dev/zram0 已启用，但配套内存参数和配置不一致：${bad# }"
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
  local value usage
  value="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '$1 == "SystemMaxUse" {v = $2} END {print v}' || true)"
  usage="$(journalctl --disk-usage 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)?[KMGT]?B?' | head -n 1 || true)"
  if [[ "$value" == 100M ]]; then verify_set pass "日志上限 100M 已生效，当前占用 ${usage:-未知}"
  else verify_set fail "当前生效的日志上限是 ${value:-默认值}，不是 100M"; fi
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
  local pkg missing=''
  for pkg in "${TOOLS_PACKAGES[@]}"; do installed "$pkg" || missing+=" $pkg"; done
  if [[ -z "$missing" ]]; then verify_set pass "${TOOLS_PACKAGES[*]}"
  else verify_set fail "缺少：${missing# }"; fi
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
  local status failed banned actions
  if ! active fail2ban || ! command -v fail2ban-client >/dev/null; then verify_set fail 'Fail2ban 服务没有运行'; return 0; fi
  # This tool's ban action is a UFW rule: without a running UFW nothing is blocked.
  if ! ufw_active; then verify_set fail '防火墙没有运行：Fail2ban 的封禁要靠防火墙执行，现在封不住任何 IP'; return 0; fi
  if ! status="$(fail2ban-client status sshd 2>/dev/null)"; then verify_set fail 'sshd 规则没有加载'; return 0; fi
  failed="$(awk -F: '/Total failed/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  banned="$(awk -F: '/Total banned/ {gsub(/[ \t]/, "", $2); print $2}' <<< "$status")"
  actions="$(fail2ban-client get sshd actions 2>/dev/null || true)"
  if [[ "$actions" != *vps-stable-ufw-sshd* ]]; then verify_set fail 'sshd 规则没有使用本工具的 UFW 封禁动作'; return 0; fi
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

verify_health() {
  local failed host
  failed="$(systemctl list-units --state=failed --type=service --no-legend --no-pager --plain 2>/dev/null | grep -c . || true)"
  if [[ "$failed" == 0 ]]; then verify_line healthy '系统服务' '本次启动没有失败的服务'
  else verify_line fail '系统服务' "有 ${failed} 个失败的服务，运行 systemctl --failed 查看"; fi
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
    same) echo '⚠ 有设置是本次开机后才做的，还没有经过重启验证：以下结果只代表当前运行状态。' ;;
    other) echo '✅ 开荒之后已经重启过（启动 ID 已变化），以下结果代表重启后的真实状态。' ;;
    *) echo '没有找到开荒记录，只检查系统当前状态。' ;;
  esac
}

verify_summary() {
  say '开荒验收（只读）'
  verify_reboot_state
  verify_kernel
  verify_module bbr 'BBR 网络优化' check_bbr
  verify_module sysctl '内核网络安全参数' check_sysctl
  verify_module zram 'ZRAM 内存缓冲' check_zram
  verify_module ntp '时间同步' check_ntp
  verify_module journal '日志限制' check_journal
  verify_module trim '磁盘 TRIM' check_trim
  verify_module updates '自动安全更新' check_updates
  verify_module autoreboot '更新后自动重启' check_autoreboot
  verify_module tools '常用工具' check_tools
  verify_module traffic '流量统计' check_traffic
  verify_module timezone '时区' check_timezone
  verify_module hosts '主机名解析' check_hosts
  verify_module ssh 'SSH 登录加固' check_ssh
  verify_module firewall '防火墙' check_firewall
  verify_module fail2ban 'Fail2ban 防爆破' check_fail2ban
  if docker_present; then verify_line unknown 'Docker' '已安装：用 -p 发布的容器端口会绕过防火墙，请确认这些端口确实需要对外'; fi
  verify_health
  echo
  printf '结论：%s 项正常，%s 项未生效，%s 项按计划未处理，%s 项无法确认' "$VERIFY_PASS" "$VERIFY_FAIL" "$VERIFY_NA" "$VERIFY_UNKNOWN"
  if ((${VERIFY_REBOOT:-0})); then printf '，%s 项等重启后生效' "$VERIFY_REBOOT"; fi
  echo '。'
  if ((VERIFY_FAIL)); then echo '“未生效”的项目请按说明处理；处理后可再次运行 vps check。'; fi
  if ((${VERIFY_REBOOT:-0})); then echo '“待重启”的项目重启后自动生效：选菜单 7 重启，重启后再选 3 验收。'; fi
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
  printf '\033[1;33m检测到开荒后已经重启，建议选 3 做开荒验收，确认优化真的生效。\033[0m\n'
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
  printf '%s\n' upgrade updates autoreboot bbr sysctl zram journal trim ntp timezone hosts tools vnstat kernel firewall fail2ban ssh ports
}

item_label() {
  case "$1" in
    upgrade) echo '系统升级（立即升级一次）' ;; updates) echo '自动安全更新' ;; autoreboot) echo '更新后自动重启' ;;
    bbr) echo 'BBR 网络加速' ;; sysctl) echo '内核网络安全参数' ;; zram) echo 'ZRAM 内存缓冲' ;;
    journal) echo '日志空间限制' ;; trim) echo '定期 TRIM' ;; ntp) echo '时间同步' ;; timezone) echo '时区' ;;
    hosts) echo '主机名解析' ;; tools) echo '常用工具' ;; vnstat) echo 'vnStat 流量统计' ;; kernel) echo '清理旧内核' ;;
    firewall) echo '防火墙' ;; fail2ban) echo 'Fail2ban 防爆破' ;; ssh) echo 'SSH 登录加固' ;; ports) echo '端口管理' ;;
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
    zram)
      value="$(awk 'NR > 1 && $1 == "/dev/zram0" {printf "%d", $3 / 1024}' /proc/swaps 2>/dev/null || true)"
      if [[ -n "$value" ]]; then echo "已开启，约 ${value} MiB"
      elif swapon --noheadings 2>/dev/null | grep -q .; then echo '已有其他 Swap'
      elif ! zram_module_available; then echo '内核不支持（没有 zram 模块）'
      else echo '未开启'; fi ;;
    journal) if [[ -f "$JOURNAL_FILE" ]]; then echo '已限制（100M）'; else echo '默认设置'; fi ;;
    trim) if ! trim_support; then echo '系统盘不支持'; elif systemctl is-enabled -q fstrim.timer 2>/dev/null; then echo '已开启'; else echo '未开启'; fi ;;
    ntp) if ntp_synced; then echo '已同步'; else echo '未同步'; fi ;;
    timezone) timedatectl show -p Timezone --value 2>/dev/null || echo '未知' ;;
    hosts) if hostname_resolves; then echo '正常'; else echo '无法解析'; fi ;;
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
    autoreboot) echo '1. 设置自动重启时间   2. 取消（撤销本工具的设置）   0. 返回' ;;
    ssh) echo '1. 加固（只允许密钥登录，可选禁止 root）   2. 撤销（恢复密码和 root 登录）   0. 返回' ;;
    *) echo '1. 开启   2. 关闭（撤销本工具的修改）   0. 返回' ;;
  esac
  read -r -p '请选择: ' choice || return 0
  case "$key:$choice" in
    firewall:2) item_firewall_pause ;;
    firewall:3) item_turn_off firewall ;;
    upgrade:1|kernel:1) item_turn_on "$key" ;;
    upgrade:*|kernel:*) return 0 ;;
    *:1) item_turn_on "$key" ;;
    *:2) item_turn_off "$key" ;;
    *) return 0 ;;
  esac
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
    echo '  0. 返回'
    read -r -p "请选择要修改的项目 [1-$i，0 返回]: " choice || return 0
    if [[ -z "$choice" || "$choice" == 0 ]]; then return 0; fi
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

# Menu 11 / vps reboot. Refuses while an SSH protection timer is pending (a
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

# ---- Update (menu 12 / vps update) -------------------------------------------------
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

# ---- Fail2ban ban records (menu 13 / vps bans) -------------------------------------
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
      if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) t = $1 " " substr($2, 1, 8)
      else { t = substr($1, 1, 19); sub(/T/, " ", t) }
      if ($0 ~ / Unban /) e = "解封"; else if ($0 ~ / Restore Ban /) e = "重启后恢复封禁"; else e = "封禁"
      print t "\t" e "\t" $NF
    }' | tail -n "$limit"
}

bans_main() {
  local status failed banned total list bantime times ignore me ip line
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
  printf '正在封禁：%s 个 IP' "${banned:-0}"
  if [[ "$bantime" =~ ^[0-9]+$ ]] && ((bantime >= 3600)); then printf '（每次封 %s 小时）' "$((bantime / 3600))"
  elif [[ "$bantime" =~ ^[0-9]+$ ]]; then printf '（每次封 %s 分钟）' "$((bantime / 60))"; fi
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
  case "$MODE" in
    menu) menu; return 0 ;;
    uninstall) tool_uninstall; return 0 ;;
    rollback) restore_main; exit "$RESTORE_EXIT_CODE" ;;
    records) records_report; return 0 ;;
    check) verify_main; exit "$VERIFY_EXIT" ;;
    plan) plan; return 0 ;;
    port) port_main; return 0 ;;
    item) item_main; return 0 ;;
    reboot) reboot_main; return 0 ;;
    update) update_main; return 0 ;;
    bans) bans_main; return 0 ;;
  esac
  validate_vm
  plan
  if [[ "$MODE" == setup ]] && ! session_resilience_check; then
    ok '已取消；进入 tmux 或 screen 后再运行 vps 即可。'
    return 0
  fi
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
    # Time first (APT validates Release dates), every question next, ZRAM
    # before a large upgrade; the steps that need the user come last.
    stage_run ntp ntp_stage
    stage_run apt_index apt_index_stage
    stage_run questions setup_questions
    stage_run zram zram_stage
    stage_run apt_upgrade apt_upgrade_stage
    stage_run bbr bbr_stage
    stage_run sysctl sysctl_hardening_stage
    stage_run journal journal_stage
    stage_run trim trim_stage
    stage_run updates updates_stage
    stage_run autoreboot auto_reboot_configure
    stage_run timezone timezone_stage
    stage_run hosts hosts_stage
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
