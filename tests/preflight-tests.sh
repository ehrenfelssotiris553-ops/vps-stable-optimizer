#!/usr/bin/env bash
# Repository parsing tests use the actual function and local fixture files.
# No APT command, source refresh, DNS request, or optimizer mode is run.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions apt_source_records apt_mirror_list_hosts apt_host_official release_info ymd_days support_lifecycle_report preflight_gate
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); }

for pair in 19700101:0 19691231:-1 20000301:11017 20240229:19782 20261025:20751 20280630:21365; do
  [[ "$(ymd_days "${pair%%:*}")" == "${pair#*:}" ]] || fail "day arithmetic wrong for ${pair%%:*}"
done
OS=debian OS_VERSION=13
[[ "$(release_info | cut -f1)" == trixie ]] || fail 'release table codename'
OS=centos OS_VERSION=9
if release_info >/dev/null; then fail 'unreviewed release accepted by the release table'; fi
printf '%s\n' 'PASS: pure-Bash date arithmetic and the single reviewed release table.'
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
preflight_block() { PREFLIGHT_BLOCKERS=$((PREFLIGHT_BLOCKERS+1)); }
assert_not_secret() {
  if [[ "$1" == *SECRET* || "$1" == *private-user* || "$1" == *PRIVATE_KEY* ]]; then
    fail 'repository parser leaked credentials or unrelated key material'
  fi
}

cat > "$TEST_ROOT/sources.list" <<'LIST'
# deb https://disabled.example.net bookworm main
deb-src https://source-only.example.net bookworm main
deb [signed-by=/keyring] https://private-user:SECRET_PASSWORD@mirror.example.net:443/debian?token=SECRET_QUERY bookworm main
deb [trusted=yes check-valid-until=no] http://deb.debian.org/debian bookworm-updates main
LIST
out="$(apt_source_records "$TEST_ROOT/sources.list" list)"
expected=$'mirror.example.net\tbookworm\t0\t0\ndeb.debian.org\tbookworm-updates\t1\t1'
[[ "$out" == "$expected" ]] || fail "one-line source records differed: $out"
assert_not_secret "$out"
printf '%s\n' 'PASS: one-line sources ignore inactive/source-only entries and redact credentials.'

cat > "$TEST_ROOT/debian.sources" <<'SOURCES'
Types: deb deb-src
URIs: https://private-user:SECRET_PASSWORD@security.debian.org/debian-security?token=SECRET_QUERY
Suites: bookworm-security
 bookworm-updates
Components: main
Signed-By:
 -----BEGIN PGP PUBLIC KEY BLOCK-----
 PRIVATE_KEY_SENTINEL
 -----END PGP PUBLIC KEY BLOCK-----

Types: deb
URIs: https://disabled.example.net
Suites: bookworm
Enabled: no

Types: deb
URIs: http://mirror.example.net
Suites: bookworm
Trusted: yes
Check-Valid-Until: no
SOURCES
out="$(apt_source_records "$TEST_ROOT/debian.sources" sources)"
expected=$'security.debian.org\tbookworm-security\t0\t0\nsecurity.debian.org\tbookworm-updates\t0\t0\nmirror.example.net\tbookworm\t1\t1'
[[ "$out" == "$expected" ]] || fail "deb822 records differed: $out"
assert_not_secret "$out"
printf '%s\n' 'PASS: deb822 multiline suites and policy flags parsed without key material output.'

cat > "$TEST_ROOT/odd.list" <<'ODD'
deb file:/local/mirror custom!suite main
deb https://bad%host.example.net/debian bookworm main
ODD
out="$(apt_source_records "$TEST_ROOT/odd.list" list)"
expected=$'[non-http-source]\t[custom-suite]\t0\t0\n[unrecognized-host]\tbookworm\t0\t0'
[[ "$out" == "$expected" ]] || fail "unrecognized repository fields were not bounded: $out"
printf '%s\n' 'PASS: non-HTTP, malformed host, and nonstandard suite are represented as unknown data.'

cat > "$TEST_ROOT/boolean.list" <<'BOOL_LIST'
deb [trusted=true] https://deb.debian.org/debian bookworm main
deb [allow-insecure=1 check-valid-until=false] https://deb.debian.org/debian bookworm main
deb [allow-weak=1 check-date=0] https://deb.debian.org/debian bookworm main
deb [allow-downgrade-to-insecure=true] https://deb.debian.org/debian bookworm main
BOOL_LIST
out="$(apt_source_records "$TEST_ROOT/boolean.list" list)"
expected=$'deb.debian.org\tbookworm\t1\t0\ndeb.debian.org\tbookworm\t1\t1\ndeb.debian.org\tbookworm\t1\t1\ndeb.debian.org\tbookworm\t1\t0'
[[ "$out" == "$expected" ]] || fail "one-line boolean variants were not recognized: $out"
cat > "$TEST_ROOT/boolean.sources" <<'BOOL_SOURCES'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm
Trusted: TRUE
Check-Valid-Until: 0

Types: deb
URIs: https://disabled.example.net
Suites: bookworm
Enabled: false

Types: deb
URIs: https://disabled.example.net
Suites: bookworm
Enabled: 0

Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm
Allow-Weak: true
Check-Date: false

Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm
Allow-Downgrade-To-Insecure: 1
BOOL_SOURCES
out="$(apt_source_records "$TEST_ROOT/boolean.sources" sources)"
[[ "$out" == $'deb.debian.org\tbookworm\t1\t1\ndeb.debian.org\tbookworm\t1\t1\ndeb.debian.org\tbookworm\t1\t0' ]] || fail "deb822 boolean variants were not recognized: $out"
printf '%s\n' 'PASS: APT boolean variants preserve insecure flags and disabled-source semantics.'

date() {
  [[ "$*" == '-u +%Y%m%d' ]] || fail "unexpected lifecycle clock request: $*"
  printf '%s\n' "$CASE_DATE"
}
OS=debian OS_VERSION=12 CASE_DATE=20261023 PREFLIGHT_BLOCKERS=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$PREFLIGHT_BLOCKERS" == 0 ]] || fail 'reviewed Debian 12 release was blocked before cutoff'
OS=ubuntu OS_VERSION=22.04 CASE_DATE=20270601 PREFLIGHT_BLOCKERS=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$PREFLIGHT_BLOCKERS" == 1 ]] || fail 'expired Ubuntu maintenance reference was accepted'
OS=debian OS_VERSION=13 CASE_DATE=19990101 PREFLIGHT_BLOCKERS=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$PREFLIGHT_BLOCKERS" == 1 ]] || fail 'implausible clock was accepted'
OS=unreviewed OS_VERSION=1 CASE_DATE=20261023 PREFLIGHT_BLOCKERS=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$PREFLIGHT_BLOCKERS" == 1 ]] || fail 'unreviewed system lifecycle was accepted'
OS=ubuntu OS_VERSION=22.04 CASE_DATE=20270101 PREFLIGHT_BLOCKERS=0 WARN_COUNT=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$PREFLIGHT_BLOCKERS" == 0 && "$WARN_COUNT" == 1 ]] || fail 'approaching end of maintenance was not warned (or was blocked)'
OS=debian OS_VERSION=12 CASE_DATE=20261025 PREFLIGHT_BLOCKERS=0 WARN_COUNT=0
support_lifecycle_report > "$TEST_ROOT/lifecycle"
[[ "$WARN_COUNT" == 0 ]] || fail 'distant end of maintenance produced a warning'
printf '%s\n' 'PASS: lifecycle gate blocks expired, implausible-clock, and unreviewed releases.'

preflight_report() { PREFLIGHT_BLOCKERS="$CASE_BLOCKERS"; SOURCE_REVIEW_REQUIRED="$CASE_REVIEW"; }
confirm_yes() { printf 'SOURCES\n' >> "$TEST_ROOT/confirmation"; ((CASE_CONFIRM)); }
for gate_case in blocked rejected accepted no_review; do
  CASE_BLOCKERS=0 CASE_REVIEW=1 CASE_CONFIRM=0
  case "$gate_case" in
    blocked) CASE_BLOCKERS=1 ;;
    rejected) : ;;
    accepted) CASE_CONFIRM=1 ;;
    no_review) CASE_REVIEW=0 ;;
  esac
  : > "$TEST_ROOT/confirmation"
  # A tested shell function must not be called from an if/!/&&/|| context.
  set +e
  ( set -Eeuo pipefail; preflight_gate; printf 'CONTINUED\n' > "$TEST_ROOT/$gate_case.marker" ) > "$TEST_ROOT/gate-output" 2>&1
  gate_rc=$?
  set -e
  case "$gate_case" in
    blocked|rejected) [[ "$gate_rc" != 0 && ! -e "$TEST_ROOT/$gate_case.marker" ]] || fail "preflight $gate_case continued" ;;
    accepted|no_review) [[ "$gate_rc" == 0 && -e "$TEST_ROOT/$gate_case.marker" ]] || fail "preflight $gate_case did not continue" ;;
  esac
  if [[ "$gate_case" == rejected || "$gate_case" == accepted ]]; then
    grep -Fxq SOURCES "$TEST_ROOT/confirmation" || fail 'unknown sources bypassed explicit SOURCES confirmation'
  else
    [[ ! -s "$TEST_ROOT/confirmation" ]] || fail 'blocked/no-review path asked a spurious source confirmation'
  fi
done
printf '%s\n' 'PASS: blocked and unconfirmed source review cannot continue through the actual preflight gate.'

# The plan run immediately before APPLY is reused instead of probing again.
preflight_report() { printf 'probe\n' >> "$TEST_ROOT/probes"; PREFLIGHT_BLOCKERS=0; SOURCE_REVIEW_REQUIRED=0; }
: > "$TEST_ROOT/probes"
PREFLIGHT_DONE=1 PREFLIGHT_BLOCKERS=0 SOURCE_REVIEW_REQUIRED=0
preflight_gate
[[ ! -s "$TEST_ROOT/probes" ]] || fail 'preflight probes repeated right after the plan'
PREFLIGHT_DONE=1 PREFLIGHT_BLOCKERS=2
set +e
( set -Eeuo pipefail; preflight_gate ) > "$TEST_ROOT/gate-output" 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" != 0 ]] || fail 'cached blocking findings were not enforced'
printf '%s\n' 'PASS: cached plan findings are enforced without repeating probes.'

# Debian 13 cloud images: deb822 sources point at mirror+file lists.
printf 'Types: deb\nURIs: mirror+file:///etc/apt/mirrors/debian.list\nSuites: trixie trixie-updates\nComponents: main\n\nTypes: deb\nURIs: mirror+file:///etc/apt/mirrors/debian-security.list\nSuites: trixie-security\nComponents: main\n' > "$TEST_ROOT/cloud.sources"
out="$(apt_source_records "$TEST_ROOT/cloud.sources" sources)"
expected=$'mirror-file:/etc/apt/mirrors/debian.list\ttrixie\t0\t0\nmirror-file:/etc/apt/mirrors/debian.list\ttrixie-updates\t0\t0\nmirror-file:/etc/apt/mirrors/debian-security.list\ttrixie-security\t0\t0'
[[ "$out" == "$expected" ]] || { printf '%s\n' "$out" >&2; fail 'mirror+file source not recognized'; }
# Only the fixed mirror directory is accepted.
printf 'deb mirror+file:///tmp/evil.list trixie main\ndeb mirror+file:///etc/apt/mirrors/../x.list trixie main\n' > "$TEST_ROOT/odd-mirror.list"
out="$(apt_source_records "$TEST_ROOT/odd-mirror.list" list)"
[[ "$out" == $'[non-http-source]\ttrixie\t0\t0\n[non-http-source]\ttrixie\t0\t0' ]] || fail 'mirror list outside /etc/apt/mirrors accepted'
printf '# comment\nhttps://deb.debian.org/debian\thttps://x\nhttp://USER@Mirror.Example.COM:8080/debian priority:1\n\nftp://old.example/debian\n' > "$TEST_ROOT/mirrors.list"
[[ "$(apt_mirror_list_hosts "$TEST_ROOT/mirrors.list")" == $'deb.debian.org\nmirror.example.com\n[non-http-source]' ]] || fail 'mirror list hosts'
if apt_mirror_list_hosts "$TEST_ROOT/missing.list" >/dev/null; then fail 'missing mirror list accepted'; fi
OS=debian
apt_host_official deb.debian.org || fail 'deb.debian.org not official'
if apt_host_official mirror.example.com; then fail 'third-party mirror counted as official'; fi
OS=ubuntu
apt_host_official security.ubuntu.com || fail 'Ubuntu security host not official'
printf 'PASS: mirror+file sources (Debian cloud images) are read from their mirror lists.\n'
