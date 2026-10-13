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
# STR# 130 #2 (an external mp3/mov, not a snd resource), only over the authentic
# main menu. This frontend has no main menu to play it over, so there is no music.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Node

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

# What the last drain asked each voice to do, for tests and debugging.
var cues_started := 0


func setup(nova: Object) -> void:
	_nova = nova
	_stride = int(nova.sound_stride())
	for i in int(nova.sound_voice_count()):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		add_child(p)
		_players.append(p)


func _process(_delta: float) -> void:
	if _nova != null:
		apply(_nova.drain_sound_cues())


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
	return stream


## Queue interface beep n (1…5 = snd 150…154) at the call sites the Apple app
## uses; screens can also call nova.sound_beep(n) directly.
func beep(n: int) -> void:
	_nova.sound_beep(n)
