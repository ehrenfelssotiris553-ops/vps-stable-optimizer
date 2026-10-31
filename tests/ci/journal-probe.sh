#!/usr/bin/env bash
# CI only, as root on the machine under test, with the tool installed: the
# health report's journal query, run through the tool's own patterns
# (audit_journal_counts), printing each line it counts. A fresh cloud machine
# has no out-of-memory, storage or crash lines and a readable journal, so any
# count fails: that would be a false alarm for every user of such a machine.
set -Eeuo pipefail
script=/usr/local/lib/vps-stable-opt/vps-stable-opt.sh
definition="$(awk '$0 == "audit_journal_counts() {" {copy = 1} copy {print} copy && $0 == "}" {exit}' "$script")"
[[ -n "$definition" ]] || { echo 'audit_journal_counts not found in the installed tool'; exit 1; }
# Each count also prints the line it counts ($0 belongs to awk).
# shellcheck disable=SC2016
eval "$(sed -E 's/\) (access_issue|oom|io|crash)\+\+/) {\1++; print "\1: " $0}/' <<< "$definition")"
out="$(journalctl --system -b 0 --since '-24 hours' -n 1000 --no-pager -o cat 2>&1 | LC_ALL=C audit_journal_counts)"
counted="$(grep -E '^(access_issue|oom|io|crash): ' <<< "$out" || true)"
read -r scanned oom io crash access _ <<< "$(tail -n 1 <<< "$out")"
printf 'scanned %s, out of memory %s, storage %s, crash %s, access %s\n' "$scanned" "$oom" "$io" "$crash" "$access"
if [[ -n "$counted" ]]; then head -n 20 <<< "$counted"; fi
((scanned > 0 && oom + io + crash + access == 0))
