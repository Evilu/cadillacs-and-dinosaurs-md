"""Report on a cps1_profile.lua run.

usage: profile_report.py <profile dir> <ghidra functions.tsv> [--idle 83c-8a2] [--kernel 8a2-a40] [--top 30]
Prints where the samples fall: idle scheduler loop, kernel calls, tasks, and the
hottest routines by exclusive (PC inside) and inclusive (on the call stack) samples.
"""
import argparse
import bisect
import csv
from pathlib import Path


def load(path):
    return {k: int(v) for k, v in csv.reader(open(path))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('functions')
    ap.add_argument('--idle', default='83c-8a2')
    ap.add_argument('--kernel', default='8a2-a40')
    ap.add_argument('--spin', default='9e38c-9e41c', help='PC range of the polling task loop')
    ap.add_argument('--top', type=int, default=30)
    a = ap.parse_args()
    d = Path(a.dir)
    leaf = {int(k): v for k, v in load(d / 'profile_leaf.csv').items()}
    incl = {int(k): v for k, v in load(d / 'profile_incl.csv').items()}
    tasks = load(d / 'profile_tasks.csv')
    modes = load(d / 'profile_modes.csv')
    total = sum(leaf.values())
    rng = lambda s: tuple(int(x, 16) for x in s.split('-'))
    (i0, i1), (k0, k1) = rng(a.idle), rng(a.kernel)
    idle = sum(v for k, v in leaf.items() if i0 <= k < i1)
    kern = sum(v for k, v in leaf.items() if k0 <= k < k1)
    work = total - idle
    per_frame = total / len(open(d.parent / 'dino_steady_frames.txt').read().split()) if (d.parent / 'dino_steady_frames.txt').exists() else None
    print(f'samples {total}' + (f' ({per_frame:.0f} per profiled frame)' if per_frame else ''))
    print(f'idle scheduler loop {idle / total * 100:.1f}%   kernel calls (yield, sleep, create) {kern / total * 100:.1f}%   '
          f'everything else {(work - kern) / total * 100:.1f}%')
    print(f'user mode {modes["user"] / total * 100:.1f}%  supervisor {modes["super"] / total * 100:.1f}%')
    print('\nsamples by task slot (user mode = task code, super = kernel/interrupt while that slot is current):')
    for k, v in sorted(tasks.items(), key=lambda x: -x[1])[:10]:
        print(f'  {k:10} {v / total * 100:5.1f}%')

    s0, s1 = rng(a.spin)
    overhead = lambda pc: i0 <= pc < i1 or k0 <= pc < k1 or s0 <= pc < s1
    real = sum(v for k, v in leaf.items() if not overhead(k))
    print(f'real work (not idle loop, kernel calls or polling loop): {real / total * 100:.1f}% of samples')

    funcs = []
    for r in csv.DictReader(open(a.functions), delimiter='\t'):
        funcs.append((int(r['address'], 16), int(r['size'])))
    funcs.sort()
    starts = [f[0] for f in funcs]
    targets = sorted(k for k in incl if k > 0)

    def owner(pc):
        i = bisect.bisect_right(starts, pc) - 1
        if i >= 0 and pc < funcs[i][0] + max(funcs[i][1], 2):
            return f'{funcs[i][0]:06x}'
        j = bisect.bisect_right(targets, pc) - 1
        if j >= 0 and pc - targets[j] < 0x200 and (i < 0 or targets[j] > funcs[i][0]):
            return f'{targets[j]:06x}'
        return f'{pc & ~0xff:06x}+'

    excl = {}
    for pc, v in leaf.items():
        if overhead(pc):
            continue
        o = owner(pc)
        excl[o] = excl.get(o, 0) + v
    work = real
    print(f'\ntop {a.top} routines by exclusive samples (share of real work; "+" = 256-byte block of unmapped code):')
    for o, v in sorted(excl.items(), key=lambda x: -x[1])[:a.top]:
        on = incl.get(int(o.rstrip('+'), 16), 0) if not o.endswith('+') else 0
        print(f'  {o:8} {v / work * 100:5.1f}%   on stack {on / work * 100:5.1f}%')
    print(f'\ntop {a.top} call targets by inclusive samples (share of real work; "via" = indirect call site):')
    for o, v in sorted(incl.items(), key=lambda x: -x[1])[:a.top]:
        name = f'{o:06x}' if o > 0 else f'via {-o:06x}'
        print(f'  {name:12} {v / work * 100:5.1f}%')


if __name__ == '__main__':
    main()
