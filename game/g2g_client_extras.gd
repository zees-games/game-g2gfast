extends Node

const G2GGame := preload("g2g_game.gd")
const G2GNetBridge := preload("net/g2g_net_bridge.gd")
const G2GServices := preload("g2g_services.gd")

## The client halves of chat and voice.
##
## [b]Two server-side layers already exist and both are useless without a client that
## answers.[/b] That is this family's most repeated shape with the ends swapped: a
## voice router with nothing capturing and a chat router with nothing to draw are both
## things that work perfectly and do nothing.
##
## Kept out of [G2GClient], which is already about a camera, a sampler, the HUD and the
## keys, and none of this is about any of that.
##
## [b]There is no map-sync client here, and game-arena has one.[/b] The difference is
## real rather than an omission: `G2GGame` drives a [DotMapSession] on every instance
## including a mirroring client, and the bridge already sends a map change as a game
## event that the client's own session loads. Adding [DotMapSyncClient] on top would be
## a second thing loading the same map — which is two owners of one world, and the
## symptom is the world being freed while something still holds it.
##
## [codeblock]
## var extras := G2GClientExtras.new()
## add_child(extras)
## extras.attach(bridge, game)
## [/codeblock]

const CHANNEL := "g2g.client.extras"

## A chat line arrived, with the speaker and what they said kept apart.
##
## [b]Separate from [signal line_received], which flattens them.[/b] A chat box draws the
## name in one colour and the text in another, and a signal that has already joined them
## with a colon is a signal a window has to take back apart.
signal said(speaker: String, text: String, kind: String)

## What is carrying this conversation changed. See [code]DotChatManager.chat_state[/code].
signal chat_relay_changed(relayed: bool)

## A chat line arrived and should be drawn.
signal line_received(text: String)

@export_group("Voice")

## Whether to open the microphone at all.
##
## [b]Capture is started on the first press and never at boot.[/b] A microphone opened
## because a game launched is a microphone nobody agreed to, and on the web it is a
## permission prompt in front of somebody who has not asked for one.
@export var voice_enabled: bool = true

@export var push_to_talk: bool = true

var bridge: G2GNetBridge = null
var game: G2GGame = null

var chat: DotChatClient = null
var voice: DotVoiceManager = null

var _talking: bool = false


func attach(p_bridge: G2GNetBridge, p_game: G2GGame) -> DotResult:
	if p_bridge == null:
		return DotResult.fail(DotError.CODE_STATE, "No bridge to attach to.")

	bridge = p_bridge
	game = p_game

	_build_chat()

	if voice_enabled:
		_build_voice()

	return DotResult.success(self)


# --- Chat ------------------------------------------------------------------

## The client's own view of chat: channels, history, unread counts.
##
## [b]It decides nothing, and that is the point of there being two halves.[/b] The
## server's router decides who hears a line; this holds what arrived, in order, per
## channel — and detects a gap in the sequence, which is how a client tells "I missed
## something" from "nobody spoke".
func _build_chat() -> void:
	chat = DotChatClient.new()
	chat.name = "Chat"
	chat.rules = DotChatRules.new()
	chat.history_limit = 300
	chat.register_as = DotChatClient.SERVICE
	add_child(chat)

	var started := chat.start()

	if not started.ok:
		DotLog.warn(CHANNEL, "the chat client did not start", {
			"why": started.error.message
		})
		return

	for id in [
		G2GServices.CH_ALL, G2GServices.CH_RUNNING,
		G2GServices.CH_TEAM, G2GServices.CH_WHISPER
	]:
		var channel := DotChatChannel.everyone()
		channel.id = id
		chat.add_channel(channel)

	chat.message_received.connect(
		func(message: DotChatMessage, _channel: StringName) -> void:
			# A dot-chat line's kind is "say" on every channel; the channel is what makes
			# it a team line, and "team" is what the chat box colours.
			var kind := "team" if message.channel in [G2GServices.CH_TEAM, G2GServices.CH_RUNNING] else message.kind_name()
			said.emit(speaker_of(message), text_of(message), kind)
			line_received.emit(message.describe())
	)

	chat.gap_detected.connect(
		func(expected: int, received: int) -> void:
			DotLog.info(CHANNEL, "a chat line was missed", {
				"expected": expected, "received": received
			})
	)


## Puts a line the server sent into this client's own history.
##
## [b]This is the entry point, and nothing called it.[/b] dot-chat's router decides who
## hears a line and then hands it to dot-server's chat manager to put on the wire — so
## on the client it arrives on `DotClientLink.chat_received`, not through anything
## dot-chat owns. A `DotChatClient` that nothing feeds is a history that stays empty
## and an unread count that stays zero, while chat works perfectly on screen.
##
## Found by the family's own detector: a public method whose name occurs once in its
## repository is a method nothing calls.
func receive_wire(payload: Dictionary) -> void:
	# Not a line at all: the server saying what is carrying chat. It arrives before the
	# first line does, so the client can decide whether to draw a box rather than drawing
	# one and taking it away a moment later.
	if str(payload.get("kind", "")) == "state":
		chat_relay_changed.emit(bool(payload.get("relay", false)))
		return

	if chat != null:
		var taken := chat.receive(payload)

		if taken.ok:
			# `message_received` fires from inside `receive`, so the line has already
			# been emitted. Returning is what stops it being drawn twice.
			return

	# Not a shape `DotChatClient` knows. dot-server's own chat manager sends a simpler
	# payload than dot-chat's wire, and a server running WITHOUT dot-chat sends only
	# that — so this is the other deployment rather than a failure path.
	#
	# [b]It used to be unreachable, and that is what made every line in this game blank.[/b]
	# `DotChatMessage.from_dictionary` gave every key a default, so dot-server's payload
	# parsed as a valid message with no text, no sender and no channel — `receive` returned
	# ok and this never ran. dot-chat refuses a dictionary with no `m` now.
	var speaker := str(payload.get("name", ""))
	var text := str(payload.get("text", payload.get("message", "")))

	said.emit(speaker, text, str(payload.get("kind", "all")))
	line_received.emit(text if speaker == "" else "%s: %s" % [speaker, text])


## Who a dot-chat line is drawn as said by: nobody, for a join or leave notice.
##
## [b]A join or leave notice is the server's line about a player, not the player's line.[/b]
## It carries the player's name as its sender and no text at all (dot-chat's `_presence`),
## so drawing it as `sender: text` put a bare "Guest 435:" in the chat box on every join,
## which read as a chat command echoed with its text stripped. It is drawn as a plain line,
## worded by [method DotChatMessage.describe]. Only those two kinds: an ADMIN line's sender
## is the admin, and `describe()` would drop the name.
static func speaker_of(message: DotChatMessage) -> String:
	return "" if is_presence(message) else message.sender_name


## The text a dot-chat line is drawn with. See [method speaker_of].
static func text_of(message: DotChatMessage) -> String:
	return message.describe() if is_presence(message) else message.text


## A join or leave notice: a name and no text.
static func is_presence(message: DotChatMessage) -> bool:
	return message.kind in [DotChatMessage.Kind.JOIN, DotChatMessage.Kind.LEAVE]


# --- Voice -----------------------------------------------------------------

func _build_voice() -> void:
	var config := DotVoiceConfig.new()
	config.capture_enabled = false
	config.push_to_talk = push_to_talk
	config.jitter_ms = 60.0

	voice = DotVoiceManager.new()
	voice.name = "Voice"
	voice.config = config
	voice.config_file = ""
	voice.register_service = true
	# Not positional. The server routes voice to everybody by default here — a course
	# is long and thin and half the server is two hundred metres away — so playing it
	# from a direction would put most of the room behind the listener. game-arena is
	# the other way round and says so.
	voice.positional_playback = false
	voice.playback_root_ref = DotNodeRef.of_self()
	add_child(voice)

	# One frame out, one call. Without it a client captured, encoded and counted every frame
	# it sent nowhere: received voice played here, and nobody ever heard this player.
	voice.send_fn = func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.link != null:
			bridge.link.send_voice_frame(bytes)

	bridge.voice_in_fn = func(payload: PackedByteArray) -> void:
		if voice != null:
			voice.receive(payload)

	# The menu's voice rows bind to this, and the server's sv_voice_enable reaches it.
	voice.publish_as_client()
	var _following := voice.follow_cvars(DotRegistry.get_service(&"dot_client_link"))


## Holds or releases the talk key.
func set_talking(pressed: bool) -> void:
	if voice == null:
		return

	# The first press opens the microphone (dot-voice's update_talk), and only then: a
	# browser asks for it at that moment, attached to the key the player pressed.
	var started := voice.update_talk(pressed)

	if pressed and not started.ok:
		# Headless, no device, or the browser refused; update_talk returns it once a press.
		# Reported at all because [AudioServer] claims a working sound card when there is
		# none: 44100 Hz, a "Default" input device and zero latency, with only
		# `get_driver_name()` saying "Dummy".
		DotLog.info(CHANNEL, "voice capture is not available", {"why": started.error.message})
		return

	_talking = pressed and voice.server_enabled


func is_talking() -> bool:
	return _talking


func describe() -> Dictionary:
	return {
		"talking": _talking,
		"voice": voice.describe() if voice != null else {},
		"chat_lines": chat.describe_lines().size() if chat != null else 0,
	}
