#!/usr/bin/env python3
"""Plan a bhop route over an imported map's collision, and write maps/routes/<id>.json."""
import json, struct, sys, heapq, math, argparse, os

HEADROOM = 72.0      # a top with a solid this close above it is not stood on
CELL = 64.0         # terrain is binned into cells this wide
CLIMB = 54.0         # the most a jump lands on above take-off (57 apex, less margin)

PIT_MARGIN = 2.0  # the hull stands a little above the box top it is caught by


def load(mid, root):
    base = '%s/maps/imported/%s/%s' % (root, mid, mid)
    d = json.load(open(base + '.json')); blob = open(base + '.bin', 'rb').read()
    c = d['collision']; off = c['hull_offset']; hulls = []
    for _ in range(c['hull_count']):
        n = struct.unpack_from('<I', blob, off)[0]; off += 4
        f = struct.unpack_from('<%df' % (n * 3), blob, off); off += n * 12
        xs, ys, zs = f[0::3], f[1::3], f[2::3]
        ty = max(ys)
        top = [(xs[i], zs[i]) for i in range(n) if ys[i] > ty - 1]
        hulls.append({'box': (min(xs), max(xs), min(zs), max(zs)), 'bottom': min(ys), 'top': ty,
                      'face': (min(p[0] for p in top), max(p[0] for p in top),
                               min(p[1] for p in top), max(p[1] for p in top)) if len(top) >= 3 else None})
    # Terrain (displacements) is triangles, not hulls: every walkable triangle is binned
    # into a 64-unit cell per height band, and each cell is a top of its own.
    cells = {}
    vc = c.get('displacement_vertex_count', 0); ic = c.get('displacement_index_count', 0)
    if vc and ic:
        v = struct.unpack_from('<%df' % (vc * 3), blob, c['displacement_vertex_offset'])
        ix = struct.unpack_from('<%di' % ic, blob, c['displacement_index_offset'])
        for k in range(0, ic - 2, 3):
            p = [v[ix[k + m] * 3: ix[k + m] * 3 + 3] for m in range(3)]
            ax, ay, az = [p[1][q] - p[0][q] for q in range(3)]
            bx, by, bz = [p[2][q] - p[0][q] for q in range(3)]
            nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
            ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            if abs(ny) / ln < 0.7:
                continue
            cx = sum(q[0] for q in p) / 3; cz = sum(q[2] for q in p) / 3; cy = max(q[1] for q in p)
            key = (int(math.floor(cx / CELL)), int(math.floor(cz / CELL)), int(math.floor(cy / 96.0)))
            cells[key] = max(cells.get(key, -1e18), cy)
    for (gx, gz, _), y in cells.items():
        hulls.append({'box': None, 'bottom': y - 1.0, 'top': y,
                      'face': (gx * CELL, (gx + 1) * CELL, gz * CELL, (gz + 1) * CELL)})
    return d, hulls

def teleports(mid, root, d):
    """Every teleport as (xz box, y range, destination): the map's own trigger_teleports when the
    .bsp is beside (stage gates, lane exits and pits are not in the manifest, only their arrivals
    are), else the manifest's TELEPORT zones. A staged map is a graph: a gate moves the player
    from one section to the next, a pit back to a lane start."""
    out = []
    bsp = os.environ.get('G2G_BSP') or os.path.join(root, '..', 'inspirations', 'g2gfast', mid + '.bsp')
    if os.path.isfile(bsp):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from bsp_read import Bsp, to_godot
        b = Bsp(bsp); b.load()
        dest = {}
        for e in b.entities:
            if e.get('targetname') and e.get('classname') in ('info_teleport_destination', 'info_target', 'info_landmark', 'point_teleport'):
                dest.setdefault(e['targetname'], e)
        for e in b.entities:
            if e.get('classname') != 'trigger_teleport' or not e.get('model', '').startswith('*'):
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

def tiles(f, top):
    """A top as itself, or as a row of tiles when it is long enough that its centre is nowhere near its ends."""
    area = (f[1] - f[0]) * (f[3] - f[2])
    tile = max(TILE, math.sqrt(area / 2500.0))   # a floor the size of the map still gets tiles, only coarser
    nx = max(1, int(math.ceil((f[1] - f[0]) / tile))); nz = max(1, int(math.ceil((f[3] - f[2]) / tile)))
    if nx == 1 and nz == 1:
        return [{'face': f, 'top': top}]
    out = []
    for ix in range(nx):
        for iz in range(nz):
            out.append({'face': (f[0] + (f[1] - f[0]) * ix / nx, f[0] + (f[1] - f[0]) * (ix + 1) / nx,
                                 f[2] + (f[3] - f[2]) * iz / nz, f[2] + (f[3] - f[2]) * (iz + 1) / nz), 'top': top})
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
    ap.add_argument('--out'); ap.add_argument('--debug', action='store_true')
    a = ap.parse_args()
    d, hulls = load(a.map, a.root)
    region = [float(v) for v in a.region.split(',')] if a.region else None
    tops = []
    for i, h in enumerate(hulls):
        f = h['face']
        if f is None or f[1] - f[0] < 16 or f[3] - f[2] < 16:
            continue
        if region and not overlap(f, region):
            continue
        over = [o['box'] for j, o in enumerate(hulls)
                if j != i and o['box'] is not None and h['top'] - 1 < o['bottom'] < h['top'] + HEADROOM and overlap(f, o['box'])]
        for t in tiles(f, h['top']):
            tf = t['face']; shade = 0.0
            for b in over:
                shade += max(0.0, min(tf[1], b[1]) - max(tf[0], b[0])) * max(0.0, min(tf[3], b[3]) - max(tf[2], b[2]))
            if shade <= 0.5 * (tf[1] - tf[0]) * (tf[3] - tf[2]):
                tops.append(t)
    tps, tps_from_bsp = teleports(a.map, a.root, d)
    pits = [z for z in d['zones'] if z['kind'] == 'RESPAWN' and z.get('track', 0) == 0]
    def in_pit(t):
        f = t['face']; cx, cz = (f[0] + f[1]) / 2, (f[2] + f[3]) / 2
        # a RESPAWN box reaches up to the floor it catches: anything at or under its top is a fall
        if any(min(z['min'][0], z['max'][0]) <= cx <= max(z['min'][0], z['max'][0]) and
               min(z['min'][2], z['max'][2]) <= cz <= max(z['min'][2], z['max'][2]) and
               min(z['min'][1], z['max'][1]) - 8 <= t['top'] <= max(z["min"][1], z["max"][1]) + PIT_MARGIN for z in pits):
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
    s0 = under(sp[0], sp[2], sp[1], 3000.0)
    starts = [s0] if s0 is not None else []
    goals = set(i for i, t in enumerate(tops) if overlap(t['face'], ebox) and ey[0] - 300 <= t['top'] <= ey[1])
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
    def near(i):
        f = tops[i]['face']; seen = set()
        for gx in range(int(math.floor((f[0] - a.reach) / B)), int(math.floor((f[1] + a.reach) / B)) + 1):
            for gz in range(int(math.floor((f[2] - a.reach) / B)), int(math.floor((f[3] + a.reach) / B)) + 1):
                for j in grid.get((gx, gz), []):
                    if j != i and j not in seen:
                        seen.add(j); yield j
    # Hull boxes in a grid, for "is the way from one top to the next clear at body height".
    hgrid = {}
    for k, h in enumerate(hulls):
        b = h['box']
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
                        if h['bottom'] < y < h['top'] - 1:
                            return False
        return True
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
    via = {}
    dist = {i: 0.0 for i in starts}; prev = {}; q = [(0.0, i) for i in starts]
    done = None
    while q:
        c, i = heapq.heappop(q)
        if c > dist.get(i, 1e18):
            continue
        if i in goals:
            done = i; break
        for land, door in doors.get(i, []):
            w = 64.0
            if c + w < dist.get(land, 1e18):
                dist[land] = c + w; prev[land] = i; via[land] = door; heapq.heappush(q, (c + w, land))
        for j in near(i):
            g = gap(tops[i]['face'], tops[j]['face'])
            rise = tops[j]['top'] - tops[i]['top']
            if g > a.reach or rise > CLIMB:
                continue
            if g < 1.0 and abs(rise) > 18.0 and rise > 0:
                continue  # a wall, not a step
            if not clear(i, j) or falls_into_trigger(i, j):
                continue
            ci, cj = centre(tops[i]), centre(tops[j])
            w = math.dist(ci, cj) + 2.0 * g + (g * g) / 100.0
            if c + w < dist.get(j, 1e18):
                dist[j] = c + w; prev[j] = i; via.pop(j, None); heapq.heappush(q, (c + w, j))
    if a.debug and os.environ.get('ROUTE_DUMP'):
        json.dump({'reached': [[round(centre(tops[i])[0]), round(tops[i]['top']), round(centre(tops[i])[1])] for i in dist],
                   'all': [[round(centre(t)[0]), round(t['top']), round(centre(t)[1])] for t in tops]}, open(os.environ['ROUTE_DUMP'], 'w'))
    if done is None:
        if a.debug:
            for i in dist:
                if i in doors: print('door top reached', centre(tops[i]), tops[i]['top'], [dd[0] for dd in doors[i]], file=sys.stderr)
            print('reached door-less frontier; sample', sorted(centre(tops[i]) for i in dist)[:3], file=sys.stderr)
        reached = max(dist, key=lambda i: dist[i])
        sys.exit('no route to the finish within reach %.0f; %d tops reached, the furthest at %s' % (
            a.reach, len(dist), str(centre(tops[reached]))))
    path = [done]
    while path[-1] in prev:
        path.append(prev[path[-1]])
    path.reverse()
    pts = []
    for i in path[1:]:
        if i in via:
            x, y, z = via[i]
            pts.append({'at': [round(x), round(y), round(z)], 'radius': 16, 'door': True})
        t = tops[i]; f = t['face']; cx, cz = centre(t)
        pts.append({'at': [round(cx), round(t['top']), round(cz)],
                    'radius': round(min(32.0, (f[1] - f[0]) / 2, (f[3] - f[2]) / 2))})
    print('%s: %d tops, route of %d points, %.0f u' % (a.map, len(tops), len(pts), dist[done]), file=sys.stderr)
    doc = {'id': a.map, 'units': 'manifest units and axes: Godot axes in genre units (x, up, z), what the tools print',
           'how': 'tools/route_plan.py %s --reach %.0f' % (a.map, a.reach) + (' --region %s' % a.region if a.region else ''),
           'points': pts}
    s = json.dumps(doc, indent=1) + '\n'
    if a.out:
        open(a.out, 'w').write(s)
    else:
        print(s)

main()
