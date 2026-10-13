# NOVA Swift — the movie a `dësc` record names, played the way the original's text dialogs do
# (Ui_LoadDescAndPlayMovie 0x0049e3c0, Ui_RunTravelSelectionDialog 0x004982a0, Ui_PlayMovieFileModal
# 0x0049db00): before the text unless the dësc Flags say 0x0001 (after it); Flags 0x0002 = double size,
# 0x0004 = blank the whole screen first. Off with the classic "QuickTime Movies" pref, and a clip that
# cannot be found / converted (no ffmpeg) is skipped exactly like the pref being off.
#
# Pure GDScript with static helpers, loaded with preload() (no class_name).
extends RefCounted

const Movies = preload("res://Movies.gd")
const MoviePlayer = preload("res://ui/MoviePlayer.gd")
const Prefs = preload("res://Prefs.gd")

## Clips up to this size are converted on the spot (a few hundred ms); bigger ones in the background.
const SYNC_CONVERT_BYTES := 12 * 1024 * 1024


static func _plugins() -> Object:
	if not ClassDB.class_exists("NovaPlugins"):
		return null
	var pl: Object = ClassDB.instantiate("NovaPlugins")
	if pl != null and pl.has_method("desc_movie"):
		return pl
	return null


## {"info": Movies.ready() result, "after": bool, "double": bool, "fill": bool, "path": String} for the
## movie `desc_id` names when it can play right now, else {}.
static func lookup(desc_id: int) -> Dictionary:
	return _lookup(desc_id, false)


## The hypergate / wormhole entry movie for travel-target system `system_id` (Stellar_EnterHypergate
## 0x00456480 / Stellar_EnterWormhole 0x00456ca0 -> FUN_0049e3c0(target + 0x80): the dësc whose id is
## the target sÿst id, no text; shared Swift `GateTravelMovie`). Same result shape as `lookup`, {} when
## there is nothing to play (no target, no such dësc, pref off, no ffmpeg / file).
static func lookup_gate(system_id: int) -> Dictionary:
	return _lookup(system_id, true)


static func _lookup(desc_id: int, gate: bool) -> Dictionary:
	if desc_id < 128 and gate:
		return {}
	if desc_id < 0 or not bool(Prefs.get_value("classic", "play_movies")):
		return {}
	var pl: Object = _plugins()
	if pl == null:
		return {}
	var raw: String = ""
	if gate and pl.has_method("gate_movie"):
		raw = str(pl.gate_movie(desc_id))
	else:
		raw = str(pl.desc_movie(desc_id))
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return {}
	var dm: Dictionary = parsed
	var name: String = str(dm.get("movie", "")).strip_edges()
	if name == "":
		return {}
	var path: String = ""
	if pl.has_method("find_media"):
		path = str(pl.find_media(name))
	if path == "":
		path = Movies.find_movie(name, Movies.search_roots(""))
	if path == "":
		return {}
	var info: Dictionary = Movies.ready(path)
	if info.is_empty():
		if Movies._size(path) <= SYNC_CONVERT_BYTES:
			info = Movies.transcode(path)
		else:
			Movies.convert_async(path)
	if info.is_empty():
		return {}
	return {"info": info, "after": bool(dm.get("after", false)), "double": bool(dm.get("double", false)),
		"fill": bool(dm.get("fill", false)), "path": path}


## Full-screen skippable player over `host`'s tree; `then` runs once when it ends, is skipped or fails.
## Returns the overlay (a CanvasLayer) so callers/tests can inspect it.
static func play(host: Node, clip: Dictionary, then: Callable) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 120
	layer.name = "desc_movie"
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1.0 if bool(clip.get("fill", false)) else 0.92)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var area: Vector2 = Vector2(960, 720) if bool(clip.get("double", false)) else Vector2(480, 360)
	var vp: Vector2 = host.get_viewport().get_visible_rect().size
	area = area.min(vp - Vector2(40, 90))
	var player: Control = MoviePlayer.new()
	player.setup(clip.info, area)
	player.set_anchors_preset(Control.PRESET_CENTER)
	player.position = (vp - area) * 0.5 - Vector2(0, 20)
	root.add_child(player)
	var skip := Button.new()
	skip.text = "Skip"
	skip.custom_minimum_size = Vector2(110, 36)
	skip.position = Vector2((vp.x - 110.0) * 0.5, player.position.y + area.y + 14.0)
	skip.pressed.connect(func(): player.skip())
	root.add_child(skip)
	host.add_child(layer)
	player.finished.connect(func():
		layer.queue_free()
		then.call())
	return layer


## Plays the gate-entry movie for `system_id` over `host` and runs `then` afterwards; with nothing to
## play `then` runs at once. Returns the overlay (or null).
static func play_gate(host: Node, system_id: int, then: Callable) -> CanvasLayer:
	var clip: Dictionary = lookup_gate(system_id)
	if clip.is_empty():
		then.call()
		return null
	return play(host, clip, then)
