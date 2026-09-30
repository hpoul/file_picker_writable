"""Turn BENCH lines from a flutter run log into a compact table."""
import re
import sys

runs = {}
pings = {}
meta = ''
idle = []
for line in open(sys.argv[1], errors='replace'):
    m = re.search(r'BENCH (.*)$', line)
    if not m:
        continue
    body = m.group(1).strip()
    kv = dict(re.findall(r'(\w+)=("[^"]*"|\S+)', body))
    if body.startswith('META'):
        meta = body
    elif body.startswith('RUN '):
        key = (kv['transport'], int(kv['chunk_kib']))
        runs.setdefault(key, []).append(kv)
    elif body.startswith('PING '):
        pings.setdefault(kv['chan'], []).append(kv)
    elif body.startswith('IDLE '):
        idle.append(kv)


def med(vals):
    s = sorted(vals)
    return s[len(s) // 2]


def f(v, nd=1):
    return f'{float(v):.{nd}f}'


print(meta)
for kv in idle:
    print(f"IDLE 5s: frames={kv['frames']} fps={kv.get('fps')} jank={kv['jank']} jank33={kv.get('jank33')} "
          f"uiStall={kv.get('uiStall')} gaps40={kv.get('gaps40')} worst_ms={kv['worst_ms']} "
          f"medianSpan_ms={kv.get('medianSpan_ms')} maxGap_ms={kv.get('maxGap_ms')}")
print()
print('PING (0-byte MethodChannel round trip, 1000 calls; medians over reps)')
print(f"{'chan':6} {'n':>2} {'mean_us':>8} {'p50_us':>7} {'p99_us':>7} {'max_us':>7}")
for chan, rows in pings.items():
    print(f"{chan:6} {len(rows):>2} {f(med([float(r['mean_us']) for r in rows])):>8} "
          f"{med([int(r['p50_us']) for r in rows]):>7} {med([int(r['p99_us']) for r in rows]):>7} "
          f"{med([int(r['max_us']) for r in rows]):>7}")
print()
print('RUNS (1 GiB sequential; medians over reps; jank = frames > 16.7 ms, jank33 = > 33.4 ms, '
      'uiStall = build > 16.7 ms, gaps40 = vsync gaps > 40 ms; worst/maxGap = max over reps)')
hdr = (f"{'transport':22} {'chunk':>6} {'n':>2} {'MiB/s':>7} {'mean_us':>8} {'p50_us':>7} {'p99_us':>7} "
       f"{'max_us':>8} {'frames':>6} {'fps':>5} {'jank':>5} {'jank33':>6} {'uiStall':>7} {'gaps40':>6} "
       f"{'worst_ms':>8} {'maxGap_ms':>9}")
print(hdr)
for key in sorted(runs, key=lambda k: (k[0], k[1])):
    rows = runs[key]
    def m(k, cast=int):
        return med([cast(r[k]) for r in rows])
    print(f"{key[0]:22} {str(key[1]) + 'K':>6} {len(rows):>2} "
          f"{f(m('MiB_s', float)):>7} "
          f"{f(m('mean_us', float)):>8} "
          f"{m('p50_us'):>7} {m('p99_us'):>7} {m('max_us'):>8} "
          f"{m('frames'):>6} {f(m('fps', float)):>5} "
          f"{m('jank'):>5} {m('jank33'):>6} {m('uiStall'):>7} {m('gaps40'):>6} "
          f"{f(max(float(r['worst_ms']) for r in rows)):>8} "
          f"{f(max(float(r['maxGap_ms']) for r in rows)):>9}")
