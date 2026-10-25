#!/usr/bin/env bash
# Installer decision for an existing installation: reuse, in-place upgrade or
# refuse. Only the pure decision function is loaded from install.sh.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
TEST_SCRIPT="$HERE/../install.sh"
load_optimizer_functions install_existing_action
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
old="$(printf 'a%.0s' {1..64})" new="$(printf 'b%.0s' {1..64})" edited="$(printf 'c%.0s' {1..64})"

[[ "$(install_existing_action "$new" "$new" "$new")" == reuse ]] || fail 'same version not reused'
[[ "$(install_existing_action "$old" "$old" "$new")" == upgrade ]] || fail 'intact older version not upgraded'
[[ "$(install_existing_action "$new" "$old" "$new")" == upgrade ]] || fail 'interrupted upgrade (new script, old hash) not finished'
[[ "$(install_existing_action "$edited" "$old" "$new")" == refuse ]] || fail 'hand-edited script would be overwritten'
[[ "$(install_existing_action "$old" 'not-a-hash' "$new")" == refuse ]] || fail 'malformed hash record accepted'
[[ "$(install_existing_action '' "$old" "$new")" == refuse ]] || fail 'missing script hash accepted'
printf 'PASS: installer reuses the same version, upgrades an intact one in place, finishes an interrupted upgrade and refuses edited files.\n'
