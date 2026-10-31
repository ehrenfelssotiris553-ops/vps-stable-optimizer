#!/usr/bin/env bash
# CI only, as root on the machine under test: what the health report's journal
# query really returns, and which lines its patterns count. On fresh cloud
# machines a count above zero, or "empty or access hint", is suspect.
set -Eeuo pipefail
out="$(journalctl --system -b 0 --since '-24 hours' -n 1000 --no-pager -o cat 2>&1 || true)"
printf 'journal lines: %s\n' "$(grep -c '' <<< "$out" || true)"
printf 'first lines:\n%s\n' "$(head -n 3 <<< "$out")"
awk '
  {line = tolower(substr($0, 1, 1024))}
  line ~ /^hint:|^no journal files|^-- no entries --$|^failed to open|^you are currently not seeing|^insufficient permissions|^no entries were found/ {print "access: " $0}
  line ~ /out of memory:|oom-kill:|oom_reaper:|memory cgroup out of memory|killed process [0-9]+|invoked oom-killer/ {print "oom: " $0}
  line ~ /i\/o error|buffer i\/o|blk_update_request:.*error|blk_print_req_error:|ext4-fs error|xfs.*(corrupt|i\/o error)|btrfs.*(error|corrupt)|nvme.*(i\/o|timeout)/ {print "io: " $0}
  line ~ /kernel panic|not syncing:|watchdog.*(lockup|locked up)|soft lockup|hard lockup|unclean shutdown|uncleanly shut down|not cleanly shut down/ {print "crash: " $0}
' <<< "$out" | head -n 20
