#!/usr/bin/env python3
"""Plan a bhop route over an imported map's collision, and write maps/routes/<id>.json."""
import json, struct, sys, heapq, math, argparse, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import booster_flight

HEADROOM = 72.0      # a top with a solid this close above it is not stood on
CELL = 32.0         # terrain is binned into cells this wide
WALKABLE = 0.8      # the least normal-y of a triangle that is ground to land on
CELL_SPREAD = 24.0  # a terrain cell whose walkable triangles span more height than this is a slope
FALL = 2000.0       # the deepest drop off a ledge into a catch box that a fall door takes
STEP = 18.0         # the motor's step: walking up a slope, a cell's low edge may stand this far over the last one's top
RUN_SPEED, JUMP_V, GRAVITY = 250.0, 302.0, 800.0  # u/s, u/s, u/s^2: the follower's take-off at a lip


def envelope(rise, safety, speed=RUN_SPEED, launch=JUMP_V):
    """The furthest edge-to-edge gap a jump from a lip at `speed` lands, `rise` units above take-off (negative: a drop)."""
    disc = launch * launch - 2.0 * GRAVITY * rise
    return 0.0 if disc < 0 else safety * speed * (launch + math.sqrt(disc)) / GRAVITY


CLIMB = 54.0         # the most a jump lands on above take-off (57 apex, less margin)

PIT_MARGIN = 2.0
SLOPE_PIT_MARGIN = 4.0  # the margin over a pit for a terrain cell's lowest point
NARROW = 16.0     # narrower than this is trim, not a floor


_warned = [False]


def geometry(f):
    """A hull's outward face planes (nx, ny, nz, d) and its sloped walkable triangles, or (None, []):
    its box alone misjudges a slanted beam, and its highest vertices alone miss a ramp's floor."""
    try:
        from scipy.spatial import ConvexHull
        ch = ConvexHull([f[k:k + 3] for k in range(0, len(f), 3)])
    except Exception:  # no scipy, or a flat hull qhull refuses
        if not _warned[0]:
            _warned[0] = True; print('warning: scipy missing or a hull refused: sloped faces are skipped, the plan differs', file=sys.stderr)
        return None, []
    slopes = [[tuple(ch.points[v]) for v in s] for s, e in zip(ch.simplices, ch.equations) if WALKABLE <= e[1] < 0.999]
    return [tuple(e) for e in ch.equations], slopes


def inside(h, x, y, z, inset=0.0):
    """Whether (x, y, z) is inside hull h, at least `inset` from its faces where its planes are known."""
    return h['planes'] is None or all(a * x + b * y + c * z + d < -inset for a, b, c, d in h['planes'])


def load(mid, root, slopes_walked=False):
    """The manifest and its hulls; with `slopes_walked`, terrain up to the map's max_slope is kept and a cell on a slope is a top marked 'slope'."""
    base = '%s/maps/imported/%s/%s' % (root, mid, mid)
    d = json.load(open(base + '.json')); blob = open(base + '.bin', 'rb').read()
    c = d['collision']; off = c['hull_offset']; hulls = []; slopes = []
    for _ in range(c['hull_count']):
        n = struct.unpack_from('<I', blob, off)[0]; off += 4
        f = struct.unpack_from('<%df' % (n * 3), blob, off); off += n * 12
        xs, ys, zs = f[0::3], f[1::3], f[2::3]
        ty = max(ys)
        top = [(xs[i], zs[i]) for i in range(n) if ys[i] > ty - 1]
        pl, sl = geometry(f); slopes += sl
        hulls.append({'box': (min(xs), max(xs), min(zs), max(zs)), 'bottom': min(ys), 'top': ty, 'planes': pl,
                      'face': (min(p[0] for p in top), max(p[0] for p in top),
                               min(p[1] for p in top), max(p[1] for p in top)) if len(top) >= 3 else None})
    # Terrain (displacements) and sloped hull faces are triangles: every walkable one is sampled
    # every few units, the samples binned into cells per height band, each cell a top of its own.
    tris = slopes
    vc = c.get('displacement_vertex_count', 0); ic = c.get('displacement_index_count', 0)
    if vc and ic:
        v = struct.unpack_from('<%df' % (vc * 3), blob, c['displacement_vertex_offset'])
        ix = struct.unpack_from('<%di' % ic, blob, c['displacement_index_offset'])
        tris = tris + [[v[ix[k + m] * 3: ix[k + m] * 3 + 3] for m in range(3)] for k in range(0, ic - 2, 3)]
    cells = {}
    walkable = math.cos(math.radians(d.get('max_slope', 45.57))) if slopes_walked else WALKABLE
    for p in tris:
        ax, ay, az = [p[1][q] - p[0][q] for q in range(3)]
        bx, by, bz = [p[2][q] - p[0][q] for q in range(3)]
        nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
        ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
        if abs(ny) / ln < walkable:  # a steeper sliver of cliff base is not ground to land on
            continue
        # a vertex outside the cell would put its height (a lower shore) on the cell
        n = max(1, int(math.ceil(max(math.dist(p[0], p[1]), math.dist(p[0], p[2]), math.dist(p[1], p[2])) / 8.0)))
        for s_ in range(n + 1):
            for t_ in range(n + 1 - s_):
                x, y, z = [p[0][q] + (p[1][q] - p[0][q]) * s_ / n + (p[2][q] - p[0][q]) * t_ / n for q in range(3)]
                key = (int(math.floor(x / CELL)), int(math.floor(z / CELL)), int(math.floor(y / 96.0)))
                lo_, hi_, sm, n_ = cells.get(key, (1e18, -1e18, 0.0, 0))
                cells[key] = (min(lo_, y), max(hi_, y), sm + y, n_ + 1)
    for (gx, gz, _), (lo_, y, sm, n_) in cells.items():
        slope = y - lo_ > CELL_SPREAD
        if slope and not slopes_walked:
            continue  # a cell on a slope: its highest vertex is a lip over lower ground, not a floor to land on
        hulls.append({'box': None, 'bottom': y - 1.0, 'top': y, 'low': lo_, 'planes': None, 'slope': slope,
                      'face': (gx * CELL, (gx + 1) * CELL, gz * CELL, (gz + 1) * CELL)})
    return d, hulls

def inert_filters(mid, root, b):
    """The filter names whose teleports the importer drops, so the game never fires them: the zones
    file's `conditional_teleports` (and the filters passing those names) and class filters on a non-player."""
    zf = os.path.join(root, 'maps', 'zones', mid + '.json')
    names = set()
    if os.path.isfile(zf):
        names = set(str(n).strip().lower() for n in json.load(open(zf)).get('conditional_teleports', {}).get('filters', []))
    out = set(names)
    for e in b.entities:
        cls = e.get('classname', '')
        own = e.get('targetname', '').strip().lower()
        if cls.startswith('filter_') and e.get('filtername', '').strip().lower() in names:
            out.add(own)
        if cls == 'filter_activator_class' and e.get('filterclass', '').strip().lower() != 'player' and \
                e.get('Negated', '0').strip().lower() not in ('1', 'filter out entities that match criteria'):
            out.add(own)
    out.discard('')
    return out


def spawnflags(e):
    try:
        return int(float(e.get('spawnflags') or 1))
    except (TypeError, ValueError):
        return 1


def teleports(mid, root, d):
    """Every teleport as (xz box, y range, destination): the map's own trigger_teleports when the
    .bsp is beside (stage gates, lane exits and pits are not in the manifest, only their arrivals
    are), else the manifest's TELEPORT zones. A staged map is a graph: a gate moves the player
    from one section to the next, a pit back to a lane start."""
    out = []
    # needs inspirations/g2gfast/<id>.bsp directly under ~/godot (or the maps link target), or G2G_BSP
    linked = os.path.realpath(os.path.join(root, 'maps', 'imported', '..', '..'))
    bsp = os.environ.get('G2G_BSP') or next((p for p in (os.path.join(r, 'inspirations', 'g2gfast', mid + '.bsp') for r in (
        os.path.join(root, '..'), linked)) if os.path.isfile(p)), '')
    if os.path.isfile(bsp):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from bsp_read import Bsp, to_godot
        b = Bsp(bsp); b.load()
        dest = {}
        for e in b.entities:
            if e.get('targetname') and e.get('classname') in ('info_teleport_destination', 'info_target', 'info_landmark', 'point_teleport'):
                dest.setdefault(e['targetname'], e)
        skip = inert_filters(mid, root, b)
        for e in b.entities:
            if e.get('classname') != 'trigger_teleport' or not e.get('model', '').startswith('*'):
                continue
            if e.get('filtername', '').strip().lower() in skip or not spawnflags(e) & 1:
                continue
            t = dest.get(e.get('target', ''))
            if t is None or 'origin' not in t:
                continue
            mi, ma = b.model_bounds(int(e['model'][1:]))
            og = [float(v) for v in e.get('origin', '0 0 0').split()]
            lo, hi = to_godot([mi[k] + og[k] for k in range(3)]), to_godot([ma[k] + og[k] for k in range(3)])
            q = to_godot([float(v) for v in t['origin'].split()])
            out.append(((min(lo[0], hi[0]), max(lo[0], hi[0]), min(lo[2], hi[2]), max(lo[2], hi[2])),
                        (min(lo[1], hi[1]), max(lo[1], hi[1])), q))
        return out, True
    for z in d['zones']:
        if z['kind'] != 'TELEPORT' or z.get('track', 0) != 0 or not z.get('destination'):
            continue
        out.append(((min(z['min'][0], z['max'][0]), max(z['min'][0], z['max'][0]),
                     min(z['min'][2], z['max'][2]), max(z['min'][2], z['max'][2])),
                    (min(z['min'][1], z['max'][1]), max(z['min'][1], z['max'][1])), z['destination']))
    return out, False

TILE = 96.0          # a long top is cut into nodes this wide: a line between two centres crosses walls a hop never would

def tiles(f, top, low=None, slope=False):
    """A top as itself, or as a row of tiles when it is long enough that its centre is nowhere near its ends."""
    area = (f[1] - f[0]) * (f[3] - f[2])
    tile = max(TILE, math.sqrt(area / 2500.0))   # a floor the size of the map still gets tiles, only coarser
    nx = max(1, int(math.ceil((f[1] - f[0]) / tile))); nz = max(1, int(math.ceil((f[3] - f[2]) / tile)))
    if nx == 1 and nz == 1:
        return [{'face': f, 'top': top, 'low': top if low is None else low, 'terrain': low is not None, 'slope': slope}]
    out = []
    for ix in range(nx):
        for iz in range(nz):
            out.append({'face': (f[0] + (f[1] - f[0]) * ix / nx, f[0] + (f[1] - f[0]) * (ix + 1) / nx,
                                 f[2] + (f[3] - f[2]) * iz / nz, f[2] + (f[3] - f[2]) * (iz + 1) / nz), 'top': top, 'low': top, 'terrain': False, 'slope': False})
    return out

def overlap(a, b, m=0.0):
    return not (a[0] > b[1] - m or a[1] < b[0] + m or a[2] > b[3] - m or a[3] < b[2] + m)

def gap(a, b):
    dx = max(0.0, a[0] - b[1], b[0] - a[1]); dz = max(0.0, a[2] - b[3], b[2] - a[3])
    return math.hypot(dx, dz)

def closest_pair(a, b):
    """The nearest points of two rectangles' faces, as ((x, z), (x, z))."""
    def pick(lo1, hi1, lo2, hi2):
        if hi1 < lo2:
            return hi1, lo2
        if hi2 < lo1:
            return lo1, hi2
        m = (max(lo1, lo2) + min(hi1, hi2)) / 2
        return m, m
    ax, bx = pick(a[0], a[1], b[0], b[1]); az, bz = pick(a[2], a[3], b[2], b[3])
    return (ax, az), (bx, bz)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('map'); ap.add_argument('--root', default='.')
    ap.add_argument('--region', help='x0,z0,x1,z1')
    ap.add_argument('--reach', type=float, default=200.0)
    ap.add_argument('--safety', type=float, default=0.85, help='fraction of the run-speed jump envelope the planner trusts the follower with')
    ap.add_argument('--speed', type=float, default=RUN_SPEED, help='take-off speed (u/s) trusted for a long gap; past run speed the bot hops into it to carry speed')
    ap.add_argument('--carry', type=float, default=0.0, help='speed (u/s) a hop gains over the one before it; each edge then lands with the speed it carried, up to --vmax (0: every jump at --speed)')
    ap.add_argument('--vmax', type=float, default=416.0, help='the most speed a chain of hops carries')
    ap.add_argument('--no-strafe', action='store_true', help='a booster flight keeps its launch speed (the old envelope) instead of strafing for more (tools/booster_flight.py)')
    ap.add_argument('--slopes', action='store_true', help='walk terrain up to the map\'s max_slope: a cell on a slope is reached only by walking from the cell beside it')
    ap.add_argument('--to', help='x,up,z: plan to the tops within 64 u of this point instead of the END, to ride a section (never kept as the map\'s route)')
    ap.add_argument('--from', dest='frm', help='x,up,z: start on the top under this point instead of the spawn, to plan a section from (never kept as the map\'s route)')
    ap.add_argument('--fall-doors', action='store_true', help='a teleport box with no floor inside is a door entered by walking off a ledge over it (stages that join by a fall)')
    ap.add_argument('--out'); ap.add_argument('--debug', action='store_true')
    ap.add_argument('--why', help='x,up,z;x,up,z: why the tops nearest these two points are joined or not')
    a = ap.parse_args()
    d, hulls = load(a.map, a.root, a.slopes)
    region = [float(v) for v in a.region.split(',')] if a.region else None
    tops = []
    # Only boxed hulls can shade a top; a grid over them replaces a scan of every terrain cell too.
    SB = 512.0; shade_grid = {}
    for j, o in enumerate(hulls):
        if o['box'] is None:
            continue
        ob = o['box']
        for gx in range(int(math.floor(ob[0] / SB)), int(math.floor(ob[1] / SB)) + 1):
            for gz in range(int(math.floor(ob[2] / SB)), int(math.floor(ob[3] / SB)) + 1):
                shade_grid.setdefault((gx, gz), []).append(j)
    for i, h in enumerate(hulls):
        f = h['face']
        if f is None or f[1] - f[0] < NARROW or f[3] - f[2] < NARROW:
            continue
        if region and not overlap(f, region):
            continue
        cand = set()
        for gx in range(int(math.floor(f[0] / SB)), int(math.floor(f[1] / SB)) + 1):
            for gz in range(int(math.floor(f[2] / SB)), int(math.floor(f[3] / SB)) + 1):
                cand.update(shade_grid.get((gx, gz), ()))
        over = [hulls[j]['box'] for j in sorted(cand)
                if j != i and hulls[j]['bottom'] < h['top'] + HEADROOM and hulls[j]['top'] > h['top'] + 1 and overlap(f, hulls[j]['box'])]
        for t in tiles(f, h['top'], h.get('low'), h.get('slope', False)):
            tf = t['face']; shade = 0.0
            for b in over:
                shade += max(0.0, min(tf[1], b[1]) - max(tf[0], b[0])) * max(0.0, min(tf[3], b[3]) - max(tf[2], b[2]))
            if shade <= 0.5 * (tf[1] - tf[0]) * (tf[3] - tf[2]):
                tops.append(t)
    hulls = [h if h['box'] is not None else None for h in hulls]  # terrain cells are tops now; only boxed hulls block a line
    tps, tps_from_bsp = teleports(a.map, a.root, d)
    pits = [z for z in d['zones'] if z['kind'] == 'RESPAWN' and z.get('track', 0) == 0]
    def in_pit(t):
        f = t['face']; cx, cz = (f[0] + f[1]) / 2, (f[2] + f[3]) / 2
        # a RESPAWN box reaches up to the floor it catches: anything at or under its top is a fall
        if any(min(z['min'][0], z['max'][0]) <= cx <= max(z['min'][0], z['max'][0]) and
               min(z['min'][2], z['max'][2]) <= cz <= max(z['min'][2], z['max'][2]) and
               min(z['min'][1], z['max'][1]) - 8 <= t['top'] and t['low'] <= max(z["min"][1], z["max"][1]) + (SLOPE_PIT_MARGIN if t['terrain'] else PIT_MARGIN) for z in pits):
            return True
        # a floor a little under a teleport trigger is a pit's bottom, not a place to stand
        return tps_from_bsp and any(zb[0] <= cx <= zb[1] and zb[2] <= cz <= zb[3] and 8 < zy[0] - t['top'] <= 96 for zb, zy, _ in tps)
    waters = [(min(w['min'][0], w['max'][0]), max(w['min'][0], w['max'][0]), min(w['min'][2], w['max'][2]),
               max(w['min'][2], w['max'][2]), min(w['min'][1], w['max'][1]), max(w['min'][1], w['max'][1]))
              for w in d.get('mechanics', {}).get('water', [])]
    def in_water(t):
        # a floor under water is swum over, not hopped on (and on a pit map the water is the pit)
        f = t['face']; cx, cz = (f[0] + f[1]) / 2, (f[2] + f[3]) / 2
        return any(w[0] <= cx <= w[1] and w[2] <= cz <= w[3] and w[4] - 8 <= t['top'] <= w[5] for w in waters)
    tops = [t for t in tops if not in_pit(t) and not in_water(t)]
    sp = d['spawn']['origin']
    end = [z for z in d['zones'] if z['kind'] == 'END' and z.get('track', 0) == 0][0]
    ebox = (min(end['min'][0], end['max'][0]), max(end['min'][0], end['max'][0]),
            min(end['min'][2], end['max'][2]), max(end['min'][2], end['max'][2]))
    ey = (min(end['min'][1], end['max'][1]), max(end['min'][1], end['max'][1]))
    def centre(t):
        f = t['face']; return ((f[0] + f[1]) / 2, (f[2] + f[3]) / 2)
    def under(x, z, y, depth):
        """The highest top under (x, z) at most `depth` below y (and not above y + 8)."""
        best = None
        for i, t in enumerate(tops):
            f = t['face']
            if f[0] - 1 <= x <= f[1] + 1 and f[2] - 1 <= z <= f[3] + 1 and y - depth <= t['top'] <= y + 8:
                if best is None or t['top'] > tops[best]['top']:
                    best = i
        return best
    if a.frm:
        sp = [float(v) for v in a.frm.split(',')]
    s0 = under(sp[0], sp[2], sp[1], 3000.0)
    starts = [s0] if s0 is not None else []
    goals = set(i for i, t in enumerate(tops) if overlap(t['face'], ebox) and ey[0] - 300 <= t['top'] <= ey[1])
    if a.to:
        tx, ty, tz = [float(v) for v in a.to.split(',')]
        goals = set(i for i, t in enumerate(tops) if math.dist(centre(t), (tx, tz)) < 64.0 and abs(t['top'] - ty) < 64.0)
    # Doors: a TELEPORT zone keeps the run and moves the player to its destination, so a
    # top the door stands on (or over) is joined to the top under the destination.
    doors = {}
    for zb, zy, q in tps:
        land = under(q[0], q[2], q[1], 600.0)
        if land is None:
            continue
        for i, t in enumerate(tops):
            if overlap(t['face'], zb) and zy[0] - 24 <= t['top'] <= zy[1]:
                if land != i:
                    doors.setdefault(i, []).append((land, ((zb[0] + zb[1]) / 2, max(zy[0], t['top']), (zb[2] + zb[3]) / 2)))
    if a.debug:
        print('teleports', len(tps), 'doors on', len(doors), 'tops', len(tops), file=sys.stderr)
    if not starts or not goals:
        sys.exit('no start (%d) or no goal (%d) top' % (len(starts), len(goals)))
    # grid buckets for neighbours
    B = 512.0; grid = {}
    for i, t in enumerate(tops):
        f = t['face']
        for gx in range(int(math.floor(f[0] / B)), int(math.floor(f[1] / B)) + 1):
            for gz in range(int(math.floor(f[2] / B)), int(math.floor(f[3] / B)) + 1):
                grid.setdefault((gx, gz), []).append(i)
    def near(i, r=None):
        f = tops[i]['face']; seen = set(); r = a.reach if r is None else r
        for gx in range(int(math.floor((f[0] - r) / B)), int(math.floor((f[1] + r) / B)) + 1):
            for gz in range(int(math.floor((f[2] - r) / B)), int(math.floor((f[3] + r) / B)) + 1):
                for j in grid.get((gx, gz), []):
                    if j != i and j not in seen:
                        seen.add(j); yield j
    # Hull boxes in a grid, for "is the way from one top to the next clear at body height".
    hgrid = {}
    for k, h in enumerate(hulls):
        b = h and h['box']
        if b is None:
            continue
        if (b[1] - b[0]) * (b[3] - b[2]) > 4.0e6:
            continue  # a skybox wall or a whole-map floor: never between two blocks
        for gx in range(int(math.floor(b[0] / B)), int(math.floor(b[1] / B)) + 1):
            for gz in range(int(math.floor(b[2] / B)), int(math.floor(b[3] / B)) + 1):
                hgrid.setdefault((gx, gz), []).append(k)
    def clear(i, j):
        (ax, az), (bx, bz) = closest_pair(tops[i]['face'], tops[j]['face'])
        y0 = max(tops[i]['top'], tops[j]['top'])
        # The bot runs centre to centre, so that is the line asked about, outside the
        # two tops themselves.
        (px, pz), (qx, qz) = centre(tops[i]), centre(tops[j])
        n = max(2, int(math.dist((px, pz), (qx, qz)) / 16.0))
        samples = []
        fi, fj = tops[i]['face'], tops[j]['face']
        for s_ in range(n + 1):
            t = s_ / n; x = px + (qx - px) * t; z = pz + (qz - pz) * t
            if (fi[0] <= x <= fi[1] and fi[2] <= z <= fi[3]) or (fj[0] <= x <= fj[1] and fj[2] <= z <= fj[3]):
                continue
            samples.append((x, z, (y0 + 24.0, y0 + 48.0), -0.5))
        # A drop lands from above: the column over the landing, from the take-off down to
        # the top, has to be open too, or the "top" is a ledge inside the floor.
        lo, hi = tops[j]['top'] + 24.0, tops[i]['top'] + 48.0
        if hi > lo:
            f = tops[j]['face']
            cx, cz = (f[0] + f[1]) / 2, (f[2] + f[3]) / 2
            ix = min(max(bx, f[0] + 16.0), f[1] - 16.0) if f[1] - f[0] > 32 else cx
            iz = min(max(bz, f[2] + 16.0), f[3] - 16.0) if f[3] - f[2] > 32 else cz
            column = tuple(lo + k * 32.0 for k in range(int((hi - lo) / 32.0) + 1))
            samples.append((ix, iz, column, -0.5))
            samples.append((cx, cz, column, -0.5))
        for x, z, heights, inset in samples:
            for k in hgrid.get((int(math.floor(x / B)), int(math.floor(z / B))), []):
                b = hulls[k]['box']; h = hulls[k]
                if b[0] + inset < x < b[1] - inset and b[2] + inset < z < b[3] - inset:
                    for y in heights:
                        if h['bottom'] < y < h['top'] - 1 and inside(h, x, y, z, inset):
                            return False
        return True
    def open_column(x, z, lo, hi):
        """Whether nothing solid and no top stands in the column at (x, z) from lo up to hi."""
        for k in hgrid.get((int(math.floor(x / B)), int(math.floor(z / B))), []):
            h = hulls[k]; b = h['box']
            if b[0] < x < b[1] and b[2] < z < b[3] and h['bottom'] < hi and h['top'] > lo and \
                    any(h['bottom'] < y < h['top'] and inside(h, x, y, z) for y in (lo + 8.0 + 32.0 * n for n in range(int((hi - lo) / 32.0) + 1))):
                return False
        return not any(lo < tops[j]['top'] < hi - 40.0 and tops[j]['face'][0] <= x <= tops[j]['face'][1] and tops[j]['face'][2] <= z <= tops[j]['face'][3]
                       for j in grid.get((int(math.floor(x / B)), int(math.floor(z / B))), []))
    # Fall doors: a teleport box with no floor inside it (a stage's catch box over the void) is
    # entered by walking off a ledge over it, so the ledge is joined to the box's destination.
    if a.fall_doors:
        nf = 0
        for zb, zy, q in tps:
            land = under(q[0], q[2], q[1], 600.0)
            if land is None:
                continue
            cand = set()
            for gx in range(int(math.floor((zb[0] - 48.0) / B)), int(math.floor((zb[1] + 48.0) / B)) + 1):
                for gz in range(int(math.floor((zb[2] - 48.0) / B)), int(math.floor((zb[3] + 48.0) / B)) + 1):
                    cand.update(grid.get((gx, gz), []))
            if any(zy[0] - 24 <= tops[i]['top'] <= zy[1] and overlap(tops[i]['face'], zb) for i in cand):
                continue  # it has a floor, and the ordinary door stands on it
            for i in cand:
                t = tops[i]
                if i == land or not zy[1] < t['top'] <= zy[1] + FALL:
                    continue
                f = t['face']; cx, cz = centre(t)
                for x, z in ((f[0] - 24.0, cz), (f[1] + 24.0, cz), (cx, f[2] - 24.0), (cx, f[3] + 24.0)):
                    if zb[0] < x < zb[1] and zb[2] < z < zb[3] and open_column(x, z, zy[1], t['top'] + 48.0):
                        doors.setdefault(i, []).append((land, (x, zy[1] - 8.0, z))); nf += 1
                        break
        if a.debug:
            print('fall doors', nf, file=sys.stderr)
    def falls_into_trigger(i, j):
        """A drop whose column crosses a teleport trigger (a pit's catch box) lands the player at the pit's destination, not on j."""
        if tops[i]['top'] - tops[j]['top'] < 24.0:
            return False
        lt, tt = tops[j]['top'], tops[i]['top']
        (px, pz), (qx, qz) = centre(tops[i]), centre(tops[j])
        n = max(2, int(math.dist((px, pz), (qx, qz)) / 32.0))
        pts_ = [(px + (qx - px) * k / n, pz + (qz - pz) * k / n) for k in range(n + 1)]
        for zb, zy, _ in tps + [((w[0], w[1], w[2], w[3]), (w[4], w[5]), None) for w in waters]:
            if zy[0] < tt - 8.0 and zy[1] > lt + 24.0 and not (zy[0] - 24.0 <= lt <= zy[1]):
                if any(zb[0] <= x <= zb[1] and zb[2] <= z <= zb[3] for x, z in pts_):
                    return True
        return False
    # Boosters: a pad whose push is given on leaving launches a jump off it at JUMP_V plus the push.
    launch = {}
    for m in d.get('mechanics', {}).get('push', []):
        pv = m['push']
        if not m.get('leave') or m.get('filtered') or pv[1] < 100.0 or math.hypot(pv[0], pv[2]) > 0.25 * pv[1]:
            continue
        pb = (min(m['min'][0], m['max'][0]), max(m['min'][0], m['max'][0]), min(m['min'][2], m['max'][2]), max(m['min'][2], m['max'][2]))
        py = (min(m['min'][1], m['max'][1]), max(m['min'][1], m['max'][1]))
        for i, t in enumerate(tops):
            cx, cz = centre(t)
            if pb[0] <= cx <= pb[1] and pb[2] <= cz <= pb[3] and py[0] - 8.0 <= t['top'] <= py[1] + 2.0:
                launch[i] = max(launch.get(i, 0.0), JUMP_V + pv[1])
    def flight_reach(v, rise):
        return booster_flight.reach(v, a.speed, rise, a.safety, GRAVITY, not a.no_strafe)
    def boosted(i, j):
        """Whether the launch off booster top i lands on j: within the flight's reach, under its apex, the column over the pad open."""
        v = launch[i]; rise = tops[j]['top'] - tops[i]['top']
        if rise > 0.9 * v * v / (2.0 * GRAVITY) or rise < -600.0 or gap(tops[i]['face'], tops[j]['face']) > flight_reach(v, rise):
            return False
        cx, cz = centre(tops[i])
        for k in hgrid.get((int(math.floor(cx / B)), int(math.floor(cz / B))), []):
            h = hulls[k]
            if h['box'][0] < cx < h['box'][1] and h['box'][2] < cz < h['box'][3] and h['bottom'] < tops[j]['top'] + 48.0 and h['top'] > tops[i]['top'] + 24.0:
                return False
        return clear(i, j)
    if a.debug:
        print('booster tops', len(launch), file=sys.stderr)
    if a.why:
        ends = [[float(v) for v in e.split(',')] for e in a.why.split(';')]
        i, j = [min(range(len(tops)), key=lambda k: math.dist((centre(tops[k])[0], tops[k]['top'], centre(tops[k])[1]), (e[0], e[1], e[2]))) for e in ends]
        g = gap(tops[i]['face'], tops[j]['face']); rise = tops[j]['top'] - tops[i]['top']
        print('from', tops[i], '\nto', tops[j], '\ngap %.0f rise %.0f envelope %.0f clear %s trigger %s' % (
            g, rise, min(a.reach, envelope(rise, a.safety, a.speed)), clear(i, j), falls_into_trigger(i, j)), file=sys.stderr)
        if i in launch:
            print('booster %.0f u/s: lands %s' % (launch[i], boosted(i, j)), file=sys.stderr)
        sys.exit(0)
    def slope_walk(i, j):
        """Whether j is the terrain cell beside i up or down a walkable slope: its low edge meets i's top within a step."""
        ti, tj = tops[i], tops[j]
        return a.slopes and ti['terrain'] and tj['terrain'] and gap(ti['face'], tj['face']) < 1.0 and \
            tj['low'] - ti['top'] <= STEP and ti['low'] - tj['top'] <= STEP
    def slope_jump(i, j):
        """A jump onto or off a slope cell: its top is its highest sample, a lip, not where a jump lands or leaves."""
        return (tops[i]['slope'] or tops[j]['slope']) and not slope_walk(i, j)
    def blocked(i, j):
        """Why the edge i -> j is not taken, or None when it is."""
        g = gap(tops[i]['face'], tops[j]['face'])
        rise = tops[j]['top'] - tops[i]['top']
        if slope_walk(i, j):
            return None if clear(i, j) else 'not clear'
        if slope_jump(i, j):
            return 'slope'
        if rise > CLIMB:
            return 'rise'
        if g > min(a.reach, envelope(rise, a.safety, a.speed)):
            return 'gap'
        if g < 1.0 and abs(rise) > 18.0 and rise > 0:
            return 'wall'
        if not clear(i, j):
            return 'not clear'
        if falls_into_trigger(i, j):
            return 'trigger'
        return None
    def frontier_edges(n=24):
        """The shortest refused edges out of the reached set, one per unreached top (--debug)."""
        best = {}
        seen_ = set(s % N for s in dist)
        for i in seen_:
            for j in near(i):
                if j in seen_:
                    continue
                g = gap(tops[i]['face'], tops[j]['face']); rise = tops[j]['top'] - tops[i]['top']
                if rise > 400 or rise < -400 or (j in best and best[j][0] <= g):
                    continue
                why_ = blocked(i, j)
                if why_:
                    best[j] = (g, rise, why_, i, j)
        return sorted(best.values(), key=lambda e: (e[2] == 'rise', e[0]))[:n]
    via = {}; boost_from = {}
    N = len(tops)
    levels = int(math.ceil(max(0.0, a.vmax - a.speed) / a.carry)) if a.carry > 0 else 0
    cache = {}
    def static_ok(i, j):
        k = i * N + j
        if len(cache) > 2000000:
            cache.clear()  # a slope-walked map reaches millions of pairs; a bounded cache only costs recomputation
        if k not in cache:
            ci, cj = centre(tops[i]), centre(tops[j])
            g = gap(tops[i]['face'], tops[j]['face']); rise = tops[j]['top'] - tops[i]['top']
            cache[k] = not (g < 1.0 and abs(rise) > 18.0 and rise > 0) and clear(i, j) and not falls_into_trigger(i, j)
        return cache[k]
    dist = {i: 0.0 for i in starts}; prev = {}; q = [(0.0, i) for i in starts]
    done = None
    while q:
        c, s_ = heapq.heappop(q)
        if c > dist.get(s_, 1e18):
            continue
        i, lv = s_ % N, s_ // N
        if i in goals:
            done = s_; break
        for land, door in doors.get(i, []):
            w = 64.0
            if c + w < dist.get(land, 1e18):
                dist[land] = c + w; prev[land] = s_; via[land] = door; boost_from.pop(land, None); heapq.heappush(q, (c + w, land))
        if i in launch:
            for j in near(i, flight_reach(launch[i], -600.0)):
                if boosted(i, j):
                    w = math.dist(centre(tops[i]), centre(tops[j])) + 64.0
                    if c + w < dist.get(j, 1e18):
                        dist[j] = c + w; prev[j] = s_; via.pop(j, None); boost_from[j] = s_; heapq.heappush(q, (c + w, j))
        for j in near(i, 1.0 if tops[i]['slope'] else a.reach if not levels else max(a.reach, envelope(CLIMB, a.safety, a.vmax))):
            g = gap(tops[i]['face'], tops[j]['face'])
            if tops[j]['slope'] and g >= 1.0:
                continue  # a slope cell is only walked onto from the cell beside it
            rise = tops[j]['top'] - tops[i]['top']
            v = a.speed + lv * a.carry
            sw = slope_walk(i, j)
            if not sw and (g > min(a.reach, envelope(rise, a.safety, v)) or rise > CLIMB or slope_jump(i, j)):
                continue
            if not (clear(i, j) if sw else static_ok(i, j)):
                continue
            ci, cj = centre(tops[i]), centre(tops[j])
            w = math.dist(ci, cj) + 2.0 * g + (g * g) / 100.0
            # a walked step keeps no speed; every other hop lands a level up
            nl = 0 if (not levels or sw or (g < 16.0 and abs(rise) < 1.0)) else min(levels, lv + 1)
            n_ = j + nl * N
            if c + w < dist.get(n_, 1e18):
                dist[n_] = c + w; prev[n_] = s_; via.pop(n_, None); boost_from.pop(n_, None); heapq.heappush(q, (c + w, n_))
    if a.debug and os.environ.get('ROUTE_DUMP'):
        json.dump({'reached': [[round(centre(tops[i])[0]), round(tops[i]['top']), round(centre(tops[i])[1])] for i in set(s % N for s in dist)],
                   'all': [[round(centre(t)[0]), round(t['top']), round(centre(t)[1])] for t in tops]}, open(os.environ['ROUTE_DUMP'], 'w'))
    if done is None:
        if a.debug:
            for i in set(s % N for s in dist):
                if i in doors: print('door top reached', centre(tops[i]), tops[i]['top'], [dd[0] for dd in doors[i]], file=sys.stderr)
            print('reached door-less frontier; sample', sorted(centre(tops[i]) for i in set(s % N for s in dist))[:3], file=sys.stderr)
            print('booster tops reached', sorted((round(centre(tops[i])[0]), round(tops[i]['top']), round(centre(tops[i])[1])) for i in set(s % N for s in dist) if i in launch), file=sys.stderr)
            for g, rise, why_, i, j in frontier_edges():
                print('blocked %s gap %.0f rise %.0f from %s %.0f to %s %.0f' % (why_, g, rise, centre(tops[i]), tops[i]['top'], centre(tops[j]), tops[j]['top']), file=sys.stderr)
        reached = max(dist, key=lambda i: dist[i]) % N
        sys.exit('no route to the finish within reach %.0f; %d tops reached, the furthest at %s' % (
            a.reach, len(set(s % N for s in dist)), str(centre(tops[reached]))))
    def walk(i, j):
        return j not in via and j not in boost_from and gap(tops[i % N]['face'], tops[j % N]['face']) < 16.0 and (
            abs(tops[i % N]['top'] - tops[j % N]['top']) < 1.0 or slope_walk(i % N, j % N))
    def walked_through(i, j, k):
        """j is a step on a floor the bot runs straight across: a point there makes it land, and so hop, on every tile."""
        if not (walk(i, j) and walk(j, k)):
            return False
        (ax, az), (bx, bz), (cx, cz) = centre(tops[i % N]), centre(tops[j % N]), centre(tops[k % N])
        u, v = (bx - ax, bz - az), (cx - bx, cz - bz)
        nu, nv = math.hypot(*u), math.hypot(*v)
        return nu > 0 and nv > 0 and (u[0] * v[0] + u[1] * v[1]) / (nu * nv) > math.cos(math.radians(20.0))
    path = [done]
    while path[-1] in prev:
        path.append(prev[path[-1]])
    path.reverse()
    path = [path[0]] + [i for k, i in enumerate(path[1:-1], 1) if not walked_through(path[k - 1], i, path[k + 1])] + path[-1:]
    pts = []
    for k, (h, i) in enumerate(zip(path, path[1:]), 1):
        if i in via:
            x, y, z = via[i]
            pts.append({'at': [round(x), round(y), round(z)], 'radius': 16, 'door': True})
        h, pv, t = h % N, prev[i] % N, tops[i % N]; f = t['face']; cx, cz = centre(t)
        pts.append({'at': [round(cx), round(t['top']), round(cz)],
                    'radius': round(min(32.0, (f[1] - f[0]) / 2, (f[3] - f[2]) / 2))})
        if i not in via and tops[h]['terrain'] and gap(tops[h]['face'], f) >= 8.0 and not (a.slopes and walk(prev[i], i)):
            pts[-1]['hop'] = True  # terrain has no lip to jump at: run on it and the bot walks down into the water
        if i not in via and i not in boost_from and gap(tops[pv]['face'], f) > envelope(t['top'] - tops[pv]['top'], 1.0):
            pts[-1]['hop'] = True  # past a run-speed jump: only speed carried from hop to hop crosses it
        if levels and i not in via and i not in boost_from and gap(tops[pv]['face'], f) >= 16.0:
            pts[-1]['hop'] = True  # a chain of hops carries its speed only while it keeps jumping
        if k + 1 < len(path) and path[k + 1] in boost_from:
            pts[-1]['launch'] = True  # a booster: passed by jumping off it
    print('%s: %d tops, route of %d points, %.0f u' % (a.map, len(tops), len(pts), dist[done]), file=sys.stderr)
    doc = {'id': a.map, 'units': 'manifest units and axes: Godot axes in genre units (x, up, z), what the tools print',
           'how': 'tools/route_plan.py %s --reach %.0f --safety %g' % (a.map, a.reach, a.safety) + (' --speed %g' % a.speed if a.speed != RUN_SPEED else '') + (' --carry %g --vmax %g' % (a.carry, a.vmax) if a.carry > 0 else '') + (' --region %s' % a.region if a.region else '') + (' --slopes' if a.slopes else '') + (' --fall-doors' if a.fall_doors else '') + (' --from %s' % a.frm if a.frm else '') + (' --to %s' % a.to if a.to else ''),
           'points': pts}
    s = json.dumps(doc, indent=1) + '\n'
    if a.out:
        open(a.out, 'w').write(s)
    else:
        print(s)

if __name__ == '__main__':
    main()
