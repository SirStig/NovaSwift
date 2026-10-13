# NOVA Swift — settings plumbing (autoload).
#
# Prefs.gd holds every user setting; this node makes them DO something, live:
#
#   * engine   -- the gameplay settings go to the bridge as one JSON object (Prefs.engine_settings() ->
#                 NovaWorld.apply_settings): difficulty, system aliveness, game speed, auto-target,
#                 confirm / auto landing, invert turn and the enhancement toggles. The bridge applies
#                 them to the live world and to every world built afterwards.
#   * Caps Lock -- the original's 2x mode. Godot cannot query the lock's state, so this node tracks the
#                 key and pushes it (NovaWorld.set_caps_lock); the bridge runs GameSpeedRules.
#   * mouse aim -- Apple GameScene.updateMouseAim: while Input > Mouse aiming is on, the ship turns toward
#                 the pointer (NovaWorld.set_mouse_aim, a compass heading from the ship).
#   * colorblind -- a screen-space shader on the engine's own CIColorMatrix rows (NovaWorld.colorblind_matrix).
#   * FPS counter, frame-rate cap, UI scale, HUD opacity, smooth sprites, pause on focus loss, and the
#     "Land here?" confirmation (Settings > Confirm landing).
#
# It re-applies whenever Prefs.hub emits `changed` (one batch per frame) and when a NovaWorld enters the
# tree, so the Settings screen needs only Prefs.set_value. Nothing here edits Main.gd: the running scene
# is found through get_tree().current_scene and duck-typed (`_can_pause`, `_flight`, `_shell`).
extends Node

const Prefs = preload("res://Prefs.gd")
const ShellUI = preload("res://screens/ShellUI.gd")

const FPS_CAPS := {"fps30": 30, "fps60": 60, "fps120": 120, "unlimited": 0}
const COLORBLIND_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform vec4 row_r = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 row_g = vec4(0.0, 1.0, 0.0, 0.0);
uniform vec4 row_b = vec4(0.0, 0.0, 1.0, 0.0);
void fragment() {
	vec4 c = textureLod(screen_tex, SCREEN_UV, 0.0);
	COLOR = vec4(clamp(vec3(dot(row_r, c), dot(row_g, c), dot(row_b, c)), 0.0, 1.0), 1.0);
}
"""

## The bridge's NovaWorld (the latest one added to the tree).
var nova: Object
## Caps Lock as this node last saw it (see set_caps_lock).
var caps_lock := false
## The colorblind overlay (null until first needed) and its mode.
var cb_layer: CanvasLayer
var cb_mode := "none"
var fps_label: Label
var _confirm_layer: CanvasLayer
var _confirm_id := -1
var _dirty := true
var _fps_clock := 0.0
var _slow_clock := 0.0
var _mouse_aiming := false


func _ready() -> void:
	process_priority = 1000   # after the scene's own _process: it reads this frame's state
	Prefs.hub.changed.connect(_on_pref_changed)
	get_tree().node_added.connect(_on_node_added)
	for n in get_tree().root.get_children():
		_adopt(n)
	get_window().focus_exited.connect(_on_focus_lost)


func _adopt(n: Node) -> void:
	if n.get_class() == "NovaWorld":
		nova = n
		_dirty = true


func _on_node_added(n: Node) -> void:
	_adopt(n)


func _on_pref_changed(_section: String, _key: String) -> void:
	_dirty = true


## Re-apply everything now (also what tests call after changing Prefs).
func apply_now() -> void:
	_dirty = false
	if nova != null and is_instance_valid(nova):
		Prefs.apply_engine(nova)
		if nova.has_method("set_caps_lock"):
			nova.set_caps_lock(caps_lock)
	_apply_presentation()


func _process(delta: float) -> void:
	if _dirty:
		apply_now()
	_slow_clock += delta
	if _slow_clock >= 0.5:
		_slow_clock = 0.0
		_apply_hud_opacity()
	if fps_label != null and fps_label.visible:
		_fps_clock += delta
		if _fps_clock >= 0.25:
			_fps_clock = 0.0
			fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	if _mouse_aiming and not _in_flight():
		_set_mouse_aim(false, 0.0)   # menus, docked, maps: never leave a stale heading behind
	_poll_land_confirm()


# --- the running scene -------------------------------------------------------------------------

func _main() -> Node:
	var m := get_tree().current_scene
	return m if m != null and m.has_method("_can_pause") else null


## Flying with nothing modal up (Main._can_pause: not in a menu, paused, docked, or behind a dialog).
func _in_flight() -> bool:
	var m := _main()
	return m != null and bool(m.call("_can_pause"))


# --- Caps Lock ---------------------------------------------------------------------------------

## Caps Lock is the original's 2x mode. Tests / an on-screen toggle may set it directly.
func set_caps_lock(on: bool) -> void:
	caps_lock = on
	if nova != null and is_instance_valid(nova) and nova.has_method("set_caps_lock"):
		nova.set_caps_lock(on)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_CAPSLOCK and not event.echo:
		# macOS reports the lock's state as the key's state (down = on); elsewhere each tap toggles it.
		if OS.get_name() == "macOS":
			set_caps_lock(event.pressed)
		elif event.pressed:
			set_caps_lock(not caps_lock)
	elif event is InputEventMouseMotion and bool(Prefs.get_value("input", "mouse_aiming")):
		_mouse_motion(event.position)
	if _confirm_layer != null and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause_menu")):
		get_viewport().set_input_as_handled()
		_answer_land(false)


# --- mouse aim (Apple GameScene.updateMouseAim) --------------------------------------------------

func _mouse_motion(screen_pos: Vector2) -> void:
	if nova == null or not nova.has_method("set_mouse_aim") or not _in_flight():
		return
	var flight = _main().get("_flight")
	if flight == null or not flight.has_method("screen_to_world"):
		return
	var d: Vector2 = flight.screen_to_world(screen_pos) - nova.player_position()
	if d.length() <= 10.0:   # ignore tiny jitter at the ship
		return
	_set_mouse_aim(true, atan2(d.x, d.y))   # engine compass: 0 = +y (up), clockwise


func _set_mouse_aim(active: bool, heading: float) -> void:
	_mouse_aiming = active
	if nova != null and is_instance_valid(nova) and nova.has_method("set_mouse_aim"):
		nova.set_mouse_aim(active, heading)


# --- presentation settings ---------------------------------------------------------------------------

func _apply_presentation() -> void:
	var headless := DisplayServer.get_name() == "headless"
	if not bool(Prefs.get_value("input", "mouse_aiming")) and _mouse_aiming:
		_set_mouse_aim(false, 0.0)
	# Frame-rate cap. Not in headless runs: the self-checks would crawl at 60 fps.
	if not headless:
		Engine.max_fps = int(FPS_CAPS.get(str(Prefs.get_value("graphics", "frame_rate_cap")), 60))
	# UI scale (Apple uiScale): the logical viewport shrinks, so every screen grows.
	var us := clampf(float(Prefs.get_value("interface", "ui_scale")), 0.8, 1.4)
	if not is_equal_approx(get_window().content_scale_factor, us):
		get_window().content_scale_factor = us
	_apply_fps_counter()
	_apply_colorblind(str(Prefs.get_value("accessibility", "colorblind_mode")))
	_apply_sprite_filter()
	_apply_hud_opacity()


func _apply_fps_counter() -> void:
	var on := bool(Prefs.get_value("graphics", "show_fps"))
	if on and fps_label == null:
		var layer := CanvasLayer.new()
		layer.layer = 127
		layer.name = "FPSCounter"
		fps_label = Label.new()
		fps_label.add_theme_font_size_override("font_size", 13)
		fps_label.add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
		fps_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		fps_label.add_theme_constant_override("shadow_offset_x", 1)
		fps_label.add_theme_constant_override("shadow_offset_y", 1)
		fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		fps_label.offset_left = -84.0
		fps_label.offset_right = -8.0
		fps_label.offset_top = 6.0
		fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		layer.add_child(fps_label)
		add_child(layer)
	if fps_label != null:
		fps_label.visible = on
		fps_label.get_parent().visible = on


## The colorblind-assist filter: the engine's matrix rows (Apple's CIColorMatrix) in a screen-space shader.
func _apply_colorblind(mode: String) -> void:
	cb_mode = mode
	var rows := PackedFloat32Array()
	if nova != null and is_instance_valid(nova) and nova.has_method("colorblind_matrix"):
		rows = nova.colorblind_matrix(mode)
	if rows.size() != 16:
		if cb_layer != null:
			cb_layer.visible = false
		return
	if cb_layer == null:
		cb_layer = CanvasLayer.new()
		cb_layer.layer = 126
		cb_layer.name = "ColorblindFilter"
		var rect := ColorRect.new()
		rect.name = "Rect"
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = COLORBLIND_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = sh
		rect.material = mat
		cb_layer.add_child(rect)
		add_child(cb_layer)
	var m: ShaderMaterial = cb_layer.get_node("Rect").material
	m.set_shader_parameter("row_r", Vector4(rows[0], rows[1], rows[2], rows[3]))
	m.set_shader_parameter("row_g", Vector4(rows[4], rows[5], rows[6], rows[7]))
	m.set_shader_parameter("row_b", Vector4(rows[8], rows[9], rows[10], rows[11]))
	cb_layer.visible = true


## smooth_sprites: crisp (nearest) is the faithful default; linear smooths the world's sprites.
func _apply_sprite_filter() -> void:
	var m := _main()
	if m == null:
		return
	var flight = m.get("_flight")
	if flight is CanvasItem:
		flight.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR if bool(Prefs.get_value("graphics", "smooth_sprites")) \
				else CanvasItem.TEXTURE_FILTER_NEAREST


## hud_opacity: the primitive HUD is the scene's own drawing (self_modulate keeps the world opaque);
## the Classic status bar is a CanvasLayer child.
func _apply_hud_opacity() -> void:
	var m := _main()
	if m == null:
		return
	var a := Prefs.hud_opacity()
	var scene := m as CanvasItem
	if scene != null:
		scene.self_modulate.a = a
	var layer = m.get("_classic_hud")
	if layer is CanvasLayer and layer.get_child_count() > 0:
		var hud = layer.get_child(0)
		if hud is CanvasItem:
			hud.modulate.a = a


# --- pause on focus loss -------------------------------------------------------------------------------

func _on_focus_lost() -> void:
	if not bool(Prefs.get_value("gameplay", "pause_on_focus_loss")) or not _in_flight():
		return
	var shell = _main().get("_shell")
	if shell != null and shell.has_method("open_pause"):
		shell.open_pause()


# --- "Land here?" (Settings > Confirm landing) ----------------------------------------------------------

func _poll_land_confirm() -> void:
	if nova == null or not is_instance_valid(nova) or not nova.has_method("pending_land_confirm"):
		return
	var id: int = nova.pending_land_confirm()
	if id >= 0 and _confirm_layer == null:
		_show_land_confirm(id)
	elif id < 0 and _confirm_layer != null:
		_close_land_confirm()


func _show_land_confirm(id: int) -> void:
	_confirm_id = id
	_confirm_layer = CanvasLayer.new()
	_confirm_layer.layer = 90
	_confirm_layer.name = "LandConfirm"
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = ShellUI.theme()
	_confirm_layer.add_child(root)
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.5)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Land here?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var land := Button.new()
	land.name = "Land"
	land.text = "Land"
	land.custom_minimum_size = Vector2(110, 34)
	land.pressed.connect(_answer_land.bind(true))
	row.add_child(land)
	var cancel := Button.new()
	cancel.name = "Cancel"
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, 34)
	cancel.pressed.connect(_answer_land.bind(false))
	row.add_child(cancel)
	add_child(_confirm_layer)
	land.grab_focus()


func _answer_land(accept: bool) -> void:
	_close_land_confirm()
	if nova == null or not is_instance_valid(nova):
		return
	var r = JSON.parse_string(nova.confirm_landing(accept))
	if r is Dictionary and r.get("result", "") in ["landed", "gate"]:
		var m := _main()
		if m != null and m.has_method("_suppress_held"):
			m.call("_suppress_held")
		if r.get("result", "") == "gate" and m != null:
			var nav = m.get("_nav")
			if nav != null and nav.has_method("open_gate_picker"):
				nav.open_gate_picker()


func _close_land_confirm() -> void:
	if _confirm_layer != null:
		_confirm_layer.queue_free()
		_confirm_layer = null
	_confirm_id = -1
