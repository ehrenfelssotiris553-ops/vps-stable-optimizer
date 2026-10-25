#!/usr/bin/env bash
# Installs the menu tool only. System changes require a later menu selection.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

# Download location and the main script's hash; update the hash on every release.
RELEASE_BASE_URL='https://raw.githubusercontent.com/ehrenfelssotiris553-ops/vps-stable-optimizer/main'
EXPECTED_SHA256='61b8893b6811421aa07fe894b2ad3d0501f3847216436df6ca93a82f8c2f14d9'
PAYLOAD_NAME='vps-stable-opt-v2.6.0.sh'
INSTALL_DIR=/usr/local/lib/vps-stable-opt
INSTALL_FILE="$INSTALL_DIR/vps-stable-opt.sh"
MARKER_FILE="$INSTALL_DIR/.installer-owner"
HASH_FILE="$INSTALL_DIR/.installed-sha256"
LAUNCHER_FILE=/usr/local/bin/vps
BASE_URL="$RELEASE_BASE_URL"
LOCAL_FILE=''
NO_RUN=0
BASE_SELECTED=0
TMP_DIR=''
MAIN_STAGE=''
MARKER_STAGE=''
HASH_STAGE=''
LAUNCHER_STAGE=''
CREATED_MAIN=0
CREATED_MARKER=0
CREATED_HASH=0
CREATED_LAUNCHER=0
CREATED_DIR=0
INSTALL_OK=0

die() { printf '安装已停止：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
VPS Stable Optimizer V2.6.0 安装入口

用法：bash install.sh [--base-url HTTPS目录 | --local-file 脚本路径] [--no-run]

  --base-url URL    从该 HTTPS 目录下载 vps-stable-opt-v2.6.0.sh。
  --local-file 文件 核验并安装已经下载的主脚本。
  --no-run          只安装，不打开菜单；允许没有交互终端。
  --help            显示此说明。

安装成功后，使用 sudo vps 打开中文菜单；root 用户直接执行 vps。
安装器仅安装菜单工具。系统更新、防火墙等操作须进入菜单后另行选择。
菜单内可卸载工具及其安装数据，保留软件和优化效果。没有临时使用模式。
EOF
}

cleanup() {
  local code=$?
  trap - EXIT
  # On incomplete installation, remove only files published by this invocation.
  if (( INSTALL_OK == 0 )); then
    if (( CREATED_LAUNCHER )); then rm -f -- "$LAUNCHER_FILE" || true; fi
    if (( CREATED_MARKER )); then rm -f -- "$MARKER_FILE" || true; fi
    if (( CREATED_HASH )); then rm -f -- "$HASH_FILE" || true; fi
    if (( CREATED_MAIN )); then rm -f -- "$INSTALL_FILE" || true; fi
  fi
  [[ -z "$MAIN_STAGE" ]] || rm -f -- "$MAIN_STAGE" || true
  [[ -z "$MARKER_STAGE" ]] || rm -f -- "$MARKER_STAGE" || true
  [[ -z "$HASH_STAGE" ]] || rm -f -- "$HASH_STAGE" || true
  [[ -z "$LAUNCHER_STAGE" ]] || rm -f -- "$LAUNCHER_STAGE" || true
  if [[ -n "$TMP_DIR" ]]; then
    rm -f -- "$TMP_DIR/payload.sh" "$TMP_DIR/launcher" "$TMP_DIR/marker" "$TMP_DIR/sha256" || true
    rmdir -- "$TMP_DIR" 2>/dev/null || true
  fi
  if (( CREATED_DIR && INSTALL_OK == 0 )); then rmdir -- "$INSTALL_DIR" 2>/dev/null || true; fi
  exit "$code"
}

on_error() {
  local code="$1" line="$2"
  trap - ERR
  printf '安装步骤失败（行 %s，退出码 %s）；未执行系统优化。\n' "$line" "$code" >&2
  exit "$code"
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# )); do
  case "$1" in
    --base-url)
      (( $# >= 2 )) || die '--base-url 缺少网址。'
      (( BASE_SELECTED == 0 )) || die '不能重复指定 --base-url。'
      BASE_SELECTED=1; BASE_URL="$2"; shift 2 ;;
    --local-file)
      (( $# >= 2 )) || die '--local-file 缺少路径。'
      [[ -z "$LOCAL_FILE" ]] || die '不能重复指定 --local-file。'
      LOCAL_FILE="$2"; shift 2 ;;
    --no-run) NO_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数：$1。使用 --help 查看说明。" ;;
  esac
done

[[ -z "$LOCAL_FILE" || "$BASE_SELECTED" == 0 ]] || die '--base-url 与 --local-file 只能选择一个。'
[[ "$EUID" -eq 0 ]] || die '请使用 root 或 sudo bash install.sh。'
if (( NO_RUN == 0 )); then [[ -t 0 && -t 1 ]] || die '请在 SSH 交互终端中执行，或加 --no-run 仅安装。'; fi
[[ "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die '本安装入口尚未生成主脚本校验值，不能发布或使用。'

# These are the optimizer's tested target platforms, not an OS conversion step.
[[ -r /etc/os-release ]] || die '无法识别 Linux 发行版。'
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
  *) die '当前仅支持 Debian 12/13、Ubuntu 22.04/24.04/26.04。' ;;
esac
[[ -d /run/systemd/system ]] || die '需要以 systemd 作为系统服务管理器。'
command -v systemd-detect-virt >/dev/null || die '缺少 systemd-detect-virt。'
if systemd-detect-virt --container >/dev/null 2>&1; then die '容器环境不能运行此系统初始化工具。'; fi
case "$(uname -m)" in x86_64|aarch64) ;; *) die '当前仅验证过 x86_64 和 aarch64。';; esac
for required in sha256sum stat install mktemp cmp ln rm rmdir cp mkdir chmod find sort flock; do
  command -v "$required" >/dev/null || die "缺少系统工具：$required。"
done

secure_dir() {
  local path="$1" owner mode
  [[ -d "$path" && ! -L "$path" ]] || die "安装目录不存在或是符号链接：$path"
  owner="$(stat -c '%u' -- "$path")"
  mode="$(stat -c '%a' -- "$path")"
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || die "安装目录归属或权限异常：$path"
  (( (8#$mode & 8#022) == 0 )) || die "安装目录可被其他用户写入：$path"
}

secure_file() {
  local path="$1" owner mode
  [[ -f "$path" && ! -L "$path" ]] || die "已有安装文件类型异常：$path"
  owner="$(stat -c '%u' -- "$path")"
  mode="$(stat -c '%a' -- "$path")"
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || die "已有安装文件归属或权限异常：$path"
  (( (8#$mode & 8#022) == 0 )) || die "已有安装文件可被其他用户写入：$path"
}

# What to do with an existing installation, from three SHA-256 values: reuse
# (this version), upgrade (an intact other version, or an interrupted upgrade
# to this one, whose script is already in place) or refuse (edited by hand).
install_existing_action() {
  local installed="$1" recorded="$2" expected="$3"
  [[ "$installed" =~ ^[0-9a-f]{64}$ && "$recorded" =~ ^[0-9a-f]{64}$ && "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo refuse; return 0; }
  if [[ "$installed" == "$expected" && "$recorded" == "$expected" ]]; then echo reuse
  elif [[ "$installed" == "$recorded" || "$installed" == "$expected" ]]; then echo upgrade
  else echo refuse; fi
}

# Staging files are published with ln/mv and cleaned on exit; only a power loss
# leaves them behind. Remove those (fixed mktemp names, owned by this user); a
# directory left with nothing else and no launcher is removed for a fresh install.
install_clean_staging() {
  local dir="$1" bindir="$2" stale
  for stale in "$dir"/.main.???????? "$dir"/.owner.???????? "$dir"/.sha256.???????? "$bindir"/.vps.????????; do
    [[ -f "$stale" && ! -L "$stale" && "$(stat -c '%u' -- "$stale")" == "$EUID" ]] || continue
    rm -f -- "$stale"
  done
  if [[ -d "$dir" && ! -L "$dir" && ! -e "$bindir/vps" && ! -L "$bindir/vps" ]]; then rmdir -- "$dir" 2>/dev/null || true; fi
}

for directory in / /usr /usr/local /usr/local/lib /usr/local/bin /var /var/lib; do secure_dir "$directory"; done
# Share the stable directory lock used by setup/rollback/uninstall. Acquiring
# it before publishing any file also prevents install/uninstall races.
exec 8</var/lib
flock -n -x 8 || die '另一个安装、优化、回退或卸载任务正在运行，请等它结束。'
# Never shadow another program named vps earlier/later in the normal root PATH.
for candidate in /usr/local/sbin/vps /usr/sbin/vps /usr/bin/vps /sbin/vps /bin/vps; do
  [[ ! -e "$candidate" && ! -L "$candidate" ]] || die "已有其他 vps 命令：$candidate，未安装或覆盖。"
done
TMP_DIR="$(mktemp -d /tmp/vps-stable-opt-install.XXXXXXXX)"
chmod 700 -- "$TMP_DIR"
payload="$TMP_DIR/payload.sh"

if [[ -n "$LOCAL_FILE" ]]; then
  [[ -f "$LOCAL_FILE" && ! -L "$LOCAL_FILE" ]] || die '本地主脚本必须是普通文件，不能是符号链接。'
  cp -- "$LOCAL_FILE" "$payload"
else
  BASE_URL="${BASE_URL%/}"
  [[ "$BASE_URL" != 'https://raw.githubusercontent.com/OWNER/REPO/main' ]] || die 'GitHub 仓库地址尚未配置；请填写真实 --base-url，或使用 --local-file。'
  [[ "$BASE_URL" == https://* && "$BASE_URL" != *[[:space:]]* && "$BASE_URL" != *'?'* && "$BASE_URL" != *'#'* ]] || die '下载目录必须是无空白、查询串和片段的 HTTPS 地址。'
  authority="${BASE_URL#https://}"; authority="${authority%%/*}"
  [[ -n "$authority" && "$authority" != *@* && "$authority" != -* ]] || die 'HTTPS 地址的主机部分无效。'
  download_url="$BASE_URL/$PAYLOAD_NAME"
  printf '正在下载经过固定校验值约束的主脚本……\n'
  if command -v curl >/dev/null; then
    curl --fail --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 120 --silent --show-error \
      --output "$payload" "$download_url"
  elif command -v wget >/dev/null && command -v timeout >/dev/null; then
    # No redirects: wget's --https-only alone does not constrain every redirect.
    timeout 120s wget --https-only --max-redirect=0 --timeout=15 --tries=2 \
      --no-verbose --output-document="$payload" "$download_url"
  else
    die '缺少 curl 或 wget；请先手动安装其中一个，安装器不会自动执行 apt。'
  fi
fi

actual_sha="$(sha256sum -- "$payload")"; actual_sha="${actual_sha%% *}"
[[ "$actual_sha" == "${EXPECTED_SHA256,,}" ]] || die '主脚本 SHA-256 校验失败；停止安装。'
bash -n -- "$payload"
printf '主脚本校验与 Bash 语法检查通过。\n'
cat > "$TMP_DIR/launcher" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if (( $# == 0 )); then set -- menu; fi
exec /bin/bash /usr/local/lib/vps-stable-opt/vps-stable-opt.sh "$@"
EOF
printf '%s\n' 'vps-stable-opt-installer:2.6' > "$TMP_DIR/marker"
printf '%s\n' "$EXPECTED_SHA256" > "$TMP_DIR/sha256"

if [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
  secure_dir "$INSTALL_DIR"
  install_clean_staging "$INSTALL_DIR" /usr/local/bin
fi
if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" || -e "$LAUNCHER_FILE" || -L "$LAUNCHER_FILE" ]]; then
  secure_dir "$INSTALL_DIR"
  for existing in "$MARKER_FILE" "$HASH_FILE" "$INSTALL_FILE" "$LAUNCHER_FILE"; do secure_file "$existing"; done
  cmp -s -- "$TMP_DIR/marker" "$MARKER_FILE" || die '已有目录不属于本安装器，未覆盖。'
  cmp -s -- "$TMP_DIR/launcher" "$LAUNCHER_FILE" || die '已有启动命令内容不同，未覆盖。'
  entries="$(find -P "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
  [[ "$entries" == $'.installed-sha256\n.installer-owner\nvps-stable-opt.sh' ]] || die '已有安装目录包含其他文件，未接管。'
  installed_sha="$(sha256sum -- "$INSTALL_FILE")"; installed_sha="${installed_sha%% *}"
  recorded_sha="$(cat -- "$HASH_FILE")"
  case "$(install_existing_action "$installed_sha" "$recorded_sha" "${EXPECTED_SHA256,,}")" in
    reuse) printf '已安装相同版本，直接复用。\n' ;;
    upgrade)
      printf '发现已安装的其他版本：原地替换主脚本；运行记录、配置备份和回退资料都保留。\n'
      MAIN_STAGE="$(mktemp "$INSTALL_DIR/.main.XXXXXXXX")"
      HASH_STAGE="$(mktemp "$INSTALL_DIR/.sha256.XXXXXXXX")"
      install -m 700 -- "$payload" "$MAIN_STAGE"
      install -m 600 -- "$TMP_DIR/sha256" "$HASH_STAGE"
      # Script first, then its hash: if this is interrupted, running the
      # installer again finds the new script in place and finishes the job.
      mv -fT -- "$MAIN_STAGE" "$INSTALL_FILE"; MAIN_STAGE=''
      mv -fT -- "$HASH_STAGE" "$HASH_FILE"; HASH_STAGE=''
      if ! cmp -s -- "$payload" "$INSTALL_FILE" || ! cmp -s -- "$TMP_DIR/sha256" "$HASH_FILE"; then
        die '替换后核对失败；请重新运行安装命令。'
      fi
      printf '已更新到这个版本。\n' ;;
    *) die '已安装的主脚本和它的校验记录对不上（可能被手动改过），未覆盖。请先检查 /usr/local/lib/vps-stable-opt/。' ;;
  esac
else
  mkdir -m 755 -- "$INSTALL_DIR"
  CREATED_DIR=1
  secure_dir "$INSTALL_DIR"
  # Each final file is published atomically with a hard link; ln refuses to replace.
  MAIN_STAGE="$(mktemp "$INSTALL_DIR/.main.XXXXXXXX")"
  MARKER_STAGE="$(mktemp "$INSTALL_DIR/.owner.XXXXXXXX")"
  HASH_STAGE="$(mktemp "$INSTALL_DIR/.sha256.XXXXXXXX")"
  LAUNCHER_STAGE="$(mktemp /usr/local/bin/.vps.XXXXXXXX)"
  install -m 700 -- "$payload" "$MAIN_STAGE"
  install -m 600 -- "$TMP_DIR/marker" "$MARKER_STAGE"
  install -m 600 -- "$TMP_DIR/sha256" "$HASH_STAGE"
  install -m 755 -- "$TMP_DIR/launcher" "$LAUNCHER_STAGE"
  ln -- "$MAIN_STAGE" "$INSTALL_FILE"; CREATED_MAIN=1
  ln -- "$MARKER_STAGE" "$MARKER_FILE"; CREATED_MARKER=1
  ln -- "$HASH_STAGE" "$HASH_FILE"; CREATED_HASH=1
  ln -- "$LAUNCHER_STAGE" "$LAUNCHER_FILE"; CREATED_LAUNCHER=1
  printf '菜单工具已安装：/usr/local/bin/vps\n'
fi

INSTALL_OK=1
printf '尚未执行任何系统优化。以后输入 vps 打开菜单；普通用户使用 sudo vps。\n'
if (( NO_RUN )); then exit 0; fi
# Clean transient files before exec; keep the caller's SSH terminal as standard input.
[[ -z "$MAIN_STAGE" ]] || rm -f -- "$MAIN_STAGE"
[[ -z "$MARKER_STAGE" ]] || rm -f -- "$MARKER_STAGE"
[[ -z "$HASH_STAGE" ]] || rm -f -- "$HASH_STAGE"
[[ -z "$LAUNCHER_STAGE" ]] || rm -f -- "$LAUNCHER_STAGE"
MAIN_STAGE=''; MARKER_STAGE=''; HASH_STAGE=''; LAUNCHER_STAGE=''
rm -f -- "$TMP_DIR/payload.sh" "$TMP_DIR/launcher" "$TMP_DIR/marker" "$TMP_DIR/sha256"
rmdir -- "$TMP_DIR"; TMP_DIR=''
# A persistent parent menu must never retain this lock: each chosen operation
# acquires its own lifecycle lock in a fresh Bash child.
flock -u 8
exec 8<&-
exec /bin/bash "$INSTALL_FILE" menu
