"""usage: level_sheet.py <arcade run dir> <md run dir> <out.png>
Pairs the snapshots of two tools/level.sh runs: arcade above, Mega Drive below, one
column per snapshot, and prints the two level.csv files side by side."""
import csv
import glob
import sys

from PIL import Image

W, H, PER_ROW = 384, 224, 6


def shots(folder):
    return sorted(glob.glob(folder + '/*/*.png'))


def rows(folder):
    try:
        return list(csv.DictReader(open(folder + '/level.csv')))
    except FileNotFoundError:
        return []


def side(r):
    if not r:
        return ' ' * 44
    return f"stage {r['stage']} area {r['area']} mode {r['mode']:>2} steps {r['steps']:>5} x {r['p1_x']:>5}"


def main(arcade, md, out):
    a, m = shots(arcade), shots(md)
    n = max(len(a), len(m))
    lines = (n + PER_ROW - 1) // PER_ROW
    sheet = Image.new('RGB', (W * PER_ROW, lines * (2 * H + 8)), (40, 0, 40))
    for i in range(n):
        x, y = W * (i % PER_ROW), (2 * H + 8) * (i // PER_ROW)
        if i < len(a):
            sheet.paste(Image.open(a[i]).convert('RGB'), (x, y))
        if i < len(m):
            picture = Image.open(m[i]).convert('RGB')
            sheet.paste(picture, (x + (W - picture.size[0]) // 2, y + H + 4))
    sheet.save(out)
    ra, rm = rows(arcade), rows(md)
    for i in range(max(len(ra), len(rm))):
        left = ra[i] if i < len(ra) else None
        right = rm[i] if i < len(rm) else None
        print(f"{(left or right)['frame']:>6}  arcade {side(left)}   md {side(right)}")
    print(f'{len(a)} arcade and {len(m)} md snapshots -> {out}')


main(*sys.argv[1:4])
