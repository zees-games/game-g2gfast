"""Is a texture a map packed the source game's own? Asked of the game's archives on /extra.

Christian's rule for imported maps (`[g2g-maps-stock-1]`): the map's own texture, else a
Kenney stand-in, else the grid -- never the source game's textures. A mapper can pack the
source game's texture into the .bsp, and it then decodes like the map's own: bhop_arcane_v2
drew 54% of its triangles that way (2026-10-11). The importer asks this module about every
texture it decodes and drops one whose pixels are the archive's at the same path.

Only on a machine with the archives (`/extra/*_dir.vpk`, Christian's own copy, reference
only). Nothing is read out of them except to compare, and nothing read is written anywhere.
Without them every answer is "not stock", and publish_maps.gd's guard is what is left.
"""
import glob
import os
import struct

ARCHIVES = "/extra"

_index = None


def _read_dir(path):
    """{lowercased path: (archive number, offset, length, preload bytes)} of a VPK v1/v2 directory."""
    out = {}
    with open(path, "rb") as f:
        sig, ver, _tree = struct.unpack("<III", f.read(12))
        if sig != 0x55AA1234:
            return out
        if ver == 2:
            f.read(16)

        def cstr():
            b = bytearray()
            while True:
                c = f.read(1)
                if not c or c == b"\0":
                    return b.decode("latin-1")
                b += c

        while True:
            ext = cstr()
            if not ext:
                break
            while True:
                folder = cstr()
                if not folder:
                    break
                while True:
                    name = cstr()
                    if not name:
                        break
                    _crc, pre, arc, off, ln, _term = struct.unpack("<IHHIIH", f.read(18))
                    preload = f.read(pre)
                    key = ("%s/%s.%s" % (folder, name, ext) if folder.strip() else "%s.%s" % (name, ext)).lower()
                    out[key] = (arc, off, ln, preload)
    return out


def _load():
    global _index
    if _index is None:
        _index = {}
        for d in sorted(glob.glob(os.path.join(ARCHIVES, "**", "*_dir.vpk"), recursive=True)):
            for key, entry in _read_dir(d).items():
                _index.setdefault(key, (d, entry))
    return _index


def original(path):
    """The archive's bytes for `materials/...vtf` [param path], or None when it has none."""
    found = _load().get(path.lower())
    if found is None:
        return None
    d, (arc, off, ln, pre) = found
    if arc == 0x7FFF:
        return None
    with open("%s_%03d.vpk" % (d[:-len("_dir.vpk")], arc), "rb") as a:
        a.seek(off)
        return pre + a.read(ln)


def is_stock(path, raw, decode):
    """Whether [param raw] (a VTF at [param path]) is the archive's own image: the same
    bytes, or the same pixels after [param decode] (a re-saved copy with another header)."""
    theirs = original(path)
    if theirs is None:
        return False
    if theirs == raw:
        return True
    try:
        a, b = decode(raw), decode(theirs)
    except ValueError:
        return False
    return a[0] == b[0] and a[1] == b[1] and bytes(a[2]) == bytes(b[2])
