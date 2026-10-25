#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions ufw_rule ufw_active ufw_stored_rules_safe port_source_valid firewall_conflict nft_ruleset_has_policy
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
MOCK_ADDED='' MOCK_FAIL=0 MOCK_READ_FAIL=0 MOCK_STATE='Status: active' MOCK_STATUS_RC=0
SSH_PORTS=(22 2222)
warn() { printf '%s\n' "$*" >> "$TEST_DIR/warnings"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
restore_record_fw_rule() { printf '%s\n' "$1" >> "$TEST_DIR/recorded"; }
ufw() {
  if [[ "$*" == 'show added' ]]; then
    ((MOCK_READ_FAIL == 0)) || return 1
    printf '%s\n' "$MOCK_ADDED"; return 0
  fi
  if [[ "$*" == status ]]; then
    printf '%s\n' "$MOCK_STATE"; return "$MOCK_STATUS_RC"
  fi
  printf '%s\n' "$*" >> "$TEST_DIR/calls"
  ((MOCK_FAIL == 0))
}

unset verb port expected || true
: > "$TEST_DIR/calls"; : > "$TEST_DIR/recorded"
ufw_rule allow 80
[[ "$(cat "$TEST_DIR/calls")" == 'allow 80/tcp' ]] || fail 'new rule under set -u'
[[ "$(cat "$TEST_DIR/recorded")" == 'ufw allow 80/tcp' ]] || fail 'added rule was not recorded for rollback'
: > "$TEST_DIR/calls"; : > "$TEST_DIR/recorded"
MOCK_ADDED=$'ufw allow 80/tcp\nufw limit 22/tcp'
ufw_rule allow 80
ufw_rule limit 22
[[ ! -s "$TEST_DIR/calls" ]] || fail 'existing rule duplicated'
[[ ! -s "$TEST_DIR/recorded" ]] || fail 'a pre-existing rule was claimed as added by this tool'
MOCK_ADDED='ufw allow 8080/tcp'
ufw_rule allow 80
[[ "$(cat "$TEST_DIR/calls")" == 'allow 80/tcp' ]] || fail 'different port suppressed a rule'
MOCK_ADDED='' MOCK_FAIL=1
: > "$TEST_DIR/recorded"
if ufw_rule allow 443; then fail 'ufw write error hidden'; fi
[[ ! -s "$TEST_DIR/recorded" ]] || fail 'a failed rule was recorded'
MOCK_FAIL=0 MOCK_READ_FAIL=1
if ufw_rule allow 443; then fail 'unreadable rules caused a write'; fi
MOCK_READ_FAIL=0
printf 'PASS: UFW rule creation, exact matching, idempotency, rollback records and failure propagation.\n'

ufw_active || fail 'active state not recognized'
MOCK_STATE='Status: inactive'
if ufw_active; then fail 'inactive treated as active'; fi
MOCK_STATE='Status: active' MOCK_STATUS_RC=1
if ufw_active; then fail 'failed status command treated as active'; fi
MOCK_STATUS_RC=0
printf 'PASS: UFW state is checked together with command success.\n'

MOCK_ADDED=$'Added user rules:\nufw limit 22/tcp\nufw limit 2222/tcp\nufw allow 80/tcp\nufw allow 443/tcp'
ufw_stored_rules_safe || fail 'known baseline rejected'
# Allow rules (including earlier port-manager rules) only widen access.
for MOCK_ADDED in 'ufw allow 2222/tcp' 'ufw allow 1234/udp' 'ufw allow from 192.0.2.1' 'ufw allow 443:600/tcp'; do
  ufw_stored_rules_safe || fail "harmless allow rule rejected: $MOCK_ADDED"
done
for MOCK_ADDED in 'ufw deny 22/tcp' 'ufw reject from 192.0.2.1' 'ufw limit 8080/tcp' 'ufw route allow 80/tcp' 'ufw deny out 53'; do
  if ufw_stored_rules_safe; then fail "unknown stored rule accepted: $MOCK_ADDED"; fi
done
# Fail2ban bans one address on an SSH port; they pile up while UFW is paused.
for MOCK_ADDED in 'ufw deny from 198.51.100.7 to any port 22 proto tcp' 'ufw prepend deny proto tcp from 198.51.100.7 to any port 22,2222' 'ufw prepend deny proto tcp from 2001:db8::7 to any port 2222' 'ufw insert 1 deny from 203.0.113.0/24 to any port 22 proto tcp'; do
  ufw_stored_rules_safe || fail "Fail2ban SSH ban rejected: $MOCK_ADDED"
done
for MOCK_ADDED in 'ufw deny from 198.51.100.7 to any port 8080 proto tcp' 'ufw deny from 198.51.100.7 to any port 22' 'ufw deny from any to any port 22 proto tcp' 'ufw deny from 999.1.1.1 to any port 22 proto tcp' 'ufw deny proto udp from 198.51.100.7 to any port 22' 'ufw deny proto tcp from 198.51.100.7 to any port 22,8080'; do
  if ufw_stored_rules_safe; then fail "non-ban deny rule accepted: $MOCK_ADDED"; fi
done
MOCK_READ_FAIL=1
if ufw_stored_rules_safe; then fail 'unreadable stored rules accepted'; fi
MOCK_READ_FAIL=0
printf 'PASS: inactive UFW with deny/limit/route rules or unreadable rules is preserved.\n'

NFT_RULES='' NFT_RC=0 IPV4_RULES='' IPV4_RC=0 IPV6_RULES='' IPV6_RC=0
active() { return 1; }
nft() { printf '%s\n' "$NFT_RULES"; return "$NFT_RC"; }
iptables-save() { printf '%s\n' "$IPV4_RULES"; return "$IPV4_RC"; }
ip6tables-save() { printf '%s\n' "$IPV6_RULES"; return "$IPV6_RC"; }
if firewall_conflict; then fail 'empty inspectable rules rejected'; fi
# What iptables-nft and `ufw disable` leave behind: empty base chains, accept policy.
NFT_RULES=$'table ip filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t}\n\tchain FORWARD {\n\t\ttype filter hook forward priority filter; policy accept;\n\t}\n}\ntable ip6 filter {\n\tchain OUTPUT {\n\t\ttype filter hook output priority filter; policy accept;\n\t}\n}'
if firewall_conflict; then fail 'inert empty nftables chains blocked takeover'; fi
# A "#" note above a table (newer nft) is not a rule.
NFT_RULES=$'# Warning: table ip filter is managed by iptables-nft, do not touch!\ntable ip filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t}\n}'
if firewall_conflict; then fail 'an nft comment line blocked takeover'; fi
NFT_RULES=$'table inet administrator {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t}\n}'
firewall_conflict || fail 'drop policy chain missed'
NFT_RULES=$'table inet administrator {\n\tchain input {\n\t\ttype filter hook input priority filter; policy accept;\n\t\ttcp dport 22 accept\n\t}\n}'
: > "$TEST_DIR/warnings"
firewall_conflict || fail 'nftables rule missed'
grep -Fq 'tcp dport 22 accept' "$TEST_DIR/warnings" || fail 'the blocking nftables rule was not named'
NFT_RULES=$'table inet administrator {\n\tset blocked {\n\t\ttype ipv4_addr\n\t}\n}'
firewall_conflict || fail 'nftables set missed'
NFT_RULES=''
IPV6_RULES='-A INPUT -p tcp --dport 1234 -j ACCEPT'
firewall_conflict || fail 'IPv6 firewall append missed'
IPV6_RULES='' IPV4_RULES=':INPUT DROP [0:0]'
firewall_conflict || fail 'DROP policy missed'
IPV4_RULES='' NFT_RC=1
firewall_conflict || fail 'unreadable nftables accepted'
NFT_RC=0 IPV6_RC=1
firewall_conflict || fail 'unreadable IPv6 firewall accepted'
printf 'PASS: real IPv4/IPv6/nftables policies block takeover; inert empty chains do not.\n'
