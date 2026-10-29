extends RefCounted

## The exit probe of `dedicated.gd`: the suite run once more in a fresh process, to read what it leaves at exit.

## The copy is killed after this many seconds, and the probe fails. `-- --exit-probe-seconds N` lowers it.
const SECONDS := 300


static func seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return SECONDS


## Runs [param host]'s scene again with [param flag]: `[exit code, stdout, stderr, killed, seconds allowed]`.
## A leak is reported by the engine after `quit()`, so only a second process can read it.
## Not `OS.execute`: it blocks, and a hung copy held the run and outlived the outer `timeout`.
## Polled to a deadline and drained each pass (a full pipe blocks the copy); stdin stays open, so suites turn the console off.
static func run(host: Node, flag: String) -> Array:
	var allowed := seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit, %d s allowed)" % allowed)
	var scene: String = host.scene_file_path if host.scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), scene, "--", flag,
	])
	var wrapped := false
	# coreutils `timeout` outlives this process, so a copy orphaned by the outer one still dies (exit 124).
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(allowed), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, allowed]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (allowed + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		drain(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await host.get_tree().create_timer(0.1).timeout
	# The leak report is the last thing the copy writes, after the final pass.
	drain(pipes, bytes)

	# OS.kill has already reaped it, and asking a reaped pid for its exit code is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, allowed]


static func drain(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


static func line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


static func last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
