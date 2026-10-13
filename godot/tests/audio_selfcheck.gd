# Headless self-check for sound: snd decoding through the bridge, the shared
# event -> cue mapping, and the GDScript voice pool. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/audio_selfcheck.gd
extends SceneTree

const GameAudio = preload("res://audio/GameAudio.gd")


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame   # nodes only count as in-tree once the loop is running
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var ok := true
	ok = _check("load_game", nova.load_game(data)) and ok
	ok = _check("make_world", nova.make_world(-1)) and ok

	# --- decoding
	var ids: PackedInt32Array = nova.sound_ids()
	print("snd ids: ", ids.size())
	ok = _check("data has sounds", ids.size() > 50) and ok
	for id in [128, 130, 150, 154, 370, 390]:
		var info: PackedInt32Array = nova.sound_info(id)
		var pcm: PackedByteArray = nova.sound_pcm(id)
		print("  snd %d: rate=%s ch=%s bits=%s frames=%s bytes=%d" % [id, info[0] if info.size() else "-",
			info[1] if info.size() else "-", info[2] if info.size() else "-", info[3] if info.size() else "-", pcm.size()])
		ok = _check("snd %d decodes" % id, info.size() == 4 and info[3] > 0 and pcm.size() == info[3] * 2
			and info[0] >= 5000 and info[0] <= 48000 and info[1] == 1 and info[2] == 16) and ok
	ok = _check("missing snd is empty", nova.sound_info(99999).size() == 0 and nova.sound_pcm(99999).size() == 0) and ok

	# --- voice pool + beeps (no combat needed)
	var audio = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	ok = _check("16 voice players", audio.get_child_count() == 16) and ok
	nova.sound_beep(1)
	var rows: PackedFloat32Array = nova.drain_sound_cues()
	ok = _check("beep makes a start row", rows.size() == nova.sound_stride() and int(rows[1]) == 150 and int(rows[3]) == 1) and ok
	audio.apply(rows)
	ok = _check("player started", audio.cues_started == 1 and audio.get_child(int(rows[0])).playing) and ok
	ok = _check("stream cached", audio.stream_for(150) == audio.stream_for(150) and audio.stream_for(150) != null) and ok
	ok = _check("nothing changed -> no rows", nova.drain_sound_cues().size() == 0) and ok

	# --- combat scenario: fire guns at a hostile, expect weapon/explosion cues
	var seen := {}
	var total := 0
	nova.set_intent(false, false, true, false, false, true, false)
	for frame in 900:
		nova.select_nearest_target(true)
		nova.step(1.0 / 30.0)
		nova.drain_events()
		nova.drain_effects()
		var r: PackedFloat32Array = nova.drain_sound_cues()
		var j := 0
		while j + 6 <= r.size():
			if int(r[j + 3]) == 1:
				seen[int(r[j + 1])] = true
				total += 1
			j += 6
		audio.apply(r)
	print("combat: ", total, " sounds started, ids ", seen.keys())
	ok = _check("combat produced sound cues", total > 0) and ok

	print("AUDIO SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
