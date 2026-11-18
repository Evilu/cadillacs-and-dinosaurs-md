"""Summarise MAME trace CSVs from cps1_trace.lua and md_trace.lua.

usage: summarise_traces.py --cps1 <cps1_frames.csv> --md <md_frames.csv>
"""
import argparse
import collections
import csv
import statistics


def rows(path):
    return list(csv.DictReader(open(path)))


def n(r, k):
    return int(r[k], 16) if k in ('pc', 'layer_ctrl') else int(r[k])


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))]


def table(title, frames, keys):
    print(f'\n{title} ({len(frames)} frames)')
    print(f'{"metric":28} {"mean":>8} {"p50":>7} {"p95":>7} {"p99":>7} {"max":>7}')
    for k in keys:
        v = [n(r, k) for r in frames]
        print(f'{k:28} {statistics.mean(v):8.1f} {pct(v, .5):7} {pct(v, .95):7} {pct(v, .99):7} {max(v):7}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cps1')
    ap.add_argument('--md')
    ap.add_argument('--idle', default='752-7b6', help='arcade scheduler idle PC range, hex')
    a = ap.parse_args()
    if a.cps1:
        g = [r for r in rows(a.cps1) if n(r, 'obj_tiles') > 0 and n(r, 's3_unique') > 20 and n(r, 's2_on')]
        table('CPS-1 gameplay', g, ['obj_entries', 'obj_tiles', 'obj_unique', 'md_sprites_est', 'obj_line_tiles_max',
                                    'obj_lines_over_320px', 's1_unique', 's2_unique', 's2_prio_cells', 's3_unique',
                                    's3_prio_cells', 'palettes', 'colours', 'working_set_patterns',
                                    'new_patterns_vs_prev', 'lru_miss_patterns'])
        lo, hi = (int(x, 16) for x in a.idle.split('-'))
        idle = sum(1 for r in g if lo <= n(r, 'pc') <= hi)
        print(f'frames ending in the idle scheduler loop: {idle / len(g) * 100:.1f}%')
        ch = sum(1 for x, y in zip(g, g[1:]) if x['obj_hash'] != y['obj_hash'])
        print(f'frames whose sprite list differs from the previous frame: {ch / len(g) * 100:.1f}%')
        miss = [n(r, 'lru_miss_patterns') for r in g]
        for th in (100, 230, 330, 500, 1000):
            print(f'frames needing more than {th} new patterns (LRU cache of 1400): {sum(1 for m in miss if m > th)}')
        over = sum(1 for r in g if n(r, 'working_set_patterns') > 1400)
        print(f'frames whose visible working set exceeds 1400 patterns: {over / len(g) * 100:.1f}%')
    if a.md:
        m = rows(a.md)
        g = [r for r in m if r['in_game'] == '1']
        table('Mega Drive gameplay', g, ['dma_vram', 'dma_cram', 'dma_vsram', 'dma_active', 'dma_ops', 'cpu_vram',
                                        'cpu_cram', 'fill', 'copy', 'cram_active', 'reg_active', 'spr_visible',
                                        'spr_cells', 'spr_line_max', 'spr_line_px_max', 'spr_over_lines',
                                        'spr_pals', 'cram_colours', 'cram_changed'])
        sat = sum(1 for r in g if n(r, 'sat_dma') > 0)
        print(f'frames with a sprite-table DMA: {sat / len(g) * 100:.1f}%')
        hist = collections.Counter(n(r, 'pc') & ~0xf for r in g)
        print('most common frame-end PC (16-byte buckets):', ', '.join(f'{k:06x}:{v}' for k, v in hist.most_common(8)))
        modes = collections.Counter((r['hscroll_mode'], r['vscroll_mode'], r['width'], r['hint']) for r in g)
        print('scroll modes (h, v, width, hint):', dict(modes))
        mp = sum(n(r, 'mapper') for r in m)
        print('mapper register writes:', mp)


if __name__ == '__main__':
    main()
