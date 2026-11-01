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
With --purged (the tool recorded the packages' state before its first run, so
it purges what it installed) any such configuration is a difference instead.

Usage: snapdiff.py BEFORE AFTER [--upgrades FILE] [--allow-user NAME]... [--purged]
"""
import argparse
import re
import sys

VOLATILE = re.compile(
    r'^(kernel\.random\.|fs\.(dentry-state|file-nr|inode-nr|inode-state|aio-nr)$|fs\.quota\.'
    r'|kernel\.ns_last_pid$|kernel\.pty\.nr$|net\.netfilter\.nf_conntrack_count$'
    r'|kernel\.perf_event_max_sample_rate$|net\.core\.netdev_rss_key$|net\.ipv4\.tcp_fastopen_key$'
    # A container's virtual interface gets a new name whenever it starts.
    r'|net\.ipv[46]\.(conf|neigh)\.veth[0-9a-f]+\.)')
KERNEL_PKG = re.compile(r'^linux-(image|modules|modules-extra|headers|tools|cloud-tools)-')
# Lists that grow when a module loads: congestion control, upper layer protocols.
CC_KEYS = ('net.ipv4.tcp_available_congestion_control', 'net.ipv4.tcp_allowed_congestion_control',
           'net.ipv4.tcp_available_ulp')
# What the tool itself sets: compared even across a kernel change.
TOOL_KEYS = re.compile(r'^(net\.ipv[46]\.conf\.|net\.ipv4\.(tcp_congestion_control|tcp_syncookies|icmp_)'
                       r'|net\.core\.(default_qdisc|rmem_max|wmem_max)|vm\.(swappiness|page-cluster)'
                       r'|kernel\.(kptr_restrict|dmesg_restrict))')
# Defaults the kernel works out from the free memory at boot: after a reboot
# they move a little (a wrong restore moves them a lot).
MEMORY_KEYS = re.compile(r'^(net\.ipv4\.(tcp_mem|udp_mem|tcp_rmem|tcp_wmem|inet_peer_threshold)'
                         r'|vm\.(user_reserve_kbytes|admin_reserve_kbytes|min_free_kbytes)'
                         r'|kernel\.threads-max|fs\.epoll\.max_user_watches|fs\.file-max)$')
# Kept up to date by the maintainer scripts of packages, not as their files.
PKG_SCRIPT_FILES = {'/etc/shells': None, '/etc/ca-certificates.conf': 'ca-certificates',
                    '/etc/ca-certificates.conf.dpkg-old': 'ca-certificates'}


def close(x, y, share=0.02):
    """Every number of x within SHARE of y's (the same count of numbers)."""
    try:
        xs, ys = [int(v) for v in x.split()], [int(v) for v in y.split()]
    except ValueError:
        return False
    return len(xs) == len(ys) and all(abs(i - j) <= share * max(abs(i), abs(j), 1) for i, j in zip(xs, ys))


# A loaded logging module fills in its slot ("NONE" before).
NF_LOG = re.compile(r'^net\.netfilter\.nf_log\.[0-9]+$')
# The layout UFW writes into user.rules/user6.rules the first time it starts:
# chain declarations, logging and rate-limit chains. Rules that let traffic
# in or out live in ufw-user-input/output/forward and are never covered here.
UFW_LAYOUT = re.compile(
    r'^(|\*filter|COMMIT|:ufw6?-[a-z-]+ - \[0:0\]'
    r'|-[AI] ufw6?-((after|before|user)-logging-(input|output|forward)|logging-(allow|deny)|user-limit(-accept)?) .*)$')
# snapd mounts each snap revision it refreshes to as a unit of its own, and
# writes services and udev rules for the snaps.
SNAPD = re.compile(r'^(/etc/systemd/system/((snapd\.mounts|multi-user)\.target\.wants/)?)?snap[-.].*\.(mount|service)$'
                   r'|^/etc/systemd/system/snapd\.mounts\.target\.wants$|^/etc/udev/rules\.d/70-snap\.')
# Directories a removed package's leftovers may not explain anything in.
SHARED_RC_DIRS = {'/etc', '/etc/default', '/etc/sysctl.d', '/etc/apt/apt.conf.d', '/etc/systemd', '/etc/systemd/system',
                  '/etc/ssh', '/etc/ssh/sshd_config.d', '/etc/init.d', '/etc/logrotate.d', '/etc/cron.d'}
SHARED_DIRS = {'/etc', '/etc/sysctl.d', '/etc/apt/apt.conf.d', '/etc/ssh/sshd_config.d', '/etc/systemd/system',
               '/etc/systemd/journald.conf.d', '/etc/default', '/etc/fail2ban/jail.d', '/etc/fail2ban/action.d',
               '/etc/ufw', '/etc/modules-load.d', '/etc/systemd'}
# Rebuilt by package triggers whenever packages come or go.
TRIGGERED = {'/etc/mailcap'}
# update-ca-certificates rebuilds these whenever ca-certificates is upgraded;
# the links belong to no package.
CERTS = re.compile(r'^/etc/ssl/certs/')
# Start/stop links of a SysV script that a removed package keeps.
RC_LINK = re.compile(r'^/etc/rc[0-6S]\.d/[SK][0-9]+(.+)$')
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
    r'|(counter )?jump ufw6?-[a-z-]+|)$')  # (and the blank lines of nft's listing)


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
    ap.add_argument('--purged', action='store_true')
    args = ap.parse_args()
    a, b = load(args.before), load(args.after)
    up = load(args.upgrades) if args.upgrades else {}
    up_pkgs, up_files = set(up.get('upgradepkg', [])), set(up.get('upgradefile', []))
    # A real system upgrade (apt upgrade, unattended-upgrade) ran, not only
    # dependencies brought up to date by an install.
    system_upgrade = bool(up.get('systemupgrade'))
    unexplained, explained, warnings = [], [], []

    # Kernel parameters. After a reboot into a newer kernel its own defaults
    # (from memory sizes, its version) differ; the network settings the tool
    # changes do not, so those are still compared.
    sa, sb = pairs(a, 'sysctl', ' = '), pairs(b, 'sysctl', ' = ')
    new_kernel = sa.get('kernel.osrelease') != sb.get('kernel.osrelease')
    rebooted = sa.get('kernel.random.boot_id') != sb.get('kernel.random.boot_id')
    if new_kernel:
        explained.append(f"kernel {sa.get('kernel.osrelease')} -> {sb.get('kernel.osrelease')} after the reboot")
    for key in sorted(set(sa) | set(sb)):
        if VOLATILE.match(key) or sa.get(key) == sb.get(key):
            continue
        if new_kernel and not TOOL_KEYS.match(key):
            continue
        if rebooted and key in sa and key in sb:
            if MEMORY_KEYS.match(key) and close(sa[key], sb[key]):
                explained.append(f'{key}: {sa[key]} -> {sb[key]} (worked out from memory at boot)')
                continue
            if key in CC_KEYS:
                explained.append(f'{key}: {sa[key]} -> {sb[key]} (other modules loaded in this boot)')
                continue
        if key not in sa:
            explained.append(f'new kernel parameter (module loaded): {key} = {sb[key]}')
        elif key not in sb:
            unexplained.append(f'kernel parameter gone: {key} (was {sa[key]})')
        elif key in CC_KEYS and set(sa[key].split()) <= set(sb[key].split()):
            explained.append(f'{key}: {sa[key]} -> {sb[key]} (module loaded)')
        elif NF_LOG.match(key) and sa[key] == 'NONE':
            explained.append(f'{key}: NONE -> {sb[key]} (logging module loaded)')
        else:
            unexplained.append(f'kernel parameter changed: {key}: {sa[key]} -> {sb[key]}')

    # Packages.
    pa, pb = set(a.get('pkg', [])), set(b.get('pkg', []))
    auto_b = set(b.get('autopkg', []))
    for name in sorted(pb - pa):
        if name in up_pkgs or KERNEL_PKG.match(name):
            explained.append(f'package installed: {name}')
        elif name in auto_b:
            # Removing the tool's packages skips autoremove when it would also
            # take packages the tool did not install.
            warnings.append(f'dependency installed with a tool package stays (marked automatic): {name}')
        else:
            unexplained.append(f'package installed: {name}')
    for name in sorted(pa - pb):
        (explained if name in up_pkgs or KERNEL_PKG.match(name) else unexplained).append(f'package removed: {name}')
    rc_new = sorted(set(b.get('pkgconf', [])) - set(a.get('pkgconf', [])))
    rc_files = set(b.get('rcfile', []))
    if rc_new and args.purged:
        unexplained += [f'configuration left by a removed package (the tool purges): {name}' for name in rc_new]
    elif rc_new:
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

    # UFW's stored rules: only its own layout may differ.
    ufw_left = set(b.get('ufwrule', [])) ^ set(a.get('ufwrule', []))
    ufw_layout_only = bool(ufw_left) and all(UFW_LAYOUT.match(x.partition(': ')[2]) for x in ufw_left)
    if ufw_layout_only:
        warnings.append('UFW rewrote user.rules/user6.rules in its own layout (logging and limit chains); none of the tool\'s rules are left')
        a['ufwrule'] = b.get('ufwrule', [])

    # Units (compared further down; the links below need them too).
    ua_units, ub_units = pairs(a, 'unit', ' '), pairs(b, 'unit', ' ')
    up_units = set(up.get('upgradeunit', []))
    # Units their own service switched off (upgrade-info.sh read it in the journal).
    self_disabled = set(up.get('selfdisabled', []))

    # Files, links and directories under /etc.
    fa, fb = files(a), files(b)
    dangling = set(b.get('dangling', [])) - set(a.get('dangling', []))
    rc_dirs = {p.rsplit('/', i)[0] for p in rc_files for i in range(1, p.count('/'))}
    # Directories of upgraded packages, but never the shared drop-in ones the
    # tool writes into, and never a file of the tool itself.
    up_dirs = {p.rsplit('/', 1)[0] for p in up_files} - SHARED_DIRS
    for path in sorted(set(fa) | set(fb)):
        if fa.get(path) == fb.get(path) or SNAPD.match(path):
            continue
        what = 'file added' if path not in fa else 'file removed' if path not in fb else 'file changed'
        if path in PKG_SCRIPT_FILES and up_pkgs and (PKG_SCRIPT_FILES[path] is None or PKG_SCRIPT_FILES[path] in up_pkgs):
            explained.append(f'{what}: {path} (kept by package scripts during upgrades)')
            continue
        if (system_upgrade and what == 'file removed' and 'vps-stable' not in path
                and path.rsplit('/', 1)[0] not in SHARED_DIRS):
            explained.append(f'{what}: {path} (dropped by the system upgrade)')
            continue
        if up_pkgs and 'vps-stable' not in path and (path in TRIGGERED or path.rsplit('/', 1)[0] in up_dirs):
            explained.append(f'{what}: {path} (package upgrades)')
            continue
        if path in ALWAYS_EXPLAINED or path in up_files or (CERTS.match(path) and 'ca-certificates' in up_pkgs):
            explained.append(f'{what}: {path}')
        elif ufw_layout_only and path in ('/etc/ufw/user.rules', '/etc/ufw/user6.rules'):
            explained.append(f'{what}: {path} (UFW layout, see the warning)')
        elif path in USER_FILES and users_changed and users_ok:
            explained.append(f'{what}: {path} (users above)')
        elif path in USER_FILES and path.endswith('-') and fa.get(path[:-1]) == fb.get(path[:-1]):
            # useradd/userdel keep the previous copy: a package that added its
            # system user and removed it again with its purge (vnstat).
            explained.append(f'{what}: {path} (backup copy; {path[:-1]} itself is exactly as before)')
        elif what in ('file added', 'file changed') and path in rc_files:
            continue  # listed with the package warning
        elif what == 'file added' and path.rsplit('/', 1)[0] in rc_dirs - SHARED_RC_DIRS:
            continue  # in the configuration directory a removed package keeps
        else:
            unexplained.append(f'{what}: {path}')
    la, lb = pairs(a, 'link', ' -> '), pairs(b, 'link', ' -> ')
    for path in sorted(set(la) | set(lb)):
        if la.get(path) == lb.get(path):
            continue
        rc_link = RC_LINK.match(path)
        unit = path.rsplit('/', 1)[-1]
        if SNAPD.match(path):
            continue
        if path in la and path not in lb and unit in self_disabled:
            explained.append(f'enablement link its own service took away (journal): {path}')
            continue
        if system_upgrade and path.startswith('/etc/alternatives/'):
            explained.append(f'alternative set by a package of the system upgrade: {path}')
            continue
        if (system_upgrade and re.match(r'^/etc/systemd/system/[^/]+\.(wants|requires)/', path)
                and (unit in up_units or (unit in ua_units) != (unit in ub_units))):
            explained.append(f'enablement link of a unit the system upgrade changed: {path}')
            continue
        if CERTS.match(path) and 'ca-certificates' in up_pkgs:
            explained.append(f'certificate link rebuilt by the ca-certificates upgrade: {path}')
            continue
        if (path not in la and lb.get(path) == '/dev/null' and path.startswith('/etc/systemd/system/')
                and unit.rsplit('.', 1)[0] in set(b.get('pkgconf', []))):
            continue  # the mask of a removed package's service, warned with the unit
        if path not in la and path in dangling and path.startswith('/etc/systemd/system/'):
            warnings.append(f'enablement link of a removed package stays (dangling): {path}')
        elif path not in la and rc_link and '/etc/init.d/' + rc_link.group(1) in rc_files:
            warnings.append(f'start/stop link of a removed package stays: {path}')
        elif (path == '/etc/localtime' and path in la and path in lb
              and la[path].split('zoneinfo/')[-1] == lb[path].split('zoneinfo/')[-1]):
            explained.append(f'/etc/localtime: same zone, link written differently ({la[path]} -> {lb[path]})')
        elif path in up_files:
            explained.append(f'link changed: {path}')
        else:
            unexplained.append(f'link: {path}: {la.get(path, "(none)")} -> {lb.get(path, "(none)")}')
    da, db = set(a.get('dir', [])), set(b.get('dir', []))
    for path in sorted(db - da):
        if SNAPD.match(path):
            continue
        if path in up_files:
            explained.append(f'directory added: {path}')
        elif path in rc_dirs:
            continue
        else:
            unexplained.append(f'directory added: {path}')
    for path in sorted(da - db):
        (explained if path in up_files else unexplained).append(f'directory removed: {path}')

    # Everything else must be exactly as before.
    rc_pkgs = set(b.get('pkgconf', []))
    for name in sorted(set(ua_units) | set(ub_units)):
        if 'transient' in (ua_units.get(name), ub_units.get(name)) or SNAPD.match(name):
            continue  # login sessions and snapd's own mounts come and go
        if ua_units.get(name) != ub_units.get(name):
            if name in self_disabled and (ua_units.get(name), ub_units.get(name)) == ('enabled', 'disabled'):
                explained.append(f'unit {name}: enabled -> disabled (by its own service, see the journal)')
                continue
            if name in up_units:
                explained.append(f'unit {name}: {ua_units.get(name, "(none)")} -> {ub_units.get(name, "(none)")} (its package was upgraded)')
                continue
            if up_pkgs and (name not in ua_units or name not in ub_units):
                explained.append(f'unit {name}: {ua_units.get(name, "(none)")} -> {ub_units.get(name, "(none)")} (package upgrades)')
                continue
            # Removing a package whose SysV script stays masks its service, or
            # systemd generates a unit from that script.
            if ub_units.get(name) in ('masked', 'generated') and name not in ua_units and name.rsplit('.', 1)[0] in rc_pkgs:
                warnings.append(f'a unit for the SysV script of a removed package ({ub_units[name]}): {name}')
                continue
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
                        ('swap', 'swap'), ('vpsunit', 'tool unit'), ('ufwrule', 'stored UFW rule')):
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
