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
    ap.add_argument('--broad', action='store_true',
                    help='count every frame with sprites and a scroll 2 picture (includes indoor scenes and cutscenes)')
    ap.add_argument('--clock', type=float, default=10e6, help='arcade 68000 clock in Hz (ffight 10e6, dino 12e6)')
    ap.add_argument('--poll-cycles', type=float, default=99, help='68000 cycles per scheduler frame-flag read')
    a = ap.parse_args()
    if a.cps1:
        if a.broad:
            g = [r for r in rows(a.cps1) if n(r, 'obj_tiles') > 0 and n(r, 's2_unique') > 20 and n(r, 's1_on')]
        else:
            g = [r for r in rows(a.cps1) if n(r, 'obj_tiles') > 0 and n(r, 's3_unique') > 20 and n(r, 's2_on')]
        table('CPS-1 gameplay', g, ['obj_entries', 'obj_tiles', 'obj_unique', 'md_sprites_est', 'obj_line_tiles_max',
                                    'obj_lines_over_320px', 's1_unique', 's2_unique', 's2_prio_cells', 's3_unique',
                                    's3_prio_cells', 'palettes', 'colours', 'working_set_patterns',
                                    'new_patterns_vs_prev', 'lru_miss_patterns'])
        if 'idle_reads' in g[0] and any(n(r, 'idle_reads') for r in g):
            cyc = a.clock / 59.637
            load = [max(0.0, 1 - n(r, 'idle_reads') * a.poll_cycles / cyc) for r in g]
            print(f'CPU load (share of a {cyc:.0f}-cycle frame outside the scheduler poll loop): '
                  f'mean {statistics.mean(load):.2f} p50 {pct(load, .5):.2f} p95 {pct(load, .95):.2f} '
                  f'p99 {pct(load, .99):.2f} max {max(load):.2f}')
            for name, budget in (('a Mega Drive frame', 7670454 / 59.92), ('a Mega Drive frame minus VBlank', 7670454 / 59.92 * 224 / 262)):
                over = sum(1 for x in load if x * cyc > budget)
                print(f'frames needing more than {name} ({budget:.0f} cycles): {over / len(load) * 100:.1f}%')
            md = 7670454 / 59.92
            hot = [n(r, 'frame') for r, x in zip(g, load) if x * cyc > md]
            runs = []
            for fr in hot:
                if runs and fr - runs[-1][1] <= 30:
                    runs[-1][1] = fr
                    runs[-1][2] += 1
                else:
                    runs.append([fr, fr, 1])
            burst = set()
            for lo, hi, count in runs:
                if count >= 5:
                    burst.update(range(lo - 5, hi + 6))
            calm = [x for r, x in zip(g, load) if n(r, 'frame') not in burst]
            print(f'bursts of 5+ over-budget frames: {sum(1 for r in runs if r[2] >= 5)}, covering {len(load) - len(calm)} frames; '
                  f'longest {max((r[1] - r[0] + 1 for r in runs), default=0)} frames')
            print(f'outside bursts ({len(calm)} frames): cycles mean {statistics.mean(calm) * cyc:.0f} '
                  f'p95 {pct(calm, .95) * cyc:.0f} p99 {pct(calm, .99) * cyc:.0f}; '
                  f'over a Mega Drive frame {sum(1 for x in calm if x * cyc > md) / len(calm) * 100:.2f}%, '
                  f'over frame minus VBlank {sum(1 for x in calm if x * cyc > md * 224 / 262) / len(calm) * 100:.1f}%')
        ch = sum(1 for x, y in zip(g, g[1:]) if x['obj_hash'] != y['obj_hash'])
        print(f'frames whose sprite list differs from the previous frame: {ch / len(g) * 100:.1f}%')
        miss = [n(r, 'lru_miss_patterns') for r in g]
        for th in (100, 230, 330, 500, 1000):
            print(f'frames needing more than {th} new patterns (LRU cache of 1400): {sum(1 for m in miss if m > th)}')
        for cap in (1400, 1536):
            over = sum(1 for r in g if n(r, 'working_set_patterns') > cap)
            print(f'frames showing more than {cap} patterns: {over / len(g) * 100:.1f}%')
        eq = sum(1 for r in g if r['obj_entries'] == r['obj_tiles'])
        print(f'frames where every sprite entry is a single tile: {eq / len(g) * 100:.1f}%')
    if a.md:
        m = rows(a.md)
        g = [r for r in m if r['in_game'] == '1' and n(r, 'spr_visible') >= 3]
        table('Mega Drive gameplay', g, ['dma_vram', 'dma_cram', 'dma_vsram', 'dma_active', 'dma_ops', 'cpu_vram',
                                        'cpu_cram', 'fill', 'copy', 'cram_active', 'reg_active', 'spr_visible',
                                        'spr_cells', 'spr_line_max', 'spr_line_px_max', 'spr_over_lines',
                                        'spr_pals', 'cram_colours', 'cram_changed'])
        sat = sum(1 for r in g if n(r, 'sat_dma') > 0)
        print(f'frames with a sprite-table DMA: {sat / len(g) * 100:.1f}%')
        for label, test in (('a line over a sprite limit', lambda r: n(r, 'spr_over_lines') > 0),
                            ('more than 20 sprites on a line', lambda r: n(r, 'spr_line_max') > 20),
                            ('a CRAM change', lambda r: n(r, 'cram_changed') > 0)):
            print(f'frames with {label}: {sum(1 for r in g if test(r)) / len(g) * 100:.2f}%')
        if 'dma_src_rom' in g[0]:
            rom, ram = sum(n(r, 'dma_src_rom') for r in g), sum(n(r, 'dma_src_ram') for r in g)
            print(f'VRAM DMA bytes from ROM: {rom / (rom + ram) * 100:.1f}%')
        hist = collections.Counter(n(r, 'pc') & ~0xf for r in g)
        print('most common frame-end PC (16-byte buckets):', ', '.join(f'{k:06x}:{v}' for k, v in hist.most_common(8)))
        modes = collections.Counter((r['hscroll_mode'], r['vscroll_mode'], r['width'], r['hint']) for r in g)
        print('scroll modes (h, v, width, hint):', dict(modes))
        mp = sum(n(r, 'mapper') for r in m)
        print('mapper register writes:', mp)


if __name__ == '__main__':
    main()
