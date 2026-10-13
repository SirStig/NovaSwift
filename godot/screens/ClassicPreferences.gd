# NOVA Swift — the original's Preferences window (Menu_RunSettingsDialog 0x00488650, DLOG/DITL
# 4003), drawn with the Classic UI kit at the DITL's own rects. A port of the Apple app's
# ClassicPreferencesView; opened by Settings > Interface > "Original Preferences Window...", never
# in place of the NovaSwift Settings screen.
#
# DITL index -> preference (Prefs [classic]): 1 Share Processor Time, 4 sound-volume label
# (STR# 136) with the PICT 135/134 down/up arrows at 5/6, 7 Intro Music, 8 QuickTime Movies,
# 9 Smoke Trails, 10 Run in a window (hidden: Windows-only), 11 Ship Animations, 12 Engine Glows,
# 13 Running Lights, 14 Weapon Effects, 15 Key Settings, 17 Parallax Starfield, 19 Ambient Sounds,
# 20 Hyperspace Effects, 21 Check For Updates, 23 brightness label (STR# 139) with arrows 24/25,
# 0 OK.
#
# Wired: the sound-volume arrows are the Settings master volume (step 0...8 = master 0...1) and
# Intro Music gates the title music; the rest are stored (so the dialog round-trips and the Apple
# defaults hold) but the Godot renderer has no counterpart yet. Key Settings opens the NovaSwift
# Controls page (the 34-cell DITL 4002 key dialog is not ported). The arrows are mouse-only in the
# original too; the same levels are sliders on the Settings Audio page for pad players.
extends CanvasLayer

const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Prefs = preload("res://Prefs.gd")

## OK / Esc / B.
signal closed
## "Key Settings": the host shows the NovaSwift Controls page.
signal key_settings
## A preference changed (Shell re-applies audio / music).
signal changed

const CHECKS := {1: "share_processor_time", 7: "intro_music", 8: "play_movies", 9: "smoke_trails",
	11: "ship_animations", 12: "engine_glow", 13: "running_lights", 14: "weapon_effects",
	17: "parallax_starfield", 19: "ambient_sounds", 21: "check_for_updates"}
const HYPERSPACE_ITEM := 20
const MAX_VOLUME := 8
const MAX_BRIGHTNESS := 6

var dialog: Control
var _nova: Object
var _host: Control
var _closing := false


func setup(nova: Object) -> void:
	_nova = nova
	layer = 75
	ClassicTheme.setup(nova)
	# The level the dialog shows follows the real master volume.
	Prefs.set_value("classic", "sound_volume_step", roundi(float(Prefs.get_value("audio", "master")) * MAX_VOLUME))
	_build()


func _label(list: int, n: int) -> String:
	if _nova == null:
		return ""
	var s: PackedStringArray = _nova.classic_strings(list)
	return s[n] if n >= 0 and n < s.size() else ""


func _build() -> void:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	var me := self
	var actions := {0: me._close, 15: func(): me.key_settings.emit(); me._close(),
		5: func(): me._volume(-1), 6: func(): me._volume(1),
		24: func(): me._brightness(-1), 25: func(): me._brightness(1)}
	for idx in CHECKS:
		actions[idx] = me._read_checks
	actions[HYPERSPACE_ITEM] = me._read_checks
	var step := int(Prefs.get_value("classic", "sound_volume_step"))
	var bright := int(Prefs.get_value("classic", "brightness_step"))
	dialog = ClassicDialog.from_ditl(_nova, 4003, {
		"texts": {4: _label(136, step), 23: _label(139, bright) if bright < 7 else ""},
		"actions": actions, "hidden": [10], "default_item": 0, "cancel_item": 0,
		"fallback_size": Vector2i(340, 300)})
	for idx in CHECKS:
		var c = dialog.item(idx)
		if c != null:
			c.set_pressed_no_signal(bool(Prefs.get_value("classic", CHECKS[idx])))
	var hs = dialog.item(HYPERSPACE_ITEM)
	if hs != null:
		hs.set_pressed_no_signal(bool(Prefs.get_value("classic", "hyperspace_effects")))
	_host = ClassicDialog.modal(self, dialog, 0.55)
	(func(): if is_instance_valid(dialog): dialog.focus_first()).call_deferred()


## The checkboxes -> Prefs. Called after every toggle (the kit calls the item's action).
func _read_checks() -> void:
	for idx in CHECKS:
		var c = dialog.item(idx)
		if c != null:
			Prefs.set_value("classic", CHECKS[idx], c.button_pressed)
	var hs = dialog.item(HYPERSPACE_ITEM)
	if hs != null:
		Prefs.set_value("classic", "hyperspace_effects", hs.button_pressed)
	Prefs.save()
	changed.emit()


## Volume arrows: master volume in 1/8 steps; each sounds snd 154 once applied (0x00488650).
func _volume(delta: int) -> void:
	var step := clampi(int(Prefs.get_value("classic", "sound_volume_step")) + delta, 0, MAX_VOLUME)
	Prefs.set_value("classic", "sound_volume_step", step)
	Prefs.set_value("audio", "master", float(step) / MAX_VOLUME)
	Prefs.save()
	changed.emit()
	dialog.set_text(4, _label(136, step))
	if _nova != null:
		_nova.sound_beep(5)


func _brightness(delta: int) -> void:
	var b := clampi(int(Prefs.get_value("classic", "brightness_step")) + delta, 0, MAX_BRIGHTNESS)
	Prefs.set_value("classic", "brightness_step", b)
	Prefs.save()
	dialog.set_text(23, _label(139, b) if b < 7 else "")
	changed.emit()


func _close() -> void:
	if _closing:
		return
	_closing = true
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()
