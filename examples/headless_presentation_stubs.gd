extends DotGameCheckSuite

## The stand-ins headless_presentation builds on: a rendezvous server and a menu host.

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives. The delay is the point: a
## coroutine that never suspends passes against an answer inside the call even without `await`.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## The ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(38900, 38960):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open.duplicate():
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## A client with the methods the menu's pages ask. Nothing in it decides anything.
class FakeHost:
	extends Node
	var style: StringName = &"normal"
	var light := false
	var third := false
	var preset: StringName = &""
	var edited := 0

	func menu_styles() -> Array:
		return [{"id": &"normal", "name": "Normal"}, {"id": &"sideways", "name": "Sideways"}]

	func menu_style() -> StringName:
		return style

	func menu_choose_style(id: StringName) -> void:
		style = id

	func menu_flashlight_allowed() -> bool:
		return true

	func menu_flashlight_on() -> bool:
		return light

	func menu_set_flashlight(on: bool) -> void:
		light = on

	func menu_third_person_allowed() -> bool:
		return false

	func menu_third_person_on() -> bool:
		return third

	func menu_set_third_person(on: bool) -> void:
		third = on

	func menu_layout_presets() -> Array:
		return [[&"minimal", "Minimal"]]

	func menu_apply_layout_preset(id: StringName) -> void:
		preset = id

	func menu_edit_layout() -> void:
		edited += 1

	func menu_where() -> String:
		return "surf_test  ·  offline"

	func menu_leave_label() -> String:
		return "Quit game"
