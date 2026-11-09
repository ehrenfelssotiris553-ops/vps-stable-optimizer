#!/usr/bin/env bash
# Published Docker ports behind the firewall: which ports count as published,
# what UFW lets in, the nftables text that comes of it, when it is loaded, and
# the stage with its way back. Docker, UFW, nft and systemd are stand-ins here;
# tests/ci/docker-run.sh checks the real thing from outside the machine.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions record_line_remove dockerfw_settle dockerfw_ufw_state dockerfw_on dockerfw_unsupported dockerfw_published dockerfw_rules dockerfw_open dockerfw_text dockerfw_load dockerfw_sync dockerfw_off \
  dockerfw_rules_undo dockerfw_show dockerfw_stage check_dockerfw docker_firewall_note dockerfw_service_text dockerfw_path_text port_rule_parse nft_ruleset_has_policy \
  ufw_active restore_ids restore_group_ids restore_groups restore_dockerfw_group item_keys item_label
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
STATE_ROOT="$TEST_ROOT/state" RESTORE_ROOT="$TEST_ROOT/restore" CALLS="$TEST_ROOT/calls"
mkdir -p -- "$STATE_ROOT" "$RESTORE_ROOT"
DOCKER_FW_PATH_FILE="$TEST_ROOT/fw.path" DOCKER_FW_SERVICE_FILE="$TEST_ROOT/fw.service" DOCKER_DAEMON_FILE="$TEST_ROOT/daemon.json"
: > "$CALLS"
record() { printf '%s\n' "$*" >> "$CALLS"; }
called() { grep -Fxq -- "$1" "$CALLS"; }

# What the stand-ins answer; each section sets what it needs.
DOCKER_PS='' DOCKER_SWARM=inactive UFW_STATE=active BRIDGES='' PATH_ENABLED=1
UFW_ADDED="Added user rules (see 'ufw status' for running firewall):"
docker() {
  case "$1" in
    ps) if [[ -n "$DOCKER_PS" ]]; then printf '%s\n' "$DOCKER_PS"; fi ;;
    info) printf '%s\n' "$DOCKER_SWARM" ;;
  esac
}
ufw() {
  case "$1 ${2:-}" in
    'show added') printf '%s\n' "$UFW_ADDED" ;;
    'status '*) printf 'Status: %s\n' "$UFW_STATE" ;;
    '--force delete') record "ufw $*" ;;
  esac
}
ip() { if [[ -n "$BRIDGES" ]]; then printf '%s\n' "$BRIDGES"; fi; }
nft() {
  record "nft $*"
  if [[ "$1" == -c ]]; then return "${NFT_CHECK_RC:-0}"; fi
  if [[ "$1" == list ]]; then return "${NFT_LIST_RC:-0}"; fi
  return "${NFT_RC:-0}"
}
systemctl() {
  record "systemctl $*"
  case "$1 ${2:-}" in
    'is-enabled -q') ((PATH_ENABLED)) ;;
    *) return 0 ;;
  esac
}

# 1. Which ports are published to the outside.
DOCKER_PS=$'web\t0.0.0.0:8081->80/tcp, :::8081->80/tcp
db\t127.0.0.1:5432->5432/tcp
db6\t[::1]:5433->5432/tcp
range\t0.0.0.0:8000-8010->8000-8010/tcp
dns\t0.0.0.0:53->53/udp, 0.0.0.0:53->53/tcp
internal\t6379/tcp
bound\t203.0.113.9:8443->443/tcp
none\t'
expected=$'53/tcp\tdns\n53/udp\tdns\n8000-8010/tcp\trange\n8081/tcp\tweb\n8443/tcp\tbound'
[[ "$(dockerfw_published | LC_ALL=C sort -u)" == "$expected" ]] || fail "published ports: $(dockerfw_published | LC_ALL=C sort -u)"
printf 'PASS: the ports containers publish are read; those bound to this machine only and those not published do not count.\n'

# 2. What UFW lets in.
UFW_ADDED="Added user rules (see 'ufw status' for running firewall):
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443
ufw allow 8000:8100/tcp
ufw allow from 203.0.113.5 to any port 3306 proto tcp
ufw allow from 2001:db8::5 to any port 5432 proto tcp
ufw deny 23/tcp
ufw route allow 9000/tcp"
for case in '80 tcp yes' '80 udp no' '443 tcp yes' '443 udp yes' '8050 tcp yes' '8050-8060 tcp yes' '8000-8100 tcp yes' '8090-8200 tcp no' '7999 tcp no' '3306 tcp no' '5432 tcp no' '23 tcp no' '9000 tcp no'; do
  read -r port proto want <<< "$case"
  if dockerfw_open "$port" "$proto"; then got=yes; else got=no; fi
  [[ "$got" == "$want" ]] || fail "port $port/$proto open: $got, should be $want"
done
printf 'PASS: a port counts as open only when UFW lets everyone in on all of it.\n'

# 3. The rules: UFW's list, as seen from outside; only this tool's own table.
text="$(dockerfw_text)"
mapfile -t lines <<< "$text"
[[ "${lines[0]} | ${lines[1]} | ${lines[2]}" == 'add table inet vps-stable-docker | delete table inet vps-stable-docker | table inet vps-stable-docker {' ]] || fail "table replaced how: ${lines[*]:0:3}"
[[ "$(grep -c '^table \|^add table \|^delete table ' <<< "$text")" == 3 ]] || fail 'another table is touched'
grep -Fq 'set open_tcp { type inet_service; flags interval; auto-merge; elements = { 22, 80, 443, 8000-8100 }; }' <<< "$text" || fail "TCP set: $text"
grep -Fq 'set open_udp { type inet_service; flags interval; auto-merge; elements = { 443 }; }' <<< "$text" || fail "UDP set: $text"
grep -Fq 'type filter hook forward priority -1; policy accept;' <<< "$text" || fail 'must run before the filter chains of UFW and Docker'
grep -Fq 'ct state new ct status dnat jump published' <<< "$text" || fail 'only new connections that were published may be looked at'
grep -Fq 'ip saddr 203.0.113.5 meta l4proto tcp ct original proto-dst 3306 return' <<< "$text" || fail 'IPv4 source rule'
grep -Fq 'ip6 saddr 2001:db8::5 meta l4proto tcp ct original proto-dst 5432 return' <<< "$text" || fail 'IPv6 source rule'
grep -Fq 'meta l4proto tcp ct original proto-dst @open_tcp return' <<< "$text" || fail 'the port must be the one seen from outside'
[[ "$(grep -n 'drop$' <<< "$text" | cut -d: -f1)" -gt "$(grep -n 'proto-dst 5432 return' <<< "$text" | cut -d: -f1)" ]] || fail 'the drop must come last'
if grep -Eq 'proto-dst (23|9000)|[ ,]23,|[ ,]9000,' <<< "$text"; then fail "denied or routed rules let in: $text"; fi
# Containers reaching a published port through the host are not from outside.
for name in docker0 docker_gwbridge 'br-*'; do grep -Fq "iifname \"$name\" return" <<< "$text" || fail "bridge $name not let through"; done
BRIDGES=$'3: docker0: <BROADCAST> mtu 1500\n7: lxdbr0: <BROADCAST> mtu 1500\n8: br-abc123: <UP> mtu 1500\n9: we;ird: <UP> mtu 1500'
text="$(dockerfw_text)"
grep -Fq 'iifname "lxdbr0" return' <<< "$text" || fail 'a bridge of another name not let through'
[[ "$(grep -c 'iifname "docker0"' <<< "$text")" == 1 ]] || fail 'docker0 twice'
if grep -Fq 'we;ird' <<< "$text"; then fail 'an interface name that is not safe in the rules went in'; fi
BRIDGES=''
saved="$UFW_ADDED" UFW_ADDED="Added user rules (see 'ufw status' for running firewall):"
text="$(dockerfw_text)"
if grep -Fq 'elements' <<< "$text"; then fail "no rules, yet elements: $text"; fi
grep -Fq 'set open_tcp { type inet_service; flags interval; auto-merge; }' <<< "$text" || fail "empty set: $text"
UFW_ADDED="$saved"
printf 'PASS: the rules are what UFW allows, as seen from outside, in a table of their own.\n'

# 4. When they are loaded.
: > "$DOCKER_FW_PATH_FILE"
(
  PATH_ENABLED=0
  dockerfw_sync
  if grep -q '^nft ' "$CALLS"; then fail 'loaded with the switch off'; fi
  [[ ! -e "$STATE_ROOT/docker-fw.nft" ]] || fail 'rules written with the switch off'
)
(
  dockerfw_sync
  called "nft -c -f $(ls -d "$STATE_ROOT"/.docker-fw.* 2>/dev/null || true)" || grep -q '^nft -c -f ' "$CALLS" || fail 'not checked before loading'
  called "nft -f $STATE_ROOT/docker-fw.nft" || fail "not loaded: $(cat "$CALLS")"
  grep -Fq 'table inet vps-stable-docker {' "$STATE_ROOT/docker-fw.nft" || fail 'rules file empty'
)
: > "$CALLS"
(
  # Rules that do not check out: what is in place stays.
  printf 'old rules\n' > "$STATE_ROOT/docker-fw.nft"
  NFT_CHECK_RC=1
  if dockerfw_sync 2> /dev/null; then fail 'bad rules reported as loaded'; fi
  if called "nft -f $STATE_ROOT/docker-fw.nft"; then fail 'bad rules loaded'; fi
  [[ "$(cat "$STATE_ROOT/docker-fw.nft")" == 'old rules' ]] || fail 'the working rules were replaced by bad ones'
  [[ -z "$(ls -A "$STATE_ROOT" | grep '^\.docker-fw')" ]] || fail 'temporary file left'
)
: > "$CALLS"
(
  # The firewall off: there is no list of what is open, so nothing is held back.
  UFW_STATE=inactive
  dockerfw_sync
  called 'nft delete table inet vps-stable-docker' || fail 'table kept with the firewall off'
  if grep -q '^nft -f' "$CALLS"; then fail 'loaded with the firewall off'; fi
)
: > "$CALLS"
(
  # A rule added while this runs (found reading systemd's path units: a change
  # during the run does not start it again).
  # (Runs in a $(...): the count has to live in a file.)
  dockerfw_ufw_state() { local n; printf 'x' >> "$TEST_ROOT/looks"; n="$(wc -c < "$TEST_ROOT/looks")"; if ((n < 3)); then echo "state $n"; else echo stable; fi; }
  dockerfw_load() { record load; }
  dockerfw_sync
  [[ "$(grep -c '^load$' "$CALLS")" == 3 ]] || fail "rules changing during a run: loaded $(grep -c '^load$' "$CALLS") times, should be 3"
)
: > "$CALLS"
(
  dockerfw_ufw_state() { echo same; }
  dockerfw_load() { record load; }
  dockerfw_sync
  [[ "$(grep -c '^load$' "$CALLS")" == 1 ]] || fail 'rules not changing: must load once'
)
: > "$CALLS"
(
  # Never ends only if UFW never stops changing: it gives up by itself.
  : > "$TEST_ROOT/looks"
  dockerfw_ufw_state() { printf 'x' >> "$TEST_ROOT/looks"; wc -c < "$TEST_ROOT/looks"; }
  dockerfw_load() { record load; }
  dockerfw_sync
  (($(grep -c '^load$' "$CALLS") <= 20)) || fail 'keeps looping'
)
: > "$CALLS"
printf 'PASS: rules are loaded only with the switch on and the firewall on, checked first, and again when UFW changes meanwhile.\n'

# 5. Where it is not offered.
active() { [[ "$1" == docker && "${DOCKER_ACTIVE:-1}" == 1 ]]; }
docker_present() { [[ "${DOCKER_THERE:-1}" == 1 ]]; }
[[ -z "$(dockerfw_unsupported)" ]] || fail "refused on a machine that can have it: $(dockerfw_unsupported)"
(DOCKER_THERE=0; [[ "$(dockerfw_unsupported)" == *'没有在运行 Docker'* ]] || fail 'no Docker')
(DOCKER_ACTIVE=0; [[ "$(dockerfw_unsupported)" == *'没有在运行 Docker'* ]] || fail 'Docker stopped')
(DOCKER_SWARM=active; [[ "$(dockerfw_unsupported)" == *Swarm* ]] || fail 'Swarm')
(UFW_STATE=inactive; [[ "$(dockerfw_unsupported)" == *'先开启防火墙'* ]] || fail 'firewall off')
(printf '{ "firewall-backend": "nftables" }\n' > "$DOCKER_DAEMON_FILE"; [[ "$(dockerfw_unsupported)" == *nftables* ]] || fail "Docker's nftables backend"; rm -f -- "$DOCKER_DAEMON_FILE")
printf 'PASS: not offered where it could not work or was never tested.\n'

# 6. The stage.
say() { :; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*"; }
module_result() { RESULT="$1 $2"; record "module $1 $2"; }
guard_leftovers() { return 1; }
install_pkgs() { record "install $*"; }
ufw_rule() { record "ufw_rule $*"; }
check_file_write() { record "write $1"; printf '%s\n' "$3" > "$2"; }
guard_arm() { record "guard_arm $1"; return "${GUARD_ARM_RC:-0}"; }
guard_confirm() { record guard_confirm; return "${GUARD_CONFIRM_RC:-0}"; }
confirm_default_yes() { record "ask $1"; return "${ANSWER_RC:-0}"; }
stage() { : > "$CALLS"; rm -f -- "$RESTORE_ROOT/dockerfw_rules" "$RESTORE_ROOT/fw_rules" "$DOCKER_FW_PATH_FILE"; DOCKERFW_CHOICE=1; dockerfw_stage > "$TEST_ROOT/out"; }
DOCKER_PS=$'web\t0.0.0.0:6081->80/tcp\nrange\t0.0.0.0:7000-7010->7000-7010/tcp\nsite\t0.0.0.0:80->80/tcp'

(
  DOCKERFW_CHOICE=''
  dockerfw_stage > /dev/null
  [[ "$RESULT" == 'dockerfw declined' ]] || fail "not chosen: $RESULT"
  if grep -q 'write\|nft\|ufw_rule' "$CALLS"; then fail 'something changed although it was not chosen'; fi
)
(
  UFW_STATE=inactive
  stage
  [[ "$RESULT" == 'dockerfw unsupported' ]] || fail "unsupported: $RESULT"
  if grep -q 'write\|ufw_rule\|guard_arm' "$CALLS"; then fail 'something changed where it cannot work'; fi
)
(
  stage
  [[ "$RESULT" == 'dockerfw applied' ]] || fail "applied: $RESULT $(cat "$TEST_ROOT/out")"
  called 'ufw_rule allow 6081 tcp' || fail 'running port not kept open'
  called 'ufw_rule allow 7000:7010 tcp' || fail 'range not kept open (UFW writes it with a colon)'
  if called 'ufw_rule allow 80 tcp'; then fail 'a port already allowed added again'; fi
  # 6081 and the range are this tool's to take back; 80 was the user's already.
  [[ "$(LC_ALL=C sort "$RESTORE_ROOT/dockerfw_rules")" == $'ufw allow 6081/tcp\nufw allow 7000:7010/tcp' ]] || fail "recorded: $(cat "$RESTORE_ROOT/dockerfw_rules")"
  called 'write dockerfw_service' && called 'write dockerfw_path' || fail 'units not written'
  called 'systemctl enable vps-stable-docker-fw.service' || fail 'service not enabled'
  called 'systemctl enable --now vps-stable-docker-fw.path' || fail 'path unit not on'
  # The way back is armed before the rules can lock anyone out.
  [[ "$(grep -n '^guard_arm ' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^nft -f ' "$CALLS" | cut -d: -f1)" ]] || fail "guard after the rules: $(cat "$CALLS")"
  called guard_confirm || fail 'not confirmed by the user'
  if called 'nft delete table inet vps-stable-docker'; then fail 'table removed after a confirmed start'; fi
)
(
  # "No": those ports close, the rest still happens.
  ANSWER_RC=1
  stage
  if grep -q '^ufw_rule ' "$CALLS"; then fail 'ports opened after the answer no'; fi
  [[ ! -s "$RESTORE_ROOT/dockerfw_rules" ]] || fail 'rules recorded after the answer no'
  [[ "$RESULT" == 'dockerfw applied' ]] || fail "answer no: $RESULT"
)
(
  # Every published port already allowed: nothing is asked.
  UFW_ADDED="Added user rules (see 'ufw status' for running firewall):
ufw allow 80/tcp
ufw allow 7000:7010/tcp
ufw allow 6081/tcp"
  stage
  if grep -q '^ask ' "$CALLS"; then fail 'asked with nothing to ask'; fi
)
(
  GUARD_ARM_RC=1
  stage
  [[ "$RESULT" == 'dockerfw failed' ]] || fail "no guard: $RESULT"
  if grep -q '^nft -f ' "$CALLS"; then fail 'rules loaded without a way back'; fi
  called 'nft delete table inet vps-stable-docker' || fail 'not taken back'
)
(
  # No "CONNECTED" in time: everything as before, the rules it added included.
  GUARD_CONFIRM_RC=1
  printf 'ufw allow 22/tcp\nufw allow 6081/tcp\nufw allow 7000:7010/tcp\n' > "$RESTORE_ROOT/fw_rules.seed"
  stage_and_keep() { : > "$CALLS"; rm -f -- "$RESTORE_ROOT/dockerfw_rules"; cp -- "$RESTORE_ROOT/fw_rules.seed" "$RESTORE_ROOT/fw_rules"; DOCKERFW_CHOICE=1; dockerfw_stage > "$TEST_ROOT/out"; }
  stage_and_keep
  [[ "$RESULT" == 'dockerfw failed' ]] || fail "not confirmed: $RESULT"
  called 'nft delete table inet vps-stable-docker' || fail 'table kept without a confirmation'
  called 'systemctl disable --now vps-stable-docker-fw.path' || fail 'switch left on without a confirmation'
  called 'ufw --force delete allow 6081/tcp' || fail "rule added for it not taken back: $(cat "$CALLS")"
  called 'ufw --force delete allow 7000:7010/tcp' || fail 'range added for it not taken back'
  [[ "$(cat "$RESTORE_ROOT/fw_rules")" == 'ufw allow 22/tcp' ]] || fail "other rules of the record changed: $(cat "$RESTORE_ROOT/fw_rules")"
  [[ ! -e "$RESTORE_ROOT/dockerfw_rules" ]] || fail 'list left'
)
(
  # A start that did not take: the files stay for the rollback but it is not on.
  : > "$DOCKER_FW_PATH_FILE"
  PATH_ENABLED=0
  if dockerfw_on; then fail 'counted as on with its unit off (after an automatic undo)'; fi
  PATH_ENABLED=1
  dockerfw_on || fail 'not counted as on'
  rm -f -- "$DOCKER_FW_PATH_FILE"
  if dockerfw_on; then fail 'counted as on without its file'; fi
)
printf 'PASS: the stage keeps running ports open when asked, has a way back before the rules load, and undoes all of it unconfirmed.\n'

# nftables comes from a fresh package index (the switch may be the first
# thing done on a machine whose index is old).
(
  command() { if [[ "$*" == '-v nft' ]]; then return 1; fi; builtin command "$@"; }
  apt_index_ready() { record index; }
  DOCKERFW_CHOICE=1
  : > "$CALLS"
  dockerfw_stage > /dev/null 2>&1 || true
  [[ "$(grep -n '^index$' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^install nftables$' "$CALLS" | cut -d: -f1)" ]] || fail "nftables installed without a fresh index: $(cat "$CALLS")"
)
# A range of ports is recorded like one port, and goes again with the rollback.
(
  load_optimizer_functions restore_record_fw_rule restore_data_safe state_path_safe port_source_valid restore_fw_rules_apply ssh_candidates
  RESTORE_READY=1
  ssh_candidates() { echo 22; }
  rm -f -- "$RESTORE_ROOT/fw_rules"
  restore_record_fw_rule 'ufw allow 7000:7010/tcp' || fail 'a range of ports could not be recorded'
  grep -Fxq 'ufw allow 7000:7010/tcp' "$RESTORE_ROOT/fw_rules" || fail 'range not in the record'
  if restore_record_fw_rule 'ufw allow 7000:x/tcp'; then fail 'nonsense accepted as a range'; fi
  ufw() {
    case "$1 ${2:-}" in
      'show added') echo 'ufw allow 7000:7010/tcp' ;;
      'status '*) echo 'Status: inactive' ;;
      '--force delete') record "ufw $*" ;;
    esac
  }
  RESTORE_PARTIAL=0
  : > "$CALLS"
  restore_fw_rules_apply > /dev/null
  called 'ufw --force delete allow 7000:7010/tcp' || fail "range not deleted by the rollback: $(cat "$CALLS")"
  ((RESTORE_PARTIAL == 0)) || fail 'a range reported as not undone'
)
# Rules added for the switch still count when its units are already gone.
(
  load_optimizer_functions restore_group_pending restore_needed restore_at_origin restore_read restore_data_safe state_path_safe sshd_off_files
  restore_needed() { return 1; }
  restore_read() { echo clean; }
  rm -f -- "$RESTORE_ROOT/dockerfw_rules"
  if restore_group_pending dockerfw; then fail 'pending with nothing to undo'; fi
  printf 'ufw allow 6081/tcp\n' > "$RESTORE_ROOT/dockerfw_rules"
  restore_group_pending dockerfw || fail 'rules added for the switch not pending'
  rm -f -- "$RESTORE_ROOT/dockerfw_rules"
)
printf 'PASS: nftables comes from a fresh index, and ranges of ports are recorded and undone.\n'

# 7. What the check says, and the note in the acceptance check.
verify_set() { VERDICT="$1 $2"; }
: > "$DOCKER_FW_PATH_FILE"
UFW_ADDED="Added user rules (see 'ufw status' for running firewall):
ufw allow 80/tcp
ufw allow 7000:7010/tcp
ufw allow 6081/tcp"
check() { VERDICT=''; check_dockerfw; }
(check; [[ "$VERDICT" == pass* ]] || fail "check: $VERDICT")
(UFW_ADDED="Added user rules (see 'ufw status' for running firewall):
ufw allow 80/tcp"; check; [[ "$VERDICT" == notice*6081/tcp* ]] || fail "port not let through: $VERDICT")
(UFW_STATE=inactive; check; [[ "$VERDICT" == notice* ]] || fail "firewall off: $VERDICT")
(NFT_LIST_RC=1; check; [[ "$VERDICT" == fail* ]] || fail "no rules in nftables: $VERDICT")
(PATH_ENABLED=0; check; [[ "$VERDICT" == fail* ]] || fail "unit off: $VERDICT")
(rm -f -- "$DOCKER_FW_PATH_FILE"; check; [[ "$VERDICT" == fail* ]] || fail "file gone: $VERDICT")
: > "$DOCKER_FW_PATH_FILE"
[[ "$(docker_firewall_note)" == *'受防火墙管'*已开启* ]] || fail "note when on: $(docker_firewall_note)"
if [[ "$(docker_firewall_note)" == *绕过*挡不住* ]]; then fail 'still warns with the switch on'; fi
(PATH_ENABLED=0; [[ "$(docker_firewall_note)" == *'绕过 UFW'* ]] || fail "note when off: $(docker_firewall_note)")
(DOCKER_THERE=0; [[ -z "$(docker_firewall_note)" ]] || fail 'note without Docker')
# The foreign-rules check does not take this tool's own table for someone else's.
own=$'table inet vps-stable-docker {\n\tchain forward {\n\t\ttype filter hook forward priority -1; policy accept;\n\t\tct state new ct status dnat jump published\n\t}\n\tchain published {\n\t\tdrop\n\t}\n}'
if nft_ruleset_has_policy 0 <<< "$own" > /dev/null; then fail "this tool's table taken for foreign rules"; fi
foreign=$'table inet other {\n\tchain forward {\n\t\ttype filter hook forward priority -1; policy accept;\n\t\tdrop\n\t}\n}'
nft_ruleset_has_policy 0 <<< "$foreign" > /dev/null || fail 'foreign rules no longer seen'
printf 'PASS: the check tells working, not let through and broken apart.\n'

# 8. The list of ports, and its way back in the rollback.
out="$(dockerfw_show)"
grep -Eq '^  6081/tcp +web（放行）$' <<< "$out" || fail "show: $out"
(UFW_ADDED="Added user rules (see 'ufw status' for running firewall):"; out="$(dockerfw_show)"; grep -Fq 'vps port open 7000-7010 tcp' <<< "$out" || fail "show, range blocked: $out")
(DOCKER_PS=''; [[ "$(dockerfw_show)" == *没有容器* ]] || fail 'show with nothing published')
[[ "$(restore_ids dockerfw | tr '\n' ' ')" == 'dockerfw_units dockerfw_service dockerfw_path ' ]] || fail "tracked: $(restore_ids dockerfw | tr '\n' ' ')"
grep -Fxq dockerfw <<< "$(restore_groups)" || fail 'no rollback group'
grep -Fxq dockerfw <<< "$(item_keys)" || fail 'no single item'
[[ "$(item_label dockerfw)" == 'Docker 端口受防火墙管' ]] || fail 'label'
: > "$CALLS"
(
  restore_resource() { record "restore $1"; }
  printf 'ufw allow 6081/tcp\n' > "$RESTORE_ROOT/dockerfw_rules"
  restore_dockerfw_group
  # Widening is all that is left once the table is gone first.
  first="$(grep -n 'nft delete table' "$CALLS" | head -n 1 | cut -d: -f1)"
  [[ "$first" -lt "$(grep -n '^restore dockerfw_units$' "$CALLS" | cut -d: -f1)" ]] || fail 'table not removed first'
  for id in dockerfw_units dockerfw_service dockerfw_path; do called "restore $id" || fail "$id not restored"; done
  called 'ufw --force delete allow 6081/tcp' || fail 'rule added for it stays after the rollback'
)
printf 'PASS: the rollback takes the table away first and the rules added for it too.\n'

# 9. The units: what starts it and what makes it follow UFW.
service="$(dockerfw_service_text)" path="$(dockerfw_path_text)"
grep -Fxq 'After=ufw.service' <<< "$service" || fail 'must start after UFW'
grep -Fxq 'Before=docker.service' <<< "$service" || fail 'must be in place before containers start'
grep -Fxq 'ExecStart=/bin/bash /usr/local/lib/vps-stable-opt/vps-stable-opt.sh docker-fw-sync' <<< "$service" || fail 'ExecStart'
for file in user.rules user6.rules ufw.conf; do grep -Fxq "PathChanged=/etc/ufw/$file" <<< "$path" || fail "does not follow $file"; done
printf 'PASS: the rules are there before Docker starts and follow every change of UFW.\n'

# The session lost before the confirmation: the timer took the switch away, the
# firewall rules added for it go with the next run; not while a timer counts.
(
  T2="$(mktemp -d)"; RESTORE_ROOT="$T2"; PENDING_TIMER=1
  warned="$T2/warned" deleted="$T2/deleted"
  warn() { printf '%s\n' "$*" >> "$warned"; }
  ufw() { printf '%s\n' "$*" >> "$deleted"; }
  tool_no_pending_firewall() { ((PENDING_TIMER == 0)); }
  printf 'ufw allow 8081/tcp\n' > "$T2/dockerfw_rules"; printf 'ufw allow 8081/tcp\nufw allow 22/tcp\n' > "$T2/fw_rules"
  dockerfw_settle
  [[ -s "$T2/dockerfw_rules" && ! -e "$deleted" ]] || fail 'settled while a timer still counts'
  PENDING_TIMER=0; dockerfw_settle
  grep -Fxq -- '--force delete allow 8081/tcp' "$deleted" || fail "the rule stayed: $(cat "$deleted" 2>&1)"
  [[ ! -e "$T2/dockerfw_rules" ]] || fail 'the record of the rules stayed'
  [[ "$(cat "$T2/fw_rules")" == 'ufw allow 22/tcp' ]] || fail "the firewall record: $(cat "$T2/fw_rules")"
  grep -q '没有等到确认' "$warned" || fail 'not said'
  rm -rf -- "$T2"
)
printf 'PASS: a Docker switch lost before its confirmation leaves no firewall rules behind.\n'
