#!/usr/bin/env bash
# CI only: helpers shared by the real runs (layers 2 and 3).
# Sourced after ROOT is set; LOGS is where every transcript is kept.
CI="$ROOT/tests/ci"
LOGS="${CI_LOGS:-${RUNNER_TEMP:-/tmp}/vps-ci-logs}"
mkdir -p -- "$LOGS"

fail() { printf '::error::%s\n' "$*"; exit 1; }
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }

# Answers one interactive command with a rules file; the readable transcript
# (colours and carriage returns removed) lands in $LOGS/NAME.log.
drive() {
  local rules="$1" name="$2" rc=0
  shift 2
  LANG=C.UTF-8 TERM=xterm expect "$CI/answer.exp" "$CI/rules/$rules" "$LOGS/$name.raw" "$@" || rc=$?
  sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Za-z0-9]//g; s/\r//g' "$LOGS/$name.raw" > "$LOGS/$name.log"
  return "$rc"
}

has() { grep -Fq -- "$2" "$LOGS/$1.log" || fail "$1: \"$2\" is missing"; }
lacks() { if grep -Fq -- "$2" "$LOGS/$1.log"; then fail "$1: \"$2\" should not be there"; fi; }

# An acceptance line "[✅ 生效]   LABEL：…" (or "✅ 正常" for health lines).
passed() {
  grep -Eq "\[✅ (生效|正常)\][[:space:]]+$2：" "$LOGS/$1.log" || {
    grep -E "^\[.*\][[:space:]]+$2：" "$LOGS/$1.log" | head -n 3 >&2 || true
    fail "$1: \"$2\" did not pass"
  }
}
