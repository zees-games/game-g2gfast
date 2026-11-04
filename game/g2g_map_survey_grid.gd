extends "g2g_map_survey_geometry.gd"

## The raster and the cell graph of G2GMapSurvey.



func _rasterise() -> void:
	var low := Vector2(INF, INF)
	var high := -low

	for s in solids:
		low = low.min(Vector2(s.bounds.position.x, s.bounds.position.z))
		high = high.max(Vector2(s.bounds.end.x, s.bounds.end.z))

	# One cell of air round everything, so an edge of the map is an edge.
	_origin = low - Vector2(CELL, CELL)
	_nx = int(ceil((high.x - low.x) / CELL)) + 3
	_nz = int(ceil((high.y - low.y) / CELL)) + 3

	var raw: Dictionary = {}

	for s in solids:
		var ix0 := maxi(0, int(floor((s.bounds.position.x - _origin.x) / CELL)))
		var ix1 := mini(_nx - 1, int(floor((s.bounds.end.x - _origin.x) / CELL)))
		var iz0 := maxi(0, int(floor((s.bounds.position.z - _origin.y) / CELL)))
		var iz1 := mini(_nz - 1, int(floor((s.bounds.end.z - _origin.y) / CELL)))
		var up := s.inverse.basis.y
		var half := s.size * 0.5

		if s.xform.basis.is_equal_approx(Basis.IDENTITY):
			var span := [s.bounds.position.y, s.bounds.end.y, true, 0.0, 0.0]
			var ax0 := maxi(ix0, int(ceil((s.bounds.position.x - _origin.x) / CELL - 0.5)))
			var ax1 := mini(ix1, int(floor((s.bounds.end.x - _origin.x) / CELL - 0.5)))
			var az0 := maxi(iz0, int(ceil((s.bounds.position.z - _origin.y) / CELL - 0.5)))
			var az1 := mini(iz1, int(floor((s.bounds.end.z - _origin.y) / CELL - 0.5)))
			for iz in range(az0, az1 + 1):
				for ix in range(ax0, ax1 + 1):
					var col := ix + iz * _nx
					var list: Array = raw.get(col, [])
					list.append(span)
					raw[col] = list
			continue

		for iz in range(iz0, iz1 + 1):
			for ix in range(ix0, ix1 + 1):
				var x := _origin.x + (float(ix) + 0.5) * CELL
				var z := _origin.y + (float(iz) + 0.5) * CELL
				var a := s.inverse * Vector3(x, 0.0, z)

				# A vertical line through the box, in the box's own space: a + y * up.
				var t_in := -INF
				var t_out := INF
				var exit_axis := -1
				var missed := false

				for axis in range(3):
					if absf(up[axis]) < 1e-9:
						if absf(a[axis]) > half[axis]:
							missed = true
							break
						continue

					var t1 := (-half[axis] - a[axis]) / up[axis]
					var t2 := (half[axis] - a[axis]) / up[axis]
					t_in = maxf(t_in, minf(t1, t2))

					if maxf(t1, t2) < t_out:
						t_out = maxf(t1, t2)
						exit_axis = axis

				if missed or t_in >= t_out or exit_axis < 0:
					continue

				var local_normal := Vector3.ZERO
				local_normal[exit_axis] = signf(up[exit_axis])
				var normal := (s.xform.basis * local_normal).normalized()
				var standable := normal.y >= cos_limit

				var col := ix + iz * _nx
				var list: Array = raw.get(col, [])
				list.append([t_in, t_out, standable, normal.x, normal.z])
				raw[col] = list

	_top_max.resize(_nx * _nz)
	_top_max.fill(-INF)
	_bottom_min.resize(_nx * _nz)
	_bottom_min.fill(INF)

	for col: int in raw:
		var list: Array = raw[col]

		if list.size() == 1:
			var only := PackedFloat32Array()
			_push_span(only, list[0])
			_spans[col] = only
			_bottom_min[col] = only[0]
			_top_max[col] = only[1]
			continue

		list.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))

		var merged := PackedFloat32Array()
		var current: Array = (list[0] as Array).duplicate()

		for k in range(1, list.size()):
			var next: Array = list[k]
			if float(next[0]) <= float(current[1]) + 0.5:
				if float(next[1]) > float(current[1]) + 0.01:
					current[1] = next[1]
					current[2] = next[2]
					current[3] = next[3]
					current[4] = next[4]
				elif absf(float(next[1]) - float(current[1])) <= 0.01 and bool(next[2]):
					current[2] = true
			else:
				_push_span(merged, current)
				current = next.duplicate()

		_push_span(merged, current)
		_spans[col] = merged
		_bottom_min[col] = merged[0]
		_top_max[col] = merged[merged.size() - 4]


func _solid_between(col: int, y0: float, y1: float) -> bool:
	if _top_max[col] <= y0 or _bottom_min[col] >= y1:
		return false
	var spans: PackedFloat32Array = _spans.get(col, PackedFloat32Array())
	for k in range(0, spans.size(), 5):
		if spans[k] < y1 and spans[k + 1] > y0:
			return true
	return false


func _too_tall(col: int, y: float) -> bool:
	return _top_max[col] > y + climb


func _floor_near(col: int, y: float) -> bool:
	if _top_max[col] < y - step:
		return false
	var spans: PackedFloat32Array = _spans.get(col, PackedFloat32Array())
	for k in range(0, spans.size(), 5):
		if spans[k + 2] > 0.5 and absf(spans[k + 1] - y) <= step:
			return true
	return false


func _find_cells() -> void:
	_col_first.resize(_nx * _nz)
	_col_first.fill(-1)
	_col_count.resize(_nx * _nz)
	_col_count.fill(0)

	var cols: Array = _spans.keys()
	cols.sort()

	for col: int in cols:
		var spans: PackedFloat32Array = _spans[col]
		var ix := col % _nx
		var iz := col / _nx
		for k in range(0, spans.size(), 5):
			if spans[k + 2] < 0.5:
				continue

			var y := spans[k + 1]

			if k + 5 < spans.size() and spans[k + 5] - y < headroom:
				continue

			var clear := true
			for d in NEIGHBOURS:
				var jx := ix + d.x
				var jz := iz + d.y
				if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
					continue
				if _solid_between(jx + jz * _nx, y + step, y + headroom):
					clear = false
					break

			if not clear:
				continue

			if _col_count[col] == 0:
				_col_first[col] = _node_col.size()
			_col_count[col] += 1
			_node_col.append(col)
			_node_y.append(y)


# --- Regions ------------------------------------------------------------------

func _find(n: int) -> int:
	while _parent[n] != n:
		_parent[n] = _parent[_parent[n]]
		n = _parent[n]
	return n


func _join_regions() -> void:
	_parent.resize(_node_col.size())
	for n in range(_node_col.size()):
		_parent[n] = n

	for n in range(_node_col.size()):
		var col := _node_col[n]
		var ix := col % _nx
		var iz := col / _nx

		for d in SIDES:
			var jx := ix + d.x
			var jz := iz + d.y
			if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
				continue
			var jcol := jx + jz * _nx
			for m in range(_col_first[jcol], _col_first[jcol] + _col_count[jcol]):
				if absf(_node_y[m] - _node_y[n]) <= step:
					var ra := _find(n)
					var rb := _find(m)
					if ra != rb:
						_parent[ra] = rb

	var index: Dictionary = {}
	_node_region.resize(_node_col.size())

	for n in range(_node_col.size()):
		var root := _find(n)
		if not index.has(root):
			index[root] = index.size()
			_region_low.append(Vector3(INF, INF, INF))
			_region_high.append(Vector3(-INF, -INF, -INF))
			_region_count.append(0)
			_region_edge.append(PackedInt32Array())
			_out.append({})

		var r: int = index[root]
		_node_region[n] = r
		var at := _node_at(n)
		_region_low[r] = _region_low[r].min(at)
		_region_high[r] = _region_high[r].max(at)
		_region_count[r] += 1


func _node_at(n: int) -> Vector3:
	var col := _node_col[n]
	return Vector3(
		_origin.x + (float(col % _nx) + 0.5) * CELL,
		_node_y[n],
		_origin.y + (float(col / _nx) + 0.5) * CELL
	)
