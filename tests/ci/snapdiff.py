#!/usr/bin/env python3
"""CI only: compares two snapshot.sh outputs, taken before the install and
after the full rollback and uninstall, and fails on any difference it cannot
explain. Explained are:
- what loading kernel modules leaves (new sysctl keys, more congestion
  control algorithms available);
- package upgrades, which a rollback keeps by design (upgrade-info.sh);
- system users that packages create, and users named with --allow-user;
- volatile kernel counters.
Configuration that removed packages keep ("rc" state, as with apt remove) is
listed as a warning: it is not the tool's own file, but it is left behind.

Usage: snapdiff.py BEFORE AFTER [--upgrades FILE] [--allow-user NAME]...
"""
import argparse
import re
import sys

VOLATILE = re.compile(
    r'^(kernel\.random\.|fs\.(dentry-state|file-nr|inode-nr|inode-state|aio-nr)$|fs\.quota\.'
    r'|kernel\.ns_last_pid$|kernel\.pty\.nr$|net\.netfilter\.nf_conntrack_count$'
    r'|kernel\.perf_event_max_sample_rate$|net\.core\.netdev_rss_key$)')
KERNEL_PKG = re.compile(r'^linux-(image|modules|modules-extra|headers|tools|cloud-tools)-')
CC_KEYS = ('net.ipv4.tcp_available_congestion_control', 'net.ipv4.tcp_allowed_congestion_control')
USER_FILES = {'/etc/' + f + s for f in ('passwd', 'group', 'shadow', 'gshadow', 'subuid', 'subgid')
              for s in ('', '-')}
ALWAYS_EXPLAINED = {'/etc/ld.so.cache'}
# What `ufw disable` and removing UFW leave in the kernel until a reboot: empty
# ufw chains, plain jumps into them and accept policies. They filter nothing
# (the tool itself treats them as no firewall); any other rule fails.
INERT_FIREWALL = re.compile(
    r'^(\*(filter|nat|mangle|raw|security)|COMMIT'
    r'|:(INPUT|FORWARD|OUTPUT|PREROUTING|POSTROUTING) ACCEPT \[0:0\]'
    r'|:ufw6?-[a-z-]+ - \[0:0\]|-A (INPUT|FORWARD|OUTPUT) -j ufw6?-[a-z-]+'
    r'|#.*|\}|table (ip|ip6|inet) filter \{|chain [A-Za-z0-9_-]+ \{'
    r'|type filter hook (input|forward|output) priority filter; policy accept;'
    r'|(counter )?jump ufw6?-[a-z-]+)$')


def load(path):
    snap = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            kind, _, rest = line.partition(' ')
            snap.setdefault(kind, []).append(rest)
    return snap


def pairs(snap, kind, sep):
    out = {}
    for rest in snap.get(kind, []):
        key, _, value = rest.partition(sep)
        out[key] = value
    return out


def files(snap):
    out = {}
    for rest in snap.get('file', []):
        path, _, digest = rest.rpartition(' ')
        out[path] = digest
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('before')
    ap.add_argument('after')
    ap.add_argument('--upgrades')
    ap.add_argument('--allow-user', action='append', default=[])
    args = ap.parse_args()
    a, b = load(args.before), load(args.after)
    up = load(args.upgrades) if args.upgrades else {}
    up_pkgs, up_files = set(up.get('upgradepkg', [])), set(up.get('upgradefile', []))
    unexplained, explained, warnings = [], [], []

    # Kernel parameters.
    sa, sb = pairs(a, 'sysctl', ' = '), pairs(b, 'sysctl', ' = ')
    for key in sorted(set(sa) | set(sb)):
        if VOLATILE.match(key) or sa.get(key) == sb.get(key):
            continue
        if key not in sa:
            explained.append(f'new kernel parameter (module loaded): {key} = {sb[key]}')
        elif key not in sb:
            unexplained.append(f'kernel parameter gone: {key} (was {sa[key]})')
        elif key in CC_KEYS and set(sa[key].split()) <= set(sb[key].split()):
            explained.append(f'{key}: {sa[key]} -> {sb[key]} (module loaded)')
        else:
            unexplained.append(f'kernel parameter changed: {key}: {sa[key]} -> {sb[key]}')

    # Packages.
    pa, pb = set(a.get('pkg', [])), set(b.get('pkg', []))
    for name in sorted(pb - pa):
        (explained if name in up_pkgs or KERNEL_PKG.match(name) else unexplained).append(f'package installed: {name}')
    for name in sorted(pa - pb):
        (explained if name in up_pkgs or KERNEL_PKG.match(name) else unexplained).append(f'package removed: {name}')
    rc_new = sorted(set(b.get('pkgconf', [])) - set(a.get('pkgconf', [])))
    rc_files = set(b.get('rcfile', []))
    if rc_new:
        warnings.append('removed packages keep their configuration (apt remove, not purge): ' + ' '.join(rc_new))

    # Users.
    ua, ub = pairs(a, 'user', ' '), pairs(b, 'user', ' ')
    users_ok = True
    for name in sorted(set(ub) - set(ua)):
        uid = int(ub[name]) if ub[name].isdigit() else 65534
        if name in args.allow_user:
            explained.append(f'user kept by design: {name}')
        elif uid < 1000:
            warnings.append(f'system user a package created stays: {name} ({uid})')
        else:
            users_ok = False
            unexplained.append(f'user added: {name} ({uid})')
    for name in sorted(set(ua) - set(ub)):
        users_ok = False
        unexplained.append(f'user removed: {name}')
    users_changed = set(ua) != set(ub)

    # Files, links and directories under /etc.
    fa, fb = files(a), files(b)
    dangling = set(b.get('dangling', [])) - set(a.get('dangling', []))
    rc_dirs = {p.rsplit('/', i)[0] for p in rc_files for i in range(1, p.count('/'))}
    for path in sorted(set(fa) | set(fb)):
        if fa.get(path) == fb.get(path):
            continue
        what = 'file added' if path not in fa else 'file removed' if path not in fb else 'file changed'
        if path in ALWAYS_EXPLAINED or path in up_files:
            explained.append(f'{what}: {path}')
        elif path in USER_FILES and users_changed and users_ok:
            explained.append(f'{what}: {path} (users above)')
        elif what == 'file added' and path in rc_files:
            continue  # listed with the package warning
        else:
            unexplained.append(f'{what}: {path}')
    la, lb = pairs(a, 'link', ' -> '), pairs(b, 'link', ' -> ')
    for path in sorted(set(la) | set(lb)):
        if la.get(path) == lb.get(path):
            continue
        if path not in la and path in dangling and path.startswith('/etc/systemd/system/'):
            warnings.append(f'enablement link of a removed package stays (dangling): {path}')
        elif path in up_files:
            explained.append(f'link changed: {path}')
        else:
            unexplained.append(f'link: {path}: {la.get(path, "(none)")} -> {lb.get(path, "(none)")}')
    da, db = set(a.get('dir', [])), set(b.get('dir', []))
    for path in sorted(db - da):
        if path in up_files:
            explained.append(f'directory added: {path}')
        elif path in rc_dirs:
            continue
        else:
            unexplained.append(f'directory added: {path}')
    for path in sorted(da - db):
        (explained if path in up_files else unexplained).append(f'directory removed: {path}')

    # Everything else must be exactly as before.
    ua_units, ub_units = pairs(a, 'unit', ' '), pairs(b, 'unit', ' ')
    for name in sorted(set(ua_units) | set(ub_units)):
        if ua_units.get(name) != ub_units.get(name):
            unexplained.append(f'unit {name}: {ua_units.get(name, "(none)")} -> {ub_units.get(name, "(none)")}')
    inert = []
    for kind in ('nft', 'iptables-save', 'ip6tables-save'):
        left = set(b.get(kind, [])) - set(a.get(kind, []))
        if left and all(INERT_FIREWALL.match(x) for x in left):
            inert.append(kind)
            a[kind] = b.get(kind, [])
    if inert:
        warnings.append("UFW's empty chains (they filter nothing) stay until a reboot: " + ' '.join(inert))
    for kind, label in (('local', 'tool path'), ('cron', 'root crontab'), ('nft', 'nft rule'),
                        ('iptables-save', 'iptables rule'), ('ip6tables-save', 'ip6tables rule'),
                        ('swap', 'swap'), ('vpsunit', 'tool unit')):
        sa_k, sb_k = set(a.get(kind, [])), set(b.get(kind, []))
        unexplained += [f'{label} left: {x}' for x in sorted(sb_k - sa_k)]
        unexplained += [f'{label} gone: {x}' for x in sorted(sa_k - sb_k)]

    for line in explained:
        print('explained:', line)
    for line in warnings:
        print('warning:', line)
        print('::warning::left after rollback and uninstall: ' + line)
    if unexplained:
        print(f'UNEXPLAINED differences after rollback and uninstall ({len(unexplained)}):')
        for line in unexplained:
            print('  ' + line)
        return 1
    print(f'Snapshot matches the one before the install ({len(explained)} explained differences, {len(warnings)} warnings).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
