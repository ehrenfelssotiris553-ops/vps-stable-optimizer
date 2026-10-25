#!/usr/bin/env bash
# Installer decision for an existing installation: reuse, in-place upgrade or
# refuse. Only the pure decision function is loaded from install.sh.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
TEST_SCRIPT="$HERE/../install.sh"
load_optimizer_functions install_existing_action install_clean_staging
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
old="$(printf 'a%.0s' {1..64})" new="$(printf 'b%.0s' {1..64})" edited="$(printf 'c%.0s' {1..64})"

[[ "$(install_existing_action "$new" "$new" "$new")" == reuse ]] || fail 'same version not reused'
[[ "$(install_existing_action "$old" "$old" "$new")" == upgrade ]] || fail 'intact older version not upgraded'
[[ "$(install_existing_action "$new" "$old" "$new")" == upgrade ]] || fail 'interrupted upgrade (new script, old hash) not finished'
[[ "$(install_existing_action "$edited" "$old" "$new")" == refuse ]] || fail 'hand-edited script would be overwritten'
[[ "$(install_existing_action "$old" 'not-a-hash' "$new")" == refuse ]] || fail 'malformed hash record accepted'
[[ "$(install_existing_action '' "$old" "$new")" == refuse ]] || fail 'missing script hash accepted'
printf 'PASS: installer reuses the same version, upgrades an intact one in place, finishes an interrupted upgrade and refuses edited files.\n'

# Staging files left by a power loss are removed; other files stay. A directory
# left with nothing but staging files and no launcher is removed for a fresh install.
mkdir -p "$T/lib" "$T/bin"
: > "$T/lib/.main.Ab12Cd34"; : > "$T/lib/.sha256.Zz99Yy88"; : > "$T/bin/.vps.Qq11Ww22"; : > "$T/lib/keep.txt"
install_clean_staging "$T/lib" "$T/bin"
[[ ! -e "$T/lib/.main.Ab12Cd34" && ! -e "$T/lib/.sha256.Zz99Yy88" && ! -e "$T/bin/.vps.Qq11Ww22" ]] || fail 'staging files left behind'
[[ -e "$T/lib/keep.txt" ]] || fail 'a file that is not a staging file was removed'
rm -- "$T/lib/keep.txt"; : > "$T/lib/.owner.Mm55Nn66"
install_clean_staging "$T/lib" "$T/bin"
[[ ! -e "$T/lib" ]] || fail 'a directory holding only staging files was not removed'
mkdir "$T/lib2"; : > "$T/bin/vps"
install_clean_staging "$T/lib2" "$T/bin"
[[ -d "$T/lib2" ]] || fail 'install directory removed although the launcher exists'
printf 'PASS: installer clears staging files left by a power loss, and only those.\n'
