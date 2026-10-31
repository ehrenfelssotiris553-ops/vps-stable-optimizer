#!/usr/bin/env bash
# CI only, after a push to main: what a user gets from GitHub. First waits
# until raw.githubusercontent.com serves this commit (it caches for minutes);
# then `vps update` from the previous release to this one, and the install
# command exactly as the README gives it (curl, and the wget variant).
set -Eeuo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
source "$ROOT/tests/ci/lib.sh"
version="$(sed -n 's/^SCRIPT_VERSION=//p' "$ROOT/vps-stable-opt.sh")"
raw="$(sed -n "s/^RELEASE_BASE_URL='\\(.*\\)'$/\\1/p" "$ROOT/install.sh")"
[[ "$raw" == https://raw.githubusercontent.com/* ]] || fail "unexpected RELEASE_BASE_URL: $raw"

group 'GitHub serves this commit'
want="$(sha256sum < "$ROOT/vps-stable-opt.sh" | cut -d' ' -f1)" got=''
for ((i = 0; i < 40; i++)); do
  got="$(curl -fsSL "$raw/vps-stable-opt.sh" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
  [[ "$got" == "$want" ]] && break
  sleep 15
done
[[ "$got" == "$want" ]] || fail 'raw.githubusercontent.com still serves another version after 10 minutes'
endgroup

group 'vps update: from the previous release to this one'
previous="$(previous_release "$version")" || fail 'no previous release on origin/main'
read -r old_commit old_version <<< "$previous"
git -C "$ROOT" show "$old_commit:install.sh" > "$LOGS/old-install.sh"
git -C "$ROOT" show "$old_commit:vps-stable-opt.sh" > "$LOGS/old-vps-stable-opt.sh"
sudo bash "$LOGS/old-install.sh" --local-file "$LOGS/old-vps-stable-opt.sh" --no-run
[[ "$(sudo vps --version)" == "$old_version" ]] || fail "the previous release $old_version is not installed"
drive update.rules update sudo vps update || fail "update exited with $?"
has update "已更新到 $version"
[[ "$(sudo vps --version)" == "$version" ]] || fail "vps update did not install $version"
drive update.rules update-again sudo vps update || fail "second update exited with $?"
has update-again '已经是最新版本，不需要更新'
drive uninstall.rules uninstall-1 sudo vps uninstall || fail "uninstall exited with $?"
endgroup

group "The README's install command"
command="$(grep -m1 -o 'curl -fsSLO https://[^ ]*/install\.sh && bash install\.sh' "$ROOT/README.md")" ||
  fail 'the curl install command is not in the README any more'
url="${command#curl -fsSLO }" url="${url%% *}"
[[ "$url" == "$raw/install.sh" ]] || fail "the README downloads $url, the installer uses $raw"
work="$(mktemp -d)"
(cd "$work" && curl -fsSLO "$url" && sudo bash install.sh --no-run)
[[ "$(sudo vps --version)" == "$version" ]] || fail 'the README command did not install this version'
wget_url="$(grep -m1 -o 'wget -qO install\.sh https://[^ ]*/install\.sh' "$ROOT/README.md")" ||
  fail 'the wget install command is not in the README any more'
(cd "$work" && wget -qO install-wget.sh "${wget_url##* }" && cmp install.sh install-wget.sh) ||
  fail 'the wget command gets another installer'
drive uninstall.rules uninstall-2 sudo vps uninstall || fail "uninstall exited with $?"
endgroup
printf 'PASS: GitHub serves %s; update from %s and the README install command work.\n' "$version" "$old_version"
