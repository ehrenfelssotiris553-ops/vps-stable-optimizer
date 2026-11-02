#!/usr/bin/env bash
# CI only: helpers shared by the real runs (layers 2 and 3).
# Sourced after ROOT is set; LOGS is where every transcript is kept.
CI="$ROOT/tests/ci"
LOGS="${CI_LOGS:-${RUNNER_TEMP:-/tmp}/vps-ci-logs}"
mkdir -p -- "$LOGS"

fail() { printf '::error::%s\n' "$*"; exit 1; }
# A notice annotation with the first 40 lines of FILE: GitHub shows
# annotations without signing in, unlike the logs.
notice() {
  local text
  text="$(head -n 40 -- "$2" | sed -e ':a' -e 'N' -e '$!ba' -e 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
  printf '::notice title=%s::%s\n' "$1" "$text"
}
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }

# Answers one interactive command with a rules file; the readable transcript
# (colours and carriage returns removed) lands in $LOGS/NAME.log.
drive() {
  local rules="$1" name="$2" rc=0
  shift 2
  # A name from tests/ci/rules/, or a path (rules written for one run).
  [[ "$rules" == /* ]] || rules="$CI/rules/$rules"
  LANG=C.UTF-8 TERM=xterm expect "$CI/answer.exp" "$rules" "$LOGS/$name.raw" "$@" || rc=$?
  sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Za-z0-9]//g; s/\r//g' "$LOGS/$name.raw" > "$LOGS/$name.log"
  return "$rc"
}

has() { grep -Fq -- "$2" "$LOGS/$1.log" || fail "$1: \"$2\" is missing"; }

# Facts the tool reports, against the machine itself. on_target CMD (defined
# by each run script) runs CMD as root where the tool runs.
# Two whole numbers at most 1 apart (rounding differs between tools).
near() { [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] && (($1 - $2 <= 1 && $2 - $1 <= 1)); }
# The health report's first line: kernel, virtualization, memory, system disk.
plan_facts() {
  local header kernel virt mem disk real_kernel real_virt real_mem real_disk
  header="$(grep -m1 '^系统：' "$LOGS/$1.log")" || fail "$1: no system line"
  kernel="$(sed -n 's/.*| 内核：\([^ |]*\) |.*/\1/p' <<< "$header")"
  virt="$(sed -n 's/.*| 虚拟化：\([^ |]*\) |.*/\1/p' <<< "$header")"
  mem="$(sed -n 's/.*| 内存：\([0-9]*\) MiB.*/\1/p' <<< "$header")"
  disk="$(sed -n 's/.*| 系统盘：\([0-9]*\) GiB.*/\1/p' <<< "$header")"
  # The $2 belong to awk on the target.
  # shellcheck disable=SC2016
  { read -r real_kernel; read -r real_virt; read -r real_mem; read -r real_disk; } < <(on_target \
    'uname -r; systemd-detect-virt || true; free -m | awk "/^Mem:/ {print \$2}"; df -P -B1G / | awk "NR == 2 {print \$2}"')
  [[ "$kernel" == "$real_kernel" ]] || fail "$1: kernel $kernel, really $real_kernel"
  [[ "$virt" == "${real_virt:-none}" ]] || fail "$1: virtualization $virt, really $real_virt"
  near "${mem:-0}" "$real_mem" || fail "$1: memory $mem MiB, really $real_mem MiB"
  near "${disk:-0}" "$real_disk" || fail "$1: system disk $disk GiB, really $real_disk GiB"
}
# The SSH port the firewall step confirmed, and what it says about password
# login, against sshd itself.
ssh_facts() {
  local said real password
  said="$(sed -n 's/^已确认 SSH 端口：//p' "$LOGS/$1.log" | head -n 1)"
  real="$(on_target "sshd -T 2>/dev/null | awk '\$1 == \"port\" {print \$2}' | sort -n | tr '\n' ' '")"
  [[ "$said " == "$real" ]] || fail "$1: SSH ports confirmed as '$said', sshd uses '$real'"
  password="$(on_target "sshd -T 2>/dev/null | awk '\$1 == \"passwordauthentication\" {print \$2}'")"
  if [[ "$password" == yes ]]; then has "$1" 'SSH 仍允许密码登录'; else has "$1" 'SSH 已关闭密码登录'; fi
}
# Acceptance check lines that state a fact: UFW's IPv6 setting, the host name.
check_facts() {
  local ipv6 host
  ipv6="$(on_target "sed -n 's/^IPV6=//p' /etc/default/ufw")"
  grep -Fq "IPv6 管理：$ipv6" "$LOGS/$1.log" || fail "$1: UFW IPv6 is $ipv6, the check says otherwise"
  host="$(on_target 'hostname')"
  if on_target "getent hosts \"\$(hostname)\" >/dev/null"; then has "$1" "主机名 $host 可以正常解析"; fi
}

# The newest commit on origin/main whose tool has another version than
# VERSION, printed as "COMMIT VERSION" (needs the git history).
previous_release() {
  local commit other
  git -C "$ROOT" fetch -q --no-tags origin main 2>/dev/null || true
  for commit in $(git -C "$ROOT" rev-list origin/main -- vps-stable-opt.sh); do
    other="$(git -C "$ROOT" show "$commit:vps-stable-opt.sh" | sed -n 's/^SCRIPT_VERSION=//p' || true)"
    if [[ -n "$other" && "$other" != "$1" ]]; then printf '%s %s\n' "$commit" "$other"; return 0; fi
  done
  return 1
}

# The menu number of single item KEY, from the tool's own list (item_keys).
item_index() {
  awk -v key="$1" '
    /^item_keys\(\) \{/ {list = 1; next}
    list && /printf/ {for (i = 3; i <= NF; i++) if ($i == key) {print i - 2; found = 1}; exit}
    END {exit !found}
  ' "$ROOT/vps-stable-opt.sh"
}
lacks() { if grep -Fq -- "$2" "$LOGS/$1.log"; then fail "$1: \"$2\" should not be there"; fi; }

# The tool's error trap ("出错：第 N 行") in any transcript or saved output is
# never part of a healthy run, also where the run went on: a pipeline failing
# in a process substitution printed it three times in vps audit on a real
# Debian 13 VPS, and no check looked for it. NAME... are runs where it may
# appear on purpose (Ctrl+C in the middle of a setup).
no_tool_errors() {
  local f name skip hits=''
  for f in "$LOGS"/*.log; do
    [[ -f "$f" ]] || continue
    skip=0
    for name in "$@"; do if [[ "${f##*/}" == "$name.log" ]]; then skip=1; fi; done
    if ((skip == 0)) && grep -Eq '出错：第 [0-9]+ 行' "$f"; then hits+=" ${f##*/}: $(grep -Em1 '出错：第 [0-9]+ 行' "$f")"; fi
  done
  [[ -z "$hits" ]] || fail "the tool hit its error trap:$hits"
}

# An acceptance line "✔ 生效  LABEL：…" (or "✔ 正常" for health lines).
passed() {
  grep -Eq "^✔ (生效|正常)[[:space:]]+$2：" "$LOGS/$1.log" || {
    grep -E "^[^[:space:]]+ [^[:space:]]+[[:space:]]+$2：" "$LOGS/$1.log" | head -n 3 >&2 || true
    fail "$1: \"$2\" did not pass"
  }
}
