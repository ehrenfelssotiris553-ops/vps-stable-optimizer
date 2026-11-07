#!/usr/bin/env bash
# Installer decision for an existing installation: reuse, in-place upgrade or
# refuse. Only the pure decision function is loaded from install.sh.
set -Eeuo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-common.sh"
TEST_SCRIPT="$HERE/../install.sh"
load_optimizer_functions install_existing_action install_clean_staging install_launcher_action
KNOWN_LAUNCHERS="$(sed -n "s/^KNOWN_LAUNCHERS='\(.*\)'$/\1/p" "$TEST_SCRIPT")"
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

# The launcher in place: this version's is kept, an earlier version's (in
# KNOWN_LAUNCHERS) replaced in place, anything else refused.
chmod 755 "$T"
launcher="$T/launcher"
awk '/^cat > "\$TMP_DIR\/launcher" <</ {f = 1; next} f && /^EOF$/ {exit} f' "$TEST_SCRIPT" > "$launcher"
chmod 644 "$launcher"
want="$(sha256sum < "$launcher")"; want="${want%% *}"
[[ "$(install_launcher_action "$want" "$want")" == keep ]] || fail "this version's launcher not kept"
[[ -n "$KNOWN_LAUNCHERS" ]] || fail 'no earlier launchers listed'
for known in $KNOWN_LAUNCHERS; do
  [[ "$(install_launcher_action "$known" "$want")" == replace ]] || fail "an earlier launcher not replaced: $known"
done
[[ "$(install_launcher_action "$edited" "$want")" == refuse ]] || fail 'a launcher edited by hand would be overwritten'
[[ "$(install_launcher_action '' "$want")" == refuse ]] || fail 'a missing launcher hash accepted'
[[ " $KNOWN_LAUNCHERS " != *" $want "* ]] || fail "this version's launcher is listed as an earlier one"
# The launcher of 2.6 to 2.8 is one of them.
v28="$(printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' \
  'if (( $# == 0 )); then set -- menu; fi' 'exec /bin/bash /usr/local/lib/vps-stable-opt/vps-stable-opt.sh "$@"' | sha256sum)"
[[ " $KNOWN_LAUNCHERS " == *" ${v28%% *} "* ]] || fail 'the launcher of 2.8 is not known'
# Anyone but root is told to use sudo (the main script is root's only), with
# the words given; nothing else runs.
runner=()
if ((EUID == 0)); then runner=(setpriv --reuid=65534 --regid=65534 --clear-groups); fi
rc=0; out="$("${runner[@]}" bash "$launcher" item 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == 'vps 需要 root 权限：请用 sudo vps item（root 用户直接输入 vps）。' ]] || fail "not root, with a word: $rc $out"
rc=0; out="$("${runner[@]}" bash "$launcher" 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == 'vps 需要 root 权限：请用 sudo vps（root 用户直接输入 vps）。' ]] || fail "not root: $rc $out"
printf 'PASS: the installer keeps this launcher, replaces a known earlier one and refuses others; it tells anyone but root to use sudo.\n'
