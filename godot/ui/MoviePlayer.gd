# NOVA Swift — plays one converted movie (see Movies.gd) in a fixed-size black area.
# Skippable with the confirm/cancel actions (Enter/Space/Esc, pad A/B) or a click;
# `finished` fires exactly once, on end, skip, or a decode failure/timeout, so callers
# never hang on a clip. Loaded with preload() (no class_name).
extends Control

signal finished

var _info: Dictionary = {}
var _done: bool = false
var _t: float = 0.0
var _video: VideoStreamPlayer
var _rect: TextureRect
var _audio: AudioStreamPlayer
var _last_frame: int = -1


## info = Movies.ready()/transcode() result; area = on-screen size.
func setup(info: Dictionary, area: Vector2) -> void:
	_info = info
	custom_minimum_size = area
	size = area
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	if String(info.get("kind", "")) == "ogv":
		_video = VideoStreamPlayer.new()
		var st := VideoStreamTheora.new()
		st.file = String(info.path)
		_video.stream = st
		_video.expand = true
		_video.set_anchors_preset(Control.PRESET_FULL_RECT)
		_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_video.finished.connect(_finish)
		add_child(_video)
		_video.play()
	else:
		_rect = TextureRect.new()
		_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_rect)
		var wav: String = String(info.get("audio", ""))
		if wav != "":
			var s: AudioStreamWAV = AudioStreamWAV.load_from_file(wav)
			if s != null:
				_audio = AudioStreamPlayer.new()
				_audio.stream = s
				add_child(_audio)
				_audio.play()
		_show_frame(0)


func _show_frame(i: int) -> void:
	var path: String = String(_info.dir).path_join("f%04d.jpg" % (i + 1))
	var img := Image.load_from_file(path)
	if img != null:
		_rect.texture = ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	if _rect != null:
		var n: int = int(_info.get("count", 0))
		var i: int = int(_t * float(_info.get("fps", 24.0)))
		if i >= n:
			_finish()
		elif i != _last_frame:
			_last_frame = i
			_show_frame(i)
	elif _t > 30.0:   # a stalled/undecodable clip must not strand the screen
		_finish()


func _input(event: InputEvent) -> void:
	if _done:
		return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_finish()
	elif event is InputEventMouseButton and event.pressed and get_global_rect().has_point(event.position):
		_finish()


func skip() -> void:
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	if _video != null:
		_video.stop()
	if _audio != null:
		_audio.stop()
	finished.emit()
