# NOVA Swift — Godot sound.
#
# The frontend half of the sound path. Everything that decides WHAT plays lives
# in the shared Swift core and arrives through NovaWorld's "Audio" bridge section:
#   · snd decoding           -> sound_info / sound_pcm (16-bit mono PCM, native rate)
#   · event -> snd mapping   -> SoundCues (weapons, bööm, cloak, docking, chatter,
#                               beeps, Warp up/out, Red Alert, Klaxxon)
#   · the original's 16-voice list (priority/volume ranking, only the first 8
#     heard, same-sound stacking guards, the 200 px / 850²/d² distance law with a
#     1/8 floor, mono and unpanned like the original) -> SoundVoiceBoard
# so this script only owns Godot objects: an AudioStreamWAV per sound id and one
# AudioStreamPlayer per virtual voice, driven by the rows drain_sound_cues()
# returns. No mixing rule is reimplemented here.
#
# Music: the Apple app plays exactly one track — the title-menu music named by
# STR# 130 #2 (an external mp3/mov, not a snd resource), only over the main menu
# (audio/TitleMusic.gd). The one looping SFX voice is the landed spaceport's
# ambient bed (below), exactly like GameAudio.startAmbient.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Node

const Prefs = preload("res://Prefs.gd")

var _nova: Object
var _players: Array[AudioStreamPlayer] = []
var _streams := {}            # snd id -> AudioStreamWAV, or null for "no such sound"
var _stride := 6

## Output levels, 0…1: master × effects for everything, × interface for the
## beeps and escort chatter (the Apple app's master / sfx / ui sliders).
var master_volume := 1.0
var sfx_volume := 1.0
var ui_volume := 1.0
var muted := false
## Set by the Shell: returns true while the main menu (or any pre-game screen) is up, when no
## spaceport ambience may sound even though the world still reports "landed".
var menu_probe: Callable = Callable()

# The landed spaceport's ambient loop (GameAudio.startAmbient / stopAmbient): one dedicated
# looping player, started on the landing edge, cut on takeoff / leaving the game.
var _ambient: AudioStreamPlayer
var _ambient_id := -1
var _was_landed := false

# The quickHyperjump enhancement's charge-up loop (GameAudio.startHyperspaceCharge): snd 128 looped from the
# start of the turn until the jump commits. The bridge says which snd (hyperspace_charge_loop_sound, -1 = none).
var _charge: AudioStreamPlayer
var _charge_id: int = -1

# What the last drain asked each voice to do, for tests and debugging.
var cues_started := 0
## snd ids a cue asked for that the data cannot decode (tests/plugins_load_selfcheck.gd).
var missing_sounds: Dictionary = {}


func setup(nova: Object) -> void:
	_nova = nova
	_stride = int(nova.sound_stride())
	for i in int(nova.sound_voice_count()):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		add_child(p)
		_players.append(p)
	_ambient = AudioStreamPlayer.new()
	_ambient.name = "Ambient"
	add_child(_ambient)
	_charge = AudioStreamPlayer.new()
	_charge.name = "HyperspaceCharge"
	add_child(_charge)


func _process(_delta: float) -> void:
	if _nova != null:
		apply(_nova.drain_sound_cues())
		_track_ambient()
		_track_charge()
		if _ambient != null and _ambient.playing:
			_ambient.volume_db = _db(1.0, false)   # follows the Settings sliders live


## The ambient loop follows the docked state: it starts on the landing edge and stops on takeoff
## (`GameContainerView` onChange of landedSpobID). Nothing sounds over the main menu.
func _track_ambient() -> void:
	var landed: bool = _nova.is_landed()
	if menu_probe.is_valid() and bool(menu_probe.call()):
		landed = false
	if landed == _was_landed:
		return
	_was_landed = landed
	if not landed:
		stop_ambient()
	elif _nova.has_method("landed_ambient_sound"):
		start_ambient(int(_nova.landed_ambient_sound()))


## `GameAudio.startAmbient`: loop the stellar's CustSndID snd gaplessly while docked. "Ambient
## Sounds" off (Preferences, 0x00491f30), mute, a missing/undecodable sound or id < 0 = silence.
## Level = master x effects (the sound-preference step is folded into master).
func start_ambient(sound_id: int) -> void:
	if _ambient == null:
		return
	# The original loads CustSndID only when it is >= 128 (0x00491f30), and when "Ambient Sounds" is on.
	if not bool(Prefs.get_value("classic", "ambient_sounds")) or muted or sound_id < 128:
		stop_ambient()
		return
	var base: AudioStreamWAV = stream_for(sound_id)
	if base == null:
		stop_ambient()
		return
	var loop: AudioStreamWAV = base.duplicate() as AudioStreamWAV
	loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end = int(float(base.data.size()) / (4.0 if base.stereo else 2.0))
	_ambient_id = sound_id
	_ambient.stream = loop
	_ambient.pitch_scale = 1.0
	_ambient.volume_db = _db(1.0, false)
	_ambient.play()


func stop_ambient() -> void:
	_ambient_id = -1
	if _ambient != null:
		_ambient.stop()


## The charge loop follows the bridge: it starts when a quick hyperjump begins and is cut the frame the jump
## commits (or the player dies). Mute, or a sound the data cannot decode, = silence.
func _track_charge() -> void:
	if _charge == null or not _nova.has_method("hyperspace_charge_loop_sound"):
		return
	var want: int = int(_nova.hyperspace_charge_loop_sound())
	if muted:
		want = -1
	if want == _charge_id:
		if _charge.playing:
			_charge.volume_db = _db(1.0, false)   # follows the Settings sliders live
		return
	if want < 0:
		stop_charge()
		return
	var base: AudioStreamWAV = stream_for(want)
	if base == null:
		stop_charge()
		return
	var loop: AudioStreamWAV = base.duplicate() as AudioStreamWAV
	loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end = int(float(base.data.size()) / (4.0 if base.stereo else 2.0))
	_charge_id = want
	_charge.stream = loop
	_charge.pitch_scale = 1.0
	_charge.volume_db = _db(1.0, false)
	_charge.play()


func stop_charge() -> void:
	_charge_id = -1
	if _charge != null:
		_charge.stop()


## True while the quickHyperjump charge loop is sounding (tests).
func charge_playing() -> bool:
	return _charge != null and _charge.playing


## True while the spaceport loop is sounding (tests).
func ambient_playing() -> bool:
	return _ambient != null and _ambient.playing


## `AppModel.returnToMainMenu` / game exit: every voice and the loop stop (stopAllLoops + stop(0)).
func stop_all() -> void:
	stop_ambient()
	stop_charge()
	_was_landed = false
	if _nova != null and _nova.has_method("sound_stop"):
		_nova.sound_stop(0)


## Apply one drain_sound_cues() result. Public so a test can feed it directly.
func apply(rows: PackedFloat32Array) -> void:
	var i := 0
	while i + _stride <= rows.size():
		var node := int(rows[i])
		var sound_id := int(rows[i + 1])
		var gain := rows[i + 2]
		var action := int(rows[i + 3])
		var rate := rows[i + 4]
		var is_ui := rows[i + 5] > 0.5
		i += _stride
		if node < 0 or node >= _players.size():
			continue
		var p := _players[node]
		match action:
			2:
				p.stop()
			1:
				var stream := stream_for(sound_id)
				if stream == null:
					continue
				p.stream = stream
				p.pitch_scale = maxf(rate, 0.01)
				p.volume_db = _db(gain, is_ui)
				p.play()
				cues_started += 1
			_:
				p.volume_db = _db(gain, is_ui)


func _db(gain: float, is_ui: bool) -> float:
	var level := gain * master_volume * sfx_volume * (ui_volume if is_ui else 1.0)
	if muted or level <= 0.0:
		return -80.0
	return linear_to_db(level)


## The decoded stream for a snd id (built once and cached), or null if the data
## has no such sound / it can't be decoded.
func stream_for(sound_id: int) -> AudioStreamWAV:
	if _streams.has(sound_id):
		return _streams[sound_id]
	var stream: AudioStreamWAV = null
	var info: PackedInt32Array = _nova.sound_info(sound_id)
	if info.size() >= 4 and info[3] > 0:
		stream = AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS   # info[2] is always 16
		stream.stereo = info[1] == 2
		stream.mix_rate = info[0]
		stream.data = _nova.sound_pcm(sound_id)
	_streams[sound_id] = stream
	if stream == null:
		missing_sounds[sound_id] = true
	return stream


## Queue interface beep n (1…5 = snd 150…154) at the call sites the Apple app
## uses; screens can also call nova.sound_beep(n) directly.
func beep(n: int) -> void:
	_nova.sound_beep(n)
