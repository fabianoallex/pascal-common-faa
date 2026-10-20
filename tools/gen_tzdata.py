"""Builds the embedded tzdb (src/PascalCommon.TimeZones.Data.pas) and the
golden file its tests check against (tests/Unit/golden/
tzdata-golden.txt) from an IANA tzdata release.

Why from IANA and not from a system: measured 2026-10-20 (docs/
timezones-design.md), Debian 12 and 13 images carried 2026b and 2026c while
IANA was at 2026e, Debian 13 drops the backward names, Alpine has none and
Windows' ICU is 2022g. The release's own text files compiled with zic are the
source of truth.

Steps:
  1. download tzdata<release>.tar.gz from data.iana.org into .ci/tzdata
     (or take --tarball), print its SHA-512 and, when gpg is on the PATH,
     check the .asc signature (IANA's key must already be in the keyring);
  2. compile it with `zic -b slim` in a debian:13-slim container (zic and
     zdump are in libc-bin) and dump every zone's transitions 1970-2040 with
     zdump, which reads the files with glibc's code, not ours;
  3. read the compiled tree here and write the Pascal data unit: each zone's
     TZif bytes exactly as zic wrote them (identical contents stored once),
     the zone names, the links and their targets;
  4. write the golden file: zdump's transitions, and Python zoneinfo's
     offsets at fixed instants for every name, and its fold=0/fold=1 answers
     for a local reading inside each gap and overlap 2010-2040. Two readers
     that aren't ours; the script stops when they disagree with each other.

The test suite then checks the Pascal reader against the golden file on
every target (PascalCommon.TimeZonesTests, Golden_*).

Usage: python tools/gen_tzdata.py --release 2026e
       python tools/gen_tzdata.py --tarball path/to/tzdata2026e.tar.gz
       [--image debian:13-slim]
"""
import argparse
import datetime as dt
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zoneinfo
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / '.ci' / 'tzdata'
DATA_UNIT = ROOT / 'src' / 'PascalCommon.TimeZones.Data.pas'
GOLDEN_FILE = ROOT / 'tests' / 'Unit' / 'golden' / 'tzdata-golden.txt'
SOURCES = ['africa', 'antarctica', 'asia', 'australasia', 'europe', 'northamerica',
           'southamerica', 'etcetera', 'backward']
URL = 'https://data.iana.org/time-zones/releases/tzdata{0}.tar.gz'

UTC = dt.timezone.utc
# Instants checked for every name: the past before most zones' first
# transition, both halves of several years, and the far future (the footer).
SAMPLE_INSTANTS = [int(dt.datetime(y, m, 1, 12, tzinfo=UTC).timestamp())
                   for y in (1850, 1900, 1920, 1945, 1950, 1970, 1980, 1990, 2000, 2010,
                             2019, 2020, 2026, 2027, 2038, 2050, 2100, 2400)
                   for m in (1, 7)]
TRANSITION_YEARS = (1970, 2041)   # zdump's -c: [1970, 2041)
MAPPING_FROM = int(dt.datetime(2010, 1, 1, tzinfo=UTC).timestamp())


def fail(msg):
    print('gen_tzdata: ' + msg, file=sys.stderr)
    sys.exit(1)


def fetch(release):
    WORK.mkdir(parents=True, exist_ok=True)
    tarball = WORK / ('tzdata%s.tar.gz' % release)
    if not tarball.exists():
        print('downloading', URL.format(release))
        urllib.request.urlretrieve(URL.format(release), tarball)
    asc = WORK / ('tzdata%s.tar.gz.asc' % release)
    if shutil.which('gpg'):
        if not asc.exists():
            urllib.request.urlretrieve(URL.format(release) + '.asc', asc)
        r = subprocess.run(['gpg', '--verify', str(asc), str(tarball)], capture_output=True, text=True)
        print('gpg --verify:', 'good' if r.returncode == 0 else 'NOT VERIFIED (' + r.stderr.strip().splitlines()[-1] + ')')
    else:
        print('gpg not found: signature not checked')
    return tarball


def extract(tarball):
    data = tarball.read_bytes()
    print('SHA-512', hashlib.sha512(data).hexdigest())
    dest = WORK / (tarball.name.replace('.tar.gz', ''))
    if dest.exists():
        shutil.rmtree(dest)
    (dest / 'src').mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        tf.extractall(dest / 'src', filter='data')
    version = (dest / 'src' / 'version').read_text().strip()
    return dest, version


def parse_sources(src):
    zones, links = [], {}
    for name in SOURCES:
        for line in (src / name).read_text(encoding='utf-8').splitlines():
            line = line.split('#', 1)[0]
            fields = line.split()
            if not fields:
                continue
            if fields[0] == 'Zone':
                zones.append(fields[1])
            elif fields[0] == 'Link':
                links[fields[2]] = fields[1]
    for link in links:   # resolve chains
        seen = set()
        while links[link] in links:
            if link in seen:
                fail('link loop at ' + link)
            seen.add(link)
            links[link] = links[links[link]]
    for link, target in links.items():
        if target not in zones:
            fail('link %s -> %s: no such zone' % (link, target))
    return sorted(set(zones)), dict(sorted(links.items()))


def compile_and_dump(dest, zones, image):
    out = dest / 'out'
    if out.exists():
        shutil.rmtree(out)
    mount = str(dest)
    zone_list = ' '.join(zones)
    script = (
        'set -e; cd /w/src; zic -b slim -d /w/out %s; '
        'for z in %s; do zdump -v -c %d,%d /w/out/$z; done > /w/zdump.txt'
        % (' '.join(SOURCES), zone_list, TRANSITION_YEARS[0], TRANSITION_YEARS[1]))
    env = dict(os.environ, MSYS_NO_PATHCONV='1')
    subprocess.run(['docker', 'run', '--rm', '-v', mount + ':/w', image, 'sh', '-c', script],
                   check=True, env=env)
    return out, dest / 'zdump.txt'


ZDUMP_RE = re.compile(r'^/w/out/(\S+)\s+\w{3} (\w{3})\s+(\d+) (\d\d:\d\d:\d\d) (-?\d+) UT = .* isdst=\d gmtoff=(-?\d+)$')


def parse_zdump(path):
    entries = {}
    for line in path.read_text().splitlines():
        m = ZDUMP_RE.match(line)
        if not m:
            continue
        name, mon, day, hms, year, off = m.groups()
        if not 1 <= int(year) <= 9999:
            continue   # zdump's own boundary lines (years +-2147481748)
        t = dt.datetime.strptime('%s %s %s %s' % (year, mon, day, hms), '%Y %b %d %H:%M:%S')
        entries.setdefault(name, []).append((int(t.replace(tzinfo=UTC).timestamp()), int(off)))
    transitions = {}
    for name, items in entries.items():
        items.sort()
        tr = []
        for (t1, o1), (t2, o2) in zip(items, items[1:]):
            if t2 - t1 == 1 and o1 != o2:
                tr.append((t2, o1, o2))
        transitions[name] = tr
    return transitions


def py_zone(out, name):
    with open(out / name, 'rb') as f:
        return zoneinfo.ZoneInfo.from_file(f, key=name)


def py_offset(zi, t):
    # Not fromtimestamp: it refuses negative instants on Windows.
    u = dt.datetime(1970, 1, 1, tzinfo=UTC) + dt.timedelta(seconds=t)
    return int(u.astimezone(zi).utcoffset().total_seconds())


def pascal_str(s):
    return "'" + s.replace("'", "''") + "'"


def wrap(items, per_line, indent='    '):
    lines = []
    for i in range(0, len(items), per_line):
        lines.append(indent + ', '.join(items[i:i + per_line]))
    return ',\n'.join(lines)


def write_data_unit(version, zones, links, out):
    blob = bytearray()
    starts, by_hash = [], {}
    for z in zones:
        data = (out / z).read_bytes()
        if not data.startswith(b'TZif'):
            fail(z + ': not TZif')
        h = hashlib.sha256(data).digest()
        if h not in by_hash:
            by_hash[h] = (len(blob), len(data))
            blob += data
        starts.append(by_hash[h])
    zone_index = {z: i for i, z in enumerate(zones)}
    link_names = list(links)
    text = []
    w = text.append
    w('unit PascalCommon.TimeZones.Data;\n\n{$I pascalcommon.inc}\n\n')
    w('{ GENERATED FILE: the IANA time zone database, release %s, produced by\n'
      '  tools/gen_tzdata.py. Do not edit by hand: run the script with a new\n'
      '  release instead (docs/timezones-design.md, "Update policy").\n\n'
      '  Each zone\'s TZif bytes are exactly what "zic -b slim" wrote for it;\n'
      '  zones with identical contents share one copy. PascalCommon.TimeZones\n'
      '  reads them through TPcEmbeddedTzSource; nothing else should need this\n'
      '  unit. The tzdb is in the public domain. }\n\n' % version)
    w('interface\n\nconst\n')
    w("  PC_TZDB_VERSION = '%s';\n" % version)
    w('  PC_TZDB_ZONE_COUNT = %d;\n' % len(zones))
    w('  PC_TZDB_LINK_COUNT = %d;\n' % len(link_names))
    w('  PC_TZDB_SIZE = %d;\n\n' % len(blob))
    w('  /// The zones, sorted (ordinal).\n')
    w('  PcTzdbZoneNames: array[0..PC_TZDB_ZONE_COUNT - 1] of string = (\n')
    w(wrap([pascal_str(z) for z in zones], 4) + ');\n\n')
    w('  /// Where each zone\'s TZif starts in PcTzdbBytes, and its length.\n')
    w('  PcTzdbZoneStarts: array[0..PC_TZDB_ZONE_COUNT - 1] of Integer = (\n')
    w(wrap([str(s) for s, _ in starts], 10) + ');\n')
    w('  PcTzdbZoneLengths: array[0..PC_TZDB_ZONE_COUNT - 1] of Integer = (\n')
    w(wrap([str(n) for _, n in starts], 10) + ');\n\n')
    w('  /// The links (backward names such as US/Eastern), sorted, and the\n')
    w('  /// index of each one\'s zone in PcTzdbZoneNames.\n')
    w('  PcTzdbLinkNames: array[0..PC_TZDB_LINK_COUNT - 1] of string = (\n')
    w(wrap([pascal_str(l) for l in link_names], 4) + ');\n')
    w('  PcTzdbLinkTargets: array[0..PC_TZDB_LINK_COUNT - 1] of Integer = (\n')
    w(wrap([str(zone_index[links[l]]) for l in link_names], 10) + ');\n\n')
    w('  PcTzdbBytes: array[0..PC_TZDB_SIZE - 1] of Byte = (\n')
    w(wrap(['$%02X' % b for b in blob], 24) + ');\n\n')
    w('implementation\n\nend.\n')
    DATA_UNIT.write_text(''.join(text), encoding='utf-8', newline='\n')
    print('wrote %s: %d zones, %d links, %d bytes (%d distinct contents)'
          % (DATA_UNIT.relative_to(ROOT), len(zones), len(link_names), len(blob), len(by_hash)))


def build_golden(version, zones, links, out, transitions):
    names = sorted(zones + list(links))
    idx = {n: i for i, n in enumerate(names)}
    offsets = []
    for n in names:
        zi = py_zone(out, links.get(n, n))
        for t in SAMPLE_INSTANTS:
            offsets.append((idx[n], t, py_offset(zi, t)))
    trans, maps = [], []
    for z in zones:
        zi = py_zone(out, z)
        for (t, before, after) in transitions.get(z, []):
            # zdump and Python must agree before either is a reference.
            if py_offset(zi, t - 1) != before or py_offset(zi, t) != after:
                fail('%s at %d: zdump says %d -> %d, Python %d -> %d'
                     % (z, t, before, after, py_offset(zi, t - 1), py_offset(zi, t)))
            trans.append((idx[z], t, before, after))
            if t < MAPPING_FROM:
                continue
            # A local reading in the middle of the gap or overlap.
            local = t + min(before, after) + abs(after - before) // 2
            ld = dt.datetime(1970, 1, 1) + dt.timedelta(seconds=local)
            f0 = local - int(ld.replace(tzinfo=zi, fold=0).utcoffset().total_seconds())
            f1 = local - int(ld.replace(tzinfo=zi, fold=1).utcoffset().total_seconds())
            count = 0 if after > before else 2
            maps.append((idx[z], local, count, f0, f1))
    return names, offsets, trans, maps


def write_golden_file(version, names, offsets, trans, maps):
    # A data file the tests read at run time, not a Pascal unit: as a 15 000
    # line unit, together with the data unit, it pushed the Delphi test
    # project to where Delphi Community Edition shows its EULA reminder on
    # every build (measured 2026-10-20; either unit alone in a project
    # didn't).
    text = []
    w = text.append
    w('# GENERATED FILE: reference answers for the IANA time zone database,\n'
      '# release %s, produced by tools/gen_tzdata.py from the same compiled tree\n'
      '# as src/PascalCommon.TimeZones.Data.pas. Do not edit by hand.\n'
      '#\n'
      "# From readers that aren't ours: the transitions from zdump (glibc),\n"
      '# %d-%d; the offsets at fixed instants and the fold=0/fold=1 instants of\n'
      '# a local reading inside each gap and overlap since 2010 from Python\n'
      '# zoneinfo. Read by PascalCommon.TimeZonesTests (Golden_*).\n'
      '#\n'
      '# V release | N name (numbered from 0 in order) | O name instant offset |\n'
      '# T zone instant before after | M zone local count fold0 fold1\n'
      % (version, TRANSITION_YEARS[0], TRANSITION_YEARS[1] - 1))
    w('V %s\n' % version)
    for n in names:
        w('N %s\n' % n)
    for row in offsets:
        w('O %d %d %d\n' % row)
    for row in trans:
        w('T %d %d %d %d\n' % row)
    for row in maps:
        w('M %d %d %d %d %d\n' % row)
    GOLDEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    GOLDEN_FILE.write_text(''.join(text), encoding='utf-8', newline='\n')
    print('wrote %s: %d names, %d offsets, %d transitions, %d mappings'
          % (GOLDEN_FILE.relative_to(ROOT), len(names), len(offsets), len(trans), len(maps)))


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--release')
    g.add_argument('--tarball')
    ap.add_argument('--image', default='debian:13-slim')
    a = ap.parse_args()
    tarball = fetch(a.release) if a.release else Path(a.tarball)
    dest, version = extract(tarball)
    print('release', version)
    zones, links = parse_sources(dest / 'src')
    out, zdump = compile_and_dump(dest, zones, a.image)
    transitions = parse_zdump(zdump)
    missing = [z for z in zones if z not in transitions and (out / z).exists() is False]
    if missing:
        fail('not compiled: ' + ', '.join(missing))
    write_data_unit(version, zones, links, out)
    write_golden_file(version, *build_golden(version, zones, links, out, transitions))


if __name__ == '__main__':
    main()
