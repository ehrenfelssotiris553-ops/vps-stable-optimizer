#!/usr/bin/env bash
# Update check (menu 12 / vps update): the real functions; every download and
# the installer are replaced by fixtures, so nothing is installed.
# shellcheck disable=SC2034,SC2329,SC2016
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
load_optimizer_functions update_fetch script_version_of version_newer update_install update_main
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { :; }
ok() { printf 'OK %s\n' "$*" >> "$TEST_ROOT/log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TEST_ROOT/log"; }
die() { fail "$*"; }

version_newer 2.6.10 2.6.9 || fail '2.6.10 is newer than 2.6.9'
version_newer 2.7.0 2.6.1 || fail '2.7.0 is newer than 2.6.1'
if version_newer 2.6.1 2.6.1; then fail 'same version taken as newer'; fi
if version_newer 2.6.0 2.6.1; then fail 'older version taken as newer'; fi
printf 'SCRIPT_VERSION=2.7.3\nMODE="${1:-menu}"\n' > "$TEST_ROOT/sample.sh"
[[ "$(script_version_of "$TEST_ROOT/sample.sh")" == 2.7.3 ]] || fail 'version not read from the script'
# Downloads are HTTPS only, also after redirects, and fail on HTTP errors.
curl() { printf '%s\n' "$*" > "$TEST_ROOT/curl-args"; }
update_fetch https://example.invalid/install.sh "$TEST_ROOT/out"
for arg in --fail "--proto =https" "--proto-redir =https" --max-time; do
  grep -Fq -- "$arg" "$TEST_ROOT/curl-args" || fail "download without $arg"
done
unset -f curl
printf 'PASS: version comparison, version reading and HTTPS-only downloads.\n'

# update_main insists on root; everything after that check runs unchanged.
eval "$(declare -f update_main | sed 's/\$EUID -eq 0/0 -eq 0/')"
UPDATE_BASE_URL=https://example.invalid/repo
SCRIPT_VERSION=2.7.0
REMOTE="$TEST_ROOT/remote"; mkdir -p "$REMOTE"
# A release on "GitHub": the main script and an install.sh pinning its hash.
release() {
  local hash
  printf '#!/usr/bin/env bash\nSCRIPT_VERSION=%s\n' "$1" > "$REMOTE/vps-stable-opt.sh"
  hash="$(sha256sum "$REMOTE/vps-stable-opt.sh" | cut -d' ' -f1)"
  if [[ "${2:-}" == badhash ]]; then hash="$(printf '%064d' 0)"; fi
  printf "#!/usr/bin/env bash\nEXPECTED_SHA256='%s'\n" "$hash" > "$REMOTE/install.sh"
}
update_fetch() {
  printf '%s\n' "$1" >> "$TEST_ROOT/urls"
  ((FETCH_FAIL == 0)) || return 1
  cp -- "$REMOTE/${1##*/}" "$2"
}
confirm_default_yes() { printf 'ask %s\n' "$1" >> "$TEST_ROOT/log"; ((ANSWER)); }
update_install() {
  [[ -f "$1" && "$(sha256sum "$2" | cut -d' ' -f1)" == "$(sha256sum "$REMOTE/vps-stable-opt.sh" | cut -d' ' -f1)" ]] || fail 'installer not given the downloaded files'
  printf 'install\n' >> "$TEST_ROOT/log"
  return "$INSTALL_RC"
}
reset() { : > "$TEST_ROOT/log"; : > "$TEST_ROOT/urls"; FETCH_FAIL=0 ANSWER=1 INSTALL_RC=0; }

reset; release 2.7.0
update_main > /dev/null
grep -Fq '已经是最新版本' "$TEST_ROOT/log" || fail 'same version not reported as up to date'
if grep -q '^ask\|^install' "$TEST_ROOT/log"; then fail 'asked or installed although up to date'; fi
[[ "$(cat "$TEST_ROOT/urls")" == "$UPDATE_BASE_URL/install.sh"$'\n'"$UPDATE_BASE_URL/vps-stable-opt.sh" ]] || fail 'wrong download addresses'

reset; release 2.7.1
update_main > /dev/null
grep -Fq 'ask 现在更新到 2.7.1' "$TEST_ROOT/log" || fail 'newer version not offered'
grep -Fxq install "$TEST_ROOT/log" || fail 'newer version not installed after yes'
grep -Fq '已更新到 2.7.1' "$TEST_ROOT/log" || fail 'update not reported'

reset; ANSWER=0
update_main > /dev/null
if grep -Fxq install "$TEST_ROOT/log"; then fail 'installed although the update was declined'; fi

reset; INSTALL_RC=1
update_main > /dev/null
grep -Fq '更新没有完成' "$TEST_ROOT/log" || fail 'failed installer not reported'

reset; release 2.7.1 badhash
update_main > /dev/null
if grep -q '^ask\|^install' "$TEST_ROOT/log"; then fail 'update offered although the script does not match install.sh'; fi
grep -Fq '对不上' "$TEST_ROOT/log" || fail 'hash mismatch not explained'

reset; release 2.6.9
update_main > /dev/null
if grep -q '^ask\|^install' "$TEST_ROOT/log"; then fail 'older version offered as an update'; fi

reset; FETCH_FAIL=1
update_main > /dev/null
grep -Fq '连不上 GitHub' "$TEST_ROOT/log" || fail 'download failure not explained'
if grep -q '^ask\|^install' "$TEST_ROOT/log"; then fail 'continued after a failed download'; fi
printf 'PASS: update offers only a newer, hash-consistent release and installs it only after yes.\n'
