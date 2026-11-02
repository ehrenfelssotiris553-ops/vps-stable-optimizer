#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions ufw_rule ufw_active ufw_stored_rules_safe port_source_valid firewall_conflict nft_ruleset_has_policy iptables_save_has_policy
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
for MOCK_ADDED in 'ufw deny from 198.51.100.7 to any port 22 proto tcp' 'ufw prepend deny proto tcp from 198.51.100.7 to any port 22,2222' 'ufw prepend deny proto tcp from 2001:db8::7 to any port 2222' 'ufw insert 1 deny from 203.0.113.9 to any port 22 proto tcp'; do
  ufw_stored_rules_safe || fail "Fail2ban SSH ban rejected: $MOCK_ADDED"
done
for MOCK_ADDED in 'ufw deny from 198.51.100.7 to any port 8080 proto tcp' 'ufw deny from 198.51.100.7 to any port 22' 'ufw deny from any to any port 22 proto tcp' 'ufw deny from 999.1.1.1 to any port 22 proto tcp' 'ufw deny proto udp from 198.51.100.7 to any port 22' 'ufw deny proto tcp from 198.51.100.7 to any port 22,8080' \
    'ufw deny from 198.18.1.0/24 to any port 22 proto tcp' 'ufw insert 1 deny from 2001:db8::/64 to any port 22 proto tcp'; do
  if ufw_stored_rules_safe; then fail "non-ban deny rule accepted: $MOCK_ADDED"; fi
done
MOCK_READ_FAIL=1
if ufw_stored_rules_safe; then fail 'unreadable stored rules accepted'; fi
MOCK_READ_FAIL=0
printf 'PASS: inactive UFW with deny/limit/route rules or unreadable rules is preserved.\n'

NFT_RULES='' NFT_RC=0 IPV4_RULES='' IPV4_RC=0 IPV6_RULES='' IPV6_RC=0
active() { return 1; }
# No iptables of its own here unless a case gives one (it decides how nft's
# listing is read).
iptables() { return 127; }
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
IPV6_RC=0
# What `ufw disable` leaves in iptables-save (seen on Debian 13 without nft):
# empty ufw chains plus the jumps into them.
IPV4_RULES=$'# Generated by iptables-save v1.8.11 (nf_tables)\n*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:ufw-after-forward - [0:0]\n:ufw-before-input - [0:0]\n-A INPUT -j ufw-before-logging-input\n-A INPUT -j ufw-before-input\n-A FORWARD -j ufw-before-forward\n-A OUTPUT -j ufw-before-output\nCOMMIT'
IPV6_RULES=$'*filter\n:INPUT ACCEPT [0:0]\n:ufw6-before-input - [0:0]\n-A INPUT -j ufw6-before-input\nCOMMIT'
if firewall_conflict; then fail 'UFW skeleton left by ufw disable blocked takeover'; fi
IPV4_RULES+=$'\n-A ufw-before-input -p tcp --dport 8080 -j ACCEPT'
: > "$TEST_DIR/warnings"
firewall_conflict || fail 'a rule inside a UFW chain missed'
grep -Fq -- '--dport 8080' "$TEST_DIR/warnings" || fail 'the blocking iptables rule was not named'
IPV4_RULES=$'*filter\n:INPUT ACCEPT [0:0]\n-A FORWARD -j MYFW-USER\nCOMMIT'
firewall_conflict || fail 'a jump into a chain of another firewall missed'
IPV4_RULES='' IPV6_RULES=''
NFT_RULES=$'table ip filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t\tcounter packets 12 bytes 840 jump ufw-before-logging-input\n\t\tjump ufw-before-input\n\t}\n\tchain ufw-before-input {\n\t}\n}'
if firewall_conflict; then fail 'nft jumps into empty UFW chains blocked takeover'; fi
NFT_RULES=$'table ip filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t\tjump DOCKER-USER\n\t}\n}'
firewall_conflict || fail 'nft jump into a non-UFW chain missed'
NFT_RULES=''
printf 'PASS: real IPv4/IPv6/nftables policies block takeover; inert empty chains and the UFW skeleton do not.\n'

# Docker's own rules, exactly as Docker 29 wrote them on Ubuntu 22.04 (iptables
# 1.8.7 on nftables, whose nft listing does not mark its tables): not a
# firewall to keep. Anybody else's rule, policy or table next to them is.
DOCKER4=$'*raw\n:PREROUTING ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A PREROUTING -d 172.17.0.2/32 ! -i docker0 -j DROP\nCOMMIT\n*filter\n:INPUT ACCEPT [0:0]\n:FORWARD DROP [0:0]\n:OUTPUT ACCEPT [0:0]\n:DOCKER - [0:0]\n:DOCKER-BRIDGE - [0:0]\n:DOCKER-CT - [0:0]\n:DOCKER-FORWARD - [0:0]\n:DOCKER-INTERNAL - [0:0]\n:DOCKER-USER - [0:0]\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A DOCKER -d 172.17.0.2/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 80 -j ACCEPT\n-A DOCKER ! -i docker0 -o docker0 -j DROP\n-A DOCKER-BRIDGE -o docker0 -j DOCKER\n-A DOCKER-CT -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A DOCKER-FORWARD -j DOCKER-CT\n-A DOCKER-FORWARD -j DOCKER-INTERNAL\n-A DOCKER-FORWARD -j DOCKER-BRIDGE\n-A DOCKER-FORWARD -i docker0 -j ACCEPT\nCOMMIT\n*nat\n:PREROUTING ACCEPT [0:0]\n:INPUT ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n:DOCKER - [0:0]\n-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER\n-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER\n-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE\n-A POSTROUTING -s 172.17.0.2/32 -d 172.17.0.2/32 -p tcp -m tcp --dport 80 -j MASQUERADE\n-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8081 -j DNAT --to-destination 172.17.0.2:80\nCOMMIT'
DOCKER6=$'*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:DOCKER - [0:0]\n:DOCKER-FORWARD - [0:0]\n:DOCKER-USER - [0:0]\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A DOCKER-FORWARD -j DOCKER-CT\nCOMMIT\n*nat\n:PREROUTING ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n:DOCKER - [0:0]\n-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER\n-A OUTPUT ! -d ::1/128 -m addrtype --dst-type LOCAL -j DOCKER\nCOMMIT'
DOCKER_NFT=$'table ip nat {\n\tchain DOCKER {\n\t\tiifname != "docker0" meta l4proto tcp tcp dport 8081 counter packets 0 bytes 0 dnat to 172.17.0.2:80\n\t}\n\n\tchain PREROUTING {\n\t\ttype nat hook prerouting priority dstnat; policy accept;\n\t\tfib daddr type local counter packets 91 bytes 5100 jump DOCKER\n\t}\n}\ntable ip filter {\n\tchain DOCKER {\n\t\tiifname != "docker0" oifname "docker0" counter packets 0 bytes 0 drop\n\t}\n\n\tchain FORWARD {\n\t\ttype filter hook forward priority filter; policy drop;\n\t\tcounter packets 0 bytes 0 jump DOCKER-USER\n\t}\n}'
iptables() { echo 'iptables v1.8.7 (nf_tables)'; }
IPV4_RULES="$DOCKER4" IPV6_RULES="$DOCKER6" NFT_RULES="$DOCKER_NFT"
: > "$TEST_DIR/warnings"
if firewall_conflict; then fail "Docker's own rules blocked the firewall: $(cat "$TEST_DIR/warnings")"; fi
IPV4_RULES="$DOCKER4"$'\n-A INPUT -s 10.0.0.0/8 -p tcp --dport 3306 -j ACCEPT'
firewall_conflict || fail 'an administrator rule next to Docker missed'
IPV4_RULES="${DOCKER4/:INPUT ACCEPT/:INPUT DROP}"
firewall_conflict || fail 'an INPUT drop policy next to Docker missed'
IPV4_RULES="$DOCKER4"
IPV6_RULES="$DOCKER6"$'\n-A FORWARD -i wg0 -j ACCEPT'
firewall_conflict || fail 'a WireGuard forward rule next to Docker missed'
IPV6_RULES="$DOCKER6"
NFT_RULES="$DOCKER_NFT"$'\ntable inet admin {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t}\n}'
firewall_conflict || fail 'a native nftables table next to Docker missed'
NFT_RULES="$DOCKER_NFT"
# iptables not on nftables: an ip filter table in nft is somebody's own.
iptables() { echo 'iptables v1.8.7 (legacy)'; }
firewall_conflict || fail 'an nft table read as Docker although iptables is legacy'
iptables() { echo 'iptables v1.8.7 (nf_tables)'; }
# Without Docker's chains a FORWARD drop policy is somebody's firewall.
IPV4_RULES=$'*filter\n:INPUT ACCEPT [0:0]\n:FORWARD DROP [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT' IPV6_RULES='' NFT_RULES=''
firewall_conflict || fail 'a FORWARD drop policy without Docker missed'
# A table iptables cannot show (native nft rules in it) cannot be judged.
IPV4_RULES=$'# Table `filter\' is incompatible, use \'nft\' tool.'
firewall_conflict || fail 'a table iptables cannot show was accepted'
IPV4_RULES='' IPV6_RULES='' NFT_RULES=''
iptables() { return 127; }
printf 'PASS: Docker'"'"'s own rules do not block the firewall; anything else next to them still does.\n'
