#!/usr/bin/env bash
# Port manager tests: actual parsing/rule functions, every UFW call mocked.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions port_parse_spec port_item_count port_item_text port_item_covers port_protocols port_source_valid port_ssh_ports port_rule_text port_listen_note port_risky_names port_open port_rule_parse port_close port_list
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/messages"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/messages"; }
CONFIRM_YES=1 CONFIRM_CLOSE=1 UFW_ON=1 ADDED='' ALLOW_FAIL=0
confirm_yes() {
  printf 'ask\n' >> "$TEST_ROOT/asks"
  case "$1" in *关闭*) ((CONFIRM_CLOSE)) ;; *) ((CONFIRM_YES)) ;; esac
}
ufw_active() { ((UFW_ON)); }
ssh_candidates() { printf '%s\n' 22 2222; }
ss() { :; }
DOCKER=0
docker_present() { ((DOCKER)); }
ufw() {
  case "$*" in
    'show added') printf 'Added user rules:\n%s\n' "$ADDED" ;;
    allow\ *) printf '%s\n' "$*" >> "$TEST_ROOT/calls"; ((ALLOW_FAIL == 0)) ;;
    '--force delete '*) printf '%s\n' "$*" >> "$TEST_ROOT/calls" ;;
    *) fail "unexpected ufw $*" ;;
  esac
}
reset() { : > "$TEST_ROOT/calls"; : > "$TEST_ROOT/messages"; : > "$TEST_ROOT/asks"; CONFIRM_YES=1 CONFIRM_CLOSE=1 UFW_ON=1 ADDED='' ALLOW_FAIL=0; }

[[ "$(port_parse_spec 8080)" == 8080 ]] || fail 'single port'
[[ "$(port_parse_spec 443-600)" == 443:600 ]] || fail 'range converted to UFW colon form'
[[ "$(port_parse_spec '8080,9000-9100')" == $'8080\n9000:9100' ]] || fail 'list of port and range'
[[ "$(port_parse_spec ' 80 , 443 ')" == $'80\n443' ]] || fail 'spaces around items'
[[ "$(port_parse_spec '80 - 90')" == 80:90 ]] || fail 'spaces around a range dash'
[[ "$(port_parse_spec 08080)" == 8080 ]] || fail 'leading zero must not be octal'
for bad in '' 0 65536 99999 600-443 1-65535 abc '80;rm -rf /' '80,,90' -5 '80-' '$(id)' '80 90'; do
  if port_parse_spec "$bad" >/dev/null; then fail "invalid port spec accepted: <$bad>"; fi
done
[[ "$(port_item_count 443:600)" == 158 && "$(port_item_count 8080)" == 1 ]] || fail 'port counts'
port_item_covers 1:100 22 || fail 'range covering SSH port missed'
if port_item_covers 8080 22; then fail 'single port wrongly covers SSH'; fi
[[ "$(port_item_text 443:600)" == 443-600 ]] || fail 'display text'
for good in 203.0.113.5 10.0.0.0/8 2001:db8::/32 2001:db8::1; do port_source_valid "$good" || fail "valid source rejected: $good"; done
for good in :: ::/0 ::1 fe80::1:2:3:4:5:6 1:2:3:4:5:6:7:8/128 1:2:3:4:5:6:7:: ABCD::ef; do
  port_source_valid "$good" || fail "valid IPv6 source rejected: $good"
done
for bad in 256.1.1.1 1.2.3.4/33 any '1.2.3.4;id' 2001:db8::/129 '' ::: :::: 12345::1 1:2:3 1::2: :1::2 1::2::3 \
           1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7::8 :1:2:3:4:5:6:7:8 1::g; do
  if port_source_valid "$bad"; then fail "invalid source accepted: $bad"; fi
done
printf 'PASS: port specs, ranges, counts and source addresses are validated strictly.\n'

[[ "$(port_rule_text 8080 tcp)" == 'ufw allow 8080/tcp' ]] || fail 'plain rule text'
[[ "$(port_rule_text 443:600 udp 203.0.113.5)" == 'ufw allow from 203.0.113.5 to any port 443:600 proto udp' ]] || fail 'source rule text'
[[ "$(port_rule_parse 'ufw allow 443:600/udp')" == $'443:600\tudp\t' ]] || fail 'parse plain range rule'
[[ "$(port_rule_parse 'ufw allow 8080')" == $'8080\tboth\t' ]] || fail 'parse protocol-less rule'
[[ "$(port_rule_parse 'ufw allow from 203.0.113.5 to any port 8080 proto tcp')" == $'8080\ttcp\t203.0.113.5' ]] || fail 'parse source rule'
if port_rule_parse 'ufw limit 22/tcp' >/dev/null || port_rule_parse 'ufw deny from 198.51.100.7' >/dev/null; then fail 'non-allow rule parsed as an open port'; fi
printf 'PASS: rule text and parsing round-trip.\n'

reset
port_open 443-600 both '' > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == $'allow 443:600/tcp\nallow 443:600/udp' ]] || fail 'range not opened for both protocols'
grep -Fq '共 316 个' "$TEST_ROOT/out" || fail 'port total not shown'
grep -Fq '安全组' "$TEST_ROOT/out" || fail 'provider security group reminder missing'

reset
ADDED='ufw allow 8080/tcp'
port_open 8080 tcp '' > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'existing rule was added again'

reset
port_open 8080 tcp 203.0.113.5 > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == 'allow proto tcp from 203.0.113.5 to any port 8080' ]] || fail 'source-restricted rule command'

reset
port_open '80;id' tcp '' > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'invalid spec reached UFW'
port_open 8080 icmp '' > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'invalid protocol reached UFW'
port_open 8080 tcp 'any' > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'invalid source reached UFW'

reset
CONFIRM_YES=0
port_open 8080 tcp '' > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'declined confirmation still opened a port'

reset
port_open 30000-32000 tcp '' > "$TEST_ROOT/out"
[[ "$(grep -c ask "$TEST_ROOT/asks")" == 2 ]] || fail 'large range did not ask a second time'

# Database/admin ports open to everyone need an extra confirmation.
[[ "$(port_risky_names 3306 8080 6000:6400)" == '3306(MySQL) 6379(Redis)' ]] || fail 'risky port names'
reset
port_open 3306 tcp '' > "$TEST_ROOT/out"
[[ "$(grep -c ask "$TEST_ROOT/asks")" == 2 ]] || fail 'risky port opened to everyone without an extra question'
grep -Fq '3306(MySQL)' "$TEST_ROOT/messages" || fail 'risky port warning missing'
reset
port_open 3306 tcp 203.0.113.5 > "$TEST_ROOT/out"
[[ "$(grep -c ask "$TEST_ROOT/asks")" == 1 ]] || fail 'source-restricted risky port asked an extra question'
reset
DOCKER=1
port_open 8080 tcp '' > "$TEST_ROOT/out"
grep -Fq 'Docker' "$TEST_ROOT/out" || fail 'Docker bypass note missing'
DOCKER=0

reset
UFW_ON=0
port_open 8080 tcp '' > "$TEST_ROOT/out"
grep -Fq '没有开启' "$TEST_ROOT/messages" || fail 'inactive firewall was not reported'
printf 'PASS: opening ports validates input, skips duplicates, warns and confirms.\n'

reset
ADDED=$'ufw limit 22/tcp\nufw allow 1:100/tcp'
port_close 1-100 both > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'a range containing the SSH port was closed'
grep -Fq 'SSH 端口 22' "$TEST_ROOT/messages" || fail 'SSH protection message missing'
port_close 2222 tcp > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'second SSH port was closed'

reset
ADDED=$'ufw allow 8080/tcp\nufw allow 8080/udp\nufw allow from 203.0.113.5 to any port 8080 proto tcp\nufw allow 9090/tcp'
port_close 8080 both > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == $'--force delete allow 8080/tcp\n--force delete allow 8080/udp\n--force delete allow from 203.0.113.5 to any port 8080 proto tcp' ]] || fail 'exact 8080 rules were not all removed'

reset
ADDED=$'ufw allow 8080/tcp\nufw allow 8080/udp'
port_close 8080 udp > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == '--force delete allow 8080/udp' ]] || fail 'protocol filter not honoured'

reset
ADDED='ufw allow 443:600/tcp'
port_close 500 tcp > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'a single port inside a range was deleted'
grep -Fq '443-600' "$TEST_ROOT/messages" || fail 'partial-range explanation missing'

reset
ADDED='ufw allow 8080/tcp'
CONFIRM_CLOSE=0
port_close 8080 tcp > "$TEST_ROOT/out"
[[ ! -s "$TEST_ROOT/calls" ]] || fail 'closing without CLOSE confirmation'

# A protocol-less rule allows TCP and UDP: closing one protocol re-allows the
# other on its own first, then deletes the combined rule.
reset
ADDED='ufw allow 18081'
port_close 18081 tcp > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == $'allow 18081/udp\n--force delete allow 18081' ]] || fail 'combined rule not split when closing TCP'
grep -Fq '先单独放行 udp' "$TEST_ROOT/out" || fail 'split not explained before confirming'

# The SSH port in a combined rule: closing UDP keeps SSH's TCP open.
reset
ADDED='ufw allow 22'
port_close 22 udp > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == $'allow 22/tcp\n--force delete allow 22' ]] || fail 'UDP not closed on a combined SSH-port rule'

reset
ADDED='ufw allow from 203.0.113.5 to any port 8080'
port_close 8080 udp > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == $'allow proto tcp from 203.0.113.5 to any port 8080\n--force delete allow from 203.0.113.5 to any port 8080' ]] || fail 'source-restricted combined rule not split'

# Re-allowing the kept protocol fails: the combined rule stays.
reset
ADDED='ufw allow 18081'
ALLOW_FAIL=1
port_close 18081 tcp > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == 'allow 18081/udp' ]] || fail 'combined rule deleted although the kept protocol could not be re-allowed'
grep -Fq '保持不变' "$TEST_ROOT/messages" || fail 'kept rule not reported'

# Closing both protocols needs no split.
reset
ADDED='ufw allow 18081'
port_close 18081 both > "$TEST_ROOT/out"
[[ "$(cat "$TEST_ROOT/calls")" == '--force delete allow 18081' ]] || fail 'combined rule not deleted when closing both'
printf 'PASS: closing ports protects SSH, matches exactly, explains ranges and splits combined TCP+UDP rules.\n'

reset
ADDED=$'ufw allow 22/tcp\nufw allow 443:600/udp\nufw allow from 203.0.113.5 to any port 3306 proto tcp\nufw deny from 198.51.100.7 to any port 22 proto tcp'
port_list > "$TEST_ROOT/out"
grep -Eq '^22 .*（SSH）' "$TEST_ROOT/out" || fail 'SSH rule not marked'
grep -Eq '^443-600 +udp' "$TEST_ROOT/out" || fail 'range not listed'
grep -Fq '203.0.113.5' "$TEST_ROOT/out" || fail 'source not listed'
grep -Fq 'deny from 198.51.100.7' "$TEST_ROOT/out" || fail 'other rules not listed'
printf 'PASS: port list shows ranges, sources, SSH marks and other rules.\n'
