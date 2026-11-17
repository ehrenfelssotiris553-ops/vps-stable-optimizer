#!/usr/bin/env bash
# Files this tool shares with their owner: Docker's daemon.json (it merges two
# keys into it) and /etc/gai.conf (it appends two lines). Undoing takes only
# that part out again; what the owner wrote before or since stays. Up to 3.1.4
# the whole file came back as it was before the tool, so a data-root added to
# daemon.json later was gone after "undo the log limit". A file of the tool's
# own that was edited by hand is kept aside before the rollback replaces it.
# The whole script is sourced: these are its real functions.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
optimizer_sourceable || fail "this version of the script cannot be sourced whole: $TEST_SCRIPT"
# shellcheck source=/dev/null
source "$TEST_SCRIPT"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
say() { :; }
step() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { printf 'DIE %s\n' "$*" >> "$TEST_ROOT/log"; exit 1; }
module_result() { :; }
backup_config_path() { :; }
record_config_change() { :; }
PARAMS_FILE="$TEST_ROOT/no-params"

# A fresh machine for each case: an empty rollback record and no files yet.
fresh() {
  CASE="$TEST_ROOT/$1"
  STATE_ROOT="$CASE/state" RESTORE_ROOT="$CASE/state/restore-v2" RESTORE_READY=1 RESTORE_PARTIAL=0 RESTORE_STAGE=''
  mkdir -p "$RESTORE_ROOT" "$CASE/docker" "$CASE/etc"
  DOCKER_DAEMON_FILE="$CASE/docker/daemon.json" GAI_FILE="$CASE/etc/gai.conf" KEEPALIVE_FILE="$CASE/etc/keepalive.conf"
  : > "$TEST_ROOT/log"
}
# STAGE COMMAND...: COMMAND as a stage of the tool runs it, with the rollback
# record taken before and after.
as_stage() {
  local stage="$1"
  shift
  restore_before_stage "$stage" || fail "$stage: no rollback record"
  "$@"
  restore_after_stage "$stage" || fail "$stage: the result was not recorded"
}
# FILE KEY: the value of a top-level key of a JSON file ("-" when it is not there).
json_value() {
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d[sys.argv[2]], sort_keys=True) if sys.argv[2] in d else "-")' "$1" "$2"
}
undo() {
  restore_group_pending "$1" || fail "$1: nothing to undo although the tool's part is in the file"
  restore_group_apply "$1" > "$CASE/undo.out" 2>&1
  ((RESTORE_PARTIAL == 0)) || fail "$1: the rollback was left partial: $(cat "$CASE/undo.out" "$TEST_ROOT/log")"
  if restore_group_pending "$1"; then fail "$1: still listed as to be undone afterwards"; fi
}
active() { return 1; }

if command -v python3 > /dev/null && python3 -c 1 > /dev/null 2>&1; then
  # The owner's daemon.json, the tool's log limits merged in, a setting added
  # by the owner later: undoing the log limits keeps both of the owner's.
  fresh docker-added
  printf '{\n  "registry-mirrors": ["https://mirror.example"]\n}\n' > "$DOCKER_DAEMON_FILE"
  cp -- "$DOCKER_DAEMON_FILE" "$CASE/before"
  as_stage dockerlog dockerlog_merge
  [[ "$(json_value "$DOCKER_DAEMON_FILE" log-driver)" == '"json-file"' ]] || fail 'the log limits were not merged in'
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["data-root"] = "/data/docker"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$DOCKER_DAEMON_FILE"
  undo dockerlog
  [[ "$(json_value "$DOCKER_DAEMON_FILE" data-root)" == '"/data/docker"' ]] || fail "undoing the log limits lost what the owner added later: $(cat "$DOCKER_DAEMON_FILE")"
  [[ "$(json_value "$DOCKER_DAEMON_FILE" registry-mirrors)" == '["https://mirror.example"]' ]] || fail "undoing the log limits lost what was there before: $(cat "$DOCKER_DAEMON_FILE")"
  [[ "$(json_value "$DOCKER_DAEMON_FILE" log-driver)$(json_value "$DOCKER_DAEMON_FILE" log-opts)" == '--' ]] || fail "the tool's log settings stayed: $(cat "$DOCKER_DAEMON_FILE")"
  grep -Fq '只拿掉了本工具写的那部分' "$CASE/undo.out" || fail "the user is not told that only the tool's part went: $(cat "$CASE/undo.out")"
  [[ "$(restore_read dockerlog_file state)" == restored ]] || fail "state after the undo: $(restore_read dockerlog_file state)"
  # Log settings of the owner's own, written after that, are no longer the tool's.
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["log-opts"] = {"max-size": "1g"}
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$DOCKER_DAEMON_FILE"
  if restore_group_pending dockerlog; then fail "log settings the owner wrote after the undo are listed as the tool's"; fi

  # Untouched since the tool wrote it: the file from before comes back whole.
  fresh docker-untouched
  printf '{ "registry-mirrors" : ["https://mirror.example"] }\n' > "$DOCKER_DAEMON_FILE"
  cp -- "$DOCKER_DAEMON_FILE" "$CASE/before"
  as_stage dockerlog dockerlog_merge
  undo dockerlog
  cmp -s "$CASE/before" "$DOCKER_DAEMON_FILE" || fail "an untouched daemon.json did not come back byte for byte: $(cat "$DOCKER_DAEMON_FILE")"
  [[ ! -d "$RESTORE_ROOT/replaced" ]] || fail 'a copy was kept although nothing had changed'

  # The owner changed the tool's own keys: what is theirs now stays.
  fresh docker-changed
  printf '{"registry-mirrors": []}\n' > "$DOCKER_DAEMON_FILE"
  as_stage dockerlog dockerlog_merge
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["log-driver"] = "local"; d["log-opts"]["compress"] = "true"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$DOCKER_DAEMON_FILE"
  undo dockerlog
  [[ "$(json_value "$DOCKER_DAEMON_FILE" log-driver)" == '"local"' ]] || fail "a log driver the owner chose was removed: $(cat "$DOCKER_DAEMON_FILE")"
  [[ "$(json_value "$DOCKER_DAEMON_FILE" log-opts)" == '{"compress": "true"}' ]] || fail "the owner's own log option went, or the tool's stayed: $(cat "$DOCKER_DAEMON_FILE")"

  # No daemon.json before the tool: its own file goes when nothing else is in
  # it, and stays with what the owner added.
  fresh docker-created
  as_stage dockerlog dockerlog_merge
  [[ -f "$DOCKER_DAEMON_FILE" ]] || fail 'the tool did not create daemon.json'
  undo dockerlog
  [[ ! -e "$DOCKER_DAEMON_FILE" ]] || fail "the tool's own daemon.json stayed: $(cat "$DOCKER_DAEMON_FILE")"
  fresh docker-created-added
  as_stage dockerlog dockerlog_merge
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["ipv6"] = True
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$DOCKER_DAEMON_FILE"
  undo dockerlog
  [[ "$(json_value "$DOCKER_DAEMON_FILE" ipv6)" == true && "$(json_value "$DOCKER_DAEMON_FILE" log-opts)" == - ]] ||
    fail "a daemon.json the tool created, with a setting added: $(cat "$DOCKER_DAEMON_FILE" 2>&1)"
  fresh docker-created-emptied
  as_stage dockerlog dockerlog_merge
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["ipv6"] = True
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$DOCKER_DAEMON_FILE"
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); del d["ipv6"]
json.dump(d, open(sys.argv[1], "w"), indent=4)' "$DOCKER_DAEMON_FILE"
  undo dockerlog
  [[ ! -e "$DOCKER_DAEMON_FILE" ]] || fail "a rewritten daemon.json with only the tool's settings stayed as: $(cat "$DOCKER_DAEMON_FILE")"

  # A file that is no JSON any more is left alone, and the rollback says so.
  fresh docker-broken
  printf '{"registry-mirrors": []}\n' > "$DOCKER_DAEMON_FILE"
  as_stage dockerlog dockerlog_merge
  printf '{"log-opts": {"max-size": "20m"}, broken\n' > "$DOCKER_DAEMON_FILE"
  cp -- "$DOCKER_DAEMON_FILE" "$CASE/broken"
  restore_group_apply dockerlog > "$CASE/undo.out" 2>&1
  ((RESTORE_PARTIAL == 1)) || fail 'a daemon.json that could not be read was reported as undone'
  cmp -s "$CASE/broken" "$DOCKER_DAEMON_FILE" || fail 'a daemon.json that could not be read was changed'
  printf 'PASS: undoing the Docker log limit takes only its two settings out of daemon.json.\n'
else
  printf 'SKIP: no python3 here: the daemon.json cases need it (the tool itself refuses to touch the file without it).\n'
fi

# /etc/gai.conf with the distribution's comments, the tool's two lines
# appended by its stage, a line added by the owner later: only the two go.
fresh gai-added
printf '# Configuration for getaddrinfo(3).\n#\n#precedence ::ffff:0:0/96  10\n' > "$GAI_FILE"
cp -- "$GAI_FILE" "$CASE/before"
IPV4_CHOICE=1
as_stage ipv4 ipv4_stage
grep -Fxq -- "$(gai_prefer_line)" "$GAI_FILE" || fail "the stage did not write its line: $(cat "$GAI_FILE")"
printf 'label 2002::/16 2\n' >> "$GAI_FILE"
undo ipv4
[[ "$(cat "$GAI_FILE")" == "$(cat "$CASE/before")"$'\n''label 2002::/16 2' ]] || fail "gai.conf after the undo: $(cat "$GAI_FILE")"
grep -Fq '只拿掉了本工具写的那部分' "$CASE/undo.out" || fail "the user is not told that only the tool's lines went: $(cat "$CASE/undo.out")"
# Untouched: byte for byte as before.
fresh gai-untouched
printf '# Configuration for getaddrinfo(3).\n' > "$GAI_FILE"
cp -- "$GAI_FILE" "$CASE/before"
as_stage ipv4 ipv4_stage
undo ipv4
cmp -s "$CASE/before" "$GAI_FILE" || fail "an untouched gai.conf did not come back as it was: $(cat "$GAI_FILE")"
# None before the tool: its own file goes, unless the owner wrote into it.
fresh gai-created
as_stage ipv4 ipv4_stage
[[ -f "$GAI_FILE" ]] || fail 'the stage did not create gai.conf'
undo ipv4
[[ ! -e "$GAI_FILE" ]] || fail "the tool's own gai.conf stayed: $(cat "$GAI_FILE")"
fresh gai-created-added
as_stage ipv4 ipv4_stage
printf 'label 2002::/16 2\n' >> "$GAI_FILE"
undo ipv4
[[ "$(cat "$GAI_FILE")" == 'label 2002::/16 2' ]] || fail "a gai.conf the tool created, with a line added: $(cat "$GAI_FILE" 2>&1)"
printf 'PASS: undoing "prefer IPv4" takes only its two lines out of gai.conf.\n'

# A file of the tool's own, edited by hand since: the rollback still puts the
# state from before the tool back (the agreed rule), but what was there is
# kept aside first and the user is told where.
fresh own-edited
ssh_reload() { :; }
write_keepalive() { printf 'ClientAliveInterval 60\n' > "$KEEPALIVE_FILE"; }
as_stage keepalive write_keepalive
printf 'ClientAliveInterval 60\nClientAliveCountMax 9\n' > "$KEEPALIVE_FILE"
undo keepalive
[[ ! -e "$KEEPALIVE_FILE" ]] || fail 'the edited file of the tool was not removed by the rollback'
kept=("$RESTORE_ROOT"/replaced/keepalive_file.*)
[[ -f "${kept[0]}" && "$(cat "${kept[0]}")" == $'ClientAliveInterval 60\nClientAliveCountMax 9' ]] || fail "what was in the edited file was not kept: ${kept[*]}"
grep -Fq "${kept[0]}" "$CASE/undo.out" || fail "the user is not told where the edited file was kept: $(cat "$CASE/undo.out")"
# Not edited: nothing to keep.
fresh own-untouched
as_stage keepalive write_keepalive
undo keepalive
[[ ! -e "$KEEPALIVE_FILE" && ! -d "$RESTORE_ROOT/replaced" ]] || fail 'a copy was kept of a file nobody had edited'
printf 'PASS: a file changed since the tool wrote it is kept aside before the rollback replaces it.\n'
