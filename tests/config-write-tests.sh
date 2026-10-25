#!/usr/bin/env bash
# Tests actual configuration publication under command failures, with all paths
# under a private temporary directory. No optimizer entry point is sourced.
set -Eeuo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/test-common.sh"
load_optimizer_functions put_file
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { builtin printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { :; }
warn() { :; }
die() { builtin printf 'STOP: %s\n' "$*" >&2; exit 1; }
backup_config_path() { :; }
record_config_change() { :; }
PAYLOAD=$'managed configuration\nline two'

mkdir -m 700 -- "$TEST_ROOT/private-parent"
put_file "$TEST_ROOT/private-parent/new.conf" "$PAYLOAD"
[[ "$(cat "$TEST_ROOT/private-parent/new.conf")" == "$PAYLOAD" ]] || fail 'fresh configuration content differs'
[[ "$(stat -c %a "$TEST_ROOT/private-parent/new.conf")" == 644 ]] || fail 'fresh configuration mode differs'
[[ "$(stat -c %a "$TEST_ROOT/private-parent")" == 700 ]] || fail 'existing parent directory permissions changed'
chmod 640 -- "$TEST_ROOT/private-parent/new.conf"
put_file "$TEST_ROOT/private-parent/new.conf" "$PAYLOAD"
[[ "$(stat -c %a "$TEST_ROOT/private-parent/new.conf")" == 640 ]] || fail 'matching existing configuration permissions changed'
if put_file "$TEST_ROOT/private-parent/new.conf" different; then fail 'different existing configuration was accepted'; fi
[[ "$(cat "$TEST_ROOT/private-parent/new.conf")" == "$PAYLOAD" ]] || fail 'different existing configuration was overwritten'
ln -s new.conf "$TEST_ROOT/private-parent/link.conf"
if put_file "$TEST_ROOT/private-parent/link.conf" different; then fail 'configuration symlink was accepted'; fi
[[ -L "$TEST_ROOT/private-parent/link.conf" ]] || fail 'configuration symlink was replaced'
builtin printf '%s\n' 'PASS: fresh publication and existing file/link/permission preservation.'

for failure in mktemp printf chmod mv; do
  case_dir="$TEST_ROOT/$failure"
  mkdir -m 700 -- "$case_dir"
  # Actual put_file is deliberately called as an if condition: implicit
  # errexit cannot be relied on anywhere inside that function.
  (
    case "$failure" in
      mktemp) mktemp() { return 28; } ;;
      printf) printf() { if [[ "$1" == '%s\n' && "${2:-}" == "$PAYLOAD" ]]; then return 28; fi; builtin printf "$@"; } ;;
      chmod) chmod() { return 1; } ;;
      mv) mv() { return 1; } ;;
    esac
    if put_file "$case_dir/managed.conf" "$PAYLOAD"; then fail "$failure failure was hidden"; fi
    [[ ! -e "$case_dir/managed.conf" && ! -L "$case_dir/managed.conf" ]] || fail "$failure failure published a configuration"
    [[ -z "$(find "$case_dir" -mindepth 1 -maxdepth 1 -print)" ]] || fail "$failure failure left an incomplete temporary configuration"
  )
done
builtin printf '%s\n' 'PASS: publication failures fail safely even when called from a condition.'

set +e
(
  backup_config_path() { return 73; }
  if put_file "$TEST_ROOT/no-backup.conf" "$PAYLOAD"; then :; fi
  builtin printf 'SHOULD-NOT-RUN\n' > "$TEST_ROOT/no-backup.marker"
) > "$TEST_ROOT/no-backup.output" 2>&1
backup_rc=$?
set -e
[[ "$backup_rc" != 0 && ! -e "$TEST_ROOT/no-backup.marker" && ! -e "$TEST_ROOT/no-backup.conf" ]] || fail 'configuration write continued without mandatory backup'
builtin printf '%s\n' 'PASS: missing configuration protection aborts the caller before publication.'
